import Foundation
import Testing
@testable import Baseline

private typealias Fix = SleepFixtures

// MARK: - Fakes (in-memory, controlled clock — no HealthKit, no real sleeps)

/// Fixture-backed `SleepSampleProviding`: nights keyed by wake day, plus a scriptable delta.
@MainActor
private final class FixtureSleepProvider: SleepSampleProviding {
    var samplesByNight: [Date: [SleepSample]] = [:]
    var pendingDelta = SleepSampleDelta(samples: [], cursor: nil)
    private(set) var receivedCursors: [Data?] = []
    private(set) var receivedDeltaStarts: [Date] = []

    func sleepSamples(in window: DateInterval) async -> SleepSampleBatch {
        SleepSampleBatch(samples: samplesByNight.values.flatMap { $0 }.filter { window.contains($0.end) })
    }

    func sleepSampleDelta(after cursor: Data?, startingFrom start: Date) async -> SleepSampleDelta {
        receivedCursors.append(cursor)
        receivedDeltaStarts.append(start)
        let delta = pendingDelta
        pendingDelta = SleepSampleDelta(samples: [], cursor: delta.cursor)
        return delta
    }
}

/// Counts writes so idempotence is observable ("unchanged nights not rewritten").
@MainActor
private final class CountingSleepNightStore: SleepNightStore {
    private let inner = InMemorySleepNightStore()
    private(set) var upsertCount = 0

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

// MARK: - AC-6: progressive 90-night backfill + anchored delta sync

@MainActor
struct SleepBackfillTests {

    private let provider = FixtureSleepProvider()
    private let store = CountingSleepNightStore()
    private let cursors = InMemorySleepSyncCursorStore()
    /// Morning of Mar 11, well past the 07:00 wake, so every ingested night is `complete`.
    private let clock = TestClock(Fix.date(2026, 3, 11, 9, 30))
    private let today = Fix.calendar.startOfDay(for: Fix.date(2026, 3, 11))

    private func makeOrchestrator() -> SleepBackfillOrchestrator {
        SleepBackfillOrchestrator(
            provider: provider,
            nightStore: store,
            cursorStore: cursors,
            calendar: Fix.calendar,
            now: { [clock] in clock.now }
        )
    }

    private func nightDate(offset: Int) -> Date {
        Fix.calendar.date(byAdding: .day, value: -offset, to: today)!
    }

    /// Populates more history than the backfill will ever ask for.
    private func populateHistory(nights: Int = 120) {
        for offset in 0..<nights {
            let wakeDay = nightDate(offset: offset)
            provider.samplesByNight[wakeDay] = Fix.simpleStagedNight(wakeDay: wakeDay)
        }
    }

    @Test func initialBatchImportsMostRecentFourteenNightsIncludingToday() async throws {
        populateHistory()
        let orchestrator = makeOrchestrator()

        await orchestrator.importRecentNights()

        #expect(orchestrator.isInitialBatchComplete)
        #expect(!orchestrator.isBackfillComplete)
        let nights = store.allNights()
        #expect(nights.count == SleepBackfillOrchestrator.initialBatchNightCount)
        // Today's night is available right after batch 1 — the morning flow never waits on 90.
        #expect(store.night(for: today) != nil)
        #expect(nights.first?.date == nightDate(offset: 13))
        #expect(nights.last?.date == today)
    }

    @Test func backfillContinuesToNinetyNights() async throws {
        populateHistory()
        let orchestrator = makeOrchestrator()

        await orchestrator.importRecentNights()
        await orchestrator.continueBackfill()

        #expect(orchestrator.isBackfillComplete)
        let nights = store.allNights()
        #expect(nights.count == SleepBackfillOrchestrator.targetNightCount)
        #expect(nights.first?.date == nightDate(offset: 89))   // never past the 90-night target
        #expect(nights.last?.date == today)
    }

    @Test func rerunningTheFullBackfillIsIdempotent() async throws {
        populateHistory()
        let orchestrator = makeOrchestrator()

        await orchestrator.importRecentNights()
        await orchestrator.continueBackfill()
        let writesAfterFirstRun = store.upsertCount
        #expect(writesAfterFirstRun == SleepBackfillOrchestrator.targetNightCount)

        await orchestrator.importRecentNights()
        await orchestrator.continueBackfill()

        // Unchanged fingerprints ⇒ no rewrites, no duplicates, no revision churn.
        #expect(store.upsertCount == writesAfterFirstRun)
        let nights = store.allNights()
        #expect(nights.count == SleepBackfillOrchestrator.targetNightCount)
        #expect(nights.allSatisfy { $0.revision == 0 })
        #expect(nights.allSatisfy { $0.analysisStatus == .complete })
    }

    @Test func nightsWithoutDataAreNeverImputed() async throws {
        // Only five recent nights exist; the other nine windows in batch 1 are empty.
        for offset in [0, 1, 3, 7, 12] {
            let wakeDay = nightDate(offset: offset)
            provider.samplesByNight[wakeDay] = Fix.simpleStagedNight(wakeDay: wakeDay)
        }
        let orchestrator = makeOrchestrator()

        await orchestrator.importRecentNights()

        #expect(store.allNights().count == 5)
        #expect(store.night(for: nightDate(offset: 2)) == nil)
    }

