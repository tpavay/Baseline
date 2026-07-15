import SwiftUI

/// Pure interval → geometry math for the sleep timeline (plan §9). No SwiftUI, no `Date()`, nothing
/// invented: the same intervals always produce the same fractional frames, so the whole layout is
/// unit-testable without a view tree (house rule, mirrors `SleepEngine`/`DecisionEngine`). The chart
/// `body` only draws the segments this helper returns.
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

    /// Total minutes per stage across the intervals — the accessible-summary fallback source.
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
    /// Deepest → lightest, awake last — the stacking/summary order for the timeline legend.
    static let displayOrder: [SleepStage] = [.deep, .core, .rem, .unspecified, .awake]

    /// Design-system stage color (violet/indigo family — deliberately distinct from the readiness
    /// band hues, plan §2 Q-B). Domain→token mapping lives here in the feature, keeping `BaselineColor`
    /// free of sleep knowledge.
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

// MARK: - Chart

/// In-house SwiftUI stage timeline (plan §9): stage bands on a time axis, gap hatching, and naps
/// rendered as their own small tracks below the primary night. `body` does layout only — every
/// interval→geometry decision comes from `SleepTimelineLayout`. Under large Dynamic Type it degrades
/// to a text summary of stage durations (AC-8).
struct SleepTimelineChart: View {
    let intervals: [SleepStageInterval]
    var gaps: [DateInterval] = []
    var naps: [SleepEpisode] = []
    var calendar: Calendar = .current

    @Environment(\.dynamicTypeSize) private var typeSize

    private var window: SleepTimelineLayout.Window? { SleepTimelineLayout.window(for: intervals) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let window, !typeSize.isAccessibilitySize {
                track(intervals: intervals, gaps: gaps, window: window)
                    .frame(height: 56)
                axis(window: window)
                legend
                if !naps.isEmpty { napSection }
            } else {
                accessibleSummary
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stage timeline")
        .accessibilityValue(accessibilitySummaryText)
    }

    // MARK: - Graphical track

    private func track(intervals: [SleepStageInterval], gaps: [DateInterval],
                       window: SleepTimelineLayout.Window) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(BaselineColor.base)
                ForEach(Array(SleepTimelineLayout.segments(intervals, in: window).enumerated()), id: \.offset) { _, seg in
                    let f = SleepTimelineLayout.frame(seg, width: w, height: h)
                    Rectangle()
                        .fill((seg.stage ?? .unspecified).color)
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX)
                }
                ForEach(Array(SleepTimelineLayout.gapSegments(gaps, in: window).enumerated()), id: \.offset) { _, seg in
                    let f = SleepTimelineLayout.frame(seg, width: w, height: h)
                    GapHatch()
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func axis(window: SleepTimelineLayout.Window) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ForEach(Array(SleepTimelineLayout.hourTicks(in: window, calendar: calendar).enumerated()), id: \.offset) { _, tick in
                Text(tick.date, format: .dateTime.hour())
                    .font(.bMono(9, .medium))
                    .foregroundStyle(BaselineColor.textFaint)
                    .fixedSize()
                    .alignmentGuide(HorizontalAlignment.leading) { d in d[HorizontalAlignment.center] }
                    .offset(x: CGFloat(tick.fraction) * w)
            }
        }
        .frame(height: 12)
    }

    private var legend: some View {
        let present = SleepStage.displayOrder.filter { stage in intervals.contains { $0.stage == stage } }
        return FlowRow(spacing: 12) {
            ForEach(present, id: \.self) { stage in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(stage.color).frame(width: 10, height: 10)
                    Text(stage.label).font(.bMono(10, .medium)).foregroundStyle(BaselineColor.textMid)
                }
            }
        }
    }

    private var napSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InstrumentLabel("Naps")
            ForEach(naps) { nap in
                if let napWindow = SleepTimelineLayout.window(for: nap.intervals) {
                    HStack(spacing: 10) {
                        track(intervals: nap.intervals, gaps: nap.gaps, window: napWindow)
                            .frame(height: 20).frame(maxWidth: 140)
                        Text(napWindow.start, format: .dateTime.hour().minute())
                            .font(.bMono(10, .medium)).foregroundStyle(BaselineColor.textFaint)
                    }
                }
            }
        }
    }

    // MARK: - Accessible fallback

    private var accessibleSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SleepTimelineLayout.stageMinutes(intervals), id: \.stage) { entry in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(entry.stage.color).frame(width: 10, height: 10)
                    Text("\(entry.stage.label): \(SleepFormat.minutes(entry.minutes))")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textMid)
                }
            }
            if intervals.isEmpty {
                Text("No stage timeline available for this night.")
                    .font(.system(size: 14)).foregroundStyle(BaselineColor.textFaint)
            }
        }
    }

    private var accessibilitySummaryText: String {
        let parts = SleepTimelineLayout.stageMinutes(intervals)
            .map { "\($0.stage.label) \(SleepFormat.minutes($0.minutes))" }
        return parts.isEmpty ? "No stage data" : parts.joined(separator: ", ")
    }
}

/// Diagonal hatching used to mark tracking gaps over the sleep track.
private struct GapHatch: View {
    var body: some View {
        Rectangle()
            .fill(BaselineColor.line.opacity(0.5))
            .overlay(
                GeometryReader { geo in
                    Path { path in
                        let step: CGFloat = 6
                        var x: CGFloat = -geo.size.height
                        while x < geo.size.width {
                            path.move(to: CGPoint(x: x, y: geo.size.height))
                            path.addLine(to: CGPoint(x: x + geo.size.height, y: 0))
                            x += step
                        }
                    }
                    .stroke(BaselineColor.textFaint.opacity(0.6), lineWidth: 1)
                }
            )
    }
}

/// Minimal wrapping HStack for the legend so chips reflow under large type instead of clipping.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0, totalHeight: CGFloat = 0, maxRow: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                maxRow = max(maxRow, rowWidth - spacing)
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRow = max(maxRow, rowWidth - spacing)
        return CGSize(width: min(maxRow, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Previews

#if DEBUG
private func chartPreview() -> some View {
    let night = SleepPreviewFixtures.stagedNight
    return SleepTimelineChart(intervals: night.primaryEpisode?.intervals ?? [],
                              gaps: night.primaryEpisode?.gaps ?? [],
                              naps: night.episodes.filter { !$0.isPrimary },
                              calendar: SleepPreviewFixtures.calendar)
        .padding(20).frame(maxWidth: .infinity).background(BaselineColor.base)
}

#Preview("Timeline · dark") { chartPreview().preferredColorScheme(.dark) }
#Preview("Timeline · light") { chartPreview().preferredColorScheme(.light) }
#Preview("Timeline · accessibility summary") {
    chartPreview().environment(\.dynamicTypeSize, .accessibility3).preferredColorScheme(.dark)
}
#endif
