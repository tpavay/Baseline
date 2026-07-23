import SwiftUI

extension SegmentedRingLayout {
    /// Radial-height fill geometry for one segment of a `RadialFillSegmentedRing`: the fill keeps
    /// the segment's **full angular sweep** and expresses progress as stroke *thickness* instead of
    /// arc length. The fill shares the track's inner edge and grows outward - full track thickness
    /// at progress 1, proportionally thinner below it (the approved sleep-ring behavior: "points
    /// fill by radial height growing outward", explicitly not an arc-length fill).
    struct RadialFill: Equatable {
        /// Stroke width of the fill arc.
        let thickness: Double
        /// Fill-arc center radius minus track center radius (≤ 0: the fill hugs the inner edge).
        let centerRadiusOffset: Double
    }

    static func radialFill(progress: Double, lineWidth: Double) -> RadialFill {
        let clamped = progress.isFinite ? min(max(progress, 0), 1) : 0
        let width = max(lineWidth, 0)
        let thickness = width * clamped
        return RadialFill(thickness: thickness, centerRadiusOffset: -(width - thickness) / 2)
    }
}

/// A Dynamic Type-aware segmented score ring whose segments are weighted arcs (full sweep, rounded
/// caps, dim same-hue tracks) and whose progress renders as **radial fill height**: each fill arc
/// spans its whole segment and thickens outward from the track's inner edge as the component earns
/// points. Companion to `SegmentedRing`, which renders progress as arc length instead.
struct RadialFillSegmentedRing<CenterContent: View>: View {
    struct Segment {
        let weight: Double
        let progress: Double
        let color: Color

        init(weight: Double, progress: Double, color: Color) {
            self.weight = weight
            self.progress = progress
            self.color = color
        }
    }

    private let segments: [Segment]
    private let gapDegrees: Double
    private let trackOpacity: Double
    private let accessibilitySummary: String
    @ViewBuilder private let centerContent: CenterContent

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var lineWidth: CGFloat = 0

    init(
        segments: [Segment],
        diameter: CGFloat,
        lineWidth: CGFloat,
        gapDegrees: Double,
        trackOpacity: Double = 0.16,
        accessibilitySummary: String,
        @ViewBuilder centerContent: () -> CenterContent
    ) {
        self.segments = segments
        self.gapDegrees = gapDegrees
        self.trackOpacity = trackOpacity
        self.accessibilitySummary = accessibilitySummary
        self.centerContent = centerContent()
        _diameter = ScaledMetric(wrappedValue: diameter, relativeTo: .body)
        _lineWidth = ScaledMetric(wrappedValue: lineWidth, relativeTo: .body)
    }

    var body: some View {
        let layout = SegmentedRingLayout(
            weights: segments.map(\.weight),
            progresses: segments.map(\.progress),
            gapDegrees: gapDegrees
        )

        ZStack {
            Canvas { context, size in
                let safeLineWidth = min(lineWidth, min(size.width, size.height) / 2)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let trackRadius = max((min(size.width, size.height) - safeLineWidth) / 2, 0)

                for arc in layout.segments {
                    let segment = segments[arc.index]
                    var track = Path()
                    track.addArc(
                        center: center,
                        radius: trackRadius,
                        startAngle: .degrees(arc.startAngle),
                        endAngle: .degrees(arc.endAngle),
                        clockwise: false
                    )
                    context.stroke(
                        track,
                        with: .color(segment.color.opacity(trackOpacity)),
                        style: StrokeStyle(lineWidth: safeLineWidth, lineCap: .round)
                    )

                    let fill = SegmentedRingLayout.radialFill(
                        progress: segment.progress, lineWidth: safeLineWidth)
                    guard fill.thickness > 0 else { continue }
                    var progress = Path()
                    progress.addArc(
                        center: center,
                        radius: max(trackRadius + fill.centerRadiusOffset, 0),
                        startAngle: .degrees(arc.startAngle),
                        endAngle: .degrees(arc.endAngle),
                        clockwise: false
                    )
                    context.stroke(
                        progress,
                        with: .color(segment.color),
                        style: StrokeStyle(lineWidth: fill.thickness, lineCap: .round)
                    )
                }
            }
            .accessibilityHidden(true)

            centerContent
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
}

#if DEBUG
#Preview("Sleep score ring · radial fill") {
    VStack(spacing: BaselineSpacing.screen) {
        RadialFillSegmentedRing(
            segments: [
                .init(weight: 50, progress: 1.0, color: BaselineColor.zoneBlue),
                .init(weight: 30, progress: 16 / 30, color: BaselineColor.zoneGreen),
                .init(weight: 20, progress: 11 / 20, color: BaselineColor.zoneRed)
            ],
            diameter: BaselineSize.sleepRing,
            lineWidth: BaselineSize.sleepRingLineWidth,
            gapDegrees: BaselineSize.sleepRingGapDegrees,
            accessibilitySummary: "Sleep score 78"
        ) {
            Text("78")
                .font(.system(.title2, design: .default, weight: .bold))
                .foregroundStyle(BaselineColor.textHi)
        }

        RadialFillSegmentedRing(
            segments: [
                .init(weight: 50, progress: 0.2, color: BaselineColor.zoneBlue),
                .init(weight: 30, progress: 0.9, color: BaselineColor.zoneGreen),
                .init(weight: 20, progress: 0, color: BaselineColor.zoneRed)
            ],
            diameter: BaselineSize.sleepRing,
            lineWidth: BaselineSize.sleepRingLineWidth,
            gapDegrees: BaselineSize.sleepRingGapDegrees,
            accessibilitySummary: "Sleep score 41"
        ) {
            Text("41")
                .font(.system(.title2, design: .default, weight: .bold))
                .foregroundStyle(BaselineColor.textHi)
        }
    }
    .padding(BaselineSpacing.screen)
    .background(BaselineColor.base)
    .preferredColorScheme(.dark)
}
#endif
