import SwiftUI

/// Shared selectable row for every taxonomy picker.
struct TaxonomyPickerRow: View {
    let icon: Image
    let title: String
    var subtitle: String?
    var isSelected: Bool
    var disabledReason: String?
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var isDisabled: Bool { disabledReason != nil }

    private var accessibilityValue: String {
        [
            subtitle,
            isSelected ? "Selected" : nil,
            isDisabled ? "Unavailable" : nil
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: BaselineSpacing.medium) {
                icon
                    .font(.system(size: BaselineSize.iconGlyph))
                    .foregroundStyle(BaselineColor.textMid)
                    .frame(width: BaselineSize.icon, height: BaselineSize.icon)
                    .background {
                        RoundedRectangle(cornerRadius: BaselineRadius.icon)
                            .fill(BaselineColor.surface)
                    }

                VStack(alignment: .leading, spacing: BaselineSpacing.xxxSmall) {
                    Text(title)
                        .baselineTypography(.rowTitle)
                        .foregroundStyle(isDisabled ? BaselineColor.textFaint : BaselineColor.textHi)

                    if let subtitle {
                        Text(subtitle)
                            .baselineTypography(.rowSubtitle)
                            .foregroundStyle(BaselineColor.textFaint)
                    }

                    if let disabledReason, disabledReason != subtitle {
                        Text(disabledReason)
                            .baselineTypography(.rowSubtitle)
                            .foregroundStyle(BaselineColor.textMid)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark")
                    .font(.system(size: BaselineSize.selectionGlyph, weight: .semibold))
                    .foregroundStyle(BaselineColor.accent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, BaselineSpacing.xxSmall)
            .padding(.vertical, BaselineSpacing.small)
            .frame(maxWidth: .infinity, minHeight: BaselineSize.pickerRowMinimumHeight, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Hairline(color: BaselineColor.line.opacity(0.45))
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? disabledOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(disabledReason ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var disabledOpacity: Double {
        colorSchemeContrast == .increased ? 0.78 : 0.58
    }
}

#if DEBUG
#Preview("Picker rows") {
    VStack(spacing: 0) {
        TaxonomyPickerRow(
            icon: Image(systemName: "figure.strengthtraining.traditional"),
            title: "Barbell",
            subtitle: nil,
            isSelected: false,
            disabledReason: nil,
            action: {}
        )
        TaxonomyPickerRow(
            icon: Image(systemName: "figure.strengthtraining.functional"),
            title: "Lats",
            subtitle: "back",
            isSelected: true,
            disabledReason: nil,
            action: {}
        )
        TaxonomyPickerRow(
            icon: Image(systemName: "figure.strengthtraining.functional"),
            title: "Lats",
            subtitle: "back",
            isSelected: false,
            disabledReason: "Already selected as the primary muscle",
            action: {}
        )
    }
    .padding(.horizontal, BaselineSpacing.large)
    .background(BaselineColor.base)
    .preferredColorScheme(.dark)
}
#endif
