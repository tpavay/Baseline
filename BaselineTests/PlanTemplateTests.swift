import Foundation
import SwiftData
import Testing
@testable import Baseline

/// Templates are **immutable reusable sources**: instantiating copies content into an independent
/// scheduled-workout revision (with attribution), and updating a template never touches workouts already
/// scheduled from it.
@Suite(.serialized) @MainActor
struct PlanTemplateTests {

    private func makeStore(today: Date = Date()) -> PlanStore {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(for: Schema(models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext), today: today)
    }
    private func work(_ t: String) -> Workout {
        var ex = PlannedExercise(exerciseName: "Squat", definitionId: "deadlift")
        ex.prescription.sets = [PlannedSet(reps: 5, load: 100)]
        return Workout(title: t, blocks: [WorkoutBlock(name: "", exercises: [ex], isDefault: true)])
    }

    @Test func instantiateCopiesIndependentlyWithAttribution() {
        let plan = makeStore()
        _ = plan.addProgram(Program(name: "P", createdAt: Date()))
        let t = plan.saveAsTemplate(name: "Threshold", from: work("Threshold"), tags: [.threshold])
        #expect(plan.template(named: "threshold")?.id == t.id)   // found by name, case-insensitive

        let sw = plan.instantiateTemplate(t.id, on: Date())!
        #expect(sw.workout.title == "Threshold")
        #expect(sw.templateID == t.id)                            // attribution
        #expect(sw.templateRevisionID == t.currentRevisionID)
        #expect(sw.workoutID != t.currentRevisionID)              // its own independent identity

        // Editing the instance never changes the template.
        plan.updateWorkout(sw.id) { $0.rename("My tweaked version") }
        #expect(plan.scheduledWorkout(sw.id)?.workout.title == "My tweaked version")
        #expect(plan.instantiateTemplate(t.id, on: Date())?.workout.title == "Threshold")   // template still pristine
    }

    @Test func updatingTemplateDoesNotTouchAlreadyScheduledWorkouts() {
        let plan = makeStore()
        _ = plan.addProgram(Program(name: "P", createdAt: Date()))
        let t = plan.saveAsTemplate(name: "T", from: work("V1"))
        let sw = plan.instantiateTemplate(t.id, on: Date())!
        let rev1 = t.currentRevisionID

        let t2 = plan.updateTemplate(t.id, from: work("V2"))!     // new template revision
        #expect(t2.currentRevisionID != rev1)

        // The already-scheduled workout is unchanged and still attributed to the OLD revision.
        #expect(plan.scheduledWorkout(sw.id)?.workout.title == "V1")
        #expect(plan.scheduledWorkout(sw.id)?.templateRevisionID == rev1)

        // A fresh instantiation uses the new revision.
        let sw2 = plan.instantiateTemplate(t.id, on: Date())!
        #expect(sw2.workout.title == "V2")
        #expect(sw2.templateRevisionID == t2.currentRevisionID)
    }

    @Test func instantiationIsVersionedAndUndoable() {
        let plan = makeStore()
        _ = plan.addProgram(Program(name: "P", createdAt: Date()))
        let t = plan.saveAsTemplate(name: "T", from: work("W"))
        let sw = plan.instantiateTemplate(t.id, on: Date())!
        #expect(plan.scheduledWorkout(sw.id) != nil)
        #expect(plan.undo().isApplied)
        #expect(plan.scheduledWorkout(sw.id) == nil)
    }

    @Test func agentToolsSaveRefuseDuplicateAndCreateFromTemplate() {
        let plan = makeStore(today: mon)
        _ = plan.addProgram(Program(name: "P", createdAt: mon))
        // Bind a today workout so save_as_template has something to save.
        plan.addScheduled(ScheduledWorkout(programID: plan.programs()[0].id, date: mon, origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: work("Threshold")))
        let store = WorkoutStore(defaults: UserDefaults(suiteName: "tpl-\(UUID().uuidString)")!)
        store.bind(plan.sink(forScheduled: plan.todayScheduled(mon)!.id), coalesceContent: false)
        let tools = AgentTools(store: TrainingContextStore(), workouts: store, plan: plan)

        #expect(tools.dispatch(.saveAsTemplate(name: "Threshold")).text.contains("Saved"))
        #expect(tools.dispatch(.saveAsTemplate(name: "Threshold")).text.contains("already exists"))   // refuses dup
        let out = tools.dispatch(.createFromTemplate(name: "threshold", day: "Wednesday")).text
        #expect(out.contains("Added"))
        let wed = plan.week.days.first { cal.isDate($0.date, inSameDayAs: cal.date(byAdding: .day, value: 2, to: mon)!) }
        #expect(wed?.sessions.contains { $0.workout.title == "Threshold" } == true)
    }

    private let cal = Calendar.planWeek
    private var mon: Date { cal.weekStart(for: Date(timeIntervalSince1970: 1_752_000_000)) }
}
