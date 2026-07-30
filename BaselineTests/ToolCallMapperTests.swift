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
        let blockID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let exerciseID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let inputRevision = revision.uuidString
        #expect(ToolCallMapper.map(name: "create_workout", input: ["title": "Push"]) == .createWorkout(title: "Push", note: nil, replaceExisting: false))
        #expect(ToolCallMapper.map(name: "create_workout", input: ["title": "Push", "replace_existing": true, "expected_revision_token": inputRevision]) == .createWorkout(title: "Push", note: nil, replaceExisting: true, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "add_block", input: ["name": "Strength", "expected_revision_token": inputRevision]) == .addBlock(name: "Strength", intent: nil, guidance: nil, atIndex: nil, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "add_exercise", input: ["block_id": blockID.uuidString, "name": "Overhead carry", "distance_m": 150, "expected_revision_token": inputRevision])
                == .addExercise(containerID: blockID, name: "Overhead carry", atIndex: nil, sets: nil, reps: nil, load: nil, durationSeconds: nil, distanceMeters: 150, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "move_exercise", input: ["exercise_instance_id": exerciseID.uuidString, "to_block_id": blockID.uuidString, "to_index": 0, "expected_revision_token": inputRevision])
                == .moveExercise(exerciseInstanceID: exerciseID, toBlockID: blockID, toIndex: 0, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "replace_exercise", input: [
            "exercise_instance_id": exerciseID.uuidString, "replacement": "Run", "expected_revision_token": inputRevision,
        ]) == .replaceExercise(exerciseInstanceID: exerciseID, replacement: "Run", expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "update_set", input: [
            "set_id": inputRevision,
            "patch": ["values": ["distance": 1_000]],
            "expected_revision_token": inputRevision,
        ]) == .updateSet(
            setID: revision,
            patch: PlannedSetPatch(values: .set(.init(metrics: [.distance: .set(1_000)]))),
            expectedRevisionToken: revision
        ))
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
            "exercise_instance_id": exerciseID.uuidString,
            "to_block_id": blockID.uuidString,
            "to_index": 1,
            "expected_revision_token": revision.uuidString,
        ]) == .moveExercise(exerciseInstanceID: exerciseID, toBlockID: blockID, toIndex: 1, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "replace_exercise", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "replacement": "Treadmill Run",
            "expected_revision_token": revision.uuidString,
        ]) == .replaceExercise(
            exerciseInstanceID: exerciseID,
            replacement: "Treadmill Run",
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "remove_exercise", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "expected_revision_token": revision.uuidString,
        ]) == .removeExercise(exerciseInstanceID: exerciseID, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "update_set", input: [
            "set_id": setID.uuidString,
            "patch": ["values": ["duration": 180]],
            "expected_revision_token": revision.uuidString,
        ]) == .updateSet(
            setID: setID,
            patch: PlannedSetPatch(values: .set(.init(metrics: [.duration: .set(180)]))),
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "update_logging_config", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "enabled_metrics": ["duration", "pace", "heartRateZoneTime"],
            "pace_unit": "/mi",
            "expected_revision_token": revision.uuidString,
        ]) == .updateLoggingConfig(
            exerciseInstanceID: exerciseID,
            enabledMetrics: [.duration, .pace, .heartRateZoneTime],
            units: [.pace: .secondsPerMile],
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "set_metric_value", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "set_id": setID.uuidString,
            "metric": "pace",
            "value": 275,
            "unit": "/km",
            "expected_revision_token": revision.uuidString,
        ]) == .setMetricValue(
            exerciseInstanceID: exerciseID,
            setID: setID,
            metric: .pace,
            value: 275,
            unit: .secondsPerKilometer,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "remove_metric", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "metric": "pace",
            "expected_revision_token": revision.uuidString,
        ]) == .removeMetric(exerciseInstanceID: exerciseID, metric: .pace, expectedRevisionToken: revision))
    }

    @Test func setMetricValueUnitsConvertMinutePacesAndAcceptCanonicalPace() throws {
        let exerciseID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let setID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

        func map(value: Double, unit: String) -> AgentTools.Call? {
            ToolCallMapper.map(name: "set_metric_value", input: [
                "exercise_instance_id": exerciseID.uuidString,
                "set_id": setID.uuidString,
                "metric": "pace",
                "value": value,
                "unit": unit,
                "expected_revision_token": revision.uuidString,
            ])
        }

        // "4.5 min/km" means 270 seconds per kilometer — never 4.5 of them (a silent 60× corruption).
        #expect(map(value: 4.5, unit: "min/km") == .setMetricValue(
            exerciseInstanceID: exerciseID, setID: setID, metric: .pace,
            value: 270, unit: .secondsPerKilometer, expectedRevisionToken: revision
        ))
        #expect(map(value: 8, unit: "min/mi") == .setMetricValue(
            exerciseInstanceID: exerciseID, setID: setID, metric: .pace,
            value: 480, unit: .secondsPerMile, expectedRevisionToken: revision
        ))
        // The canonical pace unit, exactly as MetricUnit.short renders it, is a valid input unit.
        #expect(map(value: 0.27, unit: "s/m") == .setMetricValue(
            exerciseInstanceID: exerciseID, setID: setID, metric: .pace,
            value: 0.27, unit: .secondsPerMeter, expectedRevisionToken: revision
        ))
        // Seconds-per forms pass through unchanged.
        #expect(map(value: 275, unit: "/km") == .setMetricValue(
            exerciseInstanceID: exerciseID, setID: setID, metric: .pace,
            value: 275, unit: .secondsPerKilometer, expectedRevisionToken: revision
        ))
    }

    @Test func mapsWaveFiveBlockAndExerciseStructureCalls() throws {
        let blockID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let exerciseID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let expected = revision.uuidString

        #expect(ToolCallMapper.map(name: "add_block", input: [
            "name": "Main",
            "intent": "strength",
            "guidance": "Keep two reps in reserve",
            "at_index": 0,
            "expected_revision_token": expected,
        ]) == .addBlock(
            name: "Main",
            intent: "strength",
            guidance: "Keep two reps in reserve",
            atIndex: 0,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "remove_block", input: [
            "block_id": blockID.uuidString,
            "expected_revision_token": expected,
        ]) == .removeBlock(blockID: blockID, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "move_block", input: [
            "block_id": blockID.uuidString,
            "to_index": 2,
            "expected_revision_token": expected,
        ]) == .moveBlock(blockID: blockID, toIndex: 2, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "duplicate_block", input: [
            "block_id": blockID.uuidString,
            "expected_revision_token": expected,
        ]) == .duplicateBlock(blockID: blockID, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "reorder_exercise", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "to_index": 1,
            "expected_revision_token": expected,
        ]) == .reorderExercise(
            exerciseInstanceID: exerciseID,
            toIndex: 1,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "duplicate_exercise", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "expected_revision_token": expected,
        ]) == .duplicateExercise(
            exerciseInstanceID: exerciseID,
            expectedRevisionToken: revision
        ))
    }

    @Test func rejectsMalformedWaveFiveStructureCalls() {
        let id = UUID().uuidString

        #expect(ToolCallMapper.map(name: "add_block", input: [
            "name": "Main",
            "at_index": -1,
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "move_block", input: [
            "block_id": id,
            "to_index": 1.5,
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "add_exercise", input: [
            "block_id": "not-a-uuid",
            "name": "Run",
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "move_exercise", input: [
            "exercise_instance_id": id,
            "to_block_id": id,
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "remove_exercise", input: [
            "exercise": "Run",
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "duplicate_exercise", input: [
            "exercise_instance_id": id,
        ]) == nil)
    }

    @Test func mapsWaveFourSetToolsAndThreeStatePatches() throws {
        let exerciseID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let setID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let siblingID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

        #expect(ToolCallMapper.map(name: "add_set", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "after_set_id": siblingID.uuidString,
            "values": ["reps": 8, "load": 100.0],
            "role": "top",
            "targets": [
                "effort": ["type": "rpe", "value": 8.0],
                "ranges": [["metric": "load", "lower": 95.0, "upper": 105.0]],
            ],
            "expected_revision_token": revision.uuidString,
        ]) == .addSet(
            exerciseInstanceID: exerciseID,
            afterSetID: siblingID,
            values: PlannedSetValues(metrics: [.reps: 8, .load: 100]),
            role: .top,
            targets: PlannedSetTargets(
                effort: .rpe(8),
                ranges: [.init(metric: .load, lower: 95, upper: 105)]
            ),
            expectedRevisionToken: revision
        ))

        #expect(ToolCallMapper.map(name: "update_set", input: [
            "set_id": setID.uuidString,
            "patch": [
                "values": ["reps": NSNull(), "load": 102.5],
                "role": "backoff",
                "targets": [
                    "effort": NSNull(),
                    "ranges": [["metric": "load", "lower": 90.0, "upper": 100.0]],
                ],
            ],
            "expected_revision_token": revision.uuidString,
        ]) == .updateSet(
            setID: setID,
            patch: PlannedSetPatch(
                values: .set(.init(metrics: [.reps: .clear, .load: .set(102.5)])),
                role: .set(.backoff),
                targets: .set(.init(
                    effort: .clear,
                    ranges: .set([.init(metric: .load, lower: 90, upper: 100)])
                ))
            ),
            expectedRevisionToken: revision
        ))

        #expect(ToolCallMapper.map(name: "update_set", input: [
            "set_id": setID.uuidString,
            "patch": ["values": NSNull(), "targets": NSNull()],
            "expected_revision_token": revision.uuidString,
        ]) == .updateSet(
            setID: setID,
            patch: PlannedSetPatch(values: .clear, targets: .clear),
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "remove_set", input: [
            "set_id": setID.uuidString,
            "expected_revision_token": revision.uuidString,
        ]) == .removeSet(setID: setID, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "move_set", input: [
            "set_id": setID.uuidString,
            "before_set_id": siblingID.uuidString,
            "expected_revision_token": revision.uuidString,
        ]) == .moveSet(
            setID: setID,
            beforeSetID: siblingID,
            toIndex: nil,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "duplicate_set", input: [
            "set_id": setID.uuidString,
            "expected_revision_token": revision.uuidString,
        ]) == .duplicateSet(setID: setID, expectedRevisionToken: revision))
    }

    @Test func rejectsMalformedWaveFourSetCalls() {
        let id = UUID().uuidString

        #expect(ToolCallMapper.map(name: "add_set", input: [
            "exercise_instance_id": id,
            "values": [:],
            "role": "invalid",
            "targets": [:],
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_set", input: [
            "set_id": id,
            "patch": ["role": NSNull()],
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_set", input: [
            "set_id": id,
            "patch": [:],
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "move_set", input: [
            "set_id": id,
            "before_set_id": id,
            "to_index": 0,
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "move_set", input: [
            "set_id": id,
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "move_set", input: [
            "set_id": id,
            "to_index": 1.5,
            "expected_revision_token": id,
        ]) == nil)
        // 2^63 survives the old Double(Int.max) bound check but cannot be an Int — reject, never trap.
        #expect(ToolCallMapper.map(name: "move_set", input: [
            "set_id": id,
            "to_index": 9_223_372_036_854_775_808.0,
            "expected_revision_token": id,
        ]) == nil)
        // An inverted range would be silently normalized by MetricTargetRange past this boundary.
        #expect(ToolCallMapper.map(name: "add_set", input: [
            "exercise_instance_id": id,
            "values": ["duration": 60],
            "role": "working",
            "targets": ["ranges": [["metric": "duration", "lower": 80.0, "upper": 40.0]]],
            "expected_revision_token": id,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_logging_config", input: [
            "exercise_instance_id": id,
            "enabled_metrics": ["duration", "unknown"],
            "expected_revision_token": id,
        ]) == nil)
    }

    @Test func mapsMetadataPatchesWithoutCollapsingOmittedAndNull() throws {
        let blockID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let exerciseID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

        #expect(ToolCallMapper.map(name: "update_workout_metadata", input: [
            "title": "Race prep",
            "note": NSNull(),
            "expected_revision_token": revision.uuidString,
        ]) == .updateWorkoutMetadata(
            title: .set("Race prep"),
            note: .clear,
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

        func workoutNotePatch(_ fields: [String: Any]) -> MetadataPatch<String>? {
            var input = fields
            input["expected_revision_token"] = revision.uuidString
            guard case .updateWorkoutMetadata(_, let note, _)? =
                    ToolCallMapper.map(name: "update_workout_metadata", input: input) else { return nil }
            return note
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

        #expect(workoutNotePatch(["note": "Build capacity"]) == .set("Build capacity"))
        #expect(workoutNotePatch(["note": NSNull()]) == .clear)

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
        #expect(workoutNotePatch(["note": ""]) == .clear)
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

    /// The workout has one note and no guidance of its own. A payload naming workout-level guidance can
    /// only come from a schema older than the served one, so it is discarded rather than stored - while
    /// that same older schema's `goal` key still edits the note, because a functions deploy and an app
    /// build reach a device at different times.
    @Test func workoutMetadataDiscardsGuidanceAndStillAcceptsTheOlderGoalKey() throws {
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

        #expect(ToolCallMapper.map(name: "update_workout_metadata", input: [
            "guidance": "Coach text the athlete would never see",
            "expected_revision_token": revision.uuidString,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_workout_metadata", input: [
            "goal": "Written by an older served schema",
            "expected_revision_token": revision.uuidString,
        ]) == .updateWorkoutMetadata(
            title: .unchanged,
            note: .set("Written by an older served schema"),
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "update_workout_metadata", input: [
            "note": "The served key wins",
            "goal": "The older key loses",
            "guidance": "Discarded",
            "expected_revision_token": revision.uuidString,
        ]) == .updateWorkoutMetadata(
            title: .unchanged,
            note: .set("The served key wins"),
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "create_workout", input: ["title": "Push", "note": "Easy day"])
                == .createWorkout(title: "Push", note: "Easy day", replaceExisting: false))
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

    @Test func mapsPerformedLoggingWithoutInterpretingAthleteQuantities() {
        let exerciseID = UUID()
        let setID = UUID()
        let groupID = UUID()
        let performedSetID = UUID()
        let mutationID = UUID()
        let revision = UUID()

        #expect(ToolCallMapper.map(name: "get_active_session", input: [:]) == .getActiveSession)
        #expect(ToolCallMapper.map(name: "upsert_performed_set", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "planned_set_id": setID.uuidString,
            "group_id": groupID.uuidString,
            "iteration": 2,
            "values": [
                ["metric": "load", "value_text": "185 lb"],
                ["metric": "reps", "value_text": "8"],
            ],
            "expected_revision_token": revision.uuidString,
        ]) == .upsertPerformedSet(
            exerciseInstanceID: exerciseID,
            plannedSetID: setID,
            groupID: groupID,
            iteration: 2,
            values: [
                .init(metric: .load, valueText: "185 lb"),
                .init(metric: .reps, valueText: "8"),
            ],
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "set_performed_set_outcome", input: [
            "performed_set_id": performedSetID.uuidString,
            "outcome": "skipped",
            "expected_revision_token": revision.uuidString,
        ]) == .setPerformedSetOutcome(
            target: .extra(performedSetID: performedSetID),
            outcome: .skipped,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "add_extra_performed_set", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "values": [["metric": "pace", "value_text": "1:19 per 400 m"]],
            "expected_revision_token": revision.uuidString,
        ]) == .addExtraPerformedSet(
            exerciseInstanceID: exerciseID,
            groupID: nil,
            iteration: nil,
            values: [.init(metric: .pace, valueText: "1:19 per 400 m")],
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "update_extra_performed_set", input: [
            "performed_set_id": performedSetID.uuidString,
            "values": [["metric": "load", "value_text": "180 lb"]],
            "expected_revision_token": revision.uuidString,
        ]) == .updateExtraPerformedSet(
            performedSetID: performedSetID,
            values: [.init(metric: .load, valueText: "180 lb")],
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "delete_extra_performed_set", input: [
            "performed_set_id": performedSetID.uuidString,
            "expected_revision_token": revision.uuidString,
        ]) == .deleteExtraPerformedSet(
            performedSetID: performedSetID,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "add_exercise_session_note", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "note": "Felt controlled",
            "expected_revision_token": revision.uuidString,
        ]) == .addExerciseSessionNote(
            exerciseInstanceID: exerciseID,
            note: "Felt controlled",
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "undo_session_mutation", input: [
            "mutation_id": mutationID.uuidString,
            "expected_revision_token": revision.uuidString,
        ]) == .undoSessionMutation(mutationID: mutationID, expectedRevisionToken: revision))

        #expect(ToolCallMapper.map(name: "upsert_performed_set", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "planned_set_id": setID.uuidString,
            "values": [["metric": "load", "value_text": 185]],
            "expected_revision_token": revision.uuidString,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "set_performed_set_outcome", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "planned_set_id": setID.uuidString,
            "group_id": groupID.uuidString,
            "outcome": "completed",
            "expected_revision_token": revision.uuidString,
        ]) == nil)
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
            "exercise_instance_id": "not-a-uuid",
            "expected_revision_token": UUID().uuidString,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "delete_everything", input: [:]) == nil)                          // unknown tool
    }

    // MARK: - Wave 7: atomic batch and bulk selector tools

    @Test func mapsApplyWorkoutEditsPreservingOperationOrder() throws {
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let blockID = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        let exerciseID = try #require(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc"))
        let setID = try #require(UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd"))

        let call = ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [
                ["op": "update_block_metadata", "block_id": blockID.uuidString, "name": "Upper Body"],
                ["op": "move_exercise", "exercise_instance_id": exerciseID.uuidString,
                 "to_block_id": blockID.uuidString, "to_index": 1],
                ["op": "update_set", "set_id": setID.uuidString, "patch": ["values": ["distance": 1_000]]],
            ],
            "expected_revision_token": revision.uuidString,
        ])
        #expect(call == .applyWorkoutEdits(
            operations: [
                .updateBlockMetadata(blockID: blockID, name: .set("Upper Body"), intent: .unchanged, guidance: .unchanged),
                .moveExercise(exerciseInstanceID: exerciseID, toBlockID: blockID, toIndex: 1),
                .updateSet(setID: setID, patch: PlannedSetPatch(values: .set(.init(metrics: [.distance: .set(1_000)])))),
            ],
            expectedRevisionToken: revision
        ))
    }

    @Test func applyWorkoutEditsRejectsWhenAnyOperationIsMalformed() throws {
        let revision = UUID().uuidString
        let blockID = UUID().uuidString
        // A single malformed operation rejects the entire call: batch mapping is all-or-nothing too.
        #expect(ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [
                ["op": "update_block_metadata", "block_id": blockID, "name": "Upper Body"],
                ["op": "remove_set", "set_id": "not-a-uuid"],
            ],
            "expected_revision_token": revision,
        ]) == nil)
        // Unknown op names, non-batchable tools, and empty batches reject.
        #expect(ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [["op": "detonate_workout"]],
            "expected_revision_token": revision,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [["op": "create_workout", "title": "New"]],
            "expected_revision_token": revision,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [["op": "undo_workout_mutation", "mutation_id": UUID().uuidString]],
            "expected_revision_token": revision,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [[String: Any]()],
            "expected_revision_token": revision,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [[String: Any]]() as Any,
            "expected_revision_token": revision,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [["op": "remove_set", "set_id": UUID().uuidString]],
        ]) == nil)   // missing batch token
    }

    @Test func batchOperationsParseExactlyLikeTheirStandaloneTools() throws {
        // The same payload (minus the token) must produce the same typed operation both ways, so a
        // schema-valid single call can always be lifted into a batch.
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let exerciseID = try #require(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc"))
        let payload: [String: Any] = [
            "exercise_instance_id": exerciseID.uuidString,
            "values": ["reps": 8, "load": 60],
            "role": "working",
            "targets": [String: Any](),
        ]

        var standaloneInput = payload
        standaloneInput["expected_revision_token"] = revision.uuidString
        let standalone = ToolCallMapper.map(name: "add_set", input: standaloneInput)

        var batchOperation = payload
        batchOperation["op"] = "add_set"
        let batch = ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [batchOperation],
            "expected_revision_token": revision.uuidString,
        ])
        guard case .addSet(let a, let b, let c, let d, let e, let token) = try #require(standalone),
              case .applyWorkoutEdits(let operations, let batchToken) = try #require(batch) else {
            Issue.record("Expected both mappings to succeed")
            return
        }
        #expect(operations == [.addSet(exerciseInstanceID: a, afterSetID: b, values: c, role: d, targets: e)])
        #expect(token == revision)
        #expect(batchToken == revision)
    }

    @Test func mapsConvertWorkoutUnits() throws {
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let blockID = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))

        // No selector, dry_run defaults to false — the whole-workout case applies directly.
        #expect(ToolCallMapper.map(name: "convert_workout_units", input: [
            "distance_unit": "km",
            "pace_unit": "/km",
            "expected_revision_token": revision.uuidString,
        ]) == .convertWorkoutUnits(
            units: [.distance: .kilometers, .pace: .secondsPerKilometer],
            selector: nil,
            dryRun: false,
            expectedRevisionToken: revision
        ))
        // Selector + explicit dry run.
        #expect(ToolCallMapper.map(name: "convert_workout_units", input: [
            "distance_unit": "mi",
            "selector": ["pattern": "gait", "block_id": blockID.uuidString],
            "dry_run": true,
            "expected_revision_token": revision.uuidString,
        ]) == .convertWorkoutUnits(
            units: [.distance: .miles],
            selector: BulkExerciseSelectorInput(pattern: "gait", blockID: blockID),
            dryRun: true,
            expectedRevisionToken: revision
        ))
        // No units, malformed unit, empty selector object, mistyped selector values, and unknown
        // selector keys all reject — a dropped constraint would silently widen the match set.
        #expect(ToolCallMapper.map(name: "convert_workout_units", input: [
            "expected_revision_token": revision.uuidString,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "convert_workout_units", input: [
            "distance_unit": "furlongs",
            "expected_revision_token": revision.uuidString,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "convert_workout_units", input: [
            "distance_unit": "km",
            "selector": [String: Any](),
            "expected_revision_token": revision.uuidString,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "convert_workout_units", input: [
            "distance_unit": "km",
            "selector": ["muscle": 3],
            "expected_revision_token": revision.uuidString,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "convert_workout_units", input: [
            "distance_unit": "km",
            "selector": ["block_id": "not-a-uuid"],
            "expected_revision_token": revision.uuidString,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "convert_workout_units", input: [
            "distance_unit": "km",
            "selector": ["modality": "cardio", "equipmnt": "treadmill"],
            "expected_revision_token": revision.uuidString,
        ]) == nil)
    }

    /// Every unit the athlete can pick for pace must also be expressible through the agent facade,
    /// or a rower who asks for "pace per 500" gets a rejected tool call for a setting the picker
    /// already offers.
    @Test func mapsEveryAthleteSelectablePaceUnit() throws {
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let exerciseID = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))

        for (spelling, expected) in [
            ("/500m", MetricUnit.secondsPer500Meters),
            ("per 500m", .secondsPer500Meters),
            ("min/500m", .secondsPer500Meters),
            ("/km", .secondsPerKilometer),
            ("/mi", .secondsPerMile),
        ] {
            #expect(ToolCallMapper.map(name: "update_logging_config", input: [
                "exercise_instance_id": exerciseID.uuidString,
                "enabled_metrics": ["duration", "pace"],
                "pace_unit": spelling,
                "expected_revision_token": revision.uuidString,
            ]) == .updateLoggingConfig(
                exerciseInstanceID: exerciseID,
                enabledMetrics: [.duration, .pace],
                units: [.pace: expected],
                expectedRevisionToken: revision
            ), "pace_unit \(spelling)")
        }

        // Nothing outside the athlete-selectable set is invented.
        #expect(ToolCallMapper.map(name: "update_logging_config", input: [
            "exercise_instance_id": exerciseID.uuidString,
            "enabled_metrics": ["pace"],
            "pace_unit": "/400m",
            "expected_revision_token": revision.uuidString,
        ]) == nil)
    }

    @Test func mapsBulkReplaceExercisesWithDryRunAsTheDefault() throws {
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

        // Omitted dry_run maps to TRUE: only an explicit false can apply.
        #expect(ToolCallMapper.map(name: "bulk_replace_exercises", input: [
            "selector": ["definition_id": "run"],
            "replacement_definition_id": "row",
            "expected_revision_token": revision.uuidString,
        ]) == .bulkReplaceExercises(
            selector: BulkExerciseSelectorInput(definitionID: "run"),
            replacementDefinitionID: "row",
            dryRun: true,
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "bulk_replace_exercises", input: [
            "selector": ["modality": "cardio"],
            "replacement_definition_id": "ski_erg",
            "dry_run": false,
            "expected_revision_token": revision.uuidString,
        ]) == .bulkReplaceExercises(
            selector: BulkExerciseSelectorInput(modality: "cardio"),
            replacementDefinitionID: "ski_erg",
            dryRun: false,
            expectedRevisionToken: revision
        ))
        // Selector and replacement are mandatory.
        #expect(ToolCallMapper.map(name: "bulk_replace_exercises", input: [
            "replacement_definition_id": "row",
            "expected_revision_token": revision.uuidString,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "bulk_replace_exercises", input: [
            "selector": ["definition_id": "run"],
            "expected_revision_token": revision.uuidString,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "bulk_replace_exercises", input: [
            "selector": ["definition_id": "run"],
            "replacement_definition_id": "row",
        ]) == nil)
    }

    @Test func mapsCreateCustomExerciseWithTolerantTaxonomyAndUnits() throws {
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let proposal = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))

        // Raw values, display names, and snake case all land on the same taxonomy case.
        #expect(ToolCallMapper.map(name: "create_custom_exercise", input: [
            "name": "Single-arm sled drag",
            "equipment": ["sled"],
            "primary_muscles": ["glutes", "Front delts"],
            "secondary_muscles": ["hamstrings"],
            "metrics": ["distance", "duration"],
            "patterns": ["gait"],
            "tags": ["hyrox"],
            "level": "expert",
            "distance_unit": "mi",
            "expected_revision_token": revision.uuidString,
        ]) == .createCustomExercise(
            draft: WorkoutStore.CustomExerciseDraft(
                name: "Single-arm sled drag",
                equipment: [.sled],
                primaryMuscles: [.glutes, .frontDelts],
                secondaryMuscles: [.hamstrings],
                metrics: [.distance, .duration],
                patterns: [.gait],
                tags: [.hyrox],
                level: .expert,
                units: [.distance: .miles]
            ),
            proposalID: nil,
            expectedRevisionToken: revision
        ))

        // The confirming call carries the proposal id; omitted optionals stay empty, not invented.
        #expect(ToolCallMapper.map(name: "create_custom_exercise", input: [
            "name": "Keg Toss",
            "equipment": ["sandbag"],
            "primary_muscles": ["glutes"],
            "metrics": ["reps", "load"],
            "proposal_id": proposal.uuidString,
            "expected_revision_token": revision.uuidString,
        ]) == .createCustomExercise(
            draft: WorkoutStore.CustomExerciseDraft(
                name: "Keg Toss",
                equipment: [.sandbag],
                primaryMuscles: [.glutes],
                secondaryMuscles: [],
                metrics: [.reps, .load],
                patterns: [],
                tags: [],
                level: nil,
                units: [:]
            ),
            proposalID: proposal,
            expectedRevisionToken: revision
        ))
    }

    @Test func mapsEverySupportedTaxonomyCaseForCustomExercise() throws {
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let primaryMuscles: [Muscle] = [.fullBody]
        let secondaryMuscles = Muscle.allCases.filter { $0 != .fullBody }

        #expect(ToolCallMapper.map(name: "create_custom_exercise", input: [
            "name": "Taxonomy parity fixture",
            "equipment": Equipment.allCases.map(\.rawValue),
            "primary_muscles": primaryMuscles.map(\.rawValue),
            "secondary_muscles": secondaryMuscles.map(\.rawValue),
            "metrics": MetricType.allCases.map(\.rawValue),
            "patterns": [MovementPattern.squat.rawValue, MovementPattern.hold.rawValue],
            "tags": ExerciseTag.allCases.map(\.rawValue),
            "level": ExerciseLevel.expert.rawValue,
            "expected_revision_token": revision.uuidString,
        ]) == .createCustomExercise(
            draft: WorkoutStore.CustomExerciseDraft(
                name: "Taxonomy parity fixture",
                equipment: Equipment.allCases,
                primaryMuscles: primaryMuscles,
                secondaryMuscles: secondaryMuscles,
                metrics: MetricType.allCases,
                patterns: [.squat, .hold],
                tags: ExerciseTag.allCases,
                level: .expert,
                units: [:]
            ),
            proposalID: nil,
            expectedRevisionToken: revision
        ))
    }

    @Test func createCustomExerciseRejectsMissingOrUnknownClassification() throws {
        let revision = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let complete: [String: Any] = [
            "name": "Keg Toss",
            "equipment": ["sandbag"],
            "primary_muscles": ["glutes"],
            "metrics": ["reps"],
            "expected_revision_token": revision.uuidString,
        ]

        func without(_ key: String) -> [String: Any] {
            var input = complete
            input[key] = nil
            return input
        }

        // The manual form's required set is required here too.
        for key in ["name", "equipment", "primary_muscles", "metrics", "expected_revision_token"] {
            #expect(ToolCallMapper.map(name: "create_custom_exercise", input: without(key)) == nil, "missing \(key)")
        }
        // Empty required arrays are as missing as absent ones.
        for (key, value) in [("equipment", [String]()), ("primary_muscles", []), ("metrics", [])] {
            var input = complete
            input[key] = value
            #expect(ToolCallMapper.map(name: "create_custom_exercise", input: input) == nil, "empty \(key)")
        }
        // A single unparseable value anywhere rejects the whole call - a silently dropped
        // classification would commit a definition the athlete never saw proposed.
        for (key, value) in [
            ("equipment", ["sandbag", "banana"]),
            ("secondary_muscles", ["banana"]),
            ("patterns", ["banana"]),
            ("tags", ["banana"]),
            ("level", "banana"),
            ("proposal_id", "not-a-uuid"),
            ("distance_unit", "banana"),
        ] as [(String, Any)] {
            var input = complete
            input[key] = value
            #expect(ToolCallMapper.map(name: "create_custom_exercise", input: input) == nil, "unknown \(key) value")
        }
    }
}
