import Foundation
import Testing
@testable import Baseline

@Suite("Exercise taxonomy")
struct ExerciseTaxonomyTests {
    @Test func taxonomyCanExpressEveryApprovedPickerOption() {
        let approvedEquipmentRawValues = [
            "bodyweight", "barbell", "barbellPlates", "dumbbell", "kettlebell", "medicineBall",
            "machine", "cable", "sled", "sandbag", "box", "band", "rope", "exerciseBall",
            "bosuBall", "hangboard", "bike", "rower", "skiErg", "treadmill", "other"
        ]
        #expect(Equipment.customCreationOptions.map(\.rawValue) == approvedEquipmentRawValues)
        #expect(Equipment.customCreationOptions.map(\.customCreationDisplayName) == [
            "None / bodyweight", "Barbell", "Barbell plates", "Dumbbell", "Kettlebell", "Medicine ball",
            "Machine", "Cable", "Sled", "Sandbag", "Box", "Bands", "Rope", "Exercise ball", "Bosu ball",
            "Hangboard", "Bike", "Rower", "Ski erg", "Treadmill", "Other"
        ])

        let approvedTagRawValues = [
            "hyrox", "crossFit", "powerlifting", "olympicWeightlifting", "strongman", "running",
            "cycling", "rowing", "conditioning", "warmUp", "coolDown", "mobility", "rehab", "unilateral"
        ]
        #expect(ExerciseTag.customCreationOptions.map(\.rawValue) == approvedTagRawValues)
        #expect(ExerciseTag.customCreationOptions.map(\.displayName) == [
            "HYROX", "CrossFit", "Powerlifting", "Olympic lifting", "Strongman", "Running", "Cycling",
            "Rowing", "Conditioning", "Warm-up", "Cool-down", "Mobility", "Rehab", "Unilateral"
        ])

        #expect(Muscle.abdominals.displayName == "Abs")
        #expect(MovementPattern.hold.displayName == "Hold / isometric")
        #expect(ExerciseLevel.expert.displayName == "Advanced")
        #expect(Equipment.bodyweight.customCreationDisplayName == "None / bodyweight")
        #expect(MetricType.heartRate.customCreationDisplayName == "Heart rate")
    }

    @Test func approvedCreationOptionsStayOrderedAndExcludeModelOnlyCases() {
        #expect(Muscle.customCreationOptions.map(\.rawValue) == [
            "chest", "lats", "upperBack", "traps", "lowerBack", "frontDelts", "sideDelts", "rearDelts",
            "biceps", "triceps", "forearms", "abdominals", "obliques", "glutes", "quadriceps",
            "hamstrings", "adductors", "abductors", "calves"
        ])
        #expect(Muscle.customCreationOptions.map(\.displayName) == [
            "Chest", "Lats", "Upper back", "Traps", "Lower back", "Front delts", "Side delts", "Rear delts",
            "Biceps", "Triceps", "Forearms", "Abs", "Obliques", "Glutes", "Quadriceps", "Hamstrings",
            "Adductors", "Abductors", "Calves"
        ])
        #expect(MetricType.customCreationOptions.map(\.rawValue) == [
            "reps", "load", "duration", "distance", "pace", "power", "calories", "cadence", "heartRate", "rpe"
        ])
        #expect(MetricType.customCreationOptions.map(\.customCreationDisplayName) == [
            "Reps", "Load", "Duration", "Distance", "Pace", "Power", "Calories", "Cadence", "Heart rate", "RPE"
        ])
        #expect(MovementPattern.customCreationOptions == [
            .squat, .hinge, .lunge, .push, .pull, .carry, .rotation, .gait, .hold
        ])
        #expect(MovementPattern.customCreationOptions.map(\.displayName) == [
            "Squat", "Hinge", "Lunge", "Push", "Pull", "Carry", "Rotation", "Gait", "Hold / isometric"
        ])
        #expect(ExerciseLevel.customCreationOptions == [.beginner, .intermediate, .expert])
        #expect(ExerciseLevel.customCreationOptions.map(\.displayName) == ["Beginner", "Intermediate", "Advanced"])

        #expect(Equipment.allCases.contains(.ezBar))
        #expect(Equipment.customCreationOptions.contains(.ezBar) == false)
        #expect(Muscle.allCases.contains(.fullBody))
        #expect(Muscle.customCreationOptions.contains(.fullBody) == false)
        #expect(MetricType.allCases.contains(.heartRateZoneTime))
        #expect(MetricType.customCreationOptions.contains(.heartRateZoneTime) == false)
        #expect(ExerciseTag.allCases.contains(.calisthenics))
        #expect(ExerciseTag.customCreationOptions.contains(.calisthenics) == false)
    }

    @Test func everyPreviouslyPersistedTaxonomyRawValueStillDecodes() throws {
        try expectRoundTrip(Muscle.self, rawValues: [
            "abdominals", "abductors", "adductors", "biceps", "calves", "chest", "forearms", "frontDelts",
            "fullBody", "glutes", "hamstrings", "hipFlexors", "lats", "lowerBack", "neck", "obliques",
            "quadriceps", "rearDelts", "sideDelts", "traps", "triceps", "upperBack"
        ])
        try expectRoundTrip(MovementPattern.self, rawValues: [
            "squat", "hinge", "lunge", "push", "pull", "carry", "rotation", "gait", "hold"
        ])
        try expectRoundTrip(Equipment.self, rawValues: [
            "barbell", "dumbbell", "kettlebell", "cable", "machine", "bodyweight", "band", "medicineBall",
            "ezBar", "bench", "sled", "sandbag", "box", "jumpRope", "trapBar", "pullUpBar", "bike", "rower",
            "skiErg", "treadmill", "stairStepper", "elliptical", "other"
        ])
        try expectRoundTrip(Modality.self, rawValues: ["resistance", "cardio", "hold", "mobility"])
        try expectRoundTrip(Mechanic.self, rawValues: ["compound", "isolation"])
        try expectRoundTrip(ExerciseLevel.self, rawValues: ["beginner", "intermediate", "expert"])
        try expectRoundTrip(ExerciseTag.self, rawValues: [
            "hyrox", "olympicWeightlifting", "powerlifting", "calisthenics", "plyometric", "mobility", "strongman"
        ])
        try expectRoundTrip(MetricType.self, rawValues: [
            "reps", "load", "duration", "distance", "calories", "heartRate", "heartRateZoneTime", "cadence",
            "power", "pace", "rpe"
        ])
    }

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
        #expect(resistance.isEmpty == false)
        for def in resistance {
            #expect(def.primaryMuscles.isEmpty == false, "\(def.id) is resistance but names no primary muscle")
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

    private func expectRoundTrip<Value>(
        _ type: Value.Type,
        rawValues: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws where Value: Codable & RawRepresentable, Value.RawValue == String {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for rawValue in rawValues {
            let storedData = Data("\"\(rawValue)\"".utf8)
            let decoded = try decoder.decode(Value.self, from: storedData)
            #expect(decoded.rawValue == rawValue, sourceLocation: sourceLocation)
            #expect(try encoder.encode(decoded) == storedData, sourceLocation: sourceLocation)
        }
    }
}
