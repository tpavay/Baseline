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

        init(_ behaviors: [Behavior]) { remaining = behaviors }

        private func nextBehavior() -> Behavior {
            lock.withLock {
                remaining.count > 1 ? remaining.removeFirst() : remaining[0]
            }
        }

        func call(_ request: [String: String]) async throws -> Data {
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
        let defaults = UserDefaults(suiteName: "ConversationServiceRecoveryTests-\(UUID().uuidString)")!
        let callable = ScriptedCallable(behaviors)
        return ConversationService(
            tools: tools ?? AgentTools(store: TrainingContextStore(defaults: defaults), base: DecisionEngine.Inputs()),
            makeCallable: { _ in callable },
            timeouts: timeouts
        )
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
