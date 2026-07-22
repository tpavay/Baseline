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
        let revision = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let inputRevision = revision.uuidString
        #expect(ToolCallMapper.map(name: "create_workout", input: ["title": "Push"]) == .createWorkout(title: "Push", goal: nil, replaceExisting: false))
        #expect(ToolCallMapper.map(name: "create_workout", input: ["title": "Push", "replace_existing": true, "expected_revision_token": inputRevision]) == .createWorkout(title: "Push", goal: nil, replaceExisting: true, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "add_block", input: ["name": "Strength", "expected_revision_token": inputRevision]) == .addBlock(name: "Strength", intent: nil, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "add_exercise", input: ["block": "Stations", "name": "Overhead carry", "distance_m": 150, "expected_revision_token": inputRevision])
                == .addExercise(block: "Stations", name: "Overhead carry", sets: nil, reps: nil, load: nil, durationSeconds: nil, distanceMeters: 150, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "move_exercise", input: ["exercise": "Bench", "to_block": "Warm-up", "expected_revision_token": inputRevision])
                == .moveExercise(exercise: "Bench", exerciseID: nil, toBlock: "Warm-up", toBlockID: nil, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "replace_exercise", input: [
            "exercise": "Treadmill Run", "replacement": "Run", "replace_all": true, "expected_revision_token": inputRevision,
        ]) == .replaceExercise(exercise: "Treadmill Run", exerciseID: nil, replacement: "Run", block: nil, replaceAll: true, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "replace_exercise", input: [
            "exercise": "Treadmill Run", "replacement": "Run", "block": "Warm-up", "expected_revision_token": inputRevision,
        ]) == .replaceExercise(exercise: "Treadmill Run", exerciseID: nil, replacement: "Run", block: "Warm-up", replaceAll: false, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "update_set", input: ["exercise": "Row", "set_number": 1, "distance_m": 1000, "expected_revision_token": inputRevision])
                == .updateSet(exercise: "Row", setNumber: 1, setID: nil, reps: nil, load: nil, durationSeconds: nil, distanceMeters: 1000, rpe: nil, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "require_all_options", input: ["choice": "Option B", "expected_revision_token": inputRevision])
                == .requireAllOptions(choice: "Option B", expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "undo_workout_mutation", input: ["mutation_id": revision.uuidString, "expected_revision_token": inputRevision])
                == .undoWorkoutMutation(mutationID: revision, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "get_current_workout", input: [:]) == .getCurrentWorkout)
        #expect(ToolCallMapper.map(name: "create_workout", input: [:]) == nil)   // missing title → rejected
        #expect(ToolCallMapper.map(name: "create_workout", input: ["title": "Push", "replace_existing": true]) == nil)
        #expect(ToolCallMapper.map(name: "add_block", input: ["name": "Strength"]) == nil)
    }

    @Test func mapsStableWorkoutInstanceIDs() throws {
        let exerciseID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let blockID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let setID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

        #expect(ToolCallMapper.map(name: "move_exercise", input: [
            "exercise": "Run",
            "exercise_id": exerciseID.uuidString,
            "to_block": "Recovery",
            "to_block_id": blockID.uuidString,
            "expected_revision_token": revision.uuidString,
        ]) == .moveExercise(exercise: "Run", exerciseID: exerciseID, toBlock: "Recovery", toBlockID: blockID, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "replace_exercise", input: [
            "exercise": "Run",
            "exercise_id": exerciseID.uuidString,
            "replacement": "Treadmill Run",
            "expected_revision_token": revision.uuidString,
        ]) == .replaceExercise(
            exercise: "Run",
            exerciseID: exerciseID,
            replacement: "Treadmill Run",
            block: nil,
            replaceAll: false,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "remove_exercise", input: [
            "exercise": "Run",
            "exercise_id": exerciseID.uuidString,
            "expected_revision_token": revision.uuidString,
        ]) == .removeExercise(exercise: "Run", exerciseID: exerciseID, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "update_set", input: [
            "exercise": "Run",
            "set_number": 2,
            "set_id": setID.uuidString,
            "duration_seconds": 180,
            "expected_revision_token": revision.uuidString,
        ]) == .updateSet(
            exercise: "Run",
            setNumber: 2,
            setID: setID,
            reps: nil,
            load: nil,
            durationSeconds: 180,
            distanceMeters: nil,
            rpe: nil,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "update_logging_config", input: [
            "exercise": "Run",
            "exercise_id": exerciseID.uuidString,
            "enabled_metrics": ["duration"],
            "expected_revision_token": revision.uuidString,
        ]) == .updateLoggingConfig(
            exercise: "Run",
            exerciseID: exerciseID,
            enabledMetrics: [.duration],
            units: [:],
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "set_metric_value", input: [
            "exercise": "Run",
            "set_number": 2,
            "set_id": setID.uuidString,
            "metric": "distance",
            "value": 1_000,
            "expected_revision_token": revision.uuidString,
        ]) == .setMetricValue(
            exercise: "Run",
            setNumber: 2,
            setID: setID,
            metric: .distance,
            value: 1_000,
            unit: nil,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "remove_metric", input: [
            "exercise": "Run",
            "exercise_id": exerciseID.uuidString,
            "metric": "pace",
            "expected_revision_token": revision.uuidString,
        ]) == .removeMetric(exercise: "Run", exerciseID: exerciseID, metric: .pace, expectedRevisionToken: revision))
    }

    @Test func mapsMetadataPatchesWithoutCollapsingOmittedAndNull() throws {
        let blockID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let exerciseID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

        #expect(ToolCallMapper.map(name: "update_workout_metadata", input: [
            "title": "Race prep",
            "goal": NSNull(),
            "expected_revision_token": revision.uuidString,
        ]) == .updateWorkoutMetadata(
            title: .set("Race prep"),
            goal: .clear,
            guidance: .unchanged,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "update_block_metadata", input: [
            "block_id": blockID.uuidString,
            "intent": "threshold",
            "guidance": NSNull(),
            "expected_revision_token": revision.uuidString,
        ]) == .updateBlockMetadata(
            blockID: blockID,
            name: .unchanged,
            intent: .set("threshold"),
            guidance: .clear,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "update_exercise_metadata", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "display_label": NSNull(),
            "guidance": "Stay tall",
            "expected_revision_token": revision.uuidString,
        ]) == .updateExerciseMetadata(
            exerciseInstanceID: exerciseID,
            displayLabel: .clear,
            guidance: .set("Stay tall"),
            expectedRevisionToken: revision
        ))
    }

    @Test func mapsEveryNullableMetadataFieldAcrossAllThreeStates() throws {
        let blockID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let exerciseID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

        func workoutPatches(_ fields: [String: Any]) -> (MetadataPatch<String>, MetadataPatch<String>)? {
            var input = fields
            input["expected_revision_token"] = revision.uuidString
            guard case .updateWorkoutMetadata(_, let goal, let guidance, _)? =
                    ToolCallMapper.map(name: "update_workout_metadata", input: input) else { return nil }
            return (goal, guidance)
        }

        func blockPatches(_ fields: [String: Any]) -> (MetadataPatch<String>, MetadataPatch<String>)? {
            var input = fields
            input["block_id"] = blockID.uuidString
            input["expected_revision_token"] = revision.uuidString
            guard case .updateBlockMetadata(_, _, let intent, let guidance, _)? =
                    ToolCallMapper.map(name: "update_block_metadata", input: input) else { return nil }
            return (intent, guidance)
        }

        func exercisePatches(_ fields: [String: Any]) -> (MetadataPatch<String>, MetadataPatch<String>)? {
            var input = fields
            input["exercise_instance_id"] = exerciseID.uuidString
            input["expected_revision_token"] = revision.uuidString
            guard case .updateExerciseMetadata(_, let displayLabel, let guidance, _)? =
                    ToolCallMapper.map(name: "update_exercise_metadata", input: input) else { return nil }
            return (displayLabel, guidance)
        }

        #expect(workoutPatches(["guidance": "Keep steady"])?.0 == .unchanged)
        #expect(workoutPatches(["goal": "Build capacity"])?.0 == .set("Build capacity"))
        #expect(workoutPatches(["goal": NSNull()])?.0 == .clear)
        #expect(workoutPatches(["goal": "Build capacity"])?.1 == .unchanged)
        #expect(workoutPatches(["guidance": "Keep steady"])?.1 == .set("Keep steady"))
        #expect(workoutPatches(["guidance": NSNull()])?.1 == .clear)

        #expect(blockPatches(["guidance": "Stay aerobic"])?.0 == .unchanged)
        #expect(blockPatches(["intent": "threshold"])?.0 == .set("threshold"))
        #expect(blockPatches(["intent": NSNull()])?.0 == .clear)
        #expect(blockPatches(["intent": "threshold"])?.1 == .unchanged)
        #expect(blockPatches(["guidance": "Stay aerobic"])?.1 == .set("Stay aerobic"))
        #expect(blockPatches(["guidance": NSNull()])?.1 == .clear)

        #expect(exercisePatches(["guidance": "Stay tall"])?.0 == .unchanged)
        #expect(exercisePatches(["display_label": "Station A"])?.0 == .set("Station A"))
        #expect(exercisePatches(["display_label": NSNull()])?.0 == .clear)
        #expect(exercisePatches(["display_label": "Station A"])?.1 == .unchanged)
        #expect(exercisePatches(["guidance": "Stay tall"])?.1 == .set("Stay tall"))
        #expect(exercisePatches(["guidance": NSNull()])?.1 == .clear)

        // Blank strings on nullable fields normalize to clear, matching the manual editor,
        // so an agent write can never store a value the UI treats as absent.
        #expect(workoutPatches(["goal": ""])?.0 == .clear)
        #expect(workoutPatches(["guidance": "  "])?.1 == .clear)
        #expect(blockPatches(["intent": ""])?.0 == .clear)
        #expect(blockPatches(["guidance": " \n"])?.1 == .clear)
        #expect(exercisePatches(["display_label": ""])?.0 == .clear)
        #expect(exercisePatches(["guidance": "   "])?.1 == .clear)
    }

    @Test func rejectsInvalidMetadataPatches() {
        let id = UUID().uuidString

        #expect(ToolCallMapper.map(name: "update_workout_metadata", input: [
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_workout_metadata", input: [
            "title": NSNull(),
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_workout_metadata", input: [
            "title": "  ",
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_block_metadata", input: [
            "block_id": id,
            "name": NSNull(),
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_block_metadata", input: [
            "block_id": "not-a-uuid",
            "intent": "easy",
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_exercise_metadata", input: [
            "exercise_instance_id": id,
            "guidance": 42,
            "expected_revision_token": id,
        ]) == nil)
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
        // Neither parameter still maps: AgentTools explains the miss by name, where a nil here would
        // reach the model as the generic "that tool call wasn't valid". Blanks are absent, not "".
        #expect(ToolCallMapper.map(name: "get_exercise", input: [:]) == .getExercise(name: nil, id: nil))
        #expect(ToolCallMapper.map(name: "get_exercise", input: ["name": " "]) == .getExercise(name: nil, id: nil))
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
        #expect(ToolCallMapper.map(name: "undo_workout_mutation", input: [
            "mutation_id": UUID().uuidString,
            "expected_revision_token": "not-a-uuid",
        ]) == nil)
        #expect(ToolCallMapper.map(name: "remove_exercise", input: [
            "exercise": "Run",
            "exercise_id": "not-a-uuid",
        ]) == nil)
        #expect(ToolCallMapper.map(name: "delete_everything", input: [:]) == nil)                          // unknown tool
    }
}
