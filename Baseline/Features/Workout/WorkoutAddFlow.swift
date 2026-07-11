import SwiftUI

/// **Add Exercise — Hevy-model multi-select.** Search (name / alias / category) → tap to select one
/// or several → **Add N exercises**. Recents first, then all exercises A–Z. Category chips filter.
/// Each row: a category glyph, name, and category tag. Custom exercises are created *explicitly*.
/// Selected exercises are inserted with their remembered metrics/units, ready for inline editing.
/// (Real thumbnails + muscle/equipment search need catalog media/metadata — see docs/ux-flow.md.)
struct AddExerciseFlow: View {
    let blockID: UUID
    let onInserted: ([UUID]) -> Void
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selected: [String] = []          // definition ids, in tap order
    @State private var category: ActivityCategory?
    @State private var showCustom = false

    private var recents: [ExerciseDefinition] {
        store.recentDefinitions.filter { matches($0) }
    }
    private var all: [ExerciseDefinition] {
        store.searchDefinitions(query).filter { category == nil || $0.category == category }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private func matches(_ d: ExerciseDefinition) -> Bool {
        (category == nil || d.category == category) &&
        (query.isEmpty || store.searchDefinitions(query).contains { $0.id == d.id })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchField
                    chips
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if query.isEmpty && category == nil && !recents.isEmpty { list("RECENT", recents) }
                            list(query.isEmpty && category == nil ? "ALL EXERCISES" : "RESULTS", all)
                            customRow
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .navigationTitle("Add exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundStyle(BaselineColor.textMid) } }
            .navigationDestination(isPresented: $showCustom) {
                CustomExerciseForm(seedName: query) { def in add([def]) }
            }
            .safeAreaInset(edge: .bottom) { if !selected.isEmpty { addBar } }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(BaselineColor.textFaint)
            TextField("", text: $query, prompt: Text("Search exercises…").foregroundStyle(BaselineColor.textFaint))
                .font(.system(size: 15)).foregroundStyle(BaselineColor.textHi)
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(BaselineColor.surface))
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isOn: category == nil) { category = nil }
                ForEach(categoriesPresent, id: \.self) { c in
                    chip(c.rawValue.capitalized, isOn: category == c) { category = category == c ? nil : c }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
    private var categoriesPresent: [ActivityCategory] {
        ActivityCategory.allCases.filter { c in store.allDefinitions.contains { $0.category == c } }
    }
    private func chip(_ title: String, isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Color(hex: 0x120B21) : BaselineColor.textMid)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(isOn ? BaselineColor.accent : BaselineColor.surface))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func list(_ title: String, _ defs: [ExerciseDefinition]) -> some View {
        if !defs.isEmpty {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.textFaint).padding(.top, 4)
            ForEach(defs) { def in row(def) }
        }
    }

    private func row(_ def: ExerciseDefinition) -> some View {
        let isSel = selected.contains(def.id)
        return Button { toggle(def.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: def.category.glyph).font(.system(size: 16)).foregroundStyle(BaselineColor.accent)
                    .frame(width: 38, height: 38).background(RoundedRectangle(cornerRadius: 10).fill(BaselineColor.surface))
                VStack(alignment: .leading, spacing: 2) {
                    Text(def.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                    Text(def.category.rawValue.capitalized).font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                }
                Spacer()
                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(isSel ? BaselineColor.accent : BaselineColor.line)
            }
            .padding(.vertical, 4)
        }.buttonStyle(.plain)
    }

    private var customRow: some View {
        Button { showCustom = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle").foregroundStyle(BaselineColor.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Create custom exercise").font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.accent)
                    if !query.isEmpty { Text("“\(query)”").font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint) }
                }
                Spacer()
            }
            .padding(14).background(RoundedRectangle(cornerRadius: 14).strokeBorder(BaselineColor.accent.opacity(0.4), lineWidth: 1))
            .padding(.top, 6)
        }.buttonStyle(.plain)
    }

    private var addBar: some View {
        Button { add(selected.compactMap { id in store.allDefinitions.first { $0.id == id } }) } label: {
            Text("Add \(selected.count) exercise\(selected.count == 1 ? "" : "s")")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(hex: 0x120B21))
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(BaselineColor.accent))
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 8)
        .background(BaselineColor.base)
    }

    private func toggle(_ id: String) {
        if let i = selected.firstIndex(of: id) { selected.remove(at: i) } else { selected.append(id) }
    }

    private func add(_ defs: [ExerciseDefinition]) {
        var ids: [UUID] = []
        for def in defs {
            var ex = PlannedExercise(exerciseName: def.name)
            ex.definitionId = def.id == ExerciseCatalog.generic.id ? nil : def.id
            var metrics = store.preferences.selectedByExercise[def.id] ?? def.defaults
            if metrics.isEmpty { metrics = [.reps, .load] }
            ex.selectedMetrics = MetricType.allCases.filter { metrics.contains($0) }
            ex.prescription.sets = [PlannedSet()]
            store.addExercise(ex, toBlockID: blockID)
            ids.append(ex.id)
        }
        onInserted(ids)
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
                    onCreate(store.createCustomDefinition(name: name, category: category,
                                                          supported: MetricType.allCases.filter { supported.contains($0) }))
                }
                .foregroundStyle(BaselineColor.accent).bold()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || supported.isEmpty)
            }
        }
    }
}
