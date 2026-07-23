import Foundation
import Testing
@testable import Baseline

/// The Today sleep card's pure analysis → card mapping: gated on a published score (never a
/// fabricated 0–100), the Apple-post-26.2 band word, the "8h 32m asleep" readout, and the ring
/// segments weighted by the 50/30/20 component ceilings with radial-fill progress.
struct TodaySleepCardModelTests {

    private func analysis(score: Int?,
                          asleepHours: Double? = 8.533,
                          components: [SleepComponent] = [
                            SleepComponent(kind: .duration, value: 50, max: 50, isAvailable: true),
                            SleepComponent(kind: .bedtimeConsistency, value: 16, max: 30, isAvailable: true),
                            SleepComponent(kind: .interruptions, value: 11, max: 20, isAvailable: true),
                          ]) -> SleepAnalysis {
        SleepAnalysis(
            observedPoints: score ?? 0, possiblePoints: score == nil ? 0 : 100, score: score,
            needHours: 8, asleepHours: asleepHours, wasoMinutes: 24, awakenings: 10,
            components: components,
            additionalEvidence: SleepStageEvidence(remMinutes: 0, deepMinutes: 0, coreMinutes: 0,
                                                   remFraction: 0, deepFraction: 0, coreFraction: 0,
                                                   sleepOnset: nil, finalWake: nil, gapMinutes: 0),
            quality: SleepEvidenceQuality(coverage: 1, reliability: 1, status: .complete, reasons: []),
            vsBaseline: SleepComparison(acute7Mean: nil, chronic30Mean: nil, debt14Hours: 0),
            consistency: SleepConsistency(bedtimeMeanSecondsOfDay: nil, bedtimeStdMinutes: nil,
                                          wakeMeanSecondsOfDay: nil, wakeStdMinutes: nil,
                                          recordedNights: 0, isAvailable: false),
            flags: [],
            decisionEvidence: SleepDecisionEvidence(durationDeficitHours: nil, interruptionBurden: nil,
                                                    scheduleShiftMinutes: nil),
            aggregationVersion: SleepEngine.aggregationVersion,
            scoreAlgorithmVersion: SleepEngine.scoreAlgorithmVersion)
    }

    @Test func noScoreProducesNoCard() {
        #expect(TodaySleepCardModel.make(analysis(score: nil)) == nil)
    }

    @Test func scoredNightBuildsBandDurationAndSegments() throws {
        let model = try #require(TodaySleepCardModel.make(analysis(score: 78)))
        #expect(model.score == 78)
        #expect(model.band == "OK")                       // post-26.2 band, not the old "High"
        #expect(model.durationText == "8h 32m asleep")    // asleep, not "in bed"; no wake-ups line
        // Ring: three arcs weighted by the component ceilings, filled by points earned.
        #expect(model.segments.map(\.kind) == [.duration, .bedtimeConsistency, .interruptions])
        #expect(model.segments.map(\.weight) == [50, 30, 20])
        #expect(model.segments[0].progress == 1.0)
        #expect(abs(model.segments[1].progress - 16.0 / 30) < 1e-9)
        #expect(abs(model.segments[2].progress - 11.0 / 20) < 1e-9)
    }

    @Test func bandWordTracksTheScore() throws {
        #expect(try #require(TodaySleepCardModel.make(analysis(score: 30))).band == "Very Low")
        #expect(try #require(TodaySleepCardModel.make(analysis(score: 55))).band == "Low")
        #expect(try #require(TodaySleepCardModel.make(analysis(score: 82))).band == "High")
        #expect(try #require(TodaySleepCardModel.make(analysis(score: 97))).band == "Very High")
    }
}
