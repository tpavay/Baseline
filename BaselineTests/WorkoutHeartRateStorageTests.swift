import Foundation
import Testing
@testable import Baseline

/// The sidecar's transport layer: gzip, the versioned blob, the storage path, and the repository
/// contract — including the read path Ascend never built, which is why its hydrated workouts show
/// avg/max with no chart after a reinstall.
struct WorkoutHeartRateStorageTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func trace(count: Int) -> WorkoutHeartRateTrace {
        WorkoutHeartRateTrace(points: (0..<count).map {
            HeartRateTracePoint(timestamp: start.addingTimeInterval(Double($0)), bpm: 132 + $0 % 45)
        })
    }

    private var summary: WorkoutHeartRateSummary {
        WorkoutHeartRateSummary(
            averageBPM: 151,
            maxBPM: 176,
            sampleCount: 3_600,
            zoneSeconds: [10, 300, 2_400, 800, 90],
            zoneModel: HeartRateZoneModelSnapshot(HeartRateZoneModel(maxHR: 195, restingHR: 48))
        )
    }

    // MARK: - Gzip

    @Test func gzipRoundTripsArbitraryBytes() throws {
        let original = Data((0..<50_000).map { UInt8($0 % 251) })
        let compressed = try GzipCodec.compress(original)
        #expect(try GzipCodec.decompress(compressed) == original)
    }

    /// A real gzip member, not a bare deflate stream: header magic, deflate method, and an 18-byte
    /// floor. That is what makes the stored object readable by anything that speaks `.gz`.
    @Test func compressedOutputCarriesAGzipHeaderAndTrailer() throws {
        let compressed = try GzipCodec.compress(Data("heart rate".utf8))
        #expect(compressed.count >= 18)
        #expect(Array(compressed.prefix(4)) == [0x1f, 0x8b, 0x08, 0x00])

        // The trailer's little-endian input size is the last four bytes.
        let size = compressed.suffix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(size == UInt32("heart rate".utf8.count))
    }

    @Test func nonGzipInputIsRejectedRatherThanMisread() {
        #expect(throws: GzipCodec.Error.invalidGzipData) {
            try GzipCodec.decompress(Data("not a gzip object at all, not even close".utf8))
        }
        #expect(throws: GzipCodec.Error.invalidGzipData) {
            try GzipCodec.decompress(Data([0x1f, 0x8b, 0x08]))   // truncated
        }
    }

    /// The trailer is checked, not just stripped. A flipped byte in the CRC-32 (or anywhere in the
    /// payload it covers) has to fail loudly: silently returning corrupted bytes is how garbage ends
    /// up decoded into samples and charted as measured heart rate.
    @Test func aCorruptedChecksumIsRejectedRatherThanReturned() throws {
        var corrupted = try GzipCodec.compress(Data("heart rate series".utf8))
        corrupted[corrupted.count - 8] ^= 0xff        // first byte of the stored CRC-32
        #expect(throws: GzipCodec.Error.checksumMismatch) { try GzipCodec.decompress(corrupted) }
    }

    /// The declared length is checked too, so a member claiming to be a different size than what came
    /// out of it fails instead of being trusted.
    @Test func aTamperedDeclaredSizeIsRejected() throws {
        var tampered = try GzipCodec.compress(Data((0..<2_000).map { UInt8($0 % 251) }))
        tampered[tampered.count - 4] ^= 0x01          // low byte of ISIZE
        #expect(throws: GzipCodec.Error.sizeMismatch) { try GzipCodec.decompress(tampered) }
    }

    /// Bounding the compressed object alone leaves a crafted member free to expand without limit, so
    /// the declared output size is screened before anything is inflated.
    @Test func anObjectDeclaringMoreOutputThanTheCapIsRejectedBeforeInflating() throws {
        var oversized = try WorkoutHeartRateStorageCodec.encode(
            WorkoutHeartRateStorageBlob(scheduledWorkoutID: UUID(), trace: trace(count: 5), summary: nil)
        )
        // ISIZE = 0xFFFF_FFF0, ~4 GB — far past the decompressed cap.
        for offset in 0..<4 { oversized[oversized.count - 4 + offset] = offset == 0 ? 0xf0 : 0xff }

        #expect(throws: GzipCodec.Error.decompressedTooLarge) {
            try GzipCodec.decompress(oversized, maximumDecompressedBytes: WorkoutHeartRateStorageCodec.maximumDecompressedBytes)
        }
        #expect(throws: GzipCodec.Error.decompressedTooLarge) {
            try WorkoutHeartRateStorageCodec.decode(oversized, expecting: UUID())
        }
    }

    /// Verification is on the way *in* only: the bytes `compress` emits are untouched, so the objects
    /// stay readable by anything that speaks `.gz`.
    @Test func verificationDidNotChangeTheBytesOnTheWire() throws {
        let payload = Data((0..<5_000).map { UInt8($0 % 97) })
        let compressed = try GzipCodec.compress(payload)
        #expect(Array(compressed.prefix(10)) == [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        #expect(try GzipCodec.decompress(compressed) == payload)
    }

    // MARK: - Blob

    @Test func blobRoundTripsThroughJSONAndGzip() throws {
        let workoutID = UUID()
        let recorded = trace(count: 3_600)
        let blob = WorkoutHeartRateStorageBlob(
            scheduledWorkoutID: workoutID,
            trace: recorded,
            summary: summary
        )

        let encoded = try WorkoutHeartRateStorageCodec.encode(blob)
        let decoded = try WorkoutHeartRateStorageCodec.decode(encoded, expecting: workoutID)

        #expect(decoded == blob)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.trace == recorded)
        // The summary rides in the blob too, so a restored sidecar rebuilds the zone card as well as
        // the line — not just the samples.
        #expect(decoded.summary == summary)
    }

    /// gzip is what keeps an hour-long series comfortably inside the object cap.
    @Test func anHourLongSeriesCompressesToASmallFractionOfItsJSON() throws {
        let blob = WorkoutHeartRateStorageBlob(
            scheduledWorkoutID: UUID(),
            trace: trace(count: 3_600),
            summary: summary
        )
        let raw = try JSONEncoder().encode(blob).count
        let compressed = try WorkoutHeartRateStorageCodec.encode(blob).count
        #expect(Double(compressed) < Double(raw) * 0.5)
        #expect(Int64(compressed) < WorkoutHeartRateStorageCodec.maximumObjectBytes)
    }

    /// The version and the workout id live inside the blob precisely so a wrong object is caught on
    /// the way in rather than charted against the wrong session.
    @Test func decodingRejectsAnUnsupportedSchemaVersion() throws {
        let workoutID = UUID()
        let future = WorkoutHeartRateStorageBlob(
            schemaVersion: 99,
            scheduledWorkoutId: workoutID.uuidString,
            samples: trace(count: 3).points,
            summary: nil
        )
        let encoded = try GzipCodec.compress(try JSONEncoder().encode(future))
        #expect(throws: WorkoutHeartRateStorageCodec.Error.schemaVersionUnsupported(99)) {
            try WorkoutHeartRateStorageCodec.decode(encoded, expecting: workoutID)
        }
    }

    @Test func decodingRejectsAnotherWorkoutsSeries() throws {
        let stored = UUID()
        let asked = UUID()
        let encoded = try WorkoutHeartRateStorageCodec.encode(
            WorkoutHeartRateStorageBlob(scheduledWorkoutID: stored, trace: trace(count: 3), summary: nil)
        )
        #expect(throws: WorkoutHeartRateStorageCodec.Error.self) {
            try WorkoutHeartRateStorageCodec.decode(encoded, expecting: asked)
        }
    }

    @Test func storagePathIsKeyedByUserAndScheduledWorkout() {
        let workoutID = UUID()
        let path = WorkoutHeartRateStorageCodec.storagePath(userID: "abc123", scheduledWorkoutID: workoutID)
        #expect(path == "users/abc123/workout_heart_rate/\(workoutID.uuidString).json.gz")
    }

    @Test func referenceDescribesWhatWasStored() throws {
        let recorded = trace(count: 120)
        let blob = WorkoutHeartRateStorageBlob(scheduledWorkoutID: UUID(), trace: recorded, summary: summary)
        let reference = WorkoutHeartRateStorageCodec.reference(storagePath: "users/u/workout_heart_rate/x.json.gz", blob: blob)

        #expect(reference.encoding == "json+gzip")
        #expect(reference.sampleCount == 120)
        #expect(reference.seriesStartAt == recorded.startAt)
        #expect(reference.seriesEndAt == recorded.endAt)
        #expect(reference.seriesEndAt >= reference.seriesStartAt)
    }

    // MARK: - Repository contract

    /// Upload → download → delete against an in-memory conformer. This pins the *contract* the
    /// Firebase implementation has to honour, including the round trip: a series that goes up must
    /// come back as the same series, and a delete of something absent must succeed.
    @Test func theRepositoryContractRoundTripsAndDeletesIdempotently() async throws {
        let repository = InMemoryWorkoutHeartRateStorageRepository()
        let workoutID = UUID()
        let recorded = trace(count: 500)
        let blob = WorkoutHeartRateStorageBlob(scheduledWorkoutID: workoutID, trace: recorded, summary: summary)

        #expect(try await repository.download(userID: "u1", scheduledWorkoutID: workoutID) == nil)

        let reference = try await repository.upload(userID: "u1", scheduledWorkoutID: workoutID, blob: blob)
        #expect(reference.storagePath == WorkoutHeartRateStorageCodec.storagePath(userID: "u1", scheduledWorkoutID: workoutID))
        #expect(reference.sampleCount == 500)

        let restored = try #require(try await repository.download(userID: "u1", scheduledWorkoutID: workoutID))
        #expect(restored == blob)
        #expect(restored.trace == recorded)

        // Another athlete's namespace is a different object entirely.
        #expect(try await repository.download(userID: "u2", scheduledWorkoutID: workoutID) == nil)

        try await repository.deleteIfPresent(userID: "u1", scheduledWorkoutID: workoutID)
        #expect(try await repository.download(userID: "u1", scheduledWorkoutID: workoutID) == nil)
        // Deleting what is already gone succeeds, so a retry after a partial failure cannot wedge.
        try await repository.deleteIfPresent(userID: "u1", scheduledWorkoutID: workoutID)
    }

    @Test func uploadingReplacesTheStoredSeries() async throws {
        let repository = InMemoryWorkoutHeartRateStorageRepository()
        let workoutID = UUID()
        try await repository.upload(
            userID: "u1", scheduledWorkoutID: workoutID,
            blob: WorkoutHeartRateStorageBlob(scheduledWorkoutID: workoutID, trace: trace(count: 10), summary: nil)
        )
        try await repository.upload(
            userID: "u1", scheduledWorkoutID: workoutID,
            blob: WorkoutHeartRateStorageBlob(scheduledWorkoutID: workoutID, trace: trace(count: 40), summary: nil)
        )
        let restored = try #require(try await repository.download(userID: "u1", scheduledWorkoutID: workoutID))
        #expect(restored.samples.count == 40)
    }
}

