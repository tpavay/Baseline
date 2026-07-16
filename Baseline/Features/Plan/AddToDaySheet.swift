import SwiftUI

/// The path chosen from the per-day "Add to <day>" sheet. The caller runs the follow-on presentation.
enum AddToDayOption: Equatable {
    case buildWithBaseline
    case emptySession
    case template(UUID)
    case importImage
}

/// The per-day "Add to <day>" action sheet — the single entry point for adding training to a Plan day,
/// replacing the old inline menu. The conversational hero (Build with Baseline) sits above three
/// direct-control peers (empty session, template, image import), matching the principle that conversation
/// and direct controls are complementary. Selecting a row reports the choice and lets the caller dismiss.
struct AddToDaySheet: View {
    let title: String
    let templates: [WorkoutTemplate]
    let onSelect: (AddToDayOption) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(BaselineColor.textHi)
                        .padding(.top, 6)
                    Text("Describe it, start fresh, reuse a template, or import a written workout.")
                        .font(.system(size: 15))
                        .foregroundStyle(BaselineColor.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)

                    groupLabel("FASTEST - LET BASELINE BUILD IT").padding(.top, 22)
                    Button { onSelect(.buildWithBaseline) } label: {
                        optionRow(icon: "sparkles",
                                  title: "Build with Baseline",
                                  subtitle: "Describe a workout or a whole plan - get an editable draft.",
                                  hero: true)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)

                    groupLabel("BUILD IT YOURSELF").padding(.top, 22)
                    VStack(spacing: 10) {
                        Button { onSelect(.emptySession) } label: {
                            optionRow(icon: "plus",
                                      title: "Start an empty session",
                                      subtitle: "Begin training now and log as you go - no plan needed.")
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            templatePicker
                        } label: {
                            optionRow(icon: "square.stack",
                                      title: "From a template",
                                      subtitle: "Choose a saved template.")
                        }
                        .buttonStyle(.plain)

                        Button { onSelect(.importImage) } label: {
                            optionRow(icon: "doc.viewfinder",
                                      title: "Import from image",
                                      subtitle: "Photograph or upload a written workout.")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .background(BaselineColor.base)
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(BaselineColor.textHi)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .padding(.vertical, 12)
                .background(BaselineColor.base)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.height(600), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(BaselineColor.base)
    }

    // MARK: Template picker (pushed)

    private var templatePicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if templates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No templates yet")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(BaselineColor.textHi)
                        Text("Save a workout as a template and it will show up here to reuse.")
                            .font(.system(size: 14))
                            .foregroundStyle(BaselineColor.textMid)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface.opacity(0.6)))
                } else {
                    ForEach(templates) { template in
                        Button { onSelect(.template(template.id)) } label: { templateRow(template) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .background(BaselineColor.base)
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func templateRow(_ template: WorkoutTemplate) -> some View {
        HStack(spacing: 12) {
            Text(template.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BaselineColor.textHi)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BaselineColor.textFaint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(BaselineColor.surface.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BaselineColor.line, lineWidth: 1))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Building blocks

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(BaselineColor.textFaint)
    }

    private func optionRow(icon: String, title: String, subtitle: String, hero: Bool = false) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(hero ? BaselineColor.accent.opacity(0.20) : BaselineColor.amethyst)
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(BaselineColor.accent)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(BaselineColor.textHi)
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(BaselineColor.textMid)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BaselineColor.textFaint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(hero ? BaselineColor.amethyst.opacity(0.55) : BaselineColor.surface.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(hero ? BaselineColor.accent.opacity(0.55) : BaselineColor.line, lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
