import Foundation
import Testing
@testable import Baseline

/// Every day-state rule of the redesigned Plan week, pinned on the pure presentation model so the
/// rules hold independently of the view that draws them: a performed day is green and opens its log,
/// a not-yet-done session is neutral with a reorder handle, rest and undecided days say so, the
/// "add a second session" affordance is offered on today and future days only, and today is marked
/// by its accent date alone (never a duplicate dot in the weekday strip).
struct PlanWeekPresentationTests {

    private let cal = Calendar.planWeek
    /// A fixed reference Wednesday, so "past", "today" and "future" all exist inside one week.
    private var today: Date { cal.startOfDay(for: Date(timeIntervalSince1970: 1_752_000_000)) }
    private var weekStart: Date { cal.weekStart(for: today) }

    // MARK: Fixtures

    private func strengthWorkout(_ title: String) -> Workout {
        var ex = PlannedExercise(exerciseName: "Back Squat", definitionId: "back-squat")
        ex.prescription.sets = [PlannedSet(reps: 5, load: 100), PlannedSet(reps: 5, load: 100)]
        return Workout(title: title, blocks: [WorkoutBlock(name: "", exercises: [ex], isDefault: true)])
    }

    private func timedWorkout(_ title: String) -> Workout {
        var ex = PlannedExercise(exerciseName: "Row", definitionId: "row")
        ex.prescription.sets = [PlannedSet(duration: 1_800, distance: 5_000)]
        return Workout(title: title, blocks: [WorkoutBlock(name: "", exercises: [ex], isDefault: true)])
    }

    private func scheduled(_ workout: Workout, on date: Date) -> ScheduledWorkout {
        ScheduledWorkout(programID: UUID(), date: date, origin: .userCreated,
                         workoutID: workout.id, workoutRevisionID: UUID(), workout: workout)
    }

