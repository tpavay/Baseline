import Foundation
import Testing
@testable import Baseline

struct HRVTests {

    @Test func artifactCorrectionInterpolatesEctopicWithoutBiasing() {
        // Steady ~1000ms rhythm with one ectopic pair (short 500 then long 1500) — an artifact.
        let rr = [1000.0, 1010, 990, 1000, 500, 1500, 1000, 990, 1010, 1000]
        let (corrected, artifacts, quality) = HRV.corrected(rr)
        #expect(artifacts >= 1)
        // Correction pulls the huge inflated RMSSD back down toward the real ~10ms.
        #expect(HRV.rmssd(corrected)! < HRV.rmssd(rr)!)
        #expect(corrected.count == rr.count)         // beats preserved, not dropped
        _ = quality
    }

    @Test func cleanSeriesHasNoArtifactsAndGoodQuality() {
        let rr = [1000.0, 1010, 990, 1005, 995, 1000, 1008, 992]
        let (_, artifacts, quality) = HRV.corrected(rr)
        #expect(artifacts == 0)
        #expect(quality == .good)
    }

    @Test func manyArtifactsRatePoor() {
        // Alternating clean / wild → a large fraction flagged → Poor.
        let rr = (0..<20).map { $0 % 2 == 0 ? 1000.0 : 2200.0 }
        let (_, artifacts, quality) = HRV.corrected(rr)
        #expect(artifacts > 0)
        #expect(quality == .poor)
    }

    @Test func parsesUInt8HRWithOneRRInterval() {
        // flags 0x10 (R-R present, HR uint8), HR 60, R-R = 1024 (1/1024 s) → 1000 ms
        let data = Data([0x10, 60, 0x00, 0x04])
        let result = HRV.parseMeasurement(data)
        #expect(result.hr == 60)
        #expect(result.rrMs.count == 1)
        #expect(abs(result.rrMs[0] - 1000.0) < 0.001)
    }

    @Test func parsesUInt16HRAndMultipleRR() {
        // flags 0x11 (R-R present, HR uint16), HR 300, two R-R values (512, 1024) → 500ms, 1000ms
        let data = Data([0x11, 0x2C, 0x01, 0x00, 0x02, 0x00, 0x04])
        let result = HRV.parseMeasurement(data)
        #expect(result.hr == 300)
        #expect(result.rrMs.count == 2)
        #expect(abs(result.rrMs[0] - 500.0) < 0.001)
        #expect(abs(result.rrMs[1] - 1000.0) < 0.001)
    }

    @Test func skipsEnergyExpendedBeforeRR() {
        // flags 0x18 (energy expended + R-R, HR uint8), HR 55, energy 0x00F0, R-R 1024 → 1000ms
        let data = Data([0x18, 55, 0xF0, 0x00, 0x00, 0x04])
        let result = HRV.parseMeasurement(data)
        #expect(result.hr == 55)
        #expect(result.rrMs.count == 1)
        #expect(abs(result.rrMs[0] - 1000.0) < 0.001)
    }

    @Test func rmssdMatchesHandComputation() {
        // R-R [800, 850, 820, 840] → diffs [50, -30, 20] → squares [2500,900,400] → /3 → sqrt ≈ 35.59
        let rr = [800.0, 850.0, 820.0, 840.0]
        let r = try! #require(HRV.rmssd(rr))
        #expect(abs(r - 35.5903) < 0.001)
    }

    @Test func rmssdNeedsTwoIntervals() {
        #expect(HRV.rmssd([800.0]) == nil)
        #expect(HRV.rmssd([]) == nil)
    }

    @Test func cleanedDropsImplausibleIntervals() {
        let rr = [100.0, 800.0, 850.0, 3000.0]   // 100 and 3000 are out of [300, 2000]
        #expect(HRV.cleaned(rr) == [800.0, 850.0])
    }

    // MARK: - Mean RR / SDNN / pNN50

    @Test func meanRR() {
        #expect(HRV.meanRR([]) == nil)
        #expect(abs((HRV.meanRR([900, 1100]) ?? 0) - 1000) < 0.0001)
    }

    @Test func sdnnOfTwoBeats() {
        // mean 1000, variance = (200^2 + 200^2)/(2-1) = 80000 → sd ≈ 282.84
        let s = try! #require(HRV.sdnn([800, 1200]))
        #expect(abs(s - 282.842712) < 0.001)
        #expect(HRV.sdnn([1000]) == nil)
    }

    @Test func pnn50CountsLargeDifferences() {
        #expect(abs((HRV.pnn50([800, 1200]) ?? -1) - 100) < 0.0001)      // one diff > 50ms
        #expect(abs((HRV.pnn50([1000, 1000, 1000]) ?? -1) - 0) < 0.0001) // none > 50ms
        #expect(HRV.pnn50([1000]) == nil)
    }

    // MARK: - Readiness score (0–100 normalization of lnRMSSD)

    @Test func readinessScoreNormalizes() {
        #expect(HRV.readinessScore(lnRMSSD: 6.5) == 100)
        #expect(HRV.readinessScore(lnRMSSD: 3.25) == 50)
        #expect(HRV.readinessScore(lnRMSSD: 0) == 0)
    }

    @Test func readinessScoreClamps() {
        #expect(HRV.readinessScore(lnRMSSD: 10) == 100)   // above range → clamp 100
        #expect(HRV.readinessScore(lnRMSSD: -2) == 0)      // below range → clamp 0
    }
}
