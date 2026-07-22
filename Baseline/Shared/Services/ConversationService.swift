import Foundation
import CryptoKit
import UIKit
@preconcurrency import FirebaseFunctions

/// The remote boundary of the conversation runtime, mirroring `WorkoutImportRemoteCalling` so the
/// turn's timeout, cancellation, and error mapping are unit-testable without a network.
protocol ConversationRemoteCalling: AnyObject, Sendable {
    var timeoutInterval: TimeInterval { get set }
    /// Returns the callable's response payload re-encoded as JSON `Data`: the raw response is a
    /// heterogeneous object graph (non-Sendable), and the deadline race needs a Sendable value.
    func call(_ request: [String: String]) async throws -> Data
}

private final class FirebaseConversationRemoteCallable: ConversationRemoteCalling, @unchecked Sendable {
    private let callable: HTTPSCallable

    var timeoutInterval: TimeInterval {
        get { callable.timeoutInterval }
        set { callable.timeoutInterval = newValue }
    }

    init(functions: Functions, name: String) {
        callable = functions.httpsCallable(name)
    }

    func call(_ request: [String: String]) async throws -> Data {
        let raw = try await callable.call(request).data
        guard JSONSerialization.isValidJSONObject(raw) else { return Data() }
        return try JSONSerialization.data(withJSONObject: raw)
    }
}

enum ConversationError: Error, Equatable {
    /// The wall-clock deadline for one model round elapsed. Distinct from the callable's own
    /// timeout, which is idle-based and never fires on a connection that trickles bytes.
    case roundDeadlineExceeded
    case badResponse
}

/// The app side of the **Conversation Runtime**. Sends the transcript to the `conversation` Cloud
/// Function, then runs the on-device tool loop — map each `tool_use` → validated `AgentTools.Call`
/// → dispatch → `tool_result` → resend — until the model returns a final reply. The deterministic
/// engine owns truth; this only shuttles language and executes validated tools. See
/// docs/architecture.md (Context Engine) + docs/conversation-design.md.
@MainActor
@Observable
final class ConversationService {

    /// Network patience knobs, injectable so tests can compress them to fractions of a second.
    struct Timeouts: Sendable {
        /// Idle timeout handed to the callable (`URLRequest.timeoutInterval`). It resets on every
        /// received byte, so on its own it cannot bound a trickling connection.
        var callableIdleSeconds: TimeInterval = 30
        /// Wall-clock bound on one model round — the guarantee that a turn always ends. Generous
        /// because a tool-using model round legitimately takes tens of seconds.
        var roundDeadlineSeconds: TimeInterval = 60
        /// Wall-clock bound on the fail-open observability export.
        var telemetryDeadlineSeconds: TimeInterval = 10
    }

    enum Scope: Equatable, Sendable {
        case general
        case workoutImport
    }

    enum Surface: String, Equatable, Sendable {
        case today = "chat.today"
        case plan = "chat.plan"
        case workout = "chat.workout"
        case workoutImport = "chat.import_fix"
    }

    struct Message: Identifiable, Sendable {
        enum Role: Sendable { case you, baseline }
        let id = UUID()
        let role: Role
        let text: String
    }

    /// One behind-the-scenes tool the model actually invoked — surfaced in the state inspector so
    /// the athlete can see what the conversation logged, not just what it said.
    struct ToolEvent: Identifiable, Sendable {
        let id = UUID()
        let label: String
    }

    private(set) var log: [Message] = []
    private(set) var isThinking = false

    /// True only while a turn task is in flight and can actually be stopped. `isThinking` also
    /// covers the local undo, which has no task to cancel, so the stop affordance keys off this.
    var canCancelTurn: Bool { turnTask != nil }

    // Observability: the structured state + plan the conversation is building, exposed for the
    // "What Baseline knows" inspector.
    private(set) var latestDecision: DecisionEngine.Result?
    private(set) var latestPlan: PlanningEngine.Plan?
    private(set) var latestWorkoutMutationReceipt: WorkoutMutationReceipt?
    private(set) var toolActivity: [ToolEvent] = []

