import Foundation
import Testing
@testable import Baseline

/// The pure session-aggregate accumulator: average, max, and elapsed over recorded `(bpm, at)`
/// samples, deterministic and independent of any live clock.
struct SessionHeartRateStatsTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func emptyStatsAreNil() {
        let stats = SessionHeartRateStats()
        #expect(stats.averageBPM == nil)
        #expect(stats.maxBPM == nil)
        #expect(stats.elapsed == 0)
    }

    @Test func averageIsRoundedMeanAndMaxIsPeak() {
        var stats = SessionHeartRateStats()
        stats.record(bpm: 130, at: t0)
        stats.record(bpm: 150, at: t0 + 3)
        stats.record(bpm: 190, at: t0 + 5)
        #expect(stats.averageBPM == 157)     // 156.67 → 157
        #expect(stats.maxBPM == 190)
        #expect(stats.elapsed == 5)          // first → last stamp
    }

    @Test func nonPositiveBPMIsIgnored() {
        var stats = SessionHeartRateStats()
        stats.record(bpm: 0, at: t0)
        stats.record(bpm: -5, at: t0 + 1)
        #expect(stats.averageBPM == nil)     // nothing recorded
        stats.record(bpm: 120, at: t0 + 2)
        #expect(stats.averageBPM == 120)
    }

    @Test func outOfOrderStampNeverShortensElapsed() {
        var stats = SessionHeartRateStats()
        stats.record(bpm: 140, at: t0 + 10)
        stats.record(bpm: 150, at: t0)       // earlier stamp arrives late
        // Elapsed spans first-seen (t0+10) to the max stamp (t0+10); an earlier stamp does not
        // rewind first, and never yields a negative elapsed.
        #expect(stats.elapsed >= 0)
        #expect(stats.averageBPM == 145)     // both still count toward the average
        #expect(stats.maxBPM == 150)
    }
}
