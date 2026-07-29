import SwiftUI

/// Final review before a performed workout becomes immutable history.
struct WorkoutFinishSheet: View {
    let workoutTitle: String
    let summary: WorkoutLogSummary
    let units: ShareUnitResolver
    @Binding var durationSeconds: TimeInterval
    let onSave: () -> Void
    let onDiscard: () -> Void

    @State private var showDurationPicker = false
    @AccessibilityFocusState private var durationIsFocused: Bool

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: BaselineSpacing.xLarge) {
                    header
                    durationButton
                    summaryCard

                    Button("Save workout", action: onSave)
                        .buttonStyle(InstrumentButtonStyle())

                    Button("Discard workout", role: .destructive, action: onDiscard)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BaselineColor.zoneRed)
                        .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, BaselineSpacing.screen)
                .padding(.top, BaselineSpacing.xSmall)
                .padding(.bottom, BaselineSpacing.screen)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showDurationPicker, onDismiss: {
            durationIsFocused = true
        }) {
            WorkoutDurationPickerSheet(durationSeconds: durationSeconds) { value in
                durationSeconds = value
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BaselineSpacing.xSmall) {
            Text("Nice work 🎉")
                .font(.largeTitle.bold())
                .foregroundStyle(BaselineColor.textHi)

            Text("Review your \(workoutTitle), then save it to today.")
                .font(.body)
                .foregroundStyle(BaselineColor.textMid)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var durationButton: some View {
        Button {
            showDurationPicker = true
        } label: {
            HStack(spacing: BaselineSpacing.medium) {
                VStack(alignment: .leading, spacing: BaselineSpacing.xxSmall) {
                    InstrumentLabel("Duration", color: BaselineColor.accent, tracking: 1)
                    Text(MetricFormat.durationEditText(durationSeconds))
                        .font(.bMono(28, .bold))
                        .foregroundStyle(BaselineColor.textHi)
                        .contentTransition(.numericText())
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(BaselineColor.accent)
            }
            .padding(BaselineSpacing.cardContent)
            .background {
                RoundedRectangle(cornerRadius: BaselineRadius.card, style: .continuous)
                    .fill(BaselineColor.amethyst.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: BaselineRadius.card, style: .continuous)
                            .stroke(BaselineColor.accent.opacity(0.55), lineWidth: BaselineSize.hairline)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Edit workout duration, \(MetricFormat.durationEditText(durationSeconds))"
        )
        .accessibilityHint("Opens the duration picker")
        .accessibilityFocused($durationIsFocused)
    }

    private var summaryCard: some View {
        BaselineCard {
            VStack(spacing: 0) {
                summaryRow(label: "Exercises", value: "\(summary.exerciseCount)")

                if summary.totalSets > 0 {
                    Hairline()
                    summaryRow(label: "Sets", value: "\(summary.totalSets)")
                }

                if summary.totalDistanceMeters > 0 {
                    Hairline()
                    summaryRow(
                        label: "Distance",
                        value: MetricFormat.value(
                            summary.totalDistanceMeters,
                            .distance,
                            unit: units.unitForTotals(.distance)
                        )
                    )
                }

                if let pace = summary.averagePaceSecondsPerMeter {
                    Hairline()
                    summaryRow(
                        label: "Avg pace",
                        value: MetricFormat.value(
                            pace,
                            .pace,
                            unit: units.unitForTotals(.pace)
                        )
                    )
                }

                if let heartRate = summary.averageHeartRate {
                    Hairline()
                    summaryRow(label: "Avg heart rate", value: "\(heartRate) bpm")
                }
            }
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(BaselineColor.textMid)

            Spacer()

            Text(value)
                .font(.bMono(15, .semibold))
                .foregroundStyle(BaselineColor.textHi)
        }
        .frame(minHeight: BaselineSize.minimumTapTarget)
    }
}
