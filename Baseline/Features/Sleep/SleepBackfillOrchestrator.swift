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
    func importRecentNights() async {
        await ingest(nightOffsets: 0..<Self.initialBatchNightCount)
        isInitialBatchComplete = true
    }

    /// Continues past batch 1 to the full 90-night window.
    func continueBackfill() async {
        var next = Self.initialBatchNightCount
        while next < Self.targetNightCount {
            // Cooperative cancellation between batches: when the owning Task goes away the
            // import must stop. The flag stays false so a later run resumes (idempotently).
            guard !Task.isCancelled else { return }
            let batchEnd = min(next + Self.backgroundBatchNightCount, Self.targetNightCount)
            await ingest(nightOffsets: next..<batchEnd)
            next = batchEnd
        }
        isBackfillComplete = true
    }

    /// One anchored-query step: re-resolve every night the delta touches, then advance the
    /// persisted cursor. A delta that doesn't change a night's fingerprint writes nothing.
    /// Bounded both ways: the query starts at the 90-night window, and — defense in depth,
    /// should a provider return older samples anyway — touched dates outside that window are
    /// skipped rather than materialized.
    func syncDelta() async {
        let oldestTargetDate = nightDate(offset: Self.targetNightCount - 1)
        let delta = await provider.sleepSampleDelta(
            after: cursorStore.cursor(forKey: Self.sleepAnalysisCursorKey),
            startingFrom: SleepIngestionEngine.nightWindow(for: oldestTargetDate, calendar: calendar).start
        )
        let touchedDates = Set(delta.samples.map {
            SleepIngestionEngine.nightDate(containing: $0.end, calendar: calendar)
        })
        .filter { $0 >= oldestTargetDate }
        let context = makeContext()
        for date in touchedDates.sorted() {
            let window = SleepIngestionEngine.nightWindow(for: date, calendar: calendar)
            let samples = await provider.sleepSamples(in: window)
            reconcileAndStore(
                date: date,
                candidate: SleepIngestionEngine.night(for: date, from: samples, context: context)
            )
        }
        cursorStore.setCursor(delta.cursor, forKey: Self.sleepAnalysisCursorKey)
    }

    // MARK: - Batches

    /// Offset 0 is the most recent night (the one ending this morning). One provider fetch spans
    /// the whole batch; the engine then assembles each night from its own window.
    private func ingest(nightOffsets: Range<Int>) async {
        guard !nightOffsets.isEmpty else { return }
        let dates = nightOffsets.map(nightDate(offset:))
        guard let newest = dates.first, let oldest = dates.last else { return }
        let window = DateInterval(
            start: SleepIngestionEngine.nightWindow(for: oldest, calendar: calendar).start,
            end: SleepIngestionEngine.nightWindow(for: newest, calendar: calendar).end
        )
        let samples = await provider.sleepSamples(in: window)
        let context = makeContext()
        for date in dates {
            reconcileAndStore(
                date: date,
                candidate: SleepIngestionEngine.night(for: date, from: samples, context: context)
            )
        }
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
