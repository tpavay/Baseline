import SwiftUI

/// Pure interval → lane geometry for the staged hypnogram (approved sleep redesign). No SwiftUI, no
/// `Date()`: the same intervals always produce the same lanes, bands, ticks, and totals, so the whole
/// layout is unit-testable without a view tree (house rule, mirrors `SleepTimelineLayout`, whose
/// window/fraction math it reuses).
enum SleepHypnogramLayout {

    /// Lane order top → bottom, exactly as the approved design plots the night:
    /// Awake / REM / Core / Deep.
    static let lanes: [SleepStage] = [.awake, .rem, .core, .deep]

    /// One drawable stage band: its lane row plus fractional x-position in the window.
    struct Band: Equatable, Sendable {
        var lane: Int
        var stage: SleepStage
        var startFraction: Double
        var widthFraction: Double
    }

    /// True when the intervals carry real stage structure (anything beyond `.unspecified`) - the
    /// hypnogram only renders staged nights; a duration-only night has no lanes to plot.
    static func hasStagedData(_ intervals: [SleepStageInterval]) -> Bool {
        intervals.contains { lanes.contains($0.stage) }
    }

    /// Lane bands for the staged intervals clipped to `window`. `.unspecified` intervals drop out
    /// (they have no lane); order is preserved.
    static func bands(_ intervals: [SleepStageInterval],
                      in window: SleepTimelineLayout.Window) -> [Band] {
        SleepTimelineLayout.segments(intervals, in: window).compactMap { segment in
            guard let stage = segment.stage, let lane = lanes.firstIndex(of: stage) else { return nil }
            return Band(lane: lane, stage: stage,
                        startFraction: segment.startFraction,
                        widthFraction: segment.widthFraction)
        }
    }

    /// Every-other-hour axis ticks (the approved design labels the axis at 2 h intervals: "9 PM ·
    /// 11 PM · 1 AM …"), taken from the shared whole-hour tick math.
    static func axisTicks(in window: SleepTimelineLayout.Window,
                          calendar: Calendar) -> [SleepTimelineLayout.Tick] {
        let hourly = SleepTimelineLayout.hourTicks(in: window, calendar: calendar)
        return hourly.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
    }

    /// Per-stage totals in lane order, for the legend ("Awake 24m · REM 1h 15m · …"). Stages with no
    /// time drop out.
    static func legendTotals(_ intervals: [SleepStageInterval]) -> [(stage: SleepStage, minutes: Double)] {
        let minutes = SleepTimelineLayout.stageMinutes(intervals)
        return lanes.compactMap { lane in
            minutes.first { $0.stage == lane }
        }
    }
}

/// The staged hypnogram from the approved sleep redesign: Awake / REM / Core / Deep lanes plotted
/// across the sleep window with dashed lane gridlines, gap hatching, a 2-hour time axis, and a
/// legend of per-stage totals. `body` does layout only - every interval→geometry decision comes from
/// `SleepHypnogramLayout`. Under accessibility Dynamic Type it degrades to a text summary of stage
/// durations, mirroring `SleepTimelineChart`.
struct SleepHypnogramChart: View {
    let intervals: [SleepStageInterval]
    var gaps: [DateInterval] = []
    var calendar: Calendar = .current

    @Environment(\.dynamicTypeSize) private var typeSize

    private var window: SleepTimelineLayout.Window? { SleepTimelineLayout.window(for: intervals) }

