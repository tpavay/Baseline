import Foundation
import Testing
@testable import Baseline

/// AC-6/AC-7: the Today sleep row is gated purely on analysis presence. `TodaySleepRowModel.make`
/// returns a row **iff** a context exists, so the "tappable iff analysis present / byte-identical when
/// dormant" behavior is provable without a view tree.
struct TodaySleepRowTests {

    private func night(source: SleepSource = .healthKit(bundleID: "watch"),
                       asleepHours: Double? = 7.3) -> SleepNight {
        SleepNight(id: UUID(), date: Date(timeIntervalSince1970: 1_000_000), episodes: [],
                   bedtime: nil, wakeTime: nil, asleepHours: asleepHours, inBedHours: nil,
                   awakenings: nil, wasoMinutes: nil, resolvedSource: source,
                   analysisStatus: .complete, sourceFingerprint: "t", composingSampleUUIDs: [],
                   lastHealthKitSyncAt: nil, lastSampleEndDate: nil, revision: 0, factsSchemaVersion: 1)
    }

    private func analysis(score: Int?, observed: Int = 0, possible: Int = 0,
                          reliability: Double = 1.0) -> SleepAnalysis {
        SleepAnalysis(
            observedPoints: observed, possiblePoints: possible, score: score,
            asleepHours: 7.3, wasoMinutes: 15, awakenings: 2, components: [],
            additionalEvidence: SleepStageEvidence(remMinutes: 0, deepMinutes: 0, coreMinutes: 0,
                                                   remFraction: 0, deepFraction: 0, coreFraction: 0,
                                                   sleepOnset: nil, finalWake: nil, gapMinutes: 0),
            quality: SleepEvidenceQuality(coverage: 1, reliability: reliability, status: .complete, reasons: []),
            vsBaseline: SleepComparison(acute7Mean: nil, chronic30Mean: nil, debt14Hours: 0),
            consistency: SleepConsistency(bedtimeMeanSecondsOfDay: nil, bedtimeStdMinutes: nil,
                                          wakeMeanSecondsOfDay: nil, wakeStdMinutes: nil,
                                          recordedNights: 0, isAvailable: false),
            flags: [], decisionEvidence: SleepDecisionEvidence(durationDeficitHours: nil,
                                                               interruptionBurden: nil, scheduleShiftMinutes: nil),
            aggregationVersion: SleepEngine.aggregationVersion,
            scoreAlgorithmVersion: SleepEngine.scoreAlgorithmVersion)
    }

    // MARK: - Dormancy gate

    @Test func dormantContextProducesNoRow() {
        #expect(TodaySleepRowModel.make(nil) == nil)
    }

    @Test func analysisPresentProducesRow() {
        let ctx = SleepDetailContext(night: night(), analysis: analysis(score: 84), decision: nil)
        let model = TodaySleepRowModel.make(ctx)
        #expect(model != nil)
        #expect(model?.headline == "84")
        #expect(model?.isScore == true)
        #expect(model?.caption.contains("High reliability") == true)
    }

    @Test func partialNightShowsObservedPossibleNotAScore() {
        let ctx = SleepDetailContext(night: night(), analysis: analysis(score: nil, observed: 42, possible: 50),
                                     decision: nil)
        let model = TodaySleepRowModel.make(ctx)
        #expect(model?.headline == "42/50")
        #expect(model?.isScore == false)
    }

    @Test func manualNightLabelsManualEntry() {
        let ctx = SleepDetailContext(night: night(source: .manual), analysis: analysis(score: nil, reliability: 0.3),
                                     decision: nil)
        #expect(TodaySleepRowModel.make(ctx)?.caption.contains("Manual entry") == true)
    }

    @Test func accessibilityLabelSpeaksTheScore() {
        let ctx = SleepDetailContext(night: night(), analysis: analysis(score: 84), decision: nil)
        #expect(TodaySleepRowModel.make(ctx)?.accessibilityLabel.contains("Sleep score 84") == true)
    }
}
