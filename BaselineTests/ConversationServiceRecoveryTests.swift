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

    private final class ScriptedCallable: ConversationRemoteCalling, @unchecked Sendable {
        enum Behavior: Sendable {
            case hang                      // never returns; the realistic stalled-connection shape
            case fail(any Error)
            case reply(Data)
        }

        var timeoutInterval: TimeInterval = 70
        private let behavior: Behavior

        init(_ behavior: Behavior) { self.behavior = behavior }

        func call(_ request: [String: String]) async throws -> Data {
            switch behavior {
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
        let defaults = UserDefaults(suiteName: "ConversationServiceRecoveryTests-\(UUID().uuidString)")!
        let tools = AgentTools(store: TrainingContextStore(defaults: defaults), base: DecisionEngine.Inputs())
        return ConversationService(
            tools: tools,
            makeCallable: { _ in ScriptedCallable(behavior) },
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

        service.cancelTurn()
        try await waitUntil("the cancelled turn ends", timeout: 2) { !service.isThinking }
        #expect(service.log.count == 1, "A cancelled turn appends no error bubble.")
        #expect(service.log.last?.role == .you)

        // The guard is not wedged: the next send goes out again.
        service.send("Actually, make it a push-up")
        #expect(service.isThinking)
        service.cancelTurn()
        try await waitUntil("the second cancelled turn ends", timeout: 2) { !service.isThinking }
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