    @Test func provisionalTodayUpgradesToCompleteOnALaterSync() async throws {
        populateHistory()
        clock.now = Fix.date(2026, 3, 11, 7, 30)   // 30 min after wake — inside stabilization
        let orchestrator = makeOrchestrator()

        await orchestrator.importRecentNights()
        let todayNight = try #require(store.night(for: today))
        #expect(todayNight.analysisStatus == .provisional)
        let writesAfterFirstRun = store.upsertCount

        clock.now = Fix.date(2026, 3, 11, 10, 0)   // past wake + stabilization
        await orchestrator.importRecentNights()

        let upgraded = try #require(store.night(for: today))
        #expect(upgraded.analysisStatus == .complete)
        #expect(upgraded.revision == 0)
        #expect(upgraded.id == todayNight.id)
        // Exactly one write: the upgrade. The 13 unchanged historical nights stay untouched.
        #expect(store.upsertCount == writesAfterFirstRun + 1)
    }

    @Test func deltaSyncRevisesTouchedNightAndAdvancesCursor() async throws {
        populateHistory()
        let orchestrator = makeOrchestrator()
        await orchestrator.importRecentNights()
        await orchestrator.continueBackfill()
        let writesAfterBackfill = store.upsertCount
        let original = try #require(store.night(for: today))

        // A late Health sync delivers an awakening inside last night's sleep.
        let awake = Fix.watch(.awake, Fix.date(2026, 3, 11, 3, 0), Fix.date(2026, 3, 11, 3, 10))
        provider.samplesByNight[today]?.append(awake)
        provider.pendingDelta = SleepSampleDelta(samples: [awake], cursor: Data([1]))

        await orchestrator.syncDelta()

        let revised = try #require(store.night(for: today))
        #expect(revised.analysisStatus == .revised)
        #expect(revised.revision == 1)
        #expect(revised.id == original.id)
        #expect(revised.awakenings == 1)
        #expect(revised.sourceFingerprint != original.sourceFingerprint)
        #expect(store.upsertCount == writesAfterBackfill + 1)   // only the touched night
        #expect(provider.receivedCursors == [nil])              // first delta ran from scratch
        #expect(cursors.cursor(forKey: SleepBackfillOrchestrator.sleepAnalysisCursorKey) == Data([1]))
    }

    @Test func emptyDeltaWritesNothingButStillAdvancesCursor() async throws {
        populateHistory()
        let orchestrator = makeOrchestrator()
        await orchestrator.importRecentNights()
        let writesBefore = store.upsertCount

        cursors.setCursor(Data([7]), forKey: SleepBackfillOrchestrator.sleepAnalysisCursorKey)
        provider.pendingDelta = SleepSampleDelta(samples: [], cursor: Data([8]))

        await orchestrator.syncDelta()

        #expect(store.upsertCount == writesBefore)
        #expect(provider.receivedCursors.last == Data([7]))     // the persisted cursor was passed through
        #expect(cursors.cursor(forKey: SleepBackfillOrchestrator.sleepAnalysisCursorKey) == Data([8]))
    }

    @Test func deltaOlderThanTargetWindowIsSkipped() async throws {
        // History exists beyond the 90-night target (populateHistory seeds 120), so a missing
        // skip WOULD materialize the old night and this test would catch it.
        populateHistory()
        let orchestrator = makeOrchestrator()
        await orchestrator.importRecentNights()
        await orchestrator.continueBackfill()
        let writesAfterBackfill = store.upsertCount

        // A delta lands for a night 100 days back — outside the engine's 90-night window.
        let ancientDay = nightDate(offset: 100)
        let awake = Fix.watch(
            .awake,
            Fix.calendar.date(bySettingHour: 3, minute: 0, second: 0, of: ancientDay)!,
            Fix.calendar.date(bySettingHour: 3, minute: 10, second: 0, of: ancientDay)!)
        provider.samplesByNight[ancientDay]?.append(awake)
        provider.pendingDelta = SleepSampleDelta(samples: [awake], cursor: Data([9]))

        await orchestrator.syncDelta()

        #expect(store.night(for: ancientDay) == nil)        // never materialized
        #expect(store.upsertCount == writesAfterBackfill)   // nothing rewritten
        // The cursor still advances — the out-of-window delta is consumed, not replayed forever.
        #expect(cursors.cursor(forKey: SleepBackfillOrchestrator.sleepAnalysisCursorKey) == Data([9]))
        // And the anchored query itself was bounded to the 90-night window's start.
        let expectedStart = SleepIngestionEngine.nightWindow(
            for: nightDate(offset: SleepBackfillOrchestrator.targetNightCount - 1),
            calendar: Fix.calendar
        ).start
        #expect(provider.receivedDeltaStarts.last == expectedStart)
    }

    @Test func cancelledBackfillStopsBetweenBatchesWithoutCompleting() async throws {
        populateHistory()
        let orchestrator = makeOrchestrator()
        await orchestrator.importRecentNights()

        // Cancel before the task body can run (we hold the main actor), so the cooperative
        // check fires before the first background batch — deterministic, no timing.
        let task = Task { await orchestrator.continueBackfill() }
        task.cancel()
        await task.value

        #expect(!orchestrator.isBackfillComplete)
        #expect(store.allNights().count == SleepBackfillOrchestrator.initialBatchNightCount)

        // A later (uncancelled) run resumes and finishes the job.
        await orchestrator.continueBackfill()
        #expect(orchestrator.isBackfillComplete)
        #expect(store.allNights().count == SleepBackfillOrchestrator.targetNightCount)
    }

    @Test func emptyProviderProducesNoNightsAndDoesNotThrow() async throws {
        // PRIMARY AC-7 denied/unavailable evidence: HealthKit reports denial as empty data, and
        // this pins the whole pipeline's response to it — no nights, no writes, no crash.
        let orchestrator = makeOrchestrator()

        await orchestrator.importRecentNights()
        await orchestrator.continueBackfill()

        #expect(store.allNights().isEmpty)
        #expect(store.upsertCount == 0)
        #expect(orchestrator.isBackfillComplete)
    }
}
