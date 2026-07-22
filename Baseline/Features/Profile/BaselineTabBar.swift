import SwiftUI

struct BaselineTabBar: View {
    @Binding var selection: MainTab

    var body: some View {
        HStack(spacing: BaselineSpacing.xxSmall) {
            tabButton(.today)
            tabButton(.plan)
            tabButton(.profile)
        }
        .padding(BaselineSpacing.compact)
        .frame(height: BaselineSize.tabBarHeight)
        .background {
            Capsule()
                .fill(BaselineColor.surface.opacity(0.97))
                .overlay {
                    Capsule()
                        .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
                }
        }
        .padding(.horizontal, BaselineSpacing.screen + BaselineSpacing.large)
        .padding(.bottom, BaselineSpacing.xSmall)
    }

    private func tabButton(_ tab: MainTab) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: BaselineSpacing.xxxSmall) {
                Image(systemName: tab.systemImage)
                    .font(.caption.weight(.semibold))
                Text(tab.title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(selection == tab ? BaselineColor.accent : BaselineColor.textMid)
            .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget)
            .background {
                if selection == tab {
                    Capsule()
                        .fill(BaselineColor.accent.opacity(0.12))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}
