import SwiftUI

struct ProfileSegmentedControl: View {
    @Binding var selection: ProfileSection

    var body: some View {
        HStack(spacing: BaselineSpacing.xxxSmall) {
            ForEach(ProfileSection.allCases) { section in
                Button(section.rawValue) {
                    selection = section
                }
                .font(.subheadline.weight(selection == section ? .semibold : .regular))
                .foregroundStyle(selection == section ? BaselineColor.textHi : BaselineColor.textMid)
                .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget)
                .background {
                    if selection == section {
                        RoundedRectangle(cornerRadius: BaselineRadius.icon)
                            .fill(BaselineColor.accent.opacity(0.16))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .padding(BaselineSpacing.xxxSmall)
        .background {
            RoundedRectangle(cornerRadius: BaselineRadius.control + BaselineSize.hairline)
                .fill(BaselineColor.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: BaselineRadius.control + BaselineSize.hairline)
                        .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
                }
        }
    }
}
