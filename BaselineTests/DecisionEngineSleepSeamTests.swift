import Foundation
import Testing
@testable import Baseline

private typealias DE = DecisionEngine

/// Slice 4 (issue #7) additions to the decision engine — kept in a NEW file so the pre-existing
/// `DecisionEngineTests` stay byte-for-byte untouched (they are the AC-1 "existing suite green"
/// evidence). Covers AC-1 (new fields default-neutral), AC-2 (deficit-based `poorSleep` cap equals the
/// legacy hours cap, no double cap), AC-3 (certainty quality gating).
struct DecisionEngineSleepSeamTests {

    // MARK: - AC-1: new fields are default-neutral

    @Test func omittingNewSleepFieldsIsIdenticalToPreSlice() {
        // Same inputs, once without and once with the new fields explicitly nil → identical Result.
        let baseline = DE.compute(DE.Inputs(lnRMSSD: 4.0, sleepScore: 80, sleepHours: 7.0, energy: 4))
        let explicitNil = DE.compute(DE.Inputs(lnRMSSD: 4.0, sleepScore: 80, sleepHours: 7.0,
                                               sleepConfidence: nil, sleepDurationDeficit: nil,
                                               sleepInterruptionBurden: nil, sleepScheduleShift: nil,
                                               energy: 4))
        #expect(baseline == explicitNil)
    }

    @Test func burdenAndShiftNeverMoveTheScore() {
        // Carried for the snapshot/Slice-5 narration only — they must not alter compute in Slice 4.
        let plain = DE.compute(DE.Inputs(sleepScore: 80, sleepHours: 7.0))
        let loaded = DE.compute(DE.Inputs(sleepScore: 80, sleepHours: 7.0,
                                          sleepInterruptionBurden: 0.9, sleepScheduleShift: 180))
        #expect(plain == loaded)
    }

    // MARK: - AC-2: deficit cap == legacy cap, no double cap

    @Test func deficitCapMatchesLegacyHoursCap() {
        // Legacy path: sleepHours 4.0 (< 4.5) fires the poorSleep cap at 55.
        let legacy = DE.compute(DE.Inputs(sleepScore: 40, sleepHours: 4.0))
        #expect(legacy.appliedCaps.contains { $0.reason == "poorSleep" && $0.cap == 55 })

        // Seam path: a structured deficit ≥ threshold fires the SAME cap. With both a deficit and the
        // (still-short) sleepHours present, the cap must fire exactly ONCE — the deficit path wins and
        // the legacy hours path is suppressed (no double cap).
        let seam = DE.compute(DE.Inputs(sleepScore: 40, sleepHours: 4.0, sleepDurationDeficit: 4.0))
        let poor = seam.appliedCaps.filter { $0.reason == "poorSleep" }
        #expect(poor.count == 1)
        #expect(poor.first?.cap == 55)
        #expect(seam.score == legacy.score)   // identical binding outcome
    }

    @Test func deficitBelowThresholdSuppressesTheLegacyHoursCap() {
        // deficit 3.0 (< 3.5) → no cap. Crucially, the legacy `sleepHours 4.0 < 4.5` rule must NOT
        // fire either, because a non-nil deficit means the seam owns the cap decision (the XOR).
        let r = DE.compute(DE.Inputs(sleepScore: 70, sleepHours: 4.0, sleepDurationDeficit: 3.0))
        #expect(!r.appliedCaps.contains { $0.reason == "poorSleep" })
    }

    @Test func deficitAtThresholdCaps() {
        let r = DE.compute(DE.Inputs(sleepScore: 50, sleepHours: 5.0, sleepDurationDeficit: 3.5))
        #expect(r.appliedCaps.contains { $0.reason == "poorSleep" && $0.cap == 55 })
    }

    // MARK: - AC-3: certainty quality gating

    // Three certainty points are earned from energy (subjective) + loadRatio, plus sleep when it
    // counts. No HRV baseline → calibrating → no baseline point. So sleep is the pivot between
    // low (2 pts) and medium (3 pts): the gate is directly observable.

    @Test func sleepCountsTowardCertaintyWhenQualityClearsBar() {
        let r = DE.compute(DE.Inputs(sleepScore: 80, sleepConfidence: 1.0, energy: 4, loadRatio: 1.0))
        #expect(r.certainty == .medium)
    }

    @Test func sleepDoesNotCountBelowQualityBar() {
        let r = DE.compute(DE.Inputs(sleepScore: 80, sleepConfidence: 0.0, energy: 4, loadRatio: 1.0))
        #expect(r.certainty == .low)   // sleep present but gated out → only 2 points
    }

    @Test func confidenceAtBarInclusive() {
        let r = DE.compute(DE.Inputs(sleepScore: 80, sleepConfidence: 0.5, energy: 4, loadRatio: 1.0))
        #expect(r.certainty == .medium)   // exactly at the 0.5 bar → counts (≥)
    }

    @Test func legacyNilConfidencePreservesPreSliceCertainty() {
        // Seam off: a present sleep score counts, exactly as before Slice 4.
        let r = DE.compute(DE.Inputs(sleepScore: 80, energy: 4, loadRatio: 1.0))
        #expect(r.certainty == .medium)
    }
}
