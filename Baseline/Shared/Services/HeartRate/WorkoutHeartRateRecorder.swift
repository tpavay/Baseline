import Foundation

/// Captures the live heart-rate series of one workout so it survives the session.
///
/// It hangs off `HeartRateMonitor`, not off `BluetoothManager`: `ingest(_:)` is the single funnel
/// every live sample already passes through, and it already stamps arrival with the monitor's
/// injected clock. Attaching there means the recorder sees exactly the samples the HUD sees, stays
/// deterministic in tests, and sits strictly *downstream* of the freshness watchdog — it cannot
/// delay, reorder, or suppress anything the live HUD reads.
///
/// Baseline's live path is push-driven (`LiveHeartRateSource.onLiveSample`), so unlike Ascend — which
/// polls a `freshMeasurement` property on a timer — there is no tick here and no staleness window to
/// reason about. The buffer's `minimumCaptureInterval` is the only rate limit.
@MainActor
final class WorkoutHeartRateRecorder {

    private(set) var buffer: HeartRateTraceBuffer
    private let minimumCaptureInterval: TimeInterval

    init(minimumCaptureInterval: TimeInterval = HeartRateTraceBuffer.defaultMinimumCaptureInterval) {
        self.minimumCaptureInterval = minimumCaptureInterval
        self.buffer = HeartRateTraceBuffer(minimumCaptureInterval: minimumCaptureInterval)
    }

    /// The captured series so far.
    var trace: WorkoutHeartRateTrace { buffer.trace }

    var hasSamples: Bool { buffer.isEmpty == false }

    /// The seam a mid-session durability checkpoint will write through: the whole captured series as
    /// JSON, assembled **on demand** rather than accumulated per sample — see
    /// `HeartRateTraceBuffer`'s header for why live capture must not pay that cost while nothing
    /// checkpoints. Nil when nothing was captured.
    var encodedPayload: Data? { buffer.encodedPayload }

    /// Record one live sample at the monitor's arrival instant. `sessionStartedAt`/`sessionElapsed`
    /// are carried through to the buffer for a future pause/resume; passing neither anchors on the
    /// arrival clock, which is what Baseline does today.
    func record(
        _ sample: HeartRateSample,
        at capturedAt: Date,
        sessionStartedAt: Date? = nil,
        sessionElapsed: TimeInterval = 0
    ) {
        buffer.record(
            bpm: sample.bpm,
            capturedAt: capturedAt,
            sessionStartedAt: sessionStartedAt,
            sessionElapsed: sessionElapsed
        )
    }

    /// Start a fresh capture, optionally seeded from a recovered series so a resumed session extends
    /// one continuous trace rather than starting a second one.
    func prepareForSession(restoring points: [HeartRateTracePoint] = []) {
        buffer = HeartRateTraceBuffer(
            restoring: points,
            minimumCaptureInterval: minimumCaptureInterval
        )
    }
}

/// What the finish sequence hands to persistence: the full trace plus the summary computed from the
/// live monitor's own accumulators, captured together at one instant.
struct WorkoutHeartRateCapture: Equatable, Sendable {
    let trace: WorkoutHeartRateTrace
    let summary: WorkoutHeartRateSummary
}

extension WorkoutHeartRateCapture {

    /// Snapshot a finishing workout's heart rate. Nil when nothing was recorded, so "no strap, or a
    /// strap that never streamed" persists nothing at all rather than an empty record.
    ///
    /// The zone seconds and avg/max are read from the monitor rather than recomputed from the trace:
    /// `HeartRateMonitor.ingest` credits each interval to the zone in force when the sample arrived,
    /// and the zone model is captured **as of completion** for the same reason (a later settings edit
    /// must not re-band a past workout).
    @MainActor
    init?(recorder: WorkoutHeartRateRecorder, monitor: HeartRateMonitor) {
        let trace = recorder.trace
        guard trace.hasSamples else { return nil }
        self.init(
            trace: trace,
            summary: WorkoutHeartRateSummary(
                averageBPM: monitor.averageBPM,
                maxBPM: monitor.maxBPM,
                sampleCount: trace.count,
                zoneSeconds: monitor.zoneTime.secondsByZoneOrdered.map(\.seconds),
                zoneModel: HeartRateZoneModelSnapshot(monitor.zoneModel)
            )
        )
    }
}
