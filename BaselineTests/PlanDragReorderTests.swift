import Foundation
import SwiftData
import Testing
@testable import Baseline

@MainActor
struct PlanDragReorderTests {
    private let calendar = Calendar.planWeek

    @Test("Drop after an existing session persists final within-day order")
    func reorderWithinDayAfterExistingSession() throws {
        let bed = try TestBed()
        let day = bed.today
        let first = bed.seed("First", on: day)
        _ = bed.seed("Second", on: day)
        _ = bed.seed("Third", on: day)

        let result = bed.repository.reposition(
            first.id,
            toDate: day,
            at: .index(2),
            notBefore: day,
            actor: .user,
            reason: nil
        )

        #expect(result.isApplied)
        #expect(bed.titles(on: day) == ["Second", "Third", "First"])
    }

    @Test("Drop before an existing session persists final within-day order")
    func reorderWithinDayBeforeExistingSession() throws {
        let bed = try TestBed()
        let day = bed.today
        _ = bed.seed("First", on: day)
        _ = bed.seed("Second", on: day)
        let third = bed.seed("Third", on: day)

        let result = bed.repository.reposition(
            third.id,
            toDate: day,
            at: .index(0),
            notBefore: day,
            actor: .user,
            reason: nil
        )

        #expect(result.isApplied)
        #expect(bed.titles(on: day) == ["Third", "First", "Second"])
    }

