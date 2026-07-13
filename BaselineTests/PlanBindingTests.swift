import Foundation
import SwiftData
import Testing
@testable import Baseline

/// The two integration seams: the shared `WorkoutStore` (agent editing surface) and the Plan-execution
/// buffer both write through to the Plan repository via a `PlanSink` — one mutation path, no divergence.
@MainActor
struct PlanBindingTests {

    private func makeStore() -> PlanStore {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(for: Schema(models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))
    }
    private func work(_ t: String) -> Workout {
        var ex = PlannedExercise(exerciseName: "Squat", definitionId: "deadlift")
        ex.prescription.sets = [PlannedSet(reps: 5, load: 100)]
        return Workout(title: t, blocks: [WorkoutBlock(name: "", exercises: [ex], isDefault: true)])
    }
    private func buffer() -> WorkoutStore { WorkoutStore(defaults: UserDefaults(suiteName: "bind-\(UUID().uuidString)")!) }

    @Test func agentBoundStoreWriteThroughsContentAndLifecycleToThePlan() {
        let plan = makeStore()
        let p = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: p.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: work("W")))
        let sw = plan.todayScheduled()!
        let store = buffer()
        store.bind(plan.sink(forScheduled: sw.id), coalesceContent: false)   // agent mode — immediate

        #expect(store.current?.title == "W")
        // A content edit becomes a new revision in the plan (immediately).
        store.edit { $0.rename("W2") }
        #expect(plan.scheduledWorkout(sw.id)?.workout.title == "W2")

        // Start + log flow to the plan's session, not a local-only log.
        store.startWorkout()
        #expect(plan.session(for: sw.id) != nil)
        let ex = store.current!.allExercises.first!
        store.editLog { $0.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName, plannedSetID: ex.prescription.sets[0].id) { s in
            s.values[.load] = 105; s.completed = true
        } }
        #expect(plan.session(for: sw.id)?.log.performed(forPlanned: ex.id)?.setLogs.first?.values[.load] == 105)
    }

    @Test func manualExecutionCoalescesContentUntilFlushButLogsLive() {
        let plan = makeStore()
        let p = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: p.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: work("W")))
        let sw = plan.todayScheduled()!
        let store = buffer()
        store.bind(plan.sink(forScheduled: sw.id), coalesceContent: true)    // manual editor — coalesced

        store.edit { $0.rename("Edited") }
        #expect(plan.scheduledWorkout(sw.id)?.workout.title == "W")          // not written through yet
        store.flush()
        #expect(plan.scheduledWorkout(sw.id)?.workout.title == "Edited")     // one revision on flush

        // Logging still writes through live (only content is coalesced).
        store.startWorkout()
        let ex = store.current!.allExercises.first!
        store.editLog { $0.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName, plannedSetID: ex.prescription.sets[0].id) { $0.completed = true } }
        #expect(plan.session(for: sw.id)?.log.performed(forPlanned: ex.id)?.setLogs.first?.completed == true)
    }

    @Test func manualAddWorkoutCreatesAnEmptyVersionedWorkoutOnThatDay() {
        let plan = makeStore()
        let sw = plan.newScheduledWorkout(on: Date(), title: "New workout")   // the timeline "+ Add workout" flow
        #expect(plan.todayScheduled()?.id == sw.id)
        #expect(plan.todayScheduled()?.workout.blocks.first?.isDefault == true)   // ready for exercises
        // Versioned + undoable.
        #expect(plan.undo().isApplied)
        #expect(plan.todayScheduled() == nil)
    }

    @Test func createWithFactoryLandsANewWorkoutInThePlan() {
        let plan = makeStore()
        let store = buffer()
        store.makeTodayScheduled = { w in plan.addTodayScheduled(workout: w) }
        #expect(plan.todayScheduled() == nil)

        store.create(title: "Fresh session", goal: nil)
        #expect(plan.todayScheduled()?.workout.title == "Fresh session")     // created in the plan, not just locally

        // And subsequent edits write through to that same scheduled workout.
        store.edit { $0.updateGoal("easy") }
        #expect(plan.todayScheduled()?.workout.goal == "easy")
    }
}
