import SwiftUI

struct CustomExerciseTaxonomyPicker<Value: Hashable>: View {
    let title: String
    let options: [CustomExerciseTaxonomyOption<Value>]
    let allowsMultiple: Bool
    let isSearchEnabled: Bool
    let searchPrompt: String?
    let selectionLimit: Int?
    @Binding var selected: [Value]
    let unavailableReason: (Value) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<Value>

    init(
        title: String,
        options: [CustomExerciseTaxonomyOption<Value>],
        allowsMultiple: Bool,
        isSearchEnabled: Bool,
        searchPrompt: String? = nil,
        selectionLimit: Int? = nil,
        selected: Binding<[Value]>,
        unavailableReason: @escaping (Value) -> String? = { _ in nil }
    ) {
        self.title = title
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.isSearchEnabled = isSearchEnabled
        self.searchPrompt = searchPrompt
        self.selectionLimit = selectionLimit
        _selected = selected
        self.unavailableReason = unavailableReason
        _selectedIDs = State(initialValue: Set(selected.wrappedValue))
    }

    var body: some View {
        TaxonomyPickerShell(
            title: title,
            items: options,
            selection: $selectedIDs,
            selectionMode: selectionMode,
            isSearchEnabled: isSearchEnabled,
            searchPrompt: searchPrompt,
            itemTitle: { option in option.title },
            itemSubtitle: { option in option.subtitle },
            itemIcon: { option in option.icon },
            disabledReason: { option in disabledReason(option) },
            onSelect: { id in singleSelect(id) },
            onBack: { dismiss() },
            onDone: doneAction
        )
        .onChange(of: selectedIDs) { _, newValue in
            updateSelection(newValue)
        }
    }

    private var selectionMode: TaxonomyPickerShell<CustomExerciseTaxonomyOption<Value>>.SelectionMode {
        allowsMultiple ? .multiple : .single
    }

    private var doneAction: (() -> Void)? {
        allowsMultiple ? { dismiss() } : nil
    }

    private func disabledReason(_ option: CustomExerciseTaxonomyOption<Value>) -> String? {
        if let unavailableReason = unavailableReason(option.id) {
            return unavailableReason
        }
        guard let selectionLimit,
              selectedIDs.count >= selectionLimit,
              selectedIDs.contains(option.id) == false else {
            return nil
        }
        return "Pick up to \(selectionLimit)"
    }

    private func updateSelection(_ newValue: Set<Value>) {
        selected = CustomExercisePickerLogic.orderedSelection(
            options: options.map(\.id),
            selectedIDs: newValue,
            previousSelection: selected
        )
    }

    private func singleSelect(_ id: Value) {
        guard allowsMultiple == false else { return }
        selected = CustomExercisePickerLogic.orderedSelection(
            options: options.map(\.id),
            selectedIDs: [id],
            previousSelection: selected
        )
        dismiss()
    }
}
