import Foundation
import Testing
@preconcurrency import FirebaseFunctions
@testable import Baseline

/// A conversation turn must always end, whatever the network does. These drive `ConversationService`
/// through its remote seam with no network at all: a callable that hangs forever stands in for the
/// gym-wifi stall that once locked the chat sheet permanently (the callable's idle timeout resets on
/// every trickled byte, so only the service's own wall-clock deadline can bound it).
@MainActor
struct ConversationServiceRecoveryTests {

    /// Plays its behaviors in call order, repeating the last one forever — so a single-behavior
    /// script keeps its old always-that-behavior meaning, and a multi-round script can commit a
    /// tool mutation on round one and hang (or reply) on round two. State is lock-guarded because
    /// the service's deadline race invokes `call` off the main actor.
    private final class ScriptedCallable: ConversationRemoteCalling, @unchecked Sendable {
        enum Behavior: Sendable {
            case hang                      // never returns; the realistic stalled-connection shape
            case fail(any Error)
            case reply(Data)
        }

        var timeoutInterval: TimeInterval = 70
        private let lock = NSLock()
        private var remaining: [Behavior]
        private var received: [[String: String]] = []

        init(_ behaviors: [Behavior]) { remaining = behaviors }

        /// Every request the service actually sent, in order — lets a test assert the transcript the
        /// retry reconstructed rather than only the observable log.
        var requests: [[String: String]] { lock.withLock { received } }

        private func nextBehavior() -> Behavior {
            lock.withLock {
                remaining.count > 1 ? remaining.removeFirst() : remaining[0]
            }
        }

        func call(_ request: [String: String]) async throws -> Data {
            lock.withLock { received.append(request) }
            switch nextBehavior() {
            case .hang:
                try await Task.sleep(for: .seconds(3600))
                return Data()
            case .fail(let error):
                throw error
            case .reply(let data):
                return data
            }
        }
    }

    private func makeService(
        behavior: ScriptedCallable.Behavior,
        timeouts: ConversationService.Timeouts = .init()
    ) -> ConversationService {
        makeService(behaviors: [behavior], timeouts: timeouts)
    }

    private func makeService(
        behaviors: [ScriptedCallable.Behavior],
        tools: AgentTools? = nil,
        timeouts: ConversationService.Timeouts = .init()
    ) -> ConversationService {
        makeServiceAndCallable(behaviors: behaviors, tools: tools, timeouts: timeouts).service
    }

    /// Like `makeService` but also hands back the callable, so a test can inspect the exact requests
    /// the service sent (the retry-reconstructs-the-transcript assertion needs the wire messages).
    private func makeServiceAndCallable(
        behaviors: [ScriptedCallable.Behavior],
        tools: AgentTools? = nil,
        timeouts: ConversationService.Timeouts = .init()
    ) -> (service: ConversationService, callable: ScriptedCallable) {
        let defaults = UserDefaults(suiteName: "ConversationServiceRecoveryTests-\(UUID().uuidString)")!
        let callable = ScriptedCallable(behaviors)
        let service = ConversationService(
            tools: tools ?? AgentTools(store: TrainingContextStore(defaults: defaults), base: DecisionEngine.Inputs()),
            makeCallable: { _ in callable },
            timeouts: timeouts
        )
        return (service, callable)
    }

    /// Short enough that tests finish fast, long enough that the round trip through the fake isn't racy.
    private var compressed: ConversationService.Timeouts {
        .init(callableIdleSeconds: 5, roundDeadlineSeconds: 0.5, telemetryDeadlineSeconds: 0.2)
    }

    // MARK: - The regression the outage exposed

    @Test func hungRequestEndsByTheDeadlineWithTheOfflineCopy() async throws {
        let service = makeService(behavior: .hang, timeouts: compressed)
        service.send("Replace the barbell bench press with something else")
        #expect(service.isThinking)

        try await waitUntil("the turn ends by the wall-clock deadline") { !service.isThinking }
        #expect(service.log.last?.role == .baseline)
        #expect(service.log.last?.text == ConversationService.offlineFailureMessage)
    }

    @Test func offlineFailureSurfacesTheOfflineCopy() async throws {
        let service = makeService(behavior: .fail(URLError(.notConnectedToInternet)), timeouts: compressed)
        service.send("Replace the barbell bench press with something else")

        try await waitUntil("the turn fails") { !service.isThinking }
        #expect(service.log.last?.text == ConversationService.offlineFailureMessage)
    }

