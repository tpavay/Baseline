import Foundation
import Testing
@testable import Baseline

/// Slice 3 contract coverage for descriptive insights (AC-7): each rule's quantity is recomputed
/// from analysis fields, and a negative scan proves no stage→effect claims leak into the copy.
struct SleepInsightsTests {

    /// A neutral analysis; each test overrides only the fields its rule reads.
    private func analysis(asleepHours: Double? = 7.5,
                          wasoMinutes: Double? = 5,
                          chronic30Mean: Double? = 7.5,
                          gapMinutes: Double = 0,
                          scheduleShiftMinutes: Double? = nil,
                          flags: [SleepFlag] = []) -> SleepAnalysis {
        SleepAnalysis(
            observedPoints: 0, possiblePoints: 0, score: nil,
            asleepHours: asleepHours, wasoMinutes: wasoMinutes, awakenings: 1,
            components: [],
            additionalEvidence: SleepStageEvidence(
                remMinutes: 120, deepMinutes: 60, coreMinutes: 300,
                remFraction: 0.27, deepFraction: 0.13, coreFraction: 0.6,
                sleepOnset: nil, finalWake: nil, gapMinutes: gapMinutes),
            quality: SleepEvidenceQuality(coverage: 1, reliability: 1, status: .complete, reasons: []),
            vsBaseline: SleepComparison(acute7Mean: nil, chronic30Mean: chronic30Mean, debt14Hours: 0),
            consistency: SleepConsistency(bedtimeMeanSecondsOfDay: nil, bedtimeStdMinutes: nil,
                                          wakeMeanSecondsOfDay: nil, wakeStdMinutes: nil,
                                          recordedNights: 0, isAvailable: false),
            flags: flags,
            decisionEvidence: SleepDecisionEvidence(durationDeficitHours: nil, interruptionBurden: nil,
                                                    scheduleShiftMinutes: scheduleShiftMinutes),
            aggregationVersion: SleepEngine.aggregationVersion,
            scoreAlgorithmVersion: SleepEngine.scoreAlgorithmVersion)
    }

    // MARK: - Rule-by-rule quantity match

    @Test func durationVsAverageQuantityMatches() {
        // 6.5 h vs 7.4 h average → 54 minutes less.
        let lines = SleepInsights.rules(for: analysis(asleepHours: 6.5, chronic30Mean: 7.4))
        let line = lines.first { $0.contains("average") }
        #expect(line == "You slept 54 minutes less than your 30-day average.")
    }

    @Test func durationVsAverageReportsSurplusDirection() {
        let lines = SleepInsights.rules(for: analysis(asleepHours: 8.0, chronic30Mean: 7.4))
        #expect(lines.contains("You slept 36 minutes more than your 30-day average."))
    }

    @Test func bedtimeShiftQuantityMatches() {
        let lines = SleepInsights.rules(for: analysis(scheduleShiftMinutes: 72))
        #expect(lines.contains("Your bedtime was 1 h 12 m off your usual time."))
    }

    @Test func awakeTimeQuantityMatches() {
        let lines = SleepInsights.rules(for: analysis(wasoMinutes: 38))
        #expect(lines.contains("You were awake 38 minutes during the night."))
    }

    @Test func trackingGapQuantityMatches() {
        let lines = SleepInsights.rules(for: analysis(gapMinutes: 46))
        #expect(lines.contains("Your sleep data contains a tracking gap of 46 minutes."))
    }

    @Test func shortestInNQuantityMatches() {
        let lines = SleepInsights.rules(for: analysis(flags: [.worstIn(days: 21)]))
        #expect(lines.contains("This was your shortest night in 21 days."))
    }

    @Test func longestNightUsesBestInFlag() {
        let lines = SleepInsights.rules(for: analysis(flags: [.bestIn(days: 30)]))
        #expect(lines.contains("This was your longest night in 30 days."))
    }

    // MARK: - Suppression of trivial deltas

    @Test func trivialDeltasEmitNothing() {
        // 8-minute duration delta, 10-minute bedtime shift, 3-minute WASO, 2-minute gap — all below
        // their notability thresholds.
        let lines = SleepInsights.rules(for: analysis(
            asleepHours: 7.5 + 8.0 / 60, wasoMinutes: 3, chronic30Mean: 7.5,
            gapMinutes: 2, scheduleShiftMinutes: 10))
        #expect(lines.isEmpty)
    }

    // MARK: - All five shapes together

    @Test func allFiveShapesEmitTogether() {
        let lines = SleepInsights.rules(for: analysis(
            asleepHours: 6.5, wasoMinutes: 38, chronic30Mean: 7.4,
            gapMinutes: 46, scheduleShiftMinutes: 72, flags: [.worstIn(days: 21)]))
        #expect(lines.count == 5)
    }

    // MARK: - Negative scan: no stage→effect claims

    @Test func rulesNeverMentionStagesOrEffects() {
        // A staged night with every rule firing — the copy must still name no stage or effect.
        let lines = SleepInsights.rules(for: analysis(
            asleepHours: 6.5, wasoMinutes: 38, chronic30Mean: 7.4,
            gapMinutes: 46, scheduleShiftMinutes: 72, flags: [.worstIn(days: 21)]))
        #expect(!lines.isEmpty)

        let forbidden = ["rem", "deep", "core", "stage", "effort", "perform", "recovery", "energy"]
        for line in lines {
            let lower = line.lowercased()
            for token in forbidden {
                #expect(!lower.contains(token), "Insight leaked a stage/effect token '\(token)': \(line)")
            }
        }
    }
}
