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

    // MARK: - Radial-height fill (the approved sleep-ring behavior)

    @Test func radialFillGrowsThicknessOutwardFromTheInnerEdge() {
        let lineWidth = 11.0

        // Full points → full track thickness, centered on the track (offset 0).
        let full = SegmentedRingLayout.radialFill(progress: 1, lineWidth: lineWidth)
        #expect(abs(full.thickness - lineWidth) < tolerance)
        #expect(abs(full.centerRadiusOffset) < tolerance)

        // Partial points → proportional thickness hugging the track's inner edge: the fill's inner
        // radius (center + offset − t/2) equals the track's inner radius (−lineWidth/2).
        let half = SegmentedRingLayout.radialFill(progress: 16.0 / 30, lineWidth: lineWidth)
        #expect(abs(half.thickness - lineWidth * 16 / 30) < tolerance)
        #expect(abs((half.centerRadiusOffset - half.thickness / 2) - (-lineWidth / 2)) < tolerance)

        // Zero points → no fill.
        let empty = SegmentedRingLayout.radialFill(progress: 0, lineWidth: lineWidth)
        #expect(empty.thickness == 0)
    }

    @Test func radialFillClampsInvalidProgress() {
        let over = SegmentedRingLayout.radialFill(progress: 2, lineWidth: 10)
        #expect(abs(over.thickness - 10) < tolerance)
        let negative = SegmentedRingLayout.radialFill(progress: -1, lineWidth: 10)
        #expect(negative.thickness == 0)
        let nan = SegmentedRingLayout.radialFill(progress: .nan, lineWidth: 10)
        #expect(nan.thickness == 0)
    }

    @Test func sleepRingUsesFullSweepArcsWeightedByComponentCeilings() {
        // The approved geometry: 50/30/20 arcs with 28° gaps → 276° usable sweep, split 138/82.8/55.2.
        let layout = SegmentedRingLayout(
            weights: [50, 30, 20],
            progresses: [1, 16.0 / 30, 11.0 / 20],
            gapDegrees: 28
        )
        #expect(layout.segments.count == 3)
        #expect(abs(layout.segments[0].sweep - 138.0) < tolerance)
        #expect(abs(layout.segments[1].sweep - 82.8) < tolerance)
        #expect(abs(layout.segments[2].sweep - 55.2) < tolerance)
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