    private let tools: AgentTools
    private let makeCallable: @Sendable (String) -> any ConversationRemoteCalling
    private let scope: Scope
    private let surface: Surface
    private let timeouts: Timeouts
    /// Import scope only: the live import issues (ids, severity, messages, candidates) supplied by
    /// the review screen. A closure, not a snapshot - issues reconcile away as the draft is fixed,
    /// and each round must describe what is still actually open.
    private let importIssueContext: (@MainActor () -> String?)?
    private let conversationSessionID = UUID().uuidString.lowercased()
    private var transcript: [[String: Any]] = []      // Anthropic wire-format messages
    private let maxToolRounds = 6                       // safety bound on tool ping-pong
    private var activeTraceID = ""
    private var pendingToolObservations: [ClientToolObservation] = []
    private var turnTask: Task<Void, Never>?

    convenience init(
        tools: AgentTools,
        functions: Functions = Functions.functions(),
        scope: Scope = .general,
        surface: Surface = .today,
        timeouts: Timeouts = .init(),
        importIssueContext: (@MainActor () -> String?)? = nil
    ) {
        self.init(
            tools: tools,
            makeCallable: { FirebaseConversationRemoteCallable(functions: functions, name: $0) },
            scope: scope,
            surface: surface,
            timeouts: timeouts,
            importIssueContext: importIssueContext
        )
    }

    init(
        tools: AgentTools,
        makeCallable: @escaping @Sendable (String) -> any ConversationRemoteCalling,
        scope: Scope = .general,
        surface: Surface = .today,
        timeouts: Timeouts = .init(),
        importIssueContext: (@MainActor () -> String?)? = nil
    ) {
        self.tools = tools
        self.makeCallable = makeCallable
        self.scope = scope
        self.surface = scope == .workoutImport ? .workoutImport : surface
        self.timeouts = timeouts
        self.importIssueContext = importIssueContext
    }

    var canUndoLatestWorkoutMutation: Bool {
        latestWorkoutMutationReceipt?.undoAvailable == true && !isThinking
    }

    func send(_ text: String) {
        let userText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty, !isThinking else { return }
        log.append(Message(role: .you, text: userText))
        // Checkpoint *before* this turn: if it fails, we roll the transcript back here so it never
        // ends on a dangling user/tool turn — otherwise the next send stacks two user turns and the
        // API rejects every subsequent message until the chat is reopened.
        let checkpoint = transcript.count
        activeTraceID = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        pendingToolObservations = []
        transcript.append(["role": "user", "content": userText])
        isThinking = true
        turnTask = Task { [weak self] in
            guard let self else { return }
            // `defer` and not straight-line code: the loading state must clear on every exit —
            // clean finish, failure, and cancellation alike. A stuck `isThinking` locks the composer.
            defer {
                isThinking = false
                turnTask = nil
            }
            let completed = await runLoop()
            if !completed { transcript.removeLast(transcript.count - checkpoint) }
        }
    }

    /// Aborts the in-flight turn. The turn task rolls the transcript back to its pre-turn
    /// checkpoint and clears the loading state; no error copy is appended, because the athlete
    /// chose to stop — but a tool result already committed this turn still surfaces.
    func cancelTurn() {
        turnTask?.cancel()
    }

    /// Applies the exact persisted inverse represented by the latest receipt. This deliberately
    /// bypasses the model: undo is a deterministic user action bound to one mutation and revision.
    func undoLatestWorkoutMutation() {
        guard canUndoLatestWorkoutMutation,
              let receipt = latestWorkoutMutationReceipt else { return }
        isThinking = true
        Task { [weak self] in
            guard let self else { return }
            let call: AgentTools.Call = if receipt.scope == .performedLog {
                .undoSessionMutation(
                    mutationID: receipt.mutationID,
                    expectedRevisionToken: receipt.afterRevisionToken
                )
            } else {
                .undoWorkoutMutation(
                    mutationID: receipt.mutationID,
                    expectedRevisionToken: receipt.afterRevisionToken
                )
            }
            let response = await tools.execute(call)
            record(call, response)
            if response.mutationReceipt == nil {
                latestWorkoutMutationReceipt = nil
            }
            log.append(Message(role: .baseline, text: response.userFacingText))
            isThinking = false
        }
    }

