@preconcurrency import FirebaseStorage
import Foundation

/// The backup leg for a workout's heart-rate series.
///
/// **Not wired to a call site in this phase, on purpose.** Baseline's durable record for a workout's
/// heart rate is the local `SDWorkoutHeartRateSeries`, which is complete on its own. There is no
/// workout/session document in Firestore for a sidecar to hang off yet, and `storage.rules` denies
/// every write, so uploading now would put series in the cloud for workouts whose logs, plans, and
/// sessions are not — with nothing to restore them onto. The repository is built and tested behind
/// this protocol so that when durable workout sync lands, the sidecar becomes a field on whatever
/// document that design produces and this is already here.
///
/// Three methods, not Ascend's two: Ascend never downloads its sidecar, so after a reinstall its
/// hydrated workouts show avg/max with no chart. Baseline ships the read path with the write path.
protocol WorkoutHeartRateStorageRepositoryProtocol: Sendable {
    /// Store the series and return where it went. Replaces any existing object for that workout.
    @discardableResult
    func upload(
        userID: String,
        scheduledWorkoutID: UUID,
        blob: WorkoutHeartRateStorageBlob
    ) async throws -> WorkoutHeartRateSeriesReference

    /// Read the series back, or nil when no object exists for that workout — a missing sidecar is an
    /// ordinary state (the workout had no strap), not an error.
    func download(
        userID: String,
        scheduledWorkoutID: UUID
    ) async throws -> WorkoutHeartRateStorageBlob?

    /// Remove the sidecar. Idempotent: deleting one that is already gone succeeds, so a retry after a
    /// partial failure cannot get stuck.
    func deleteIfPresent(userID: String, scheduledWorkoutID: UUID) async throws
}

/// Firebase Storage implementation. An `actor` with injected use, following
/// `FirebaseExerciseMediaRepository` rather than Ascend's `@unchecked Sendable` singleton.
actor FirebaseWorkoutHeartRateStorageRepository: WorkoutHeartRateStorageRepositoryProtocol {

    private lazy var storage = Storage.storage()

    init() {}

    @discardableResult
    func upload(
        userID: String,
        scheduledWorkoutID: UUID,
        blob: WorkoutHeartRateStorageBlob
    ) async throws -> WorkoutHeartRateSeriesReference {
        let path = WorkoutHeartRateStorageCodec.storagePath(
            userID: userID,
            scheduledWorkoutID: scheduledWorkoutID
        )
        // Encode (and size-check) before touching the network, so a malformed or oversized series
        // fails locally instead of half-way through an upload.
        let data = try WorkoutHeartRateStorageCodec.encode(blob)

        let metadata = StorageMetadata()
        metadata.contentType = WorkoutHeartRateStorageCodec.contentType

        try Task.checkCancellation()
        _ = try await storage.reference(withPath: path).putDataAsync(data, metadata: metadata)
        return WorkoutHeartRateStorageCodec.reference(storagePath: path, blob: blob)
    }

    func download(
        userID: String,
        scheduledWorkoutID: UUID
    ) async throws -> WorkoutHeartRateStorageBlob? {
        let path = WorkoutHeartRateStorageCodec.storagePath(
            userID: userID,
            scheduledWorkoutID: scheduledWorkoutID
        )
        try Task.checkCancellation()
        let data: Data
        do {
            data = try await storage.reference(withPath: path)
                .data(maxSize: WorkoutHeartRateStorageCodec.maximumObjectBytes)
        } catch let error as NSError {
            if Self.isObjectNotFound(error) { return nil }
            throw error
        }
        try Task.checkCancellation()
        return try WorkoutHeartRateStorageCodec.decode(data, expecting: scheduledWorkoutID)
    }

    func deleteIfPresent(userID: String, scheduledWorkoutID: UUID) async throws {
        let path = WorkoutHeartRateStorageCodec.storagePath(
            userID: userID,
            scheduledWorkoutID: scheduledWorkoutID
        )
        do {
            try await storage.reference(withPath: path).delete()
        } catch let error as NSError {
            guard Self.isObjectNotFound(error) else { throw error }
        }
    }

    private static func isObjectNotFound(_ error: NSError) -> Bool {
        error.domain == StorageErrorDomain && error.code == StorageErrorCode.objectNotFound.rawValue
    }
}
