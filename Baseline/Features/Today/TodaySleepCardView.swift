import SwiftUI

/// The Today home sleep card (approved redesign, screen 1): band word + time asleep on the left,
/// the segmented score ring on the right. The ring's three arcs are weighted by the component
/// ceilings (Duration 50 / Bedtime 30 / Interruptions 20) and fill by radial height as points are
/// earned (`RadialFillSegmentedRing`). In the two-up grid next to the HRV card it stacks the ring
/// above the readout instead.
struct TodaySleepCardView: View {
    let model: TodaySleepCardModel
    let isSolo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SLEEP")
                    .baselineTypography(.instrumentLabel)
                    .foregroundStyle(BaselineColor.textFaint)
                if isSolo {
                    Spacer()
                    HStack(spacing: 3) {
                        Text("Today")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(BaselineColor.textMid)
                }
            }

            Group {
                if isSolo {
                    HStack(spacing: BaselineSpacing.large) {
                        readout
                        Spacer(minLength: BaselineSpacing.small)
                        ring
                    }
                } else {
                    VStack(spacing: BaselineSpacing.tile) {
                        ring
                        readout
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isSolo ? .leading : .center)
        }
        .padding(.horizontal, isSolo ? BaselineSpacing.cardContent : BaselineSpacing.medium)
        .padding(.vertical, BaselineSpacing.medium)
        .frame(
            maxWidth: .infinity,
            minHeight: isSolo ? BaselineSize.readingCardSoloHeight : BaselineSize.readingCardFullHeight,
            alignment: .leading
        )
        .background {
            RoundedRectangle(cornerRadius: BaselineRadius.control)
                .fill(BaselineColor.surface.opacity(0.5))
                .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep score \(model.score), \(model.band), \(model.durationText)")
    }

    private var ring: some View {
        RadialFillSegmentedRing(
            segments: model.segments.map {
                .init(weight: $0.weight, progress: $0.progress, color: $0.kind.color)
            },
            diameter: BaselineSize.sleepRing,
            lineWidth: BaselineSize.sleepRingLineWidth,
            gapDegrees: BaselineSize.sleepRingGapDegrees,
            accessibilitySummary: "Sleep score \(model.score)"
        ) {
            Text("\(model.score)")
                .font(.system(.title2, design: .default, weight: .bold))
                .foregroundStyle(BaselineColor.textHi)
        }
    }

    private var readout: some View {
        VStack(alignment: isSolo ? .leading : .center, spacing: BaselineSpacing.xxSmall) {
            Text(model.band)
                .font(.title2.bold())
                .foregroundStyle(BaselineColor.textHi)
            Text(model.durationText)
                .font(.system(size: 13))
                .foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(isSolo ? .leading : .center)
        }
    }
}

#if DEBUG
#Preview("Today sleep card · solo + grid") {
    let model = TodaySleepCardModel(
        score: 78,
        band: "OK",
        durationText: "8h 32m asleep",
        segments: [
            .init(kind: .duration, weight: 50, progress: 1.0),
            .init(kind: .bedtimeConsistency, weight: 30, progress: 16 / 30),
            .init(kind: .interruptions, weight: 20, progress: 11 / 20),
        ]
    )
    return VStack(spacing: BaselineSpacing.tile) {
        TodaySleepCardView(model: model, isSolo: true)
        HStack(spacing: BaselineSpacing.tile) {
            TodaySleepCardView(model: model, isSolo: false)
            TodaySleepCardView(model: model, isSolo: false)
        }
    }
    .padding(BaselineSpacing.screen)
    .background(BaselineColor.base)
    .preferredColorScheme(.dark)
}
#endif
