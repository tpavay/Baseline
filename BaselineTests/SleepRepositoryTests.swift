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
