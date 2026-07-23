import Foundation
import Testing
@testable import Baseline

private typealias Fix = SleepFixtures

/// Slice 3 contract coverage for the pure scoring engine (AC-1/2/3/4/5/6/9). Everything is
/// hand-constructed with pinned dates (no `Date()`); component values are pinned to hand-computed
/// figures, not re-derived from the formula under test.
struct SleepEngineTests {

    // A non-DST base wake day (America/New_York springs forward 2026-03-08; April is clear).
    private let wakeDay = Fix.calendar.startOfDay(for: Fix.date(2026, 4, 20))
    private let need: Duration = .seconds(8 * 3600)

    // MARK: - Builders

    /// Full control over one night's facts + primary-episode stage structure.
    private func mkNight(wakeDay: Date, bedtime: Date, wake: Date? = nil,
                         asleepHours: Double?, waso: Double? = 15, awakenings: Int? = 2,
                         remMin: Double = 90, deepMin: Double = 60, coreMin: Double = 260,
                         awakeMin: Double = 0,
                         staged: Bool = true,
                         source: SleepSource = .healthKit(bundleID: Fix.watchBundle),
                         gaps: [DateInterval] = [],
                         status: SleepAnalysisStatus = .complete) -> SleepNight {
        var intervals: [SleepStageInterval] = []
        var cursor = bedtime
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            let end = cursor.addingTimeInterval(minutes * 60)
            intervals.append(SleepStageInterval(stage: stage, start: cursor, end: end, source: source))
            cursor = end
        }
        if staged {
            add(.core, coreMin); add(.deep, deepMin); add(.rem, remMin); add(.awake, awakeMin)
        } else if let asleepHours {
            intervals.append(SleepStageInterval(
                stage: .unspecified, start: bedtime,
                end: bedtime.addingTimeInterval(asleepHours * 3600), source: source))
        }
        let episodeEnd = wake ?? bedtime.addingTimeInterval(((asleepHours ?? 0) + (waso ?? 0) / 60) * 3600)
        let primary = SleepEpisode(id: UUID(), start: bedtime, end: episodeEnd,
                                   intervals: intervals, isPrimary: true, gaps: gaps)
        return SleepNight(
            id: UUID(), date: wakeDay, episodes: [primary],
            bedtime: bedtime, wakeTime: episodeEnd, asleepHours: asleepHours, inBedHours: nil,
            awakenings: awakenings, wasoMinutes: waso, resolvedSource: source,
            analysisStatus: status, sourceFingerprint: "fp", composingSampleUUIDs: [],
            lastHealthKitSyncAt: nil, lastSampleEndDate: nil, revision: 0, factsSchemaVersion: 1)
    }

    /// Evening bedtime the day before `wakeDay`, at `hour:minute`.
    private func bedtimeBefore(_ wakeDay: Date, hour: Int = 23, minute: Int = 0) -> Date {
        let prev = Fix.calendar.date(byAdding: .day, value: -1, to: wakeDay)!
        return Fix.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: prev)!
    }

    /// A device prior `dayOffset` days before `wakeDay`.
    private func prior(dayOffset: Int, asleepHours: Double = 7.0, bedtimeHour: Int = 23,
                       source: SleepSource = .healthKit(bundleID: Fix.watchBundle),
                       staged: Bool = true) -> SleepNight {
        let day = Fix.calendar.date(byAdding: .day, value: -dayOffset, to: wakeDay)!
        return mkNight(wakeDay: day, bedtime: bedtimeBefore(day, hour: bedtimeHour),
                       asleepHours: asleepHours, staged: staged, source: source)
    }

    private func priors(_ offsets: [Int], asleepHours: Double = 7.0, bedtimeHour: Int = 23) -> [SleepNight] {
        offsets.map { prior(dayOffset: $0, asleepHours: asleepHours, bedtimeHour: bedtimeHour) }
    }

    // MARK: - AC-1: full component scoring + sum

    @Test func fullyObservedNightScoresAllThreeComponents() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay),
                            asleepHours: 7.0 + 25.0 / 60, waso: 15, awakenings: 2)  // 7h25m asleep
        let analysis = SleepEngine.analyze(night: night, history: priors(Array(1...6)), need: need)

        let duration = analysis.component(.duration)!
        let consistency = analysis.component(.bedtimeConsistency)!
        let interruptions = analysis.component(.interruptions)!

        // Duration: floor = need/2 = 4h; 50·(7.41667−4)/(8−4) = 42.7083.
        #expect(duration.isAvailable)
        #expect(abs(duration.value - 42.708333) < 0.0005)
        // Consistency: all six priors + tonight at 23:00 → deviation 0 → full 30.
        #expect(consistency.isAvailable)
        #expect(abs(consistency.value - 30) < 1e-9)
        // Interruptions: WASO 15 ≤ 20 grace → full 12; awakenings 2 → 8·(1−1/5) = 6.4.
        #expect(interruptions.isAvailable)
        #expect(abs(interruptions.value - 18.4) < 1e-9)

        #expect(analysis.possiblePoints == 100)
        #expect(analysis.observedPoints == 91)   // 43 + 30 + 18 (components round before summing)
        #expect(analysis.score == 91)
        #expect(analysis.score == analysis.observedPoints)
        #expect(analysis.needHours == 8)         // the need the night was scored against, stamped
    }

    @Test func scoreIsAlwaysTheSumOfTheRoundedComponents() {
        // Engineered so v1's round-the-unrounded-sum scheme would disagree with the visible rows:
        // duration 49.4 (asleep 7.952 h) + consistency 16.4 (bedtime 111.6 min off the 23:00 mean)
        // + interruptions 11.4 (WASO 51.5 → 6.6, awakenings 3 → 4.8) = 77.2 → v1 said 77 while the
        // rows showed 49/16/11 = 76. v2 publishes exactly the row sum.
        let lateBedtime = Fix.calendar.date(bySettingHour: 0, minute: 51, second: 36, of: wakeDay)!
        let night = mkNight(wakeDay: wakeDay, bedtime: lateBedtime,
                            asleepHours: 7.952, waso: 51.5, awakenings: 3)
        let analysis = SleepEngine.analyze(night: night, history: priors(Array(1...6)), need: need)

        let components = analysis.components.filter(\.isAvailable)
        #expect(abs(components[0].value - 49.4) < 1e-9)
        #expect(abs(components[1].value - 16.4) < 1e-6)
        #expect(abs(components[2].value - 11.4) < 1e-9)

        let rowSum = components.map { Int($0.value.rounded()) }.reduce(0, +)
        #expect(rowSum == 76)
        #expect(analysis.observedPoints == 76)
        #expect(analysis.score == 76)            // never the v1 off-by-one 77
    }

    @Test func durationTaperIsFullAtNeedAndZeroAtHalfNeed() {
        func durationPoints(asleep: Double) -> Double {
            let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: asleep)
            return SleepEngine.analyze(night: night, history: priors(Array(1...6)), need: need)
                .component(.duration)!.value
        }
        #expect(abs(durationPoints(asleep: 8.0) - 50) < 1e-9)   // ≥ need → full
        #expect(abs(durationPoints(asleep: 9.0) - 50) < 1e-9)   // above need still capped
        #expect(abs(durationPoints(asleep: 6.0) - 25) < 1e-9)   // 50·(6−4)/4
        #expect(abs(durationPoints(asleep: 4.0) - 0) < 1e-9)    // at floor
        #expect(abs(durationPoints(asleep: 3.0) - 0) < 1e-9)    // below floor clamped
    }

    // MARK: - AC-2: no renormalization / observed-points path

    @Test func manualNightNeverScores() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay),
                            asleepHours: 7.5, waso: nil, awakenings: nil,
                            staged: false, source: .manual)
        // AC-2b: even with ample history a manual night takes NO scoring path - no duration points,
        // no consistency, no interruptions. The single manual route is Slice 4's subjective fallback.
        let analysis = SleepEngine.analyze(night: night, history: priors(Array(1...10)), need: need)

        #expect(!analysis.component(.duration)!.isAvailable)         // no duration-scoring path
        #expect(!analysis.component(.bedtimeConsistency)!.isAvailable)
        #expect(!analysis.component(.interruptions)!.isAvailable)
        #expect(analysis.observedPoints == 0)
        #expect(analysis.possiblePoints == 0)
        #expect(analysis.score == nil)
        #expect(abs(analysis.quality.reliability - 0.3) < 1e-9)      // lowest source tier
        // The manual duration survives as evidence, it just earns nothing.
        #expect(analysis.asleepHours == 7.5)
    }

    @Test func unknownSourceNightNeverScores() {
        // A corrupt-decode (.none) source is likewise never scored.
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay),
                            asleepHours: 7.5, waso: nil, awakenings: nil,
                            staged: false, source: .none)
        let analysis = SleepEngine.analyze(night: night, history: priors(Array(1...10)), need: need)
        #expect(analysis.observedPoints == 0)
        #expect(analysis.possiblePoints == 0)
        #expect(analysis.score == nil)
    }

    @Test func coldStartSuppressesConsistencyNoRenormalization() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 7.5)
        // Only 4 prior nights → below the 5-night consistency floor.
        let analysis = SleepEngine.analyze(night: night, history: priors(Array(1...4)), need: need)

        #expect(analysis.component(.duration)!.isAvailable)
        #expect(!analysis.component(.bedtimeConsistency)!.isAvailable)
        #expect(analysis.component(.interruptions)!.isAvailable)
        #expect(analysis.possiblePoints == 70)   // 50 + 20, never scaled to 100
        #expect(analysis.score == nil)
        #expect(!analysis.consistency.isAvailable)
        #expect(analysis.consistency.recordedNights == 4)
    }

    @Test func genericSourceWithoutStagesSuppressesInterruptions() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay),
                            asleepHours: 7.5, waso: nil, awakenings: nil,
                            staged: false, source: .healthKit(bundleID: Fix.phoneBundle))
        let analysis = SleepEngine.analyze(night: night, history: priors(Array(1...6)), need: need)

        #expect(analysis.component(.duration)!.isAvailable)
        #expect(analysis.component(.bedtimeConsistency)!.isAvailable)   // device bedtime + history
        #expect(!analysis.component(.interruptions)!.isAvailable)       // no awake-stage evidence
        #expect(analysis.possiblePoints == 80)
        #expect(analysis.score == nil)
    }

    // MARK: - AC-3: stages never move the score

    @Test func stageDistributionDoesNotChangeScore() {
        let base: (Double, Double, Double) -> SleepNight = { rem, deep, core in
            self.mkNight(wakeDay: self.wakeDay, bedtime: self.bedtimeBefore(self.wakeDay),
                         asleepHours: 7.5, waso: 15, awakenings: 2,
                         remMin: rem, deepMin: deep, coreMin: core)
        }
        let history = priors(Array(1...6))
        let a = SleepEngine.analyze(night: base(120, 40, 290), history: history, need: need)
        let b = SleepEngine.analyze(night: base(40, 120, 290), history: history, need: need)

        // Identical score and components…
        #expect(a.score == b.score)
        #expect(a.components == b.components)
        #expect(a.observedPoints == b.observedPoints)
        // …but the additional (unscored) evidence reflects the distribution difference.
        #expect(a.additionalEvidence.remMinutes == 120)
        #expect(b.additionalEvidence.remMinutes == 40)
        #expect(a.additionalEvidence != b.additionalEvidence)
    }

    @Test func stageCompositionShiftAtConstantAsleepHoursDoesNotChangeScore() {
        // Same scored facts (asleepHours / WASO / awakenings / bedtime), but the stage intervals
        // shift minutes between asleep (core) and awake - the full stage set, not just deep/REM.
        // If any scored component secretly read a stage proportion, the scores would diverge.
        let history = priors(Array(1...6))
        let low = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 7.5,
                          waso: 15, awakenings: 2, coreMin: 300, awakeMin: 20)
        let high = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 7.5,
                           waso: 15, awakenings: 2, coreMin: 240, awakeMin: 80)
        let a = SleepEngine.analyze(night: low, history: history, need: need)
        let b = SleepEngine.analyze(night: high, history: history, need: need)

        #expect(a.score == b.score)
        #expect(a.components == b.components)
        #expect(a.additionalEvidence.coreMinutes == 300)   // evidence differs…
        #expect(b.additionalEvidence.coreMinutes == 240)   // …score does not
    }

    // MARK: - AC-4: quality separation

    @Test func completeManualEntryIsHighCoverageLowReliability() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay),
                            asleepHours: 7.5, waso: nil, awakenings: nil,
                            staged: false, source: .manual)
        let q = SleepEngine.analyze(night: night, history: [], need: need).quality
        #expect(abs(q.coverage - 1.0) < 1e-9)     // one block, no gaps → fully covered
        #expect(abs(q.reliability - 0.3) < 1e-9)  // self-report
        #expect(q.status == .complete)
        #expect(q.reasons.contains(.manualEntry))
    }

    @Test func reliabilitySeparatesSourceClasses() {
        let staged = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 7.5)
        let generic = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 7.5,
                              waso: nil, awakenings: nil, staged: false,
                              source: .healthKit(bundleID: Fix.phoneBundle))
        #expect(abs(SleepEngine.analyze(night: staged, history: [], need: need).quality.reliability - 1.0) < 1e-9)
        let genericQ = SleepEngine.analyze(night: generic, history: [], need: need).quality
        #expect(abs(genericQ.reliability - 0.6) < 1e-9)
        #expect(genericQ.reasons.contains(.genericSource))
    }

    @Test func trackingGapReducesCoverage() {
        // A 60-minute gap inside an 8-hour window → coverage 1 − 60/480 = 0.875.
        let bedtime = bedtimeBefore(wakeDay)
        let wake = bedtime.addingTimeInterval(8 * 3600)
        let gap = DateInterval(start: bedtime.addingTimeInterval(2 * 3600),
                               end: bedtime.addingTimeInterval(3 * 3600))
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtime, wake: wake,
                            asleepHours: 7.0, gaps: [gap])
        let q = SleepEngine.analyze(night: night, history: [], need: need).quality
        #expect(abs(q.coverage - 0.875) < 1e-9)
        #expect(q.reasons.contains(.trackingGap))
    }

    @Test func provisionalStatusIsSurfacedIndependently() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay),
                            asleepHours: 7.5, status: .provisional)
        let q = SleepEngine.analyze(night: night, history: [], need: need).quality
        #expect(q.status == .provisional)
        #expect(q.reasons.contains(.provisionalNight))
    }

    // MARK: - AC-5: comparison windows, DST, gaps, no imputation

    @Test func acuteChronicMeansAndDebtOverAvailableHistory() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 6.0)
        let history = priors(Array(1...8), asleepHours: 7.0)
        let c = SleepEngine.analyze(night: night, history: history, need: need).vsBaseline

        #expect(abs((c.acute7Mean ?? -1) - 7.0) < 1e-9)     // offsets 1…7
        #expect(abs((c.chronic30Mean ?? -1) - 7.0) < 1e-9)  // all 8 available
        // Debt over dayGap 0…13: tonight (8−6=2) + 8 priors (8−7=1 each) = 10.
        #expect(abs(c.debt14Hours - 10.0) < 1e-9)
    }

    @Test func gapNightsAreExcludedFromMeansAndNeverImputedIntoDebt() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 6.0)
        // Offset 3 is missing entirely (a gap night - no record).
        let history = priors([1, 2, 4, 5, 6, 7, 8], asleepHours: 7.0)
        let c = SleepEngine.analyze(night: night, history: history, need: need).vsBaseline

        // Mean over the 6 available nights in the 7-day window (offset 3 absent, not imputed).
        #expect(abs((c.acute7Mean ?? -1) - 7.0) < 1e-9)
        // Debt: tonight 2 + seven recorded priors ×1 = 9 (the missing night adds no deficit).
        #expect(abs(c.debt14Hours - 9.0) < 1e-9)
    }

    @Test func dayGapIsDSTRobustAcrossSpringForward() {
        // Wake day just after the 2026-03-08 spring-forward; offset 7 lands ON the 23-hour day.
        let dstWake = Fix.calendar.startOfDay(for: Fix.date(2026, 3, 15))
        func dstPrior(_ offset: Int, asleep: Double) -> SleepNight {
            let day = Fix.calendar.date(byAdding: .day, value: -offset, to: dstWake)!
            return mkNight(wakeDay: day, bedtime: bedtimeBefore(day), asleepHours: asleep)
        }
        let night = mkNight(wakeDay: dstWake, bedtime: bedtimeBefore(dstWake), asleepHours: 6.0)
        // Six 7.0-hour priors + one 5.0-hour prior at offset 7 (the DST-boundary night).
        var history = (1...6).map { dstPrior($0, asleep: 7.0) }
        history.append(dstPrior(7, asleep: 5.0))
        let c = SleepEngine.analyze(night: night, history: history, need: need).vsBaseline

        // If the DST hour corrupted the day gap, offset 7 would drop out and the mean would be 7.0.
        // Correct day counting includes it: (6·7 + 5)/7 = 47/7.
        let expectedMean = 47.0 / 7
        let acute7 = c.acute7Mean ?? -1
        #expect(abs(acute7 - expectedMean) < 1e-9)
    }

    @Test func dayGapIsDSTRobustAcrossFallBack() {
        // America/New_York falls back 2026-11-01 (a 25-hour day). Offset 7 lands on it; correct day
        // counting must still include the boundary night (the /86400 rounding handles the extra hour).
        let dstWake = Fix.calendar.startOfDay(for: Fix.date(2026, 11, 8))
        func dstPrior(_ offset: Int, asleep: Double) -> SleepNight {
            let day = Fix.calendar.date(byAdding: .day, value: -offset, to: dstWake)!
            return mkNight(wakeDay: day, bedtime: bedtimeBefore(day), asleepHours: asleep)
        }
        let night = mkNight(wakeDay: dstWake, bedtime: bedtimeBefore(dstWake), asleepHours: 6.0)
        var history = (1...6).map { dstPrior($0, asleep: 7.0) }
        history.append(dstPrior(7, asleep: 5.0))   // the 25-hour-day night
        let c = SleepEngine.analyze(night: night, history: history, need: need).vsBaseline

        let expectedMean = 47.0 / 7   // offset 7 included → (6·7 + 5)/7
        let acute7 = c.acute7Mean ?? -1
        #expect(abs(acute7 - expectedMean) < 1e-9)
    }

    // MARK: - AC-6: flags

    @Test func comparativeFlagsSuppressedBelow14RecordedNights() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 5.0)

        let thirteen = SleepEngine.analyze(night: night, history: priors(Array(1...13)), need: need).flags
        #expect(!thirteen.contains { if case .worstIn = $0 { return true }; return false })
        #expect(!thirteen.contains { if case .bestIn = $0 { return true }; return false })
        // shortNight still fires (source-independent) - proves suppression is scoped to comparatives.
        #expect(thirteen.contains { if case .shortNight = $0 { return true }; return false })

        let fourteen = SleepEngine.analyze(night: night, history: priors(Array(1...14)), need: need).flags
        #expect(fourteen.contains(.worstIn(days: 14)))
    }

    @Test func bestInSuppressedBelow14RecordedNights() {
        // Tonight is the LONGEST night - bestIn shares the comparative-flag gate, so it must be
        // suppressed at 13 recorded nights and appear at 14.
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 9.0)

        let thirteen = SleepEngine.analyze(night: night, history: priors(Array(1...13)), need: need).flags
        #expect(!thirteen.contains { if case .bestIn = $0 { return true }; return false })

        let fourteen = SleepEngine.analyze(night: night, history: priors(Array(1...14)), need: need).flags
        #expect(fourteen.contains(.bestIn(days: 14)))
    }

    @Test func scheduleShiftFiresBeyondThreshold() {
        // Tonight's bedtime is 01:00 (on the wake day) vs a 23:00 rolling mean → 120 min shift.
        let lateBedtime = Fix.calendar.date(bySettingHour: 1, minute: 0, second: 0, of: wakeDay)!
        let night = mkNight(wakeDay: wakeDay, bedtime: lateBedtime, asleepHours: 7.5)
        let flags = SleepEngine.analyze(night: night, history: priors(Array(1...6)), need: need).flags

        let shift = flags.compactMap { flag -> Double? in
            if case .scheduleShift(let m) = flag { return m }; return nil
        }.first
        #expect(shift != nil)
        #expect(abs((shift ?? 0) - 120) < 1e-6)
    }

    @Test func shortNightFiresBelowFloor() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 5.5)
        let flags = SleepEngine.analyze(night: night, history: [], need: need).flags
        #expect(flags.contains(.shortNight(hours: 5.5)))
    }

    // MARK: - Circular mean correctness

    @Test func bedtimeMeanUsesCircularArithmeticAcrossMidnight() {
        // Five priors straddling midnight: 23:00, 23:30, 00:00, 00:30, 01:00.
        func straddlePrior(_ offset: Int, hour: Int, minute: Int, onWakeDay: Bool) -> SleepNight {
            let day = Fix.calendar.date(byAdding: .day, value: -offset, to: wakeDay)!
            let anchor = onWakeDay ? day : Fix.calendar.date(byAdding: .day, value: -1, to: day)!
            let bedtime = Fix.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: anchor)!
            return mkNight(wakeDay: day, bedtime: bedtime, asleepHours: 7.5)
        }
        let history = [
            straddlePrior(1, hour: 23, minute: 0, onWakeDay: false),
            straddlePrior(2, hour: 23, minute: 30, onWakeDay: false),
            straddlePrior(3, hour: 0, minute: 0, onWakeDay: true),
            straddlePrior(4, hour: 0, minute: 30, onWakeDay: true),
            straddlePrior(5, hour: 1, minute: 0, onWakeDay: true),
        ]
        // Tonight goes to bed at exactly midnight.
        let night = mkNight(wakeDay: wakeDay,
                            bedtime: Fix.calendar.startOfDay(for: wakeDay), asleepHours: 7.5)
        let analysis = SleepEngine.analyze(night: night, history: history, need: need)

        // Circular mean of the straddling set is midnight (≈0 s), NOT noon (43200 s).
        let mean = analysis.consistency.bedtimeMeanSecondsOfDay ?? -1
        let distanceToMidnight = min(mean, 86_400 - mean)
        #expect(distanceToMidnight < 60)                     // within a minute of midnight
        // And tonight at midnight is essentially on the mean → near-full consistency.
        #expect(analysis.component(.bedtimeConsistency)!.value > 29.5)
    }

    // MARK: - AC-9: decision evidence

    @Test func manualNightWithInjectedWASOStillFeedsNoInterruptionBurden() {
        // Tripwire: hand-build a manual night that (against Slice 1's ingestion invariant) carries
        // WASO + awakenings. interruptionBurden must be nil because the SOURCE is manual, not merely
        // because WASO is absent. Fails if the isDeviceSourced gate on burden is removed - pinning
        // AC-2b locally against a future ingestion change that attaches WASO to a non-staged source.
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay),
                            asleepHours: 6.5, waso: 30, awakenings: 3,
                            staged: false, source: .manual)
        #expect(night.wasoMinutes == 30)   // the fixture really did inject WASO onto a manual night
        let e = SleepEngine.analyze(night: night, history: priors(Array(1...10)), need: need).decisionEvidence
        #expect(e.interruptionBurden == nil)   // gated by source, not by WASO presence
        #expect(e.durationDeficitHours == nil)
        #expect(e.scheduleShiftMinutes == nil)
    }

    @Test func decisionEvidencePopulatedForObservedNight() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay),
                            asleepHours: 7.0 + 25.0 / 60, waso: 15, awakenings: 2)
        let e = SleepEngine.analyze(night: night, history: priors(Array(1...6)), need: need).decisionEvidence
        let expectedDeficit = 8.0 - (7.0 + 25.0 / 60)   // 0.58333
        let deficit = e.durationDeficitHours ?? -1
        let burden = e.interruptionBurden ?? -1
        let shift = e.scheduleShiftMinutes ?? -1
        #expect(abs(deficit - expectedDeficit) < 1e-9)
        #expect(abs(burden - 0.25) < 1e-9)              // 15/60
        #expect(abs(shift - 0) < 1e-6)                  // on the mean
    }

    @Test func decisionEvidenceIsNilSafeForPartialManualNight() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay),
                            asleepHours: 6.5, waso: nil, awakenings: nil,
                            staged: false, source: .manual)
        let e = SleepEngine.analyze(night: night, history: priors(Array(1...10)), need: need).decisionEvidence
        // AC-2b: a manual night feeds NO decision signal - Slice 4 reaches it via the subjective
        // fallback, never a duration deficit (which would be a second manual scoring route).
        #expect(e.durationDeficitHours == nil)
        #expect(e.interruptionBurden == nil)                        // no WASO
        #expect(e.scheduleShiftMinutes == nil)                      // manual bedtime not trusted
    }

    // MARK: - Versioning

    @Test func analysisStampsCurrentEngineVersions() {
        let night = mkNight(wakeDay: wakeDay, bedtime: bedtimeBefore(wakeDay), asleepHours: 7.5)
        let analysis = SleepEngine.analyze(night: night, history: [], need: need)
        #expect(analysis.aggregationVersion == SleepEngine.aggregationVersion)
        #expect(analysis.scoreAlgorithmVersion == SleepEngine.scoreAlgorithmVersion)
    }
}
