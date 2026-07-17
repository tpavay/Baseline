import Foundation

/// Session-long BPM aggregates — average, max, and elapsed — accumulated across one live run. Pure
/// value type driven by explicit `(bpm, timestamp)` samples so it is fully deterministic in tests (no
/// wall clock), mirroring `ZoneTimeAccumulator`.
///
/// These are *aggregates of what was actually recorded*, so they legitimately persist through a
/// signal dropout: unlike the live BPM (which must blank when stale — see `baseline-live-heart-rate`),
/// an average/max/elapsed summarizes real past samples and never fabricates a current value.
struct SessionHeartRateStats: Equatable, Sendable {

    private(set) var sampleCount = 0
    private(set) var bpmSum = 0
    private(set) var maxBPM: Int?
    private(set) var firstSampleAt: Date?
    private(set) var lastSampleAt: Date?

    /// Rounded mean BPM over every recorded sample, or nil before the first one.
    var averageBPM: Int? {
        guard sampleCount > 0 else { return nil }
        return Int((Double(bpmSum) / Double(sampleCount)).rounded())
    }

    /// Elapsed seconds from the first to the most recent recorded sample (0 before any sample). Read
    /// from recorded stamps rather than a live clock so it is deterministic and only ever grows.
    var elapsed: TimeInterval {
        guard let firstSampleAt, let lastSampleAt else { return 0 }
        return max(lastSampleAt.timeIntervalSince(firstSampleAt), 0)
    }

    /// Record one sample's BPM at time `at`. A non-positive BPM is ignored (a malformed sample
    /// contributes nothing rather than dragging the average down); an out-of-order timestamp still
    /// counts toward average/max but never shortens `elapsed`.
    mutating func record(bpm: Int, at: Date) {
        guard bpm > 0 else { return }
        sampleCount += 1
        bpmSum += bpm
        maxBPM = max(maxBPM ?? bpm, bpm)
        if firstSampleAt == nil { firstSampleAt = at }
        lastSampleAt = lastSampleAt.map { max($0, at) } ?? at
    }
}
