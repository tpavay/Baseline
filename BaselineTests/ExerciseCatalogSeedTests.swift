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

    @Test func legacyStoredExerciseDefinitionStillDecodesWithOriginalRawValues() throws {
        let stored = Data(#"""
        {
          "id": "legacy_custom",
          "name": "Legacy custom exercise",
          "category": "strength",
          "supported": ["reps", "load", "heartRateZoneTime"],
          "defaults": ["reps", "load"],
          "aliases": ["legacy"],
          "primaryMuscles": ["abdominals"],
          "secondaryMuscles": ["hipFlexors"],
          "patterns": ["hold"],
          "equipment": ["ezBar", "bodyweight"],
          "mechanic": "isolation",
          "modality": "resistance",
          "level": "expert",
          "tags": ["calisthenics", "plyometric"]
        }
        """#.utf8)

        let definition = try JSONDecoder().decode(ExerciseDefinition.self, from: stored)

        #expect(definition.primaryMuscles == [.abdominals])
        #expect(definition.secondaryMuscles == [.hipFlexors])
        #expect(definition.patterns == [.hold])
        #expect(definition.equipment == [.ezBar, .bodyweight])
        #expect(definition.level == .expert)
        #expect(definition.tags == [.calisthenics, .plyometric])
        #expect(definition.supported == [.reps, .load, .heartRateZoneTime])
    }

    @Test func schemaOneCatalogCanDecodeApprovedAdditiveTaxonomyValues() throws {
        let definition = ExerciseDefinition(
            id: "approved_custom",
            name: "Approved custom exercise",
            category: .strength,
            supported: [.reps, .heartRate],
            defaults: [.reps],
            aliases: [],
            primaryMuscles: [.abdominals],
            patterns: [.hold],
            equipment: [.barbellPlates, .rope, .exerciseBall, .bosuBall, .hangboard],
            modality: .resistance,
            level: .expert,
            tags: [.crossFit, .running, .cycling, .rowing, .conditioning, .warmUp, .coolDown, .rehab, .unilateral]
        )
        let manifest = ExerciseCatalogManifest(
            schemaVersion: ExerciseCatalog.supportedSchemaVersion,
            version: 1,
            exercises: [definition]
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ExerciseCatalogManifest.self, from: data)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.exercises == [definition])
    }
}
