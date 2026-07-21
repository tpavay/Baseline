import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Drives the real `WorkoutImportView` in a scene-attached window and reads back the actual system
/// idle-timer flag. The claim worth guarding is end-to-end: while a photo import is working - which
/// can be a minute or more on a real device - the display must stay on, and every way out of that
/// wait must restore normal idle behavior. `UIApplication.shared.isIdleTimerDisabled` is the exact
/// flag iOS uses to hold the display, so asserting it is asserting the end-user effect.
///
/// Hosted in a window attached to the app's scene: sign-in gates a plain launch and an unattached
/// window renders blank. Mirrors `WorkoutKeepAwakeRenderTests`.
@MainActor
struct WorkoutImportKeepAwakeRenderTests {

    /// The long stage - sections being parsed server-side - holds the screen awake, and leaving the
    /// import screen releases it.
    @Test func workingImportKeepsScreenAwakeAndLeavingRestoresIt() async throws {
        UIApplication.shared.isIdleTimerDisabled = false

        let screen = try await WorkoutImportScreen(status: .processingSections(completed: 2, total: 5))
        #expect(
            UIApplication.shared.isIdleTimerDisabled,
            "Rendering a working import must disable the idle timer so the display stays on."
        )
        screen.capture("workout-import-progress-screen-awake")

        screen.tearDown()
        #expect(
            !UIApplication.shared.isIdleTimerDisabled,
            "Leaving the import must restore normal idle behavior."
        )
    }

    /// Failure is the exit path a leaked idle-timer disable would hide behind: the work has stopped
    /// but the screen would stay lit forever.
    @Test func failedImportLeavesIdleBehavior() async throws {
        UIApplication.shared.isIdleTimerDisabled = false

        let screen = try await WorkoutImportScreen(
            status: .failed(message: "Baseline could not parse that workout right now. Try again."),
            settleOn: "Import didn't finish"
        )
        defer { screen.tearDown() }

        #expect(!UIApplication.shared.isIdleTimerDisabled)
    }

    /// The picker, before anything is selected, has no reason to hold the display on.
    @Test func selectingLeavesIdleBehavior() async throws {
        UIApplication.shared.isIdleTimerDisabled = false

        let screen = try await WorkoutImportScreen(
            status: .selecting,
            settleOn: "Choose workout photos"
        )
        defer { screen.tearDown() }

        #expect(!UIApplication.shared.isIdleTimerDisabled)
    }

    /// A queued job says so on screen rather than implying a section is being parsed.
    @Test func queuedImportSaysItIsWaitingInLine() async throws {
        UIApplication.shared.isIdleTimerDisabled = false

        var job = WorkoutImportJob(stage: .processingSections, expectedPageCount: 1)
        job.serverProgress = WorkoutImportServerProgress(
            serverJobID: "server-1",
            status: WorkoutImportRemoteJobState.queued.rawValue,
            completedSections: 0,
            totalSections: 4
        )
        let screen = try await WorkoutImportScreen(
            status: .processingSections(completed: 0, total: 4),
            job: job,
            settleOn: "Waiting for a parser slot"
        )
        defer { screen.tearDown() }

        #expect(UIApplication.shared.isIdleTimerDisabled, "A queued import is still an active wait.")
        screen.capture("workout-import-queued")
    }
}

// MARK: - Harness

/// The real `WorkoutImportView` staged into a given status through its debug initializer, hosted in
/// a real scene-attached window.
@MainActor
private final class WorkoutImportScreen {
    private let window: UIWindow
    private let defaults: UserDefaults
    private let suiteName: String
    private let container: ModelContainer

    init(
        status: WorkoutImportStatus,
        job: WorkoutImportJob? = nil,
        settleOn marker: String = "Creating your workout"
    ) async throws {
        suiteName = "WorkoutImportKeepAwakeRenderTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let root = WorkoutImportView(
            debugSession: ImportSession(status: status),
            debugJob: job
        )
            .environment(WorkoutStore(defaults: defaults))
            .environment(PlanStore(context: container.mainContext))
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()

        try await settle(until: { [weak window] in
            guard let window else { return false }
            return WorkoutImportScreen.elements(in: window).contains {
                $0.accessibilityLabel?.contains(marker) == true
            }
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
        let url = WorkoutImportScreen.evidenceDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SCREENSHOT \(url.path)")
    }

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workout-import-keep-awake")
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
        Issue.record("WorkoutImportView never finished rendering.")
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