    private enum Metrics {
        static let laneHeight: CGFloat = 28
        static let bandHeight: CGFloat = 10
        static let labelWidth: CGFloat = 40
        static let bandMinWidth: CGFloat = 4
        static let bandCornerRadius: CGFloat = 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let window, SleepHypnogramLayout.hasStagedData(intervals), !typeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 6) {
                    laneLabels
                    VStack(alignment: .leading, spacing: 6) {
                        plot(window: window)
                            .frame(height: Metrics.laneHeight * CGFloat(SleepHypnogramLayout.lanes.count))
                        axis(window: window)
                    }
                }
                legend
            } else {
                accessibleSummary
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stage hypnogram")
        .accessibilityValue(accessibilitySummaryText)
    }

    // MARK: - Plot

    private var laneLabels: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SleepHypnogramLayout.lanes, id: \.self) { stage in
                Text(stage.label.uppercased())
                    .font(.bMono(9, .semibold)).tracking(0.5)
                    .foregroundStyle(BaselineColor.textFaint)
                    .frame(height: Metrics.laneHeight)
            }
        }
        .frame(width: Metrics.labelWidth, alignment: .leading)
    }

    private func plot(window: SleepTimelineLayout.Window) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                // Dashed lane gridlines, one per stage row.
                ForEach(Array(SleepHypnogramLayout.lanes.indices), id: \.self) { lane in
                    Path { path in
                        let y = laneCenter(lane)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                    .stroke(BaselineColor.line,
                            style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                // Tracking gaps as faint hatched bands across all lanes (data honesty: a gap must
                // read as untracked time, not as a stage).
                ForEach(Array(SleepTimelineLayout.gapSegments(gaps, in: window).enumerated()),
                        id: \.offset) { _, segment in
                    let frame = SleepTimelineLayout.frame(segment, width: width, height: geo.size.height)
                    Rectangle()
                        .fill(BaselineColor.line.opacity(0.35))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX)
                }
                // Stage bands on their lanes.
                ForEach(Array(SleepHypnogramLayout.bands(intervals, in: window).enumerated()),
                        id: \.offset) { _, band in
                    RoundedRectangle(cornerRadius: Metrics.bandCornerRadius, style: .continuous)
                        .fill(band.stage.color)
                        .frame(width: max(CGFloat(band.widthFraction) * width, Metrics.bandMinWidth),
                               height: Metrics.bandHeight)
                        .offset(x: CGFloat(band.startFraction) * width,
                                y: laneCenter(band.lane) - Metrics.bandHeight / 2)
                }
            }
        }
    }

    private func laneCenter(_ lane: Int) -> CGFloat {
        Metrics.laneHeight * (CGFloat(lane) + 0.5)
    }

    private func axis(window: SleepTimelineLayout.Window) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ForEach(Array(SleepHypnogramLayout.axisTicks(in: window, calendar: calendar).enumerated()),
                    id: \.offset) { _, tick in
                Text(tick.date, format: .dateTime.hour())
                    .font(.bMono(9, .medium))
                    .foregroundStyle(BaselineColor.textFaint)
                    .fixedSize()
                    .alignmentGuide(HorizontalAlignment.leading) { d in d[HorizontalAlignment.center] }
                    .offset(x: CGFloat(tick.fraction) * width)
            }
        }
        .frame(height: 12)
    }

    // MARK: - Legend

    private var legend: some View {
        FlowRow(spacing: 12) {
            ForEach(SleepHypnogramLayout.legendTotals(intervals), id: \.stage) { entry in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(entry.stage.color).frame(width: 9, height: 9)
                    Text("\(entry.stage.label) \(SleepFormat.minutes(entry.minutes))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BaselineColor.textMid)
                }
            }
        }
    }

    // MARK: - Accessible fallback

    private var accessibleSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SleepHypnogramLayout.legendTotals(intervals), id: \.stage) { entry in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(entry.stage.color).frame(width: 10, height: 10)
                    Text("\(entry.stage.label): \(SleepFormat.minutes(entry.minutes))")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textMid)
                }
            }
            if !SleepHypnogramLayout.hasStagedData(intervals) {
                Text("No stage detail from this source.")
                    .font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accessibilitySummaryText: String {
        let parts = SleepHypnogramLayout.legendTotals(intervals)
            .map { "\($0.stage.label) \(SleepFormat.minutes($0.minutes))" }
        return parts.isEmpty ? "No stage data" : parts.joined(separator: ", ")
    }
}

/// Minimal wrapping HStack for the legend so chips reflow under large type instead of clipping
/// (hoisted twin of `SleepTimelineChart`'s private layout).
struct FlowRow: Layout {
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
private func hypnogramPreview() -> some View {
    let night = SleepPreviewFixtures.stagedNight
    return SleepHypnogramChart(intervals: night.primaryEpisode?.intervals ?? [],
                               gaps: night.primaryEpisode?.gaps ?? [],
                               calendar: SleepPreviewFixtures.calendar)
        .padding(20).frame(maxWidth: .infinity).background(BaselineColor.base)
}

#Preview("Hypnogram · dark") { hypnogramPreview().preferredColorScheme(.dark) }
#Preview("Hypnogram · accessibility summary") {
    hypnogramPreview().environment(\.dynamicTypeSize, .accessibility3).preferredColorScheme(.dark)
}
#endif
