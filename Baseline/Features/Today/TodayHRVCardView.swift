import SwiftUI

struct TodayHRVCardView: View {
    let model: TodayHRVCardModel
    let isSolo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HRV")
                .baselineTypography(.instrumentLabel)
                .foregroundStyle(BaselineColor.textFaint)

            HStack(alignment: .firstTextBaseline, spacing: isSolo ? BaselineSpacing.medium : BaselineSpacing.xxSmall) {
                HStack(alignment: .firstTextBaseline, spacing: BaselineSpacing.xxSmall) {
                    Text("\(model.value)")
                        .font(.system(.title, design: .monospaced, weight: .bold))
                        .foregroundStyle(BaselineColor.textHi)
                    Text("MS")
                        .baselineTypography(.instrumentLabel)
                        .foregroundStyle(BaselineColor.textFaint)
                }

                if isSolo {
                    comparison
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isSolo ? .leading : .center)

            if !isSolo {
                comparison.frame(maxWidth: .infinity)
            }
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
        .accessibilityLabel("HRV \(model.value) milliseconds, \(model.comparisonText)")
    }

    private var comparison: some View {
        Text(model.comparisonText.uppercased())
            .baselineTypography(.instrumentMeta)
            .foregroundStyle(model.isPositive ? BaselineColor.zoneGreen : BaselineColor.zoneAmber)
            .multilineTextAlignment(isSolo ? .leading : .center)
    }
}
