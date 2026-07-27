import Foundation
import Testing
@testable import Baseline

/// A controllable live source, mirroring the one in `HeartRateMonitorTests`: samples arrive through
/// the real `onLiveSample` seam so the recorder is exercised where it actually sits.
private final class RecorderLiveSource: LiveHeartRateSource {
    var liveSample: HeartRateSample?
    var connectionStatus: BluetoothManager.Status = .connected
    var onLiveSample: ((HeartRateSample) -> Void)?

    func startLiveMonitoring() {}
    func stopLiveMonitoring() {}
    func resubscribeLive() {}
    func reconnectLive() {}

    func emit(bpm: Int) {
        let sample = HeartRateSample(bpm: bpm, sensorContact: .detected, receivedAt: .distantPast)
        liveSample = sample
        onLiveSample?(sample)
    }
}

@MainActor
private final class RecorderClock {
    private(set) var current = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(by seconds: TimeInterval) { current += seconds }
    var now: @MainActor () -> Date { { [self] in current } }
}

/// The recorder itself, and the capture it produces at completion.
@MainActor
struct WorkoutHeartRateRecorderTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ bpm: Int) -> HeartRateSample {
        HeartRateSample(bpm: bpm, sensorContact: .detected, receivedAt: .distantPast)
    }

    @Test func aSessionWithNoSamplesHasNoTrace() {
        let recorder = WorkoutHeartRateRecorder()
        #expect(recorder.hasSamples == false)
        #expect(recorder.trace.isEmpty)
        #expect(recorder.encodedPayload == nil)
    }

    @Test func recordingRateLimitsToAboutOneHertz() {
        let recorder = WorkoutHeartRateRecorder()
        // BLE straps notify slightly faster than 1 Hz and sometimes burst; the 0.9 s floor is what
        // keeps an hour-long session near 3600 points rather than several times that.
        for tick in 0..<20 {
            recorder.record(sample(150), at: start.addingTimeInterval(Double(tick) * 0.5))
        }
        #expect(recorder.trace.count == 10)
    }

    @Test func preparingForASessionClearsAPreviousTrace() {
        let recorder = WorkoutHeartRateRecorder()
        recorder.record(sample(140), at: start)
        recorder.record(sample(142), at: start.addingTimeInterval(2))
        #expect(recorder.trace.count == 2)

        recorder.prepareForSession()
        #expect(recorder.trace.isEmpty)
    }

    @Test func preparingCanRestoreARecoveredSeries() {
        let recovered = (0..<4).map {
            HeartRateTracePoint(timestamp: start.addingTimeInterval(Double($0)), bpm: 130 + $0)
        }
        let recorder = WorkoutHeartRateRecorder()
        recorder.prepareForSession(restoring: recovered)
        recorder.record(sample(160), at: start.addingTimeInterval(30))

        #expect(recorder.trace.points.map(\.bpm) == [130, 131, 132, 133, 160])
    }

    // MARK: - Capture at completion

    @Test func captureIsNilWhenNothingWasRecorded() {
        let clock = RecorderClock()
        let monitor = HeartRateMonitor(source: RecorderLiveSource(), zoneModel: HeartRateZoneModel(maxHR: 200), now: clock.now)
        let recorder = WorkoutHeartRateRecorder()
        monitor.recorder = recorder

        // No strap, or a strap that never streamed: persist nothing rather than an empty record.
        #expect(WorkoutHeartRateCapture(recorder: recorder, monitor: monitor) == nil)
    }

    /// The end-to-end shape of what completion freezes: the trace from the recorder, and avg / max /
    /// zone seconds / zone model read from the monitor's own accumulators.
    @Test func captureCarriesTheTraceAndTheMonitorsAggregates() throws {
        let clock = RecorderClock()
        let source = RecorderLiveSource()
        // maxHR 200, %max → zone floors 100 / 120 / 140 / 160 / 180.
        let monitor = HeartRateMonitor(source: source, zoneModel: HeartRateZoneModel(maxHR: 200), now: clock.now)
        let recorder = WorkoutHeartRateRecorder()
        monitor.recorder = recorder
        monitor.startMonitoring()
        defer { monitor.stopMonitoring() }

        source.emit(bpm: 130)          // Z2 for the next 2 s
        clock.advance(by: 2)
        source.emit(bpm: 150)          // Z3 for the next 2 s
        clock.advance(by: 2)
        source.emit(bpm: 190)          // Z5, nothing after it to credit

        let capture = try #require(WorkoutHeartRateCapture(recorder: recorder, monitor: monitor))
        #expect(capture.trace.points.map(\.bpm) == [130, 150, 190])
        #expect(capture.summary.sampleCount == 3)
        #expect(capture.summary.averageBPM == 157)      // (130 + 150 + 190) / 3, rounded
        #expect(capture.summary.maxBPM == 190)
        #expect(capture.summary.seconds(in: .z2) == 2)
        #expect(capture.summary.seconds(in: .z3) == 2)
        #expect(capture.summary.seconds(in: .z5) == 0)  // no later sample bounds the last interval
        #expect(capture.summary.zoneSeconds.count == 5)
        #expect(capture.summary.hasEvidence)
    }

    /// The zone boundaries are frozen *as of completion*, so editing max HR afterwards cannot re-band
    /// a workout that is already in the past.
    @Test func captureSnapshotsTheZoneModelInForceAtCompletion() throws {
        let clock = RecorderClock()
        let source = RecorderLiveSource()
        let monitor = HeartRateMonitor(source: source, zoneModel: HeartRateZoneModel(maxHR: 190, restingHR: 50), now: clock.now)
        let recorder = WorkoutHeartRateRecorder()
        monitor.recorder = recorder
        monitor.startMonitoring()
        defer { monitor.stopMonitoring() }
        source.emit(bpm: 155)

        let snapshot = try #require(WorkoutHeartRateCapture(recorder: recorder, monitor: monitor)?.summary.zoneModel)
        #expect(snapshot.maxHR == 190)
        #expect(snapshot.restingHR == 50)
        #expect(snapshot.method == .heartRateReserve)
        // Rehydrating re-derives the same model, so a stored band cannot drift from the live resolver.
        #expect(snapshot.model == HeartRateZoneModel(maxHR: 190, restingHR: 50))
        #expect(snapshot.model.method == snapshot.method)
    }

    @Test func summaryReadoutIsTheSharedInstrumentString() {
        let summary = WorkoutHeartRateSummary(
            averageBPM: 142, maxBPM: 171, sampleCount: 900, zoneSeconds: [0, 0, 0, 0, 0], zoneModel: nil
        )
        #expect(summary.readout == "AVG 142 · MAX 171 BPM")
        #expect(summary.hasEvidence)
    }

    /// Zone seconds are normalized to one entry per zone, so any reader can index by ordinal.
    @Test func zoneSecondsAreAlwaysFivePerSummary() {
        let short = WorkoutHeartRateSummary(
            averageBPM: 120, maxBPM: 130, sampleCount: 4, zoneSeconds: [10, 20], zoneModel: nil
        )
        #expect(short.zoneSeconds == [10, 20, 0, 0, 0])
        #expect(short.seconds(in: .z5) == 0)
        #expect(short.totalZoneSeconds == 30)
    }

    @Test func aSummaryWithoutSamplesIsNotEvidence() {
        let empty = WorkoutHeartRateSummary(
            averageBPM: nil, maxBPM: nil, sampleCount: 0, zoneSeconds: [], zoneModel: nil
        )
        #expect(empty.hasEvidence == false)
        #expect(empty.readout == nil)
    }
}
