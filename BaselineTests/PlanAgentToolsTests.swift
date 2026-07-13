import Foundation
import SwiftData
import Testing
@testable import Baseline

/// Slice 4: the week-plan agent tools resolve workouts by name (ambiguity-aware) and route to the same
/// versioned repository mutations as the manual UI — no separate write path.
@Suite(.serialized) @MainActor
struct PlanAgentToolsTests {

    private func makeStore() -> PlanStore {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(for: Schema(models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext), today: mon)
    }
    private let cal = Calendar.planWeek
    private var mon: Date { cal.weekStart(for: Date(timeIntervalSince1970: 1_752_000_000)) }
    private func day(_ o: Int) -> Date { cal.date(byAdding: .day, value: o, to: mon)! }
    private func work(_ t: String) -> Workout { Workout(title: t, blocks: [WorkoutBlock(name: "", isDefault: true)]) }

    private func seed(_ plan: PlanStore, _ title: String, on date: Date, program: UUID) {
        plan.addScheduled(ScheduledWorkout(programID: program, date: date, origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: work(title)))
    }
    private func tools(_ plan: PlanStore) -> AgentTools { AgentTools(store: TrainingContextStore(), plan: plan) }

    @Test func getWeekPlanListsScheduledWorkouts() {
        let plan = makeStore(); let p = plan.addProgram(Program(name: "P", createdAt: mon))
        seed(plan, "Threshold Run", on: mon, program: p.id)
        seed(plan, "Recovery Ride", on: day(2), program: p.id)
        let out = tools(plan).dispatch(.getWeekPlan).text
        #expect(out.contains("Threshold Run"))
        #expect(out.contains("Recovery Ride"))
    }

    @Test func moveByNameRoutesThroughVersionedMutation() {
        let plan = makeStore(); let p = plan.addProgram(Program(name: "P", createdAt: mon))
        seed(plan, "Threshold Run", on: mon, program: p.id)
        let out = tools(plan).dispatch(.moveWorkout(workout: "threshold", toDay: "Thursday")).text
        #expect(out.contains("Moved"))
        let thursday = plan.week.days.first { cal.isDate($0.date, inSameDayAs: day(3)) }
        #expect(thursday?.sessions.first?.workout.title == "Threshold Run")
        #expect(plan.versions(limit: 9).count == 2)   // genesis + move
    }

    @Test func ambiguousNameAsksInsteadOfGuessing() {
        let plan = makeStore(); let p = plan.addProgram(Program(name: "P", createdAt: mon))
        seed(plan, "Threshold Run", on: mon, program: p.id)
        seed(plan, "Threshold Run", on: day(1), program: p.id)
        let out = tools(plan).dispatch(.moveWorkout(workout: "Threshold Run", toDay: "Friday")).text
        #expect(out.lowercased().contains("more than one"))
        // Nothing moved to Friday.
        #expect(plan.week.days.first { self.cal.isDate($0.date, inSameDayAs: day(4)) }?.sessions.isEmpty == true)
    }

    @Test func deleteToolIsConfirmationGated() {
        let plan = makeStore(); let p = plan.addProgram(Program(name: "P", createdAt: mon))
        seed(plan, "Recovery Ride", on: mon, program: p.id)
        let first = tools(plan).dispatch(.deleteWorkout(workout: "recovery", proposalID: nil)).text
        #expect(first.contains("proposal_id"))
        #expect(plan.week.days.flatMap(\.sessions).count == 1)   // not deleted yet
    }
}
