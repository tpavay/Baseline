import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// The Plan calendar's per-day flows, driven end to end through the real shell: empty rows carry a
/// visible "Add workout" affordance plus a one-tap rest-day toggle, and the add sheet's "Start an
/// empty workout" opens live logging with the timer already counting.
@MainActor
@Suite(.serialized)
struct PlanDayRowFlowsTests {

    /// Empty rows lead with "Add workout" (the old copy said "Rest day" on every day with no way to
    /// tell it was tappable). The trailing moon marks a decided rest day in one tap, relabels the
    /// row, and the same tap takes it back.
    @Test func emptyRowsOfferAddWorkoutAndAOneTapRestToggle() async throws {
        let screen = try MainTabShellScreen(tab: .plan)
        defer { screen.tearDown() }
        try await screen.settle()

        try await screen.settleUntil { screen.element(labelled: "Add workout") != nil }
        #expect(screen.element(labelled: "Mark as rest day") != nil)
        #expect(screen.element(labelled: "Remove rest day") == nil)

        #expect(screen.activate(labelled: "Mark as rest day"))
        try await screen.settleUntil { screen.element(labelled: "Remove rest day") != nil }
        #expect(screen.element(labelled: "Rest day") != nil)
        try screen.capture("plan-page")

        #expect(screen.activate(labelled: "Remove rest day"))
        try await screen.settleUntil { screen.element(labelled: "Remove rest day") == nil }
    }

    /// "Start an empty workout" means "I want to train right now": the live logging screen must open
    /// immediately with the session started and the elapsed timer actually counting — the same
    /// behavior as a template's "Start Workout", never a template editor.
    @Test func startEmptyWorkoutOpensLiveLoggingWithTheTimerRunning() async throws {
        let screen = try MainTabShellScreen(tab: .plan)
        defer { screen.tearDown() }
        try await screen.settle()

        try await screen.settleUntil { screen.element(labelled: "Add workout") != nil }
        #expect(screen.activate(labelled: "Add workout"))
        try await screen.settleUntil { screen.element(labelled: "Start an empty workout") != nil }

        #expect(screen.activate(labelled: "Start an empty workout"))
        // The add sheet dismisses, the execution sheet presents, and the log timer starts. A live
        // timer moves off 00:00:00 within a couple of seconds; the static fallback never does.
        try await screen.settleUntil(timeout: 10) {
            guard let label = screen.element(labelled: "Workout duration")?.accessibilityLabel else {
                return false
            }
            return !label.hasSuffix("00:00:00")
        }
        #expect(screen.element(labelled: "Finish") != nil, "Live logging shows Finish, not Edit")
        try screen.capture("plan-empty-workout-live")
    }
}
