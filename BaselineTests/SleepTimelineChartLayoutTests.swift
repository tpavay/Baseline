import Foundation
import Testing
@testable import Baseline

/// AC-1: the pure interval→geometry helper is asserted without a view tree — enclosing window, stage
/// segment fractions, gaps, midnight crossing, naps (own window), and the empty case. No `Date()`.
struct SleepTimelineChartLayoutTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func interval(_ stage: SleepStage, _ start: Date, _ end: Date) -> SleepStageInterval {
        SleepStageInterval(stage: stage, start: start, end: end, source: .healthKit(bundleID: "test"))
    }

    // MARK: - Window

    @Test func windowSpansEarliestStartToLatestEnd() {
        let intervals = [
            interval(.core, date(2026, 7, 13, 23, 0), date(2026, 7, 14, 1, 0)),
            interval(.rem, date(2026, 7, 14, 1, 0), date(2026, 7, 14, 6, 30)),
        ]
        let window = SleepTimelineLayout.window(for: intervals)
        #expect(window?.start == date(2026, 7, 13, 23, 0))
        #expect(window?.end == date(2026, 7, 14, 6, 30))
        #expect(window?.duration == 7.5 * 3600)
    }

    @Test func emptyIntervalsHaveNoWindow() {
        #expect(SleepTimelineLayout.window(for: []) == nil)
    }

    @Test func zeroSpanHasNoWindow() {
        let t = date(2026, 7, 14, 1, 0)
        #expect(SleepTimelineLayout.window(for: [interval(.core, t, t)]) == nil)
    }

    // MARK: - Segments

    @Test func segmentFractionsAreProportionalAndOrdered() {
        // 8 h window; a 2 h core at the start, a 6 h rem after it.
        let start = date(2026, 7, 13, 23, 0)
        let mid = date(2026, 7, 14, 1, 0)
        let end = date(2026, 7, 14, 7, 0)
        let intervals = [interval(.core, start, mid), interval(.rem, mid, end)]
        let window = SleepTimelineLayout.window(for: intervals)!
        let segs = SleepTimelineLayout.segments(intervals, in: window)

        #expect(segs.count == 2)
        #expect(segs[0].stage == .core)
        #expect(abs(segs[0].startFraction - 0.0) < 1e-9)
        #expect(abs(segs[0].widthFraction - 0.25) < 1e-9)   // 2h / 8h
        #expect(segs[1].stage == .rem)
        #expect(abs(segs[1].startFraction - 0.25) < 1e-9)
        #expect(abs(segs[1].widthFraction - 0.75) < 1e-9)   // 6h / 8h
    }

    @Test func midnightCrossingIsContinuous() {
        // 23:00 → 00:30 must be a single 1.5 h span, not a negative/wrapped one.
        let start = date(2026, 7, 13, 23, 0)
        let end = date(2026, 7, 14, 0, 30)
        let intervals = [interval(.core, start, end)]
        let window = SleepTimelineLayout.window(for: intervals)!
        let segs = SleepTimelineLayout.segments(intervals, in: window)
        #expect(segs.count == 1)
        #expect(abs(segs[0].widthFraction - 1.0) < 1e-9)
    }

    @Test func intervalsOutsideWindowAreClipped() {
        let window = SleepTimelineLayout.Window(start: date(2026, 7, 14, 0, 0), end: date(2026, 7, 14, 4, 0))
        // A 3 h → 5 h interval overlaps only the last hour of the window.
        let seg = SleepTimelineLayout.segments(
            [interval(.rem, date(2026, 7, 14, 3, 0), date(2026, 7, 14, 5, 0))], in: window)
        #expect(seg.count == 1)
        #expect(abs(seg[0].startFraction - 0.75) < 1e-9)
        #expect(abs(seg[0].widthFraction - 0.25) < 1e-9)   // clipped to 3–4h
    }

    // MARK: - Gaps

    @Test func gapSegmentsMapWithoutStage() {
        let window = SleepTimelineLayout.Window(start: date(2026, 7, 14, 0, 0), end: date(2026, 7, 14, 8, 0))
        let gaps = [DateInterval(start: date(2026, 7, 14, 4, 0), end: date(2026, 7, 14, 5, 0))]
        let segs = SleepTimelineLayout.gapSegments(gaps, in: window)
        #expect(segs.count == 1)
        #expect(segs[0].stage == nil)
        #expect(abs(segs[0].startFraction - 0.5) < 1e-9)
        #expect(abs(segs[0].widthFraction - 0.125) < 1e-9)   // 1h / 8h
    }

    // MARK: - Frame mapping

    @Test func frameScalesToWidth() {
        let seg = SleepTimelineLayout.Segment(stage: .core, startFraction: 0.25, widthFraction: 0.5)
        let frame = SleepTimelineLayout.frame(seg, width: 200, height: 40)
        #expect(frame.minX == 50)
        #expect(frame.width == 100)
        #expect(frame.height == 40)
    }

    // MARK: - Naps (own window)

    @Test func napUsesItsOwnWindow() {
        // A 35-min nap fills its own mini-track fully.
        let start = date(2026, 7, 14, 14, 30)
        let end = date(2026, 7, 14, 15, 5)
        let window = SleepTimelineLayout.window(for: [interval(.core, start, end)])!
        let segs = SleepTimelineLayout.segments([interval(.core, start, end)], in: window)
        #expect(segs.count == 1)
        #expect(abs(segs[0].widthFraction - 1.0) < 1e-9)
    }

    // MARK: - Ticks + stage minutes

    @Test func hourTicksLandOnWholeHours() {
        let window = SleepTimelineLayout.Window(start: date(2026, 7, 13, 23, 15), end: date(2026, 7, 14, 2, 45))
        let ticks = SleepTimelineLayout.hourTicks(in: window, calendar: cal)
        // Whole hours strictly inside: 00:00, 01:00, 02:00.
        #expect(ticks.count == 3)
        #expect(ticks.first?.date == date(2026, 7, 14, 0, 0))
        #expect(ticks.allSatisfy { $0.fraction > 0 && $0.fraction < 1 })
    }

    @Test func stageMinutesSumPerStage() {
        let intervals = [
            interval(.core, date(2026, 7, 14, 0, 0), date(2026, 7, 14, 1, 0)),   // 60
            interval(.core, date(2026, 7, 14, 2, 0), date(2026, 7, 14, 2, 30)),  // 30
            interval(.rem, date(2026, 7, 14, 1, 0), date(2026, 7, 14, 2, 0)),    // 60
        ]
        let minutes = SleepTimelineLayout.stageMinutes(intervals)
        #expect(minutes.first(where: { $0.stage == .core })?.minutes == 90)
        #expect(minutes.first(where: { $0.stage == .rem })?.minutes == 60)
        // Stages with no time drop out.
        #expect(minutes.contains(where: { $0.stage == .deep }) == false)
    }
}
