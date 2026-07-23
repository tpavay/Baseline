import Foundation
import Testing
@testable import Baseline

/// AC-2/AC-3/AC-4: the analysis→sections mapping. Full scored night (score + band + Apple-style
/// component subtitles), cold-start partial (score nil → observed/possible + coverage, never a
/// fabricated 0–100), manual not-scored, and the influence-vs-cap footer strings computed from the
/// decision result. Pure - no view tree, no `Date()`.
struct SleepDetailPresentationTests {

    // MARK: - Builders

    private func component(_ kind: SleepComponent.Kind, _ value: Double, _ max: Double, _ available: Bool) -> SleepComponent {
        SleepComponent(kind: kind, value: value, max: max, isAvailable: available)
    }

    private func analysis(score: Int? = nil,
                          observed: Int = 0, possible: Int = 0,
                          needHours: Double? = 8,
                          asleepHours: Double? = 7.3,
                          wasoMinutes: Double? = 15,
                          awakenings: Int? = 2,
                          components: [SleepComponent] = [],
                          coverage: Double = 1.0,
                          reliability: Double = 1.0,
                          status: SleepEvidenceQuality.Status = .complete,
                          gapMinutes: Double = 0,
                          acute: Double? = nil,
                          chronic: Double? = nil,
                          debt: Double = 0,
                          flags: [SleepFlag] = [],
                          scheduleShiftMinutes: Double? = nil) -> SleepAnalysis {
        SleepAnalysis(
            observedPoints: observed, possiblePoints: possible, score: score,
            needHours: needHours,
            asleepHours: asleepHours, wasoMinutes: wasoMinutes, awakenings: awakenings,
            components: components,
            additionalEvidence: SleepStageEvidence(remMinutes: 118, deepMinutes: 62, coreMinutes: 258,
                                                   remFraction: 0.27, deepFraction: 0.14, coreFraction: 0.59,
                                                   sleepOnset: nil, finalWake: nil, gapMinutes: gapMinutes),
            quality: SleepEvidenceQuality(coverage: coverage, reliability: reliability, status: status, reasons: []),
            vsBaseline: SleepComparison(acute7Mean: acute, chronic30Mean: chronic, debt14Hours: debt),
            consistency: SleepConsistency(bedtimeMeanSecondsOfDay: nil, bedtimeStdMinutes: nil,
                                          wakeMeanSecondsOfDay: nil, wakeStdMinutes: nil,
                                          recordedNights: 0, isAvailable: false),
            flags: flags,
            decisionEvidence: SleepDecisionEvidence(durationDeficitHours: nil, interruptionBurden: nil,
                                                    scheduleShiftMinutes: scheduleShiftMinutes),
            aggregationVersion: SleepEngine.aggregationVersion,
            scoreAlgorithmVersion: SleepEngine.scoreAlgorithmVersion)
    }

    private func decision(sleepSub: Int? = nil, sleepWeight: Double = 0.15,
                          caps: [DecisionEngine.AppliedCap] = []) -> DecisionEngine.Result {
        var domains: [DecisionEngine.DomainScore] = [.init(domain: .autonomic, subscore: 78, weight: 0.4)]
        if let sleepSub { domains.append(.init(domain: .sleep, subscore: sleepSub, weight: sleepWeight)) }
        return DecisionEngine.Result(score: 70, band: .amber, certainty: .medium, calibrating: false,
                                     domains: domains, primaryLimiter: nil, secondaryLimiter: nil,
                                     appliedCaps: caps, constraints: [])
    }

    private let fullComponents = [
        SleepComponent(kind: .duration, value: 44, max: 50, isAvailable: true),
        SleepComponent(kind: .bedtimeConsistency, value: 26, max: 30, isAvailable: true),
        SleepComponent(kind: .interruptions, value: 14, max: 20, isAvailable: true),
    ]

    // MARK: - Full scored night (AC-2)

    @Test func scoredNightShowsScoreHeadlineBandAndComponents() {
        let p = SleepDetailPresentation(analysis: analysis(score: 84, observed: 84, possible: 100,
                                                           components: fullComponents,
                                                           scheduleShiftMinutes: 20),
                                        resolvedSource: .healthKit(bundleID: "watch"))
        #expect(p.headline == .score(84))
        #expect(p.bandLabel == "High")           // Apple-post-26.2 band, 81–95
        #expect(p.components.count == 3)
        #expect(p.components.map(\.title) == ["Duration", "Bedtime", "Interruptions"])
        #expect(p.components[0].value == "44 / 50")
        let allAvailable = p.components.allSatisfy(\.isAvailable)
        #expect(allAvailable)
    }

