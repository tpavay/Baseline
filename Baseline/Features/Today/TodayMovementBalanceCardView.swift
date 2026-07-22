import SwiftUI

struct TodayMovementBalanceCardView: View {
    let movements: [TodayMovementSummary]

    var body: some View {
        BaselineCard {
            VStack(alignment: .leading, spacing: BaselineSpacing.xSmall) {
                Text("MOVEMENT BALANCE")
                    .baselineTypography(.instrumentLabel)
                    .foregroundStyle(BaselineColor.textFaint)
                    .padding(.bottom, BaselineSpacing.xxxSmall)

                ForEach(movements) { movement in
                    TodayMovementRowView(
                        movement: movement,
                        maximum: max(movements.map(\.sets).max() ?? 0, 1)
                    )
                }
            }
        }
    }
}

private struct TodayMovementRowView: View {
    let movement: TodayMovementSummary
    let maximum: Int

    var body: some View {
        HStack(spacing: BaselineSpacing.tile) {
            Text(movement.name)
                .font(.caption)
                .foregroundStyle(BaselineColor.textMid)
                .frame(width: BaselineSize.movementLabelWidth, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(BaselineColor.line)
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: BaselineSize.movementBarHeight)
            .accessibilityHidden(true)

            Text("\(movement.sets) sets")
                .baselineTypography(.instrumentMeta)
                .foregroundStyle(movement.tint == .caution ? BaselineColor.zoneAmber : BaselineColor.textFaint)
                .frame(width: BaselineSize.movementValueWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(movement.name), \(movement.sets) sets")
    }

    private var tint: Color {
        movement.tint == .caution ? BaselineColor.zoneAmber : BaselineColor.accent
    }

    private var progress: Double {
        min(max(Double(movement.sets) / Double(maximum), 0), 1)
    }
}
