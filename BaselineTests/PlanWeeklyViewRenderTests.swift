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

    // MARK: Drag reorder evidence

    @Test func aLongPressLiftRaisesTheSessionWithAnAccentOutline() async throws {
        let screen = try PlanWeekScreen(dragSourceTitle: "Zone 2 Recovery")
        defer { screen.tearDown() }

        try await screen.settleUntil { screen.element(labelled: "Dragging Zone 2 Recovery") != nil }
        try screen.capture("plan-drag-lift")
    }

    @Test func draggingToAnOccupiedFutureDayOpensTheExactInsertionGap() async throws {
        let screen = try PlanWeekScreen(
            dragSourceTitle: "Zone 2 Recovery",
            dragDestinationDayOffset: 4,
            dragDestinationIndex: 1
        )
        defer { screen.tearDown() }

        try await screen.settleUntil {
            screen.element(labelled: "Dragging Zone 2 Recovery") != nil
                && screen.element(labelled: "Drop position") != nil
                && screen.element(labelled: "Past day - can't drop here") != nil
        }
        try screen.capture("plan-drag-mid")
    }

    @Test func aCompletedDropPersistsAsTheSecondSessionOnTheFutureDay() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Zone 2 Recovery") != nil }

        let monday = Calendar.planWeek.weekStart(for: Self.fixedNow)
        let friday = try #require(Calendar.planWeek.date(byAdding: .day, value: 4, to: monday))
        let moved = try #require(
            screen.plan.week(containing: Self.fixedNow).days
                .flatMap(\.sessions)
                .first { $0.workout.title == "Zone 2 Recovery" }
        )
        #expect(screen.plan.reposition(
            moved.id,
            toDate: friday,
            at: 1,
            notBefore: Self.fixedNow
        ).isApplied)

        try await screen.settleUntil {
            guard let legDay = screen.element(labelled: "Leg Day"),
                  let movedRow = screen.element(labelled: "Zone 2 Recovery") else {
                return false
            }
            return movedRow.accessibilityFrame.minY > legDay.accessibilityFrame.minY
        }
        try screen.capture("plan-drag-drop-complete")
    }

    @Test func assistiveReorderActionsMoveAWorkoutWithinItsDay() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Zone 2 Recovery") != nil }

        let recovery = try #require(screen.element(labelled: "Zone 2 Recovery"))
        #expect(screen.customActionNames(of: recovery).contains("Move earlier"))
        #expect(screen.customActionNames(of: recovery).contains("Move later"))
        #expect(screen.performCustomAction("Move later", on: recovery))

        try await screen.settleUntil {
            guard let moved = screen.element(labelled: "Zone 2 Recovery"),
                  let accessories = screen.element(labelled: "Evening Accessories") else {
                return false
            }
            return moved.accessibilityFrame.minY > accessories.accessibilityFrame.minY
        }
        let calendar = Calendar.planWeek
        let ordered = screen.plan.week(containing: Self.fixedNow).days
            .first(where: { calendar.isDate($0.date, inSameDayAs: Self.fixedNow) })?
            .sessions
            .map(\.workout.title)
        #expect(ordered == ["Evening Accessories", "Zone 2 Recovery"])
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

    // MARK: Crossing midnight on a resident process

    /// Leaving the tab open across midnight must not keep yesterday marked as today: the day-derived
    /// state is rebuilt from the live clock, while the week the athlete was looking at stays put.
    @Test func crossingMidnightMovesTheTodayMarkerWithoutPagingTheVisibleWeek() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "Wednesday, today") != nil }

        screen.advanceClock(byDays: 1)

        try await screen.settleUntil { screen.element(labelled: "Thursday, today") != nil }
        #expect(screen.element(labelled: "Wednesday, today") == nil)
        #expect(screen.element(labelled: "JUL 20 – 26") != nil, "The same week is still on screen")
    }

    /// An app left resident on the current week and foregrounded the next week must land on the real
    /// current week - not strand the athlete on last week's grid with no day marked today - and
    /// `PlanStore.week`, which is what "this week" means to the agent, has to follow the clock too.
    @Test func crossingIntoANewWeekCarriesForwardAWeekTheAthleteNeverPagedAwayFrom() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "JUL 20 – 26") != nil }
        let cal = Calendar.planWeek
        #expect(cal.isDate(screen.plan.week.startDate, inSameDayAs: cal.weekStart(for: Self.fixedNow)))

        screen.advanceClock(byDays: 7)

        try await screen.settleUntil { screen.element(labelled: "JUL 27 – AUG 2") != nil }
        #expect(screen.element(labelled: "Wednesday, today") != nil, "Today is marked again")
        #expect(screen.count(labelled: "Add workout") == 7, "The whole new week is undecided")
        let nextWeekStart = cal.weekStart(for: cal.date(byAdding: .day, value: 7, to: Self.fixedNow)!)
        #expect(cal.isDate(screen.plan.week.startDate, inSameDayAs: nextWeekStart),
                "The agent's \"this week\" follows the clock")
    }

    /// A week the athlete deliberately paged to is theirs: crossing a week boundary re-anchors the
    /// store behind it but never moves the grid out from under them.
    @Test func crossingIntoANewWeekLeavesADeliberatelyPagedWeekAlone() async throws {
        let screen = try PlanWeekScreen()
        defer { screen.tearDown() }
        try await screen.settleUntil { screen.element(labelled: "JUL 20 – 26") != nil }
        let cal = Calendar.planWeek

        #expect(screen.activate(labelled: "Previous week"))
        try await screen.settleUntil { screen.element(labelled: "JUL 13 – 19") != nil }
        #expect(cal.isDate(screen.plan.week.startDate, inSameDayAs: cal.weekStart(for: Self.fixedNow)),
                "Paging never moves the agent's week")

        screen.advanceClock(byDays: 7)
        try await screen.settle()

        #expect(screen.element(labelled: "JUL 13 – 19") != nil, "The paged week is still on screen")
        let nextWeekStart = cal.weekStart(for: cal.date(byAdding: .day, value: 7, to: Self.fixedNow)!)
        #expect(cal.isDate(screen.plan.week.startDate, inSameDayAs: nextWeekStart),
                "The agent's \"this week\" still follows the clock")
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
    private let clock: PlanTestClock

    private static let cal = Calendar.planWeek

    init(
        now: Date = Calendar.planWeek.date(
            from: DateComponents(year: 2026, month: 7, day: 22, hour: 12)
        )!,
        dragSourceTitle: String? = nil,
        dragDestinationDayOffset: Int? = nil,
        dragDestinationIndex: Int = 0
    ) throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(for: Schema(models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let planStore = PlanStore(context: container.mainContext, today: now)
        plan = planStore
        Self.seed(planStore, now: now)
        let clock = PlanTestClock(now)
        self.clock = clock
        let dragEvidence: PlanView.DragEvidence? = dragSourceTitle.flatMap { title in
            guard let source = planStore.week(containing: now).days
                .flatMap(\.sessions)
                .first(where: { $0.workout.title == title }) else {
                return nil
            }
            let destinationDate = dragDestinationDayOffset.flatMap {
                Self.cal.date(byAdding: .day, value: $0, to: Self.cal.weekStart(for: now))
            }
            return PlanView.DragEvidence(
                sourceID: source.id,
                destinationDate: destinationDate,
                destinationIndex: dragDestinationIndex
            )
        }

        let root = PlanView(now: { clock.now }, dragEvidence: dragEvidence)
            .environment(plan)
            .environment(AppSettings())
            .environment(BluetoothManager())
            .environment(OnboardingStore())
            .environment(WorkoutStore(units: AppSettings()))
            // Starting a session from a row presents the real `WorkoutView`, which reads the zone
            // store; without it the execution sheet traps instead of opening.
            .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
            .modelContainer(container)
            .preferredColorScheme(.dark)
        window = try Self.makeWindow(rootView: root)
    }

    var isPresentingCover: Bool { window.rootViewController?.presentedViewController != nil }

    /// Move the clock forward and tell the screen the calendar day turned over, exactly as the system
    /// does at midnight for a process that stayed resident.
    func advanceClock(byDays days: Int) {
        clock.now = Self.cal.date(byAdding: .day, value: days, to: clock.now)!
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
    }

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

/// A clock the test can move under a screen that is already hosted, so one `PlanView` can be walked
/// across midnight the way a resident app crosses it. Lock-guarded because `PlanView.now` is a plain
/// non-isolated closure and the screen reads it from the render loop.
private final class PlanTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
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
