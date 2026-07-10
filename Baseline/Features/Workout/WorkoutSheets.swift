import SwiftUI

/// Input sheets for manual workout editing. Deliberately plain — steppers + number fields, no polish.

// MARK: - Add block

struct AddBlockSheet: View {
    let onSave: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var intent = ""

    var body: some View {
        SheetScaffold(title: "Add block", canSave: !name.trimmed.isEmpty, onSave: {
            onSave(name.trimmed, intent.trimmed.isEmpty ? nil : intent.trimmed); dismiss()
        }, onCancel: { dismiss() }) {
            SheetField("Name", text: $name, prompt: "Strength, Warm-up, Stations…")
            SheetField("Intent (optional)", text: $intent, prompt: "hypertrophy, aerobic…")
        }
    }
}

// MARK: - Add exercise

struct AddExerciseSheet: View {
    let blocks: [WorkoutBlock]
    let preferredBlock: UUID?
    let onSave: (UUID, PlannedExercise) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var blockID: UUID?
    @State private var name = ""
    @State private var sets = 3
    @State private var reps = ""
    @State private var load = ""
    @State private var duration = ""
    @State private var distance = ""

    var body: some View {
        SheetScaffold(title: "Add exercise", canSave: blockID != nil && !name.trimmed.isEmpty, onSave: save, onCancel: { dismiss() }) {
            if blocks.isEmpty {
                Text("Add a block first.").font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
            } else {
                labeled("Block") {
                    Picker("", selection: $blockID) {
                        ForEach(blocks) { b in Text(b.name).tag(Optional(b.id)) }
                    }.pickerStyle(.menu).tint(BaselineColor.accent)
                }
                SheetField("Exercise", text: $name, prompt: "Bench press, SkiErg…")
                labeled("Sets") { Stepper("\(sets)", value: $sets, in: 1...20).foregroundStyle(BaselineColor.textHi) }
                SheetField("Reps (optional)", text: $reps, prompt: "8", keyboard: .numberPad)
                SheetField("Load (optional)", text: $load, prompt: "60", keyboard: .decimalPad)
                SheetField("Duration sec (optional)", text: $duration, prompt: "3600", keyboard: .numberPad)
                SheetField("Distance m (optional)", text: $distance, prompt: "150", keyboard: .numberPad)
            }
        }
        .onAppear { blockID = preferredBlock ?? blocks.first?.id }
    }

    private func save() {
        guard let blockID else { return }
        var ex = PlannedExercise(exerciseName: name.trimmed)
        ex.prescription.sets = (0..<max(1, sets)).map { _ in
            PlannedSet(reps: Int(reps), load: Double(load), duration: Int(duration), distance: Double(distance))
        }
        onSave(blockID, ex); dismiss()
    }
}

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
            Text("Replacing \(currentName)").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
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

// MARK: - Log set (dynamic — one field per selected metric, in its display unit)

struct MetricLogSheet: View {
    let title: String
    let fields: [(metric: MetricType, unit: MetricUnit)]
    let onSave: (MetricValues) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: [MetricType: String] = [:]

    var body: some View {
        SheetScaffold(title: title, canSave: hasAny, onSave: save, onCancel: { dismiss() }) {
            Text("Enter what you actually did.").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
            ForEach(fields, id: \.metric) { field in
                SheetField(label(field.metric, field.unit), text: binding(field.metric), prompt: "",
                           keyboard: field.metric.isInteger ? .numberPad : .decimalPad)
            }
        }
    }

    private func binding(_ m: MetricType) -> Binding<String> {
        Binding(get: { text[m] ?? "" }, set: { text[m] = $0 })
    }
    private func label(_ m: MetricType, _ u: MetricUnit) -> String {
        u.short.isEmpty ? m.label : "\(m.label) (\(u.short))"
    }
    private var hasAny: Bool { fields.contains { !(text[$0.metric] ?? "").trimmed.isEmpty } }

    private func save() {
        var values = MetricValues()
        for (metric, unit) in fields {
            if let d = Double((text[metric] ?? "").trimmed) {
                values[metric] = max(0, MetricConvert.toCanonical(d, metric, from: unit))
            }
        }
        onSave(values); dismiss()
    }
}

// MARK: - Configure metrics (this workout: pick metrics + display units)

struct MetricConfigSheet: View {
    let exercise: PlannedExercise
    let unitFor: (MetricType) -> MetricUnit
    let onApply: (_ enabled: [MetricType], _ units: [MetricType: MetricUnit]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<MetricType>
    @State private var units: [MetricType: MetricUnit]

    init(exercise: PlannedExercise, unitFor: @escaping (MetricType) -> MetricUnit,
         onApply: @escaping (_ enabled: [MetricType], _ units: [MetricType: MetricUnit]) -> Void) {
        self.exercise = exercise; self.unitFor = unitFor; self.onApply = onApply
        _selected = State(initialValue: Set(exercise.selectedMetrics))
        var u: [MetricType: MetricUnit] = [:]
        for m in exercise.supportedMetrics where m.displayUnits.count > 1 { u[m] = unitFor(m) }
        _units = State(initialValue: u)
    }

    var body: some View {
        SheetScaffold(title: exercise.exerciseName, canSave: true, onSave: apply, onCancel: { dismiss() }) {
            Text("Log only what matters for this exercise — for this workout.").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
            ForEach(exercise.supportedMetrics, id: \.self) { metric in
                VStack(spacing: 8) {
                    Toggle(metric.label, isOn: toggle(metric)).tint(BaselineColor.accent)
                        .font(.system(size: 15)).foregroundStyle(BaselineColor.textHi)
                    if selected.contains(metric), metric.displayUnits.count > 1 {
                        Picker("Unit", selection: unitBinding(metric)) {
                            ForEach(metric.displayUnits, id: \.self) { Text($0.short).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                }
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
        onApply(enabled, overrides); dismiss()
    }
}

// MARK: - Shared scaffold

private struct SheetScaffold<Content: View>: View {
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

private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.textFaint)
        content()
    }
}

private struct SheetField: View {
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
                .font(.system(size: 15)).foregroundStyle(BaselineColor.textHi).keyboardType(keyboard)
                .padding(.horizontal, 14).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(BaselineColor.surface).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BaselineColor.line, lineWidth: 1)))
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
