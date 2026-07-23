import Foundation
import Testing
@testable import Baseline

private typealias Fix = SleepFixtures

/// Pure lane geometry for the staged hypnogram: stage → lane mapping in the approved top-to-bottom
/// order, fractional band positions, the 2-hour axis ticks, and lane-ordered legend totals.
struct SleepHypnogramLayoutTests {

    private let source: SleepSource = .healthKit(bundleID: Fix.watchBundle)

    private func interval(_ stage: SleepStage, _ startMin: Double, _ endMin: Double,
                          from anchor: Date) -> SleepStageInterval {
        SleepStageInterval(stage: stage,
                           start: anchor.addingTimeInterval(startMin * 60),
                           end: anchor.addingTimeInterval(endMin * 60),
                           source: source)
    }

    @Test func lanesFollowTheApprovedTopToBottomOrder() {
        #expect(SleepHypnogramLayout.lanes == [.awake, .rem, .core, .deep])
    }

    @Test func bandsMapStagesToLanesWithWindowFractions() throws {
        let anchor = Fix.date(2026, 4, 19, 23, 0)
        let intervals = [
            interval(.core, 0, 120, from: anchor),
            interval(.awake, 120, 130, from: anchor),
            interval(.rem, 130, 190, from: anchor),
            interval(.deep, 190, 240, from: anchor),
        ]
        let window = try #require(SleepTimelineLayout.window(for: intervals))
        let bands = SleepHypnogramLayout.bands(intervals, in: window)

        #expect(bands.map(\.lane) == [2, 0, 1, 3])           // core, awake, rem, deep lanes
        #expect(bands.map(\.stage) == [.core, .awake, .rem, .deep])
        #expect(abs(bands[0].startFraction - 0) < 1e-9)
        #expect(abs(bands[0].widthFraction - 0.5) < 1e-9)    // 120 of 240 min
        #expect(abs(bands[1].startFraction - 0.5) < 1e-9)
        #expect(abs(bands[3].widthFraction - 50.0 / 240) < 1e-9)
    }

    @Test func unspecifiedIntervalsHaveNoLaneAndNoStagedData() throws {
        let anchor = Fix.date(2026, 4, 19, 23, 0)
        let unspecified = [interval(.unspecified, 0, 480, from: anchor)]
        let window = try #require(SleepTimelineLayout.window(for: unspecified))

        #expect(SleepHypnogramLayout.hasStagedData(unspecified) == false)
        #expect(SleepHypnogramLayout.bands(unspecified, in: window).isEmpty)

        let staged = unspecified + [interval(.rem, 60, 90, from: anchor)]
        #expect(SleepHypnogramLayout.hasStagedData(staged))
    }

    @Test func axisTicksAreEveryOtherHour() throws {
        // 23:00 → 07:00: hourly ticks at 00:00…06:00 (7); every-other keeps 00:00, 02:00, 04:00, 06:00.
        let anchor = Fix.date(2026, 4, 19, 23, 0)
        let intervals = [interval(.core, 0, 480, from: anchor), interval(.rem, 60, 90, from: anchor)]
        let window = try #require(SleepTimelineLayout.window(for: intervals))
        let ticks = SleepHypnogramLayout.axisTicks(in: window, calendar: Fix.calendar)

        #expect(ticks.count == 4)
        let hours = ticks.map { Fix.calendar.component(.hour, from: $0.date) }
        #expect(hours == [0, 2, 4, 6])
    }

    @Test func legendTotalsAreLaneOrderedAndSummed() {
        let anchor = Fix.date(2026, 4, 19, 23, 0)
        let intervals = [
            interval(.core, 0, 100, from: anchor),
            interval(.deep, 100, 180, from: anchor),
            interval(.awake, 180, 204, from: anchor),
            interval(.core, 204, 300, from: anchor),
            interval(.rem, 300, 375, from: anchor),
        ]
        let totals = SleepHypnogramLayout.legendTotals(intervals)

        #expect(totals.map(\.stage) == [.awake, .rem, .core, .deep])
        #expect(totals.map(\.minutes) == [24, 75, 196, 80])
    }
}
