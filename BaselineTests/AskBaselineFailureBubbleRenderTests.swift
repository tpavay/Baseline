import Foundation
import Network
import SwiftData
import SwiftUI
import Testing
import UIKit
@preconcurrency import FirebaseFunctions
@testable import Baseline

/// A failed coach turn must keep the athlete's message and offer a real retry, not a dead end. These
/// present the real `AskBaselineSheet` the way production does, point the app's own Functions instance
/// at a local socket that answers every request with a transient provider-capacity error, and assert
/// the chat renders a tappable "Try again" affordance over the "coach is busy" copy.
///
/// When `TEST_RUNNER_FAILURE_BUBBLE_SCREENSHOT` names a path, the test also captures the rendered
/// sheet to that PNG - the evidence the retry affordance ships. Hosted in a scene-attached window
/// because sign-in gates a plain launch; interaction goes through the accessibility layer.
@MainActor
@Suite(.serialized)
struct AskBaselineFailureBubbleRenderTests {

    @Test func aFailedTurnShowsTheTryAgainAffordance() async throws {
        let server = try CapacityErrorServer()
        defer { server.stop() }
        let screen = try await ChatFailureScreen(failingOnPort: server.port)
        defer { screen.tearDown() }

        try await screen.send("Today I did a 10-minute bike warm-up, then a 3x8-minute tempo row")
        // Wait for the turn to fully settle: the retry button renders the instant the failure bubble
        // appears, but stays disabled until `isThinking` clears, so poll for the tappable state.
        try await screen.settle(
            until: {
                guard let retry = screen.element(labeled: "Try again") else { return false }
                return !retry.accessibilityTraits.contains(.notEnabled)
            },
            orRecord: "The failed turn never rendered an enabled Try again button."
        )

        // The message the coach never received is still on screen, and the copy invites a retry.
        #expect(screen.element(labeled: ConversationService.overloadedFailureMessage) != nil,
                "The transient-capacity failure should show the 'coach is busy, message saved' copy.")
        let retry = try #require(screen.element(labeled: "Try again"), "No Try again button on screen.")
        #expect(!retry.accessibilityTraits.contains(.notEnabled), "Retry must be tappable once the turn ends.")

        screen.captureScreenshotIfRequested()
    }
}

// MARK: - A provider-capacity error stand-in

/// Accepts the callable's request and answers with an HTTP 503 whose body carries the callable
/// error shape Firebase decodes, including the `provider_capacity` reason the app keys its transient
/// copy off. Only the app's own traffic is affected. State is confined to `queue`; `port` is written
/// once before init returns, the invariant behind the @unchecked Sendable.
private final class CapacityErrorServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CapacityErrorServer")
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async { self.adopt(connection) }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let boundPort = listener.port?.rawValue else {
            throw NSError(domain: "CapacityErrorServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        port = boundPort
    }

    private func adopt(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        readRequestThenFail(connection)
    }

    /// Drain the request head, then answer once with the capacity error and close.
    private func readRequestThenFail(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, done, error in
            guard let self, error == nil, !done else { return }
            self.queue.async { self.respond(connection) }
        }
    }

    private func respond(_ connection: NWConnection) {
        let body = #"{"error":{"status":"UNAVAILABLE","message":"The coach is busy right now.","details":{"reason":"provider_capacity"}}}"#
        let bytes = Array(body.utf8)
        let head = """
        HTTP/1.1 503 Service Unavailable\r
        Content-Type: application/json\r
        Content-Length: \(bytes.count)\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + Data(bytes), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func stop() {
        queue.async {
            self.connections.forEach { $0.cancel() }
            self.listener.cancel()
        }
    }
}

// MARK: - Harness

/// The real chat surface, presented as a sheet, wired to a failing socket. Modeled on
/// `ChatSheetScreen` in AskBaselineEscapeHatchRenderTests.
@MainActor
private final class ChatFailureScreen {
    private let window: UIWindow
    private let defaults: UserDefaults
    private let suiteName = "AskBaselineFailureBubbleRenderTests"
    private let container: ModelContainer

    private struct SheetHost: View {
        @State private var showChat = true
        let content: AnyView

        var body: some View {
            Color.black.ignoresSafeArea()
                .sheet(isPresented: $showChat) { content }
        }
    }

    init(failingOnPort port: UInt16) async throws {
        Functions.functions().useEmulator(withHost: "127.0.0.1", port: Int(port))

        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models + SleepSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let sheet = AskBaselineSheet()
            .environment(TrainingContextStore(defaults: defaults))
            .environment(HealthService(defaults: defaults))
            .environment(OnboardingStore(defaults: defaults))
            .environment(WorkoutStore(units: StubUnitSystem(), defaults: defaults))
            .environment(PlanStore(context: container.mainContext))
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SheetHost(content: AnyView(sheet)))
        window.makeKeyAndVisible()

        try await settle(until: { [weak self] in self?.element(labeled: "Send message") != nil },
                         orRecord: "The chat sheet never finished opening.")
    }

    func tearDown() {
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Reading the screen

    func element(labeled label: String) -> NSObject? {
        Self.elements(in: window).first { $0.accessibilityLabel == label }
    }

    /// Writes the rendered sheet to the PNG named by `FAILURE_BUBBLE_SCREENSHOT`, if set. `xcodebuild`
    /// forwards `TEST_RUNNER_`-prefixed variables to the runner (some toolchains strip the prefix),
    /// so both spellings are honored. A no-op otherwise, so the assertion half still runs in CI.
    func captureScreenshotIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FAILURE_BUBBLE_SCREENSHOT"] ?? env["TEST_RUNNER_FAILURE_BUBBLE_SCREENSHOT"],
              !path.isEmpty else { return }
        let target = window.rootViewController?.presentedViewController?.view ?? window
        window.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: target.bounds)
        let image = renderer.image { _ in
            target.drawHierarchy(in: target.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else {
            Issue.record("Could not encode the failure-bubble screenshot.")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            Issue.record("Could not write the failure-bubble screenshot: \(error)")
        }
    }

    // MARK: Driving the screen

    func send(_ text: String) async throws {
        let field = try #require(textInput, "No composer text field on screen.")
        field.becomeFirstResponder()
        if let range = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument) {
            field.replace(range, withText: text)
        }
        try await settle(until: { [weak self] in
            (self?.element(labeled: "Send message")?.accessibilityTraits.contains(.notEnabled)) == false
        }, orRecord: "The send button never enabled for the typed draft.")
        let send = try #require(element(labeled: "Send message"))
        #expect(send.accessibilityActivate())
    }

    // MARK: Plumbing

    private var textInput: (UIView & UITextInput)? {
        Self.allViews(in: window).lazy.compactMap { $0 as? (UIView & UITextInput) }.first
    }

    func settle(
        until condition: @MainActor () -> Bool,
        timeout: TimeInterval = 20,
        orRecord message: String
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record(Comment(rawValue: message))
    }

    private static func allViews(in root: UIView) -> [UIView] {
        root.subviews.reduce(into: [root]) { $0 += allViews(in: $1) }
    }

    private static func elements(in root: UIView) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()

        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                if view.isAccessibilityElement { out.append(view) }
                (view.accessibilityElements as? [NSObject])?.forEach(walk)
                view.subviews.forEach(walk)
            } else {
                out.append(object)
                let count = object.accessibilityElementCount()
                guard count != NSNotFound, count > 0 else { return }
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { walk(child) }
                }
            }
        }
        walk(root)
        return out
    }
}
