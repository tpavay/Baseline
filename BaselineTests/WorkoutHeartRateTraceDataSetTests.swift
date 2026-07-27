import Foundation
import Testing
@testable import Baseline

/// Everything the trace chart draws, tested without a view: clipping, the elapsed mapping, the axis,
/// the short-series guard, the zone bands, and the display decimation.
struct WorkoutHeartRateTraceDataSetTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func trace(_ offsets: [(TimeInterval, Int)]) -> WorkoutHeartRateTrace {
        WorkoutHeartRateTrace(points: offsets.map {
            HeartRateTracePoint(timestamp: start.addingTimeInterval($0.0), bpm: $0.1)
        })
    }

    private func dataSet(
        _ offsets: [(TimeInterval, Int)],
        duration: TimeInterval = 600,
        zoneModel: HeartRateZoneModel? = nil,
        maximumPlottedPoints: Int = WorkoutHeartRateTraceDataSet.maximumPlottedPoints
    ) -> WorkoutHeartRateTraceDataSet {
        WorkoutHeartRateTraceDataSet(
            trace: trace(offsets),
            startedAt: start,
            duration: duration,
            zoneModel: zoneModel,
            maximumPlottedPoints: maximumPlottedPoints
        )
    }

    // MARK: - Short series

    @Test func oneSampleCannotPlotALineAndGetsAFlatPaddedRange() {
        let set = dataSet([(5, 154)])
        #expect(set.canPlotLine == false)      // a single reading is a dot, never a trend
        #expect(set.points.count == 1)
        #expect(set.heartRateRange == 149...159)
    }

    @Test func twoSamplesStillCannotPlotALine() {
        let set = dataSet([(5, 150), (300, 160)])
        #expect(set.canPlotLine == false)
        #expect(set.points.count == 2)
    }

    @Test func threeSamplesAcrossDistinctSecondsCanPlotALine() {
        let set = dataSet([(5, 150), (300, 160), (600, 140)])
        #expect(set.canPlotLine)
        #expect(set.points.map(\.elapsed) == [5, 300, 600])
        #expect(set.points.map(\.bpm) == [150, 160, 140])
    }

    /// Three readings inside the same second are three measurements of one instant — the line would be
    /// a vertical smear, so they render as points.
    @Test func threeSamplesInsideOneSecondCannotPlotALine() {
        let set = dataSet([(10.1, 150), (10.2, 152), (10.3, 149)])
        #expect(set.points.count == 3)
        #expect(set.canPlotLine == false)
    }

    @Test func anEmptyTraceFallsBackToADefaultRange() {
        let set = dataSet([])
        #expect(set.isEmpty)
        #expect(set.canPlotLine == false)
        #expect(set.heartRateRange == 60...180)
    }

    // MARK: - Clipping and elapsed mapping

    /// A 60 s tolerance either side keeps a strap that started just before the tap, but a reading from
    /// an unrelated session is not this workout's data.
    @Test func samplesFarOutsideTheSessionWindowAreDropped() {
        let set = dataSet([(-30, 120), (-600, 200), (300, 150), (1_200, 190)], duration: 600)
        #expect(set.points.map(\.bpm) == [120, 150])
        #expect(set.sampleCount == 2)
    }

    @Test func elapsedIsClampedIntoTheVisibleWindow() {
        let set = dataSet([(-30, 120), (30, 150), (630, 140)], duration: 600)
        #expect(set.points.map(\.elapsed) == [0, 30, 600])
    }

    @Test func outOfOrderSamplesAreSortedBeforePlotting() {
        let set = dataSet([(300, 160), (5, 150), (600, 140)])
        #expect(set.points.map(\.elapsed) == [5, 300, 600])
    }

    @Test func nonPositiveBeatsPerMinuteNeverReachTheChart() {
        let set = dataSet([(5, 0), (10, 150), (20, -4), (30, 155)])
        #expect(set.points.map(\.bpm) == [150, 155])
    }

    // MARK: - Axis

    @Test func rangePadsBySpanAndFloorsAtThirty() {
        let wide = dataSet([(0, 100), (10, 200), (20, 150)])
        #expect(wide.heartRateRange == 90...210)       // 10 % of a 100 bpm span

        let narrow = dataSet([(0, 150), (10, 154), (20, 152)])
        #expect(narrow.heartRateRange == 147...157)    // padding floors at 3

        let low = dataSet([(0, 31), (10, 33), (20, 32)])
        #expect(low.heartRateRange.lowerBound == 30)   // never below 30 bpm
    }

    @Test func thereAreAlwaysFiveTicksWithPinnedEndpoints() {
        let set = dataSet([(0, 100), (10, 200), (20, 150)])
        #expect(set.heartRateTickValues.count == 5)
        #expect(set.heartRateTickValues.first == set.heartRateRange.lowerBound)
        #expect(set.heartRateTickValues.last == set.heartRateRange.upperBound)
        #expect(set.heartRateTickValues == set.heartRateTickValues.sorted())
    }

    @Test func aZeroDurationSessionStillGetsAVisibleAxis() {
        let set = dataSet([(0, 150), (0.2, 151), (0.4, 152)], duration: 0)
        #expect(set.duration == 1)
    }

    // MARK: - Zone bands

    @Test func zoneBandsComeFromTheSameTableAsZoneClassification() throws {
        // maxHR 200, %max → floors 100 / 120 / 140 / 160 / 180.
        let model = HeartRateZoneModel(maxHR: 200)
        let set = dataSet([(0, 130), (10, 175), (20, 150)], zoneModel: model)
        let preview = HeartRateZonePreview(model: model)

        let z3 = try #require(set.zoneBands.first { $0.zone == .z3 })
        let previewZ3 = try #require(preview.rows.first { $0.zone == .z3 })
        #expect(z3.lowerBPM == previewZ3.lowerBPM)
        #expect(model.zone(forBPM: z3.lowerBPM) == .z3)
    }

    /// The bands tile the drawn range with no unpainted strip, and never spill outside it.
    @Test func zoneBandsCoverExactlyTheDrawnRange() {
        let set = dataSet([(0, 130), (10, 175), (20, 150)], zoneModel: HeartRateZoneModel(maxHR: 200))
        let range = set.heartRateRange
        #expect(set.zoneBands.isEmpty == false)
        for band in set.zoneBands {
            #expect(band.lowerBPM >= range.lowerBound)
            #expect(band.upperBPM <= range.upperBound)
            #expect(band.upperBPM > band.lowerBPM)
        }
        #expect(set.zoneBands.map(\.lowerBPM).min() == range.lowerBound)
        #expect(set.zoneBands.map(\.upperBPM).max() == range.upperBound)

        // Contiguous: each band starts exactly where the previous one ended. Building them from the
        // inclusive *display* upper (next floor − 1) would leave a one-bpm unpainted seam between
        // every pair of zones.
        let ordered = set.zoneBands.sorted { $0.lowerBPM < $1.lowerBPM }
        for (lower, upper) in zip(ordered, ordered.dropFirst()) {
            #expect(lower.upperBPM == upper.lowerBPM)
        }
    }

    /// Only the zones the athlete was actually in are drawn: a hard session does not stretch its axis
    /// down to a Z1 floor it never touched.
    @Test func onlyZonesInsideTheDrawnRangeGetBands() {
        let set = dataSet([(0, 170), (10, 178), (20, 174)], zoneModel: HeartRateZoneModel(maxHR: 200))
        #expect(set.zoneBands.contains { $0.zone == .z1 } == false)
        #expect(set.zoneBands.contains { $0.zone == .z4 })
        #expect(set.heartRateRange.lowerBound > 100)
    }

    @Test func withNoZoneModelThereAreNoBands() {
        let set = dataSet([(0, 130), (10, 175), (20, 150)], zoneModel: nil)
        #expect(set.zoneBands.isEmpty)
    }

    // MARK: - Decimation

    @Test func aLongSeriesIsThinnedForDisplayButKeepsItsRecordedCount() {
        let offsets = (0..<3_600).map { (TimeInterval($0), 140 + $0 % 30) }
        let set = dataSet(offsets, duration: 3_600)

        #expect(set.sampleCount == 3_600)                                 // what was recorded
        #expect(set.points.count == WorkoutHeartRateTraceDataSet.maximumPlottedPoints)  // what is drawn
        #expect(set.points.first?.elapsed == 0)                           // the line still spans
        #expect(set.points.last?.elapsed == 3_599)                        // the whole session
    }

    @Test func aSeriesUnderTheThresholdIsUntouched() {
        let offsets = (0..<50).map { (TimeInterval($0), 150 + $0 % 5) }
        let set = dataSet(offsets, duration: 60, maximumPlottedPoints: 400)
        #expect(set.points.count == 50)
    }

    /// The reason for Largest-Triangle-Three-Buckets over plain striding: a sprint that a stride would
    /// step over survives the thinning, because peaks are what an HR chart is for.
    @Test func decimationPreservesAnIsolatedPeak() {
        var offsets = (0..<2_000).map { (TimeInterval($0), 140) }
        offsets[977] = (977, 191)
        let set = dataSet(offsets, duration: 2_000, maximumPlottedPoints: 100)

        #expect(set.points.contains { $0.bpm == 191 })
        #expect(set.heartRateRange.upperBound >= 191)   // and the axis still reaches it
    }

    @Test func decimationIsAPureFunctionOverPoints() {
        let points = (0..<1_000).map {
            WorkoutHeartRateTraceDataSet.Point(id: $0, elapsed: TimeInterval($0), bpm: 130 + $0 % 50)
        }
        let thinned = WorkoutHeartRateTraceDataSet.decimated(points, to: 250)
        #expect(thinned.count == 250)
        #expect(thinned.first == points.first)
        #expect(thinned.last == points.last)
        #expect(thinned.map(\.elapsed) == thinned.map(\.elapsed).sorted())
        // Below three there is nothing meaningful to thin to, so the input passes through.
        #expect(WorkoutHeartRateTraceDataSet.decimated(points, to: 2).count == points.count)
    }

    // MARK: - Selection and accessibility

    @Test func nearestPointResolvesTapSelection() throws {
        let set = dataSet([(0, 140), (100, 150), (200, 160)])
        #expect(try #require(set.nearestPoint(toElapsed: 96)).bpm == 150)
        #expect(try #require(set.nearestPoint(toElapsed: 1_000)).bpm == 160)
        #expect(dataSet([]).nearestPoint(toElapsed: 10) == nil)
    }

    @Test func theChartSpeaksItsSummaryAsOneElement() {
        let summary = WorkoutHeartRateSummary(
            averageBPM: 148, maxBPM: 172, sampleCount: 600,
            zoneSeconds: [10, 60, 400, 120, 10],
            zoneModel: HeartRateZoneModelSnapshot(HeartRateZoneModel(maxHR: 200))
        )
        let spoken = dataSet([(0, 140), (100, 150), (200, 160)], duration: 600).accessibilityLabel(summary: summary)

        #expect(spoken.contains("average 148 beats per minute"))
        #expect(spoken.contains("maximum 172"))
        #expect(spoken.contains("10:00"))
        #expect(spoken.contains("most time in Z3 Aerobic"))
        #expect(dataSet([]).accessibilityLabel(summary: summary) == "No heart-rate samples")
    }

    // MARK: - Capture convenience

    /// A completed workout charts against its own session window.
    @Test func aCaptureChartsAgainstTheSessionWindow() {
        let capture = WorkoutHeartRateCapture(
            trace: trace([(0, 140), (300, 160), (600, 150)]),
            summary: WorkoutHeartRateSummary(averageBPM: 150, maxBPM: 160, sampleCount: 3, zoneSeconds: [], zoneModel: nil)
        )
        let set = WorkoutHeartRateTraceDataSet(capture: capture, startedAt: start, finishedAt: start.addingTimeInterval(900))
        #expect(set.duration == 900)
        #expect(set.points.count == 3)
    }

    /// Missing bookends must not collapse the axis: the trace's own span is the honest fallback.
    @Test func aCaptureWithoutSessionBookendsFallsBackToItsOwnSpan() {
        let capture = WorkoutHeartRateCapture(
            trace: trace([(0, 140), (300, 160), (600, 150)]),
            summary: WorkoutHeartRateSummary(averageBPM: 150, maxBPM: 160, sampleCount: 3, zoneSeconds: [], zoneModel: nil)
        )
        let set = WorkoutHeartRateTraceDataSet(capture: capture, startedAt: nil, finishedAt: nil)
        #expect(set.duration == 600)
        #expect(set.points.count == 3)
        #expect(set.canPlotLine)
    }

    /// A session that ran on after the strap stopped keeps the full session window, not the shorter
    /// trace — the gap at the end is real and should be visible.
    @Test func aTraceShorterThanTheSessionKeepsTheSessionWindow() {
        let capture = WorkoutHeartRateCapture(
            trace: trace([(0, 140), (60, 150), (120, 145)]),
            summary: WorkoutHeartRateSummary(averageBPM: 145, maxBPM: 150, sampleCount: 3, zoneSeconds: [], zoneModel: nil)
        )
        let set = WorkoutHeartRateTraceDataSet(capture: capture, startedAt: start, finishedAt: start.addingTimeInterval(1_800))
        #expect(set.duration == 1_800)
        #expect(set.points.last?.elapsed == 120)
    }

    /// A session whose bookends disagree with the recorded trace still charts every sample on a real
    /// axis. Intersecting the two would collapse a half-hour trace into a one-second axis and render
    /// a stack of dots — a rendering bug that also hides real training.
    @Test func aSessionWindowThatDisagreesWithTheTraceStillChartsTheWholeSeries() {
        let capture = WorkoutHeartRateCapture(
            trace: trace((0..<1_800).map { (TimeInterval($0), 140 + $0 % 20) }),
            summary: WorkoutHeartRateSummary(averageBPM: 149, maxBPM: 159, sampleCount: 1_800, zoneSeconds: [], zoneModel: nil)
        )
        // Bookends an instant wide, 30 minutes after the trace began.
        let bookend = start.addingTimeInterval(1_800)
        let set = WorkoutHeartRateTraceDataSet(capture: capture, startedAt: bookend, finishedAt: bookend)

        #expect(set.duration == 1_800)
        #expect(set.sampleCount == 1_800)
        #expect(set.canPlotLine)
        #expect(set.points.first?.elapsed == 0)
    }

    /// The zone bands of a completed workout come from the snapshot frozen at completion, so editing
    /// max HR later cannot re-band a chart of a past session.
    @Test func aCaptureBandsAgainstItsFrozenZoneModel() throws {
        let capture = WorkoutHeartRateCapture(
            trace: trace([(0, 140), (60, 150), (120, 145)]),
            summary: WorkoutHeartRateSummary(
                averageBPM: 145, maxBPM: 150, sampleCount: 3, zoneSeconds: [0, 0, 120, 0, 0],
                zoneModel: HeartRateZoneModelSnapshot(HeartRateZoneModel(maxHR: 200))
            )
        )
        let set = WorkoutHeartRateTraceDataSet(capture: capture, startedAt: start, finishedAt: start.addingTimeInterval(120))
        let z3 = try #require(set.zoneBands.first { $0.zone == .z3 })
        #expect(z3.lowerBPM == HeartRateZoneModel(maxHR: 200).lowerBPM(for: .z3))
    }
}
