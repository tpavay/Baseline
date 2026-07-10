import SwiftUI

/// **Catalog-first Add Exercise.** Select a stable Exercise Definition first (search / recent / all),
/// then configure the Planned Exercise instance with a modality-aware prescription that shows only
/// that exercise's default metrics. Free text creates a *custom definition* only after explicit
/// confirmation — never by default, so typos can't fragment history. The block is inherited from
/// where "Add exercise" was tapped. See docs/ux-flow.md.
struct AddExerciseFlow: View {
    let blockID: UUID
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ExercisePickerList(blockID: blockID, finish: { dismiss() })
        }
    }
}

// MARK: - Screen 1 · pick an exercise definition

private struct ExercisePickerList: View {
    let blockID: UUID
    let finish: () -> Void
    @Environment(WorkoutStore.self) private var store
    @State private var query = ""

    private var results: [ExerciseDefinition] { store.searchDefinitions(query) }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SheetField("", text: $query, prompt: "Search exercises…")

                    if query.isEmpty, !store.recentDefinitions.isEmpty {
                        section("RECENT", store.recentDefinitions)
                    }
                    section(query.isEmpty ? "ALL EXERCISES" : "MATCHES", results)

                    // Create-custom is a deliberate, separate action — shown always, emphasized when nothing matches.
                    NavigationLink {
                        CustomExerciseForm(blockID: blockID, seedName: query, finish: finish)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle").foregroundStyle(BaselineColor.accent)
                            Text(query.isEmpty ? "Create custom exercise" : "Create “\(query)”")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.accent)
                            Spacer()
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(BaselineColor.accent.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    if !query.isEmpty && results.isEmpty {
                        Text("No exercise found — create it as a custom exercise.")
                            .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Add exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel", action: finish).foregroundStyle(BaselineColor.textMid) } }
    }

    @ViewBuilder private func section(_ title: String, _ defs: [ExerciseDefinition]) -> some View {
        if !defs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.textFaint)
                ForEach(defs) { def in
                    NavigationLink {
                        PrescriptionEditor(definition: def, blockID: blockID, finish: finish)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(def.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                                Text(def.category.rawValue.capitalized).font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(BaselineColor.textFaint)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(BaselineColor.surface))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Screen 2 · configure the prescription (modality-aware)

private struct PrescriptionEditor: View {
    let definition: ExerciseDefinition
    let blockID: UUID
    let finish: () -> Void
    @Environment(WorkoutStore.self) private var store

    @State private var sets: Int
    @State private var selected: [MetricType]
    @State private var text: [MetricType: String] = [:]

    init(definition: ExerciseDefinition, blockID: UUID, finish: @escaping () -> Void) {
        self.definition = definition; self.blockID = blockID; self.finish = finish
        // Cardio-style modalities default to a single interval; strength to 3 sets.
        let isCardio = definition.defaults.contains(.distance) || definition.defaults.contains(.duration)
        _sets = State(initialValue: isCardio ? 1 : 3)
        _selected = State(initialValue: definition.defaults)
    }

    private var unusedMetrics: [MetricType] { definition.supported.filter { !selected.contains($0) } }
    private func unit(_ m: MetricType) -> MetricUnit {
        store.displayUnit(m, for: PlannedExercise(exerciseName: definition.name, definitionId: definition.id))
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled("Sets") { Stepper("\(sets)", value: $sets, in: 1...30).foregroundStyle(BaselineColor.textHi) }
                    ForEach(selected, id: \.self) { metric in
                        metricField(metric)
                    }
                    if !unusedMetrics.isEmpty {
                        Menu {
                            ForEach(unusedMetrics, id: \.self) { m in Button(m.label) { selected.append(m) } }
                        } label: {
                            Label("Add metric", systemImage: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.accent)
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(definition.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Add", action: save).foregroundStyle(BaselineColor.accent).bold() } }
    }

    @ViewBuilder private func metricField(_ metric: MetricType) -> some View {
        let u = unit(metric)
        let label = u.short.isEmpty ? metric.label : "\(metric.label) (\(u.short))"
        HStack {
            SheetField(metric == .duration ? "\(metric.label) (m:ss)" : label,
                       text: binding(metric), prompt: prompt(metric),
                       keyboard: metric == .duration ? .numbersAndPunctuation : (metric.isInteger ? .numberPad : .decimalPad))
            if selected.count > definition.defaults.count || !definition.defaults.contains(metric) {
                Button { selected.removeAll { $0 == metric } } label: {
                    Image(systemName: "minus.circle").foregroundStyle(BaselineColor.textFaint)
                }.buttonStyle(.plain).padding(.top, 18)
            }
        }
    }

    private func binding(_ m: MetricType) -> Binding<String> { Binding(get: { text[m] ?? "" }, set: { text[m] = $0 }) }
    private func prompt(_ m: MetricType) -> String {
        switch m { case .duration: "1:00"; case .distance: "150"; case .load: "60"; case .reps: "8"; case .rpe: "8"; default: "" }
    }

    private func save() {
        var values = MetricValues()
        for metric in selected {
            guard let raw = text[metric]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
            if metric == .duration {
                values[.duration] = Double(parseDuration(raw))
            } else if let d = Double(raw) {
                values[metric] = max(0, MetricConvert.toCanonical(d, metric, from: unit(metric)))
            }
        }
        var ex = PlannedExercise(exerciseName: definition.name)
        ex.definitionId = definition.id == ExerciseCatalog.generic.id ? nil : definition.id
        ex.selectedMetrics = MetricType.allCases.filter { selected.contains($0) }
        ex.prescription.sets = (0..<max(1, sets)).map { _ in PlannedSet(values: values) }
        store.addExercise(ex, toBlockID: blockID)
        finish()
    }

    /// "1:00" → 60, "90" → 90.
    private func parseDuration(_ s: String) -> Int {
        if s.contains(":") {
            let parts = s.split(separator: ":").map { Int($0) ?? 0 }
            return parts.count == 2 ? parts[0] * 60 + parts[1] : (parts.first ?? 0)
        }
        return Int(s) ?? 0
    }
}

// MARK: - Deliberate custom exercise creation

private struct CustomExerciseForm: View {
    let blockID: UUID
    let seedName: String
    let finish: () -> Void
    @Environment(WorkoutStore.self) private var store

    @State private var name: String
    @State private var category: ActivityCategory = .other
    @State private var supported: Set<MetricType> = [.reps, .load, .rpe]
    @State private var created: ExerciseDefinition?

    init(blockID: UUID, seedName: String, finish: @escaping () -> Void) {
        self.blockID = blockID; self.seedName = seedName; self.finish = finish
        _name = State(initialValue: seedName)
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SheetField("Name", text: $name, prompt: "Single-arm sled drag")
                    labeled("Category") {
                        Picker("", selection: $category) {
                            ForEach(ActivityCategory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }.pickerStyle(.menu).tint(BaselineColor.accent)
                    }
                    labeled("Metrics it supports") {
                        VStack(spacing: 6) {
                            ForEach(MetricType.allCases, id: \.self) { m in
                                Toggle(m.label, isOn: Binding(get: { supported.contains(m) },
                                    set: { if $0 { supported.insert(m) } else { supported.remove(m) } }))
                                    .tint(BaselineColor.accent).font(.system(size: 14)).foregroundStyle(BaselineColor.textHi)
                            }
                        }
                    }
                    NavigationLink(isActive: Binding(get: { created != nil }, set: { if !$0 { created = nil } })) {
                        if let def = created { PrescriptionEditor(definition: def, blockID: blockID, finish: finish) }
                    } label: { EmptyView() }.hidden()
                }
                .padding(20)
            }
        }
        .navigationTitle("Custom exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Create") {
                    created = store.createCustomDefinition(name: name, category: category, supported: MetricType.allCases.filter { supported.contains($0) })
                }
                .foregroundStyle(BaselineColor.accent).bold()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || supported.isEmpty)
            }
        }
    }
}