    /// Returns true only on a clean finish (a final assistant reply). False on a network failure or
    /// tool-round exhaustion — the caller rolls the failed turn out of the transcript.
    @discardableResult
    private func runLoop() async -> Bool {
        // Tools mutate local state (constraints, workout) before the model's follow-up reply. If that
        // follow-up fails, the change is already committed — so report the deterministic tool result
        // instead of a misleading "couldn't reach the coach" (which implies nothing happened). Only
        // the human sentence from mutating tools qualifies: the full result text carries machine
        // payload (receipts, revision tokens) that must never become an athlete-visible bubble.
        var lastToolResult: String?
        for roundIndex in 0..<maxToolRounds {
            let content: [[String: Any]]
            do {
                content = try await callFunction(roundIndex: roundIndex)
            } catch is CancellationError {
                // The athlete stopped the turn: no error copy, but a mutation a tool already
                // committed must still surface — the same invariant the failure path holds.
                if let lastToolResult { log.append(Message(role: .baseline, text: lastToolResult)) }
                return false
            } catch {
                // Message first, telemetry second: the athlete should not wait out the (bounded,
                // fail-open) observability export before learning the turn failed.
                log.append(Message(role: .baseline, text: lastToolResult
                    ?? Self.failureMessage(for: error)))
                await sendTerminalTelemetry("provider_failed", roundIndex: roundIndex)
                return false
            }
            transcript.append(["role": "assistant", "content": content])

            var text = ""
            var toolUses: [(id: String, name: String, input: [String: Any])] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let s = block["text"] as? String { text += s }
                case "tool_use":
                    if let id = block["id"] as? String, let name = block["name"] as? String {
                        toolUses.append((id, name, block["input"] as? [String: Any] ?? [:]))
                    }
                default:
                    break
                }
            }
            if toolUses.isEmpty {
                if !text.isEmpty { log.append(Message(role: .baseline, text: text)) }
                return true                                // final reply, no tools → clean finish
            }

