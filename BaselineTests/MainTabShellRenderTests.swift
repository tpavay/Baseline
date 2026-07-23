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

/// The signed-in shell hosted end to end: a real `UIWindow` around `MainTabView`. Reused by every
/// suite that exercises the shell through the shared `HostedScreen` harness.
@MainActor
final class MainTabShellScreen: HostedScreen {
    let window: UIWindow
    /// The live plan store the shell is driving, exposed so flow tests can read the plan back the way
    /// the athlete would open it tomorrow (e.g. asserting a discarded empty workout left the day empty).
    let plan: PlanStore
    private let container: ModelContainer

    init(tab: MainTab) throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self]
            + PlanSchema.models + SleepSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        plan = PlanStore(context: container.mainContext)
        let root = MainTabView(initialSelection: tab)
            .environment(AuthViewModel())
            .environment(AppSettings())
            .environment(BluetoothManager())
            .environment(HealthService())
            .environment(TrainingContextStore())
            .environment(OnboardingStore())
            .environment(WorkoutStore(units: AppSettings()))
            .environment(plan)
            .modelContainer(container)
            .preferredColorScheme(.dark)
        window = try Self.makeWindow(rootView: root)
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

    var floatingBarTop: CGFloat {
        MainTab.allCases
            .compactMap { element(labelled: $0.title)?.accessibilityFrame.minY }
            .min() ?? 0
    }
}
