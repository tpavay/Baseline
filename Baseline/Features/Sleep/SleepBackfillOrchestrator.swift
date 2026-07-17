import Foundation

/// Progressive 90-night history import plus anchored delta sync (plan §5, Q-D). Batch 1 covers
/// the most recent nights so today's night is available immediately; the remaining batches fill
/// the comparison window in the background. Every write is fingerprint-gated through
/// `SleepNightLifecycle`, so re-running any part is idempotent: unchanged nights are never
/// rewritten and nothing is duplicated.
///
/// All decisions live in `SleepIngestionEngine`/`SleepNightLifecycle`; this class only sequences
/// fetches and store writes. Fully injectable (provider, stores, calendar, clock) so tests run
/// it against fixtures.
@MainActor
final class SleepBackfillOrchestrator {

    /// Batch 1 — enough recent history for today's night plus short-window comparisons.
    static let initialBatchNightCount = 14
    /// The full backfill target (90 nights, per plan Q-D).
    static let targetNightCount = 90
    static let backgroundBatchNightCount = 14
    /// One cursor per sample-type query — this is the sleep-analysis stream's key.
    static let sleepAnalysisCursorKey = "sleepSync.cursor.sleepAnalysis"

    private let provider: any SleepSampleProviding
    private let nightStore: any SleepNightStore
    private let cursorStore: any SleepSyncCursorStore
    private let calendar: Calendar
    private let preferredSourceBundleID: String?
    private let stabilization: SleepStabilizationRule
    private let now: @MainActor () -> Date

    private(set) var isInitialBatchComplete = false
    private(set) var isBackfillComplete = false
    /// Running total of raw HealthKit samples the mapping rejected (`@unknown default`) —
    /// data-loss visibility as a count only; no health values are logged or stored (AC-8).
    private(set) var droppedUnknownSampleCount = 0

    init(provider: any SleepSampleProviding,
         nightStore: any SleepNightStore,
         cursorStore: any SleepSyncCursorStore,
         calendar: Calendar = .current,
         preferredSourceBundleID: String? = nil,
         stabilization: SleepStabilizationRule = SleepStabilizationRule(),
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.provider = provider
        self.nightStore = nightStore
        self.cursorStore = cursorStore
        self.calendar = calendar
        self.preferredSourceBundleID = preferredSourceBundleID
        self.stabilization = stabilization
        self.now = now
    }

    /// Batch 1: the most recent `initialBatchNightCount` nights. Callers can compute today's
    /// readiness as soon as this returns — the rest of the history follows in the background.
    /// A transiently failed fetch leaves the flag false so callers know to re-run (idempotent).
    func importRecentNights() async {
        if await ingest(nightOffsets: 0..<Self.initialBatchNightCount) {
            isInitialBatchComplete = true
        }
    }

    /// Continues past batch 1 to the full 90-night window.
    func continueBackfill() async {
        var next = Self.initialBatchNightCount
        while next < Self.targetNightCount {
            // Cooperative cancellation between batches: when the owning Task goes away the
            // import must stop. The flag stays false so a later run resumes (idempotently).
            guard !Task.isCancelled else { return }
            let batchEnd = min(next + Self.backgroundBatchNightCount, Self.targetNightCount)
            // A failed batch also leaves the flag false — a later run retries from the store's
            // actual state; fingerprint gating makes the overlap free.
            guard await ingest(nightOffsets: next..<batchEnd) else { return }
            next = batchEnd
        }
        isBackfillComplete = true
    }

