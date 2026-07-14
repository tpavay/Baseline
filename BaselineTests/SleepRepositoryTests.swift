import Foundation
import HealthKit
import SwiftData
import Testing
@testable import Baseline

private typealias Engine = SleepIngestionEngine
private typealias Fix = SleepFixtures

/// Slice 2 contract coverage for the store itself: AC-1 lossless round-trip + pinned Date
/// strategy, AC-2 CloudKit-safety/migration defaults + `.none` decode, AC-3 fingerprint-gated
/// replacement + single-row invariant, AC-6 window queries + timezone-shift tolerance.
/// Every test gets its own in-memory ModelContainer — nothing touches disk.
@MainActor
struct SleepRepositoryTests {

    private let container: ModelContainer
    private let repository: SwiftDataSleepRepository

    private let bedtime = Fix.date(2026, 3, 10, 23, 0)
    private let wakeDay = Fix.calendar.startOfDay(for: Fix.date(2026, 3, 11))
    private var settled: SleepIngestionEngine.Context { Fix.context(lastSyncAt: Fix.date(2026, 3, 11, 10, 0)) }

    init() throws {
        container = try ModelContainer(
            for: Schema(SleepSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        repository = SwiftDataSleepRepository(context: ModelContext(container), calendar: Fix.calendar)
    }

    /// "Reopen": a fresh context + repository over the same container — new object graph, same
    /// persisted rows (as close to a cold open as an in-memory store allows).
    private func reopenedRepository(calendar: Calendar = Fix.calendar) -> SwiftDataSleepRepository {
        SwiftDataSleepRepository(context: ModelContext(container), calendar: calendar)
    }

    private func rowCount() throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<SDSleepNight>())
    }

    // MARK: - AC-1: lossless round-trip