    private func date(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    /// A week built from `content` keyed by day-offset from today, so each test states only the days
    /// it cares about.
    private func week(
        sessions: [Int: [ScheduledWorkout]] = [:],
        restDays: Set<Int> = []
    ) -> TrainingWeek {
        let days = (0 ..< 7).map { index -> TrainingDay in
            let day = cal.date(byAdding: .day, value: index, to: weekStart)!
            let offset = cal.dateComponents([.day], from: today, to: day).day ?? 0
            return TrainingDay(date: day, sessions: sessions[offset] ?? [], isRestDay: restDays.contains(offset))
        }
        return TrainingWeek(startDate: weekStart, days: days)
    }

    private func build(_ week: TrainingWeek, statuses: [UUID: ScheduleStatus] = [:]) -> PlanWeekPresentation {
        PlanWeekPresentation.build(week: week, statuses: statuses, today: today, calendar: cal)
    }

    private func row(_ presentation: PlanWeekPresentation, offset: Int) throws -> PlanDayRow {
        try #require(presentation.days.first { self.cal.isDate($0.date, inSameDayAs: self.date(offset)) })
    }

    // MARK: Day states

    @Test func aPerformedSessionIsCompletedAndOpensItsLogWithoutAReorderHandle() throws {
        let done = scheduled(strengthWorkout("Full Body"), on: date(-1))
        let presentation = build(week(sessions: [-1: [done]]), statuses: [done.id: .completed])

        let entry = try #require(try row(presentation, offset: -1).sessions.first)
        #expect(entry.isCompleted)
        #expect(entry.title == "Full Body")
        #expect(entry.detail == "View log")
        #expect(entry.showsReorderHandle == false, "A day already trained is history, not something to reorder")
    }

    @Test func aCompletedDayLocksEverySessionFromReordering() throws {
        let done = scheduled(strengthWorkout("Completed"), on: today)
        let planned = scheduled(strengthWorkout("Planned sibling"), on: today)
        let presentation = build(
            week(sessions: [0: [done, planned]]),
            statuses: [done.id: .completed, planned.id: .today(.asPlanned)]
        )

        let entries = try row(presentation, offset: 0).sessions
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.showsReorderHandle == false })
    }

    // MARK: The locked days, and the move targets they rule out

    @Test func aPastDayIsLockedAndACompletedDayIsLockedForADifferentReason() throws {
        let done = scheduled(strengthWorkout("Completed"), on: date(1))
        let missed = scheduled(strengthWorkout("Push Day"), on: date(-1))
        let presentation = build(
            week(sessions: [-1: [missed], 1: [done]]),
            statuses: [done.id: .completed, missed.id: .missed]
        )

        let past = try row(presentation, offset: -1)
        let completed = try row(presentation, offset: 1)
        let todayRow = try row(presentation, offset: 0)
        let openFuture = try row(presentation, offset: 2)

        #expect(past.lock == .past)
        #expect(completed.lock == .completed)
        #expect(todayRow.lock == nil, "Today accepts training")
        #expect(openFuture.lock == nil, "So does an untouched future day")
    }

    /// The long-press menu is the drag's secondary route, so it offers exactly the days the drag would
    /// accept: nothing before today, nothing already trained on, and never the day it is already on.
    @Test func theMoveMenuOffersOnlyUnlockedDaysAndNeverTheSessionsOwnDay() throws {
        let done = scheduled(strengthWorkout("Completed"), on: date(2))
        let planned = scheduled(strengthWorkout("Planned"), on: today)
        let presentation = build(
            week(sessions: [0: [planned], 2: [done]]),
            statuses: [done.id: .completed, planned.id: .today(.asPlanned)]
        )

        let destinations = presentation.moveDestinations(from: try row(presentation, offset: 0), calendar: cal)

        #expect(destinations.contains { cal.isDate($0, inSameDayAs: date(0)) } == false,
                "The session is already on today")
        #expect(destinations.contains { cal.isDate($0, inSameDayAs: date(-1)) } == false,
                "A past day is locked")
        #expect(destinations.contains { cal.isDate($0, inSameDayAs: date(2)) } == false,
                "A day carrying performed training is locked")
        #expect(destinations.contains { cal.isDate($0, inSameDayAs: date(1)) },
                "An untouched future day is offered")
        #expect(destinations.allSatisfy { $0 >= self.today }, "Nothing before today survives the filter")
    }

    /// A session sitting on a locked day is not going anywhere, so the view drops the submenu entirely
    /// rather than listing days the repository would refuse.
    @Test func aSessionOnALockedDayIsOfferedNoMoveDestinationsAtAll() throws {
        let done = scheduled(strengthWorkout("Completed"), on: today)
        let planned = scheduled(strengthWorkout("Planned sibling"), on: today)
        let missed = scheduled(strengthWorkout("Push Day"), on: date(-1))
        let presentation = build(
            week(sessions: [-1: [missed], 0: [done, planned]]),
            statuses: [done.id: .completed, planned.id: .today(.asPlanned), missed.id: .missed]
        )

        #expect(presentation.moveDestinations(from: try row(presentation, offset: 0), calendar: cal).isEmpty,
                "Today already holds performed training, so neither of its sessions can move")
        #expect(presentation.moveDestinations(from: try row(presentation, offset: -1), calendar: cal).isEmpty)
    }

    /// The core "not green until you actually did it" rule: a scheduled session on a past day with no
    /// completed log is missed, never completed, and never offers a log to view.
    @Test func aPastSessionWithoutACompletedLogIsNotCompleted() throws {
        let missed = scheduled(strengthWorkout("Push Day"), on: date(-1))
        let presentation = build(week(sessions: [-1: [missed]]), statuses: [missed.id: .missed])

        let entry = try #require(try row(presentation, offset: -1).sessions.first)
        #expect(entry.isCompleted == false)
        #expect(entry.detail != "View log")
        #expect(entry.showsReorderHandle == false)
    }

    @Test func todaysSessionIsNeutralWithAReorderHandleAndNeverSaysPlanned() throws {
        let session = scheduled(timedWorkout("Zone 2 Recovery"), on: today)
        let presentation = build(week(sessions: [0: [session]]), statuses: [session.id: .today(.asPlanned)])

        let day = try row(presentation, offset: 0)
        #expect(day.isToday)
        let entry = try #require(day.sessions.first)
        #expect(entry.isCompleted == false)
        #expect(entry.showsReorderHandle)
        #expect(entry.detail == "Row · 30m", "The subtitle states the work and its planned duration")
        #expect(entry.detail.lowercased().contains("planned") == false)
    }

    /// A session with no planned duration must simply say what the work is - the old row filled the
    /// duration slot with the literal word "Planned", which read as a plan state and was really a
    /// missing-value placeholder.
    @Test func aSessionWithoutAPlannedDurationStatesTheWorkAlone() throws {
        let session = scheduled(strengthWorkout("Leg Day"), on: date(2))
        let presentation = build(week(sessions: [2: [session]]), statuses: [session.id: .planned])

        let entry = try #require(try row(presentation, offset: 2).sessions.first)
        #expect(entry.detail == "Back Squat")
    }

    @Test func aMarkedDayIsRestAndAnUndecidedDayIsEmpty() throws {
        let presentation = build(week(restDays: [1]))

        #expect(try row(presentation, offset: 1).content == .rest)
        #expect(try row(presentation, offset: 2).content == .empty)
    }

    /// A rest marker is display-only once training is scheduled on the day: the session wins the row.
    @Test func aRestMarkerDoesNotHideAScheduledSession() throws {
        let session = scheduled(strengthWorkout("Leg Day"), on: date(1))
        let presentation = build(week(sessions: [1: [session]], restDays: [1]), statuses: [session.id: .planned])

        #expect(try row(presentation, offset: 1).sessions.count == 1)
    }

    // MARK: The "add a second session" rule

    @Test func addingASecondSessionIsOfferedOnTodayAndFutureDaysOnly() throws {
        let past = scheduled(strengthWorkout("Full Body"), on: date(-1))
        let now = scheduled(timedWorkout("Zone 2 Recovery"), on: today)
        let future = scheduled(strengthWorkout("Leg Day"), on: date(1))
        let presentation = build(
            week(sessions: [-1: [past], 0: [now], 1: [future]]),
            statuses: [past.id: .completed, now.id: .today(.asPlanned), future.id: .planned]
        )

        #expect(try row(presentation, offset: -1).showsAddAnother == false)
        #expect(try row(presentation, offset: 0).showsAddAnother)
        #expect(try row(presentation, offset: 1).showsAddAnother)
    }

    @Test func anEmptyDayCarriesNoAddAnotherRow() throws {
        let presentation = build(week())
        #expect(presentation.days.allSatisfy { $0.showsAddAnother == false })
    }

    @Test func aDayWithTwoSessionsRendersBothAndOneAddAnotherRow() throws {
        let first = scheduled(timedWorkout("Zone 2 Recovery"), on: today)
        let second = scheduled(strengthWorkout("Evening Accessories"), on: today)
        let presentation = build(
            week(sessions: [0: [first, second]]),
            statuses: [first.id: .today(.asPlanned), second.id: .today(.asPlanned)]
        )

        let day = try row(presentation, offset: 0)
        #expect(day.sessions.map(\.title) == ["Zone 2 Recovery", "Evening Accessories"])
        #expect(day.showsAddAnother)
    }

    // MARK: Weekday strip

    @Test func theStripMarksCompletedDaysGreenRestDaysWithAMoonAndLeavesTodayClear() throws {
        let done = scheduled(strengthWorkout("Full Body"), on: date(-1))
        let now = scheduled(timedWorkout("Zone 2 Recovery"), on: today)
        let presentation = build(
            week(sessions: [-1: [done], 0: [now]], restDays: [1]),
            statuses: [done.id: .completed, now.id: .today(.asPlanned)]
        )

        func cell(_ offset: Int) throws -> PlanWeekdayCell {
            try #require(presentation.weekdays.first { self.cal.isDate($0.date, inSameDayAs: self.date(offset)) })
        }
        #expect(presentation.weekdays.count == 7)
        #expect(try cell(-1).mark == .completed)
        #expect(try cell(1).mark == .rest)
        #expect(try cell(2).mark == .none)
        let todayCell = try cell(0)
        #expect(todayCell.isToday)
        #expect(todayCell.mark == .none, "Today is marked by its accent letter, not by a second glyph")
    }

    /// Completing today's session must not sprout a dot over the accent letter.
    @Test func todayStaysUnmarkedEvenOnceItsSessionIsCompleted() throws {
        let done = scheduled(strengthWorkout("Full Body"), on: today)
        let presentation = build(week(sessions: [0: [done]]), statuses: [done.id: .completed])

        let cell = try #require(presentation.weekdays.first { $0.isToday })
        #expect(cell.mark == .none)
        #expect(try row(presentation, offset: 0).sessions.first?.isCompleted == true)
    }

    // MARK: Week identity

    @Test func theWeekIsSevenOrderedDaysStartingOnItsWeekStart() {
        let presentation = build(week())
        #expect(presentation.days.count == 7)
        #expect(presentation.weekStart == weekStart)
        #expect(presentation.containsToday)
        #expect(presentation.days.map(\.date) == (0 ..< 7).map { cal.date(byAdding: .day, value: $0, to: weekStart)! })
        #expect(presentation.days.filter(\.isToday).count == 1)
    }

    @Test func theRangeLabelNamesTheWeekAndSpellsTheMonthOnlyWhenItChanges() {
        let july = TrainingWeek(startDate: cal.weekStart(for: dateFrom(2026, 7, 22)), days: [])
        #expect(PlanWeekPresentation.build(week: july, statuses: [:], today: today, calendar: cal).rangeLabel == "JUL 20 – 26")

        let straddling = TrainingWeek(startDate: cal.weekStart(for: dateFrom(2026, 7, 30)), days: [])
        #expect(PlanWeekPresentation.build(week: straddling, statuses: [:], today: today, calendar: cal).rangeLabel == "JUL 27 – AUG 2")
    }

    /// The navigation title has to name the months the visible week actually covers - a week running
    /// "JUL 27 – AUG 2" titled "July 2026" names a month six of its seven days are not in.
    @Test func theMonthLabelNamesEveryMonthTheVisibleWeekCovers() {
        let july = TrainingWeek(startDate: cal.weekStart(for: dateFrom(2026, 7, 22)), days: [])
        #expect(build(july).monthLabel == "Jul 2026")

        let straddling = TrainingWeek(startDate: cal.weekStart(for: dateFrom(2026, 7, 30)), days: [])
        #expect(build(straddling).monthLabel == "Jul – Aug 2026")
    }

    /// A week straddling New Year names both years, so the title is never ambiguous.
    @Test func theMonthLabelNamesBothYearsAcrossTheTurnOfTheYear() {
        let newYear = TrainingWeek(startDate: cal.weekStart(for: dateFrom(2026, 12, 31)), days: [])
        #expect(build(newYear).monthLabel == "Dec 2026 – Jan 2027")
    }

    /// The title sits in the principal toolbar slot between the filter chip and Today, so even the
    /// longest form has to stay short - abbreviated months are what keeps it from truncating there.
    @Test func theMonthLabelStaysShortEnoughForThePrincipalToolbarSlot() {
        let widest = TrainingWeek(startDate: cal.weekStart(for: dateFrom(2026, 12, 31)), days: [])
        #expect(build(widest).monthLabel.count <= 20)
    }

    // MARK: The day the projection was built for

    /// The view caches this projection, so it has to carry the day its `isToday`/`isPast` rules were
    /// resolved against - that is what lets a rolled-over day be detected and rebuilt.
    @Test func thePresentationRecordsTheDayItsRulesWereResolvedAgainst() {
        #expect(build(week()).today == cal.startOfDay(for: today))
    }

    private func dateFrom(_ year: Int, _ month: Int, _ day: Int) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
