import Foundation

/// The **single recompute path** — the one place base evidence (HRV/RHR/sleep/check-in) is merged
/// with the Context Engine's structured state (constraints + daily context) and run through the
/// Decision + Planning engines. Both the morning reveal and the chat's `recompute` tool call this,
/// so there's one source of truth for "today's plan." Pure and testable: the caller supplies the
/// base `DecisionEngine.Inputs` (from the reading + Health); this layers context on top.
enum PlanAssembler {
    static func assemble(
        base: DecisionEngine.Inputs,
        dailyContext: TrainingContextStore.DailyContext = .init(),
        constraints: [DecisionEngine.Constraint] = [],
        style: PlanningEngine.Style = .balanced
    ) -> (decision: DecisionEngine.Result, plan: PlanningEngine.Plan) {
        var inputs = base
        inputs.constraints = constraints
        inputs.illness = dailyContext.illness ?? inputs.illness
        let decision = DecisionEngine.compute(inputs)
        let daily = PlanningEngine.DailyFactors(
            timeAvailableMinutes: dailyContext.timeAvailableMinutes,
            traveling: dailyContext.traveling,
            limitedEquipment: limitedEquipment(dailyContext.equipment)
        )
        let plan = PlanningEngine.plan(for: decision, daily: daily, style: style)
        return (decision, plan)
    }

    /// A listed equipment set with nothing gym-grade → limited. Unknown (nil/empty) → no claim.
    private static func limitedEquipment(_ equipment: [String]?) -> Bool? {
        guard let eq = equipment, !eq.isEmpty else { return nil }
        let gym: Set<String> = ["gym", "full gym", "commercial gym", "barbell", "rack", "squat rack",
                                "machine", "machines", "dumbbells", "sled", "skierg", "cable"]
        let hasGym = eq.contains { gym.contains($0.lowercased()) }
        return hasGym ? false : true
    }
}