    @Test func bandLabelIsNilWithoutAScore() {
        let p = SleepDetailPresentation(analysis: analysis(score: nil, observed: 42, possible: 50))
        #expect(p.bandLabel == nil)
    }

    @Test func seventyEightReadsOKNotHigh() {
        let p = SleepDetailPresentation(analysis: analysis(score: 78, observed: 78, possible: 100,
                                                           components: fullComponents))
        #expect(p.bandLabel == "OK")
    }

    // MARK: - Component subtitles (the Apple-style human readings)

    @Test func durationSubtitleAtGoal() {
        let comps = [component(.duration, 50, 50, true)]
        let p = SleepDetailPresentation(analysis: analysis(needHours: 8, asleepHours: 8.533,
                                                           components: comps))
        #expect(p.components[0].subtitle == "8h 32m - at your sleep goal")
    }

    @Test func durationSubtitleShortOfGoal() {
        let comps = [component(.duration, 40, 50, true)]
        let p = SleepDetailPresentation(analysis: analysis(needHours: 8, asleepHours: 7.2,
                                                           components: comps))
        #expect(p.components[0].subtitle == "7h 12m - 48m short of your sleep goal")
    }

    @Test func bedtimeSubtitleReportsDriftOffTheRollingAverage() {
        let comps = [component(.bedtimeConsistency, 16, 30, true)]
        let p = SleepDetailPresentation(analysis: analysis(components: comps,
                                                           scheduleShiftMinutes: 114))
        #expect(p.components[1].subtitle == "1h 54m off your 14-day average")
    }

    @Test func bedtimeSubtitleWithinTheGraceBand() {
        let comps = [component(.bedtimeConsistency, 30, 30, true)]
        let p = SleepDetailPresentation(analysis: analysis(components: comps,
                                                           scheduleShiftMinutes: 12))
        #expect(p.components[1].subtitle == "Close to your 14-day average")
    }

    @Test func interruptionsSubtitleCountsWakeUpsAndAwakeTime() {
        let comps = [component(.interruptions, 11, 20, true)]
        let many = SleepDetailPresentation(analysis: analysis(wasoMinutes: 24, awakenings: 10,
                                                              components: comps))
        #expect(many.components[2].subtitle == "10 wake-ups · 24m awake")

        let one = SleepDetailPresentation(analysis: analysis(wasoMinutes: 8, awakenings: 1,
                                                             components: comps))
        #expect(one.components[2].subtitle == "1 wake-up · 8m awake")
    }

    @Test func unavailableComponentHasNoSubtitle() {
        let comps = [component(.duration, 42, 50, true),
                     component(.bedtimeConsistency, 0, 30, false),
                     component(.interruptions, 0, 20, false)]
        let p = SleepDetailPresentation(analysis: analysis(score: nil, observed: 42, possible: 50,
                                                           components: comps))
        #expect(p.components[1].subtitle.isEmpty)
        #expect(p.components[1].value == "Not observed")
        #expect(p.components[1].fraction == 0)
    }

    // MARK: - Headline date label

