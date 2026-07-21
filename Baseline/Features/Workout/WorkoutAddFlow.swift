import SwiftUI

/// **Add Exercise — Hevy-model multi-select.** Search (name / alias / category) → tap to select one
/// or several → **Add N exercises**. Recents first, then all exercises A–Z. Category chips filter.
/// Each row: a category glyph, name, and category tag. Custom exercises are created *explicitly*.
/// Selected exercises are inserted with their remembered metrics/units, ready for inline editing.
/// (Real thumbnails + muscle/equipment search need catalog media/metadata — see docs/ux-flow.md.)
struct AddExerciseFlow: View {
    let blockID: UUID
    /// Stated by the presenter, which knows whether it is shaping a live session or the saved plan.
    let scope: WorkoutEditScope
    let onInserted: ([UUID]) -> Void
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selected: [String] = []          // definition ids, in tap order
    @State private var category: ActivityCategory?
    @State private var showCustom = false
    @ScaledMetric(relativeTo: .body) private var exerciseThumbnailSize: CGFloat = 64

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
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .navigationTitle("Add exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundStyle(BaselineColor.textMid) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { showCustom = true }.foregroundStyle(BaselineColor.accent).fontWeight(.semibold)
                        .accessibilityHint("Create a custom exercise")
                }
            }
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
                Capsule()
                    .fill(isSel ? BaselineColor.accent : .clear)
                    .frame(width: 4, height: exerciseThumbnailSize - 8)
                    .accessibilityHidden(true)
                ExerciseThumbnailView(definition: def, size: exerciseThumbnailSize)
                VStack(alignment: .leading, spacing: 3) {
                    Text(def.name)
                        .font(.headline)
                        .foregroundStyle(BaselineColor.textHi)
                    Text(def.category.rawValue.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(BaselineColor.textFaint)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSel ? "Selected" : "Not selected")
        .accessibilityHint(isSel ? "Removes this exercise from the list to add" : "Adds this exercise to the list to add")
        .accessibilityAddTraits(isSel ? .isSelected : [])
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
            store.addExercise(ex, toBlockID: blockID, scope: scope)
            ids.append(ex.id)
        }
        onInserted(ids)
        dismiss()
    }
}

// MARK: - Deliberate custom exercise creation

/// Create a custom exercise with the full taxonomy. Required: name, equipment, primary muscle, and at
/// least one metric. Movement pattern is capped at two; level defaults to Intermediate; modality and the
/// legacy category are derived (the metrics you log decide what modality it is). See docs/ux-flow.md.
struct CustomExerciseForm: View {
    let seedName: String
    let onCreate: (ExerciseDefinition) -> Void
    @Environment(WorkoutStore.self) private var store

    @State private var name: String
    @State private var equipment: [Equipment] = []
    @State private var primary: [Muscle] = []
    @State private var secondary: [Muscle] = []
    @State private var metrics: [MetricType] = []
    @State private var patterns: [MovementPattern] = []
    @State private var tags: [ExerciseTag] = []
    @State private var level: [ExerciseLevel] = [.intermediate]
    @State private var active: PickerKind?

    enum PickerKind: String, Identifiable { case equipment, primary, secondary, metrics, pattern, tags, level; var id: String { rawValue } }

