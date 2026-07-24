import SwiftUI

struct WorkoutDetailExerciseSection: View {
    @Environment(WorkoutStore.self) private var store
    let planned: PlannedExercise
    let performed: PerformedExercise?

    private var rows: [MetricValues] {
        let performedRows = performed?.setLogs.filter(\.isHandled).map(\.values) ?? []
        return performedRows.isEmpty ? planned.prescription.sets.map(\.values) : performedRows
    }

    private var metrics: [MetricType] {
        // Columns follow the exercise's metric schema (its selected metrics), intersected with the
        // metrics that were actually logged, so a substituted movement shows its own metrics and never
        // a previous movement's. Fall back to raw present values only when there is no schema to lean on.
        let present = MetricType.allCases.filter { metric in rows.contains { $0[metric] != nil } }
        let schema = planned.selectedMetrics.filter(present.contains)
        return Array((schema.isEmpty ? present : schema).prefix(3))
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
        MetricFormat.columnHeader(metric, unit: store.displayUnit(metric, for: planned))
    }

    private func formatted(_ value: Double?, metric: MetricType) -> String {
        guard let value else { return "-" }
        return MetricFormat.value(value, metric, unit: store.displayUnit(metric, for: planned))
    }
}
