import Foundation
import CryptoKit
import UIKit
@preconcurrency import FirebaseFunctions

/// The app side of the **Conversation Runtime**. Sends the transcript to the `conversation` Cloud
/// Function, then runs the on-device tool loop — map each `tool_use` → validated `AgentTools.Call`
/// → dispatch → `tool_result` → resend — until the model returns a final reply. The deterministic
/// engine owns truth; this only shuttles language and executes validated tools. See
/// docs/architecture.md (Context Engine) + docs/conversation-design.md.
@MainActor
@Observable
final class ConversationService {

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

    // Observability: the structured state + plan the conversation is building, exposed for the
    // "What Baseline knows" inspector.
    private(set) var latestDecision: DecisionEngine.Result?
    private(set) var latestPlan: PlanningEngine.Plan?
    private(set) var latestWorkoutMutationReceipt: WorkoutMutationReceipt?
    private(set) var toolActivity: [ToolEvent] = []

    private let tools: AgentTools
    private let functions: Functions
    private let scope: Scope
    private let surface: Surface
    private let conversationSessionID = UUID().uuidString.lowercased()
    private var transcript: [[String: Any]] = []      // Anthropic wire-format messages
    private let maxToolRounds = 6                       // safety bound on tool ping-pong
    private var activeTraceID = ""
    private var pendingToolObservations: [ClientToolObservation] = []

    init(
        tools: AgentTools,
        functions: Functions = Functions.functions(),
        scope: Scope = .general,
        surface: Surface = .today
    ) {
        self.tools = tools
        self.functions = functions
        self.scope = scope
        self.surface = scope == .workoutImport ? .workoutImport : surface
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
        Task { [weak self] in
            guard let self else { return }
            let completed = await runLoop()
            if !completed { transcript.removeLast(transcript.count - checkpoint) }
            isThinking = false
        }
    }

    /// Applies the exact persisted inverse represented by the latest receipt. This deliberately
    /// bypasses the model: undo is a deterministic user action bound to one mutation and revision.
    func undoLatestWorkoutMutation() {
        guard canUndoLatestWorkoutMutation,
              let receipt = latestWorkoutMutationReceipt else { return }
        isThinking = true
        Task { [weak self] in
            guard let self else { return }
            let call = AgentTools.Call.undoWorkoutMutation(
                mutationID: receipt.mutationID,
                expectedRevisionToken: receipt.afterRevisionToken
            )
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
            guard let content = await callFunction(roundIndex: roundIndex) else {
                await sendTerminalTelemetry("provider_failed", roundIndex: roundIndex)
                log.append(Message(role: .baseline, text: lastToolResult
                    ?? "I couldn't reach the coach just now — try again in a moment."))
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
        await sendTerminalTelemetry("tool_round_exhausted", roundIndex: maxToolRounds - 1)
        log.append(Message(role: .baseline, text: "Let's take that one step at a time — ask me again?"))
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

    private func callFunction(roundIndex: Int) async -> [[String: Any]]? {
        let today = tools.dispatch(.getToday)
        latestDecision = today.decision
        latestPlan = today.plan
        let contextSummary = scope == .workoutImport
            ? "CURRENT SURFACE: Fixing an imported workout draft. Only inspect or edit this workout. Do not change readiness, health context, the week plan, logging state, or saved templates.\n\n\(tools.contextSummary())"
            : tools.contextSummary()   // full durable state = the model's memory
        // The transcript is heterogeneous JSON (non-Sendable), so ship it as a string; the request
        // dict is then [String: String] (Sendable) and safe to send across the callable boundary.
        guard let data = try? JSONSerialization.data(withJSONObject: transcript),
              let messagesJSON = String(data: data, encoding: .utf8) else { return nil }
        var request = traceRequest(roundIndex: roundIndex)
        request["messages"] = messagesJSON
        request["contextSummary"] = contextSummary
        if let toolEvents = Self.encodedToolObservations(pendingToolObservations) {
            request["toolEvents"] = toolEvents
        }
        do {
            let result = try await functions.httpsCallable("conversation").call(request)
            let payload = result.data as? [String: Any]
            pendingToolObservations = []
            return payload?["content"] as? [[String: Any]]
        } catch {
            return nil
        }
    }

    private func sendTerminalTelemetry(_ outcome: String, roundIndex: Int) async {
        var request = traceRequest(roundIndex: roundIndex)
        request["terminalOutcome"] = outcome
        if let toolEvents = Self.encodedToolObservations(pendingToolObservations) {
            request["toolEvents"] = toolEvents
        }
        do {
            _ = try await functions.httpsCallable("recordLLMObservability").call(request)
            pendingToolObservations = []
        } catch {
            // Observability is fail-open. The athlete's chat result must never depend on export.
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
             .addBlock, .addExercise, .moveExercise, .replaceExercise, .requireAllOptions,
             .removeExercise, .addSet, .updateSet, .removeSet, .moveSet, .duplicateSet,
             .getCurrentWorkout, .updateLoggingConfig,
             .setMetricValue, .removeMetric, .undoWorkoutMutation, .searchExercises, .getExercise:
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
