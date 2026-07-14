import Foundation

/// Assembles today's **base evidence** for the agent — the automatic/manual signals (HRV/RHR from
/// the latest morning reading + personal baselines, Apple Health sleep, and the check-in from today's
/// entry). The chat layers structured context (constraints, time, travel) on top of this via
/// `PlanAssembler`. Kept separate so `AgentTools.base` has one honest source.
enum TodayEvidence {
    /// `sleepProvider` is the Sleep Engine seam (Slice 4), defaulted to nil so every app construction
    /// site stays on the legacy path and this stays byte-identical to pre-slice (AC-5). `referenceDate`
    /// is the recovery day the provider is queried for; unused on the legacy path.
    @MainActor
    static func baseInputs(readings: [Reading], todayEntry: ReadinessEntry?, health: HealthService,
                           sleepProvider: SleepEvidenceProvider? = nil,
                           referenceDate: Date = .now) async -> DecisionEngine.Inputs {
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

        // Sleep seam. Provider nil (every app call site today) → the exact pre-slice Health path via
        // `SleepDecisionSeam.resolve(.legacy:)`; provider present → engine-sourced inputs (AC-5/AC-6).
        // `TodayEvidence` has no manual check-in fallback, so `.none` manual is passed either way.
        let sleepResult: SleepDecisionSeam.Result
        if let sleepProvider {
            sleepResult = SleepDecisionSeam.resolve(.engine(sleepProvider.sleepInputs(on: referenceDate)), manual: .none)
        } else {
            let health = await health.lastNightSleep().map {
                SleepDecisionSeam.HealthSleep(hours: $0.hours, efficiency: $0.efficiency)
            }
            sleepResult = SleepDecisionSeam.resolve(.legacy(health), manual: .none)
        }
        inputs.applySleep(sleepResult)

        if let e = todayEntry {
            inputs.energy = e.energy
            inputs.mood = e.mood
            inputs.stress = e.stress
            inputs.soreness = e.soreness
        }
        return inputs
    }
}
