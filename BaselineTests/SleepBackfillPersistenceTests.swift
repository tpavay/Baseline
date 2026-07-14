import Foundation
import HealthKit
import SwiftData
import Testing
@testable import Baseline

private typealias Engine = SleepIngestionEngine
private typealias Fix = SleepFixtures

// MARK: - Fakes (throwing-capable provider, write-counting wrapper, controlled clock)

private struct TransientFailure: Error {}

/// Fixture provider with scriptable failures — the "provider returned empty" vs "provider
/// failed" distinction AC-4 hinges on.
@MainActor
private final class ScriptableSleepProvider: SleepSampleProviding {
    var samplesByNight: [Date: [SleepSample]] = [:]
    var pendingDelta = SleepSampleDelta(samples: [], cursor: nil)
    var failWindowFetches = false
    var failDeltaFetch = false
    var droppedUnknownPerFetch = 0
    private(set) var receivedCursors: [Data?] = []

    func sleepSamples(in window: DateInterval) async throws -> SleepSampleBatch {
        guard !failWindowFetches else { throw TransientFailure() }
        return SleepSampleBatch(
            samples: samplesByNight.values.flatMap { $0 }.filter { window.contains($0.end) },
            droppedUnknownCount: droppedUnknownPerFetch
        )
    }

    func sleepSampleDelta(after cursor: Data?, startingFrom start: Date) async throws -> SleepSampleDelta {
        guard !failDeltaFetch else { throw TransientFailure() }
        receivedCursors.append(cursor)
        let delta = pendingDelta
        pendingDelta = SleepSampleDelta(samples: [], cursor: delta.cursor)
        return delta
    }
}

/// Counts writes against the real SwiftData-backed store so "unchanged nights not rewritten"
/// stays observable on the durable path.
@MainActor
private final class CountingNightStore: SleepNightStore {
    private let inner: any SleepNightStore
    private(set) var upsertCount = 0

    init(wrapping inner: any SleepNightStore) { self.inner = inner }

    func night(for date: Date) -> SleepNight? { inner.night(for: date) }
    func upsert(_ night: SleepNight) {
        upsertCount += 1
        inner.upsert(night)
    }
    func remove(for date: Date) { inner.remove(for: date) }
    func nightDates(containingSampleUUIDs uuids: [UUID]) -> [Date] { inner.nightDates(containingSampleUUIDs: uuids) }
    func allNights() -> [SleepNight] { inner.allNights() }
}

@MainActor
private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

// MARK: - AC-4/AC-5/AC-7/AC-8: the orchestrator on durable SwiftData stores

@MainActor
struct SleepBackfillPersistenceTests {

    private let container: ModelContainer
    private let repository: SwiftDataSleepRepository
    private let provider = ScriptableSleepProvider()
    private let clock = TestClock(Fix.date(2026, 3, 11, 9, 30))
    private let today = Fix.calendar.startOfDay(for: Fix.date(2026, 3, 11))
    private let cursorKey = SleepBackfillOrchestrator.sleepAnalysisCursorKey

