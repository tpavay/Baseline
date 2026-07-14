import Foundation
import Testing
@testable import Baseline

private typealias Engine = SleepIngestionEngine
private typealias Fix = SleepFixtures

/// Slice 1 contract coverage: AC-1 night assembly, AC-2 segmentation/assignment, AC-3 source
/// precedence, AC-4 fingerprints, AC-5 lifecycle, AC-7 boundaries — all pure, no HealthKit,
/// controlled clock throughout.
struct SleepIngestionTests {

    /// Canonical fixture night: bedtime 23:00 Mar 10, wake 07:00 Mar 11 (see SleepFixtures).
    private let bedtime = Fix.date(2026, 3, 10, 23, 0)
    private let wake = Fix.date(2026, 3, 11, 7, 0)
    private let wakeDay = Fix.calendar.startOfDay(for: Fix.date(2026, 3, 11))
    /// Well past wake + stabilization, so assembly tests read `complete` unless stated otherwise.
    private var settledContext: SleepIngestionEngine.Context { Fix.context(lastSyncAt: Fix.date(2026, 3, 11, 10, 0)) }

    // MARK: - AC-1: night assembly from a staged fixture

    @Test func stagedNightAssemblesCanonicalFacts() throws {
        let samples = Fix.stagedWatchNight(bedtime: bedtime)
        let night = try #require(Engine.night(for: wakeDay, from: samples, context: settledContext))

        #expect(night.date == wakeDay)
        #expect(night.bedtime == bedtime)
        #expect(night.wakeTime == wake)
        let asleepHours = try #require(night.asleepHours)
        let inBedHours = try #require(night.inBedHours)
        let wasoMinutes = try #require(night.wasoMinutes)
        #expect(abs(asleepHours - (7.0 + 25.0 / 60.0)) < 0.0001)
        #expect(abs(inBedHours - (8.0 + 10.0 / 60.0)) < 0.0001)
        #expect(night.awakenings == 2)
        #expect(abs(wasoMinutes - 15) < 0.0001)
        #expect(night.resolvedSource == .healthKit(bundleID: Fix.watchBundle))
        #expect(night.lastSampleEndDate == Fix.date(2026, 3, 11, 7, 5))   // the inBed sample's end
        #expect(night.revision == 0)
        #expect(night.factsSchemaVersion == Engine.factsSchemaVersion)

        let episode = try #require(night.primaryEpisode)
        #expect(night.episodes.count == 1)
        #expect(episode.intervals.count == 8)
        #expect(episode.gaps == [DateInterval(start: Fix.date(2026, 3, 11, 3, 0), end: Fix.date(2026, 3, 11, 3, 20))])
    }

