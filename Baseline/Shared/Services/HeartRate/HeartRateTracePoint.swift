import Foundation

/// One persisted heart-rate reading on a workout's timeline: a timestamp and a BPM, nothing else.
///
/// Deliberately *not* `HeartRateSample`. That type is a live BLE transport record — it carries
/// sensor-contact state and a radio receipt time that the `HeartRateMonitor` explicitly does not
/// trust for timing — and persisting it would freeze transport details into the durable record. This
/// is the storage shape: the two facts a trace, a chart, and a future upload all need.
struct HeartRateTracePoint: Codable, Equatable, Sendable {
    let timestamp: Date
    let bpm: Int
}

/// A workout's full heart-rate series, in timestamp order.
///
/// Value type with no reference to the plan, the log, or persistence, so the recorder, the
/// repository, the chart, and the storage blob all pass the same thing around.
struct WorkoutHeartRateTrace: Codable, Equatable, Sendable {
    let points: [HeartRateTracePoint]

    init(points: [HeartRateTracePoint] = []) {
        self.points = points
    }

    var isEmpty: Bool { points.isEmpty }
    var hasSamples: Bool { points.isEmpty == false }
    var count: Int { points.count }

    /// First and last stamps of the recorded series (nil when nothing was captured). Read from the
    /// ends rather than `min`/`max` because `HeartRateTraceBuffer` only ever appends in strictly
    /// increasing time order.
    var startAt: Date? { points.first?.timestamp }
    var endAt: Date? { points.last?.timestamp }

    /// Span covered by the trace itself, 0 when fewer than two points were captured. This is the
    /// honest fallback duration for a chart when the session's own start/finish instants are missing.
    var span: TimeInterval {
        guard let startAt, let endAt else { return 0 }
        return max(endAt.timeIntervalSince(startAt), 0)
    }
}

/// The durable heart-rate record for one scheduled workout: the full-resolution trace plus the
/// summary that was computed from the live session, and where (if anywhere) a backup copy lives.
///
/// `summary` is stored alongside the trace rather than recomputed from it because zone seconds are
/// credited *at sample-arrival time* against the zone model then in force
/// (`HeartRateMonitor.ingest`); re-deriving them later from bare BPMs would silently re-band a past
/// workout against today's settings.
struct WorkoutHeartRateSeries: Equatable, Sendable {
    let scheduledWorkoutID: UUID
    let completedLogID: UUID?
    let recordedAt: Date
    let trace: WorkoutHeartRateTrace
    let summary: WorkoutHeartRateSummary
    /// Mirrors Ascend's `lastRemoteHeartRateSeriesStoragePath`: the last sidecar path this series was
    /// successfully uploaded to. Always nil in this phase — the cloud leg is built but unwired.
    let remoteStoragePath: String?

    init(
        scheduledWorkoutID: UUID,
        completedLogID: UUID? = nil,
        recordedAt: Date,
        trace: WorkoutHeartRateTrace,
        summary: WorkoutHeartRateSummary,
        remoteStoragePath: String? = nil
    ) {
        self.scheduledWorkoutID = scheduledWorkoutID
        self.completedLogID = completedLogID
        self.recordedAt = recordedAt
        self.trace = trace
        self.summary = summary
        self.remoteStoragePath = remoteStoragePath
    }
}
