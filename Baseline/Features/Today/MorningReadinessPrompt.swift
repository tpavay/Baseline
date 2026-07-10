import SwiftUI

enum MorningReadinessPromptPolicy {
    static func shouldPresent(
        now: Date,
        hasMorningReadingToday: Bool,
        config: ReadinessConfig,
        calendar: Calendar = .current
    ) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour < 12
            && !hasMorningReadingToday
            && config.heartReadingEnabled
            && config.heartSource != nil
    }
}

struct MorningReadinessPromptView: View {
    @Environment(AppSettings.self) private var settings

    let source: HeartSource
    let onStart: () -> Void
    let onDismiss: () -> Void

    @State private var editingDuration = false
    @State private var editingPosition = false

    var body: some View {
        @Bindable var settings = settings
        ZStack {
            Image("MorningHRVReadingBackground")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    BaselineColor.base.opacity(0.45),
                    BaselineColor.base.opacity(0.05),
                    BaselineColor.base.opacity(0.78)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(BaselineColor.textHi)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                }
                .padding(.top, 8)

                Spacer(minLength: 32)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Good morning")
                        .font(.system(size: 42, weight: .heavy))
                        .foregroundStyle(BaselineColor.textHi)
                    Text("Take your morning readiness reading before training.")
                        .font(.system(size: 19, weight: .semibold))
                        .lineSpacing(3)
                        .foregroundStyle(BaselineColor.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                HStack(spacing: 14) {
                    ReadingMetricSquare(
                        title: "TIME LIMIT",
                        value: ReadingLength.label(settings.morningReadingDurationSeconds),
                        detail: "Tap to edit",
                        systemImage: "timer"
                    ) { editingDuration = true }

                    ReadingMetricSquare(
                        title: "BODY POSITION",
                        value: settings.readingPosition.title,
                        detail: source.title,
                        systemImage: settings.readingPosition.icon
                    ) { editingPosition = true }
                }

                Button(action: onStart) {
                    Text("TAKE MORNING READINESS")
                }
                .buttonStyle(InstrumentButtonStyle())
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $editingDuration) {
            DurationPickerSheet(seconds: settings.morningReadingDurationSeconds) {
                settings.morningReadingDurationSeconds = $0
            }
        }
        .sheet(isPresented: $editingPosition) {
            PositionPickerSheet(position: settings.readingPosition) {
                settings.readingPosition = $0
            }
        }
    }

}