            // Execute each requested tool on-device and feed results back for the model's follow-up.
            var results: [[String: Any]] = []
            var userFacingResults: [String] = []
            for (requestedOrder, tu) in toolUses.enumerated() {
                let started = ContinuousClock.now
                let decodeStarted = ContinuousClock.now
                let mappedCall = ToolCallMapper.map(name: tu.name, input: tu.input)
                let decodeMilliseconds = Self.milliseconds(since: decodeStarted)
                let permissionStarted = ContinuousClock.now
                let permissionGranted = mappedCall.map(permits)
                let permissionMilliseconds = Self.milliseconds(since: permissionStarted)
                let resultText: String
                let resultCategory: String
                let errorCode: String?
                let readOnly: Bool
                var executionMilliseconds = 0.0
                var resultHasDecision = false
                var resultHasPlan = false
                if let call = mappedCall, permissionGranted == true {
                    let executionStarted = ContinuousClock.now
                    let response = await tools.execute(call)   // retrieval tools query HealthKit / the store
                    executionMilliseconds = Self.milliseconds(since: executionStarted)
                    resultText = response.text
                    resultCategory = "completed"
                    errorCode = nil
                    readOnly = !call.showsInActivityFeed
                    resultHasDecision = response.decision != nil
                    resultHasPlan = response.plan != nil
                    if call.showsInActivityFeed { userFacingResults.append(response.userFacingText) }
                    record(call, response)
                } else if scope == .workoutImport {
                    resultText = "That action isn't available while fixing an imported workout. Only edit the draft workout."
                    resultCategory = mappedCall == nil ? "malformed" : "rejected_scope"
                    errorCode = mappedCall == nil ? "invalid_tool_call" : "scope_denied"
                    readOnly = mappedCall.map { !$0.showsInActivityFeed } ?? false
                } else {
                    resultText = "That tool call wasn't valid."
                    resultCategory = "malformed"
                    errorCode = "invalid_tool_call"
                    readOnly = false
                }
                pendingToolObservations.append(ClientToolObservation(
                    toolUseID: tu.id,
                    name: tu.name,
                    roundIndex: roundIndex,
                    requestedOrder: requestedOrder,
                    argumentSummary: Self.argumentSummary(tu.input),
                    argumentHash: Self.hashJSON(tu.input),
                    decodeResult: mappedCall == nil ? "failed" : "passed",
                    permissionResult: mappedCall == nil ? "not_evaluated" :
                        permissionGranted == true ? "passed" : "failed",
                    resultCategory: resultCategory,
                    resultSummary: .init(
                        textBytes: resultText.lengthOfBytes(using: .utf8),
                        hasDecision: resultHasDecision,
                        hasPlan: resultHasPlan
                    ),
                    resultHash: Self.hash(resultText),
                    errorCode: errorCode,
                    decodeMilliseconds: decodeMilliseconds,
                    permissionMilliseconds: permissionMilliseconds,
                    executionMilliseconds: executionMilliseconds,
                    durationMilliseconds: Self.milliseconds(since: started),
                    readOnly: readOnly
                ))
                results.append(["type": "tool_result", "tool_use_id": tu.id, "content": resultText])
            }
            if !userFacingResults.isEmpty { lastToolResult = userFacingResults.joined(separator: "\n") }
            transcript.append(["role": "user", "content": results])
        }
        log.append(Message(role: .baseline, text: "Let's take that one step at a time — ask me again?"))
        await sendTerminalTelemetry("tool_round_exhausted", roundIndex: maxToolRounds - 1)
        return false   // tool rounds exhausted → transcript ends on a tool_result; roll it back
    }

    /// Keep the inspector's live view in sync: refresh the plan snapshot, and log the calls worth
    /// showing as "what changed" to the activity feed.
    private func record(_ call: AgentTools.Call, _ response: AgentTools.Response) {
        if let d = response.decision { latestDecision = d }
        if let p = response.plan { latestPlan = p }
        if let receipt = response.mutationReceipt { latestWorkoutMutationReceipt = receipt }
        if Self.shouldRecordActivity(call, response: response) {
            toolActivity.append(ToolEvent(label: call.activityLabel))
        }
    }

    static func shouldRecordActivity(_ call: AgentTools.Call, response: AgentTools.Response) -> Bool {
        guard call.showsInActivityFeed else { return false }
        return !call.requiresWorkoutMutationReceiptForActivity || response.mutationReceipt != nil
    }

    private func callFunction(roundIndex: Int) async throws -> [[String: Any]] {
        let today = tools.dispatch(.getToday)
        latestDecision = today.decision
        latestPlan = today.plan
        let contextSummary: String
        if scope == .workoutImport {
            let issueBlock = importIssueContext?().map { "\n\n\($0)" } ?? ""
            contextSummary = "CURRENT SURFACE: Fixing an imported workout draft. Only inspect or edit this workout. Do not change readiness, health context, the week plan, logging state, or saved templates.\(issueBlock)\n\n\(tools.contextSummary())"
        } else {
            contextSummary = tools.contextSummary()   // full durable state = the model's memory
        }
        // The transcript is heterogeneous JSON (non-Sendable), so ship it as a string; the request
        // dict is then [String: String] (Sendable) and safe to send across the callable boundary.
        guard let data = try? JSONSerialization.data(withJSONObject: transcript),
              let messagesJSON = String(data: data, encoding: .utf8) else { throw ConversationError.badResponse }
        var request = traceRequest(roundIndex: roundIndex)
        request["messages"] = messagesJSON
        request["contextSummary"] = contextSummary
        if let toolEvents = Self.encodedToolObservations(pendingToolObservations) {
            request["toolEvents"] = toolEvents
        }
        let callable = makeCallable("conversation")
        callable.timeoutInterval = timeouts.callableIdleSeconds
        let response = try await Self.callRacingDeadline(
            callable, request: request, deadline: timeouts.roundDeadlineSeconds
        )
        pendingToolObservations = []
        guard let payload = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let content = payload["content"] as? [[String: Any]] else {
            throw ConversationError.badResponse
        }
        return content
    }

    private func sendTerminalTelemetry(_ outcome: String, roundIndex: Int) async {
        var request = traceRequest(roundIndex: roundIndex)
        request["terminalOutcome"] = outcome
        if let toolEvents = Self.encodedToolObservations(pendingToolObservations) {
            request["toolEvents"] = toolEvents
        }
        let callable = makeCallable("recordLLMObservability")
        callable.timeoutInterval = timeouts.telemetryDeadlineSeconds
        do {
            _ = try await Self.callRacingDeadline(
                callable, request: request, deadline: timeouts.telemetryDeadlineSeconds
            )
            pendingToolObservations = []
        } catch {
            // Observability is fail-open. The athlete's chat result must never depend on export.
        }
    }

    // MARK: - Deadline race

    /// Copy for a turn that failed because the network is gone or too degraded to finish.
    static let offlineFailureMessage = "No connection right now - check your signal and try again."
    /// Copy for any other failed turn.
    static let genericFailureMessage = "I couldn't reach the coach just now — try again in a moment."

    static func failureMessage(for error: any Error) -> String {
        isConnectivityFailure(error) ? offlineFailureMessage : genericFailureMessage
    }

    /// Walks the error chain looking for a connectivity-shaped failure. The Functions SDK surfaces
    /// transport errors both directly (NSURLErrorDomain) and wrapped in FunctionsErrorDomain, so
    /// both the top error and its underlying chain are inspected.
    static func isConnectivityFailure(_ error: any Error) -> Bool {
        if let conversationError = error as? ConversationError {
            return conversationError == .roundDeadlineExceeded
        }
        var next: NSError? = error as NSError
        while let nsError = next {
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                     NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
                    return true
                default:
                    break
                }
            }
            if nsError.domain == FunctionsErrorDomain,
               nsError.code == FunctionsErrorCode.unavailable.rawValue ||
               nsError.code == FunctionsErrorCode.deadlineExceeded.rawValue {
                return true
            }
            next = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Races the callable against a wall-clock deadline, honoring caller cancellation.
    ///
    /// Structured concurrency cannot express this race: a task group waits for every child on scope
    /// exit, and the Functions SDK's async `call` is a completion-handler import that ignores task
    /// cancellation — a hung fetch child would keep the group (and the turn) alive for the full
    /// hang, which on a trickling connection is forever (the callable's own timeout is idle-based).
    /// The fetch therefore runs unstructured; whichever of fetch / deadline / caller-cancellation
    /// finishes first resumes the continuation, and the losing arms are cancelled best-effort.
    private static func callRacingDeadline(
        _ callable: any ConversationRemoteCalling,
        request: [String: String],
        deadline: TimeInterval
    ) async throws -> Data {
        let race = RaceBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.begin(continuation)
                let fetch = Task {
                    do { race.finish(.success(try await callable.call(request))) }
                    catch { race.finish(.failure(error)) }
                }
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(deadline)) } catch { return }
                    race.finish(.failure(ConversationError.roundDeadlineExceeded))
                }
                race.register([fetch, timer])
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// First-finish-wins holder for the deadline race. All state is guarded by the lock; late
    /// `finish` calls from losing arms no-op, and a `begin` that arrives after an early cancellation
    /// resumes immediately with the stored result. Safe to call from any thread.
    private final class RaceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, any Error>?
        private var result: Result<Data, any Error>?
        private var pending: [Task<Void, Never>] = []

        func begin(_ continuation: CheckedContinuation<Data, any Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func register(_ tasks: [Task<Void, Never>]) {
            lock.lock()
            if result != nil {
                lock.unlock()
                tasks.forEach { $0.cancel() }
                return
            }
            pending = tasks
            lock.unlock()
        }

        func finish(_ newResult: Result<Data, any Error>) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = newResult
            let continuation = continuation
            self.continuation = nil
            let losers = pending
            pending = []
            lock.unlock()
            losers.forEach { $0.cancel() }
            continuation?.resume(with: newResult)
        }
    }

    private func traceRequest(roundIndex: Int) -> [String: String] {
        [
            "traceID": activeTraceID,
            "sessionID": conversationSessionID,
            "surface": surface.rawValue,
            "roundIndex": String(roundIndex),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "appBuild": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "clientToolSchemaVersion": "9",
            "iosVersion": Self.operatingSystemVersion,
            "deviceClass": Self.deviceClass,
        ]
    }

    /// An allowlist, denying by default: a tool added later stays out of the import scope until someone
    /// decides it belongs. The catalog reads are in because fixing a draft means naming exercises, and
    /// a guessed name that isn't in the catalog logs against the generic placeholder - the exact failure
    /// search_exercises exists to prevent. They read a static library and change nothing.
    func permits(_ call: AgentTools.Call) -> Bool {
        guard scope == .workoutImport else { return true }
        switch call {
        case .updateWorkoutMetadata, .updateBlockMetadata, .updateExerciseMetadata,
             .addBlock, .removeBlock, .moveBlock, .duplicateBlock, .addExercise, .moveExercise,
             .replaceExercise, .requireAllOptions, .removeExercise, .reorderExercise,
             .duplicateExercise, .addSet, .updateSet, .removeSet, .moveSet, .duplicateSet,
             .updateGroup, .updateChoice, .convertChoiceToGroup, .updateRest, .addRest,
             .moveNode, .removeNode, .addSetAlternative, .updateSetAlternative,
             .removeSetAlternative, .updateExercisePrescription,
             .applyWorkoutEdits, .convertWorkoutUnits, .bulkReplaceExercises,
             .getCurrentWorkout, .updateLoggingConfig,
             .setMetricValue, .removeMetric, .undoWorkoutMutation, .searchExercises, .getExercise,
             // Custom creation is in because an imported draft can genuinely contain a movement the
             // catalog lacks - creating it (deliberately, behind the proposal-confirm flow) is how an
             // unknown-exercise issue resolves without losing the movement's identity. The transient
             // review store already write-throughs deliberate catalog changes to the athlete's real
             // configuration by design.
             .createCustomExercise:
            return true
        default:
            return false
        }
    }

    private struct ClientToolObservation: Codable {
        struct ArgumentSummary: Codable {
            var argumentCount: Int
            var valueTypeCounts: [String: Int]
        }

        struct ResultSummary: Codable {
            var textBytes: Int
            var hasDecision: Bool
            var hasPlan: Bool
        }

        var toolUseID: String
        var name: String
        var roundIndex: Int
        var requestedOrder: Int
        var argumentSummary: ArgumentSummary
        var argumentHash: String
        var decodeResult: String
        var permissionResult: String
        var resultCategory: String
        var resultSummary: ResultSummary
        var resultHash: String
        var errorCode: String?
        var decodeMilliseconds: Double
        var permissionMilliseconds: Double
        var executionMilliseconds: Double
        var durationMilliseconds: Double
        var readOnly: Bool
    }

    private static func argumentSummary(_ input: [String: Any]) -> ClientToolObservation.ArgumentSummary {
        var valueTypeCounts: [String: Int] = [:]
        for (_, value) in input.prefix(40) {
            let valueType: String
            switch value {
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                valueType = "boolean"
            case is NSNumber:
                valueType = "number"
            case is String:
                valueType = "string"
            case is [Any]:
                valueType = "array"
            case is [String: Any]:
                valueType = "object"
            case is NSNull:
                valueType = "null"
            default:
                valueType = "other"
            }
            valueTypeCounts[valueType, default: 0] += 1
        }
        return .init(
            argumentCount: min(input.count, 40),
            valueTypeCounts: valueTypeCounts
        )
    }

    private static func encodedToolObservations(_ observations: [ClientToolObservation]) -> String? {
        guard !observations.isEmpty,
              let data = try? JSONEncoder().encode(Array(observations.prefix(24))) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func hashJSON(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return hash("unserializable")
        }
        return hash(data)
    }

    private static func hash(_ value: String) -> String {
        hash(Data(value.utf8))
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static var deviceClass: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: "iphone"
        case .pad: "ipad"
        case .mac: "mac"
        case .vision: "vision"
        default: "other"
        }
    }

    private static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
