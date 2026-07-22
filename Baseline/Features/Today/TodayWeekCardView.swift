import SwiftUI

struct TodayWeekCardView: View {
    let summary: TodayWeeklySummary

    var body: some View {
        BaselineCard {
            VStack(alignment: .leading, spacing: BaselineSpacing.medium) {
                Text("THIS WEEK")
                    .baselineTypography(.instrumentLabel)
                    .foregroundStyle(BaselineColor.textFaint)

                HStack(spacing: BaselineSpacing.xSmall) {
                    TodayWeekStatView(value: "\(summary.sessionCount)", label: "SESSIONS")
                    TodayWeekStatView(value: summary.trainingDurationText, label: "TRAINING")
                    TodayWeekStatView(
                        value: summary.cardioDurationText,
                        label: "CARDIO",
                        tint: BaselineColor.zoneBlue
                    )
                }

                HStack(alignment: .top, spacing: BaselineSpacing.compact) {
                    TodayMuscleMapFigureView(
                        label: "FRONT",
                        baseAsset: "MuscleMapFrontBase",
                        layers: summary.frontMuscles
                    )
                    TodayMuscleMapFigureView(
                        label: "BACK",
                        baseAsset: "MuscleMapBackBase",
                        layers: summary.backMuscles
                    )
                }

                HStack(spacing: BaselineSpacing.xSmall) {
                    Text("less")
                    LinearGradient(
                        colors: [BaselineColor.accent.opacity(0.18), BaselineColor.accent],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: BaselineSize.heatLegendWidth, height: BaselineSize.heatLegendHeight)
                    .clipShape(.capsule)
                    .accessibilityHidden(true)
                    Text("more this week")
                }
                .font(.caption)
                .foregroundStyle(BaselineColor.textFaint)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct TodayWeekStatView: View {
    let value: String
    let label: String
    var tint: Color = BaselineColor.textHi

    var body: some View {
        VStack(spacing: BaselineSpacing.xxSmall) {
            Text(value)
                .baselineTypography(.instrumentValue)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .baselineTypography(.instrumentLabel)
                .foregroundStyle(tint == BaselineColor.textHi ? BaselineColor.textFaint : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(BaselineSpacing.small)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: BaselineRadius.control)
                .fill(BaselineColor.surface.opacity(0.5))
                .stroke(
                    tint == BaselineColor.textHi ? BaselineColor.line : tint.opacity(0.35),
                    lineWidth: BaselineSize.hairline
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized), \(value)")
    }
}
