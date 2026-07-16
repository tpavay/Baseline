import Foundation
import Testing
@testable import Baseline

@Suite("Exercise catalog seed")
struct ExerciseCatalogSeedTests {
    @Test func bundlesTheFullImportedLibraryOffline() {
        // Curated built-ins (~51) plus the imported Free Exercise DB set (~870), deduped. Far more than the
        // curated count alone — proving the bundled resource decoded and merged.
        #expect(ExerciseCatalog.seedDefinitions.count > 800)
    }

    @Test func curatedBuiltInsSurviveAndWinOverImports() {
        // Curated identity and aliases are preserved; an import never shadows a curated built-in.
        #expect(ExerciseCatalog.definition(id: "deadlift") != nil)
        #expect(ExerciseCatalog.resolve("spin bike").id == "stationary_bike")
    }

    @Test func importedExercisesAreInTheCatalog() {
        // An exercise that exists only in the imported Free Exercise DB set.
        let imported = ExerciseCatalog.definition(id: "barbell_bench_press_medium_grip")
        #expect(imported != nil)
        #expect(imported?.modality == .resistance)
        #expect(imported?.primaryMuscles == [.chest])
    }

    @Test func importedExercisesAreValidForLoggingAndClassification() {
        // Every merged exercise must be usable: metrics to log + a modality/level for filtering.
        for def in ExerciseCatalog.seedDefinitions {
            #expect(!def.supported.isEmpty, "\(def.id) supports no metrics")
            #expect(def.modality != nil, "\(def.id) missing modality")
            #expect(def.level != nil, "\(def.id) missing level")
        }
    }
}
