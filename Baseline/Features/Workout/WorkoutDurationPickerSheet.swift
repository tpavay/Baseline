import SwiftUI

/// Bottom wheel picker for the athlete-confirmed workout duration.
///
/// The wheels edit local scratch state so Cancel cannot accidentally change the finish review.
struct WorkoutDurationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let durationSeconds: TimeInterval
    let onDone: (TimeInterval) -> Void

    @State private var minutes: Int
    @State private var seconds: Int

    init(durationSeconds: TimeInterval, onDone: @escaping (TimeInterval) -> Void) {
        let safeDuration = Int(
            min(max(0, durationSeconds), MetricFormat.maxDurationSeconds).rounded()
        )
        self.durationSeconds = durationSeconds
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
                        ForEach(0...10_080, id: \.self) { value in
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
