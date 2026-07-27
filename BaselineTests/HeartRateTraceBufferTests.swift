import Foundation
import Testing
@testable import Baseline

/// The capture rules of the live trace buffer: rate limiting, monotonicity, junk rejection, and the
/// invariant that its on-demand JSON payload always decodes back to exactly the points it holds.
struct HeartRateTraceBufferTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func decoded(_ buffer: HeartRateTraceBuffer) throws -> [HeartRateTracePoint] {
        let payload = try #require(buffer.encodedPayload)
        return try JSONDecoder().decode([HeartRateTracePoint].self, from: payload)
    }

    @Test func aFreshBufferHasNoPayload() {
        let buffer = HeartRateTraceBuffer()
        #expect(buffer.isEmpty)
        #expect(buffer.encodedPayload == nil)   // "no heart rate" is representable, not an empty array
        #expect(buffer.trace.hasSamples == false)
    }

    @Test func samplesFasterThanTheCaptureIntervalAreDropped() {
        var buffer = HeartRateTraceBuffer(minimumCaptureInterval: 0.9)
        // A strap notifying twice a second: every other reading clears the 0.9 s floor.
        for tick in 0..<10 {
            buffer.record(bpm: 140 + tick, capturedAt: start.addingTimeInterval(Double(tick) * 0.5))
        }
        #expect(buffer.points.map(\.bpm) == [140, 142, 144, 146, 148])
    }

    /// The floor is 0.9 s rather than 1 s so an ordinary ~1 Hz strap keeps every notification even
    /// when its cadence jitters slightly early.
    @Test func aNormalOneHertzStrapKeepsEverySample() {
        var buffer = HeartRateTraceBuffer(minimumCaptureInterval: 0.9)
        for tick in 0..<10 {
            buffer.record(bpm: 120 + tick, capturedAt: start.addingTimeInterval(Double(tick) * 0.95))
        }
        #expect(buffer.points.count == 10)
    }

    @Test func nonPositiveBeatsPerMinuteNeverLand() {
        var buffer = HeartRateTraceBuffer()
        buffer.record(bpm: 0, capturedAt: start)
        buffer.record(bpm: -70, capturedAt: start.addingTimeInterval(2))
        buffer.record(bpm: 138, capturedAt: start.addingTimeInterval(4))
        #expect(buffer.points.map(\.bpm) == [138])
    }

    /// The series must be strictly increasing in time, so a session-anchored point that does not
    /// advance the timeline is refused rather than folded back into the middle of the trace.
    @Test func aPointThatDoesNotAdvanceTheTimelineIsRefused() {
        var buffer = HeartRateTraceBuffer(minimumCaptureInterval: 0)
        buffer.record(bpm: 140, capturedAt: start, sessionStartedAt: start, sessionElapsed: 10)
        buffer.record(bpm: 150, capturedAt: start.addingTimeInterval(1), sessionStartedAt: start, sessionElapsed: 10)
        buffer.record(bpm: 160, capturedAt: start.addingTimeInterval(2), sessionStartedAt: start, sessionElapsed: 5)
        buffer.record(bpm: 170, capturedAt: start.addingTimeInterval(3), sessionStartedAt: start, sessionElapsed: 20)

        #expect(buffer.points.map(\.bpm) == [140, 170])
        #expect(buffer.points.map { $0.timestamp.timeIntervalSince(start) } == [10, 20])
    }

    /// A resumed session lands on the session's logical timeline, not on the wall clock, so the gap
    /// left by an interruption is not punched into the trace.
    @Test func sessionAnchoringStampsPointsOnTheSessionTimeline() {
        var buffer = HeartRateTraceBuffer(minimumCaptureInterval: 0)
        buffer.record(
            bpm: 145,
            capturedAt: start.addingTimeInterval(3_600),   // an hour of wall clock later
            sessionStartedAt: start,
            sessionElapsed: 42
        )
        #expect(buffer.points.first?.timestamp == start.addingTimeInterval(42))
    }

    @Test func encodedPayloadDecodesBackToExactlyThePoints() throws {
        var buffer = HeartRateTraceBuffer(minimumCaptureInterval: 0)
        for tick in 0..<50 {
            buffer.record(bpm: 130 + tick % 20, capturedAt: start.addingTimeInterval(Double(tick)))
        }
        #expect(try decoded(buffer) == buffer.points)
    }

    /// The on-demand payload is not a second format: it carries the same *values* as encoding the
    /// series directly, and stays a plain JSON array of exactly the recorded elements.
    ///
    /// Value equality, not byte equality: `JSONEncoder` does not guarantee a stable key order between
    /// calls, so two encodes of the same struct can legitimately differ byte for byte.
    @Test func theOnDemandPayloadCarriesTheSameSeriesAsAWholeEncode() throws {
        var buffer = HeartRateTraceBuffer(minimumCaptureInterval: 0)
        for tick in 0..<25 {
            buffer.record(bpm: 150 + tick, capturedAt: start.addingTimeInterval(Double(tick)))
        }
        let payload = try #require(buffer.encodedPayload)
        let whole = try JSONEncoder().encode(buffer.points)
        let decoder = JSONDecoder()
        #expect(
            try decoder.decode([HeartRateTracePoint].self, from: payload)
                == (try decoder.decode([HeartRateTracePoint].self, from: whole))
        )
        // Structurally an array of exactly the recorded elements, with nothing wrapping it.
        #expect(payload.first == UInt8(ascii: "["))
        #expect(payload.last == UInt8(ascii: "]"))
    }

    @Test func restoringSeedsTheBufferAndAppendingContinuesTheSameSeries() throws {
        let recovered = (0..<5).map {
            HeartRateTracePoint(timestamp: start.addingTimeInterval(Double($0)), bpm: 120 + $0)
        }
        var buffer = HeartRateTraceBuffer(restoring: recovered, minimumCaptureInterval: 0.9)
        #expect(buffer.points == recovered)

        buffer.record(bpm: 155, capturedAt: start.addingTimeInterval(10))
        #expect(buffer.points.count == 6)
        #expect(try decoded(buffer) == buffer.points)
    }

    /// Restoring sorts and filters, so a recovered draft with junk or out-of-order rows still yields a
    /// clean strictly-increasing series.
    @Test func restoringSortsAndDropsJunk() {
        let messy = [
            HeartRateTracePoint(timestamp: start.addingTimeInterval(5), bpm: 150),
            HeartRateTracePoint(timestamp: start, bpm: 140),
            HeartRateTracePoint(timestamp: start.addingTimeInterval(3), bpm: 0),
            HeartRateTracePoint(timestamp: start.addingTimeInterval(2), bpm: 145),
        ]
        let buffer = HeartRateTraceBuffer(restoring: messy)
        #expect(buffer.points.map(\.bpm) == [140, 145, 150])
    }

    /// `sorted(by:)` is not stable against equal timestamps, so a recovered draft carrying duplicate
    /// stamps would otherwise yield a merely non-decreasing series — and `WorkoutHeartRateTrace`'s
    /// bounds assume it strictly increases.
    @Test func restoringRefusesDuplicateTimestamps() {
        let duplicated = [
            HeartRateTracePoint(timestamp: start, bpm: 140),
            HeartRateTracePoint(timestamp: start, bpm: 141),
            HeartRateTracePoint(timestamp: start.addingTimeInterval(1), bpm: 150),
            HeartRateTracePoint(timestamp: start.addingTimeInterval(1), bpm: 151),
        ]
        let buffer = HeartRateTraceBuffer(restoring: duplicated)
        #expect(buffer.points.count == 2)
        #expect(zip(buffer.points, buffer.points.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
    }

    /// A restored series has already consumed the capture budget up to its last point, so the first
    /// live sample after recovery is rate-limited like any other rather than admitted for free.
    @Test func aLiveSampleArrivingImmediatelyAfterARestoreIsStillRateLimited() {
        let recovered = (0..<3).map {
            HeartRateTracePoint(timestamp: start.addingTimeInterval(Double($0)), bpm: 130 + $0)
        }
        var buffer = HeartRateTraceBuffer(restoring: recovered, minimumCaptureInterval: 0.9)

        buffer.record(bpm: 160, capturedAt: start.addingTimeInterval(2.4))   // 0.4 s after the last
        #expect(buffer.points.count == 3)

        buffer.record(bpm: 162, capturedAt: start.addingTimeInterval(3.1))   // clears the floor
        #expect(buffer.points.map(\.bpm).last == 162)
    }

    @Test func traceExposesItsOwnBoundsAndSpan() {
        var buffer = HeartRateTraceBuffer(minimumCaptureInterval: 0)
        buffer.record(bpm: 120, capturedAt: start)
        buffer.record(bpm: 170, capturedAt: start.addingTimeInterval(600))
        let trace = buffer.trace
        #expect(trace.count == 2)
        #expect(trace.startAt == start)
        #expect(trace.endAt == start.addingTimeInterval(600))
        #expect(trace.span == 600)
    }
}
