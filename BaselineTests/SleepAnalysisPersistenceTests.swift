import Foundation
import SwiftData
import Testing
@testable import Baseline

private typealias Engine = SleepIngestionEngine
private typealias Fix = SleepFixtures

/// Slice 3 contract coverage for the repository's lazy analysis persistence (AC-8): first read
/// derives + persists, current reads are zero-write, and a version bump (or a facts revision)
/// re-derives lazily and persists the new analysis. Derivation is injected so we can count
/// invocations and drive version bumps without touching `SleepEngine`.
@MainActor
struct SleepAnalysisPersistenceTests {

    /// Counts how many times the injected derivation actually ran — the "write" signal. Serial
    /// @MainActor tests, so unchecked Sendable is safe.
    private final class Spy: @unchecked Sendable { var count = 0 }

    private let container: ModelContainer
    private let bedtime = Fix.date(2026, 3, 10, 23, 0)
    private let wakeDay = Fix.calendar.startOfDay(for: Fix.date(2026, 3, 11))
    private var settled: SleepIngestionEngine.Context { Fix.context(lastSyncAt: Fix.date(2026, 3, 11, 10, 0)) }

    init() throws {
        container = try ModelContainer(
            for: Schema(SleepSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func derivation(agg: Int, score: Int, spy: Spy) -> SleepAnalysisDerivation {
        SleepAnalysisDerivation(
            currentAggregationVersion: agg, currentScoreAlgorithmVersion: score, historyWindowDays: 31,
            analyze: { night, history in
                spy.count += 1
                var analysis = SleepEngine.analyze(night: night, history: history)
                // Stamp the versions this derivation represents so the store's staleness check keys
                // on the injected versions, decoupled from the real engine constants.
                analysis.aggregationVersion = agg
                analysis.scoreAlgorithmVersion = score
                return analysis
            })
    }

    private func repo(agg: Int = 1, score: Int = 1, spy: Spy) -> SwiftDataSleepRepository {
        SwiftDataSleepRepository(context: ModelContext(container), calendar: Fix.calendar,
                                 derivation: derivation(agg: agg, score: score, spy: spy))
    }

    private func seededNight() throws -> SleepNight {
        try #require(Engine.night(for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settled))
    }

    /// The single stored row, read through a fresh context (reflects committed state).
    private func storedRow() throws -> SDSleepNight {
        try #require(try ModelContext(container).fetch(FetchDescriptor<SDSleepNight>()).first)
    }

    // MARK: - AC-8: first read derives + persists, then zero-write

    @Test func firstReadDerivesAndPersistsThenIsZeroWrite() throws {
        let spy = Spy()
        let repository = repo(spy: spy)
        repository.replaceCanonical(night: try seededNight())

        // A freshly written night carries no analysis until first read.
        #expect(try storedRow().analysisJSON == nil)

        let first = try #require(repository.analysis(for: wakeDay))
        #expect(spy.count == 1)
        #expect(try storedRow().analysisJSON != nil)          // persisted
        #expect(try storedRow().scoreAlgorithmVersionBacking == 1)
        // The night is alone in the store → no consistency baseline, so duration + interruptions
        // are observed (70 possible) and the score is honestly withheld (no renormalization).
        #expect(first.possiblePoints == 70)
        #expect(first.score == nil)

        // Second read: versions current → returns stored blob, no re-derivation.
        let second = try #require(repository.analysis(for: wakeDay))
        #expect(spy.count == 1)
        #expect(second == first)
    }

    @Test func reopenedRepositoryReadsStoredBlobWithoutDeriving() throws {
        let seedSpy = Spy()
        let seeder = repo(spy: seedSpy)
        seeder.replaceCanonical(night: try seededNight())
        _ = try #require(seeder.analysis(for: wakeDay))
        #expect(seedSpy.count == 1)

        // A fresh repository (same container, same versions) must serve the persisted analysis.
        let reopenSpy = Spy()
        let reopened = repo(spy: reopenSpy)
        _ = try #require(reopened.analysis(for: wakeDay))
        #expect(reopenSpy.count == 0)   // zero-write / zero-derive
    }

    // MARK: - AC-8: version-bump lazy re-derivation

    @Test func scoreAlgorithmVersionBumpReDerivesAndPersists() throws {
        let seedSpy = Spy()
        let seeder = repo(spy: seedSpy)
        seeder.replaceCanonical(night: try seededNight())
        _ = try #require(seeder.analysis(for: wakeDay))       // stored at v1
        #expect(try storedRow().scoreAlgorithmVersionBacking == 1)

        // A repository at scoreAlgorithmVersion 2 finds the stored v1 stale.
        let bumpSpy = Spy()
        let bumped = repo(score: 2, spy: bumpSpy)
        let reDerived = try #require(bumped.analysis(for: wakeDay))
        #expect(bumpSpy.count == 1)
        #expect(reDerived.scoreAlgorithmVersion == 2)
        #expect(try storedRow().scoreAlgorithmVersionBacking == 2)   // new analysis persisted

        // And now it's current for that repository → zero-write.
        _ = try #require(bumped.analysis(for: wakeDay))
        #expect(bumpSpy.count == 1)
    }

    @Test func aggregationVersionBumpAlsoReDerives() throws {
        let seedSpy = Spy()
        let seeder = repo(spy: seedSpy)
        seeder.replaceCanonical(night: try seededNight())
        _ = try #require(seeder.analysis(for: wakeDay))       // stored at agg 1

        let bumpSpy = Spy()
        let bumped = repo(agg: 2, spy: bumpSpy)
        let reDerived = try #require(bumped.analysis(for: wakeDay))
        #expect(bumpSpy.count == 1)
        #expect(reDerived.aggregationVersion == 2)
        #expect(try storedRow().aggregationVersionBacking == 2)
    }

    // MARK: - AC-6/MUST-FIX: production history window reaches flags beyond 31 days

    @Test func productionHistoryWindowReachesNotableFlagsBeyond31Days() throws {
        // The DEFAULT (.engine) derivation — its 90-night history window is what makes a
        // notable-night flag past ~30 days reachable; a 31-day window would silently cap it.
        let repository = SwiftDataSleepRepository(context: ModelContext(container), calendar: Fix.calendar)
        let base = Fix.calendar.startOfDay(for: Fix.date(2026, 6, 1))
        func noonSync(_ day: Date) -> SleepIngestionEngine.Context {
            Fix.context(lastSyncAt: Fix.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!)
        }

        // 46 prior nights at 8 h.
        for offset in 1...46 {
            let day = Fix.calendar.date(byAdding: .day, value: -offset, to: base)!
            let night = try #require(Engine.night(
                for: day, from: Fix.simpleStagedNight(wakeDay: day), context: noonSync(day)))
            repository.replaceCanonical(night: night)
        }
        // Newest night is the shortest → the worst across the full 46-day span.
        let prev = Fix.calendar.date(byAdding: .day, value: -1, to: base)!
        let bed = Fix.calendar.date(bySettingHour: 23, minute: 0, second: 0, of: prev)!
        let wake = Fix.calendar.date(bySettingHour: 5, minute: 0, second: 0, of: base)!  // 6 h
        let newest = try #require(Engine.night(for: base, from: [Fix.watch(.core, bed, wake)],
                                               context: noonSync(base)))
        repository.replaceCanonical(night: newest)