    @Test func unrecognizedFailureKeepsTheGenericCopy() async throws {
        let service = makeService(behavior: .fail(NSError(domain: "SomethingElse", code: 7)), timeouts: compressed)
        service.send("Replace the barbell bench press with something else")

        try await waitUntil("the turn fails") { !service.isThinking }
        #expect(service.log.last?.text == ConversationService.genericFailureMessage)
    }

    /// Cancelling must not wait for any deadline: default (production) timeouts, and the turn still
    /// has to end almost immediately, silently, leaving the composer usable for the next message.
    @Test func cancelTurnStopsImmediatelySilentlyAndFreesTheComposer() async throws {
        let service = makeService(behavior: .hang)
        service.send("Replace the barbell bench press with something else")
        #expect(service.isThinking)
        #expect(service.canCancelTurn, "An in-flight turn is exactly what the stop button is for.")

        service.cancelTurn()
        try await waitUntil("the cancelled turn ends", timeout: 2) { !service.isThinking }
        #expect(!service.canCancelTurn)
        #expect(service.log.count == 1, "A cancelled turn with no committed mutation appends nothing.")
        #expect(service.log.last?.role == .you)

        // The guard is not wedged: the next send goes out again.
        service.send("Actually, make it a push-up")
        #expect(service.isThinking)
        service.cancelTurn()
        try await waitUntil("the second cancelled turn ends", timeout: 2) { !service.isThinking }
    }

