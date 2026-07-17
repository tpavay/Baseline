import CryptoKit
import Foundation

/// The published catalog artifact — the exercise set in Baseline's own schema, downloaded as one blob.
/// `schemaVersion` guards the shape; `version` is a monotonic content revision.
struct ExerciseCatalogManifest: Codable, Sendable {
    let schemaVersion: Int
    let version: Int
    let exercises: [ExerciseDefinition]
}

/// The small pointer record (a single Firestore doc) that tells the client which catalog blob is current
/// and how to verify it. Kept tiny so the launch check is one cheap read; the blob itself lives in Storage.
struct ExerciseCatalogPointer: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let version: Int
    let path: String       // Storage path to the catalog blob, e.g. "exercise-catalog/v1/catalog.json"
    let checksum: String   // lowercased hex SHA-256 of the blob bytes
}

/// A cached blob plus the pointer it was fetched under, so a relaunch can install offline without a fetch.
struct ExerciseCatalogCacheEntry: Sendable {
    let pointer: ExerciseCatalogPointer
    let data: Data
}

/// The network boundary — the two remote reads the sync needs. Faked in tests; Firebase-backed in the app.
protocol ExerciseCatalogRemote: Sendable {
    func fetchPointer() async throws -> ExerciseCatalogPointer
    func fetchCatalogData(path: String) async throws -> Data
}

/// The on-disk cache boundary — last-known catalog, so the app opens with the newest set it has ever seen.
protocol ExerciseCatalogCacheStore: Sendable {
    func load() -> ExerciseCatalogCacheEntry?
    func save(_ entry: ExerciseCatalogCacheEntry)
}

enum ExerciseCatalogSyncError: Error, Equatable {
    case unsupportedSchema(Int)
    case checksumMismatch
    case decodeFailed
    case missingDocument
}

/// Keeps the live `ExerciseCatalog` in step with the server-hosted catalog. An actor so a launch `loadCache`
/// and a `refresh` (and any future foreground refresh) never overlap. Every failure is non-fatal: the app
/// keeps whatever catalog it already has (cached, or the compiled seed), so exercises never disappear
/// because the network is down or a blob is corrupt.
actor ExerciseCatalogSync {
    private let remote: any ExerciseCatalogRemote
    private let cache: any ExerciseCatalogCacheStore
    private let supportedSchemaVersion: Int
    private let install: @Sendable ([ExerciseDefinition]) -> Void
    private var installedVersion: Int?

    init(
        remote: any ExerciseCatalogRemote,
        cache: any ExerciseCatalogCacheStore,
        supportedSchemaVersion: Int = ExerciseCatalog.supportedSchemaVersion,
        install: @escaping @Sendable ([ExerciseDefinition]) -> Void = { ExerciseCatalog.install($0) }
    ) {
        self.remote = remote
        self.cache = cache
        self.supportedSchemaVersion = supportedSchemaVersion
        self.install = install
    }

    /// Install the last cached catalog, if any is present and still verifies. Call once at startup, before
    /// `refresh`, so the first render uses the newest catalog the device has ever downloaded (not the seed).
    func loadCache() {
        guard let entry = cache.load(),
              let manifest = Self.verifiedManifest(entry.data,
                                                   checksum: entry.pointer.checksum,
                                                   supportedSchemaVersion: supportedSchemaVersion)
        else { return }
        install(manifest.exercises)
        installedVersion = manifest.version
    }

    /// Best-effort sync: read the pointer, and if it names a newer, compatible, verified catalog, download,
    /// cache, and install it. A no-op when already current; silent (catalog untouched) on any failure.
    func refresh() async {
        do {
            let pointer = try await remote.fetchPointer()
            guard pointer.schemaVersion == supportedSchemaVersion else { return }
            if let installedVersion, pointer.version <= installedVersion { return }

            let data = try await remote.fetchCatalogData(path: pointer.path)
            guard let manifest = Self.verifiedManifest(data,
                                                       checksum: pointer.checksum,
                                                       supportedSchemaVersion: supportedSchemaVersion)
            else { return }

            cache.save(ExerciseCatalogCacheEntry(pointer: pointer, data: data))
            install(manifest.exercises)
            installedVersion = manifest.version
        } catch {
            // Non-fatal: keep the current catalog (cached or seed).
        }
    }

    /// Decode + integrity-check a blob: bytes must match the expected checksum and the decoded schema must
    /// be the one this build understands. Returns nil (reject, keep current) on any mismatch.
    private static func verifiedManifest(
        _ data: Data,
        checksum expected: String,
        supportedSchemaVersion: Int
    ) -> ExerciseCatalogManifest? {
        guard sha256Hex(data) == expected.lowercased(),
              let manifest = try? JSONDecoder().decode(ExerciseCatalogManifest.self, from: data),
              manifest.schemaVersion == supportedSchemaVersion
        else { return nil }
        return manifest
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