    @Test("A planned session moves to an occupied future day as its second session")
    func moveAcrossDaysToOccupiedFutureDay() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 2, to: bed.today))
        let moved = bed.seed("Move me", on: bed.today)
        _ = bed.seed("Already there", on: future)

        let result = bed.repository.reposition(
            moved.id,
            toDate: future,
            at: .index(1),
            notBefore: bed.today,
            actor: .user,
            reason: nil
        )

        #expect(result.isApplied)
        #expect(bed.titles(on: bed.today).isEmpty)
        #expect(bed.titles(on: future) == ["Already there", "Move me"])

        #expect(bed.repository.undo(actor: .user).isApplied)
        #expect(bed.titles(on: bed.today) == ["Move me"])
        #expect(bed.titles(on: future) == ["Already there"])
    }

    @Test("An in-progress session can move without changing its performed-session record")
    func moveInProgressSessionPreservesPerformedSeparation() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let moved = bed.seed("In progress", on: bed.today)
        let session = try #require(bed.repository.startSession(forScheduled: moved.id, now: bed.today))

        let result = bed.repository.reposition(
            moved.id,
            toDate: future,
            at: .index(0),
            notBefore: bed.today,
            actor: .user,
            reason: nil
        )

        #expect(result.isApplied)
        #expect(calendar.isDate(bed.repository.scheduledWorkout(moved.id)?.date ?? .distantPast,
                                inSameDayAs: future))
        let persistedSession = try #require(bed.repository.session(forScheduled: moved.id))
        #expect(persistedSession.id == session.id)
        #expect(persistedSession.status == .active)
        #expect(bed.repository.completedLog(forScheduled: moved.id) == nil)
    }

    @Test("A past day rejects a drop without appending a version")
    func pastDayRejectsDrop() throws {
        let bed = try TestBed()
        let past = try #require(calendar.date(byAdding: .day, value: -1, to: bed.today))
        let moved = bed.seed("Stay today", on: bed.today)
        let versionsBefore = bed.repository.versions(limit: 100).count

        let result = bed.repository.reposition(
            moved.id,
            toDate: past,
            at: .index(0),
            notBefore: bed.today,
            actor: .user,
            reason: nil
        )

        #expect(result == .rejected(.invalidTarget))
        #expect(bed.titles(on: bed.today) == ["Stay today"])
        #expect(bed.titles(on: past).isEmpty)
        #expect(bed.repository.versions(limit: 100).count == versionsBefore)
    }

    @Test("A completed day rejects a drop and its frozen log stays unchanged")
    func completedDayRejectsDrop() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let moved = bed.seed("Stay today", on: bed.today)
        let completed = bed.seed("Performed", on: future)
        _ = try #require(bed.repository.startSession(forScheduled: completed.id, now: bed.today))
        guard case .completed(let frozen) = bed.repository.completeSession(
            forScheduled: completed.id,
            acknowledgingOpenWork: true,
            now: bed.today
        ) else {
            Issue.record("Expected a frozen completed log")
            return
        }

        let result = bed.repository.reposition(
            moved.id,
            toDate: future,
            at: .index(1),
            notBefore: bed.today,
            actor: .user,
            reason: nil
        )

        #expect(result == .rejected(.invalidTarget))
        #expect(bed.titles(on: bed.today) == ["Stay today"])
        #expect(bed.titles(on: future) == ["Performed"])
        #expect(bed.repository.completedLog(forScheduled: completed.id) == frozen)
    }

    @Test("A session cannot be dragged out of a completed day")
    func completedSourceDayRejectsDrop() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let completed = bed.seed("Performed", on: bed.today)
        let plannedSibling = bed.seed("Do not move", on: bed.today)
        _ = try #require(bed.repository.startSession(forScheduled: completed.id, now: bed.today))
        guard case .completed(let frozen) = bed.repository.completeSession(
            forScheduled: completed.id,
            acknowledgingOpenWork: true,
            now: bed.today
        ) else {
            Issue.record("Expected a frozen completed log")
            return
        }

        let result = bed.repository.reposition(
            plannedSibling.id,
            toDate: future,
            at: .index(0),
            notBefore: bed.today,
            actor: .user,
            reason: nil
        )

        #expect(result == .rejected(.invalidTarget))
        #expect(bed.titles(on: bed.today) == ["Performed", "Do not move"])
        #expect(bed.titles(on: future).isEmpty)
        #expect(bed.repository.completedLog(forScheduled: completed.id) == frozen)
    }

    /// Adding a second workout to a day is not a reorder of that day. If it renumbers its siblings it
    /// rewrites their intents, and the very next undo collides with any session live on that day.
    @Test("Adding a workout appends to its day without rewriting a sibling's intent")
    func addingAWorkoutLeavesSiblingOrderAlone() throws {
        let bed = try TestBed()
        let day = bed.today
        let live = bed.seed("Live", on: day)
        _ = bed.seed("Second", on: day)
        bed.clearStoredDayOrder(for: live.id)
        let ordersBefore = bed.storedDayOrders(on: day)
        _ = try #require(bed.repository.startSession(forScheduled: live.id, now: day))

        #expect(bed.repository.addWorkout(bed.workout("Third", on: day), actor: .user, reason: nil).isApplied)

        #expect(bed.titles(on: day) == ["Live", "Second", "Third"],
                "A day written before drag ordering keeps its order and the new row lands last")
        #expect(Array(bed.storedDayOrders(on: day).dropLast()) == ordersBefore,
                "The add appended; it did not renumber the day")
        #expect(bed.repository.undo(actor: .user).isApplied,
                "The live session's intent never moved, so undoing the add is not a conflict")
        #expect(bed.titles(on: day) == ["Live", "Second"])
    }

    @Test("A duplicate lands after the session it was copied from")
    func duplicateAppendsToItsDay() throws {
        let bed = try TestBed()
        let day = bed.today
        let source = bed.seed("Source", on: day)
        _ = bed.seed("Second", on: day)

        #expect(bed.repository.duplicate(source.id, toDate: nil, actor: .user, reason: nil).isApplied)

        #expect(bed.titles(on: day) == ["Source", "Second", "Source"])
    }

    @Test("A duplicate onto another day appends there rather than inheriting the source's slot")
    func duplicateOntoAnotherDayAppends() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 2, to: bed.today))
        let source = bed.seed("Source", on: bed.today)
        _ = bed.seed("Already there", on: future)
        _ = bed.seed("Also there", on: future)

        #expect(bed.repository.duplicate(source.id, toDate: future, actor: .user, reason: nil).isApplied)

        #expect(bed.titles(on: future) == ["Already there", "Also there", "Source"],
                "The copy takes a fresh slot at the end, not the source's slot on another day")
    }

    @Test("Moving to another day appends there and leaves both days' siblings alone")
    func moveAppendsToTheTargetDay() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 2, to: bed.today))
        let moved = bed.seed("Move me", on: bed.today)
        let live = bed.seed("Stay", on: bed.today)
        _ = bed.seed("Already there", on: future)
        _ = try #require(bed.repository.startSession(forScheduled: live.id, now: bed.today))

        #expect(bed.repository.move(moved.id, toDate: future, timeOfDay: nil, actor: .user, reason: nil).isApplied)

        #expect(bed.titles(on: bed.today) == ["Stay"])
        #expect(bed.titles(on: future) == ["Already there", "Move me"])
        #expect(bed.repository.undo(actor: .user).isApplied,
                "The gap the move left behind was never closed, so the live session's intent stood still")
        #expect(bed.titles(on: bed.today) == ["Move me", "Stay"])
        #expect(bed.titles(on: future) == ["Already there"])
    }

    /// The long-press menu's "Move to" is the drag's secondary route, so it lands on `reposition` with
    /// `.endOfDay`: appended to the end of the target day, refused on a locked one.
    @Test("The menu's move route appends to its target and obeys the same locks as the drag")
    func repositionToEndOfDayAppendsAndStillRejectsLockedDays() throws {
        let bed = try TestBed()
        let past = try #require(calendar.date(byAdding: .day, value: -1, to: bed.today))
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let moved = bed.seed("Move me", on: bed.today)
        _ = bed.seed("Already there", on: future)

        #expect(bed.repository.reposition(
            moved.id, toDate: past, at: .endOfDay, notBefore: bed.today, actor: .user, reason: nil
        ) == .rejected(.invalidTarget))

        #expect(bed.repository.reposition(
            moved.id, toDate: future, at: .endOfDay, notBefore: bed.today, actor: .user, reason: nil
        ).isApplied)
        #expect(bed.titles(on: future) == ["Already there", "Move me"])
    }

    /// An index past the day's last slot means the same thing as `.endOfDay`, which is the contract
    /// the protocol documents rather than an accident of an internal clamp.
    @Test("An index beyond the day's last slot appends instead of failing")
    func repositionClampsAnOutOfRangeIndexToTheEnd() throws {
        let bed = try TestBed()
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let moved = bed.seed("Move me", on: bed.today)
        _ = bed.seed("Already there", on: future)

        #expect(bed.repository.reposition(
            moved.id, toDate: future, at: .index(99), notBefore: bed.today, actor: .user, reason: nil
        ).isApplied)
        #expect(bed.titles(on: future) == ["Already there", "Move me"])
    }

    /// The renumbering trap the sparse ordering exists to avoid: a day left with a gap by an earlier
    /// move gets something dropped onto it, and a *sibling* holding a live session is renumbered as
    /// collateral - which makes its intent differ between snapshots and silently refuses the next undo.
    @Test("Dropping onto a day never renumbers a sibling holding a live session")
    func repositionLeavesLiveSiblingsUntouched() throws {
        let bed = try TestBed()
        let other = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let day = bed.today
        _ = bed.seed("First", on: day)
        let leaving = bed.seed("Leaving", on: day)
        let live = bed.seed("Live", on: day)
        let arriving = bed.seed("Arriving", on: other)
        _ = try #require(bed.repository.startSession(forScheduled: live.id, now: day))

        #expect(bed.repository.reposition(
            leaving.id, toDate: other, at: .endOfDay, notBefore: day, actor: .user, reason: nil
        ).isApplied)
        let liveOrderAfterGap = bed.storedDayOrder(of: live.id)

        #expect(bed.repository.reposition(
            arriving.id, toDate: day, at: .endOfDay, notBefore: day, actor: .user, reason: nil
        ).isApplied)

        #expect(bed.titles(on: day) == ["First", "Live", "Arriving"])
        #expect(bed.storedDayOrder(of: live.id) == liveOrderAfterGap,
                "The dropped session took a fresh slot; the live sibling kept its own")
        #expect(bed.repository.undo(actor: .user).isApplied,
                "No live intent changed, so the athlete's Undo is not refused")
        #expect(bed.titles(on: day) == ["First", "Live"])
    }

    /// The same guarantee for a mid-day insert, which is what a real drag between two rows produces:
    /// the moved row takes a value inside the gap rather than pushing the rows after it along.
    @Test("Dropping between two sessions re-spaces only the moved row")
    func repositionBetweenSessionsWritesOnlyTheMovedRow() throws {
        let bed = try TestBed()
        let day = bed.today
        let first = bed.seed("First", on: day)
        let live = bed.seed("Live", on: day)
        let moved = bed.seed("Moved", on: day)
        _ = try #require(bed.repository.startSession(forScheduled: live.id, now: day))
        let firstOrder = bed.storedDayOrder(of: first.id)
        let liveOrder = bed.storedDayOrder(of: live.id)

        #expect(bed.repository.reposition(
            moved.id, toDate: day, at: .index(1), notBefore: day, actor: .user, reason: nil
        ).isApplied)

        #expect(bed.titles(on: day) == ["First", "Moved", "Live"])
        #expect(bed.storedDayOrder(of: first.id) == firstOrder)
        #expect(bed.storedDayOrder(of: live.id) == liveOrder)
        #expect(bed.repository.undo(actor: .user).isApplied)
        #expect(bed.titles(on: day) == ["First", "Live", "Moved"])
    }

    /// A legacy day whose rows predate drag ordering: dropping onto the end of it must not give those
    /// rows the numbers they never had, because that is a rewrite of intents the drop never touched.
    @Test("Appending to a day of unordered legacy rows leaves them unordered")
    func repositionOntoLegacyDayLeavesItAlone() throws {
        let bed = try TestBed()
        let day = bed.today
        let other = try #require(calendar.date(byAdding: .day, value: 1, to: bed.today))
        let legacy = bed.seed("Legacy", on: day)
        let arriving = bed.seed("Arriving", on: other)
        bed.clearStoredDayOrder(for: legacy.id)

        #expect(bed.repository.reposition(
            arriving.id, toDate: day, at: .endOfDay, notBefore: day, actor: .user, reason: nil
        ).isApplied)

        #expect(bed.titles(on: day) == ["Legacy", "Arriving"])
        #expect(bed.storedDayOrder(of: legacy.id) == nil)
    }

    @Test("Geometry resolves before and after slots, past locks, and completed locks")
    func dragTargetResolution() {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_774_000_000))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let past = calendar.date(byAdding: .day, value: -1, to: today)!
        let first = UUID()
        let second = UUID()
        let days = [
            PlanDragReorderModel.DayGeometry(
                date: past,
                frame: CGRect(x: 0, y: 0, width: 320, height: 80),
                sessions: [],
                isPast: true,
                isCompleted: false
            ),
            PlanDragReorderModel.DayGeometry(
                date: today,
                frame: CGRect(x: 0, y: 80, width: 320, height: 120),
                sessions: [
                    .init(id: first, frame: CGRect(x: 0, y: 80, width: 320, height: 60)),
                    .init(id: second, frame: CGRect(x: 0, y: 140, width: 320, height: 60))
                ],
                isPast: false,
                isCompleted: false
            ),
            PlanDragReorderModel.DayGeometry(
                date: tomorrow,
                frame: CGRect(x: 0, y: 200, width: 320, height: 80),
                sessions: [],
                isPast: false,
                isCompleted: true
            )
        ]

        #expect(PlanDragReorderModel.target(
            at: CGPoint(x: 100, y: 190),
            sourceID: first,
            sourceDate: today,
            days: days
        ) == .destination(.init(date: today, index: 1, displayIndex: 2)))
        #expect(PlanDragReorderModel.target(
            at: CGPoint(x: 100, y: 90),
            sourceID: second,
            sourceDate: today,
            days: days
        ) == .destination(.init(date: today, index: 0, displayIndex: 0)))
        #expect(PlanDragReorderModel.target(
            at: CGPoint(x: 100, y: 40),
            sourceID: first,
            sourceDate: today,
            days: days
        ) == .locked(date: past, reason: .past))
        #expect(PlanDragReorderModel.target(
            at: CGPoint(x: 100, y: 240),
            sourceID: first,
            sourceDate: today,
            days: days
        ) == .locked(date: tomorrow, reason: .completed))
    }
}