    init(seedName: String, onCreate: @escaping (ExerciseDefinition) -> Void) {
        self.seedName = seedName; self.onCreate = onCreate
        _name = State(initialValue: seedName)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !equipment.isEmpty && !primary.isEmpty && !metrics.isEmpty
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SheetField("Name", text: $name, prompt: "Single-arm sled drag")
                        .padding(.bottom, 8)

                    section("CLASSIFICATION")
                    row("Equipment", required: true, value: equipment.map(\.displayName).joined(separator: ", ")) { active = .equipment }
                    row("Primary muscle", required: true, value: primary.first?.displayName ?? "") { active = .primary }
                    row("Other muscles", value: secondary.map(\.displayName).joined(separator: ", ")) { active = .secondary }
                    row("Metrics it can log", required: true, value: metrics.map(\.label).joined(separator: ", ")) { active = .metrics }
                    row("Movement pattern", value: patterns.map(\.displayName).joined(separator: ", ")) { active = .pattern }
                    row("Tags", value: tags.map(\.displayName).joined(separator: ", ")) { active = .tags }
                    row("Level", value: level.first?.displayName ?? "Intermediate") { active = .level }

                    Text("Name, equipment, primary muscle and at least one metric are required. Level defaults to Intermediate; you can change what you actually log per workout.")
                        .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                        .padding(.top, 16)
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
                    onCreate(store.createCustomDefinition(
                        name: name,
                        supported: metrics,
                        equipment: equipment,
                        primaryMuscles: primary,
                        secondaryMuscles: secondary,
                        patterns: patterns,
                        tags: tags,
                        level: level.first ?? .intermediate))
                }
                .foregroundStyle(canCreate ? BaselineColor.accent : BaselineColor.textFaint).bold()
                .disabled(!canCreate)
            }
        }
        .sheet(item: $active) { kind in pickerSheet(kind) }
    }

    @ViewBuilder private func pickerSheet(_ kind: PickerKind) -> some View {
        switch kind {
        case .equipment: TaxonomyPicker(title: "Equipment", all: Equipment.allCases, name: \.displayName, selected: $equipment)
        case .primary: TaxonomyPicker(title: "Primary muscle", all: Muscle.allCases, name: \.displayName, selected: $primary)
        case .secondary: TaxonomyPicker(title: "Other muscles", all: Muscle.allCases, name: \.displayName, multi: true, selected: $secondary)
        case .metrics: TaxonomyPicker(title: "Metrics", all: MetricType.allCases, name: \.label, multi: true, selected: $metrics)
        case .pattern: TaxonomyPicker(title: "Movement pattern", all: MovementPattern.allCases, name: \.displayName, multi: true, cap: 2, selected: $patterns)
        case .tags: TaxonomyPicker(title: "Tags", all: ExerciseTag.allCases, name: \.displayName, multi: true, selected: $tags)
        case .level: TaxonomyPicker(title: "Level", all: ExerciseLevel.allCases, name: \.displayName, selected: $level)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.6)
            .foregroundStyle(BaselineColor.textFaint).padding(.top, 22).padding(.bottom, 4)
    }

    private func row(_ label: String, required: Bool = false, value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(label).font(.system(size: 16)).foregroundStyle(BaselineColor.textHi)
                        if required { Text("*").font(.system(size: 14)).foregroundStyle(BaselineColor.accent) }
                    }
                    Text(value.isEmpty ? (required ? "Select" : "Select (optional)") : value)
                        .font(.system(size: 13))
                        .foregroundStyle(value.isEmpty ? BaselineColor.accent : BaselineColor.textMid)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(BaselineColor.line).frame(height: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Reusable single- or multi-select picker for a taxonomy enum. Single-select commits on tap; multi-select
/// toggles and can be capped (the movement-pattern picker locks after two).
struct TaxonomyPicker<T: Hashable>: View {
    let title: String
    let all: [T]
    let name: (T) -> String
    var multi: Bool = false
    var cap: Int? = nil
    @Binding var selected: [T]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [T] { query.isEmpty ? all : all.filter { name($0).localizedCaseInsensitiveContains(query) } }
    private var atCap: Bool { if let cap { return selected.count >= cap } else { return false } }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let cap, multi {
                            Text("Pick up to \(cap). \(selected.count) of \(cap) selected.")
                                .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        }
                        ForEach(filtered, id: \.self) { item in row(item) }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundStyle(BaselineColor.textMid) }
                if multi { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundStyle(BaselineColor.accent).bold() } }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        }
    }

    private func row(_ item: T) -> some View {
        let isSel = selected.contains(item)
        let locked = multi && atCap && !isSel
        return Button {
            if multi {
                if isSel { selected.removeAll { $0 == item } } else if !locked { selected.append(item) }
            } else {
                selected = [item]; dismiss()
            }
        } label: {
            HStack {
                Text(name(item)).font(.system(size: 15))
                    .foregroundStyle(locked ? BaselineColor.textFaint : BaselineColor.textHi)
                Spacer()
                if isSel { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(BaselineColor.accent) }
            }
            .padding(.vertical, 14)
            .opacity(locked ? 0.4 : 1)
            .overlay(alignment: .bottom) { Rectangle().fill(BaselineColor.line).frame(height: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }
}