/// A conformer that stores the exact gzip bytes the real repository would put in a bucket, so the
/// round trip under test is the true encode → store → fetch → decode path with only the network
/// removed.
private actor InMemoryWorkoutHeartRateStorageRepository: WorkoutHeartRateStorageRepositoryProtocol {
    private var objects: [String: Data] = [:]

    @discardableResult
    func upload(
        userID: String,
        scheduledWorkoutID: UUID,
        blob: WorkoutHeartRateStorageBlob
    ) async throws -> WorkoutHeartRateSeriesReference {
        let path = WorkoutHeartRateStorageCodec.storagePath(userID: userID, scheduledWorkoutID: scheduledWorkoutID)
        objects[path] = try WorkoutHeartRateStorageCodec.encode(blob)
        return WorkoutHeartRateStorageCodec.reference(storagePath: path, blob: blob)
    }

    func download(userID: String, scheduledWorkoutID: UUID) async throws -> WorkoutHeartRateStorageBlob? {
        let path = WorkoutHeartRateStorageCodec.storagePath(userID: userID, scheduledWorkoutID: scheduledWorkoutID)
        guard let data = objects[path] else { return nil }
        return try WorkoutHeartRateStorageCodec.decode(data, expecting: scheduledWorkoutID)
    }

    func deleteIfPresent(userID: String, scheduledWorkoutID: UUID) async throws {
        objects[WorkoutHeartRateStorageCodec.storagePath(userID: userID, scheduledWorkoutID: scheduledWorkoutID)] = nil
    }
}
