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
            at: 2,
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
            at: 0,
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
            at: 1,
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
            at: 0,
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
            at: 0,
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
            at: 1,
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
            at: 0,
            notBefore: bed.today,
            actor: .user,
            reason: nil
        )

        #expect(result == .rejected(.invalidTarget))
        #expect(bed.titles(on: bed.today) == ["Performed", "Do not move"])
        #expect(bed.titles(on: future).isEmpty)
        #expect(bed.repository.completedLog(forScheduled: completed.id) == frozen)
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

    func seed(_ title: String, on date: Date) -> ScheduledWorkout {
        var exercise = PlannedExercise(exerciseName: "Squat", definitionId: "back-squat")
        exercise.prescription.sets = [PlannedSet(reps: 5, load: 100)]
        let workout = Workout(
            title: title,
            blocks: [WorkoutBlock(name: "", exercises: [exercise], isDefault: true)]
        )
        return repository.addScheduled(
            ScheduledWorkout(
                programID: programID,
                date: date,
                origin: .userCreated,
                workoutID: workout.id,
                workoutRevisionID: UUID(),
                workout: workout
            )
        )
    }

    func titles(on date: Date) -> [String] {
        repository.day(date, filter: .allTraining).sessions.map(\.workout.title)
    }
}
