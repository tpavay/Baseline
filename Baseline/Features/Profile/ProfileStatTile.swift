import SwiftUI

struct ProfileStatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: BaselineSpacing.xxxSmall) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(BaselineColor.textHi)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.caption2.weight(.semibold).monospaced())
                .tracking(0.8)
                .foregroundStyle(BaselineColor.textFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BaselineSpacing.small)
        .background {
            RoundedRectangle(cornerRadius: BaselineRadius.control)
                .fill(BaselineColor.surface.opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: BaselineRadius.control)
                        .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
                }
        }
        .accessibilityElement(children: .combine)
    }
}
