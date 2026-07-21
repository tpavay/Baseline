import SwiftUI

/// Edit one exercise's *prescription* — the planned sets and their target values — from inside a live
/// workout.
///
/// This is deliberately distinct from logging. Typing a different number into the log table records
/// what you actually did; changing the prescription here changes what the workout is *asking* for. Only
/// the latter counts as diverging from the plan, which is why the completion "update your plan?"
/// prompt diffs prescriptions rather than logged actuals — otherwise every honest session would prompt.
///
/// Every edit goes through `store.edit`, so during a live session it lands on the session's own workout
/// copy and the saved plan stays untouched until the athlete opts in at completion.
struct EditPrescriptionSheet: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let exerciseID: UUID

    private var exercise: PlannedExercise? {
        store.current?.exercise(exerciseID)
    }

    /// Metrics that get an editable column, in the exercise's own configured order.
    ///
    /// Falls back to whichever metrics the prescription actually carries values for, matching the log
    /// table's own resolution. Plenty of exercises — anything imported or built without going through
    /// the catalog picker — have an empty `selectedMetrics` while still prescribing reps and load, and
    /// showing those an empty state would make the sheet look broken.
    private var metrics: [MetricType] {
        guard let exercise else { return [] }
        if !exercise.selectedMetrics.isEmpty { return exercise.selectedMetrics }
        return MetricType.allCases.filter { metric in
            exercise.prescription.sets.contains { $0.values[metric] != nil }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let exercise, !metrics.isEmpty {
                    content(exercise)
                } else {
                    unavailableState
                }
            }
            .navigationTitle(exercise.map(Self.name) ?? "Prescription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(BaselineColor.accent)
    }

    private func content(_ exercise: PlannedExercise) -> some View {
        List {
            Section {
                headerRow
                ForEach(Array(exercise.prescription.sets.enumerated()), id: \.element.id) { index, set in
                    setRow(set, number: index + 1, exercise: exercise)
                }
                .onDelete { offsets in
                    // Keep at least one set — an exercise with no sets has nothing to log against.
                    // Removing the exercise entirely is a separate, explicit action.
                    guard exercise.prescription.sets.count > offsets.count else { return }
                    let ids = offsets.compactMap { exercise.prescription.sets[safe: $0]?.id }
                    Haptics.tap()
                    store.removePlannedSets(ids, fromExercise: exerciseID, scope: .session)
                }
            } header: {
                Text("Planned sets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BaselineColor.textFaint)
            } footer: {
                Text("These are the targets for this workout. Your logged results are recorded separately.")
                    .font(.footnote)
                    .foregroundStyle(BaselineColor.textFaint)
            }
            .listRowBackground(BaselineColor.surface)

            Section {
                Button { addSet(after: exercise) } label: {
                    Label("Add Set", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BaselineColor.accent)
                }
            }
            .listRowBackground(BaselineColor.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(BaselineColor.base)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Column titles, so a bare row of numbers is never ambiguous about which metric is which.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("SET")
                .font(.bMono(11, .bold)).tracking(0.8)
                .foregroundStyle(BaselineColor.textFaint)
                .frame(width: 34, alignment: .leading)
            ForEach(metrics, id: \.self) { metric in
                Text(columnTitle(metric).uppercased())
                    .font(.bMono(11, .bold)).tracking(0.8)
                    .foregroundStyle(BaselineColor.textFaint)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func setRow(_ set: PlannedSet, number: Int, exercise: PlannedExercise) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(BaselineColor.textMid)
                .frame(width: 34, alignment: .leading)
            ForEach(metrics, id: \.self) { metric in
                MetricField(
                    metric: metric,
                    unit: store.displayUnit(metric, for: exercise),
                    accessibilityName: "Set \(number), planned \(metric.label), \(store.displayUnit(metric, for: exercise).short)",
                    canonical: binding(setID: set.id, metric: metric)
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Text("Nothing to adjust")
                .font(.title3.weight(.semibold))
                .foregroundStyle(BaselineColor.textHi)
            Text("This exercise has no tracked metrics. Choose metrics from its actions menu first.")
                .font(.body)
                .foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BaselineColor.base)
    }

    private func binding(setID: UUID, metric: MetricType) -> Binding<Double?> {
        Binding(
            get: {
                store.current?.exercise(exerciseID)?.prescription.sets
                    .first { $0.id == setID }?.values[metric]
            },
            set: { value in
                store.edit(.session) { $0.updateSet(setID) { $0.values[metric] = value.map { max(0, $0) } } }
            }
        )
    }

    /// Append a set seeded from the last one, matching the template editor's behavior so an athlete
    /// adding a fifth set gets the fourth set's targets rather than an empty row.
    private func addSet(after exercise: PlannedExercise) {
        Haptics.tap()
        store.edit(.session) { workout in
            workout.updateExercise(exerciseID) { planned in
                var copy = planned.prescription.sets.last ?? PlannedSet()
                copy.id = UUID()
                planned.prescription.sets.append(copy)
            }
        }
    }

    /// The unit is the most useful column header when there is one ("KG", "MI"), but unitless metrics
    /// like reps have an empty short form — fall back to the metric's own name so no column is blank.
    private func columnTitle(_ metric: MetricType) -> String {
        guard let exercise else { return metric.label }
        let unit = store.displayUnit(metric, for: exercise).short
        return unit.trimmingCharacters(in: .whitespaces).isEmpty ? metric.label : unit
    }

    private static func name(_ exercise: PlannedExercise) -> String {
        let label = exercise.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label?.isEmpty == false ? label : nil) ?? exercise.exerciseName
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
