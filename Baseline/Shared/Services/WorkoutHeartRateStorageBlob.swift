import Foundation

/// The wire format of a workout's heart-rate sidecar: JSON, then gzip.
///
/// The schema version and the workout id live **inside** the blob, so a downloaded object identifies
/// itself — a future v2 is detectable from the bytes alone, without consulting any index, and an
/// object restored to the wrong workout is detectable too.
///
/// Baseline carries the `summary` here as well (Ascend does not): a restored sidecar then rebuilds
/// everything the chart and the zone card need — avg, max, seconds per zone, and the zone boundaries
/// that were in force — not just the line.
struct WorkoutHeartRateStorageBlob: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    /// The `encoding` token recorded alongside a stored object, matching Ascend's.
    static let encoding = "json+gzip"

    let schemaVersion: Int
    let scheduledWorkoutId: String
    let samples: [HeartRateTracePoint]
    let summary: WorkoutHeartRateSummary?

    init(
        schemaVersion: Int = currentSchemaVersion,
        scheduledWorkoutId: String,
        samples: [HeartRateTracePoint],
        summary: WorkoutHeartRateSummary?
    ) {
        self.schemaVersion = schemaVersion
        self.scheduledWorkoutId = scheduledWorkoutId
        self.samples = samples
        self.summary = summary
    }

    init(scheduledWorkoutID: UUID, trace: WorkoutHeartRateTrace, summary: WorkoutHeartRateSummary?) {
        self.init(
            scheduledWorkoutId: scheduledWorkoutID.uuidString,
            samples: trace.points,
            summary: summary
        )
    }

    var trace: WorkoutHeartRateTrace { WorkoutHeartRateTrace(points: samples) }
}

/// Where a sidecar lives and what it covers. The local mirror of Ascend's Firestore reference; it
/// becomes a field on a workout document if and when Baseline gains durable workout sync.
struct WorkoutHeartRateSeriesReference: Codable, Equatable, Sendable {
    let storagePath: String
    let encoding: String
    let sampleCount: Int
    let seriesStartAt: Date
    let seriesEndAt: Date

    init(
        storagePath: String,
        encoding: String = WorkoutHeartRateStorageBlob.encoding,
        sampleCount: Int,
        seriesStartAt: Date,
        seriesEndAt: Date
    ) {
        self.storagePath = storagePath
        self.encoding = encoding
        self.sampleCount = sampleCount
        self.seriesStartAt = seriesStartAt
        self.seriesEndAt = seriesEndAt
    }
}

/// Pure encode/decode + path rules for the sidecar, factored out of the Firebase repository so the
/// bytes that go over the wire are testable without a network or a signed-in user.
enum WorkoutHeartRateStorageCodec {
    /// Rejects an object larger than this on the way in *and* out: a heart-rate series that big is a
    /// bug or a hostile object, not a workout. Matches Ascend's rule.
    static let maximumObjectBytes: Int64 = 5 * 1_024 * 1_024
    /// The cap on what an object is allowed to *expand to*. Capping the compressed bytes alone leaves
    /// a truncated or crafted member free to inflate without limit, so the gzip trailer's declared
    /// size is screened against this before anything is allocated. Generous next to the object cap
    /// because gzip runs well under half on this JSON: 16 MB of samples is on the order of a hundred
    /// hours at 1 Hz, far past any workout.
    static let maximumDecompressedBytes: Int64 = 16 * 1_024 * 1_024
    static let contentType = "application/gzip"

    enum Error: LocalizedError, Equatable {
        case objectTooLarge
        case schemaVersionUnsupported(Int)
        case workoutMismatch(expected: String, found: String)

        var errorDescription: String? {
            switch self {
            case .objectTooLarge: "The stored heart-rate series is larger than the allowed size."
            case .schemaVersionUnsupported(let version): "Unsupported heart-rate series format (v\(version))."
            case .workoutMismatch: "The stored heart-rate series belongs to a different workout."
            }
        }
    }

    /// `users/{uid}/workout_heart_rate/{scheduledWorkoutID}.json.gz`
    ///
    /// Keyed on the scheduled workout — the identity every Baseline read path already uses, stable
    /// across a re-completion. The directory name and extension match Ascend's so the two apps' rules
    /// and tooling stay interchangeable.
    static func storagePath(userID: String, scheduledWorkoutID: UUID) -> String {
        "users/\(userID)/workout_heart_rate/\(scheduledWorkoutID.uuidString).json.gz"
    }

    static func encode(_ blob: WorkoutHeartRateStorageBlob) throws -> Data {
        let data = try GzipCodec.compress(try JSONEncoder().encode(blob))
        guard Int64(data.count) <= maximumObjectBytes else { throw Error.objectTooLarge }
        return data
    }

    /// Decode a downloaded object, asserting it is a format we understand and belongs to the workout
    /// we asked for. Both checks matter because the blob is self-describing precisely so that a
    /// mismatch is caught here rather than silently charted against the wrong session.
    static func decode(_ data: Data, expecting scheduledWorkoutID: UUID) throws -> WorkoutHeartRateStorageBlob {
        guard Int64(data.count) <= maximumObjectBytes else { throw Error.objectTooLarge }
        let blob = try JSONDecoder().decode(
            WorkoutHeartRateStorageBlob.self,
            from: try GzipCodec.decompress(data, maximumDecompressedBytes: maximumDecompressedBytes)
        )
        guard blob.schemaVersion == WorkoutHeartRateStorageBlob.currentSchemaVersion else {
            throw Error.schemaVersionUnsupported(blob.schemaVersion)
        }
        guard blob.scheduledWorkoutId == scheduledWorkoutID.uuidString else {
            throw Error.workoutMismatch(
                expected: scheduledWorkoutID.uuidString,
                found: blob.scheduledWorkoutId
            )
        }
        return blob
    }

    /// The reference describing a just-uploaded object.
    static func reference(
        storagePath: String,
        blob: WorkoutHeartRateStorageBlob
    ) -> WorkoutHeartRateSeriesReference {
        let stamps = blob.samples.map(\.timestamp)
        let start = stamps.min() ?? .distantPast
        return WorkoutHeartRateSeriesReference(
            storagePath: storagePath,
            sampleCount: blob.samples.count,
            seriesStartAt: start,
            seriesEndAt: stamps.max() ?? start
        )
    }
}
