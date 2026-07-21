import SwiftUI

/// Pure circular geometry shared by every segmented ring renderer.
struct SegmentedRingLayout: Equatable {
    struct Segment: Equatable {
        let index: Int
        let startAngle: Double
        let endAngle: Double
        let progressEndAngle: Double

        var sweep: Double { endAngle - startAngle }
    }

    let segments: [Segment]

    init(
        weights: [Double],
        progresses: [Double],
        gapDegrees: Double,
        startAngle: Double = -90
    ) {
        let active = weights.enumerated().compactMap { index, weight -> (Int, Double, Double)? in
            guard weight.isFinite, weight > 0 else { return nil }
            let rawProgress = progresses.indices.contains(index) ? progresses[index] : 0
            let progress = rawProgress.isFinite ? min(max(rawProgress, 0), 1) : 0
            return (index, weight, progress)
        }
        let totalWeight = active.reduce(0) { $0 + $1.1 }

        guard active.isEmpty == false, totalWeight > 0 else {
            segments = []
            return
        }

        let requestedGap = gapDegrees.isFinite ? max(gapDegrees, 0) : 0
        let maximumGap = active.count > 1 ? 359 / Double(active.count) : 0
        let gap = min(requestedGap, maximumGap)
        let totalGap = active.count > 1 ? gap * Double(active.count) : 0
        let usableSweep = 360 - totalGap
        var cursor = startAngle.isFinite ? startAngle : -90

        segments = active.map { index, weight, progress in
            let sweep = usableSweep * weight / totalWeight
            let segment = Segment(
                index: index,
                startAngle: cursor,
                endAngle: cursor + sweep,
                progressEndAngle: cursor + sweep * progress
            )
            cursor += sweep + gap
            return segment
        }
    }
}

/// A Dynamic Type-aware circular renderer for weighted, independently progressed segments.
struct SegmentedRing<CenterContent: View>: View {
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
    private let trackColor: Color
    private let accessibilitySummary: String
    @ViewBuilder private let centerContent: CenterContent

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var lineWidth: CGFloat = 0

    init(
        segments: [Segment],
        diameter: CGFloat,
        lineWidth: CGFloat,
        gapDegrees: Double,
        trackColor: Color = BaselineColor.line,
        accessibilitySummary: String,
        @ViewBuilder centerContent: () -> CenterContent
    ) {
        self.segments = segments
        self.gapDegrees = gapDegrees
        self.trackColor = trackColor
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
                let radius = max((min(size.width, size.height) - safeLineWidth) / 2, 0)
                let stroke = StrokeStyle(lineWidth: safeLineWidth, lineCap: .butt)

                for arc in layout.segments {
                    var track = Path()
                    track.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(arc.startAngle),
                        endAngle: .degrees(arc.endAngle),
                        clockwise: false
                    )
                    context.stroke(track, with: .color(trackColor), style: stroke)

                    guard arc.progressEndAngle > arc.startAngle else { continue }
                    var progress = Path()
                    progress.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(arc.startAngle),
                        endAngle: .degrees(arc.progressEndAngle),
                        clockwise: false
                    )
                    context.stroke(progress, with: .color(segments[arc.index].color), style: stroke)
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
#Preview("Sleep and heart-rate rings") {
    VStack(spacing: BaselineSpacing.screen) {
        SegmentedRing(
            segments: [
                .init(weight: 0.4, progress: 0.78, color: BaselineColor.zoneBlue),
                .init(weight: 0.35, progress: 0.62, color: BaselineColor.accent),
                .init(weight: 0.25, progress: 0.73, color: BaselineColor.zoneGreen)
            ],
            diameter: 84,
            lineWidth: 5,
            gapDegrees: 8,
            accessibilitySummary: "Sleep score 82. Duration, bedtime, and interruptions are available."
        ) {
            Text("82")
                .baselineTypography(.instrumentValue)
                .foregroundStyle(BaselineColor.textMid)
        }

        SegmentedRing(
            segments: [
                .init(weight: 34, progress: 1, color: BaselineColor.zoneBlue),
                .init(weight: 41, progress: 1, color: BaselineColor.zoneGreen),
                .init(weight: 38, progress: 1, color: BaselineColor.accent),
                .init(weight: 22, progress: 1, color: BaselineColor.zoneAmber),
                .init(weight: 8, progress: 1, color: BaselineColor.zoneRed)
            ],
            diameter: 118,
            lineWidth: 11,
            gapDegrees: 1.2,
            accessibilitySummary: "Time in heart-rate zones. Zone 2 has the most time."
        ) {
            VStack(spacing: BaselineSpacing.xxSmall) {
                Text("Z2")
                    .baselineTypography(.instrumentValue)
                    .foregroundStyle(BaselineColor.zoneGreen)
                Text("MOST TIME")
                    .baselineTypography(.instrumentLabel)
                    .foregroundStyle(BaselineColor.textFaint)
            }
        }
    }
    .padding(BaselineSpacing.screen)
    .background(BaselineColor.base)
    .preferredColorScheme(.dark)
}
#endif
