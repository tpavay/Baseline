import Foundation
import Testing
@testable import Baseline

/// AC-5: the upgraded check-in readout shows score + duration + a quality hint (and a provisional
/// marker when syncing) when Health sleep + an analysis are present. Asserted via the pure
/// `SleepCheckInReadout`; the manual/legacy path is guarded by the card's own nil-analysis branch
/// (covered structurally — `SleepCheckInReadout` is only built when an analysis exists).
struct SleepCheckInCardTests {

    private func analysis(score: Int?, observed: Int = 0, possible: Int = 0,
                          wasoMinutes: Double? = 12, gapMinutes: Double = 0,
                          status: SleepEvidenceQuality.Status = .complete) -> SleepAnalysis {
        SleepAnalysis(
            observedPoints: observed, possiblePoints: possible, score: score,
            asleepHours: 7.3, wasoMinutes: wasoMinutes, awakenings: 2, components: [],
            additionalEvidence: SleepStageEvidence(remMinutes: 0, deepMinutes: 0, coreMinutes: 0,
                                                   remFraction: 0, deepFraction: 0, coreFraction: 0,
                                                   sleepOnset: nil, finalWake: nil, gapMinutes: gapMinutes),
            quality: SleepEvidenceQuality(coverage: 1, reliability: 1, status: status, reasons: []),
            vsBaseline: SleepComparison(acute7Mean: nil, chronic30Mean: nil, debt14Hours: 0),
            consistency: SleepConsistency(bedtimeMeanSecondsOfDay: nil, bedtimeStdMinutes: nil,
                                          wakeMeanSecondsOfDay: nil, wakeStdMinutes: nil,
                                          recordedNights: 0, isAvailable: false),
            flags: [], decisionEvidence: SleepDecisionEvidence(durationDeficitHours: nil,
                                                               interruptionBurden: nil, scheduleShiftMinutes: nil),
            aggregationVersion: SleepEngine.aggregationVersion,
            scoreAlgorithmVersion: SleepEngine.scoreAlgorithmVersion)
    }

    @Test func healthPresentShowsScoreAndQuality() {
        let r = SleepCheckInReadout(asleepHours: 7.5, analysis: analysis(score: 84))
        #expect(r.headline == "84")
        #expect(r.isScore)
        #expect(r.qualityHint == "Synced from Apple Health")
        #expect(r.showsProvisional == false)
        #expect(r.accessibilityLabel.contains("Sleep score 84"))
        #expect(r.accessibilityLabel.contains("7h 30m"))
    }

    @Test func partialNightShowsObservedPoints() {
        let r = SleepCheckInReadout(asleepHours: 6.75, analysis: analysis(score: nil, observed: 42, possible: 50))
        #expect(r.headline == "42/50")
        #expect(r.isScore == false)
    }

    @Test func provisionalNightShowsSyncingHintAndMarker() {
        let r = SleepCheckInReadout(asleepHours: 7.0, analysis: analysis(score: nil, status: .provisional))
        #expect(r.showsProvisional)
        #expect(r.qualityHint == "Still syncing from Apple Health")
    }

    @Test func interruptedNightShowsInterruptionHint() {
        let r = SleepCheckInReadout(asleepHours: 7.0, analysis: analysis(score: 70, wasoMinutes: 35))
        #expect(r.qualityHint == "Some interruptions overnight")
    }

    @Test func trackingGapHintWhenGapLarge() {
        let r = SleepCheckInReadout(asleepHours: 7.0, analysis: analysis(score: 70, wasoMinutes: 5, gapMinutes: 40))
        #expect(r.qualityHint == "Contains a tracking gap")
    }
}
