import SwiftUI

/// Options for the reading, opened from the Start screen's "Options". Cue + preview preferences
/// (persisted via `AppSettings`) plus a read at-a-glance of the protocol.
struct ReadingOptionsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var editingDuration = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        InstrumentLabel("CUES").padding(.top, 8)
                        toggleRow("Voice cues", "Calm “breathe in / out”", $settings.voiceCuesEnabled)
                        toggleRow("Haptic cues", "Distinct in / out buzz", $settings.hapticCuesEnabled)

                        InstrumentLabel("POSITION").padding(.top, 28)
                        positionSelector().padding(.top, 12)
                        Text("Keep the same position each day so trends stay comparable.")
                            .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint).padding(.top, 10)

                        InstrumentLabel("READING").padding(.top, 28)
                        toggleRow("Live preview", "Show R-R before the read starts", $settings.livePreviewEnabled)
                        toggleRow("Guided breathing", "5s-in / 5s-out pacing + cues", $settings.guidedBreathingEnabled)
                        Button { editingDuration = true } label: {
                            infoRow("Morning length", ReadingLength.label(settings.morningReadingDurationSeconds))
                        }
                        .buttonStyle(.plain)
                        infoRow("End-of-reading sound", "Soft hand bell")
                        infoRow("Snapshot length", "1:00")

                        Text("Both reads use 5s-in / 5s-out resonance breathing (≈6 breaths/min).")
                            .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                            .padding(.top, 24)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Reading options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(BaselineColor.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $editingDuration) {
            DurationPickerSheet(seconds: settings.morningReadingDurationSeconds) {
                settings.morningReadingDurationSeconds = $0
            }
        }
    }

    private func toggleRow(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(BaselineColor.textHi)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                }
                Spacer()
                Toggle("", isOn: binding).labelsHidden().tint(BaselineColor.accent)
            }
            .frame(minHeight: 52)
            Hairline()
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(BaselineColor.textHi)
                Spacer()
                Text(value).font(.bMono(13, .medium)).foregroundStyle(BaselineColor.textMid)
            }
            .frame(minHeight: 52)
            Hairline()
        }
    }

    private func positionSelector() -> some View {
        HStack(spacing: 8) {
            ForEach(BodyPosition.allCases) { pos in
                let on = settings.readingPosition == pos
                Button { settings.readingPosition = pos } label: {
                    Text(pos.title)
                        .font(.bMono(12, .bold))
                        .foregroundStyle(on ? BaselineColor.base : BaselineColor.textMid)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(on ? BaselineColor.accent : BaselineColor.base))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(on ? Color.clear : BaselineColor.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

}

#Preview {
    ReadingOptionsView().environment(AppSettings())
}
