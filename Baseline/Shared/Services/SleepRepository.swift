import Foundation
import SwiftData

/// Codable ⇄ Data helpers for the sleep blobs, with the date strategy **pinned**.
///
/// WHY pinned: the blob's dates must round-trip at exactly the precision the fingerprint
/// canonicalization uses — integer milliseconds, half-up rounding (see
/// `SleepIngestionEngine.fingerprint`). With JSONEncoder's default seconds-Double encoding the
/// stored night could drift sub-millisecond relative to its own fingerprint and re-read as a
/// phantom revision. Integer-ms round-trips bit-stably; `sortedKeys` makes the encoded bytes
/// deterministic as well.
enum SleepCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let ms = try dec.singleValueContainer().decode(Int64.self)
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        return decoder
    }()

    static func data(_ value: some Encodable) -> Data { (try? encoder.encode(value)) ?? Data() }

    static func value<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data, !data.isEmpty else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

/// What `replaceCanonical` did — observable so idempotence ("zero writes on unchanged
/// fingerprint") is testable, not folklore.
enum SleepCanonicalWrite: Equatable, Sendable {
    case inserted
    /// Fingerprint changed (or the night re-keyed after a timezone shift): single replacement,
    /// `revision` bumped, status `revised`.
    case replaced
    /// Same fingerprint, provisional → complete status upgrade only.
    case upgraded
    /// Stored night stands — nothing written.
    case unchanged
}

/// The **domain-typed gateway** to the Sleep store (plan §7). The single write path — the
/// backfill orchestrator and (from Slice 3 on) the aggregation reads all go through this;
/// engines never import SwiftData.
@MainActor
protocol SleepRepository {
    /// Fingerprint-gated canonical replacement via `SleepNightLifecycle`: unchanged → zero
    /// writes; changed → one replacement with `revision` bumped and status `revised`. Never
    /// leaves two rows for one night date.
    @discardableResult func replaceCanonical(night: SleepNight) -> SleepCanonicalWrite
    func night(for date: Date) -> SleepNight?
    func removeNight(for date: Date)
    /// Nights whose day keys fall in the half-open window `[start, end)`.
    func nights(in window: DateInterval) -> [SleepNight]
    /// The 7/14/30-day sets Slice 3 consumes: the `days` recovery days ending on (and
    /// including) `date`, oldest first.
    func nights(lastDays days: Int, endingOn date: Date) -> [SleepNight]
    /// Newest first.
    func latest(limit: Int) -> [SleepNight]
    func nightDates(containingSampleUUIDs uuids: [UUID]) -> [Date]
    func syncCursor(forKey key: String) -> Data?
    func setSyncCursor(_ cursor: Data?, forKey key: String)
}

@MainActor
final class SwiftDataSleepRepository: SleepRepository {
    private let context: ModelContext
    private let calendar: Calendar

    init(context: ModelContext, calendar: Calendar = .current) {
        self.context = context
        self.calendar = calendar
    }

    // MARK: - Canonical write path

    @discardableResult
    func replaceCanonical(night candidate: SleepNight) -> SleepCanonicalWrite {
        let key = dayKey(for: candidate.date)
        let rows = rows(dayKey: key)
        // Single-row invariant: collapse strays defensively before reconciling.
        for extra in rows.dropFirst() { context.delete(extra) }
        let row = rows.first

        // Timezone-shift tolerance (AC-6): after a calendar change the same physical night
        // re-keys to an adjacent day (the noon boundary moved). Two markers identify "same
        // physical night" under a different day key: an identical fingerprint (pure shift —
        // identical samples), or shared composing sample UUIDs (partial shift — a boundary
        // sample moved in/out of the shifted window, changing the fingerprint). Such rows are
        // stale fragments of this night: when the target key is empty one is adopted (identity
        // preserved, revision bumped — benign revision churn), and every other fragment is
        // deleted — the same sleep must never count twice in a window query.
        // Cheap skip: an unchanged fingerprint at the target key means an idempotent re-ingest;
        // fragments cannot exist.
        var fragments = row?.sourceFingerprint == candidate.sourceFingerprint
            ? [] : fragmentRows(of: candidate, excludingDayKey: key)
        if row == nil, !fragments.isEmpty {
            let adopted = fragments.removeFirst()
            for stale in fragments { context.delete(stale) }
            let previous = night(from: adopted)
            var moved = candidate
            moved.id = previous.id
            moved.revision = previous.revision + 1
            moved.analysisStatus = .revised
            apply(moved, dayKey: key, to: adopted)
            save()
            return .replaced
        }
        // No separate save for these deletions: fragments only exist when the candidate's
        // fingerprint differs from the target row's, so reconcile below always lands in
        // .store — its save commits the purge too.
        for stale in fragments { context.delete(stale) }

        let previous = row.map(night(from:))
        guard let outcome = SleepNightLifecycle.reconcile(previous: previous, candidate: candidate) else {
            return .unchanged   // unreachable: candidate is always non-nil
        }
        switch outcome {
        case .unchanged:
            return .unchanged
        case .store(let night):
            if let row {
                apply(night, dayKey: key, to: row)
                save()
                return night.sourceFingerprint == previous?.sourceFingerprint ? .upgraded : .replaced
            }
            let fresh = SDSleepNight()
            apply(night, dayKey: key, to: fresh)
            context.insert(fresh)
            save()
            return .inserted
        }
    }

