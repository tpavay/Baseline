import SwiftUI

/// Pure interval → geometry math for sleep stage charts (plan §9). No SwiftUI, no `Date()`, nothing
/// invented: the same intervals always produce the same fractional frames, so the whole layout is
/// unit-testable without a view tree (house rule, mirrors `SleepEngine`/`DecisionEngine`). The
/// staged hypnogram (`SleepHypnogramChart`, the approved-redesign chart) builds its lane geometry on
/// these primitives.
enum SleepTimelineLayout {

    /// The time window a track is drawn across. `duration` is guaranteed > 0 by `window(for:)`.
    struct Window: Equatable, Sendable {
        var start: Date
        var end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// One drawable band, positioned in 0…1 fractions of the window width. `stage` is nil for a gap.
    struct Segment: Equatable, Sendable {
        var stage: SleepStage?
        var startFraction: Double
        var widthFraction: Double
    }

    /// An axis tick at a whole-hour boundary inside the window.
    struct Tick: Equatable, Sendable {
        var fraction: Double
        var date: Date
    }

    /// The enclosing window of a set of intervals (earliest start → latest end). nil when empty or
    /// degenerate (zero span), which the view renders as its accessible-summary fallback.
    static func window(for intervals: [SleepStageInterval]) -> Window? {
        guard let start = intervals.map(\.start).min(),
              let end = intervals.map(\.end).max(),
              end > start else { return nil }
        return Window(start: start, end: end)
    }

    /// Fractional bands for stage intervals clipped to `window`. Intervals fully outside the window
    /// drop out; a partially-overlapping one is clipped. Order is preserved.
    static func segments(_ intervals: [SleepStageInterval], in window: Window) -> [Segment] {
        intervals.compactMap { segment(start: $0.start, end: $0.end, stage: $0.stage, in: window) }
    }

    /// Fractional bands for tracking gaps clipped to `window` (drawn as hatching over the track).
    static func gapSegments(_ gaps: [DateInterval], in window: Window) -> [Segment] {
        gaps.compactMap { segment(start: $0.start, end: $0.end, stage: nil, in: window) }
    }

    private static func segment(start: Date, end: Date, stage: SleepStage?, in window: Window) -> Segment? {
        let clippedStart = max(start, window.start)
        let clippedEnd = min(end, window.end)
        guard clippedEnd > clippedStart else { return nil }
        let startFraction = clippedStart.timeIntervalSince(window.start) / window.duration
        let widthFraction = clippedEnd.timeIntervalSince(clippedStart) / window.duration
        return Segment(stage: stage,
                       startFraction: startFraction.clampedUnit,
                       widthFraction: min(widthFraction, 1 - startFraction).clampedUnit)
    }

    /// A fractional segment's pixel frame for a track of the given size.
    static func frame(_ segment: Segment, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: CGFloat(segment.startFraction) * width, y: 0,
               width: CGFloat(segment.widthFraction) * width, height: height)
    }

    /// Whole-hour tick marks inside the window (both endpoints exclusive of partial hours), so the
    /// axis reads "11 PM · 1 AM · 3 AM …". Empty when the calendar can't advance (defensive).
    static func hourTicks(in window: Window, calendar: Calendar) -> [Tick] {
        guard window.duration > 0,
              let firstHour = calendar.nextDate(after: window.start, matching: DateComponents(minute: 0, second: 0),
                                                matchingPolicy: .nextTime) else { return [] }
        var ticks: [Tick] = []
        var cursor = firstHour
        var guardCount = 0
        while cursor < window.end && guardCount < 48 {
            let fraction = cursor.timeIntervalSince(window.start) / window.duration
            ticks.append(Tick(fraction: fraction.clampedUnit, date: cursor))
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        return ticks
    }

    /// Total minutes per stage across the intervals - the legend/accessible-summary source.
    static func stageMinutes(_ intervals: [SleepStageInterval]) -> [(stage: SleepStage, minutes: Double)] {
        SleepStage.displayOrder.compactMap { stage in
            let minutes = intervals.filter { $0.stage == stage }.reduce(0.0) { $0 + $1.duration } / 60
            return minutes > 0 ? (stage, minutes) : nil
        }
    }
}

private extension Double {
    var clampedUnit: Double { Swift.min(Swift.max(self, 0), 1) }
}

// MARK: - Stage presentation

extension SleepStage {
    /// Deepest → lightest, awake last - the stacking/summary order for stage totals.
    static let displayOrder: [SleepStage] = [.deep, .core, .rem, .unspecified, .awake]

    /// Design-system stage color (the approved hypnogram palette). Domain→token mapping lives here
    /// in the feature, keeping `BaselineColor` free of sleep knowledge.
    var color: Color {
        switch self {
        case .deep: BaselineColor.sleepDeep
        case .core: BaselineColor.sleepCore
        case .rem: BaselineColor.sleepREM
        case .awake: BaselineColor.sleepAwake
        case .unspecified: BaselineColor.sleepUnspecified
        }
    }

    var label: String {
        switch self {
        case .deep: "Deep"
        case .core: "Core"
        case .rem: "REM"
        case .awake: "Awake"
        case .unspecified: "Asleep"
        }
    }
}
