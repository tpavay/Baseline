import Foundation
import os
import Testing
@testable import Baseline

@Suite("Exercise catalog sync")
struct ExerciseCatalogSyncTests {
    // MARK: Fixtures

    private func exercise(_ id: String) -> ExerciseDefinition {
        ExerciseDefinition(id: id, name: id.capitalized, category: .strength,
                           supported: [.reps, .load], defaults: [.reps], aliases: [])
    }

    /// Encode a manifest and pair it with a pointer whose checksum matches the encoded bytes.
    private func published(version: Int, schemaVersion: Int = 1, ids: [String])
        -> (pointer: ExerciseCatalogPointer, data: Data) {
        let manifest = ExerciseCatalogManifest(schemaVersion: schemaVersion, version: version,
                                               exercises: ids.map(exercise))
        let data = try! JSONEncoder().encode(manifest)
        let pointer = ExerciseCatalogPointer(schemaVersion: schemaVersion, version: version,
                                             path: "exercise-catalog/v\(version)/catalog.json",
                                             checksum: ExerciseCatalogSync.sha256Hex(data))
        return (pointer, data)
    }

    private struct StubRemote: ExerciseCatalogRemote {
        var pointer: ExerciseCatalogPointer?
        var data: Data?
        func fetchPointer() async throws -> ExerciseCatalogPointer {
            guard let pointer else { throw ExerciseCatalogSyncError.missingDocument }
            return pointer
        }
        func fetchCatalogData(path: String) async throws -> Data {
            guard let data else { throw ExerciseCatalogSyncError.decodeFailed }
            return data
        }
    }

    private final class StubCache: ExerciseCatalogCacheStore, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock<ExerciseCatalogCacheEntry?>(initialState: nil)
        init(_ initial: ExerciseCatalogCacheEntry? = nil) { state.withLock { $0 = initial } }
        func load() -> ExerciseCatalogCacheEntry? { state.withLock { $0 } }
        func save(_ entry: ExerciseCatalogCacheEntry) { state.withLock { $0 = entry } }
        var saved: ExerciseCatalogCacheEntry? { state.withLock { $0 } }
    }

    /// A thread-safe recorder for the install closure (called from inside the sync actor).
    private final class InstalledCatalog: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        var install: @Sendable ([ExerciseDefinition]) -> Void {
            { defs in self.state.withLock { $0.append(defs.map(\.id)) } }
        }
        var batches: [[String]] { state.withLock { $0 } }
        var latest: [String]? { state.withLock { $0.last } }
    }

    // MARK: Refresh

    @Test func refreshInstallsAndCachesANewerCatalog() async {
        let recorder = InstalledCatalog()
        let cache = StubCache()
        let (pointer, data) = published(version: 3, ids: ["deadlift", "row"])
        let sync = ExerciseCatalogSync(remote: StubRemote(pointer: pointer, data: data),
                                       cache: cache, install: recorder.install)

        await sync.refresh()

        #expect(recorder.latest == ["deadlift", "row"])
        #expect(cache.saved?.pointer == pointer)
    }

    @Test func refreshSkipsAVersionAlreadyInstalled() async {
        let recorder = InstalledCatalog()
        let (pointer, data) = published(version: 2, ids: ["a"])
        // Seed the cache at v2 so loadCache installs it, then a refresh to the same v2 is a no-op.
        let cache = StubCache(ExerciseCatalogCacheEntry(pointer: pointer, data: data))
        let sync = ExerciseCatalogSync(remote: StubRemote(pointer: pointer, data: data),
                                       cache: cache, install: recorder.install)

        await sync.loadCache()
        await sync.refresh()

        #expect(recorder.batches.count == 1)   // only the cache load installed; refresh did nothing
    }

    @Test func refreshRejectsAChecksumMismatch() async {
        let recorder = InstalledCatalog()
        var (pointer, data) = published(version: 5, ids: ["a"])
        pointer = ExerciseCatalogPointer(schemaVersion: pointer.schemaVersion, version: pointer.version,
                                         path: pointer.path, checksum: "deadbeef") // wrong checksum
        let cache = StubCache()
        let sync = ExerciseCatalogSync(remote: StubRemote(pointer: pointer, data: data),
                                       cache: cache, install: recorder.install)

        await sync.refresh()

        #expect(recorder.batches.isEmpty)   // not installed
        #expect(cache.saved == nil)          // not cached
    }

    @Test func refreshRejectsAnUnsupportedSchema() async {
        let recorder = InstalledCatalog()
        let (pointer, data) = published(version: 1, schemaVersion: 99, ids: ["a"])
        let sync = ExerciseCatalogSync(remote: StubRemote(pointer: pointer, data: data),
                                       cache: StubCache(), install: recorder.install)

        await sync.refresh()

        #expect(recorder.batches.isEmpty)
    }

    @Test func refreshKeepsCurrentCatalogWhenThePointerIsMissing() async {
        let recorder = InstalledCatalog()
        let sync = ExerciseCatalogSync(remote: StubRemote(pointer: nil, data: nil),
                                       cache: StubCache(), install: recorder.install)

        await sync.refresh()   // pointer fetch throws

        #expect(recorder.batches.isEmpty)
    }

    // MARK: Cache load

    @Test func loadCacheInstallsAVerifiedCachedCatalog() async {
        let recorder = InstalledCatalog()
        let (pointer, data) = published(version: 7, ids: ["swim", "run"])
        let cache = StubCache(ExerciseCatalogCacheEntry(pointer: pointer, data: data))
        let sync = ExerciseCatalogSync(remote: StubRemote(), cache: cache, install: recorder.install)

        await sync.loadCache()

        #expect(recorder.latest == ["swim", "run"])
    }

    @Test func loadCacheIgnoresACorruptCachedBlob() async {
        let recorder = InstalledCatalog()
        let (pointer, _) = published(version: 7, ids: ["swim"])
        // Pointer checksum no longer matches the (garbage) bytes on disk.
        let cache = StubCache(ExerciseCatalogCacheEntry(pointer: pointer, data: Data("corrupt".utf8)))
        let sync = ExerciseCatalogSync(remote: StubRemote(), cache: cache, install: recorder.install)

        await sync.loadCache()

        #expect(recorder.batches.isEmpty)
    }

    // MARK: Path guard

    @Test func firebaseRepositoryOnlyAcceptsWellFormedCatalogPaths() {
        #expect(FirebaseExerciseCatalogRepository.isValidCatalogPath("exercise-catalog/v1/catalog.json"))
        #expect(FirebaseExerciseCatalogRepository.isValidCatalogPath("exercise-catalog/v12/catalog.json"))
        #expect(!FirebaseExerciseCatalogRepository.isValidCatalogPath("exercise-catalog/v0/catalog.json"))
        #expect(!FirebaseExerciseCatalogRepository.isValidCatalogPath("exercise-catalog/1/catalog.json"))
        #expect(!FirebaseExerciseCatalogRepository.isValidCatalogPath("other/v1/catalog.json"))
        #expect(!FirebaseExerciseCatalogRepository.isValidCatalogPath("exercise-catalog/v1/evil.json"))
        #expect(!FirebaseExerciseCatalogRepository.isValidCatalogPath("exercise-catalog/v1/nested/catalog.json"))
    }
}