        let analysis = try #require(repository.analysis(for: base))
        let worstDays = analysis.flags.compactMap { flag -> Int? in
            if case .worstIn(let d) = flag { return d }; return nil
        }.first
        #expect(worstDays == 46)          // spans the whole store, not capped at ~30
        #expect((worstDays ?? 0) > 31)    // unreachable under the old 31-day window
    }

    // MARK: - AC-8: a facts revision invalidates the stored analysis

    @Test func factsRevisionInvalidatesStoredAnalysis() throws {
        let spy = Spy()
        let repository = repo(spy: spy)
        repository.replaceCanonical(night: try seededNight())
        _ = try #require(repository.analysis(for: wakeDay))   // derive #1
        #expect(spy.count == 1)

        // Same versions, but the night's facts change → the stored analysis is stale.
        let changed = try #require(Engine.night(
            for: wakeDay,
            from: Fix.stagedWatchNight(bedtime: bedtime)
                + [Fix.watch(.awake, Fix.date(2026, 3, 11, 3, 30), Fix.date(2026, 3, 11, 3, 40))],
            context: settled))
        #expect(repository.replaceCanonical(night: changed) == .replaced)
        #expect(try storedRow().analysisJSON == nil)          // cleared on facts write

        _ = try #require(repository.analysis(for: wakeDay))   // derive #2 from new facts
        #expect(spy.count == 2)
    }
}
