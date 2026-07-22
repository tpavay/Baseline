import Foundation
import SwiftData
import Testing
@testable import Baseline

/// Slice 1 persistence: the SwiftData-backed repository (reads + lifecycle) and the migrator, exercised
/// against an in-memory container. Everything runs on the main actor (SwiftData `ModelContext`).
@Suite(.serialized) @MainActor
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

    @Test func dayRangeIsInclusiveAndPreservesEmptyDays() {
        let repo = makeRepo()
        let program = repo.addProgram(Program(name: "P", createdAt: monday))
        let wednesday = cal.date(byAdding: .day, value: 2, to: monday)!
        _ = seed(repo, date: wednesday, program: program.id)

        let days = repo.days(from: monday, through: wednesday, filter: .allTraining)

        #expect(days.count == 3)
        #expect(days.map(\.date) == [monday, cal.date(byAdding: .day, value: 1, to: monday)!, wednesday])
        #expect(days[0].sessions.isEmpty)
        #expect(days[1].sessions.isEmpty)
        #expect(days[2].sessions.count == 1)
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

    private func completeDeadlift(_ repo: SwiftDataPlanRepository, _ sw: ScheduledWorkout, load: Double) {
        let ex = sw.workout.allExercises.first { $0.definitionId == "deadlift" }!
        repo.startSession(forScheduled: sw.id, now: sw.date)
        repo.updateSessionLog(forScheduled: sw.id) { log in
            log.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName, plannedSetID: ex.prescription.sets[0].id) { $0.values[.load] = load; $0.completed = true }
        }
        _ = repo.completeSession(forScheduled: sw.id, acknowledgingOpenWork: true, now: sw.date)
    }

    @Test func historyIsNewestFirstAndGlobalAcrossPrograms() {
        let repo = makeRepo()
        let a = repo.addProgram(Program(name: "Block A", createdAt: monday))
        let b = repo.addProgram(Program(name: "Block B", createdAt: monday))
        completeDeadlift(repo, seed(repo, date: monday, program: a.id), load: 100)
        completeDeadlift(repo, seed(repo, date: cal.date(byAdding: .day, value: 3, to: monday)!, program: b.id), load: 110)

        let h = repo.history(exerciseDefinitionID: "deadlift", limit: 10)
        #expect(h.count == 2)                                  // spans both programs
        #expect(h.first!.date > h.last!.date)                  // newest-first
        #expect(h.first?.sets.first?[.load] == 110)            // most recent session
        #expect(Set(h.map(\.programID)) == Set([a.id, b.id]))
    }

    @Test func unidentifiedExerciseNeverMergesIntoHistory() {
        let repo = makeRepo()
        let p = repo.addProgram(Program(name: "P", createdAt: monday))
        // A workout with an identified deadlift + an unnamed one-off (no definitionId).
        var known = PlannedExercise(exerciseName: "Deadlift", definitionId: "deadlift")
        known.prescription.sets = [PlannedSet(reps: 5, load: 100)]
        var oneOff = PlannedExercise(exerciseName: "Mystery Move")   // definitionId nil
        oneOff.prescription.sets = [PlannedSet(reps: 5)]
        let w = Workout(title: "Mixed", blocks: [WorkoutBlock(name: "", exercises: [known, oneOff], isDefault: true)])
        let sw = repo.addScheduled(ScheduledWorkout(programID: p.id, date: monday, origin: .userCreated,
                                                    workoutID: UUID(), workoutRevisionID: UUID(), workout: w))
        completeDeadlift(repo, sw, load: 100)

        #expect(repo.history(exerciseDefinitionID: "deadlift", limit: 10).count == 1)   // only the identified one
        // The one-off produced no queryable identity — no display-name bucket to merge into.
    }

    @Test func completedCollectionFiltersToCompletedOnly() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let a = seed(repo, date: monday, program: prog.id)
        _ = seed(repo, date: monday, program: prog.id)                 // B, left untouched
        repo.startSession(forScheduled: a.id, now: monday)
        _ = repo.completeSession(forScheduled: a.id, acknowledgingOpenWork: true, now: monday)

        let completed = repo.week(containing: monday, filter: .collection(.completed)).days.flatMap(\.sessions)
        #expect(completed.map(\.id) == [a.id])
        // Ad-hoc collection (origin-based) sees both; archived sees none.
        #expect(repo.week(containing: monday, filter: .collection(.adHoc)).days.flatMap(\.sessions).count == 2)
        #expect(repo.week(containing: monday, filter: .collection(.archived)).days.flatMap(\.sessions).isEmpty)
    }

    @Test func previousPerformanceReadsCompletedActualsByIdentity() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)          // exercise definitionId == "deadlift"
        let ex = sw.workout.allExercises.first!

        repo.startSession(forScheduled: sw.id, now: monday)
        repo.updateSessionLog(forScheduled: sw.id) { log in
            log.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName, plannedSetID: ex.prescription.sets[0].id) { s in
                s.values[.load] = 100; s.values.setInt(.reps, 5); s.completed = true
            }
        }
        _ = repo.completeSession(forScheduled: sw.id, acknowledgingOpenWork: true, now: monday)

        let prev = repo.mostRecentPerformance(exerciseDefinitionID: "deadlift", before: cal.date(byAdding: .day, value: 1, to: monday)!)
        #expect(prev?.sets.first?[.load] == 100)
        #expect(repo.mostRecentPerformance(exerciseDefinitionID: "deadlift", before: monday) == nil)   // strictly before
        #expect(repo.mostRecentPerformance(exerciseDefinitionID: "nonexistent", before: cal.date(byAdding: .day, value: 1, to: monday)!) == nil)
    }

    @Test func migratorSeedsTodaysScheduledWorkoutOnceWithoutWiping() {
        let repo = makeRepo()
        let plan = PlanStore(repo: repo, today: monday)
        let defaults = UserDefaults(suiteName: "mig-\(UUID().uuidString)")!
        let workouts = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
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
