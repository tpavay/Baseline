import Foundation
import Testing
@testable import Baseline

struct MetricsTests {

    @Test func canonicalUnits() {
        #expect(MetricType.distance.canonicalUnit == .meters)
        #expect(MetricType.load.canonicalUnit == .kilograms)
        #expect(MetricType.duration.canonicalUnit == .seconds)
    }

    @Test func distanceConvertsBothWays() {
        #expect(abs(MetricConvert.fromCanonical(1609.344, .distance, to: .miles) - 1.0) < 0.0001)
        #expect(abs(MetricConvert.fromCanonical(1000, .distance, to: .kilometers) - 1.0) < 0.0001)
        #expect(abs(MetricConvert.toCanonical(1, .distance, from: .miles) - 1609.344) < 0.0001)
        #expect(abs(MetricConvert.toCanonical(5, .distance, from: .kilometers) - 5000) < 0.0001)
    }

    @Test func loadConvertsKgPounds() {
        #expect(abs(MetricConvert.fromCanonical(100, .load, to: .pounds) - 220.462) < 0.01)
        #expect(abs(MetricConvert.toCanonical(225, .load, from: .pounds) - 102.058) < 0.01)
    }

    @Test func rowingPacePerFiveHundredMetersRoundTripsCanonically() {
        let canonicalSecondsPerMeter = 102.0 / 500.0
        let displayed = MetricConvert.fromCanonical(
            canonicalSecondsPerMeter,
            .pace,
            to: .secondsPer500Meters
        )
        let restored = MetricConvert.toCanonical(
            displayed,
            .pace,
            from: .secondsPer500Meters
        )

        #expect(abs(displayed - 102) < 0.000_001)
        #expect(abs(restored - canonicalSecondsPerMeter) < 0.000_001)
        #expect(MetricFormat.value(restored, .pace, unit: .secondsPer500Meters) == "1:42/500m")
    }

    @Test func metricValuesStoreTypedAndEncodeAsObject() throws {
        var v = MetricValues()
        v[.distance] = 1000
        v.setInt(.reps, 8)
        #expect(v[.distance] == 1000)
        #expect(v.int(.reps) == 8)
        #expect(v.present.contains(.distance))
        // Canonical Codable round-trip; encodes as a keyed object, not an array.
        let data = try JSONEncoder().encode(v)
        #expect(String(data: data, encoding: .utf8)!.contains("distance"))
        #expect(try JSONDecoder().decode(MetricValues.self, from: data) == v)
    }
}

struct ExerciseCatalogTests {

    @Test func definitionsHaveUniqueStableIDsAndSearchTerms() {
        let ids = ExerciseCatalog.definitions.map(\.id)
        #expect(Set(ids).count == ids.count)

        var owners: [String: String] = [:]
        for definition in ExerciseCatalog.definitions {
            let searchTerms = Set(([definition.name] + definition.aliases).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })

            for searchTerm in searchTerms {
                if let existingOwner = owners[searchTerm], existingOwner != definition.id {
                    Issue.record("Search term '\(searchTerm)' belongs to both \(existingOwner) and \(definition.id).")
                } else {
                    owners[searchTerm] = definition.id
                }
            }
        }
    }

    @Test func resolvesCasualLanguageToStableIds() {
        #expect(ExerciseCatalog.resolve("spin bike").id == "stationary_bike")
        #expect(ExerciseCatalog.resolve("Concept2 Bike").id == "bike_erg")
        #expect(ExerciseCatalog.resolve("rower").id == "row")
        #expect(ExerciseCatalog.resolve("farmers carry").id == "farmers_carry")
        #expect(ExerciseCatalog.resolve("treadmill").id == "treadmill_run")
        #expect(ExerciseCatalog.resolve("wall ball").id == "wall_balls")
        #expect(ExerciseCatalog.resolve("air bike").id == "echo_bike")
        #expect(ExerciseCatalog.resolve("Echo Bike").id == "echo_bike")
        #expect(ExerciseCatalog.resolve("Dual DB Push Press").id == "dual_dumbbell_push_press")
        #expect(ExerciseCatalog.resolve("Dumbbell Push Press").id == "dual_dumbbell_push_press")
        #expect(ExerciseCatalog.resolve("box squat").id == "barbell_box_squat")
        #expect(ExerciseCatalog.resolve("db bench press").id == "dumbbell_bench_press")
        #expect(ExerciseCatalog.resolve("leg press").id == "leg_press")
        #expect(ExerciseCatalog.resolve("calf raises").id == "calf_raise")
        #expect(ExerciseCatalog.resolve("burpees over barbell lateral").id == "lateral_burpee_over_barbell")
        #expect(ExerciseCatalog.resolve("stepmill").id == "stair_stepper")
        #expect(ExerciseCatalog.resolve("box step overs").id == "box_step_over")
        #expect(ExerciseCatalog.resolve("hand release pushups").id == "hand_release_push_up")
        #expect(ExerciseCatalog.resolve("hanging leg raises").id == "hanging_leg_raise")
        #expect(ExerciseCatalog.resolve("plank").id == "plank")
        #expect(ExerciseCatalog.resolve("bike erg").id == "bike_erg")
        #expect(ExerciseCatalog.resolve("rope sled pull").id == "sled_pull")
        #expect(ExerciseCatalog.resolve("strict press").id == "barbell_overhead_press")
        #expect(ExerciseCatalog.resolve("front squat").id == "front_squat")
        #expect(ExerciseCatalog.resolve("kb swings").id == "kettlebell_swing")
        #expect(ExerciseCatalog.resolve("med ball slams").id == "medicine_ball_slam")
        #expect(ExerciseCatalog.resolve("goblet squats").id == "goblet_squat")
        #expect(ExerciseCatalog.resolve("walking lunges").id == "bodyweight_walking_lunge")
        #expect(ExerciseCatalog.resolve("dumbbell lunges").id == "dumbbell_walking_lunge")
        #expect(ExerciseCatalog.resolve("barbell lunges").id == "barbell_walking_lunge")
        #expect(ExerciseCatalog.resolve("hip thrusts").id == "barbell_hip_thrust")
        #expect(ExerciseCatalog.resolve("bodyweight hip thrust").id == "bodyweight_hip_thrust")
        #expect(ExerciseCatalog.resolve("single leg hip thrust").id == "single_leg_hip_thrust")
        #expect(ExerciseCatalog.resolve("one arm dumbbell row").id == "single_arm_dumbbell_row")
        #expect(ExerciseCatalog.resolve("Copenhagen").id == "isometric_hold")
    }

    @Test func unknownMovementFallsBackToGeneric() {
        #expect(ExerciseCatalog.resolve("landmine rainbow").id == "generic")
    }

    @Test func definitionsDeclareSupportedMetricsAndCategory() {
        let bike = ExerciseCatalog.definition(id: "stationary_bike")!
        #expect(bike.category == .cycling)
        #expect(bike.supported.contains(.distance))
        #expect(bike.defaults == [.duration, .distance])
        #expect(ExerciseCatalog.definition(id: "deadlift")?.category == .strength)
        #expect(ExerciseCatalog.definition(id: "sled_push")?.supported.contains(.distance) == true)
    }
}
