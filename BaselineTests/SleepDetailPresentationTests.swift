import Foundation
import Testing
@testable import Baseline

/// AC-2/AC-3/AC-4: the analysis→sections mapping. Full scored night, cold-start partial (score nil →
/// observed/possible + coverage, never a fabricated 0–100), manual low-reliability, and the
/// influence-vs-cap footer strings computed from the decision result. Pure — no view tree, no `Date()`.
struct SleepDetailPresentationTests {

    // MARK: - Builders

    private func component(_ kind: SleepComponent.Kind, _ value: Double, _ max: Double, _ available: Bool) -> SleepComponent {
        SleepComponent(kind: kind, value: value, max: max, isAvailable: available)
    }

    private func analysis(score: Int? = nil,
                          observed: Int = 0, possible: Int = 0,
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
                          flags: [SleepFlag] = []) -> SleepAnalysis {
        SleepAnalysis(
            observedPoints: observed, possiblePoints: possible, score: score,
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
                                                    scheduleShiftMinutes: nil),
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

    // MARK: - Full scored night (AC-2)

    @Test func scoredNightShowsScoreHeadlineAndComponents() {
        let comps = [component(.duration, 44, 50, true),
                     component(.bedtimeConsistency, 26, 30, true),
                     component(.interruptions, 14, 20, true)]
        let p = SleepDetailPresentation(analysis: analysis(score: 84, observed: 84, possible: 100,
                                                           components: comps),
                                        resolvedSource: .healthKit(bundleID: "watch"))
        #expect(p.headline == .score(84))
        #expect(p.components.count == 3)
        #expect(p.components[0].value == "44 / 50")
        let allAvailable = p.components.allSatisfy(\.isAvailable)
        #expect(allAvailable)
        #expect(p.badge.status == "Complete")
        #expect(p.badge.reliability == "High reliability (staged wearable)")
        #expect(p.badge.isProvisional == false)
    }

    @Test func statsIncludeAsleepAwakeAndGap() {
        let p = SleepDetailPresentation(analysis: analysis(score: 84, wasoMinutes: 15, awakenings: 2, gapMinutes: 20))
        #expect(p.stats.contains { $0.label == "Time asleep" })
        #expect(p.stats.contains { $0.label == "Awake in bed" && $0.value.contains("2×") })
        #expect(p.stats.contains { $0.label == "Tracking gap" && $0.value == "20 min" })
    }

    @Test func stageEvidenceIsPresentAndNeverScored() {
        let p = SleepDetailPresentation(analysis: analysis(score: 84))
        #expect(p.stageEvidence.map(\.label) == ["REM", "Deep", "Core"])
        #expect(p.stageEvidence[0].share == "27% of sleep")
        #expect(p.stageEvidenceCaption.contains("never move the score"))
    }

    // MARK: - Cold-start partial (AC-3) — no fabricated score

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
        #expect(p.components[1].fraction == 0)
    }

    // MARK: - Manual night (AC-3) — low reliability

    @Test func manualNightIsLowReliabilityAndNotScored() {
        let p = SleepDetailPresentation(analysis: analysis(score: nil, observed: 0, possible: 0,
                                                           asleepHours: 7.25, reliability: 0.3),
                                        resolvedSource: .manual)
        #expect(p.badge.reliability == "Low reliability (manual entry)")
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
        #expect(p.footer.influence == "Sleep domain: 80 — weighted influence 12 of 15 possible points")
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
        #expect(p.comparisons.contains { $0.label == "7-day average" })
        #expect(p.comparisons.contains { $0.label == "14-day sleep debt" })
        #expect(p.flags.contains("Shortest night in 21 days"))
    }
}
