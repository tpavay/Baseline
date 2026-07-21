import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// `UIApplication.shared.isIdleTimerDisabled` is process-global, and a suite touches it whether or
/// not it asserts on it: merely hosting `WorkoutView` in logging mode, `ReadingView`,
/// `CameraReadingView`, or a working `WorkoutImportView` makes that view's `syncKeepAwake` write the
/// flag on appear and clear it on teardown. So the rule is not "suites that assert the idle timer" -
/// it is **every suite that renders a keep-awake surface must be nested here**, because a peer
/// running in parallel would otherwise observe the other's writes. `.serialized` applies to the whole
/// subtree, so nesting is all a member suite has to do.
///
/// Current members: `WorkoutKeepAwakeRenderTests`, `WorkoutImportKeepAwakeRenderTests`,
/// `WorkoutSessionEditingE2ERenderTests`.
@Suite(.serialized)
struct IdleTimerRenderTests {}

extension IdleTimerRenderTests {
    /// Drives the real `WorkoutView` the way an athlete does - view a template, start it to begin
    /// logging, then finish - and reads back the actual system idle-timer flag each time. The claim
    /// worth guarding is end-to-end: rendering the live-log surface must keep the iPhone screen awake
    /// (so a glance at live heart rate never dims or locks), while viewing a template or the completed
    /// summary leaves normal idle behavior. `UIApplication.shared.isIdleTimerDisabled` is the exact
    /// flag iOS uses to hold the display on, so asserting it is asserting the end-user effect, not a
    /// stand-in.
    ///
    /// Hosted in a window attached to the app's scene: sign-in gates a plain launch and an unattached
    /// window renders blank. The log case also writes a PNG of the surface that stays lit.
    @MainActor
    struct WorkoutKeepAwakeRenderTests {

        /// Rendering an in-progress log holds the screen awake; leaving it restores normal idle behavior.
        @Test func loggingKeepsScreenAwakeAndLeavingRestoresIt() async throws {
            UIApplication.shared.isIdleTimerDisabled = false

            let screen = try await WorkoutScreen(stage: .logging)
            #expect(
                UIApplication.shared.isIdleTimerDisabled,
                "Rendering the active log must disable the idle timer so the display stays on."
            )
            screen.capture("workout-logging-screen-awake")

            screen.tearDown()
            #expect(
                !UIApplication.shared.isIdleTimerDisabled,
                "Leaving the workout must restore normal idle behavior."
            )
        }

        /// Viewing an un-started template keeps normal idle behavior - no reason to hold the screen on.
        @Test func viewingTemplateLeavesIdleBehavior() async throws {
            UIApplication.shared.isIdleTimerDisabled = false

            let screen = try await WorkoutScreen(stage: .viewingTemplate)
            defer { screen.tearDown() }

            #expect(!UIApplication.shared.isIdleTimerDisabled)
        }

        /// Reviewing the completed summary keeps normal idle behavior.
        @Test func completedSummaryLeavesIdleBehavior() async throws {
            UIApplication.shared.isIdleTimerDisabled = false

            let screen = try await WorkoutScreen(stage: .completed)
            defer { screen.tearDown() }

            #expect(!UIApplication.shared.isIdleTimerDisabled)
        }
    }
}

// MARK: - Harness

/// The assembled `WorkoutView` in a real, scene-attached window, staged into one of the three
/// presentation modes by driving the same `WorkoutStore` the app uses.
@MainActor
private final class WorkoutScreen {
    enum Stage { case viewingTemplate, logging, completed }

    private let window: UIWindow
    private let defaults: UserDefaults
    private let suiteName: String
    private let container: ModelContainer

    init(stage: Stage) async throws {
        suiteName = "WorkoutKeepAwakeRenderTests.\(stage)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        // Stage the store into the mode we want to render. Standalone (no plan sink) keeps it simple.
        let store = WorkoutStore(defaults: defaults)
        store.create(title: "KeepAwake Test", goal: "Verify screen stays awake while logging")
        switch stage {
        case .viewingTemplate:
            break
        case .logging:
            store.startWorkout()
        case .completed:
            store.startWorkout()
            store.completeWorkout(awaitingReconciliationDecision: false)
        }

        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let root = WorkoutView()
            .environment(store)
            .environment(PlanStore(context: container.mainContext))
            .environment(BluetoothManager())
            .environment(OnboardingStore(defaults: defaults))
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()

        // The workout title is the signal the screen has laid out and `onAppear` has run.
        try await settle(until: { [weak window] in
            guard let window else { return false }
            return WorkoutScreen.elements(in: window).contains { $0.accessibilityLabel == "KeepAwake Test" }
        })
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        // Let the removed view's onDisappear run so the idle-timer restore is exercised.
        spin(0.3)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func capture(_ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return }
        let url = WorkoutScreen.evidenceDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SCREENSHOT \(url.path)")
    }

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workout-keep-awake")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    private func settle(until condition: () -> Bool, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            spin(0.1)
            await Task.yield()
            if condition() { spin(0.3); return }
        }
        Issue.record("WorkoutView never finished rendering.")
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