    func removeNight(for date: Date) {
        for row in rows(dayKey: dayKey(for: date)) { context.delete(row) }
        save()
    }

    // MARK: - Reads

    func night(for date: Date) -> SleepNight? {
        rows(dayKey: dayKey(for: date)).first.map(night(from:))
    }

    func nights(in window: DateInterval) -> [SleepNight] {
        let startKey = dayKey(for: window.start)
        let endKey = dayKey(for: window.end)
        let descriptor = FetchDescriptor<SDSleepNight>(
            predicate: #Predicate { $0.dayKey >= startKey && $0.dayKey < endKey },
            sortBy: [SortDescriptor(\.dayKey, order: .forward)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map(night(from:))
    }

    func nights(lastDays days: Int, endingOn date: Date) -> [SleepNight] {
        nights(in: SleepWindow.interval(days: days, endingOn: date, calendar: calendar))
    }

    func latest(limit: Int) -> [SleepNight] {
        // fetchLimit 0 means UNLIMITED under Core Data semantics — a zero/negative limit must
        // mean "nothing", not "everything".
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<SDSleepNight>(sortBy: [SortDescriptor(\.dayKey, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).map(night(from:))
    }

    func nightDates(containingSampleUUIDs uuids: [UUID]) -> [Date] {
        guard !uuids.isEmpty else { return [] }
        let deleted = Set(uuids)
        // The UUID list lives inside a blob (not predicable). A full scan is bounded-cheap at
        // current scale (90-night backfill; nothing prunes yet, so rows accrete ~365/year — a
        // retention policy is a Slice 4 decision) and keeps the schema free of a join table
        // nothing else needs. Revisit alongside retention if the scan ever shows up in traces.
        let all = (try? context.fetch(FetchDescriptor<SDSleepNight>())) ?? []
        return all
            .filter { row in
                let uuids = SleepCoding.value([UUID].self, row.composingSampleUUIDsJSON) ?? []
                return !deleted.isDisjoint(with: uuids)
            }
            .map(\.date)
    }

    // MARK: - Sync cursor

    func syncCursor(forKey key: String) -> Data? {
        syncRow(forKey: key)?.anchorData
    }

    func setSyncCursor(_ cursor: Data?, forKey key: String) {
        if let row = syncRow(forKey: key) {
            row.anchorData = cursor
            row.updatedAt = Date()
        } else {
            context.insert(SDSleepSyncState(queryKey: key, anchorData: cursor, updatedAt: Date()))
        }
        save()
    }

    // MARK: - Mapping

    private func apply(_ night: SleepNight, dayKey: Int, to row: SDSleepNight) {
        row.id = night.id
        row.dayKey = dayKey
        row.date = night.date
        row.episodesJSON = SleepCoding.data(night.episodes)
        row.bedtime = night.bedtime
        row.wakeTime = night.wakeTime
        row.asleepHours = night.asleepHours
        row.inBedHours = night.inBedHours
        row.awakenings = night.awakenings
        row.wasoMinutes = night.wasoMinutes
        row.resolvedSourceJSON = SleepCoding.data(night.resolvedSource)
        row.analysisStatusRaw = night.analysisStatus.rawValue
        row.sourceFingerprint = night.sourceFingerprint
        row.composingSampleUUIDsJSON = SleepCoding.data(night.composingSampleUUIDs)
        row.lastHealthKitSyncAt = night.lastHealthKitSyncAt
        row.lastSampleEndDate = night.lastSampleEndDate
        row.revision = night.revision
        row.factsSchemaVersion = night.factsSchemaVersion
    }

    private func night(from row: SDSleepNight) -> SleepNight {
        SleepNight(
            id: row.id,
            date: row.date,
            episodes: SleepCoding.value([SleepEpisode].self, row.episodesJSON) ?? [],
            bedtime: row.bedtime,
            wakeTime: row.wakeTime,
            asleepHours: row.asleepHours,
            inBedHours: row.inBedHours,
            awakenings: row.awakenings,
            wasoMinutes: row.wasoMinutes,
            // The `.none` construction site: a missing/unreadable source blob degrades honestly.
            resolvedSource: SleepCoding.value(SleepSource.self, row.resolvedSourceJSON) ?? SleepSource.none,
            analysisStatus: SleepAnalysisStatus(rawValue: row.analysisStatusRaw) ?? .provisional,
            sourceFingerprint: row.sourceFingerprint,
            composingSampleUUIDs: SleepCoding.value([UUID].self, row.composingSampleUUIDsJSON) ?? [],
            lastHealthKitSyncAt: row.lastHealthKitSyncAt,
            lastSampleEndDate: row.lastSampleEndDate,
            revision: row.revision,
            factsSchemaVersion: row.factsSchemaVersion
        )
    }

    // MARK: - Fetch plumbing

    /// Canonical, timezone-tolerant day key (`yyyymmdd`) — calendar-*day* identity, not an
    /// instant, so the same wake day keys identically before and after a timezone change.
    private func dayKey(for date: Date) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    private func rows(dayKey key: Int) -> [SDSleepNight] {
        let descriptor = FetchDescriptor<SDSleepNight>(
            predicate: #Predicate { $0.dayKey == key },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Stale rows under OTHER day keys that are the same physical night as `candidate`:
    /// identical fingerprint, or any shared composing sample UUID. Ordered deterministically for
    /// adoption: exact fingerprint match first, then descending UUID overlap, then ascending
    /// day key. Same bounded-scan tradeoff as `nightDates(containingSampleUUIDs:)`.
    private func fragmentRows(of candidate: SleepNight, excludingDayKey key: Int) -> [SDSleepNight] {
        let candidateUUIDs = Set(candidate.composingSampleUUIDs)
        guard !candidateUUIDs.isEmpty || !candidate.sourceFingerprint.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<SDSleepNight>())) ?? []
        return all
            .filter { $0.dayKey != key }
            .compactMap { row -> (row: SDSleepNight, exact: Bool, overlap: Int)? in
                let rowUUIDs = SleepCoding.value([UUID].self, row.composingSampleUUIDsJSON) ?? []
                let overlap = candidateUUIDs.intersection(rowUUIDs).count
                let exact = !candidate.sourceFingerprint.isEmpty
                    && row.sourceFingerprint == candidate.sourceFingerprint
                guard exact || overlap > 0 else { return nil }
                return (row, exact, overlap)
            }
            .sorted {
                if $0.exact != $1.exact { return $0.exact }
                if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
                return $0.row.dayKey < $1.row.dayKey
            }
            .map(\.row)
    }

    private func syncRow(forKey key: String) -> SDSleepSyncState? {
        var descriptor = FetchDescriptor<SDSleepSyncState>(predicate: #Predicate { $0.queryKey == key })
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor)) ?? []).first
    }

    private func save() {
        try? context.save()
    }
}

// MARK: - Slice 1 store conformances

/// The repository IS the durable `SleepNightStore`/`SleepSyncCursorStore`, so
/// `SleepBackfillOrchestrator` runs on SwiftData without an adapter layer. `upsert` funnels
/// into `replaceCanonical` — one write path; the reconcile there is idempotent with the
/// orchestrator's own (same pure function, same result).
extension SwiftDataSleepRepository: SleepNightStore, SleepSyncCursorStore {
    func upsert(_ night: SleepNight) {
        replaceCanonical(night: night)
    }

    func remove(for date: Date) {
        removeNight(for: date)
    }

    func allNights() -> [SleepNight] {
        let descriptor = FetchDescriptor<SDSleepNight>(sortBy: [SortDescriptor(\.dayKey, order: .forward)])
        return ((try? context.fetch(descriptor)) ?? []).map(night(from:))
    }

    func cursor(forKey key: String) -> Data? {
        syncCursor(forKey: key)
    }

    func setCursor(_ cursor: Data?, forKey key: String) {
        setSyncCursor(cursor, forKey: key)
    }
}
