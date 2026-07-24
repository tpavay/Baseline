import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// The redesigned Plan tab, rendered for real: one bounded week at a time, a seven-day status strip,
/// and a filled-cell day grid. The week is pinned to a fixed Wednesday so a single rendered screen
/// always carries every day state - a performed day, a missed day, today with two sessions, a rest
/// day, a future planned day and undecided days - and the assertions never depend on which weekday
/// the suite happens to run.
@MainActor
@Suite(.serialized)
struct PlanWeeklyViewRenderTests {

    /// Wednesday, 22 July 2026 - mid-week, so the visible Mon–Sun always has past and future days.
    private static let fixedNow = Calendar.planWeek.date(
        from: DateComponents(year: 2026, month: 7, day: 22, hour: 12)
    )!

    // MARK: The week's states

    @Test func theWeekRendersEveryDayStateAndOffersLogsPlusOrdinaryTraining() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Full Body") != nil }

        // Performed day: green cell that opens the log the athlete actually recorded.
        #expect(screen.element(labelled: "View log") != nil)
        #expect(screen.hint(for: "Full Body") == "Opens the logged session")

        // A past day that was never performed is not a log - it stays a plain missed session.
        #expect(screen.element(labelled: "Push Day") != nil)
        #expect(screen.element(labelled: "MISSED") != nil)

        // Today's two sessions, a future planned session, the rest day and the undecided days.
        #expect(screen.element(labelled: "Zone 2 Recovery") != nil)
        #expect(screen.element(labelled: "Evening Accessories") != nil)
        #expect(screen.element(labelled: "Leg Day") != nil)
        #expect(screen.element(labelled: "Rest day") != nil)
        #expect(screen.element(labelled: "Remove rest day") != nil)
        #expect(screen.count(labelled: "Add workout") == 2, "Saturday and Sunday are the undecided days")

        // The word "planned" is gone from the grid: a plan state is not a subtitle, and a missing
        // duration is not a state.
        #expect(screen.labels.contains { $0.lowercased().contains("planned") } == false)

