import FirebaseFirestore
@preconcurrency import FirebaseStorage
import Foundation

/// Firebase-backed implementation of the catalog network boundary. Reads the pointer from Firestore and
/// downloads the blob through the authenticated Storage SDK (paths, not public URLs — same posture as
/// exercise media). App Check gates both calls at the provider boundary.
actor FirebaseExerciseCatalogRepository: ExerciseCatalogRemote {
    private static let maximumCatalogBytes: Int64 = 5 * 1_024 * 1_024
    private static let pointerDocumentPath = "catalog/current"

    private lazy var storage = Storage.storage()
    private var firestore: Firestore { Firestore.firestore() }

    func fetchPointer() async throws -> ExerciseCatalogPointer {
        let snapshot = try await firestore.document(Self.pointerDocumentPath).getDocument()
        guard let data = snapshot.data() else { throw ExerciseCatalogSyncError.missingDocument }
        guard let schemaVersion = data["schemaVersion"] as? Int,
              let version = data["version"] as? Int,
              let path = data["path"] as? String,
              let checksum = data["checksum"] as? String
        else { throw ExerciseCatalogSyncError.decodeFailed }
        return ExerciseCatalogPointer(schemaVersion: schemaVersion, version: version, path: path, checksum: checksum)
    }

    func fetchCatalogData(path: String) async throws -> Data {
        guard Self.isValidCatalogPath(path) else { throw ExerciseCatalogSyncError.decodeFailed }
        return try await storage.reference(withPath: path).data(maxSize: Self.maximumCatalogBytes)
    }

    /// Guards the pointer-supplied path so a compromised pointer can't point the download elsewhere:
    /// `exercise-catalog/v<N>/catalog.json`.
    static func isValidCatalogPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "exercise-catalog", parts[2] == "catalog.json" else { return false }
        let version = parts[1]
        guard version.first == "v" else { return false }
        let digits = version.dropFirst()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) && digits.first != "0"
    }
}

/// On-disk catalog cache in Application Support (not Caches — this is functional data that should survive
/// storage pressure, unlike purgeable media thumbnails). Stores the raw blob plus its pointer so a relaunch
/// can install and re-verify offline.
struct FileExerciseCatalogCache: ExerciseCatalogCacheStore {
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "ExerciseCatalog", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private var blobURL: URL { directory.appending(path: "catalog.json") }
    private var pointerURL: URL { directory.appending(path: "pointer.json") }

    func load() -> ExerciseCatalogCacheEntry? {
        guard let pointerData = try? Data(contentsOf: pointerURL),
              let pointer = try? JSONDecoder().decode(ExerciseCatalogPointer.self, from: pointerData),
              let blob = try? Data(contentsOf: blobURL)
        else { return nil }
        return ExerciseCatalogCacheEntry(pointer: pointer, data: blob)
    }

    func save(_ entry: ExerciseCatalogCacheEntry) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? entry.data.write(to: blobURL, options: .atomic)
        if let pointerData = try? JSONEncoder().encode(entry.pointer) {
            try? pointerData.write(to: pointerURL, options: .atomic)
        }
    }
}

extension ExerciseCatalogSync {
    /// The app-wired sync: Firestore pointer + Storage blob, cached in Application Support, installed into
    /// the live `ExerciseCatalog`.
    static let live = ExerciseCatalogSync(
        remote: FirebaseExerciseCatalogRepository(),
        cache: FileExerciseCatalogCache()
    )
}
