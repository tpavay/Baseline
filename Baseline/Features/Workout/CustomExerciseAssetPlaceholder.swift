import SwiftUI

struct CustomExerciseAssetPlaceholder: View {
    var body: some View {
        VStack(spacing: BaselineSpacing.xSmall) {
            Image(systemName: "camera")
                .font(.system(size: BaselineSize.icon, weight: .regular))
                .foregroundStyle(BaselineColor.textFaint)
                .frame(width: BaselineSize.exerciseAsset, height: BaselineSize.exerciseAsset)
                .background {
                    Circle()
                        .stroke(
                            BaselineColor.line,
                            style: StrokeStyle(lineWidth: BaselineSize.hairline, dash: [3, 3])
                        )
                }

            Text("Add image (optional)")
                .baselineTypography(.rowSubtitle)
                .foregroundStyle(BaselineColor.accent)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exercise image, optional")
    }
}