        try screen.capture("plan-week-all-states")
    }

    /// A second session is invited on today and on future days that already have one; a day that has
    /// already been and gone gets no invitation to add more to it.
    @Test func addingASecondSessionIsOfferedOnTodayAndFutureDaysOnly() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Zone 2 Recovery") != nil }

        #expect(screen.count(labelled: "Add another workout") == 2,
                "Today and Friday carry it; Monday's performed day and Tuesday's missed day do not")
        let addAnother = try #require(screen.element(labelled: "Add another workout"))
        let today = try #require(screen.element(labelled: "Zone 2 Recovery"))
        #expect(addAnother.accessibilityFrame.minY > today.accessibilityFrame.minY,
                "The + sits under the day's sessions")
    }

    /// The strip states each day at a glance: a green dot where training was performed, a moon on a
    /// rest day, and today's letter in accent with nothing above it.
    @Test func theWeekdayStripMarksCompletedRestAndToday() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Monday, workout completed") != nil }

        #expect(screen.element(labelled: "Thursday, rest day") != nil)
        #expect(screen.element(labelled: "Wednesday, today") != nil)
        #expect(screen.element(labelled: "Wednesday, workout completed") == nil,
                "Today is marked by its accent letter, never by a competing dot")
        #expect(screen.element(labelled: "Saturday") != nil)
    }

    // MARK: Week navigation

    @Test func theWeekPagerFlipsWeeksAndTodayComesBack() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "JUL 20 – 26") != nil }

        #expect(screen.activate(labelled: "Previous week"))
        try await screen.settleUntil { screen.element(labelled: "JUL 13 – 19") != nil }
        #expect(screen.element(labelled: "Zone 2 Recovery") == nil, "A different week shows different days")
        try screen.capture("plan-week-previous")

        #expect(screen.activate(labelled: "Next week"))
        try await screen.settleUntil { screen.element(labelled: "JUL 20 – 26") != nil }

        #expect(screen.activate(labelled: "Next week"))
        try await screen.settleUntil { screen.element(labelled: "JUL 27 – AUG 2") != nil }
        #expect(screen.element(labelled: "Wednesday, today") == nil, "Today is not in the week after this one")

        #expect(screen.activate(labelled: "Today"))
        try await screen.settleUntil { screen.element(labelled: "JUL 20 – 26") != nil }
        #expect(screen.element(labelled: "Wednesday, today") != nil)
    }

    // MARK: Regressions the redesign must not break

    /// Tapping the "+" of an undecided day reaches the same per-day add sheet as before, including
    /// its one-tap rest-day path - which is now the way an empty day becomes a rest day, since the
    /// row itself is a single "+" rather than a label plus a moon.
    @Test func theEmptyDayPlusOpensTheAddSheetAndItsRestDayPathStillWorks() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Add workout") != nil }
        let restDaysBefore = screen.count(labelled: "Rest day")

        #expect(screen.activate(labelled: "Add workout"))
        try await screen.settleUntil { screen.anyLabel(contains: "Make it a rest day") }
        #expect(screen.activateAnywhere(labelled: "Make it a rest day"))

        try await screen.settleUntil { screen.count(labelled: "Rest day") == restDaysBefore + 1 }
        #expect(screen.count(labelled: "Remove rest day") == restDaysBefore + 1)
    }

    /// The moon on a decided rest day is still its own undo.
    @Test func theRestDayMoonStillTogglesTheMarkerOff() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Remove rest day") != nil }

        #expect(screen.activate(labelled: "Remove rest day"))
        try await screen.settleUntil { screen.element(labelled: "Remove rest day") == nil }
        #expect(screen.element(labelled: "Rest day") == nil)
        #expect(screen.count(labelled: "Add workout") == 3, "Thursday joins Saturday and Sunday as undecided")
    }

    /// Tapping a performed row still opens the session that was logged.
    @Test func tappingAPerformedRowStillOpensItsLoggedSession() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "View log") != nil }

        #expect(screen.activate(labelled: "View log"))
        try await screen.settleUntil(timeout: 10) { screen.anyLabel(contains: "EXERCISES") }
        #expect(screen.isPresentingCover)
        #expect(screen.anyLabel(contains: "Full Body"))
    }

    /// The row's assistive-tech action still starts a session - the only start path the calendar
    /// publishes to VoiceOver, since its context menu is invisible to assistive tech.
    @Test func aSessionRowStillStartsItsWorkout() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Zone 2 Recovery") != nil }

        let row = try #require(screen.element(labelled: "Zone 2 Recovery"))
        #expect(screen.customActionNames(of: row).contains("Start workout"))
        #expect(screen.performCustomAction("Start workout", on: row))

        try await screen.settleUntil(timeout: 10) { screen.anyLabel(contains: "Start Workout") }
        #expect(screen.isPresentingCover)
    }

    /// Completing a session flips its row to the performed state: green, "View log", no handle - and
    /// its weekday letter gains the green dot.
    @Test func completingASessionTurnsItsRowIntoALogAndMarksTheStrip() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Leg Day") != nil }
        #expect(screen.element(labelled: "Friday, workout completed") == nil)
        let logsBefore = screen.count(labelledContaining: "View log")

        let legDay = try #require(screen.plan.week(containing: Self.fixedNow).days
            .flatMap(\.sessions).first { $0.workout.title == "Leg Day" })
        screen.plan.start(legDay.id)
        guard case .completed = screen.plan.complete(legDay.id, acknowledgingOpenWork: true) else {
            Issue.record("Completing the session should write a completed log")
            return
        }

        try await screen.settleUntil { screen.count(labelledContaining: "View log") == logsBefore + 1 }
        #expect(screen.element(labelled: "Friday, workout completed") != nil)
        #expect(screen.count(labelled: "Add another workout") == 2,
                "Adding a second session is a property of the day, not of what has been performed on it")
        try screen.capture("plan-week-after-completion")
    }

    /// Deleting from the row's swipe action still removes the workout from the plan.
    @Test func deletingFromARowStillRemovesTheWorkout() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Leg Day") != nil }

        let legDay = try #require(screen.plan.week(containing: Self.fixedNow).days
            .flatMap(\.sessions).first { $0.workout.title == "Leg Day" })
        #expect(screen.plan.delete(legDay.id, proposalID: nil).isApplied == false, "Deletion is confirmed first")
        guard case .confirmationRequired(_, _, let proposalID) = screen.plan.delete(legDay.id) else {
            Issue.record("Delete should ask for confirmation")
            return
        }
        #expect(screen.plan.delete(legDay.id, proposalID: proposalID).isApplied)

        try await screen.settleUntil { screen.element(labelled: "Leg Day") == nil }
        #expect(screen.count(labelled: "Add workout") == 3, "Friday is undecided again")
    }
}

// MARK: - Screen