    init() throws {
        container = try ModelContainer(
            for: Schema(SleepSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        repository = SwiftDataSleepRepository(context: ModelContext(container), calendar: Fix.calendar)
    }

    private func makeOrchestrator(
        nightStore: (any SleepNightStore)? = nil,
        cursorStore: (any SleepSyncCursorStore)? = nil
    ) -> SleepBackfillOrchestrator {
        SleepBackfillOrchestrator(
            provider: provider,
            nightStore: nightStore ?? repository,
            cursorStore: cursorStore ?? repository,
            calendar: Fix.calendar,
            now: { [clock] in clock.now }
        )
    }

    /// A fresh context + repository over the same container — the mid-run "reopen".
    private func reopenedRepository() -> SwiftDataSleepRepository {
        SwiftDataSleepRepository(context: ModelContext(container), calendar: Fix.calendar)
    }

    private func nightDate(offset: Int) -> Date {
        Fix.calendar.date(byAdding: .day, value: -offset, to: today)!
    }

    private func populateHistory(nights: Int = 120) {
        for offset in 0..<nights {
            let wakeDay = nightDate(offset: offset)
            provider.samplesByNight[wakeDay] = Fix.simpleStagedNight(wakeDay: wakeDay)
        }
    }

    // MARK: AC-7

    @Test func backfillOnSwiftDataStoresReproducesSliceOneBehavior() async throws {
        populateHistory()
        let orchestrator = makeOrchestrator()

        await orchestrator.importRecentNights()
        #expect(orchestrator.isInitialBatchComplete)
        #expect(repository.allNights().count == SleepBackfillOrchestrator.initialBatchNightCount)
        #expect(repository.night(for: today) != nil)   // today available after batch 1

        await orchestrator.continueBackfill()
        #expect(orchestrator.isBackfillComplete)
        let nights = repository.allNights()
        #expect(nights.count == SleepBackfillOrchestrator.targetNightCount)
        #expect(nights.first?.date == nightDate(offset: 89))
        #expect(nights.allSatisfy { $0.analysisStatus == .complete && $0.revision == 0 })
    }

    @Test func storeReopenMidBackfillResumesWithoutRewrites() async throws {
        populateHistory()

        // Batch 1 lands, then the app "closes" mid-backfill…
        await makeOrchestrator().importRecentNights()
        #expect(repository.allNights().count == SleepBackfillOrchestrator.initialBatchNightCount)

        // …and reopens: new context, new repository, new orchestrator, same persisted rows.
        let reopened = reopenedRepository()
        let counting = CountingNightStore(wrapping: reopened)
        let resumed = makeOrchestrator(nightStore: counting, cursorStore: reopened)
        await resumed.importRecentNights()
        await resumed.continueBackfill()

        // The 14 already-persisted nights were recognized by fingerprint — only the missing 76
        // were written, and every night still reads as a first revision.
        #expect(resumed.isBackfillComplete)
        #expect(reopened.allNights().count == SleepBackfillOrchestrator.targetNightCount)
        #expect(counting.upsertCount == SleepBackfillOrchestrator.targetNightCount
            - SleepBackfillOrchestrator.initialBatchNightCount)
        #expect(reopened.allNights().allSatisfy { $0.revision == 0 })

        // A full third pass is pure idempotence: zero additional writes.
        let third = makeOrchestrator(nightStore: counting, cursorStore: reopened)
        await third.importRecentNights()
        await third.continueBackfill()
        #expect(counting.upsertCount == SleepBackfillOrchestrator.targetNightCount
            - SleepBackfillOrchestrator.initialBatchNightCount)
    }

    // MARK: AC-4

    @Test func anchorCursorPersistsAcrossReopenAndFeedsTheNextDelta() async throws {
        populateHistory(nights: 20)
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: HKQueryAnchor(fromValue: 7), requiringSecureCoding: true)
        provider.pendingDelta = SleepSampleDelta(samples: [], cursor: archived)
        await makeOrchestrator().syncDelta()
        #expect(repository.syncCursor(forKey: cursorKey) == archived)

