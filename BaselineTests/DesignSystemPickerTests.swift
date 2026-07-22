import Testing
@testable import Baseline

struct DesignSystemPickerTests {
    @Test func singleSelectionReplacesThePreviousValue() {
        let updated = TaxonomyPickerLogic.updatedSelection(
            ["barbell"],
            selecting: "sled",
            allowsMultiple: false,
            isDisabled: false
        )

        #expect(updated == ["sled"])
    }

    @Test func multipleSelectionIsUnlimitedAndTogglesValues() {
        let ids = ["duration", "distance", "pace", "power", "heart-rate"]
        let selected = ids.reduce(into: Set<String>()) { selection, id in
            selection = TaxonomyPickerLogic.updatedSelection(
                selection,
                selecting: id,
                allowsMultiple: true,
                isDisabled: false
            )
        }

        #expect(selected == Set(ids))

        let toggled = TaxonomyPickerLogic.updatedSelection(
            selected,
            selecting: "pace",
            allowsMultiple: true,
            isDisabled: false
        )
        #expect(toggled.contains("pace") == false)
        #expect(toggled.count == ids.count - 1)
    }

    @Test func disabledSelectionPreservesCurrentValues() {
        let current: Set<String> = ["biceps", "forearms"]
        let updated = TaxonomyPickerLogic.updatedSelection(
            current,
            selecting: "lats",
            allowsMultiple: true,
            isDisabled: true
        )

        #expect(updated == current)
    }

    @Test func searchMatchesTitlesAndSubtitlesUsingLocalizedRules() {
        let items = [
            PickerFixture(id: "lats", title: "Lats", subtitle: "back"),
            PickerFixture(id: "chest", title: "Chest", subtitle: "chest"),
            PickerFixture(id: "calves", title: "Calves", subtitle: "legs")
        ]

        let byTitle = TaxonomyPickerLogic.filteredItems(items, query: "LAT") { "\($0.title) \($0.subtitle)" }
        let bySubtitle = TaxonomyPickerLogic.filteredItems(items, query: "legs") { "\($0.title) \($0.subtitle)" }
        let all = TaxonomyPickerLogic.filteredItems(items, query: "   ") { "\($0.title) \($0.subtitle)" }

        #expect(byTitle.map(\.id) == ["lats"])
        #expect(bySubtitle.map(\.id) == ["calves"])
        #expect(all == items)
    }
}

private struct PickerFixture: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
}