    /// One anchored-query step: re-resolve every night the delta touches — via its added
    /// samples or via deleted sample UUIDs mapped through the stored nights — then advance the
    /// persisted cursor. A delta that doesn't change a night's fingerprint writes nothing; a
    /// night whose composing samples are ALL gone is removed.
    ///
    /// Bounded both ways: the query starts at the 90-night window, and — defense in depth,
    /// should a provider return older samples anyway — touched dates outside that window are
    /// skipped rather than materialized. Failure handling: if the delta fetch or ANY touched
    /// night's refetch throws, the cursor is NOT advanced, so the whole delta (and the failed
    /// night with it) is retried on the next sync — fingerprint gating makes the replay free.
    func syncDelta() async {
        let oldestTargetDate = nightDate(offset: Self.targetNightCount - 1)
        let delta: SleepSampleDelta
        do {
            delta = try await provider.sleepSampleDelta(
                after: cursorStore.cursor(forKey: Self.sleepAnalysisCursorKey),
                startingFrom: SleepIngestionEngine.nightWindow(for: oldestTargetDate, calendar: calendar).start
            )
        } catch {
            return   // cursor untouched — the delta re-arrives on the next sync
        }

        var touchedDates = Set(delta.samples.map {
            SleepIngestionEngine.nightDate(containing: $0.end, calendar: calendar)
        })
        touchedDates.formUnion(nightStore.nightDates(containingSampleUUIDs: delta.deletedSampleUUIDs))
        let context = makeContext()
        var allResolved = true
        // Drop counts commit only alongside the cursor: a held cursor replays this same delta
        // next sync, and per-attempt counting would inflate the total on every retry.
        var pendingDroppedCount = delta.droppedUnknownCount
        for date in touchedDates.filter({ $0 >= oldestTargetDate }).sorted() {
            let window = SleepIngestionEngine.nightWindow(for: date, calendar: calendar)
            do {
                let batch = try await provider.sleepSamples(in: window)
                pendingDroppedCount += batch.droppedUnknownCount
                let candidate = SleepIngestionEngine.night(for: date, from: batch.samples, context: context)
                if candidate == nil, nightStore.night(for: date) != nil {
                    // The fetch succeeded and the window is genuinely empty: every composing
                    // sample was deleted, so the canonical night goes with them.
                    nightStore.remove(for: date)
                } else {
                    reconcileAndStore(date: date, candidate: candidate)
                }
            } catch {
                allResolved = false   // retried next sync — the cursor must not pass this night
            }
        }
        if allResolved {
            droppedUnknownSampleCount += pendingDroppedCount
            cursorStore.setCursor(delta.cursor, forKey: Self.sleepAnalysisCursorKey)
        }
    }

    // MARK: - Batches

    /// Offset 0 is the most recent night (the one ending this morning). One provider fetch spans
    /// the whole batch; the engine then assembles each night from its own window. Returns false
    /// when the fetch failed transiently — the caller leaves its completion flag unset.
    private func ingest(nightOffsets: Range<Int>) async -> Bool {
        guard !nightOffsets.isEmpty else { return true }
        let dates = nightOffsets.map(nightDate(offset:))
        guard let newest = dates.first, let oldest = dates.last else { return true }
        let window = DateInterval(
            start: SleepIngestionEngine.nightWindow(for: oldest, calendar: calendar).start,
            end: SleepIngestionEngine.nightWindow(for: newest, calendar: calendar).end
        )
        let batch: SleepSampleBatch
        do {
            batch = try await provider.sleepSamples(in: window)
        } catch {
            return false
        }
        droppedUnknownSampleCount += batch.droppedUnknownCount
        let context = makeContext()
        for date in dates {
            reconcileAndStore(
                date: date,
                candidate: SleepIngestionEngine.night(for: date, from: batch.samples, context: context)
            )
        }
        return true
    }

    private func nightDate(offset: Int) -> Date {
        let anchor = SleepIngestionEngine.nightDate(containing: now(), calendar: calendar)
        return calendar.date(byAdding: .day, value: -offset, to: anchor) ?? anchor
    }

    private func makeContext() -> SleepIngestionEngine.Context {
        SleepIngestionEngine.Context(
            calendar: calendar,
            preferredSourceBundleID: preferredSourceBundleID,
            lastSyncAt: now(),
            stabilization: stabilization
        )
    }

    private func reconcileAndStore(date: Date, candidate: SleepNight?) {
        let outcome = SleepNightLifecycle.reconcile(previous: nightStore.night(for: date), candidate: candidate)
        if case .store(let night) = outcome {
            nightStore.upsert(night)
        }
    }
}