    /// A cancel that lands after a tool already committed a mutation must not hide the change: the
    /// tool's own sentence becomes the reply, exactly as the failure path guarantees.
    @Test func cancelAfterACommittedMutationSurfacesTheToolResult() async throws {
        let toolUse: [[String: Any]] = [[
            "type": "tool_use", "id": "toolu_1", "name": "set_time_available",
            "input": ["minutes": 45],
        ]]
        let firstRound = try JSONSerialization.data(withJSONObject: ["content": toolUse])
        let service = makeService(behaviors: [.reply(firstRound), .hang])
        service.send("I only have 45 minutes today")

        try await waitUntil("the tool commits and the follow-up round hangs") { !service.toolActivity.isEmpty }
        service.cancelTurn()
        try await waitUntil("the cancelled turn ends", timeout: 2) { !service.isThinking }
        #expect(service.log.last?.role == .baseline)
        #expect(service.log.last?.text.contains("45 min today.") == true,
                "The committed mutation's own sentence must surface, not silence.")
    }

    /// Undo is a fast local mutation with no task to stop: it thinks, but it must never offer a
    /// stop affordance that would no-op.
    @Test func undoRunsWithoutOfferingACancellableTurn() async throws {
        let context = TrainingContextStore(defaults: UserDefaults(suiteName: "undo-ctx-\(UUID().uuidString)")!)
        let workouts = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "undo-wk-\(UUID().uuidString)")!)
        workouts.create(title: "Push Day", goal: nil)
        let token = try #require(workouts.mutationTarget(.plan)?.revisionToken)
        let toolUse: [[String: Any]] = [[
            "type": "tool_use", "id": "toolu_1", "name": "add_block",
            "input": ["name": "Main", "expected_revision_token": token.uuidString],
        ]]
        let service = makeService(
            behaviors: [
                .reply(try JSONSerialization.data(withJSONObject: ["content": toolUse])),
                .reply(try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "Added a Main block."]]])),
            ],
            tools: AgentTools(store: context, base: DecisionEngine.Inputs(), workouts: workouts),
            timeouts: compressed
        )
        service.send("Add a main block")
        try await waitUntil("the mutating turn finishes") { !service.isThinking }
        #expect(service.canUndoLatestWorkoutMutation)

        service.undoLatestWorkoutMutation()
        #expect(service.isThinking)
        #expect(!service.canCancelTurn, "Undo has no turn task; the composer must show the plain disabled arrow.")
        try await waitUntil("the undo finishes") { !service.isThinking }
    }

    /// The seam must not have cost the happy path: a well-formed reply still lands in the log.
    @Test func aWellFormedReplyStillRoundTripsThroughTheSeam() async throws {
        let content: [[String: Any]] = [["type": "text", "text": "Swapped it for a dumbbell press."]]
        let payload = try JSONSerialization.data(withJSONObject: ["content": content])
        let service = makeService(behavior: .reply(payload), timeouts: compressed)
        service.send("Replace the barbell bench press with something else")

        try await waitUntil("the reply lands") { !service.isThinking }
        #expect(service.log.last?.role == .baseline)
        #expect(service.log.last?.text == "Swapped it for a dumbbell press.")
    }

    // MARK: - Failed-turn retry

    /// The reported bug: a failed turn used to drop the athlete's message from the model transcript,
    /// so a later "try again" had no context. The message must survive as a retryable failure bubble.
    @Test func failedTurnPreservesTheMessageAsARetryableBubble() async throws {
        let service = makeService(behavior: .fail(NSError(domain: "SomethingElse", code: 7)), timeouts: compressed)
        service.send("Today I did a 3x8-minute tempo row")

        try await waitUntil("the turn fails") { !service.isThinking }
        #expect(service.log.count == 2)
        #expect(service.log.last?.role == .baseline)
        #expect(service.log.last?.kind == .failure)
        #expect(service.log.last?.retryText == "Today I did a 3x8-minute tempo row")
        #expect(service.log.last?.text == ConversationService.genericFailureMessage)
    }

    /// Tapping retry re-sends the exact failed message and, on success, leaves a clean thread: the
    /// reply lands, the failure bubble is gone, and the user's message shows exactly once (not twice).
    @Test func retryResendsTheExactMessageAndSucceeds() async throws {
        let reply: [[String: Any]] = [["type": "text", "text": "Nice - logged that tempo row."]]
        let good = try JSONSerialization.data(withJSONObject: ["content": reply])
        let service = makeService(behaviors: [.fail(NSError(domain: "SomethingElse", code: 7)), .reply(good)],
                                  timeouts: compressed)
        service.send("Today I did a 3x8-minute tempo row")
        try await waitUntil("the first turn fails") { !service.isThinking }
        #expect(service.log.last?.kind == .failure)

        service.retryFailedTurn()
        try await waitUntil("the retry lands") { !service.isThinking }

        #expect(service.log.last?.role == .baseline)
        #expect(service.log.last?.kind == .normal)
        #expect(service.log.last?.text == "Nice - logged that tempo row.")
        #expect(!service.log.contains { $0.kind == .failure }, "The stale failure bubble must be gone.")
        let userEchoes = service.log.filter { $0.role == .you && $0.text == "Today I did a 3x8-minute tempo row" }
        #expect(userEchoes.count == 1, "The retried message must appear once, not duplicated.")
    }

    /// The transcript the retry ships must be reconstructed to a single clean user turn — the whole
    /// point of the fix. Proven at the wire seam, not just the visible log.
    @Test func retryReconstructsASingleTurnTranscript() async throws {
        let reply: [[String: Any]] = [["type": "text", "text": "Logged."]]
        let good = try JSONSerialization.data(withJSONObject: ["content": reply])
        let (service, callable) = makeServiceAndCallable(
            behaviors: [.fail(NSError(domain: "SomethingElse", code: 7)), .reply(good)],
            timeouts: compressed
        )
        service.send("Today I did a 3x8-minute tempo row")
        try await waitUntil("the first turn fails") { !service.isThinking }
        service.retryFailedTurn()
        try await waitUntil("the retry lands") { !service.isThinking }

        let lastMessagesJSON = try #require(callable.requests.last?["messages"])
        let messages = try #require(
            try JSONSerialization.jsonObject(with: Data(lastMessagesJSON.utf8)) as? [[String: Any]]
        )
        #expect(messages.count == 1, "The retry must send exactly one user turn, not stack a second.")
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "Today I did a 3x8-minute tempo row")
    }

    /// No double-apply: when a tool already committed a mutation this turn, a later provider failure
    /// must surface the tool's own sentence as a plain reply — never a retry affordance that would ask
    /// the model to repeat the mutation it already made.
    @Test func retryIsNotOfferedWhenAToolAlreadyCommitted() async throws {
        let toolUse: [[String: Any]] = [[
            "type": "tool_use", "id": "toolu_1", "name": "set_time_available",
            "input": ["minutes": 45],
        ]]
        let firstRound = try JSONSerialization.data(withJSONObject: ["content": toolUse])
        let service = makeService(behaviors: [.reply(firstRound), .fail(NSError(domain: "SomethingElse", code: 7))],
                                  timeouts: compressed)
        service.send("I only have 45 minutes today")

        try await waitUntil("the tool commits and the follow-up round fails") { !service.isThinking }
        #expect(service.log.last?.role == .baseline)
        #expect(service.log.last?.kind == .normal, "A committed mutation is a plain reply, not a retryable failure.")
        #expect(service.log.last?.retryText == nil)
        #expect(service.log.last?.text.contains("45 min today.") == true)

        // And the guard holds: calling retry with no failure bubble is a no-op.
        let before = service.log.count
        service.retryFailedTurn()
        #expect(service.log.count == before)
        #expect(!service.isThinking)
    }

    /// A cancelled turn is the athlete's own choice — it stays silent and never offers a retry.
    @Test func cancelDoesNotLeaveARetryableFailure() async throws {
        let service = makeService(behavior: .hang)
        service.send("Replace the barbell bench press with something else")
        service.cancelTurn()
        try await waitUntil("the cancelled turn ends", timeout: 2) { !service.isThinking }
        #expect(!service.log.contains { $0.kind == .failure })
    }

    // MARK: - Error mapping

    @Test func connectivityShapedFailuresMapToTheOfflineCopy() {
        let offline = ConversationService.offlineFailureMessage
        let generic = ConversationService.genericFailureMessage

        #expect(ConversationService.failureMessage(for: URLError(.notConnectedToInternet)) == offline)
        #expect(ConversationService.failureMessage(for: URLError(.networkConnectionLost)) == offline)
        #expect(ConversationService.failureMessage(for: URLError(.cannotConnectToHost)) == offline)
        #expect(ConversationService.failureMessage(for: URLError(.timedOut)) == offline)
        #expect(ConversationService.failureMessage(for: ConversationError.roundDeadlineExceeded) == offline)
        #expect(ConversationService.failureMessage(
            for: NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.unavailable.rawValue)) == offline)
        #expect(ConversationService.failureMessage(
            for: NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.deadlineExceeded.rawValue)) == offline)
        // Wrapped transport errors are still recognized through the underlying chain.
        #expect(ConversationService.failureMessage(for: NSError(
            domain: FunctionsErrorDomain, code: FunctionsErrorCode.internal.rawValue,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError])) == offline)

        #expect(ConversationService.failureMessage(for: NSError(domain: "SomethingElse", code: 7)) == generic)
        #expect(ConversationService.failureMessage(for: ConversationError.badResponse) == generic)
        #expect(ConversationService.failureMessage(for: URLError(.badServerResponse)) == generic)
    }

    @Test func providerCapacityFailuresMapToTheOverloadedCopy() {
        let overloaded = ConversationService.overloadedFailureMessage
        let capacityDetails = ["reason": ConversationService.providerCapacityReason]

        // The server reports transient capacity as `unavailable` + a provider_capacity reason. The
        // reason wins over the connectivity shape, so the athlete never sees "check your signal".
        #expect(ConversationService.failureMessage(for: NSError(
            domain: FunctionsErrorDomain, code: FunctionsErrorCode.unavailable.rawValue,
            userInfo: [FunctionsErrorDetailsKey: capacityDetails])) == overloaded)
        // The reason is honored through a wrapped underlying error too.
        #expect(ConversationService.failureMessage(for: NSError(
            domain: FunctionsErrorDomain, code: FunctionsErrorCode.internal.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: FunctionsErrorDomain, code: FunctionsErrorCode.unavailable.rawValue,
                userInfo: [FunctionsErrorDetailsKey: capacityDetails])])) == overloaded)
        // An unrelated details reason is not treated as capacity.
        #expect(ConversationService.failureMessage(for: NSError(
            domain: FunctionsErrorDomain, code: FunctionsErrorCode.internal.rawValue,
            userInfo: [FunctionsErrorDetailsKey: ["reason": "something_else"]]))
            == ConversationService.genericFailureMessage)
    }

    // MARK: - Plumbing

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record(Comment(rawValue: "Timed out waiting for \(what)."))
    }
}
