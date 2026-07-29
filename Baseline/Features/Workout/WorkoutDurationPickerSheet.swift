import SwiftUI

/// Bottom wheel picker for the athlete-confirmed workout duration.
///
/// The wheels edit local scratch state so Cancel cannot accidentally change the finish review.
struct WorkoutDurationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The wheels top out at 24 hours. `.pickerStyle(.wheel)` bridges to `UIPickerView` and builds
    /// every row view when the sheet opens, so the range has to be a duration an athlete can
    /// plausibly select rather than the full `MetricFormat.maxDurationSeconds` span of a week — that
    /// would be ten thousand styled rows per presentation. It also keeps the largest selectable
    /// value well inside the canonical ceiling, so nothing the wheels display is silently clamped on
    /// the way to storage.
    static let maxMinutes = 1_440
    static let maxSelectableSeconds = TimeInterval(maxMinutes * 60)

    let onDone: (TimeInterval) -> Void

    @State private var minutes: Int
    @State private var seconds: Int

    init(durationSeconds: TimeInterval, onDone: @escaping (TimeInterval) -> Void) {
        let safeDuration = Int(
            min(max(0, durationSeconds), Self.maxSelectableSeconds).rounded()
        )
        self.onDone = onDone
        _minutes = State(initialValue: safeDuration / 60)
        _seconds = State(initialValue: safeDuration % 60)
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.bMono(12, .medium))
                        .foregroundStyle(BaselineColor.textMid)

                    Spacer()

                    Text("Duration")
                        .font(.headline)
                        .foregroundStyle(BaselineColor.textHi)

                    Spacer()

                    Button("Done") {
                        Haptics.select()
                        onDone(TimeInterval(minutes * 60 + seconds))
                        dismiss()
                    }
                    .font(.bMono(12, .bold))
                    .foregroundStyle(BaselineColor.accent)
                }
                .frame(minHeight: BaselineSize.minimumTapTarget)

                Hairline()

                HStack(spacing: BaselineSpacing.xSmall) {
                    Picker("Minutes", selection: $minutes) {
                        ForEach(0...Self.maxMinutes, id: \.self) { value in
                            Text("\(value)")
                                .font(.bMono(24, .semibold))
                                .tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Minutes")

                    Text("min")
                        .font(.bMono(14, .medium))
                        .foregroundStyle(BaselineColor.textMid)

                    Picker("Seconds", selection: $seconds) {
                        ForEach(0...59, id: \.self) { value in
                            Text(String(format: "%02d", value))
                                .font(.bMono(24, .semibold))
                                .tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Seconds")

                    Text("sec")
                        .font(.bMono(14, .medium))
                        .foregroundStyle(BaselineColor.textMid)
                }
                .colorScheme(.dark)
                .padding(.horizontal, BaselineSpacing.screen)
                .padding(.vertical, BaselineSpacing.large)
            }
            .padding(.horizontal, BaselineSpacing.large)
        }
        .presentationDetents([.height(390)])
        .presentationDragIndicator(.visible)
    }
}
