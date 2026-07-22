import SwiftUI

struct CustomExerciseClassificationRow: View {
    let label: String
    let isRequired: Bool
    let value: String
    let usesDefault: Bool
    let action: () -> Void

    init(
        label: String,
        isRequired: Bool = false,
        value: String,
        usesDefault: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.isRequired = isRequired
        self.value = value
        self.usesDefault = usesDefault
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: BaselineSpacing.small) {
                VStack(alignment: .leading, spacing: BaselineSpacing.xxxSmall) {
                    HStack(spacing: BaselineSpacing.xxSmall) {
                        Text(label)
                            .baselineTypography(.rowTitle)
                            .foregroundStyle(BaselineColor.textHi)

                        if isRequired {
                            Text("*")
                                .baselineTypography(.rowValue)
                                .foregroundStyle(BaselineColor.accent)
                        }
                    }

                    Text(displayValue)
                        .baselineTypography(.rowValue)
                        .foregroundStyle(valueColor)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: BaselineSize.iconGlyph, weight: .semibold))
                    .foregroundStyle(BaselineColor.textFaint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, BaselineSpacing.xxSmall)
            .padding(.vertical, BaselineSpacing.formRowVertical)
            .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Hairline(color: BaselineColor.line)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(displayValue)
        .accessibilityHint("Opens the \(label.lowercased()) picker")
    }

    private var displayValue: String {
        if value.isEmpty {
            return isRequired ? "Select" : "Select (optional)"
        }
        return usesDefault ? "\(value) · default" : value
    }

    private var valueColor: Color {
        if value.isEmpty {
            return isRequired ? BaselineColor.accent : BaselineColor.textFaint
        }
        return usesDefault ? BaselineColor.textFaint : BaselineColor.textHi
    }
}
