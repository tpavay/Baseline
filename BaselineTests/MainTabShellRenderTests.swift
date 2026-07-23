import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Renders the real signed-in shell — `MainTabView`, not an extracted tab — so the floating bar's
/// relationship to the system tab bar and each tab's bottom content is exercised where it actually
/// runs. The system bar must never be visible beneath the floating bar, and every tab must publish
/// the floating bar's controls in the accessibility tree.
@MainActor
@Suite(.serialized)
struct MainTabShellRenderTests {
    /// The shell offers exactly Weekly / Plan / Profile. Train is gone: ad-hoc training starts from
    /// the Plan tab's per-day add sheet, and the Weekly label names what the home screen shows.
    @Test func theShellOffersExactlyWeeklyPlanProfile() {
        #expect(MainTab.allCases == [.today, .plan, .profile])
        #expect(MainTab.allCases.map(\.title) == ["Weekly", "Plan", "Profile"])
    }

    @Test(arguments: MainTab.allCases)
    func theShellShowsOnlyTheFloatingTabBar(_ tab: MainTab) async throws {
        let screen = try MainTabShellScreen(tab: tab)
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.visibleSystemTabBars.isEmpty)
        for title in MainTab.allCases.map(\.title) {
            #expect(screen.element(labelled: title) != nil)
        }
        if tab == .plan {
            // The calendar's leading toolbar menu - "Ask Baseline" lives inside it, so the menu's
            // own label is the Plan surface's stable accessibility marker.
            #expect(screen.element(labelled: "Calendar options") != nil)
        }
        try screen.capture("shell-\(tab.title.lowercased())")
    }

    @Test func theFloatingBarDrivesRealTabSelection() async throws {
        let screen = try MainTabShellScreen(tab: .today)
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.element(labelled: "Calendar options") == nil)
        #expect(screen.activate(labelled: "Plan"))
        try await screen.settle()

        #expect(screen.element(labelled: "Calendar options") != nil)
        #expect(screen.visibleSystemTabBars.isEmpty)
    }

    /// Heart Rate Zones lives inside Profile's modal settings sheet since the Profile redesign, so
    /// the shell must reach it through Settings and the zones surface must render fully there.
    @Test func profileSettingsReachesHeartRateZones() async throws {
        let screen = try MainTabShellScreen(tab: .profile)
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.activate(labelled: "Settings"))
        try await screen.settle()

        #expect(screen.activate(labelled: "Heart Rate Zones"))
        try await screen.settle()

        #expect(screen.element(labelled: "MAX HR") != nil)
        #expect(screen.visibleSystemTabBars.isEmpty)
        try screen.capture("shell-profile-zones")
    }
}

/// Shared app-hosted shell harness: a real `UIWindow` around `MainTabView`, with accessibility
/// lookup/activation, screenshot capture into `evidence/`, and run-loop settling. Reused by every
/// suite that exercises the signed-in shell end to end.
@MainActor
final class MainTabShellScreen {
    private let window: UIWindow
    private let container: ModelContainer

    init(tab: MainTab) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self]
            + PlanSchema.models + SleepSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let root = MainTabView(initialSelection: tab)
            .environment(AuthViewModel())
            .environment(AppSettings())
            .environment(BluetoothManager())
            .environment(HealthService())
            .environment(TrainingContextStore())
            .environment(OnboardingStore())
            .environment(WorkoutStore(units: AppSettings()))
            .environment(PlanStore(context: container.mainContext))
            .modelContainer(container)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    var visibleSystemTabBars: [UITabBar] {
        var bars: [UITabBar] = []
        func walk(_ view: UIView) {
            if let bar = view as? UITabBar,
               !bar.isHidden,
               bar.alpha > 0,
               bar.frame.intersects(window.bounds.insetBy(dx: 0, dy: 1)) {
                bars.append(bar)
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return bars
    }

    func element(labelled text: String) -> NSObject? {
        AccessibilityElementWalker.elements(in: window)
            .first { $0.accessibilityLabel?.contains(text) ?? false }
    }

    func activate(labelled text: String) -> Bool {
        element(labelled: text)?.accessibilityActivate() ?? false
    }

    var floatingBarTop: CGFloat {
        MainTab.allCases
            .compactMap { element(labelled: $0.title)?.accessibilityFrame.minY }
            .min() ?? 0
    }

    func capture(_ name: String) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        let url = AccessibilityElementWalker.evidenceDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        print("SCREENSHOT \(url.path)")
    }

    func settle() async throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            spin(0.05)
            await Task.yield()
        }
        spin(0.1)
    }

    /// Settle until `condition` holds, failing the test if it never does. For content that appears
    /// asynchronously (e.g. the Today home model assembling from live evidence).
    func settleUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            spin(0.05)
            await Task.yield()
        }
        try #require(condition(), "Condition not met within \(timeout)s")
    }

    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

}
