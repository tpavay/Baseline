import Testing
@testable import Baseline

struct DesignSystemSegmentedRingTests {
    private let tolerance = 0.000_001

    @Test func sleepDialUsesThreeWeightedArcsWithIndependentProgress() throws {
        let progresses = [0.78, 0.62, 0.73]
        let layout = SegmentedRingLayout(
            weights: [0.4, 0.35, 0.25],
            progresses: progresses,
            gapDegrees: 8
        )

        #expect(layout.segments.count == 3)
        #expect(abs(layout.segments.map(\.sweep).reduce(0, +) - 336) < tolerance)

        for index in layout.segments.indices {
            let segment = layout.segments[index]
            let progressSweep = segment.progressEndAngle - segment.startAngle
            #expect(abs(progressSweep - segment.sweep * progresses[index]) < tolerance)
        }

        #expect(abs(layout.segments[1].startAngle - layout.segments[0].endAngle - 8) < tolerance)
        #expect(abs(layout.segments[2].startAngle - layout.segments[1].endAngle - 8) < tolerance)
    }

    @Test func zoneDonutUsesFiveProportionalCompletedSegments() {
        let weights = [34.0, 41, 38, 22, 8]
        let layout = SegmentedRingLayout(
            weights: weights,
            progresses: Array(repeating: 1, count: weights.count),
            gapDegrees: 1.2
        )

        #expect(layout.segments.count == 5)
        #expect(abs(layout.segments.map(\.sweep).reduce(0, +) - 354) < tolerance)
        #expect(layout.segments[1].sweep > layout.segments[0].sweep)
        #expect(layout.segments[0].sweep > layout.segments[4].sweep)

        for segment in layout.segments {
            #expect(abs(segment.progressEndAngle - segment.endAngle) < tolerance)
        }
    }

    @Test func invalidWeightsAreDroppedAndProgressClamps() {
        let layout = SegmentedRingLayout(
            weights: [1, 0, -1, 1],
            progresses: [2, 0.5, 0.5, -0.5],
            gapDegrees: 4
        )

        #expect(layout.segments.map(\.index) == [0, 3])
        #expect(layout.segments[0].progressEndAngle == layout.segments[0].endAngle)
        #expect(layout.segments[1].progressEndAngle == layout.segments[1].startAngle)
    }

    @Test func missingProgressDefaultsToEmptyAndZeroWeightsRenderNothing() throws {
        let partiallySpecified = SegmentedRingLayout(
            weights: [1, 1],
            progresses: [0.5],
            gapDegrees: 8
        )
        let second = try #require(partiallySpecified.segments.last)
        #expect(second.progressEndAngle == second.startAngle)

        let empty = SegmentedRingLayout(
            weights: [0, -1],
            progresses: [1, 1],
            gapDegrees: 8
        )
        #expect(empty.segments.isEmpty)
    }

    @Test func excessiveGapIsClampedWithoutNegativeArcs() {
        let layout = SegmentedRingLayout(
            weights: [1, 1, 1],
            progresses: [1, 1, 1],
            gapDegrees: 200
        )

        #expect(layout.segments.count == 3)
        #expect(layout.segments.allSatisfy { $0.sweep > 0 })
    }
}
