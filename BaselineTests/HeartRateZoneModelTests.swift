import Foundation
import Testing
@testable import Baseline

/// AC-2/AC-3/AC-4: pure zone boundaries (Karvonen + %max), position monotonicity/consistency, and
/// max-HR derivation (Tanaka + user override + age bounds). All thresholds are hand-computed.
struct HeartRateZoneModelTests {

    // MARK: - AC-2: %max boundaries

    /// maxHR 200, no resting → %max. Lower bounds: 100 / 120 / 140 / 160 / 180.
    @Test func percentMaxBoundaries() {
        let model = HeartRateZoneModel(maxHR: 200)
        #expect(model.method == .percentMax)
        #expect(model.zone(forBPM: 90) == .z1)     // below Z1 bottom still Z1 (clamped)
        #expect(model.zone(forBPM: 100) == .z1)
        #expect(model.zone(forBPM: 119) == .z1)
        #expect(model.zone(forBPM: 120) == .z2)    // exact divider is the zone's inclusive floor
        #expect(model.zone(forBPM: 139) == .z2)
        #expect(model.zone(forBPM: 140) == .z3)
        #expect(model.zone(forBPM: 159) == .z3)
        #expect(model.zone(forBPM: 160) == .z4)
        #expect(model.zone(forBPM: 179) == .z4)
        #expect(model.zone(forBPM: 180) == .z5)
        #expect(model.zone(forBPM: 220) == .z5)    // above max still Z5
    }

    /// maxHR 185 → fractional %max thresholds (129.5, 166.5) exercise the Double-boundary compare.
    /// Lower bounds: 111 / 129.5 / 148 / 166.5.
    @Test func percentMaxBoundariesWithNonRoundThresholds() {
        let model = HeartRateZoneModel(maxHR: 185)
        #expect(model.zone(forBPM: 110) == .z1)
        #expect(model.zone(forBPM: 111) == .z2)
        #expect(model.zone(forBPM: 129) == .z2)    // 129 < 129.5
        #expect(model.zone(forBPM: 130) == .z3)    // 130 ≥ 129.5
        #expect(model.zone(forBPM: 147) == .z3)
        #expect(model.zone(forBPM: 148) == .z4)
        #expect(model.zone(forBPM: 166) == .z4)    // 166 < 166.5
        #expect(model.zone(forBPM: 167) == .z5)    // 167 ≥ 166.5
    }

    // MARK: - AC-2: Karvonen / HRR boundaries

    /// maxHR 190, resting 50 → reserve 140. target = 50 + f·140.
    /// Lower bounds: 120 / 134 / 148 / 162 / 176.
    @Test func karvonenBoundaries() {
        let model = HeartRateZoneModel(maxHR: 190, restingHR: 50)
        #expect(model.method == .heartRateReserve)
        #expect(model.zone(forBPM: 60) == .z1)     // below reserve floor still Z1
        #expect(model.zone(forBPM: 133) == .z1)
        #expect(model.zone(forBPM: 134) == .z2)
        #expect(model.zone(forBPM: 147) == .z2)
        #expect(model.zone(forBPM: 148) == .z3)
        #expect(model.zone(forBPM: 161) == .z3)
        #expect(model.zone(forBPM: 162) == .z4)
        #expect(model.zone(forBPM: 175) == .z4)
        #expect(model.zone(forBPM: 176) == .z5)
        #expect(model.zone(forBPM: 190) == .z5)
    }

    @Test func restingHRSelectsKarvonenOverPercentMax() {
        // Same max, same BPM, different method → different zone. 130 is Z2 on %max (÷200 = 0.65)
        // but Z1 on HRR (needs ≥134). Proves the model actually switches formula on restingHR.
        #expect(HeartRateZoneModel(maxHR: 190).zone(forBPM: 130) == .z2)
        #expect(HeartRateZoneModel(maxHR: 190, restingHR: 50).zone(forBPM: 130) == .z1)
    }

    // MARK: - AC-3: position

    @Test func positionSpansZeroToOneClampedAtEnds() {
        let model = HeartRateZoneModel(maxHR: 200)   // span [100, 200]
        #expect(abs(model.position(forBPM: 100) - 0.0) < 1e-9)
        #expect(abs(model.position(forBPM: 150) - 0.5) < 1e-9)
        #expect(abs(model.position(forBPM: 200) - 1.0) < 1e-9)
        #expect(model.position(forBPM: 80) == 0.0)   // below span → clamp 0
        #expect(model.position(forBPM: 260) == 1.0)  // above span → clamp 1
    }

    @Test func positionIsMonotonic() {
        let model = HeartRateZoneModel(maxHR: 190, restingHR: 50)
        let bpms = [110, 120, 130, 140, 150, 160, 170, 180, 190]
        let positions = bpms.map { model.position(forBPM: $0) }
        for i in 1..<positions.count {
            #expect(positions[i] >= positions[i - 1])
        }
    }

    /// The position bucket `floor(position·5)` must resolve to the same zone as `zone(forBPM:)`
    /// for any BPM strictly inside a zone — both %max and Karvonen.
    @Test func positionBucketMatchesZone() {
        func bucketZone(_ p: Double) -> HeartRateZone {
            let index = min(Int((p * 5).rounded(.down)), 4)
            return HeartRateZone.allCases[index]
        }
        let models = [HeartRateZoneModel(maxHR: 200),
                      HeartRateZoneModel(maxHR: 190, restingHR: 50)]
        // BPMs chosen strictly inside zones (never on a divider) for both models.
        let bpms = [110, 130, 155, 170, 185]
        for model in models {
            for bpm in bpms {
                #expect(bucketZone(model.position(forBPM: bpm)) == model.zone(forBPM: bpm))
            }
        }
    }

    // MARK: - AC-4: max-HR derivation

    @Test func tanakaFromAge() {
        #expect(HeartRateZoneModel(age: 30).maxHR == 187)   // 208 − 21
        #expect(HeartRateZoneModel(age: 40).maxHR == 180)   // 208 − 28
        #expect(HeartRateZoneModel(age: 45).maxHR == 177)   // 208 − 31.5 → 176.5 → 177
    }

    @Test func nilAgeUsesFallback35() {
        #expect(HeartRateZoneModel(age: nil).maxHR == 184)  // 208 − 24.5 → 183.5 → 184
    }

    @Test func ageIsBounded() {
        #expect(HeartRateZoneModel(age: 5).maxHR == 199)    // clamp to 13 → 208 − 9.1 → 198.9 → 199
        #expect(HeartRateZoneModel(age: 200).maxHR == 124)  // clamp to 120 → 208 − 84
    }

    @Test func explicitMaxOverridesTanaka() {
        // Age would give 187; an explicit tested max wins and is never overwritten by the estimate.
        #expect(HeartRateZoneModel(maxHR: 195).maxHR == 195)
        #expect(HeartRateZoneModel(maxHR: 195).method == .percentMax)
        #expect(HeartRateZoneModel(maxHR: 195, restingHR: 48).method == .heartRateReserve)
    }
}
