import SwiftUI

struct SubstituteExerciseFlow: View {
    let currentName: String
    let onSelect: (ExerciseDefinition) -> Void

    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category: ActivityCategory?
    @State private var showCustom = false

    private var results: [ExerciseDefinition] {
        store.searchDefinitions(query)
            .filter { category == nil || $0.category == category }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                VStack(spacing: 0) {
                    categoryPicker
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { definition in
                                selectionRow(definition)
                            }
                            createCustomRow
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .navigationTitle("Replace \(currentName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
            }
            .searchable(text: $query, prompt: "Search exercises")
            .navigationDestination(isPresented: $showCustom) {
                CustomExerciseForm(seedName: query, onCreate: select)
            }
        }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                categoryButton("All", category: nil)
                ForEach(ActivityCategory.allCases, id: \.self) { category in
                    categoryButton(category.rawValue.capitalized, category: category)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private func categoryButton(_ title: String, category value: ActivityCategory?) -> some View {
        Button(title) { category = value }
            .font(.subheadline)
            .foregroundStyle(category == value ? BaselineColor.base : BaselineColor.textMid)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Capsule().fill(category == value ? BaselineColor.accent : BaselineColor.surface))
    }

    private func selectionRow(_ definition: ExerciseDefinition) -> some View {
        Button { select(definition) } label: {
            HStack(spacing: 12) {
                ExerciseThumbnailView(definition: definition, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.name)
                        .font(.headline)
                        .foregroundStyle(BaselineColor.textHi)
                    Text(definition.category.rawValue.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(BaselineColor.textFaint)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(BaselineColor.textFaint)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Uses this exercise instead of \(currentName)")
        .overlay(alignment: .bottom) {
            Rectangle().fill(BaselineColor.line).frame(height: 1)
        }
    }

    private var createCustomRow: some View {
        Button("Create Custom Exercise", systemImage: "plus.circle") {
            showCustom = true
        }
        .font(.headline)
        .foregroundStyle(BaselineColor.accent)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .accessibilityHint("Creates a new exercise and uses it instead of \(currentName)")
    }

    private func select(_ definition: ExerciseDefinition) {
        onSelect(definition)
        dismiss()
    }
}
