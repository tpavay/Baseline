import Foundation
import Testing
@testable import Baseline

/// AC-5: the live `0x2A37` parse (`HeartRateSample.parse`) yields the right BPM + sensor contact,
/// and the existing reading parse (`HRV.parseMeasurement`) is unaffected by the same payloads.
///
/// The BLE connection lifecycle needs real hardware, so this pins the pure parse seam that the new
/// `.live` intent depends on; the full reading suite (HRVTests, ReadingSessionTests) staying green
/// proves the reading path is undisturbed.
struct BluetoothManagerLiveTests {

    // MARK: - BPM value format

    @Test func parsesUInt8BPM() {
        let sample = HeartRateSample.parse(Data([0x00, 72]))
        #expect(sample?.bpm == 72)
    }

    @Test func parsesUInt16BPM() {
        // flags bit0 = 1 → 16-bit little-endian; 0x012C = 300.
        let sample = HeartRateSample.parse(Data([0x01, 0x2C, 0x01]))
        #expect(sample?.bpm == 300)
    }

    // MARK: - Sensor contact (flags bits 1–2)

    @Test func sensorContactUnsupportedWhenFeatureBitClear() {
        let sample = HeartRateSample.parse(Data([0x00, 60]))
        #expect(sample?.sensorContact == .unsupported)
    }

    @Test func sensorContactDetected() {
        // bit2 (feature supported) + bit1 (contact detected) = 0x06.
        let sample = HeartRateSample.parse(Data([0x06, 60]))
        #expect(sample?.sensorContact == .detected)
    }

    @Test func sensorContactNotDetected() {
        // bit2 set, bit1 clear = 0x04.
        let sample = HeartRateSample.parse(Data([0x04, 60]))
        #expect(sample?.sensorContact == .notDetected)
    }

    // MARK: - Malformed payloads

    @Test func rejectsMalformedOrZeroPayloads() {
        #expect(HeartRateSample.parse(Data([])) == nil)
        #expect(HeartRateSample.parse(Data([0x00])) == nil)          // flags only, no BPM
        #expect(HeartRateSample.parse(Data([0x00, 0x00])) == nil)    // zero BPM
        #expect(HeartRateSample.parse(Data([0x01, 0x2C])) == nil)    // 16-bit flag, missing high byte
    }

    // MARK: - Reading path parity

    @Test func readingParsePathUnaffectedByLiveParse() {
        // The canonical reading fixture (HR uint8 + one R-R interval) still parses via HRV, and the
        // live parser extracts the same BPM without touching R-R semantics.
        let data = Data([0x10, 60, 0x00, 0x04])   // flags 0x10 (R-R present), HR 60, R-R 1024 → 1000 ms
        let reading = HRV.parseMeasurement(data)
        #expect(reading.hr == 60)
        #expect(reading.rrMs.count == 1)

        let live = HeartRateSample.parse(data)
        #expect(live?.bpm == 60)
        #expect(live?.sensorContact == .unsupported)   // bit2 clear in 0x10
    }
}
