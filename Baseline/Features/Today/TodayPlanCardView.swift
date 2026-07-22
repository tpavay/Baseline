import SwiftUI

struct TodayPlanCardView: View {
    let model: TodayPlanCardModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BaselineCard(variant: .plan) {
                HStack(spacing: BaselineSpacing.small) {
                    VStack(alignment: .leading, spacing: BaselineSpacing.xxSmall) {
                        Text("TODAY'S PLAN")
                            .baselineTypography(.instrumentLabel)
                            .foregroundStyle(BaselineColor.textFaint)
                            .padding(.bottom, BaselineSpacing.compact)
                        Text(model.title)
                            .baselineTypography(.navigationTitle)
                            .foregroundStyle(BaselineColor.textHi)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.detail)
                            .baselineTypography(.proseSmall)
                            .foregroundStyle(BaselineColor.textMid)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BaselineColor.textFaint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Today's plan, \(model.title), \(model.detail)")
        .accessibilityHint("Opens the plan")
    }
}
