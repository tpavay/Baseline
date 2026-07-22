import Foundation
import Network
import SwiftData
import SwiftUI
import Testing
import UIKit
@preconcurrency import FirebaseFunctions
@testable import Baseline

/// The chat sheet must never trap the athlete behind an in-flight request. A real user once sent a
/// message on stalled gym wifi and found the spinner infinite, Done dead, and swipe-dismiss blocked.
/// These present the real `AskBaselineSheet` the way production does (`.sheet { AskBaselineSheet() }`),
/// point the app's own Functions instance at a local socket that accepts and never answers, and
/// assert every exit stays open while the request hangs: Done enabled and dismissing, swipe not
/// blocked, and a stop button in the composer.
///
/// Hosted in a scene-attached window because sign-in gates a plain launch; interaction goes through
/// the accessibility layer, pressing the same controls VoiceOver would.
@MainActor
@Suite(.serialized)
struct AskBaselineEscapeHatchRenderTests {

    @Test func everyExitStaysOpenWhileARequestHangs() async throws {
        let server = try SilentServer()
        defer { server.stop() }
        let screen = try await ChatSheetScreen(stalledOnPort: server.port)
        defer { screen.tearDown() }

        try await screen.send("Replace the barbell bench press with something else")
        try await screen.settle(until: { screen.element(labeled: "Stop") != nil },
                                orRecord: "The composer never showed the stop button for the in-flight turn.")

        // The sheet is thinking against a dead network. Every exit must still work.
        let done = try #require(screen.element(labeled: "Done"), "No Done button on screen.")
        #expect(!done.accessibilityTraits.contains(.notEnabled), "Done must stay enabled while thinking.")
        #expect(!screen.swipeDismissBlocked, "interactiveDismissDisabled must not gate an in-flight turn.")

        #expect(done.accessibilityActivate())
        try await screen.settle(until: { screen.sheetController == nil },
                                orRecord: "Done did not dismiss the sheet while the request was in flight.")
    }

    @Test func theStopButtonAbandonsTheTurnSilently() async throws {
        let server = try SilentServer()
        defer { server.stop() }
        let screen = try await ChatSheetScreen(stalledOnPort: server.port)
        defer { screen.tearDown() }

        try await screen.send("Replace the barbell bench press with something else")
        try await screen.settle(until: { screen.element(labeled: "Stop") != nil },
                                orRecord: "The composer never showed the stop button for the in-flight turn.")

        let stop = try #require(screen.element(labeled: "Stop"))
        #expect(stop.accessibilityActivate())
        try await screen.settle(until: { screen.element(labeled: "Send message") != nil },
                                orRecord: "Stopping the turn never restored the send button.")
        #expect(screen.element(labeled: ConversationService.offlineFailureMessage) == nil,
                "A stopped turn is the athlete's choice; no error bubble belongs in the log.")
        #expect(screen.element(labeled: ConversationService.genericFailureMessage) == nil)
    }
}

// MARK: - A dead-network stand-in

/// Accepts TCP connections and never sends a byte: the app's request opens, uploads, and then stalls
/// exactly like a dead backhaul. Only the app's own traffic is affected. State is confined to
/// `queue`; `port` is written once before init returns, which is the invariant behind the
/// @unchecked Sendable.
private final class SilentServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SilentServer")
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.adopt(connection) }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let boundPort = listener.port?.rawValue else {
            throw NSError(domain: "SilentServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        port = boundPort
    }

    private func adopt(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        drain(connection)
    }

    /// Keep reading (and discarding) so the client's request upload completes normally.
    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, done, error in
            guard error == nil, !done else { return }
            self?.queue.async { self?.drain(connection) }
        }
    }

    func stop() {
        queue.async {
            self.connections.forEach { $0.cancel() }
            self.listener.cancel()
        }
    }
}

// MARK: - Harness

/// The real chat surface, presented as a sheet so `interactiveDismissDisabled` semantics are live
/// (`isModalInPresentation` on the presented controller). Modeled on `AskBaselineScreen` in
/// ConversationSuggestionChipsRenderTests; long waits suspend the main actor instead of spinning
/// the run loop, because a sustained synchronous spin reads as an unresponsive test runner and the
/// simulator host force-quits the app.
@MainActor
private final class ChatSheetScreen {
    private let window: UIWindow
    private let defaults: UserDefaults
    private let suiteName = "AskBaselineEscapeHatchRenderTests"
    private let container: ModelContainer

    private struct SheetHost: View {
        @State private var showChat = true
        let content: AnyView

        var body: some View {
            Color.black.ignoresSafeArea()
                .sheet(isPresented: $showChat) { content }
        }
    }

    init(stalledOnPort port: UInt16) async throws {
        // Points the shared default Functions instance at the silent socket, exactly what the
        // sheet's own ConversationService uses. This sticks for the process; fine while no other
        // suite calls a Cloud Function for real, and app-hosted suites must not anyway.
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

    /// The presented chat sheet's controller — the object whose `isModalInPresentation` SwiftUI
    /// drives from `interactiveDismissDisabled`, i.e. the mechanism that would block swipe-dismiss.
    var sheetController: UIViewController? {
        window.rootViewController?.presentedViewController
    }

    var swipeDismissBlocked: Bool { sheetController?.isModalInPresentation == true }

    func element(labeled label: String) -> NSObject? {
        Self.elements(in: window).first { $0.accessibilityLabel == label }
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

    /// Every accessibility element on screen: SwiftUI publishes controls both as views that mark
    /// themselves accessible and as synthesized elements hanging off a container, so both paths are
    /// walked.
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
