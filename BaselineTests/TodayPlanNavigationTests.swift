import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Regression coverage for the "Today's Plan" card on the home screen. Tapping it used to push
/// `PlanView` — which owns its own `NavigationStack` — inside the Today stack's
/// `navigationDestination`. SwiftUI cannot host a nested stack in a pushed destination: the push
/// popped straight back, and a second tap corrupted the navigation controller and crashed.
/// The card now switches the shell to the Plan tab, so repeated taps must always land on the
/// Plan surface and never crash.
@MainActor
@Suite(.serialized)
struct TodayPlanNavigationTests {
    @Test func todaysPlanCardOpensThePlanSurfaceReliably() async throws {
        let screen = try MainTabShellScreen(tab: .today)
        defer { screen.tearDown() }
        try await screen.settle()

        // The card renders once the home model assembles from live evidence.
        try await screen.settleUntil { screen.element(labelled: "Today's plan") != nil }

        #expect(screen.activate(labelled: "Today's plan"))
        try await screen.settle()
        #expect(screen.element(labelled: "Calendar options") != nil,
                "First tap must land on the Plan surface and stay there")

        // Return to the home tab, then tap the card a second time — the historical crash.
        #expect(screen.activate(labelled: MainTab.today.title))
        try await screen.settleUntil { screen.element(labelled: "Today's plan") != nil }
        #expect(screen.activate(labelled: "Today's plan"))
        try await screen.settle()
        #expect(screen.element(labelled: "Calendar options") != nil,
                "Second tap must behave identically — no pop-back, no crash")
    }
}
