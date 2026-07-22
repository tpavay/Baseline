import SwiftUI

struct WorkoutDetailActionSheet: View {
    let onEdit: () -> Void
    let onSaveTemplate: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            actionButton("Edit workout", systemImage: "pencil", action: onEdit)
            Hairline(color: BaselineColor.line.opacity(0.7))
            actionButton("Save as template", systemImage: "doc.on.doc", action: onSaveTemplate)
            Hairline(color: BaselineColor.line.opacity(0.7))
            actionButton("Delete workout", systemImage: "xmark", role: .destructive, action: onDelete)

            Button("Cancel", action: onCancel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaselineColor.textMid)
                .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget)
                .background {
                    RoundedRectangle(cornerRadius: BaselineRadius.row)
                        .fill(BaselineColor.surface.opacity(0.55))
                        .overlay {
                            RoundedRectangle(cornerRadius: BaselineRadius.row)
                                .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
                        }
                }
                .padding(.top, BaselineSpacing.small)
        }
        .padding(.horizontal, BaselineSpacing.large)
        .padding(.bottom, BaselineSpacing.xLarge)
        .background(BaselineColor.surface.ignoresSafeArea())
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .foregroundStyle(role == .destructive ? BaselineColor.zoneRed : BaselineColor.textHi)
                .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
