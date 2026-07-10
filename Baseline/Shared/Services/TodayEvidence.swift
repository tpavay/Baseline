import Foundation

/// Assembles today's **base evidence** for the agent — the automatic/manual signals (HRV/RHR from
/// the latest morning reading + personal baselines, Apple Health sleep, and the check-in from today's
/// entry). The chat layers structured context (constraints, time, travel) on top of this via
/// `PlanAssembler`. Kept separate so `AgentTools.base` has one honest source.
enum TodayEvidence {
    @MainActor
    static func baseInputs(readings: [Reading], todayEntry: ReadinessEntry?, health: HealthService) async -> DecisionEngine.Inputs {
        var inputs = DecisionEngine.Inputs()

        // Autonomic evidence must be *today's* morning read — never a snapshot or yesterday's
        // reading dressed up as current state. If there's no morning reading today, the autonomic
        // domain is simply absent (honest lower certainty), not stale. Baselines are single-source
        // (mixing camera + strap corrupts them), so score only against prior mornings from the same
        // source — matching DailyReadingFlowView.
        if let latest = readings.first(where: { $0.kind == .morning && Calendar.current.isDateInToday($0.date) }) {
            let priorMornings = readings.filter {
                $0.kind == .morning
                    && !Calendar.current.isDateInToday($0.date)
                    && $0.source == latest.source
            }
            inputs.lnRMSSD = latest.lnRMSSD
            inputs.restingHR = latest.meanHR
            inputs.hrvBaseline = ReadinessScore.baseline(from: priorMornings.map(\.lnRMSSD))
            inputs.rhrBaseline = ReadinessScore.baseline(from: priorMornings.map(\.meanHR))
        }

        if let sleep = await health.lastNightSleep() {
            inputs.sleepScore = ReadinessScore.sleepScore(hours: sleep.hours, efficiency: sleep.efficiency)
            inputs.sleepHours = sleep.hours
        }

        if let e = todayEntry {
            inputs.energy = e.energy
            inputs.mood = e.mood
            inputs.stress = e.stress
            inputs.soreness = e.soreness
        }
        return inputs
    }
}
