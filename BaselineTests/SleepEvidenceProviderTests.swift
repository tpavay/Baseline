import Foundation
import SwiftData
import Testing
@testable import Baseline

private typealias Engine = SleepIngestionEngine
private typealias Fix = SleepFixtures

/// Slice 4 (issue #7) AC-4: `SleepEvidenceProvider` maps a repository's canonical `SleepAnalysis` →
/// `DecisionEngine` sleep inputs, threading `need` from `ReadinessConfig`, and a manual/partial night
/// (score == nil) yields no engine score so the seam uses the subjective fallback.
@MainActor
struct SleepEvidenceProviderTests {

    private let container: ModelContainer
    private let repository: SwiftDataSleepRepository

    init() throws {
        container = try ModelContainer(
            for: Schema(SleepSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        repository = SwiftDataSleepRepository(context: ModelContext(container), calendar: Fix.calendar)
    }

    // MARK: - Fixtures

    /// A staged watch night for the given wake day, bedtime 23:00 the evening before.
    private func stagedNight(wakeYear: Int, month: Int, day: Int) throws -> SleepNight {
        let bedtime = Fix.date(wakeYear, month, day - 1, 23, 0)
        let wakeDay = Fix.calendar.startOfDay(for: Fix.date(wakeYear, month, day))
        let settled = Fix.context(lastSyncAt: Fix.date(wakeYear, month, day, 10, 0))
        return try #require(Engine.night(for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settled))
    }

    /// A simple staged (single core block) prior night — supplies a device-observed bedtime for the
    /// consistency baseline without any awakenings.
    private func simplePrior(wakeYear: Int, month: Int, day: Int) throws -> SleepNight {
        let wakeDay = Fix.calendar.startOfDay(for: Fix.date(wakeYear, month, day))
        let settled = Fix.context(lastSyncAt: Fix.date(wakeYear, month, day, 10, 0))
        return try #require(Engine.night(for: wakeDay, from: Fix.simpleStagedNight(wakeDay: wakeDay), context: settled))
    }

    private func manualNight(wakeYear: Int, month: Int, day: Int, asleepHours: Double) -> SleepNight {
        let wakeDay = Fix.calendar.startOfDay(for: Fix.date(wakeYear, month, day))
        return SleepNight(
            id: UUID(), date: wakeDay, episodes: [], bedtime: nil, wakeTime: nil,
            asleepHours: asleepHours, inBedHours: nil, awakenings: nil, wasoMinutes: nil,
            resolvedSource: .manual, analysisStatus: .complete, sourceFingerprint: "manual-\(day)",
            composingSampleUUIDs: [], lastHealthKitSyncAt: nil, lastSampleEndDate: nil,
            revision: 0, factsSchemaVersion: 1
        )
    }

    // MARK: - AC-4: staged night publishes a score with structured evidence

    @Test func stagedNightMapsToPublishedScoreAndStructuredInputs() throws {
        // Six device priors (03-05…03-10) give the consistency baseline; the target is 03-11.
        for d in 5...10 { repository.replaceCanonical(night: try simplePrior(wakeYear: 2026, month: 3, day: d)) }
        repository.replaceCanonical(night: try stagedNight(wakeYear: 2026, month: 3, day: 11))

        let provider = RepositorySleepEvidenceProvider(repository: repository)   // default need 8 h
        let inputs = try #require(provider.sleepInputs(on: Fix.date(2026, 3, 11, 8, 0)))

        // All three components observed → a published score, and a fully staged, gap-tolerant night
        // clears the coverage∧reliability bar → certainty-eligible confidence == reliability (1.0).
        #expect(inputs.sleepScore != nil)
        #expect(inputs.sleepConfidence == 1.0)
        // asleep 7 h 25 m vs an 8 h need → ~0.583 h deficit.
        let deficit = try #require(inputs.sleepDurationDeficit)
        #expect(abs(deficit - (8.0 - 7.41667)) < 0.01)
        #expect(inputs.sleepInterruptionBurden != nil)   // staged source → WASO observed
    }

    // MARK: - AC-4: need is threaded from ReadinessConfig

    @Test func needIsThreadedFromConfig() throws {
        repository.replaceCanonical(night: try stagedNight(wakeYear: 2026, month: 3, day: 11))
        let date = Fix.date(2026, 3, 11, 8, 0)

        let eightHour = RepositorySleepEvidenceProvider(repository: repository, config: ReadinessConfig())
        var ninefig = ReadinessConfig(); ninefig.sleepNeedHours = 9
        let nineHour = RepositorySleepEvidenceProvider(repository: repository, config: ninefig)

        let d8 = try #require(eightHour.sleepInputs(on: date)?.sleepDurationDeficit)
        let d9 = try #require(nineHour.sleepInputs(on: date)?.sleepDurationDeficit)
        // A larger need means a larger deficit for the same asleep hours — exactly one hour more.
        #expect(abs((d9 - d8) - 1.0) < 0.001)
    }

    // MARK: - AC-4: manual night → no engine score → subjective fallback

    @Test func manualNightPublishesNoScoreAndFallsBackToSubjective() throws {
        repository.replaceCanonical(night: manualNight(wakeYear: 2026, month: 3, day: 11, asleepHours: 6.0))
        let provider = RepositorySleepEvidenceProvider(repository: repository)
        let inputs = try #require(provider.sleepInputs(on: Fix.date(2026, 3, 11, 8, 0)))

        // AC-2b/AC-4: a manual night is duration-only-as-evidence — it never publishes a score and
        // never feeds a decision signal.
        #expect(inputs.sleepScore == nil)
        #expect(inputs.sleepDurationDeficit == nil)

        // The seam then routes to the single manual path (thumbs-up here → 85), not the engine.
        let result = SleepDecisionSeam.resolve(.engine(inputs), manual: .init(hours: nil, thumbsUp: true))
        #expect(result.sleepScore == 85)
        #expect(result.snapshot == nil)
    }

    @Test func absentNightReturnsNil() {
        let provider = RepositorySleepEvidenceProvider(repository: repository)
        #expect(provider.sleepInputs(on: Fix.date(2026, 3, 11, 8, 0)) == nil)
    }

    // MARK: - AC-4: quality→confidence mapping (unit level)

    @Test func confidenceEncodesTheCoverageReliabilityBar() {
        // Cleared bar (staged, good coverage) → confidence == reliability.
        let cleared = SleepDecisionInputs(analysis: TestSleepAnalysis.make(score: 82, coverage: 0.95, reliability: 1.0))
        #expect(cleared.sleepConfidence == 1.0)

        // Low coverage (device night, few observed components still published) → below bar → 0.
        let lowCoverage = SleepDecisionInputs(analysis: TestSleepAnalysis.make(score: 82, coverage: 0.5, reliability: 1.0))
        #expect(lowCoverage.sleepConfidence == 0.0)

        // Low reliability → below bar → 0.
        let lowReliability = SleepDecisionInputs(analysis: TestSleepAnalysis.make(score: 82, coverage: 0.95, reliability: 0.3))
        #expect(lowReliability.sleepConfidence == 0.0)
    }
}

/// Hand-built `SleepAnalysis` values for unit-level mapping/snapshot tests — no engine, no store.
enum TestSleepAnalysis {
    static func make(score: Int?,
                     coverage: Double = 1.0,
                     reliability: Double = 1.0,
                     asleepHours: Double? = 7.0,
                     deficit: Double? = 1.0,
                     burden: Double? = 0.2,
                     shift: Double? = 15) -> SleepAnalysis {
        SleepAnalysis(
            observedPoints: score ?? 0,
            possiblePoints: 100,
            score: score,
            asleepHours: asleepHours,
            wasoMinutes: 10,
            awakenings: 1,
            components: [],
            additionalEvidence: SleepStageEvidence(
                remMinutes: 0, deepMinutes: 0, coreMinutes: 0,
                remFraction: 0, deepFraction: 0, coreFraction: 0,
                sleepOnset: nil, finalWake: nil, gapMinutes: 0),
            quality: SleepEvidenceQuality(coverage: coverage, reliability: reliability, status: .complete, reasons: []),
            vsBaseline: SleepComparison(acute7Mean: nil, chronic30Mean: nil, debt14Hours: 0),
            consistency: SleepConsistency(bedtimeMeanSecondsOfDay: nil, bedtimeStdMinutes: nil,
                                          wakeMeanSecondsOfDay: nil, wakeStdMinutes: nil,
                                          recordedNights: 0, isAvailable: false),
            flags: [],
            decisionEvidence: SleepDecisionEvidence(durationDeficitHours: deficit,
                                                    interruptionBurden: burden,
                                                    scheduleShiftMinutes: shift),
            aggregationVersion: SleepEngine.aggregationVersion,
            scoreAlgorithmVersion: SleepEngine.scoreAlgorithmVersion
        )
    }
}
