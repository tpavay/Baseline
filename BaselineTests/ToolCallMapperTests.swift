import Foundation
import Testing
@testable import Baseline

struct ToolCallMapperTests {

    @Test func mapsSimpleCalls() {
        #expect(ToolCallMapper.map(name: "get_today", input: [:]) == .getToday)
        #expect(ToolCallMapper.map(name: "explain", input: [:]) == .explain)
        #expect(ToolCallMapper.map(name: "set_traveling", input: ["traveling": true]) == .setTraveling(true))
        #expect(ToolCallMapper.map(name: "set_illness", input: ["illness": true]) == .setIllness(true))
        #expect(ToolCallMapper.map(name: "set_note", input: ["note": "slept badly"]) == .setNote("slept badly"))
    }

    @Test func mapsRetrievalAndActionTools() {
        #expect(ToolCallMapper.map(name: "get_sleep", input: ["nights_ago": 1]) == .getSleep(nightsAgo: 1))
        #expect(ToolCallMapper.map(name: "get_sleep", input: [:]) == .getSleep(nightsAgo: 0))
        #expect(ToolCallMapper.map(name: "get_hrv_readings", input: ["limit": 5]) == .getHRVReadings(limit: 5))
        #expect(ToolCallMapper.map(name: "get_resting_heart_rate", input: ["days": 14]) == .getRestingHeartRate(days: 14))
        #expect(ToolCallMapper.map(name: "open_apple_health_setup", input: [:]) == .openAppleHealthSetup)
    }

