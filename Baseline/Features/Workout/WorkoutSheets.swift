import SwiftUI

/// Input sheets for manual workout editing. Deliberately plain — steppers + number fields, no polish.

// MARK: - Substitute

struct SubstituteSheet: View {
    let currentName: String
    let onSave: (String, Prescription) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sets = 3
    @State private var reps = ""
    @State private var load = ""

    var body: some View {
        SheetScaffold(title: "Substitute", canSave: !name.trimmed.isEmpty, onSave: save, onCancel: { dismiss() }) {
            Text("Replacing \(currentName)").font(.caption).foregroundStyle(BaselineColor.textFaint)
            SheetField("New exercise", text: $name, prompt: "Dumbbell press…")
            labeled("Sets") { Stepper("\(sets)", value: $sets, in: 1...20).foregroundStyle(BaselineColor.textHi) }
            SheetField("Reps (optional)", text: $reps, prompt: "10", keyboard: .numberPad)
            SheetField("Load (optional)", text: $load, prompt: "25", keyboard: .decimalPad)
        }
        .onAppear { name = "" }
    }

    private func save() {
        var p = Prescription()
        p.sets = (0..<max(1, sets)).map { _ in PlannedSet(reps: Int(reps), load: Double(load)) }
        onSave(name.trimmed, p); dismiss()
    }
}

// MARK: - Configure metrics + units (this workout)

/// Which half of the exercise config the ⋯ menu opened — Metrics (which columns) vs Units (how each
/// is shown). Same underlying apply; a focused sheet keeps each choice a single, obvious decision.
enum MetricConfigFocus { case metrics, units }

struct MetricConfigSheet: View {
    let exercise: PlannedExercise
    let focus: MetricConfigFocus
    let unitFor: (MetricType) -> MetricUnit
    let onSetDefault: ((_ enabled: [MetricType], _ units: [MetricType: MetricUnit]) -> Void)?
    let onApply: (_ enabled: [MetricType], _ units: [MetricType: MetricUnit]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<MetricType>
    @State private var units: [MetricType: MetricUnit]
    @State private var useForFuture = false

    init(exercise: PlannedExercise, focus: MetricConfigFocus, unitFor: @escaping (MetricType) -> MetricUnit,
         onSetDefault: ((_ enabled: [MetricType], _ units: [MetricType: MetricUnit]) -> Void)? = nil,
         onApply: @escaping (_ enabled: [MetricType], _ units: [MetricType: MetricUnit]) -> Void) {
        self.exercise = exercise
        self.focus = focus
        self.unitFor = unitFor
        self.onSetDefault = onSetDefault
        self.onApply = onApply
        _selected = State(initialValue: Set(exercise.selectedMetrics))
        var u: [MetricType: MetricUnit] = [:]
        for m in exercise.supportedMetrics where m.displayUnits.count > 1 { u[m] = unitFor(m) }
        _units = State(initialValue: u)
    }

    var body: some View {
        SheetScaffold(title: exercise.exerciseName, canSave: true, onSave: apply, onCancel: { dismiss() }) {
            switch focus {
            case .metrics:
                Text("Which metrics this exercise logs — for this workout.").font(.caption).foregroundStyle(BaselineColor.textFaint)
                ForEach(exercise.supportedMetrics, id: \.self) { metric in
                    Toggle(metric.label, isOn: toggle(metric)).tint(BaselineColor.accent)
                        .font(.body).foregroundStyle(BaselineColor.textHi)
                }
            case .units:
                // Durations always render smart time (45s / 10:00) — a sec-vs-min preference is moot.
                let unitful = exercise.selectedMetrics.filter { $0.displayUnits.count > 1 && !$0.isDurationKind }
                if unitful.isEmpty {
                    Text("The metrics on this exercise don't have unit choices.").font(.caption).foregroundStyle(BaselineColor.textFaint)
                } else {
                    Text("How each metric is shown — for this workout.").font(.caption).foregroundStyle(BaselineColor.textFaint)
                    ForEach(unitful, id: \.self) { metric in
                        labeled(metric.label) {
                            Picker("Unit", selection: unitBinding(metric)) {
                                ForEach(metric.displayUnits, id: \.self) { Text($0.short).tag($0) }
                            }.pickerStyle(.segmented)
                        }
                    }
                }
            }

            if onSetDefault != nil {
                Toggle("Use for future \(exercise.exerciseName) workouts", isOn: $useForFuture)
                    .tint(BaselineColor.accent)
                    .font(.subheadline)
                    .foregroundStyle(BaselineColor.textHi)
                    .accessibilityHint("Saves these metrics and units as the default for new instances of this exercise")
            }
        }
    }

    private func toggle(_ m: MetricType) -> Binding<Bool> {
        Binding(get: { selected.contains(m) }, set: { if $0 { selected.insert(m) } else { selected.remove(m) } })
    }
    private func unitBinding(_ m: MetricType) -> Binding<MetricUnit> {
        Binding(get: { units[m] ?? m.canonicalUnit }, set: { units[m] = $0 })
    }
    private func apply() {
        let enabled = MetricType.allCases.filter { selected.contains($0) }
        let overrides = units.filter { selected.contains($0.key) }
        onApply(enabled, overrides)
        if useForFuture { onSetDefault?(enabled, overrides) }
        dismiss()
    }
}

// MARK: - Shared scaffold

struct SheetScaffold<Content: View>: View {
    let title: String
    let canSave: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { content }.padding(20)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: onCancel).foregroundStyle(BaselineColor.textMid) }
                ToolbarItem(placement: .topBarTrailing) { Button("Save", action: onSave).foregroundStyle(BaselineColor.accent).disabled(!canSave) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(BaselineColor.textFaint)
        content()
    }
}

struct SheetField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var keyboard: UIKeyboardType = .default

    init(_ label: String, text: Binding<String>, prompt: String, keyboard: UIKeyboardType = .default) {
        self.label = label; self._text = text; self.prompt = prompt; self.keyboard = keyboard
    }

    var body: some View {
        labeled(label) {
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(BaselineColor.textFaint))
                .font(.body).foregroundStyle(BaselineColor.textHi).keyboardType(keyboard)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(BaselineColor.surface).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BaselineColor.line, lineWidth: 1)))
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
