import Foundation
import Testing
@testable import Baseline

private typealias DE = DecisionEngine
private typealias Seam = SleepDecisionSeam

/// Slice 4 (issue #7) AC-5 (seam-off byte-identical parity, the headline guarantee) and AC-6 (seam-on
/// wiring + conversation override still wins). The seam is pure and shared by both call sites, so
/// pinning it here proves both `TodayEvidence.baseInputs` and `MorningReadinessScoreView.compute()`.
struct MorningReadinessParityTests {

    // The EXACT pre-slice sleep ladders, transcribed from the code as it stood before this slice.
    // The seam must reproduce these bit-for-bit when no provider is present.

    /// `TodayEvidence` had only the automatic Health branch (no manual fallback).
    private func legacyTodayEvidence(health: Seam.HealthSleep?) -> Seam.Result {
        if let health {
            return Seam.Result(sleepScore: ReadinessScore.sleepScore(hours: health.hours, efficiency: health.efficiency),
                               sleepHours: health.hours)
        }
        return Seam.Result()
    }

    /// `MorningReadinessScoreView.compute` had Health → manual hours → thumb.
    private func legacyMorning(health: Seam.HealthSleep?, manualHours: Double?, thumbsUp: Bool?) -> Seam.Result {
        if let health {
            return Seam.Result(sleepScore: ReadinessScore.sleepScore(hours: health.hours, efficiency: health.efficiency),
                               sleepHours: health.hours)
        } else if let manualHours {
            return Seam.Result(sleepScore: ReadinessScore.sleepScore(hours: manualHours), sleepHours: manualHours)
        } else if let thumbsUp {
            return Seam.Result(sleepScore: thumbsUp ? 85 : 35)
        }
        return Seam.Result()
    }

    // MARK: - AC-5: seam-off byte-identical (TodayEvidence shape)

    @Test func todayEvidenceParityWithHealth() {
        let health = Seam.HealthSleep(hours: 7.5, efficiency: 0.9)
        let seam = Seam.resolve(.legacy(health), manual: .none)
        #expect(seam == legacyTodayEvidence(health: health))
        // And the new structured fields stay nil so DecisionEngine.Inputs is unchanged.
        #expect(seam.sleepConfidence == nil && seam.sleepDurationDeficit == nil)
        #expect(seam.sleepInterruptionBurden == nil && seam.sleepScheduleShift == nil)
        #expect(seam.snapshot == nil)
    }

    @Test func todayEvidenceParityNoSleep() {
        #expect(Seam.resolve(.legacy(nil), manual: .none) == legacyTodayEvidence(health: nil))
    }

    // MARK: - AC-5: seam-off byte-identical (morning flow shape, all fixtures)

    @Test func morningParityWithHealth() {
        let health = Seam.HealthSleep(hours: 6.4, efficiency: nil)
        let manual = Seam.ManualSleep(hours: 9.0, thumbsUp: true)   // present but must be ignored — Health wins
        #expect(Seam.resolve(.legacy(health), manual: manual) == legacyMorning(health: health, manualHours: 9.0, thumbsUp: true))
    }

    @Test func morningParityManualHours() {
        let manual = Seam.ManualSleep(hours: 5.0, thumbsUp: true)
        #expect(Seam.resolve(.legacy(nil), manual: manual) == legacyMorning(health: nil, manualHours: 5.0, thumbsUp: true))
    }

    @Test func morningParityThumb() {
        let up = Seam.resolve(.legacy(nil), manual: .init(hours: nil, thumbsUp: true))
        let down = Seam.resolve(.legacy(nil), manual: .init(hours: nil, thumbsUp: false))
        #expect(up == legacyMorning(health: nil, manualHours: nil, thumbsUp: true))
        #expect(down == legacyMorning(health: nil, manualHours: nil, thumbsUp: false))
        #expect(up.sleepScore == 85 && down.sleepScore == 35)
        #expect(up.sleepHours == nil)   // thumb sets no hours — matches pre-slice
    }

    @Test func morningParityNoSleep() {
        #expect(Seam.resolve(.legacy(nil), manual: .none) == legacyMorning(health: nil, manualHours: nil, thumbsUp: nil))
    }

    // MARK: - AC-5: TodayEvidence.baseInputs seam-off leaves the new fields untouched

    @MainActor
    @Test func baseInputsSeamOffHasNilStructuredSleep() async {
        // No provider, empty HealthService → sleep absent; the new structured fields must be nil so
        // the decision inputs are byte-identical to pre-slice.
        let inputs = await TodayEvidence.baseInputs(readings: [], todayEntry: nil, health: HealthService())
        #expect(inputs.sleepScore == nil)
        #expect(inputs.sleepConfidence == nil)
        #expect(inputs.sleepDurationDeficit == nil)
        #expect(inputs.sleepInterruptionBurden == nil)
        #expect(inputs.sleepScheduleShift == nil)
    }

    // MARK: - AC-6: seam-on uses engine inputs

    @Test func seamOnUsesEngineInputs() {
        let engine = SleepDecisionInputs(analysis: TestSleepAnalysis.make(score: 82, coverage: 0.95, reliability: 1.0,
                                                                          asleepHours: 6.5, deficit: 1.5, burden: 0.3, shift: 40))
        let result = Seam.resolve(.engine(engine), manual: .init(hours: 9.0, thumbsUp: true))   // manual ignored
        #expect(result.sleepScore == 82)
        #expect(result.sleepHours == 6.5)
        #expect(result.sleepConfidence == 1.0)
        #expect(result.sleepDurationDeficit == 1.5)
        #expect(result.sleepInterruptionBurden == 0.3)
        #expect(result.sleepScheduleShift == 40)
        #expect(result.snapshot != nil)   // snapshot captured for ReadinessEntry
    }

    // MARK: - AC-6: conversation sleep override still wins

    @Test func conversationOverrideBeatsEngineBaseAndReturnsToManualCapPath() {
        // A seam-on engine base with a large deficit that WOULD cap readiness at poorSleep.
        let engine = SleepDecisionInputs(analysis: TestSleepAnalysis.make(score: 40, coverage: 0.95, reliability: 1.0,
                                                                          asleepHours: 4.0, deficit: 4.0, burden: 0.6, shift: 120))
        var base = DE.Inputs()
        base.applySleep(Seam.resolve(.engine(engine), manual: .none))

        // Without an override, the structured deficit binds the poorSleep cap.
        let capped = DE.compute(base)
        #expect(capped.appliedCaps.contains { $0.reason == "poorSleep" })

        // The athlete reports 8 h in conversation → PlanAssembler override wins: sleepHours 8, deficit
        // cleared, so the cap no longer fires — exactly as the pre-slice manual override behaved.
        let (overridden, _) = PlanAssembler.assemble(base: base, dailyContext: .init(sleepHours: 8.0))
        #expect(!overridden.appliedCaps.contains { $0.reason == "poorSleep" })
    }
}
