import Foundation
import Testing
@testable import Baseline

struct HRVTests {

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
}
