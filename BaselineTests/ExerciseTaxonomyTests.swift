import Foundation
import Testing
@testable import Baseline

@Suite("Exercise taxonomy")
struct ExerciseTaxonomyTests {
    @Test func everyBuiltInExerciseIsClassifiedWithAModalityAndLevel() {
        // Equipment may legitimately be empty (running and swimming need none); modality and level are
        // the invariants that must hold for every built-in.
        for def in ExerciseCatalog.definitions {
            #expect(def.modality != nil, "\(def.id) is missing a modality")
            #expect(def.level != nil, "\(def.id) is missing a level")
        }
    }

    @Test func resistanceExercisesNameTheMusclesTheyWork() {
        let resistance = ExerciseCatalog.definitions.filter { $0.modality == .resistance }
        #expect(!resistance.isEmpty)
        for def in resistance {
            #expect(!def.primaryMuscles.isEmpty, "\(def.id) is resistance but names no primary muscle")
        }
    }

    @Test func bikesShareBikeEquipmentSoWeeklyTotalsRollUp() {
        for id in ["stationary_bike", "outdoor_bike", "bike_erg", "echo_bike"] {
            #expect(
                ExerciseCatalog.definition(id: id)?.equipment.contains(.bike) == true,
                "\(id) should map to .bike equipment"
            )
        }
    }

    @Test func cardioIsFirstClassAndCarriesTheCardioModality() {
        for id in ["stationary_bike", "run", "swim", "row", "ski_erg", "stair_stepper", "elliptical", "treadmill_run"] {
            #expect(ExerciseCatalog.definition(id: id)?.modality == .cardio, "\(id) should be cardio")
        }
    }

    @Test func hyroxStationsAreTagged() {
        for id in ["sled_push", "sled_pull", "wall_balls", "ski_erg", "row", "sandbag_lunge",
                   "burpee_broad_jump", "farmers_carry"] {
            #expect(
                ExerciseCatalog.definition(id: id)?.tags.contains(.hyrox) == true,
                "\(id) should carry the HYROX tag"
            )
        }
    }

    @Test func compoundLiftsCanCarryTwoPatterns() {
        #expect(ExerciseCatalog.definition(id: "dual_db_thruster")?.patterns == [.squat, .push])
        #expect(ExerciseCatalog.definition(id: "wall_balls")?.patterns == [.squat, .push])
    }

    @Test func everyMuscleHasARegionAndTheThreeRegionsPartitionTheList() {
        let byRegion = Dictionary(grouping: Muscle.allCases, by: \.region)
        let total = MuscleRegion.allCases.reduce(0) { $0 + (byRegion[$1]?.count ?? 0) }
        #expect(total == Muscle.allCases.count)
        #expect(byRegion[.systemic] == [.fullBody])
        #expect(byRegion[.anterior]?.isEmpty == false)
        #expect(byRegion[.posterior]?.isEmpty == false)
    }

    @Test func swimIsBeginnerAndBoxStepOverIsIntermediate() {
        #expect(ExerciseCatalog.definition(id: "swim")?.level == .beginner)
        #expect(ExerciseCatalog.definition(id: "box_step_over")?.level == .intermediate)
    }

    @Test func modalityInfersFromMetrics() {
        #expect(Modality.inferred(fromMetrics: [.reps, .load, .rpe]) == .resistance)
        #expect(Modality.inferred(fromMetrics: [.distance, .pace, .duration]) == .cardio)
        #expect(Modality.inferred(fromMetrics: [.duration, .rpe]) == .hold)
        #expect(Modality.inferred(fromMetrics: [.distance, .load, .duration]) == .resistance) // loaded carry
    }

    @Test @MainActor func customExerciseCarriesItsTaxonomy() {
        let store = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "test.custom.\(UUID().uuidString)")!)
        let def = store.createCustomDefinition(
            name: "Single-Arm Sled Drag",
            supported: [.distance, .load, .duration],
            equipment: [.sled],
            primaryMuscles: [.lats, .quadriceps],
            secondaryMuscles: [.biceps, .forearms],
            patterns: [.pull, .gait],
            tags: [.hyrox],
            level: .intermediate)
        #expect(def.equipment == [.sled])
        #expect(def.primaryMuscles == [.lats, .quadriceps])
        #expect(def.secondaryMuscles == [.biceps, .forearms])
        #expect(def.patterns == [.pull, .gait])
        #expect(def.tags == [.hyrox])
        #expect(def.level == .intermediate)
        #expect(def.modality == .resistance) // .load present
        #expect(def.category == .strength)   // legacy value derived from modality
    }
}