    @Test func dateLabelSaysTodayForTheCurrentDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let night = calendar.date(from: DateComponents(year: 2026, month: 7, day: 23))!
        let p = SleepDetailPresentation(analysis: analysis(score: 78, components: fullComponents),
                                        nightDate: night,
                                        referenceDate: night.addingTimeInterval(9 * 3600),
                                        calendar: calendar)
        #expect(p.dateLabel == "Today, Jul 23")
    }

    @Test func dateLabelUsesWeekdayForPastNights() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let night = calendar.date(from: DateComponents(year: 2026, month: 7, day: 21))!
        let reference = calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 9))!
        let p = SleepDetailPresentation(analysis: analysis(score: 78, components: fullComponents),
                                        nightDate: night, referenceDate: reference, calendar: calendar)
        #expect(p.dateLabel == "Tue, Jul 21")
    }

    // MARK: - Stage caption

    @Test func stageCaptionSaysStagesNeverMoveTheScore() {
        let p = SleepDetailPresentation(analysis: analysis(score: 84))
        #expect(p.stageEvidenceCaption.contains("never move the score"))
    }

    // MARK: - Cold-start partial (AC-3) - no fabricated score

    @Test func partialNightShowsObservedPossibleAndCoverageNotAScore() {
        let comps = [component(.duration, 42, 50, true),
                     component(.bedtimeConsistency, 0, 30, false),
                     component(.interruptions, 0, 20, false)]
        let p = SleepDetailPresentation(analysis: analysis(score: nil, observed: 42, possible: 50,
                                                           components: comps, coverage: 0.86),
                                        resolvedSource: .healthKit(bundleID: "watch"))
        #expect(p.headline == .partial(observed: 42, possible: 50, coveragePercent: 86))
        // Honest availability on the component rows.
        #expect(p.components[0].isAvailable)
        #expect(p.components[1].value == "Not observed")
        #expect(p.components[2].value == "Not observed")
    }

    // MARK: - Manual night (AC-3) - not scored

    @Test func manualNightIsNotScored() {
        let p = SleepDetailPresentation(analysis: analysis(score: nil, observed: 0, possible: 0,
                                                           asleepHours: 7.25),
                                        resolvedSource: .manual)
        // possiblePoints == 0 must NOT read as a "0 of 0 pts" numeral or a score (AC-3): lead with the
        // observed duration and an honest "not scored" caption.
        guard case .notScored(let duration, let caption) = p.headline else {
            Issue.record("manual night must render the not-scored/duration headline, got \(p.headline)")
            return
        }
        #expect(duration != nil)
        #expect(caption == "Manual entry · not scored")
    }

    @Test func zeroPossiblePointsNeverShowsPartialOrScore() {
        // A non-manual source with nothing scorable also collapses to the not-scored headline.
        let p = SleepDetailPresentation(analysis: analysis(score: nil, observed: 0, possible: 0,
                                                           asleepHours: 6.5),
                                        resolvedSource: .healthKit(bundleID: "generic"))
        if case .notScored(_, let caption) = p.headline {
            #expect(caption == "Not scored")
        } else {
            Issue.record("possiblePoints == 0 must be .notScored, got \(p.headline)")
        }
    }

    // MARK: - Influence vs cap footer (AC-4)

    @Test func footerWeightedInfluenceIsDescriptiveNotCausal() {
        // subscore 80, weight 0.15 → 12 of 15 possible points.
        let p = SleepDetailPresentation(analysis: analysis(score: 80),
                                        decision: decision(sleepSub: 80, sleepWeight: 0.15))
        #expect(p.footer.influence == "Sleep domain: 80 - weighted influence 12 of 15 possible points")
        #expect(p.footer.cap == nil)
        // Never claims a causal contribution.
        #expect(p.footer.influence?.contains("caused") == false)
        #expect(p.footer.influence?.contains("contributed") == false)
    }

    @Test func footerReportsSleepCapWhenItBindsTheResult() {
        let caps: [DecisionEngine.AppliedCap] = [.init(domain: .sleep, cap: 55, reason: "poorSleep")]
        let p = SleepDetailPresentation(analysis: analysis(score: 60),
                                        decision: decision(sleepSub: 60, caps: caps))
        #expect(p.footer.cap == "Today's readiness was capped by short sleep.")
    }

    @Test func footerDistinguishesNonBindingSleepCap() {
        // A sleep cap fired at 55 but another domain capped lower at 40 → sleep is not the binder.
        let caps: [DecisionEngine.AppliedCap] = [
            .init(domain: .sleep, cap: 55, reason: "poorSleep"),
            .init(domain: .autonomic, cap: 40, reason: "illness"),
        ]
        let p = SleepDetailPresentation(analysis: analysis(score: 60),
                                        decision: decision(sleepSub: 60, caps: caps))
        #expect(p.footer.cap == "Short sleep would cap readiness, but another factor bound today lower.")
    }

    @Test func footerNoteWhenNoDecisionAvailable() {
        let p = SleepDetailPresentation(analysis: analysis(score: 80), decision: nil)
        #expect(p.footer.influence == nil)
        #expect(p.footer.cap == nil)
        #expect(p.footer.note == "This night isn't part of today's readiness decision.")
    }

    // MARK: - Comparisons + flags

    @Test func comparisonsAndFlagsMap() {
        let p = SleepDetailPresentation(analysis: analysis(score: 70, acute: 7.2, chronic: 7.6, debt: 3.5,
                                                           flags: [.worstIn(days: 21), .shortNight(hours: 5.5)]))
        #expect(p.comparisons.contains { $0.label == "7-day average" && $0.value == "7h 12m" })
        #expect(p.comparisons.contains { $0.label == "14-day sleep debt" })
        #expect(p.flags.contains("Shortest night in 21 days"))
    }
}