    @Test func everyIntervalCarriesSourceProvenance() throws {
        let night = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settledContext))
        let sources = Set(night.episodes.flatMap(\.intervals).map(\.source))
        #expect(sources == [.healthKit(bundleID: Fix.watchBundle)])
    }

    // MARK: - AC-2: segmentation and noon-to-noon assignment

    @Test func napIsNotPrimaryAndDoesNotInflateAsleepHours() throws {
        // Afternoon nap on Mar 10 + full overnight block: both land in the Mar 11 night window.
        let samples = [
            Fix.watch(.core, Fix.date(2026, 3, 10, 14, 0), Fix.date(2026, 3, 10, 15, 0)),
            Fix.watch(.core, bedtime, wake),
        ]
        let night = try #require(Engine.night(for: wakeDay, from: samples, context: settledContext))

        #expect(night.episodes.count == 2)
        let primary = try #require(night.primaryEpisode)
        #expect(primary.start == bedtime)
        #expect(night.episodes.filter(\.isPrimary).count == 1)
        #expect(night.bedtime == bedtime)                     // nap start is not the night's bedtime
        let asleepHours = try #require(night.asleepHours)
        #expect(abs(asleepHours - 8) < 0.0001)                // nap hour excluded
    }

    @Test func splitSleepKeepsBothEpisodesAndLongestIsPrimary() throws {
        let samples = [
            Fix.watch(.core, Fix.date(2026, 3, 10, 22, 30), Fix.date(2026, 3, 11, 2, 30)),   // 4 h
            Fix.watch(.core, Fix.date(2026, 3, 11, 6, 0), Fix.date(2026, 3, 11, 8, 0)),      // 2 h
        ]
        let night = try #require(Engine.night(for: wakeDay, from: samples, context: settledContext))

        #expect(night.episodes.count == 2)
        let primary = try #require(night.primaryEpisode)
        #expect(primary.start == Fix.date(2026, 3, 10, 22, 30))
        let asleepHours = try #require(night.asleepHours)
        #expect(abs(asleepHours - 4) < 0.0001)
        #expect(night.wakeTime == Fix.date(2026, 3, 11, 2, 30))   // primary episode's end
    }

    @Test func midnightSpanningEpisodeAssignsToWakeDay() throws {
        let samples = [Fix.watch(.core, Fix.date(2026, 3, 10, 23, 30), Fix.date(2026, 3, 11, 6, 30))]
        let nights = Engine.nights(from: samples, context: settledContext)
        #expect(nights.count == 1)
        #expect(nights.first?.date == wakeDay)
    }

    @Test func afternoonSleepAssignsToNextRecoveryDay() throws {
        // Ends after noon → counts toward the *next* morning's recovery, per the noon boundary.
        let samples = [Fix.watch(.core, Fix.date(2026, 3, 10, 13, 0), Fix.date(2026, 3, 10, 14, 0))]
        let nights = Engine.nights(from: samples, context: settledContext)
        #expect(nights.count == 1)
        #expect(nights.first?.date == wakeDay)
    }

    // MARK: - AC-3: multi-source precedence

    private var phoneGeneric: SleepSample {
        SleepSample(start: Fix.date(2026, 3, 10, 23, 5), end: Fix.date(2026, 3, 11, 7, 10),
                    kind: .asleepUnspecified, sourceBundleID: Fix.phoneBundle, deviceModel: "iPhone")
    }

    private var ouraStaged: [SleepSample] {
        [
            SleepSample(start: Fix.date(2026, 3, 10, 23, 10), end: Fix.date(2026, 3, 11, 3, 0),
                        kind: .core, sourceBundleID: Fix.ouraBundle, deviceModel: "Oura Ring"),
            SleepSample(start: Fix.date(2026, 3, 11, 3, 0), end: Fix.date(2026, 3, 11, 6, 50),
                        kind: .rem, sourceBundleID: Fix.ouraBundle, deviceModel: "Oura Ring"),
        ]
    }

    @Test func watchStagedBeatsOverlappingPhoneGeneric() throws {
        let samples = Fix.stagedWatchNight(bedtime: bedtime) + [phoneGeneric]
        let night = try #require(Engine.night(for: wakeDay, from: samples, context: settledContext))

        #expect(night.resolvedSource == .healthKit(bundleID: Fix.watchBundle))
        // The phone's longer span must not leak into the canonical numbers.
        let asleepHours = try #require(night.asleepHours)
        #expect(abs(asleepHours - (7.0 + 25.0 / 60.0)) < 0.0001)
    }

    @Test func watchStagedBeatsThirdPartyStaged() throws {
        let samples = Fix.stagedWatchNight(bedtime: bedtime) + ouraStaged
        let night = try #require(Engine.night(for: wakeDay, from: samples, context: settledContext))
        #expect(night.resolvedSource == .healthKit(bundleID: Fix.watchBundle))
    }

    @Test func preferredSourceOverridesWatch() throws {
        let samples = Fix.stagedWatchNight(bedtime: bedtime) + ouraStaged
        let context = Fix.context(lastSyncAt: Fix.date(2026, 3, 11, 10, 0), preferred: Fix.ouraBundle)
        let night = try #require(Engine.night(for: wakeDay, from: samples, context: context))

        #expect(night.resolvedSource == .healthKit(bundleID: Fix.ouraBundle))
        let sources = Set(night.episodes.flatMap(\.intervals).map(\.source))
        #expect(sources == [.healthKit(bundleID: Fix.ouraBundle)])
    }

    @Test func manualOnlyResolvesToManual() throws {
        let samples = [SleepSample(
            start: Fix.date(2026, 3, 10, 23, 0), end: Fix.date(2026, 3, 11, 6, 0),
            kind: .asleepUnspecified, sourceBundleID: Fix.healthAppBundle, isUserEntered: true)]
        let night = try #require(Engine.night(for: wakeDay, from: samples, context: settledContext))

        #expect(night.resolvedSource == .manual)
        let asleepHours = try #require(night.asleepHours)
        #expect(abs(asleepHours - 7) < 0.0001)
        // A manual entry can't observe awakenings — unknown, never imputed to zero.
        #expect(night.awakenings == nil)
        #expect(night.wasoMinutes == nil)
        #expect(night.episodes.flatMap(\.intervals).map(\.stage) == [.unspecified])
        #expect(night.episodes.flatMap(\.intervals).map(\.source) == [.manual])
    }

    @Test func genericSourceLeavesAwakeningsUnknown() throws {
        let night = try #require(Engine.night(for: wakeDay, from: [phoneGeneric], context: settledContext))
        #expect(night.resolvedSource == .healthKit(bundleID: Fix.phoneBundle))
        #expect(night.awakenings == nil)
        #expect(night.wasoMinutes == nil)
    }

    @Test func stageIntervalsAreNeverMergedAcrossSources() throws {
        // All three sources overlap; the canonical night must contain exactly one source's
        // intervals — the same 8 the watch produces alone (the never-merge negative assertion).
        let samples = Fix.stagedWatchNight(bedtime: bedtime) + ouraStaged + [phoneGeneric]
        let night = try #require(Engine.night(for: wakeDay, from: samples, context: settledContext))

        let intervals = night.episodes.flatMap(\.intervals)
        #expect(Set(intervals.map(\.source)) == [.healthKit(bundleID: Fix.watchBundle)])
        #expect(intervals.count == 8)
    }

    // MARK: - AC-4: fingerprint determinism

    @Test func fingerprintIsDeterministicAcrossRebuildsAndOrderings() throws {
        // Fresh Date instances both times — determinism must come from the values, not identity.
        let first = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: Fix.date(2026, 3, 10, 23, 0)), context: settledContext))
        let second = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: Fix.date(2026, 3, 10, 23, 0)).reversed(), context: settledContext))

        #expect(first.sourceFingerprint == second.sourceFingerprint)
        #expect(!first.sourceFingerprint.isEmpty)

        let samples = Fix.stagedWatchNight(bedtime: bedtime)
        #expect(Engine.fingerprint(of: samples) == Engine.fingerprint(of: samples.shuffled()))
    }

    @Test func fingerprintChangesWhenAComposingSampleChanges() throws {
        var mutated = Fix.stagedWatchNight(bedtime: bedtime)
        mutated[mutated.count - 1].end = mutated[mutated.count - 1].end.addingTimeInterval(60)

        let original = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settledContext))
        let changed = try #require(Engine.night(for: wakeDay, from: mutated, context: settledContext))
        #expect(original.sourceFingerprint != changed.sourceFingerprint)
    }

    // MARK: - AC-5: provisional → complete → revised lifecycle (injected clock)

    @Test func nightInsideStabilizationWindowIsProvisional() throws {
        // Synced 30 minutes after a 07:00 wake — the watch may still be delivering samples.
        let early = Fix.context(lastSyncAt: Fix.date(2026, 3, 11, 7, 30))
        let night = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: early))
        #expect(night.analysisStatus == .provisional)
    }

    @Test func nightSyncedAfterStabilizationIsComplete() throws {
        let night = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settledContext))
        #expect(night.analysisStatus == .complete)
    }

    @Test func provisionalUpgradesToCompleteWithoutRevisionBump() throws {
        let samples = Fix.stagedWatchNight(bedtime: bedtime)
        let provisional = try #require(Engine.night(
            for: wakeDay, from: samples, context: Fix.context(lastSyncAt: Fix.date(2026, 3, 11, 7, 30))))
        let candidate = try #require(Engine.night(for: wakeDay, from: samples, context: settledContext))

        let outcome = SleepNightLifecycle.reconcile(previous: provisional, candidate: candidate)
        guard case .store(let upgraded) = outcome else {
            Issue.record("expected a status-upgrade write, got \(String(describing: outcome))")
            return
        }
        #expect(upgraded.analysisStatus == .complete)
        #expect(upgraded.revision == 0)
        #expect(upgraded.id == provisional.id)
        #expect(upgraded.sourceFingerprint == provisional.sourceFingerprint)
        #expect(upgraded.lastHealthKitSyncAt == Fix.date(2026, 3, 11, 10, 0))
    }

    @Test func unchangedFingerprintLeavesStoredNightUntouched() throws {
        let stored = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settledContext))
        let candidate = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime),
            context: Fix.context(lastSyncAt: Fix.date(2026, 3, 11, 11, 0))))

        #expect(SleepNightLifecycle.reconcile(previous: stored, candidate: candidate) == .unchanged(stored))
    }

    @Test func changedFingerprintRevisesWithBumpedRevision() throws {
        let stored = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settledContext))
        // A late Health sync delivers one more awakening inside the old tracking gap.
        let delta = Fix.stagedWatchNight(bedtime: bedtime)
            + [Fix.watch(.awake, Fix.date(2026, 3, 11, 3, 0), Fix.date(2026, 3, 11, 3, 5))]
        let candidate = try #require(Engine.night(
            for: wakeDay, from: delta, context: Fix.context(lastSyncAt: Fix.date(2026, 3, 11, 11, 0))))

        let outcome = SleepNightLifecycle.reconcile(previous: stored, candidate: candidate)
        guard case .store(let revised) = outcome else {
            Issue.record("expected a revision write, got \(String(describing: outcome))")
            return
        }
        #expect(revised.analysisStatus == .revised)
        #expect(revised.revision == 1)
        #expect(revised.id == stored.id)          // replaced canonical night, same identity
        #expect(revised.sourceFingerprint != stored.sourceFingerprint)
        #expect(revised.awakenings == 3)
    }

    @Test func reconcileHandlesMissingSides() throws {
        #expect(SleepNightLifecycle.reconcile(previous: nil, candidate: nil) == nil)

        let night = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settledContext))
        #expect(SleepNightLifecycle.reconcile(previous: nil, candidate: night) == .store(night))
        #expect(SleepNightLifecycle.reconcile(previous: night, candidate: nil) == .unchanged(night))
    }

    // MARK: - AC-7: boundary and invalid inputs

    @Test func emptySamplesYieldNoNight() {
        #expect(Engine.night(for: wakeDay, from: [], context: settledContext) == nil)
        #expect(Engine.nights(from: [], context: settledContext).isEmpty)
    }

    @Test func zeroDurationSamplesAreDroppedSafely() throws {
        let instant = Fix.date(2026, 3, 11, 3, 0)
        let zeroOnly = [Fix.watch(.core, instant, instant)]
        #expect(Engine.night(for: wakeDay, from: zeroOnly, context: settledContext) == nil)

        // Mixed in with a real night, zero-duration noise must not move any number.
        let clean = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime), context: settledContext))
        let noisy = try #require(Engine.night(
            for: wakeDay, from: Fix.stagedWatchNight(bedtime: bedtime) + zeroOnly, context: settledContext))
        #expect(noisy.sourceFingerprint == clean.sourceFingerprint)
        #expect(noisy.asleepHours == clean.asleepHours)
    }

    @Test func overlappingSameSourceSamplesDoNotDoubleCount() throws {
        let samples = [
            Fix.watch(.core, Fix.date(2026, 3, 10, 23, 0), Fix.date(2026, 3, 11, 1, 0)),
            Fix.watch(.core, Fix.date(2026, 3, 11, 0, 30), Fix.date(2026, 3, 11, 1, 30)),
        ]
        let night = try #require(Engine.night(for: wakeDay, from: samples, context: settledContext))

        let asleepHours = try #require(night.asleepHours)
        #expect(abs(asleepHours - 2.5) < 0.0001)                        // union, not sum (3.0)
        let intervals = night.episodes.flatMap(\.intervals)
        #expect(intervals.count == 1)                                   // merged into one span
        #expect(intervals.first?.end == Fix.date(2026, 3, 11, 1, 30))
    }

    @Test func inBedOnlySamplesAreNotANight() {
        let samples = [Fix.watch(.inBed, Fix.date(2026, 3, 10, 22, 0), Fix.date(2026, 3, 11, 7, 0))]
        #expect(Engine.night(for: wakeDay, from: samples, context: settledContext) == nil)
    }
}

/// AC-7's error/offline row: unauthorized HealthKit reads come back as empty data, never a throw.
/// (In the test host, sleep read access is never requested, and HealthKit reports denial and
/// absence identically — as no samples.)
@MainActor
struct HealthServiceSleepAccessTests {

    @Test func unauthorizedSleepQueriesReturnEmptyWithoutThrowing() async throws {
        let defaults = try #require(UserDefaults(suiteName: "HealthServiceSleepAccessTests"))
        defaults.removePersistentDomain(forName: "HealthServiceSleepAccessTests")
        let service = HealthService(defaults: defaults)

        let window = DateInterval(start: SleepFixtures.date(2026, 3, 10, 12, 0),
                                  end: SleepFixtures.date(2026, 3, 11, 12, 0))
        let samples = await service.sleepSamples(in: window)
        #expect(samples.isEmpty)

        let delta = await service.sleepSampleDelta(after: nil)
        #expect(delta.samples.isEmpty)
    }
}
