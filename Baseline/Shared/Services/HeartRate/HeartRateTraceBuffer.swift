import Foundation

/// Accumulates a live workout's heart-rate trace and can hand out its JSON representation.
///
/// `encodedPayload` is the seam a mid-session durability checkpoint will write through — the same
/// shape Ascend's `HeartRateSessionSampleBuffer` exposes, and seamed here for the same reason the
/// cloud storage repository was: so the checkpoint has somewhere to land when it arrives. It is
/// assembled **on demand**, not incrementally, because nothing checkpoints yet and encoding every
/// sample as it arrives would charge live capture on the main actor for a feature that does not
/// exist. If checkpointing lands and profiling shows assembling the whole series each time is too
/// slow across an hour-long session, restore the incremental build then — not before.
///
/// Pure value type driven by explicit timestamps (no wall clock), like `ZoneTimeAccumulator` and
/// `SessionHeartRateStats`, so every capture rule is deterministic in tests.
struct HeartRateTraceBuffer: Equatable, Sendable {

    /// ~1 Hz, matching the BLE Heart Rate Service notify rate. This is the *only* rate limit: there
    /// is no second downsampling pass, so what is stored is what the strap actually sent.
    static let defaultMinimumCaptureInterval: TimeInterval = 0.9

    private(set) var points: [HeartRateTracePoint]
    private let minimumCaptureInterval: TimeInterval
    private var lastCaptureAt: Date?

    init(
        restoring points: [HeartRateTracePoint] = [],
        minimumCaptureInterval: TimeInterval = defaultMinimumCaptureInterval
    ) {
        self.points = []
        self.minimumCaptureInterval = minimumCaptureInterval
        self.lastCaptureAt = nil

        for point in points.filter({ $0.bpm > 0 }).sorted(by: { $0.timestamp < $1.timestamp }) {
            append(point)
        }
    }

    var isEmpty: Bool { points.isEmpty }

    /// The captured series as a value type.
    var trace: WorkoutHeartRateTrace { WorkoutHeartRateTrace(points: points) }

    /// The full series as a JSON array: decoding it yields exactly `points`. Nil when the session
    /// captured nothing, so "no heart rate" is representable without an empty-array sentinel.
    var encodedPayload: Data? {
        guard points.isEmpty == false else { return nil }
        return try? JSONEncoder().encode(points)
    }

    /// Record one live reading. Drops a non-positive BPM (a malformed sample contributes nothing),
    /// enforces the capture interval, and refuses any point that does not advance the timeline — so
    /// the series is strictly increasing in time and can never double back on itself.
    ///
    /// `capturedAt` is the clock instant the reading arrived and governs rate limiting;
    /// `sessionStartedAt + sessionElapsed` is where the point lands on the workout's *logical*
    /// timeline. They are the same thing today (Baseline's live monitor has no pause/resume), but
    /// keeping them separate means a future resume extends one continuous trace instead of punching
    /// a gap the size of the interruption — and needs no change to the stored format.
    mutating func record(
        bpm: Int,
        capturedAt: Date,
        sessionStartedAt: Date? = nil,
        sessionElapsed: TimeInterval = 0
    ) {
        guard bpm > 0 else { return }
        if let lastCaptureAt,
           capturedAt.timeIntervalSince(lastCaptureAt) < minimumCaptureInterval {
            return
        }

        let timestamp = sessionStartedAt.map { $0.addingTimeInterval(max(sessionElapsed, 0)) } ?? capturedAt
        if let last = points.last, timestamp <= last.timestamp { return }

        lastCaptureAt = capturedAt
        append(HeartRateTracePoint(timestamp: timestamp, bpm: bpm))
    }

    /// The single funnel every point enters the series through, whether it came from a restore or
    /// from a live reading, so the ordering guarantee has one place to hold.
    private mutating func append(_ point: HeartRateTracePoint) {
        points.append(point)
    }
}
