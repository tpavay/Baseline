import SwiftUI
import UIKit

/// The path chosen from the per-day "Add to <day>" sheet. The caller runs the follow-on action.
enum AddToDayOption: Equatable {
    case buildWithBaseline
    case restDay
    case startEmptyWorkout
    case template(UUID)
    case importImage(WorkoutImportImageSource)
}

/// The per-day "Add to <day>" action sheet — the single entry point for deciding a Plan day
/// (approved redesign: `baseline-sleep-addworkout-redesign.html`, screen 3). The conversational
/// hero sits on top, a one-tap "Make it a rest day" is its prominent peer, and the direct-control
/// paths (start now, template, image import) follow as compact one-line rows. Selecting an option
/// reports the choice and lets the caller dismiss.
struct AddToDaySheet: View {
    let date: Date
    let templates: [WorkoutTemplate]
    /// Injectable so tests can exercise both dialog shapes; the simulator has no camera.
    var cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
    let onSelect: (AddToDayOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showImportSourceDialog = false

    /// The image sources offered for "Import from image". Pure so the routing is testable:
    /// no camera means no dialog — the row goes straight to the photo library.
    static func importSources(cameraAvailable: Bool) -> [WorkoutImportImageSource] {
        cameraAvailable ? [.camera, .photoLibrary] : [.photoLibrary]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.title(for: date))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(BaselineColor.textHi)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    Text("Add training, or mark it a rest day.")
                        .font(.system(size: 13))
                        .foregroundStyle(BaselineColor.textMid)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)

                    Button { onSelect(.buildWithBaseline) } label: {
                        optionRow(icon: "sparkles",
                                  title: "Build with Baseline",
                                  subtitle: "Describe it - get an editable draft.",
                                  style: .hero)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 20)

                    Button { onSelect(.restDay) } label: {
                        optionRow(icon: "moon.zzz.fill",
                                  title: "Make it a rest day",
                                  subtitle: "One tap - no workout scheduled.",
                                  style: .rest,
                                  showsChevron: false)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                    .accessibilityHint("Marks this day as a rest day and closes the sheet")

                    groupLabel("OR BUILD IT YOURSELF").padding(.top, 20)
                    VStack(spacing: 10) {
                        Button { onSelect(.startEmptyWorkout) } label: {
                            optionRow(icon: "play.fill",
                                      title: "Start an empty workout",
                                      subtitle: "Begin now - timer starts; add exercises as you go.")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens live logging immediately with the timer running")

                        NavigationLink {
                            templatePicker
                        } label: {
                            optionRow(icon: "square.stack", title: "From a template")
                        }
                        .buttonStyle(.plain)

                        Button(action: chooseImportSource) {
                            optionRow(icon: "camera",
                                      title: "Import from image",
                                      subtitle: "Take a photo or pick from your library.")
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
            .confirmationDialog("Import from image", isPresented: $showImportSourceDialog) {
                Button("Take Photo") { onSelect(.importImage(.camera)) }
                Button("Choose from Photos") { onSelect(.importImage(.photoLibrary)) }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.height(600), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(BaselineColor.base)
    }

    /// "Today, Jul 24" / "Tomorrow, Jul 25" / "Thursday, Jul 31" — the day being decided.
    static func title(for date: Date) -> String {
        let cal = Calendar.planWeek
        let dayNumber = date.formatted(.dateTime.month(.abbreviated).day())
        if cal.isDateInToday(date) { return "Today, \(dayNumber)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow, \(dayNumber)" }
        return "\(date.formatted(.dateTime.weekday(.wide))), \(dayNumber)"
    }

    private func chooseImportSource() {
        if Self.importSources(cameraAvailable: cameraAvailable) == [.photoLibrary] {
            onSelect(.importImage(.photoLibrary))
        } else {
            showImportSourceDialog = true
        }
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

    private enum RowStyle { case standard, hero, rest }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(BaselineColor.textFaint)
    }

    private func optionRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        style: RowStyle = .standard,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(iconBackground(for: style))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(style == .hero ? BaselineColor.base : BaselineColor.accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BaselineColor.textHi)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(BaselineColor.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BaselineColor.textFaint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(for: style))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func iconBackground(for style: RowStyle) -> Color {
        switch style {
        case .hero: BaselineColor.accent
        case .rest: BaselineColor.surface
        case .standard: BaselineColor.amethyst
        }
    }

    @ViewBuilder private func rowBackground(for style: RowStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        switch style {
        case .hero:
            shape
                .fill(BaselineColor.amethyst.opacity(0.55))
                .overlay(shape.strokeBorder(BaselineColor.accent.opacity(0.4), lineWidth: 1))
        case .rest:
            shape
                .fill(BaselineColor.surface.opacity(0.5))
                .overlay(
                    shape.strokeBorder(
                        BaselineColor.textMid.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
                )
        case .standard:
            shape
                .fill(BaselineColor.surface.opacity(0.5))
                .overlay(shape.strokeBorder(BaselineColor.line, lineWidth: 1))
        }
    }
}
