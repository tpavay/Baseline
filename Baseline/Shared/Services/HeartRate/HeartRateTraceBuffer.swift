import Foundation

/// Accumulates a live workout's heart-rate trace and carries its own JSON representation.
///
/// The payload is assembled **incrementally**: each point is encoded once, on append, and
/// `encodedPayload` only wraps the already-encoded elements in array brackets. That matters because
/// a durability checkpoint runs repeatedly across a session that can last well over an hour —
/// re-encoding the whole growing series each time would be quadratic main-actor work *during* a
/// workout. Ported from Ascend's `HeartRateSessionSampleBuffer`, which exists for the same reason.
///
/// Pure value type driven by explicit timestamps (no wall clock), like `ZoneTimeAccumulator` and
/// `SessionHeartRateStats`, so every capture rule is deterministic in tests.
struct HeartRateTraceBuffer: Equatable, Sendable {

    /// ~1 Hz, matching the BLE Heart Rate Service notify rate. This is the *only* rate limit: there
    /// is no second downsampling pass, so what is stored is what the strap actually sent.
    static let defaultMinimumCaptureInterval: TimeInterval = 0.9

    private static let elementSeparator = Data(",".utf8)
    private static let arrayOpen = Data("[".utf8)
    private static let arrayClose = Data("]".utf8)

    private(set) var points: [HeartRateTracePoint]
    private let minimumCaptureInterval: TimeInterval
    private var lastCaptureAt: Date?
    private var encodedElements: Data

    init(
        restoring points: [HeartRateTracePoint] = [],
        minimumCaptureInterval: TimeInterval = defaultMinimumCaptureInterval
    ) {
        self.points = []
        self.minimumCaptureInterval = minimumCaptureInterval
        self.lastCaptureAt = nil
        self.encodedElements = Data()

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
        guard encodedElements.isEmpty == false else { return nil }

        var payload = Data(capacity: encodedElements.count + 2)
        payload.append(Self.arrayOpen)
        payload.append(encodedElements)
        payload.append(Self.arrayClose)
        return payload
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

    /// The only mutator of both the series and its encoding, so a point that fails to encode never
    /// lands in `points` and the two can never diverge.
    private mutating func append(_ point: HeartRateTracePoint) {
        guard let element = try? JSONEncoder().encode(point) else { return }

        if encodedElements.isEmpty == false {
            encodedElements.append(Self.elementSeparator)
        }
        encodedElements.append(element)
        points.append(point)
    }
}