    @Test func fullNightRoundTripsLosslessly() throws {
        let night = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settled))

        #expect(repository.replaceCanonical(night: night) == .inserted)
        let fetched = try #require(reopenedRepository().night(for: wakeDay))

        // Full value equality: episodes, intervals with provenance, gaps, lifecycle,
        // fingerprint, and composing sample UUIDs all survive the store byte-stably.
        #expect(fetched == night)
        #expect(fetched.composingSampleUUIDs.count == Fix.stagedWatchNight(bedtime: bedtime).count)
    }

    @Test func dateStrategyIsPinnedToIntegerMilliseconds() throws {
        struct Wrap: Codable, Equatable { var d: Date }

        // A sub-millisecond date must round to integer ms — the same precision and rounding the
        // fingerprint canonicalization uses — and re-encode to identical bytes.
        let fractional = Wrap(d: Date(timeIntervalSince1970: 1000.1234567))
        let encoded = try SleepCoding.encoder.encode(fractional)
        #expect(String(decoding: encoded, as: UTF8.self) == #"{"d":1000123}"#)

        let decoded = try SleepCoding.decoder.decode(Wrap.self, from: encoded)
        #expect(decoded.d == Date(timeIntervalSince1970: 1000.123))
        #expect(try SleepCoding.encoder.encode(decoded) == encoded)
    }

    // MARK: - AC-2: migration defaults + `.none` decode

    @Test func rowMissingNewFieldsDecodesWithWorkingDefaults() throws {
        // Simulates a row written before optional-backed fields existed: backings nil, source
        // blob absent (the project's known add-a-scalar crash gotcha, guarded by design).
        let context = ModelContext(container)
        context.insert(SDSleepNight(dayKey: 20_260_311, date: wakeDay, sourceFingerprint: "legacy"))
        try context.save()

        let night = try #require(reopenedRepository().night(for: wakeDay))
        #expect(night.revision == 0)
        #expect(night.factsSchemaVersion == 1)
        #expect(night.resolvedSource == SleepSource.none)   // decode-path construction site
        #expect(night.analysisStatus == .provisional)
        #expect(night.episodes.isEmpty)
        #expect(night.composingSampleUUIDs.isEmpty)
    }

    @Test func sleepSourceNoneRoundTripsThroughTheBlob() throws {
        let encoded = SleepCoding.data(SleepSource.none)
        #expect(SleepCoding.value(SleepSource.self, encoded) == SleepSource.none)

        var night = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settled))
        night.resolvedSource = .none
        repository.replaceCanonical(night: night)
        #expect(reopenedRepository().night(for: wakeDay)?.resolvedSource == SleepSource.none)
    }

    // MARK: - AC-3: fingerprint-gated replacement

    @Test func replaceCanonicalIsFingerprintGated() throws {
        let night = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settled))
        #expect(repository.replaceCanonical(night: night) == .inserted)

        // Same samples, fresh assembly → same fingerprint → zero writes, stored row untouched.
        let rebuilt = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime),
            context: Fix.context(lastSyncAt: Fix.date(2026, 3, 11, 11, 0))))
        #expect(repository.replaceCanonical(night: rebuilt) == .unchanged)
        let afterUnchanged = try #require(repository.night(for: wakeDay))
        #expect(afterUnchanged.revision == 0)
        #expect(afterUnchanged.id == night.id)

        // Changed samples → single replacement, revision bumped, status revised, same identity.
        let changed = try #require(Engine.night(
            for: wakeDay,
            from: Fix.stagedWatchNight(bedtime: bedtime)
                + [Fix.watch(.awake, Fix.date(2026, 3, 11, 3, 0), Fix.date(2026, 3, 11, 3, 5))],
            context: settled))
        #expect(repository.replaceCanonical(night: changed) == .replaced)
        let revised = try #require(repository.night(for: wakeDay))
        #expect(revised.revision == 1)
        #expect(revised.analysisStatus == .revised)
        #expect(revised.id == night.id)
        #expect(try rowCount() == 1)
    }

    @Test func provisionalUpgradeWritesWithoutRevisionBump() throws {
        let samples = Fix.stagedWatchNight(bedtime: bedtime)
        let provisional = try #require(Engine.night(
            for: wakeDay, from: samples, context: Fix.context(lastSyncAt: Fix.date(2026, 3, 11, 7, 30))))
        #expect(repository.replaceCanonical(night: provisional) == .inserted)

        let complete = try #require(Engine.night(for: wakeDay, from: samples, context: settled))
        #expect(repository.replaceCanonical(night: complete) == .upgraded)
        let stored = try #require(repository.night(for: wakeDay))
        #expect(stored.analysisStatus == .complete)
        #expect(stored.revision == 0)
        #expect(try rowCount() == 1)
    }

    @Test func repeatedDivergentUpsertsNeverProduceTwoRowsForOneDate() throws {
        for extraMinutes in [0.0, 5, 10] {
            let samples = Fix.stagedWatchNight(bedtime: bedtime) + [Fix.watch(
                .awake,
                Fix.date(2026, 3, 11, 3, 0),
                Fix.date(2026, 3, 11, 3, 0).addingTimeInterval(60 + extraMinutes * 60))]
            let night = try #require(Engine.night(for: wakeDay, from: samples, context: settled))
            repository.replaceCanonical(night: night)
        }
        #expect(try rowCount() == 1)
        #expect(repository.night(for: wakeDay)?.revision == 2)
    }

    // MARK: - AC-6: window queries

    private func seedNights(count: Int, endingOn last: Date) throws {
        for offset in 0..<count {
            let day = Fix.calendar.date(byAdding: .day, value: -offset, to: last)!
            let night = try #require(Engine.night(
                for: day, from: Fix.simpleStagedNight(wakeDay: day), context: settled))
            repository.replaceCanonical(night: night)
        }
    }

    @Test func dayWindowQueriesReturnTheCorrectSets() throws {
        try seedNights(count: 35, endingOn: wakeDay)

        for days in [7, 14, 30] {
            let window = repository.nights(lastDays: days, endingOn: wakeDay)
            #expect(window.count == days)
            #expect(window.first?.date == Fix.calendar.date(byAdding: .day, value: -(days - 1), to: wakeDay))
            #expect(window.last?.date == wakeDay)   // "ending on" includes the end day
        }

        // Half-open interval: [today-9, today-2) excludes the today-2 night.
        let interval = DateInterval(
            start: Fix.calendar.date(byAdding: .day, value: -9, to: wakeDay)!,
            end: Fix.calendar.date(byAdding: .day, value: -2, to: wakeDay)!
        )
        let slice = repository.nights(in: interval)
        #expect(slice.count == 7)
        #expect(slice.last?.date == Fix.calendar.date(byAdding: .day, value: -3, to: wakeDay))

        let newestFive = repository.latest(limit: 5)
        #expect(newestFive.map(\.date) == (0..<5).map { Fix.calendar.date(byAdding: .day, value: -$0, to: wakeDay)! })
        // fetchLimit 0 is "unlimited" in Core Data — the repository must read it as "nothing".
        #expect(repository.latest(limit: 0).isEmpty)
    }

    @Test func emptyStoreReturnsEmptyEverything() {
        #expect(repository.night(for: wakeDay) == nil)
        #expect(repository.nights(lastDays: 30, endingOn: wakeDay).isEmpty)
        #expect(repository.latest(limit: 10).isEmpty)
        #expect(repository.syncCursor(forKey: "any") == nil)
    }

    @Test func timezoneShiftedDayKeyRekeysInsteadOfDuplicating() throws {
        // Assembled in New York…
        let samples = Fix.simpleStagedNight(wakeDay: wakeDay)
        let nyNight = try #require(Engine.night(for: wakeDay, from: samples, context: settled))
        #expect(repository.replaceCanonical(night: nyNight) == .inserted)

        // …then the athlete lands in Tokyo and the same physical samples re-assemble there. The
        // wake instant (07:00 NY = 21:00 Tokyo, past noon) pushes the night to the next Tokyo
        // day — a shifted day key for the same night.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let tokyoContext = SleepIngestionEngine.Context(
            calendar: tokyo, lastSyncAt: Fix.date(2026, 3, 12, 10, 0), stabilization: SleepStabilizationRule())
        let tokyoNights = Engine.nights(from: samples, context: tokyoContext)
        let tokyoNight = try #require(tokyoNights.first)
        #expect(tokyoNight.date != nyNight.date)
        #expect(tokyoNight.sourceFingerprint == nyNight.sourceFingerprint)   // same physical night

        let tokyoRepository = reopenedRepository(calendar: tokyo)
        #expect(tokyoRepository.replaceCanonical(night: tokyoNight) == .replaced)

        // Benign revision churn — never a duplicate, never a crash.
        #expect(try rowCount() == 1)
        let stored = try #require(tokyoRepository.night(for: tokyoNight.date))
        #expect(stored.revision == 1)
        #expect(stored.analysisStatus == .revised)
        #expect(stored.id == nyNight.id)
        #expect(tokyoRepository.night(for: nyNight.date) == nil)   // moved, not copied
    }

    private var tokyoCalendar: Calendar {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return tokyo
    }

    private func watchSample(_ uuid: UUID, _ start: Date, _ end: Date) -> SleepSample {
        SleepSample(uuid: uuid, start: start, end: end, kind: .core,
                    sourceBundleID: Fix.watchBundle, deviceModel: "Watch")
    }

    @Test func partialTimezoneShiftAbsorbsTheStaleFragmentRow() throws {
        // NY view: overnight U1 composes the Mar 11 night; an afternoon nap U3 composes the
        // Mar 12 night. In Tokyo BOTH samples fall into one window (Tokyo Mar 12), so the
        // reassembled night's fingerprint matches NEITHER stored row — the exact case where
        // fingerprint-only re-keying left the U1 row behind as a permanent duplicate.
        let u1 = UUID(), u3 = UUID()
        let overnight = watchSample(u1, Fix.date(2026, 3, 10, 23, 0), Fix.date(2026, 3, 11, 7, 0))
        let nap = watchSample(u3, Fix.date(2026, 3, 11, 13, 0), Fix.date(2026, 3, 11, 14, 0))
        for night in Engine.nights(from: [overnight, nap], context: settled) {
            repository.replaceCanonical(night: night)
        }
        #expect(try rowCount() == 2)
        let mar12NY = Fix.calendar.date(byAdding: .day, value: 1, to: wakeDay)!
        let napRowID = try #require(repository.night(for: mar12NY)).id

        let tokyoContext = SleepIngestionEngine.Context(
            calendar: tokyoCalendar, lastSyncAt: Fix.date(2026, 3, 12, 10, 0),
            stabilization: SleepStabilizationRule())
        let tokyoNights = Engine.nights(from: [overnight, nap], context: tokyoContext)
        #expect(tokyoNights.count == 1)
        let tokyoNight = try #require(tokyoNights.first)
        #expect(tokyoNight.sourceFingerprint != "")

        let tokyoRepository = reopenedRepository(calendar: tokyoCalendar)
        #expect(tokyoRepository.replaceCanonical(night: tokyoNight) == .replaced)

        // Single physical night, counted once: the U1 fragment is gone.
        #expect(try rowCount() == 1)
        let merged = try #require(tokyoRepository.night(for: tokyoNight.date))
        #expect(merged.id == napRowID)             // target-key row's identity preserved
        #expect(merged.revision == 1)
        #expect(merged.analysisStatus == .revised)
        #expect(Set(merged.composingSampleUUIDs) == Set([u1, u3]))
        #expect(tokyoRepository.nights(lastDays: 7, endingOn: tokyoNight.date).count == 1)
        #expect(tokyoRepository.night(for: wakeDay) == nil)   // no stale old-day row
    }

    @Test func partialShiftAdoptsTheFragmentWhenTargetKeyIsEmpty() throws {
        // NY view: ONE Mar 11 night holds evening segment U2 + overnight U1. In Tokyo they
        // split across Mar 11/Mar 12 — the overnight's new day key has no row, so the shifted
        // candidate must adopt the old row (identity + revision), not insert alongside it.
        let u1 = UUID(), u2 = UUID()
        let evening = watchSample(u2, Fix.date(2026, 3, 10, 18, 0), Fix.date(2026, 3, 10, 18, 30))
        let overnight = watchSample(u1, Fix.date(2026, 3, 10, 23, 0), Fix.date(2026, 3, 11, 7, 0))
        let nyNights = Engine.nights(from: [evening, overnight], context: settled)
        #expect(nyNights.count == 1)
        let originalID = try #require(nyNights.first).id
        repository.replaceCanonical(night: try #require(nyNights.first))

        let tokyoContext = SleepIngestionEngine.Context(
            calendar: tokyoCalendar, lastSyncAt: Fix.date(2026, 3, 12, 10, 0),
            stabilization: SleepStabilizationRule())
        let tokyoNights = Engine.nights(from: [evening, overnight], context: tokyoContext)
        #expect(tokyoNights.count == 2)
        let tokyoRepository = reopenedRepository(calendar: tokyoCalendar)

        // Process the shifted overnight FIRST: empty target key + overlapping fragment → adopt.
        let shiftedOvernight = try #require(tokyoNights.first { $0.composingSampleUUIDs.contains(u1) })
        #expect(tokyoRepository.replaceCanonical(night: shiftedOvernight) == .replaced)
        #expect(try rowCount() == 1)
        let adopted = try #require(tokyoRepository.night(for: shiftedOvernight.date))
        #expect(adopted.id == originalID)
        #expect(adopted.revision == 1)
        #expect(adopted.analysisStatus == .revised)

        // The evening segment then lands as its own (new) Tokyo night — two real nights, and
        // each sample is counted exactly once across the store.
        let eveningNight = try #require(tokyoNights.first { $0.composingSampleUUIDs.contains(u2) })
        #expect(tokyoRepository.replaceCanonical(night: eveningNight) == .inserted)
        #expect(try rowCount() == 2)
        let allUUIDs = tokyoRepository.latest(limit: 10).flatMap(\.composingSampleUUIDs)
        #expect(allUUIDs.sorted { $0.uuidString < $1.uuidString }
            == [u1, u2].sorted { $0.uuidString < $1.uuidString })
    }

    @Test func legacyRowsWithoutUUIDsAreNeverAbsorbedAsFragments() throws {
        // A pre-UUID legacy row (empty composing UUIDs, its own fingerprint — the AC-2 shape)
        // shares no samples with anything, so fragment matching must NEVER touch it: matching
        // on "no UUIDs recorded" would silently delete legacy history.
        let legacyDay = Fix.calendar.date(byAdding: .day, value: 1, to: wakeDay)!
        let context = ModelContext(container)
        context.insert(SDSleepNight(dayKey: 20_260_312, date: legacyDay, sourceFingerprint: "legacy-print"))
        try context.save()

        // A normal night lands at an ADJACENT day key — the legacy row must survive untouched.
        let night = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settled))
        #expect(repository.replaceCanonical(night: night) == .inserted)
        #expect(try rowCount() == 2)
        let legacy = try #require(reopenedRepository().night(for: legacyDay))
        #expect(legacy.sourceFingerprint == "legacy-print")

        // Symmetric top guard: a candidate with no UUIDs and no fingerprint absorbs nothing —
        // it inserts alongside, and both existing rows remain fetchable.
        var blank = night
        blank.id = UUID()
        blank.date = Fix.calendar.date(byAdding: .day, value: 2, to: wakeDay)!
        blank.composingSampleUUIDs = []
        blank.sourceFingerprint = ""
        #expect(repository.replaceCanonical(night: blank) == .inserted)
        #expect(try rowCount() == 3)
        #expect(reopenedRepository().night(for: legacyDay)?.sourceFingerprint == "legacy-print")
        #expect(reopenedRepository().night(for: wakeDay) != nil)
    }

    @Test func reverseTimezoneShiftRekeysSymmetrically() throws {
        // Tokyo → NY. A late Tokyo sleep (05:00–13:00, ends past Tokyo noon → Tokyo Mar 13)
        // reassembles in NY as a Mar 12 night — the day key shifts the other direction and the
        // same re-key path must hold.
        let tokyo = tokyoCalendar
        func tokyoDate(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
            tokyo.date(from: DateComponents(year: 2026, month: 3, day: d, hour: h, minute: m))!
        }
        let sample = watchSample(UUID(), tokyoDate(12, 5), tokyoDate(12, 13))

        let tokyoContext = SleepIngestionEngine.Context(
            calendar: tokyo, lastSyncAt: tokyoDate(12, 16), stabilization: SleepStabilizationRule())
        let tokyoNight = try #require(Engine.nights(from: [sample], context: tokyoContext).first)
        let tokyoRepository = reopenedRepository(calendar: tokyo)
        #expect(tokyoRepository.replaceCanonical(night: tokyoNight) == .inserted)

        let nyContext = Fix.context(lastSyncAt: Fix.date(2026, 3, 12, 10, 0))
        let nyNight = try #require(Engine.nights(from: [sample], context: nyContext).first)
        #expect(nyNight.date != tokyoNight.date)
        #expect(nyNight.sourceFingerprint == tokyoNight.sourceFingerprint)

        let nyRepository = reopenedRepository()
        #expect(nyRepository.replaceCanonical(night: nyNight) == .replaced)
        #expect(try rowCount() == 1)
        let stored = try #require(nyRepository.night(for: nyNight.date))
        #expect(stored.id == tokyoNight.id)
        #expect(stored.revision == 1)
        #expect(stored.analysisStatus == .revised)
        #expect(reopenedRepository(calendar: tokyo).night(for: tokyoNight.date) == nil)   // old Tokyo key empty
    }

    // MARK: - Sync cursor round-trip (repository half of AC-4)

    @Test func hkQueryAnchorCursorSurvivesReopen() throws {
        let anchor = HKQueryAnchor(fromValue: 42)
        let archived = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)

        repository.setSyncCursor(archived, forKey: SleepBackfillOrchestrator.sleepAnalysisCursorKey)
        let reopened = reopenedRepository()
        let restored = try #require(reopened.syncCursor(forKey: SleepBackfillOrchestrator.sleepAnalysisCursorKey))
        #expect(restored == archived)
        let unarchived = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: restored))
        #expect(unarchived == anchor)

        // Clearing sticks too.
        reopened.setSyncCursor(nil, forKey: SleepBackfillOrchestrator.sleepAnalysisCursorKey)
        #expect(reopenedRepository().syncCursor(forKey: SleepBackfillOrchestrator.sleepAnalysisCursorKey) == nil)
    }
}
