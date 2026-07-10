import SwiftUI

/// **Catalog-first, direct-insert Add Exercise.** Search/pick a stable Exercise Definition and it's
/// inserted immediately into the block (default metrics + remembered config, one empty set) and
/// auto-expanded for inline editing — no prescription form, no Save. Free text creates a custom
/// definition only after explicit confirmation. See docs/ux-flow.md.
struct AddExerciseFlow: View {
    let blockID: UUID
    let onInserted: (UUID) -> Void
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [ExerciseDefinition] { store.searchDefinitions(query) }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SheetField("", text: $query, prompt: "Search exercises…")
                        if query.isEmpty, !store.recentDefinitions.isEmpty { section("RECENT", store.recentDefinitions) }
                        section(query.isEmpty ? "ALL EXERCISES" : "MATCHES", results)
                        NavigationLink {
                            CustomExerciseForm(seedName: query) { def in insert(def) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle").foregroundStyle(BaselineColor.accent)
                                Text(query.isEmpty ? "Create custom exercise" : "Create “\(query)”")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.accent)
                                Spacer()
                            }
                            .padding(14).background(RoundedRectangle(cornerRadius: 14).strokeBorder(BaselineColor.accent.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.foregroundStyle(BaselineColor.textMid) } }
        }
        .presentationDetents([.large, .medium])
    }

    @ViewBuilder private func section(_ title: String, _ defs: [ExerciseDefinition]) -> some View {
        if !defs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.textFaint)
                ForEach(defs) { def in
                    Button { insert(def) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(def.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                                Text(def.category.rawValue.capitalized).font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                            }
                            Spacer()
                            Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(BaselineColor.accent)
                        }
                        .padding(14).background(RoundedRectangle(cornerRadius: 14).fill(BaselineColor.surface))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Insert the definition as a Planned Exercise instance — default (or remembered) metrics, one
    /// empty set — then hand back its id so the caller expands it for inline editing.
    private func insert(_ def: ExerciseDefinition) {
        var ex = PlannedExercise(exerciseName: def.name)
        ex.definitionId = def.id == ExerciseCatalog.generic.id ? nil : def.id
        var metrics = store.preferences.selectedByExercise[def.id] ?? def.defaults
        if metrics.isEmpty { metrics = [.reps, .load] }
        ex.selectedMetrics = MetricType.allCases.filter { metrics.contains($0) }
        ex.prescription.sets = [PlannedSet()]
        store.addExercise(ex, toBlockID: blockID)
        onInserted(ex.id)
        dismiss()
    }
}

// MARK: - Deliberate custom exercise creation

private struct CustomExerciseForm: View {
    let seedName: String
    let onCreate: (ExerciseDefinition) -> Void
    @Environment(WorkoutStore.self) private var store
    @State private var name: String
    @State private var category: ActivityCategory = .other
    @State private var supported: Set<MetricType> = [.reps, .load, .rpe]

    init(seedName: String, onCreate: @escaping (ExerciseDefinition) -> Void) {
        self.seedName = seedName; self.onCreate = onCreate
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
                }
                .padding(20)
            }
        }
        .navigationTitle("Custom exercise")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Create & add") {
                    let def = store.createCustomDefinition(name: name, category: category,
                                                           supported: MetricType.allCases.filter { supported.contains($0) })
                    onCreate(def)
                }
                .foregroundStyle(BaselineColor.accent).bold()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || supported.isEmpty)
            }
        }
    }
}
