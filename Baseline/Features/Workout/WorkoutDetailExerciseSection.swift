import SwiftUI

struct WorkoutDetailExerciseSection: View {
    @Environment(AppSettings.self) private var settings
    let planned: PlannedExercise
    let performed: PerformedExercise?

    private var rows: [MetricValues] {
        let performedRows = performed?.setLogs.filter(\.isHandled).map(\.values) ?? []
        return performedRows.isEmpty ? planned.prescription.sets.map(\.values) : performedRows
    }

    private var metrics: [MetricType] {
        let present = MetricType.allCases.filter { metric in rows.contains { $0[metric] != nil } }
        return Array((present.isEmpty ? planned.selectedMetrics : present).prefix(3))
    }

    private var muscleLabel: String {
        let muscles = planned.definition.primaryMuscles.prefix(2).map { $0.displayName.lowercased() }
        return muscles.isEmpty ? planned.definition.modality?.displayName.lowercased() ?? "training" : muscles.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: BaselineSpacing.small) {
                RoundedRectangle(cornerRadius: BaselineRadius.small)
                    .fill(BaselineColor.surface)
                    .frame(width: BaselineSize.icon, height: BaselineSize.icon)
                    .overlay {
                        Image(systemName: planned.definition.category.glyph)
                            .font(.caption)
                            .foregroundStyle(BaselineColor.accent)
                    }
                    .accessibilityHidden(true)

                Text(planned.displayLabel ?? planned.exerciseName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.textHi)

                Spacer()

                Text(muscleLabel)
                    .font(.caption2)
                    .foregroundStyle(BaselineColor.textFaint)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.top, BaselineSpacing.small)
            .padding(.bottom, BaselineSpacing.xSmall)

            if rows.isEmpty == false {
                Grid(alignment: .leading, horizontalSpacing: BaselineSpacing.xLarge, verticalSpacing: BaselineSpacing.xxSmall) {
                    GridRow {
                        header("SET")
                        ForEach(metrics, id: \.self) { metric in
                            header(columnHeader(metric))
                        }
                    }

                    ForEach(Array(rows.enumerated()), id: \.offset) { index, values in
                        GridRow {
                            Text("\(index + 1)")
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(BaselineColor.textFaint)
                            ForEach(metrics, id: \.self) { metric in
                                Text(formatted(values[metric], metric: metric))
                                    .font(.caption.monospaced().weight(.semibold))
                                    .foregroundStyle(BaselineColor.textHi)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.bottom, BaselineSpacing.small)
                .accessibilityElement(children: .combine)
            }

            Hairline(color: BaselineColor.line.opacity(0.7))
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption2.monospaced().weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(BaselineColor.textFaint)
            .lineLimit(1)
    }

    private func columnHeader(_ metric: MetricType) -> String {
        let unit = planned.displayUnits[metric] ?? settings.unitSystem.displayUnit(metric: metric, exercise: planned.definition)
        return MetricFormat.columnHeader(metric, unit: unit)
    }

    private func formatted(_ value: Double?, metric: MetricType) -> String {
        guard let value else { return "-" }
        let unit = planned.displayUnits[metric] ?? settings.unitSystem.displayUnit(metric: metric, exercise: planned.definition)
        return MetricFormat.value(value, metric, unit: unit)
    }
}
