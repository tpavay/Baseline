import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// The Plan calendar's per-day flows, driven end to end through the real shell: an undecided day is a
/// single "+" that opens the per-day add sheet, that sheet's one-tap rest-day path decides the day,
/// the rest row's moon is its own undo, and "Start an empty workout" opens live logging with the
/// timer already counting.
@MainActor
@Suite(.serialized)
struct PlanDayRowFlowsTests {

    /// The weekly redesign made an undecided day a single accent "+" - the rest-day decision moved
    /// into the sheet it opens ("Make it a rest day"), and the moon on the decided row still takes it
    /// straight back, so declaring and un-declaring a rest day both stay one tap from the row.
    @Test func theEmptyDayPlusDecidesARestDayAndTheMoonUndoesIt() async throws {
        let screen = try MainTabShellScreen(tab: .plan)
        defer { screen.tearDown() }
        try await screen.settle()

        try await screen.settleUntil { screen.element(labelled: "Add workout") != nil }
        #expect(screen.element(labelled: "Remove rest day") == nil)

        #expect(screen.activate(labelled: "Add workout"))
        try await screen.settleUntil { screen.element(labelled: "Make it a rest day") != nil }
        #expect(screen.activate(labelled: "Make it a rest day"))

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