    @Test func mapsWorkoutTools() {
        #expect(ToolCallMapper.map(name: "create_workout", input: ["title": "Push"]) == .createWorkout(title: "Push", goal: nil, replaceExisting: false))
        #expect(ToolCallMapper.map(name: "create_workout", input: ["title": "Push", "replace_existing": true]) == .createWorkout(title: "Push", goal: nil, replaceExisting: true))
        #expect(ToolCallMapper.map(name: "add_block", input: ["name": "Strength"]) == .addBlock(name: "Strength", intent: nil))
        #expect(ToolCallMapper.map(name: "add_exercise", input: ["block": "Stations", "name": "Overhead carry", "distance_m": 150])
                == .addExercise(block: "Stations", name: "Overhead carry", sets: nil, reps: nil, load: nil, durationSeconds: nil, distanceMeters: 150))
        #expect(ToolCallMapper.map(name: "move_exercise", input: ["exercise": "Bench", "to_block": "Warm-up"])
                == .moveExercise(exercise: "Bench", toBlock: "Warm-up"))
        #expect(ToolCallMapper.map(name: "replace_exercise", input: [
            "exercise": "Treadmill Run", "replacement": "Run", "replace_all": true,
        ]) == .replaceExercise(exercise: "Treadmill Run", replacement: "Run", block: nil, replaceAll: true))
        #expect(ToolCallMapper.map(name: "replace_exercise", input: [
            "exercise": "Treadmill Run", "replacement": "Run", "block": "Warm-up",
        ]) == .replaceExercise(exercise: "Treadmill Run", replacement: "Run", block: "Warm-up", replaceAll: false))
        #expect(ToolCallMapper.map(name: "update_set", input: ["exercise": "Row", "set_number": 1, "distance_m": 1000])
                == .updateSet(exercise: "Row", setNumber: 1, reps: nil, load: nil, durationSeconds: nil, distanceMeters: 1000, rpe: nil))
        #expect(ToolCallMapper.map(name: "require_all_options", input: ["choice": "Option B"])
                == .requireAllOptions(choice: "Option B"))
        #expect(ToolCallMapper.map(name: "get_current_workout", input: [:]) == .getCurrentWorkout)
        #expect(ToolCallMapper.map(name: "create_workout", input: [:]) == nil)   // missing title → rejected
    }

    @Test func mapsExerciseCatalogTools() {
        #expect(ToolCallMapper.map(name: "search_exercises", input: ["query": "bench"])
                == .searchExercises(query: "bench", muscle: nil, equipment: nil, modality: nil,
                                    pattern: nil, tag: nil, level: nil))
        #expect(ToolCallMapper.map(name: "search_exercises", input: ["muscle": "quadriceps", "equipment": "barbell"])
                == .searchExercises(query: nil, muscle: "quadriceps", equipment: "barbell", modality: nil,
                                    pattern: nil, tag: nil, level: nil))
        #expect(ToolCallMapper.map(name: "search_exercises", input: [
            "query": "sled", "muscle": "glutes", "equipment": "sled", "modality": "resistance",
            "pattern": "push", "tag": "hyrox", "level": "intermediate",
        ]) == .searchExercises(query: "sled", muscle: "glutes", equipment: "sled", modality: "resistance",
                               pattern: "push", tag: "hyrox", level: "intermediate"))
        // No params is a valid browse ("what exercises do you have?"), not a malformed call.
        #expect(ToolCallMapper.map(name: "search_exercises", input: [:])
                == .searchExercises(query: nil, muscle: nil, equipment: nil, modality: nil,
                                    pattern: nil, tag: nil, level: nil))
        // Blank strings are how models write "omitted" - treated as absent, not as a query for "".
        #expect(ToolCallMapper.map(name: "search_exercises", input: ["query": "  ", "muscle": ""])
                == .searchExercises(query: nil, muscle: nil, equipment: nil, modality: nil,
                                    pattern: nil, tag: nil, level: nil))
        #expect(ToolCallMapper.map(name: "search_exercises", input: ["query": " bench "])
                == .searchExercises(query: "bench", muscle: nil, equipment: nil, modality: nil,
                                    pattern: nil, tag: nil, level: nil))

        #expect(ToolCallMapper.map(name: "get_exercise", input: ["name": "deadlift"]) == .getExercise(name: "deadlift", id: nil))
        #expect(ToolCallMapper.map(name: "get_exercise", input: ["id": "bench_press"]) == .getExercise(name: nil, id: "bench_press"))
        #expect(ToolCallMapper.map(name: "get_exercise", input: [:]) == nil)                 // nothing to look up
        #expect(ToolCallMapper.map(name: "get_exercise", input: ["name": " "]) == nil)       // blank is nothing
    }

    @Test func mapsSleepAndCheckIn() {
        #expect(ToolCallMapper.map(name: "set_sleep", input: ["hours": 6.5]) == .setSleep(hours: 6.5))
        #expect(ToolCallMapper.map(name: "set_sleep", input: ["hours": 4]) == .setSleep(hours: 4))
        #expect(ToolCallMapper.map(name: "set_sleep", input: ["hours": NSNull()]) == .setSleep(hours: nil))
        // Partial check-in: only the fields the athlete described.
        #expect(ToolCallMapper.map(name: "set_checkin", input: ["energy": 2, "stress": 1])
                == .setCheckIn(energy: 2, mood: nil, stress: 1, soreness: nil))
    }

    @Test func mapsTimeIncludingNullAndDouble() {
        #expect(ToolCallMapper.map(name: "set_time_available", input: ["minutes": 30]) == .setTimeAvailable(30))
        #expect(ToolCallMapper.map(name: "set_time_available", input: ["minutes": 30.0]) == .setTimeAvailable(30))
        #expect(ToolCallMapper.map(name: "set_time_available", input: ["minutes": NSNull()]) == .setTimeAvailable(nil))
    }

    @Test func mapsEquipmentArray() {
        #expect(ToolCallMapper.map(name: "set_equipment", input: ["equipment": ["gym", "barbell"]]) == .setEquipment(["gym", "barbell"]))
        #expect(ToolCallMapper.map(name: "set_equipment", input: ["equipment": NSNull()]) == .setEquipment(nil))
    }

    @Test func mapsUpsertConstraint() {
        let call = ToolCallMapper.map(name: "upsert_constraint",
                                      input: ["kind": "injury", "location": "right Achilles",
                                              "severity": 2, "affectsTraining": true])
        #expect(call == .upsertConstraint(id: nil, kind: .injury, location: "right Achilles",
                                          severity: 2, affectsTraining: true))
    }

    @Test func rejectsMalformedOrUnknown() {
        #expect(ToolCallMapper.map(name: "upsert_constraint", input: ["kind": "injury"]) == nil)          // no location
        #expect(ToolCallMapper.map(name: "upsert_constraint", input: ["location": "knee", "kind": "sprain",
                                                                      "severity": 1, "affectsTraining": true]) == nil) // bad kind
        #expect(ToolCallMapper.map(name: "resolve_constraint", input: ["id": "not-a-uuid"]) == nil)
        #expect(ToolCallMapper.map(name: "replace_exercise", input: ["exercise": "Run"]) == nil)
        #expect(ToolCallMapper.map(name: "delete_everything", input: [:]) == nil)                          // unknown tool
    }
}
