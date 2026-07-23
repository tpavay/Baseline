import Testing
@testable import Baseline

/// The Apple-post-26.2 sleep score band mapping (Very Low 0–40 · Low 41–60 · OK 61–80 ·
/// High 81–95 · Very High 96–100), pinned at every cutoff so the card, detail, and About surfaces
/// can never drift from the published ranges.
struct SleepScoreBandTests {

    @Test func bandCutoffsMatchApplePost262Ranges() {
        #expect(SleepScoreBand(score: 0) == .veryLow)
        #expect(SleepScoreBand(score: 40) == .veryLow)
        #expect(SleepScoreBand(score: 41) == .low)
        #expect(SleepScoreBand(score: 60) == .low)
        #expect(SleepScoreBand(score: 61) == .ok)
        #expect(SleepScoreBand(score: 80) == .ok)
        #expect(SleepScoreBand(score: 81) == .high)
        #expect(SleepScoreBand(score: 95) == .high)
        #expect(SleepScoreBand(score: 96) == .veryHigh)
        #expect(SleepScoreBand(score: 100) == .veryHigh)
    }

    @Test func aSeventyEightIsOKNotHigh() {
        // The re-banding that motivated the redesign: 78 read as "High" under the original Apple
        // bands and under the old card rating; post-26.2 it is an "OK" night.
        #expect(SleepScoreBand(score: 78) == .ok)
        #expect(SleepScoreBand(score: 78).label == "OK")
    }

    @Test func labels() {
        #expect(SleepScoreBand.veryLow.label == "Very Low")
        #expect(SleepScoreBand.low.label == "Low")
        #expect(SleepScoreBand.ok.label == "OK")
        #expect(SleepScoreBand.high.label == "High")
        #expect(SleepScoreBand.veryHigh.label == "Very High")
    }

    @Test func rangeLabelsCoverTheWholeScale() {
        #expect(SleepScoreBand.allCases.map(\.rangeLabel) ==
                ["0–40", "41–60", "61–80", "81–95", "96+"])
    }
}
