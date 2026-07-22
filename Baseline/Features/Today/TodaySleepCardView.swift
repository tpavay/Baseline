import SwiftUI

struct TodaySleepCardView: View {
    let model: TodaySleepCardModel
    let isSolo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SLEEP")
                .baselineTypography(.instrumentLabel)
                .foregroundStyle(BaselineColor.textFaint)

            Group {
                if isSolo {
                    HStack(spacing: BaselineSpacing.large) {
                        ring
                        readout
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
        .accessibilityLabel("Sleep score \(model.score), \(model.rating), \(model.durationText)")
    }

    private var ring: some View {
        SegmentedRing(
            segments: model.segments.map {
                .init(weight: $0.weight, progress: $0.progress, color: color(for: $0.colorRole))
            },
            diameter: BaselineSize.sleepRing,
            lineWidth: BaselineSize.sleepRingLineWidth,
            gapDegrees: BaselineSize.sleepRingGapDegrees,
            accessibilitySummary: "Sleep score \(model.score)"
        ) {
            Text("\(model.score)")
                .baselineTypography(.instrumentValue)
                .foregroundStyle(BaselineColor.textMid)
        }
    }

    private var readout: some View {
        VStack(alignment: isSolo ? .leading : .center, spacing: BaselineSpacing.xxSmall) {
            Text(model.rating)
                .font(.title2.bold())
                .foregroundStyle(ratingColor)
            Text(model.durationText.uppercased())
                .baselineTypography(.instrumentMeta)
                .foregroundStyle(BaselineColor.zoneGreen)
                .multilineTextAlignment(isSolo ? .leading : .center)
        }
    }

    private var ratingColor: Color {
        switch model.score {
        case ..<40: BaselineColor.zoneRed
        case 40..<60: BaselineColor.zoneAmber
        case 60..<75: BaselineColor.accent
        default: BaselineColor.zoneGreen
        }
    }

    private func color(for role: TodaySleepCardModel.ColorRole) -> Color {
        switch role {
        case .duration: BaselineColor.zoneBlue
        case .consistency: BaselineColor.accent
        case .interruptions: BaselineColor.zoneGreen
        }
    }
}
