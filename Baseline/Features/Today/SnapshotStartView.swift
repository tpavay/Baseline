import SwiftUI

/// Pre-snapshot start screen: a quick 1-minute read. Length is fixed (1:00) but the athlete still
/// sets the body position they're in, so trends stay comparable. Mirrors the morning start.
struct SnapshotStartView: View {
    @Environment(AppSettings.self) private var settings
    let onStart: () -> Void
    let onDismiss: () -> Void

    @State private var editingPosition = false

    var body: some View {
        @Bindable var settings = settings
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(BaselineColor.textHi)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    Spacer()
                }
                .padding(.top, 8)

                Spacer(minLength: 32)

                VStack(alignment: .leading, spacing: 10) {
                    Text("HRV snapshot")
                        .font(.system(size: 42, weight: .heavy))
                        .foregroundStyle(BaselineColor.textHi)
                    Text("A quick one-minute pulse check. Sit still and breathe naturally.")
                        .font(.system(size: 19, weight: .semibold))
                        .lineSpacing(3)
                        .foregroundStyle(BaselineColor.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                HStack(spacing: 14) {
                    ReadingMetricSquare(
                        title: "TIME LIMIT",
                        value: ReadingType.snapshot.lengthLabel,
                        detail: "Fixed",
                        systemImage: "timer"
                    )
                    ReadingMetricSquare(
                        title: "BODY POSITION",
                        value: settings.readingPosition.title,
                        detail: "Tap to edit",
                        systemImage: settings.readingPosition.icon
                    ) { editingPosition = true }
                }

                Button(action: onStart) { Text("START SNAPSHOT") }
                    .buttonStyle(InstrumentButtonStyle())
                    .padding(.top, 20).padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $editingPosition) {
            PositionPickerSheet(position: settings.readingPosition) {
                settings.readingPosition = $0
            }
        }
    }
}
