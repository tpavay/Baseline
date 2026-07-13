import Foundation
import SwiftData
import Testing
@testable import Baseline

/// Slice 1 persistence: the SwiftData-backed repository (reads + lifecycle) and the migrator, exercised
/// against an in-memory container. Everything runs on the main actor (SwiftData `ModelContext`).
@MainActor
struct PlanRepositoryTests {

    private func makeRepo() -> SwiftDataPlanRepository {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(for: Schema(models),
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return SwiftDataPlanRepository(context: container.mainContext)
    }

    private let cal = Calendar.planWeek
    private var monday: Date { cal.weekStart(for: Date(timeIntervalSince1970: 1_752_000_000)) }

    private func workout(_ title: String) -> Workout {
        var ex = PlannedExercise(exerciseName: "Squat", definitionId: "deadlift")
        ex.prescription.sets = [PlannedSet(reps: 5, load: 100), PlannedSet(reps: 5, load: 100)]
        return Workout(title: title, blocks: [WorkoutBlock(name: "", exercises: [ex], isDefault: true)])
    }

    private func seed(_ repo: SwiftDataPlanRepository, date: Date, program: UUID) -> ScheduledWorkout {
        repo.addScheduled(ScheduledWorkout(programID: program, date: date, origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: workout("W")))
    }

    @Test func weekProjectionBucketsSessionsByDay() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        _ = seed(repo, date: monday, program: prog.id)
        _ = seed(repo, date: cal.date(byAdding: .day, value: 2, to: monday)!, program: prog.id)
        _ = seed(repo, date: cal.date(byAdding: .day, value: 9, to: monday)!, program: prog.id)  // next week — excluded

        let week = repo.week(containing: monday, filter: .allTraining)
        #expect(week.days.count == 7)
        #expect(week.days[0].sessions.count == 1)     // Monday
        #expect(week.days[2].sessions.count == 1)     // Wednesday
        #expect(week.days.flatMap(\.sessions).count == 2)
    }

    @Test func hydratesWorkoutContentFromRevision() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)
        let read = repo.scheduledWorkout(sw.id)
        #expect(read?.workout.title == "W")
        #expect(read?.workout.allExercises.first?.prescription.sets.count == 2)
    }

    @Test func programFilterExcludesOtherPrograms() {
        let repo = makeRepo()
        let a = repo.addProgram(Program(name: "A", createdAt: monday))
        let b = repo.addProgram(Program(name: "B", createdAt: monday))
        _ = seed(repo, date: monday, program: a.id)
        _ = seed(repo, date: monday, program: b.id)
        #expect(repo.week(containing: monday, filter: .allTraining).days[0].sessions.count == 2)
        #expect(repo.week(containing: monday, filter: .program(a.id)).days[0].sessions.count == 1)
    }

    @Test func lifecycleStartCompleteKeepsPlanAndFreezesLog() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)

        #expect(repo.session(forScheduled: sw.id) == nil)
        let session = repo.startSession(forScheduled: sw.id, now: monday)
        #expect(session?.status == .active)
        // Idempotent — starting again returns the same live session.
        #expect(repo.startSession(forScheduled: sw.id, now: monday)?.id == session?.id)

        // Unlogged sets → completion warns instead of finalizing.
        if case .unloggedWork(let sets, _) = repo.completeSession(forScheduled: sw.id, acknowledgingOpenWork: false, now: monday) {
            #expect(sets == 2)
        } else { Issue.record("expected unloggedWork") }

        // Acknowledge → completes; a CompletedWorkoutLog exists and the plan is untouched.
        if case .completed = repo.completeSession(forScheduled: sw.id, acknowledgingOpenWork: true, now: monday) {
            #expect(repo.completedLog(forScheduled: sw.id) != nil)
            #expect(repo.scheduledWorkout(sw.id)?.workout.allExercises.first?.prescription.sets.count == 2)
        } else { Issue.record("expected completed") }
    }

    @Test func editingWorkoutCreatesANewImmutableRevision() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)
        let before = repo.scheduledWorkout(sw.id)!.workoutRevisionID

        repo.updateWorkout(scheduledID: sw.id) { $0.rename("Edited") }
        let after = repo.scheduledWorkout(sw.id)!

        #expect(after.workout.title == "Edited")
        #expect(after.workoutRevisionID != before)   // new revision, old one untouched
        #expect(after.workoutID == sw.workoutID)      // stable identity across revisions
    }

    @Test func migratorSeedsTodaysScheduledWorkoutOnceWithoutWiping() {
        let repo = makeRepo()
        let plan = PlanStore(repo: repo, today: monday)
        let defaults = UserDefaults(suiteName: "mig-\(UUID().uuidString)")!
        let workouts = WorkoutStore(defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
        workouts.create(title: "Legacy day", goal: nil)

        PlanMigrator.migrateIfNeeded(defaults: defaults, into: plan, workouts: workouts, today: monday)
        let today = repo.week(containing: monday, filter: .allTraining).days[0]
        #expect(today.sessions.count == 1)
        #expect(today.sessions.first?.origin == .legacyMigrated)
        #expect(today.sessions.first?.workout.title == "Legacy day")

        // Idempotent — a second run adds nothing, and the legacy workout is still present (not wiped).
        PlanMigrator.migrateIfNeeded(defaults: defaults, into: plan, workouts: workouts, today: monday)
        #expect(repo.week(containing: monday, filter: .allTraining).days[0].sessions.count == 1)
        #expect(workouts.current?.title == "Legacy day")
    }
}