@MainActor
private final class TestBed {
    let container: ModelContainer
    let repository: SwiftDataPlanRepository
    let today: Date
    private let programID: UUID

    init() throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        repository = SwiftDataPlanRepository(context: container.mainContext)
        today = Calendar.planWeek.startOfDay(for: Date(timeIntervalSince1970: 1_774_000_000))
        programID = repository.addProgram(Program(name: "Test", createdAt: today)).id
    }

    func workout(_ title: String, on date: Date) -> ScheduledWorkout {
        var exercise = PlannedExercise(exerciseName: "Squat", definitionId: "back-squat")
        exercise.prescription.sets = [PlannedSet(reps: 5, load: 100)]
        let workout = Workout(
            title: title,
            blocks: [WorkoutBlock(name: "", exercises: [exercise], isDefault: true)]
        )
        return ScheduledWorkout(
            programID: programID,
            date: date,
            origin: .userCreated,
            workoutID: workout.id,
            workoutRevisionID: UUID(),
            workout: workout
        )
    }

    @discardableResult
    func seed(_ title: String, on date: Date) -> ScheduledWorkout {
        repository.addScheduled(workout(title, on: date))
    }

    func titles(on date: Date) -> [String] {
        repository.day(date, filter: .allTraining).sessions.map(\.workout.title)
    }

    func storedDayOrders(on date: Date) -> [Int?] {
        repository.day(date, filter: .allTraining).sessions.map(\.dayOrder)
    }

    func storedDayOrder(of id: UUID) -> Int? {
        repository.scheduledWorkout(id)?.dayOrder
    }

    /// Null out one row's stored order, the way a schedule written before drag ordering shipped looks
    /// on disk. Unordered rows sort ahead of ordered ones, so the result is still deterministic.
    func clearStoredDayOrder(for id: UUID) {
        let rows = (try? container.mainContext.fetch(FetchDescriptor<SDScheduledWorkout>())) ?? []
        for row in rows where row.id == id { row.dayOrder = nil }
        try? container.mainContext.save()
    }
}
