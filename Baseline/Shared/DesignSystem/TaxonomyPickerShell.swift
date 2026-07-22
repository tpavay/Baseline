import SwiftUI

/// Reusable navigation, search, and selection behavior for taxonomy pickers.
struct TaxonomyPickerShell<Item: Identifiable>: View {
    enum SelectionMode {
        case single
        case multiple
    }

    let title: String
    let items: [Item]
    @Binding var selection: Set<Item.ID>
    let selectionMode: SelectionMode
    let isSearchEnabled: Bool
    let itemTitle: (Item) -> String
    let itemSubtitle: (Item) -> String?
    let itemIcon: (Item) -> Image
    let disabledReason: (Item) -> String?
    let onBack: () -> Void
    let onDone: (() -> Void)?

    @State private var searchText = ""

    init(
        title: String,
        items: [Item],
        selection: Binding<Set<Item.ID>>,
        selectionMode: SelectionMode,
        isSearchEnabled: Bool = true,
        itemTitle: @escaping (Item) -> String,
        itemSubtitle: @escaping (Item) -> String? = { _ in nil },
        itemIcon: @escaping (Item) -> Image,
        disabledReason: @escaping (Item) -> String? = { _ in nil },
        onBack: @escaping () -> Void,
        onDone: (() -> Void)? = nil
    ) {
        self.title = title
        self.items = items
        _selection = selection
        self.selectionMode = selectionMode
        self.isSearchEnabled = isSearchEnabled
        self.itemTitle = itemTitle
        self.itemSubtitle = itemSubtitle
        self.itemIcon = itemIcon
        self.disabledReason = disabledReason
        self.onBack = onBack
        self.onDone = onDone
    }

    var body: some View {
        let visibleItems = TaxonomyPickerLogic.filteredItems(
            items,
            query: searchText,
            searchableText: { item in
                [itemTitle(item), itemSubtitle(item)]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
        )

        VStack(spacing: 0) {
            if isSearchEnabled {
                HStack(spacing: BaselineSpacing.xSmall) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: BaselineSize.iconGlyph))
                        .foregroundStyle(BaselineColor.textFaint)
                        .accessibilityHidden(true)

                    TextField("Search \(title)", text: $searchText)
                        .baselineTypography(.proseSmall)
                        .foregroundStyle(BaselineColor.textHi)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, BaselineSpacing.medium)
                .frame(minHeight: BaselineSize.minimumTapTarget)
                .background {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(BaselineColor.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 11)
                                .stroke(BaselineColor.line, lineWidth: BaselineSize.hairline)
                        }
                }
                .padding(.horizontal, BaselineSpacing.large)
                .padding(.vertical, BaselineSpacing.small)
            }

            if visibleItems.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No options match your search.")
                )
                .foregroundStyle(BaselineColor.textMid)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleItems) { item in
                            let reason = disabledReason(item)
                            TaxonomyPickerRow(
                                icon: itemIcon(item),
                                title: itemTitle(item),
                                subtitle: itemSubtitle(item),
                                isSelected: selection.contains(item.id),
                                disabledReason: reason,
                                action: {
                                    selection = TaxonomyPickerLogic.updatedSelection(
                                        selection,
                                        selecting: item.id,
                                        allowsMultiple: selectionMode == .multiple,
                                        isDisabled: reason != nil
                                    )
                                }
                            )
                        }
                    }
                    .padding(.horizontal, BaselineSpacing.large)
                    .padding(.bottom, BaselineSpacing.screen)
                }
            }
        }
        .background(BaselineColor.base.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", systemImage: "chevron.left", action: onBack)
                    .labelStyle(.iconOnly)
                    .tint(BaselineColor.textMid)
                    .frame(minWidth: BaselineSize.minimumTapTarget, minHeight: BaselineSize.minimumTapTarget)
            }

            if let onDone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                        .baselineTypography(.button)
                        .tint(BaselineColor.accent)
                        .frame(minHeight: BaselineSize.minimumTapTarget)
                }
            }
        }
    }

}

/// Pure picker filtering and selection transitions.
enum TaxonomyPickerLogic {
    static func filteredItems<Item>(
        _ items: [Item],
        query: String,
        searchableText: (Item) -> String
    ) -> [Item] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return items }
        return items.filter { searchableText($0).localizedStandardContains(trimmedQuery) }
    }

    static func updatedSelection<ID: Hashable>(
        _ current: Set<ID>,
        selecting id: ID,
        allowsMultiple: Bool,
        isDisabled: Bool
    ) -> Set<ID> {
        guard isDisabled == false else { return current }

        if allowsMultiple == false {
            return [id]
        }

        var updated = current
        if updated.contains(id) {
            updated.remove(id)
        } else {
            updated.insert(id)
        }
        return updated
    }
}