        // Reopen: the next sync must resume from the persisted archive, intact.
        let reopened = reopenedRepository()
        provider.pendingDelta = SleepSampleDelta(samples: [], cursor: Data([9]))
        await makeOrchestrator(nightStore: reopened, cursorStore: reopened).syncDelta()
        let handed = try #require(provider.receivedCursors.last ?? nil)
        #expect(handed == archived)
        let anchor = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: handed))
        #expect(anchor == HKQueryAnchor(fromValue: 7))
    }

    @Test func transientRefetchFailureHoldsCursorAndRetriesTheNight() async throws {
        populateHistory(nights: 20)
        let orchestrator = makeOrchestrator()
        await orchestrator.importRecentNights()
        let original = try #require(repository.night(for: today))

        // A revision arrives for last night, but the touched-night refetch fails transiently.
        let awake = Fix.watch(.awake, Fix.date(2026, 3, 11, 3, 0), Fix.date(2026, 3, 11, 3, 10))
        provider.samplesByNight[today]?.append(awake)
        provider.pendingDelta = SleepSampleDelta(samples: [awake], cursor: Data([1]))
        provider.failWindowFetches = true

        await orchestrator.syncDelta()

        // Cursor held, night untouched — nothing was lost, nothing pretended to succeed.
        #expect(repository.syncCursor(forKey: cursorKey) == nil)
        #expect(repository.night(for: today) == original)

        // Next sync (provider healed, same delta re-served because the cursor never moved).
        provider.failWindowFetches = false
        provider.pendingDelta = SleepSampleDelta(samples: [awake], cursor: Data([1]))
        await orchestrator.syncDelta()

        let revised = try #require(repository.night(for: today))
        #expect(revised.revision == 1)
        #expect(revised.analysisStatus == .revised)
        #expect(revised.awakenings == 1)
        #expect(repository.syncCursor(forKey: cursorKey) == Data([1]))
    }

    @Test func failedDeltaFetchLeavesCursorUntouched() async throws {
        repository.setSyncCursor(Data([3]), forKey: cursorKey)
        provider.failDeltaFetch = true
        await makeOrchestrator().syncDelta()
        #expect(repository.syncCursor(forKey: cursorKey) == Data([3]))
    }

    // MARK: AC-5

    /// Today's night with an awakening whose sample UUID is known — the deletion target — plus
    /// a few plain neighbouring nights that must stay untouched.
    private func seedTodayWithKnownAwakening() async -> UUID {
        populateHistory(nights: 5)
        let awakeUUID = UUID()
        let previousDay = Fix.calendar.date(byAdding: .day, value: -1, to: today)!
        let bedtime = Fix.calendar.date(bySettingHour: 23, minute: 0, second: 0, of: previousDay)!
        provider.samplesByNight[today] = [
            Fix.watch(.core, bedtime, Fix.date(2026, 3, 11, 3, 0)),
            SleepSample(uuid: awakeUUID, start: Fix.date(2026, 3, 11, 3, 0), end: Fix.date(2026, 3, 11, 3, 10),
                        kind: .awake, sourceBundleID: Fix.watchBundle, deviceModel: "Watch"),
            Fix.watch(.core, Fix.date(2026, 3, 11, 3, 10), Fix.date(2026, 3, 11, 7, 0)),
        ]
        await makeOrchestrator().importRecentNights()
        return awakeUUID
    }

    @Test func deletedSampleUUIDMapsToItsNightAndRevisesIt() async throws {
        let awakeUUID = await seedTodayWithKnownAwakening()
        let original = try #require(repository.night(for: today))
        #expect(original.awakenings == 1)
        #expect(original.composingSampleUUIDs.contains(awakeUUID))   // the persisted identity map

        // HealthKit deletes the awakening: the delta carries ONLY the UUID.
        provider.samplesByNight[today]?.removeAll { $0.uuid == awakeUUID }
        provider.pendingDelta = SleepSampleDelta(samples: [], deletedSampleUUIDs: [awakeUUID], cursor: Data([2]))

        await makeOrchestrator().syncDelta()

        let revised = try #require(repository.night(for: today))
        #expect(revised.revision == original.revision + 1)
        #expect(revised.analysisStatus == .revised)
        #expect(revised.awakenings == 0)
        #expect(revised.sourceFingerprint != original.sourceFingerprint)
        #expect(repository.syncCursor(forKey: cursorKey) == Data([2]))
    }

    @Test func deletingEveryComposingSampleRemovesTheNight() async throws {
        _ = await seedTodayWithKnownAwakening()
        let original = try #require(repository.night(for: today))
        let allUUIDs = original.composingSampleUUIDs
        #expect(!allUUIDs.isEmpty)

        provider.samplesByNight[today] = []
        provider.pendingDelta = SleepSampleDelta(samples: [], deletedSampleUUIDs: allUUIDs, cursor: Data([4]))

        await makeOrchestrator().syncDelta()

        // No samples remain → the canonical night is removed, never imputed from nothing.
        #expect(repository.night(for: today) == nil)
        #expect(repository.syncCursor(forKey: cursorKey) == Data([4]))
        // The neighbouring nights are untouched.
        #expect(repository.night(for: nightDate(offset: 1)) != nil)
    }

    // MARK: AC-8

    @Test func droppedUnknownSampleCountsAccumulateAcrossFetches() async throws {
        populateHistory(nights: 20)
        provider.droppedUnknownPerFetch = 3
        let orchestrator = makeOrchestrator()

        await orchestrator.importRecentNights()               // one window fetch
        #expect(orchestrator.droppedUnknownSampleCount == 3)

        let awake = Fix.watch(.awake, Fix.date(2026, 3, 11, 3, 0), Fix.date(2026, 3, 11, 3, 10))
        provider.samplesByNight[today]?.append(awake)
        provider.pendingDelta = SleepSampleDelta(samples: [awake], cursor: Data([5]), droppedUnknownCount: 2)
        await orchestrator.syncDelta()                        // delta (2) + one refetch (3)

        #expect(orchestrator.droppedUnknownSampleCount == 8)
    }
}
