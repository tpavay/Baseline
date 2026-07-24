import SwiftUI

/// Baseline wordmark burned into exported workout cards.
struct BaselineWordmark: View {
    var size: CGFloat = 14
    var color: Color = BaselineColor.textHi

    var body: some View {
        HStack(spacing: size * 0.42) {
            Image("BaselineIconNoBackground")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size * 1.55, height: size * 1.55)
                .accessibilityHidden(true)

            Text("BASELINE")
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .tracking(size * 0.16)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Baseline")
    }
}
