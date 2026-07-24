import Foundation
import Testing
@testable import Baseline

/// AC-5: the live `0x2A37` parse (`HeartRateSample.parse`) yields the right BPM + sensor contact,
/// and the existing reading parse (`HRV.parseMeasurement`) is unaffected by the same payloads.
///
/// The BLE connection lifecycle needs real hardware, so this pins the pure parse seam that the new
/// `.live` intent depends on; the full reading suite (HRVTests, ReadingSessionTests) staying green
/// proves the reading path is undisturbed.
@MainActor
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

    // MARK: - Routing decision (the AC-5 safety property)

    /// Only `.live` streams to the live ingest; every other intent stays on the reading path. This
    /// is the mutation killer: routing `.live` to reading would feed BPM notifications into the
    /// R-R/HRV accumulator.
    @Test func routeMapsOnlyLiveToLive() {
        #expect(BluetoothManager.route(for: .live) == .live)
        #expect(BluetoothManager.route(for: .reading) == .reading)
        #expect(BluetoothManager.route(for: .scan) == .reading)
        #expect(BluetoothManager.route(for: .idle) == .reading)
    }

    /// Transition seam: a `.live` payload sequence must never touch the reading accumulator, and a
    /// subsequent `.reading` payload must land cleanly on the R-R path.
    @Test func liveRoutingDoesNotCorruptReadingState() {
        let bt = BluetoothManager()

        bt.ingestHRMeasurement(Data([0x06, 72]), intent: .live)   // detected, 72
        bt.ingestHRMeasurement(Data([0x00, 80]), intent: .live)   // 80
        #expect(bt.liveSample?.bpm == 80)
        #expect(bt.rrIntervals.isEmpty)          // reading R-R accumulator never saw live payloads
        #expect(bt.rmssd == nil)
        #expect(bt.lnRmssd == nil)
        #expect(bt.currentHR == 0)               // reading HR untouched by the live stream

        // Now a genuine reading payload (HR 60 + one R-R = 1000 ms) on the reading path.
        bt.ingestHRMeasurement(Data([0x10, 60, 0x00, 0x04]), intent: .reading)
        #expect(bt.currentHR == 60)
        #expect(bt.rrIntervals.count == 1)
        #expect(abs((bt.rrIntervals.first ?? 0) - 1000.0) < 0.001)
    }

    // MARK: - Mutual exclusion on the single strap

    @Test func startLiveMonitoringRefusedDuringReading() {
        let bt = BluetoothManager()
        bt.startReadingCapture()
        #expect(bt.captureMode == .reading)
        bt.startLiveMonitoring()                 // refused — a reading is in progress
        #expect(bt.captureMode == .reading)
        #expect(bt.liveSample == nil)
        bt.stopReadingCapture()
    }

    @Test func startReadingCaptureTearsDownLive() {
        let bt = BluetoothManager()
        bt.startLiveMonitoring()
        #expect(bt.captureMode == .live)
        bt.startReadingCapture()                 // reading takes precedence, live is torn down
        #expect(bt.captureMode == .reading)
        bt.stopReadingCapture()
    }

    // MARK: - Live recovery guards (watchdog-driven re-subscribe / reconnect)

    /// The staleness watchdog can call recovery at any time; both must be safe no-ops when there is no
    /// live session, so a spurious call never touches the reading path or a dead connection.
    @Test func recoveryCallsAreNoOpsWhenNotLive() {
        let bt = BluetoothManager()
        bt.resubscribeLive()
        bt.reconnectLive()
        #expect(bt.captureMode == .idle)
        #expect(bt.liveSample == nil)
    }

    /// Live, but nothing connected yet: recovery is guarded on the peripheral/characteristic, so it is
    /// a no-op rather than a crash, and the live session is left intact.
    @Test func recoveryWithoutAConnectionLeavesLiveIntact() {
        let bt = BluetoothManager()
        bt.startLiveMonitoring()
        #expect(bt.captureMode == .live)
        bt.reconnectLive()                       // no peripheral → guarded no-op
        bt.resubscribeLive()                     // no characteristic → guarded no-op
        #expect(bt.captureMode == .live)
        bt.stopLiveMonitoring()
        #expect(bt.captureMode == .idle)
    }

    // MARK: - Bounded live-reconnect on a failed connect (the didFailToConnect ladder)

    /// The pure decision behind `didFailToConnect`: while a live session is active a failed connect
    /// retries the same strap up to the bound, then gives up honestly so the session can fall back to
    /// idle. The reading path (never `liveActive`) always gives up — its original behavior.
    @Test func failedLiveConnectRetriesWhileLiveThenGivesUpAtTheBound() {
        // Reading path / no live session: never retries, mirroring the original idle fallback.
        #expect(BluetoothManager.liveConnectFailureAction(liveActive: false, attempts: 0) == .giveUp)
        #expect(BluetoothManager.liveConnectFailureAction(liveActive: false, attempts: 3) == .giveUp)

        // Live session: retries for every attempt strictly below the bound…
        for attempt in 0..<BluetoothManager.maxLiveReconnectAttempts {
            #expect(BluetoothManager.liveConnectFailureAction(liveActive: true, attempts: attempt) == .retry)
        }
        // …then gives up once the consecutive-failure budget is spent (honest re-tap fallback).
        #expect(BluetoothManager.liveConnectFailureAction(
            liveActive: true, attempts: BluetoothManager.maxLiveReconnectAttempts) == .giveUp)
        #expect(BluetoothManager.liveConnectFailureAction(
            liveActive: true, attempts: BluetoothManager.maxLiveReconnectAttempts + 1) == .giveUp)
    }
}