/// `PlanView` hosted in a real window over a seeded in-memory plan, with the clock pinned to a fixed
/// Wednesday so every day state exists in the rendered week.
@MainActor
final class PlanWeekScreen: HostedScreen {
    let window: UIWindow
    let plan: PlanStore
    private let container: ModelContainer

    private static let cal = Calendar.planWeek

    init(now: Date = Calendar.planWeek.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 12))!) throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(for: Schema(models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        plan = PlanStore(context: container.mainContext)
        Self.seed(plan, now: now)

        let root = PlanView(now: { now })
            .environment(plan)
            .environment(AppSettings())
            .environment(BluetoothManager())
            .environment(OnboardingStore())
            .environment(WorkoutStore(units: AppSettings()))
            .modelContainer(container)
            .preferredColorScheme(.dark)
        window = try Self.makeWindow(rootView: root)
    }

    var isPresentingCover: Bool { window.rootViewController?.presentedViewController != nil }

    /// Mon: performed · Tue: missed · Wed (today): two sessions · Thu: rest · Fri: planned · Sat/Sun: empty.
    private static func seed(_ plan: PlanStore, now: Date) {
        let monday = cal.weekStart(for: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: monday)! }

        let performed = plan.newScheduledWorkout(on: day(0), workout: strength("Full Body"))
        plan.start(performed.id)
        _ = plan.complete(performed.id, acknowledgingOpenWork: true)

        _ = plan.newScheduledWorkout(on: day(1), workout: strength("Push Day"))
        _ = plan.newScheduledWorkout(on: day(2), workout: timed("Zone 2 Recovery"))
        _ = plan.newScheduledWorkout(on: day(2), workout: strength("Evening Accessories"))
        plan.setRestDay(day(3), true)
        _ = plan.newScheduledWorkout(on: day(4), workout: strength("Leg Day"))
    }

    private static func strength(_ title: String) -> Workout {
        var exercise = PlannedExercise(exerciseName: "Back Squat", definitionId: "back-squat")
        exercise.prescription.sets = [PlannedSet(reps: 5, load: 100), PlannedSet(reps: 5, load: 100)]
        return Workout(title: title, blocks: [WorkoutBlock(name: "", exercises: [exercise], isDefault: true)])
    }

    private static func timed(_ title: String) -> Workout {
        var exercise = PlannedExercise(exerciseName: "Row", definitionId: "row")
        exercise.prescription.sets = [PlannedSet(duration: 1_800, distance: 5_000)]
        return Workout(title: title, blocks: [WorkoutBlock(name: "", exercises: [exercise], isDefault: true)])
    }
}

// MARK: - Accessibility helpers

extension HostedScreen {
    var labels: [String] {
        AccessibilityElementWalker.elements(in: window).compactMap(\.accessibilityLabel)
    }

    func count(labelled text: String) -> Int {
        AccessibilityElementWalker.elements(in: window)
            .filter { $0.accessibilityLabel == text }
            .count
    }

    func count(labelledContaining text: String) -> Int {
        AccessibilityElementWalker.elements(in: window)
            .filter { $0.accessibilityLabel?.contains(text) ?? false }
            .count
    }

    func performCustomAction(_ name: String, on element: NSObject) -> Bool {
        guard let action = (element.accessibilityCustomActions ?? []).first(where: { $0.name == name }) else {
            return false
        }
        if let handler = action.actionHandler { return handler(action) }
        guard let target = action.target else { return false }
        _ = target.perform(action.selector, with: action)
        return true
    }

    func hint(for label: String) -> String? {
        AccessibilityElementWalker.elements(in: window)
            .first { $0.accessibilityLabel?.contains(label) ?? false }?
            .accessibilityHint
    }

    func customActionNames(of element: NSObject) -> [String] {
        (element.accessibilityCustomActions ?? []).map(\.name)
    }

    /// Elements in every visible window - a presented sheet lives in its own window.
    private var allElements: [NSObject] {
        let windows = (window.windowScene?.windows ?? [window]).filter { !$0.isHidden && $0.alpha > 0 }
        return windows.flatMap { AccessibilityElementWalker.elements(in: $0) }
    }

    func anyLabel(contains text: String) -> Bool {
        allElements.contains { $0.accessibilityLabel?.contains(text) ?? false }
    }

    func activateAnywhere(labelled text: String) -> Bool {
        allElements.first { $0.accessibilityLabel?.contains(text) ?? false }?.accessibilityActivate() ?? false
    }
}
