import SwiftUI

struct TodayMuscleMapFigureView: View {
    let label: String
    let baseAsset: String
    let layers: [TodayMuscleMapLayer]

    var body: some View {
        VStack(spacing: BaselineSpacing.xxSmall) {
            Text(label)
                .baselineTypography(.instrumentLabel)
                .foregroundStyle(BaselineColor.textFaint)

            ZStack {
                Image(baseAsset)
                    .resizable()
                    .scaledToFit()

                ForEach(layers) { layer in
                    Image(layer.assetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(BaselineColor.accent.opacity(0.22 + 0.68 * layer.intensity))
                }
            }
            .frame(maxWidth: BaselineSize.weeklyFigure)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized) muscle distribution")
        .accessibilityValue(layers.isEmpty ? "No completed work this week" : "Heat map of completed work")
    }
}
