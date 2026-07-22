import Foundation

/// Maps an LLM `tool_use` (name + JSON input) to a validated `AgentTools.Call`. Pure and tested: the
/// app never trusts the model's raw JSON — unknown or malformed calls return nil, and the runtime
/// tells the model it was rejected. Names must match `functions/src/tools.ts`.
enum ToolCallMapper {
    static func map(name: String, input: [String: Any]) -> AgentTools.Call? {
        switch name {
        case "get_today":
            return .getToday
        case "explain":
            return .explain
        case "set_time_available":
            return .setTimeAvailable(intOrNil(input["minutes"]))
        case "set_equipment":
            return .setEquipment(stringArrayOrNil(input["equipment"]))
        case "set_traveling":
            guard let b = boolOrNil(input["traveling"]) else { return nil }
            return .setTraveling(b)
        case "set_illness":
            guard let b = boolOrNil(input["illness"]) else { return nil }
            return .setIllness(b)
        case "set_sleep":
            return .setSleep(hours: doubleOrNil(input["hours"]))
        case "set_checkin":
            return .setCheckIn(energy: doubleOrNil(input["energy"]), mood: doubleOrNil(input["mood"]),
                               stress: doubleOrNil(input["stress"]), soreness: doubleOrNil(input["soreness"]))
        case "set_note":
            guard let s = input["note"] as? String else { return nil }
            return .setNote(s)
        case "upsert_constraint":
            guard let location = input["location"] as? String,
                  let kindStr = input["kind"] as? String,
                  let kind = DecisionEngine.Constraint.Kind(rawValue: kindStr) else { return nil }
            let severity = intOrNil(input["severity"]) ?? 0
            let affects = boolOrNil(input["affectsTraining"]) ?? true
            let id = (input["id"] as? String).flatMap { UUID(uuidString: $0) }
            return .upsertConstraint(id: id, kind: kind, location: location, severity: severity, affectsTraining: affects)
        case "resolve_constraint":
            guard let idStr = input["id"] as? String, let id = UUID(uuidString: idStr) else { return nil }
            return .resolveConstraint(id: id)
        case "open_apple_health_setup":
            return .openAppleHealthSetup
        case "get_sleep":
            return .getSleep(nightsAgo: max(0, intOrNil(input["nights_ago"]) ?? 0))
        case "get_hrv_readings":
            return .getHRVReadings(limit: intOrNil(input["limit"]) ?? 7)
        case "get_resting_heart_rate":
            return .getRestingHeartRate(days: intOrNil(input["days"]) ?? 7)
        case "create_workout":
            guard let title = input["title"] as? String,
                  validOptionalUUID(input["expected_revision_token"]) else { return nil }
            let replaceExisting = boolOrNil(input["replace_existing"]) ?? false
            let expectedRevisionToken = uuid(input["expected_revision_token"])
            guard !replaceExisting || expectedRevisionToken != nil else { return nil }
            return .createWorkout(title: title, goal: input["goal"] as? String,
                                  replaceExisting: replaceExisting,
                                  expectedRevisionToken: expectedRevisionToken)
        case "update_workout_metadata":
            guard let title = stringPatch(input, key: "title", nullable: false),
                  let goal = stringPatch(input, key: "goal", nullable: true),
                  let guidance = stringPatch(input, key: "guidance", nullable: true),
                  let expected = requiredUUID(input["expected_revision_token"]),
                  hasChanges(title, goal, guidance) else { return nil }
            return .updateWorkoutMetadata(
                title: title,
                goal: goal,
                guidance: guidance,
                expectedRevisionToken: expected
            )
        case "update_block_metadata":
            guard let blockID = requiredUUID(input["block_id"]),
                  let name = stringPatch(input, key: "name", nullable: false),
                  let intent = stringPatch(input, key: "intent", nullable: true),
                  let guidance = stringPatch(input, key: "guidance", nullable: true),
                  let expected = requiredUUID(input["expected_revision_token"]),
                  hasChanges(name, intent, guidance) else { return nil }
            return .updateBlockMetadata(
                blockID: blockID,
                name: name,
                intent: intent,
                guidance: guidance,
                expectedRevisionToken: expected
            )
        case "update_exercise_metadata":
            guard let exerciseID = requiredUUID(input["exercise_instance_id"]),
                  let displayLabel = stringPatch(input, key: "display_label", nullable: true),
                  let guidance = stringPatch(input, key: "guidance", nullable: true),
                  let expected = requiredUUID(input["expected_revision_token"]),
                  hasChanges(displayLabel, guidance) else { return nil }
            return .updateExerciseMetadata(
                exerciseInstanceID: exerciseID,
                displayLabel: displayLabel,
                guidance: guidance,
                expectedRevisionToken: expected
            )
        case "add_block":
            guard let name = input["name"] as? String,
                  validOptionalIndex(input["at_index"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .addBlock(
                name: name,
                intent: input["intent"] as? String,
                guidance: input["guidance"] as? String,
                atIndex: exactIntOrNil(input["at_index"]),
                expectedRevisionToken: expected
            )
        case "remove_block":
            guard let blockID = requiredUUID(input["block_id"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .removeBlock(blockID: blockID, expectedRevisionToken: expected)
        case "move_block":
            guard let blockID = requiredUUID(input["block_id"]),
                  let toIndex = exactIntOrNil(input["to_index"]), toIndex >= 0,
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .moveBlock(blockID: blockID, toIndex: toIndex, expectedRevisionToken: expected)
        case "duplicate_block":
            guard let blockID = requiredUUID(input["block_id"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .duplicateBlock(blockID: blockID, expectedRevisionToken: expected)
        case "add_exercise":
            guard let blockID = requiredUUID(input["block_id"]),
                  let name = input["name"] as? String,
                  validOptionalIndex(input["at_index"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .addExercise(
                blockID: blockID,
                name: name,
                atIndex: exactIntOrNil(input["at_index"]),
                sets: intOrNil(input["sets"]),
                reps: intOrNil(input["reps"]),
                load: doubleOrNil(input["load"]),
                durationSeconds: intOrNil(input["duration_seconds"]),
                distanceMeters: doubleOrNil(input["distance_m"]),
                expectedRevisionToken: expected
            )
        case "move_exercise":
            guard let exerciseID = requiredUUID(input["exercise_instance_id"]),
                  let toBlockID = requiredUUID(input["to_block_id"]),
                  let toIndex = exactIntOrNil(input["to_index"]), toIndex >= 0,
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .moveExercise(
                exerciseInstanceID: exerciseID,
                toBlockID: toBlockID,
                toIndex: toIndex,
                expectedRevisionToken: expected
            )
        case "replace_exercise":
            guard let exerciseID = requiredUUID(input["exercise_instance_id"]),
                  let replacement = input["replacement"] as? String,
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .replaceExercise(
                exerciseInstanceID: exerciseID,
                replacement: replacement,
                expectedRevisionToken: expected
            )
        case "require_all_options":
            guard let choice = input["choice"] as? String,
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .requireAllOptions(choice: choice, expectedRevisionToken: expected)
        case "remove_exercise":
            guard let exerciseID = requiredUUID(input["exercise_instance_id"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .removeExercise(exerciseInstanceID: exerciseID, expectedRevisionToken: expected)
        case "reorder_exercise":
            guard let exerciseID = requiredUUID(input["exercise_instance_id"]),
                  let toIndex = exactIntOrNil(input["to_index"]), toIndex >= 0,
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .reorderExercise(
                exerciseInstanceID: exerciseID,
                toIndex: toIndex,
                expectedRevisionToken: expected
            )
        case "duplicate_exercise":
            guard let exerciseID = requiredUUID(input["exercise_instance_id"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .duplicateExercise(exerciseInstanceID: exerciseID, expectedRevisionToken: expected)
        case "add_set":
            guard let exerciseID = requiredUUID(input["exercise_instance_id"]),
                  validOptionalUUID(input["after_set_id"]),
                  let values = plannedSetValues(input["values"]),
                  let role = setRole(input["role"]),
                  let targets = plannedSetTargets(input["targets"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .addSet(
                exerciseInstanceID: exerciseID,
                afterSetID: uuid(input["after_set_id"]),
                values: values,
                role: role,
                targets: targets,
                expectedRevisionToken: expected
            )
        case "update_set":
            guard let setID = requiredUUID(input["set_id"]),
                  let patchInput = input["patch"] as? [String: Any],
                  let patch = plannedSetPatch(patchInput),
                  patch.isUnchanged == false,
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .updateSet(setID: setID, patch: patch, expectedRevisionToken: expected)
        case "remove_set":
            guard let setID = requiredUUID(input["set_id"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .removeSet(setID: setID, expectedRevisionToken: expected)
        case "move_set":
            guard let setID = requiredUUID(input["set_id"]),
                  validOptionalUUID(input["before_set_id"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            let beforeSetID = uuid(input["before_set_id"])
            let toIndex = exactIntOrNil(input["to_index"])
            guard (beforeSetID != nil) != (toIndex != nil) else { return nil }
            return .moveSet(
                setID: setID,
                beforeSetID: beforeSetID,
                toIndex: toIndex,
                expectedRevisionToken: expected
            )
        case "duplicate_set":
            guard let setID = requiredUUID(input["set_id"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .duplicateSet(setID: setID, expectedRevisionToken: expected)
        case "undo_workout_mutation":
            guard let mutationID = requiredUUID(input["mutation_id"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .undoWorkoutMutation(mutationID: mutationID, expectedRevisionToken: expected)
        case "search_exercises":
            // Every field is optional - an all-empty search is a valid "what do you have?" browse.
            // Filter *values* aren't validated here: the taxonomy knows them, so ExerciseSearch parses
            // them and an unknown one comes back as a correctable message instead of a bare rejection.
            return .searchExercises(query: trimmedOrNil(input["query"]), muscle: trimmedOrNil(input["muscle"]),
                                    equipment: trimmedOrNil(input["equipment"]), modality: trimmedOrNil(input["modality"]),
                                    pattern: trimmedOrNil(input["pattern"]), tag: trimmedOrNil(input["tag"]),
                                    level: trimmedOrNil(input["level"]))
        case "get_exercise":
            // Needing a name or an id isn't checked here: a bare nil would reach the model as the
            // generic "that tool call wasn't valid". AgentTools names the two parameters instead, so
            // the model can retry - the same reason search_exercises leaves filter values to it.
            return .getExercise(name: trimmedOrNil(input["name"]), id: trimmedOrNil(input["id"]))
        case "get_current_workout":
            return .getCurrentWorkout
        case "start_workout":
            return .startWorkout
        case "complete_workout", "finish_workout":
            return .completeWorkout(confirm: (input["confirm"] as? Bool) ?? false)
        case "get_week_plan":
            return .getWeekPlan
        case "move_workout":
            guard let w = input["workout"] as? String, let d = input["to_day"] as? String else { return nil }
            return .moveWorkout(workout: w, toDay: d)
        case "swap_workouts":
            guard let a = input["a"] as? String, let b = input["b"] as? String else { return nil }
            return .swapWorkouts(a: a, b: b)
        case "skip_workout":
            guard let w = input["workout"] as? String else { return nil }
            return .skipWorkout(workout: w, skipped: (input["skipped"] as? Bool) ?? true)
        case "duplicate_workout":
            guard let w = input["workout"] as? String else { return nil }
            return .duplicateWorkout(workout: w, toDay: input["to_day"] as? String)
        case "delete_workout":
            guard let w = input["workout"] as? String else { return nil }
            return .deleteWorkout(workout: w, proposalID: input["proposal_id"] as? String)
        case "explain_modification":
            guard let w = input["workout"] as? String else { return nil }
            return .explainModification(workout: w)
        case "save_as_template":
            guard let n = input["name"] as? String else { return nil }
            return .saveAsTemplate(name: n)
        case "create_from_template":
            guard let n = input["name"] as? String, let d = input["to_day"] as? String else { return nil }
            return .createFromTemplate(name: n, day: d)
        case "update_template":
            guard let n = input["name"] as? String else { return nil }
            return .updateTemplate(name: n)
        case "update_logging_config":
            guard let exerciseID = requiredUUID(input["exercise_instance_id"]),
                  input["enabled_metrics"] == nil || metricList(input["enabled_metrics"]) != nil,
                  let units = unitOverrides(input),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .updateLoggingConfig(
                exerciseInstanceID: exerciseID,
                enabledMetrics: metricList(input["enabled_metrics"]),
                units: units,
                expectedRevisionToken: expected
            )
        case "update_exercise_preference":
            guard let ex = input["exercise"] as? String else { return nil }
            let scope: WorkoutStore.PreferenceScope = (input["scope"] as? String) == "category" ? .category : .exercise
            guard input["enabled_metrics"] == nil || metricList(input["enabled_metrics"]) != nil,
                  let units = unitOverrides(input) else { return nil }
            return .updateExercisePreference(exercise: ex, scope: scope, units: units, selectedMetrics: metricList(input["enabled_metrics"]))
        case "set_metric_value":
            guard let exerciseID = requiredUUID(input["exercise_instance_id"]),
                  let setID = requiredUUID(input["set_id"]),
                  let m = metric(input["metric"]), let v = doubleOrNil(input["value"]),
                  input["unit"] == nil || valueUnit(input["unit"]) != nil,
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            let parsedUnit = valueUnit(input["unit"])
            return .setMetricValue(
                exerciseInstanceID: exerciseID,
                setID: setID,
                metric: m,
                value: v * (parsedUnit?.multiplier ?? 1),
                unit: parsedUnit?.unit,
                expectedRevisionToken: expected
            )
        case "remove_metric":
            guard let exerciseID = requiredUUID(input["exercise_instance_id"]),
                  let m = metric(input["metric"]),
                  let expected = requiredUUID(input["expected_revision_token"]) else { return nil }
            return .removeMetric(
                exerciseInstanceID: exerciseID,
                metric: m,
                expectedRevisionToken: expected
            )
        default:
            return nil
        }
    }

    // JSON scalars arrive as Int/Double/Bool/NSNumber; JSON null as NSNull.
    private static func intOrNil(_ v: Any?) -> Int? {
        if v == nil || v is NSNull { return nil }
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    private static func exactIntOrNil(_ value: Any?) -> Int? {
        if value == nil || value is NSNull { return nil }
        if let integer = value as? Int { return integer }
        if let double = value as? Double { return Int(exactly: double) }
        return nil
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string)
    }

    private static func requiredUUID(_ value: Any?) -> UUID? { uuid(value) }

    private static func stringPatch(
        _ input: [String: Any],
        key: String,
        nullable: Bool
    ) -> MetadataPatch<String>? {
        guard let value = input[key] else { return .unchanged }
        if value is NSNull { return nullable ? .clear : nil }
        guard let string = value as? String else { return nil }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nullable ? .clear : nil
        }
        return .set(string)
    }

    private static func hasChanges<Value: Equatable & Sendable>(
        _ patches: MetadataPatch<Value>...
    ) -> Bool {
        patches.contains { !$0.isUnchanged }
    }

    private static func plannedSetValues(_ value: Any?) -> PlannedSetValues? {
        guard let object = value as? [String: Any] else { return nil }
        var values: [MetricType: Double] = [:]
        for (key, rawValue) in object {
            guard let metric = metric(key), let number = doubleOrNil(rawValue) else { return nil }
            values[metric] = number
        }
        return PlannedSetValues(metrics: values)
    }

    private static func plannedSetValuesPatch(
        _ input: [String: Any],
        key: String
    ) -> MetadataPatch<PlannedSetValuesPatch>? {
        guard let value = input[key] else { return .unchanged }
        if value is NSNull { return .clear }
        guard let object = value as? [String: Any] else { return nil }
        var patches: [MetricType: MetadataPatch<Double>] = [:]
        for (rawMetric, rawValue) in object {
            guard let metric = metric(rawMetric) else { return nil }
            if rawValue is NSNull {
                patches[metric] = .clear
            } else {
                guard let number = doubleOrNil(rawValue) else { return nil }
                patches[metric] = .set(number)
            }
        }
        guard patches.isEmpty == false else { return nil }
        return .set(PlannedSetValuesPatch(metrics: patches))
    }

    private static func setRole(_ value: Any?) -> SetRole? {
        guard let rawValue = value as? String else { return nil }
        return SetRole(rawValue: rawValue)
    }

    private static func setRolePatch(
        _ input: [String: Any],
        key: String
    ) -> MetadataPatch<SetRole>? {
        guard let value = input[key] else { return .unchanged }
        guard value is NSNull == false, let role = setRole(value) else { return nil }
        return .set(role)
    }

    private static func effortTarget(_ value: Any?) -> EffortTarget? {
        guard let object = value as? [String: Any], let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "rpe":
            guard let value = doubleOrNil(object["value"]) else { return nil }
            return .rpe(value)
        case "rir":
            guard let value = doubleOrNil(object["value"]) else { return nil }
            return .rir(value)
        case "toFailure":
            guard object["value"] == nil else { return nil }
            return .toFailure
        case "maxEffort":
            guard object["value"] == nil else { return nil }
            return .maxEffort
        default:
            return nil
        }
    }

    /// An inverted range is rejected here because `MetricTargetRange` normalizes bound order at init —
    /// past this boundary the raw claim "lower 80, upper 40" can no longer be seen, so it must not
    /// silently become 40–80.
    private static func rangeTargets(_ value: Any?) -> [MetricTargetRange]? {
        guard let array = value as? [[String: Any]] else { return nil }
        return array.reduce(into: [MetricTargetRange]?([])) { result, object in
            guard result != nil,
                  let metric = metric(object["metric"]),
                  let lower = doubleOrNil(object["lower"]),
                  let upper = doubleOrNil(object["upper"]),
                  lower <= upper else {
                result = nil
                return
            }
            result?.append(.init(metric: metric, lower: lower, upper: upper))
        }
    }

    private static func plannedSetTargets(_ value: Any?) -> PlannedSetTargets? {
        guard let object = value as? [String: Any] else { return nil }
        let effort: EffortTarget?
        if let rawEffort = object["effort"] {
            guard rawEffort is NSNull == false, let parsed = effortTarget(rawEffort) else { return nil }
            effort = parsed
        } else {
            effort = nil
        }
        let ranges: [MetricTargetRange]
        if let rawRanges = object["ranges"] {
            guard let parsed = rangeTargets(rawRanges) else { return nil }
            ranges = parsed
        } else {
            ranges = []
        }
        return PlannedSetTargets(effort: effort, ranges: ranges)
    }

    private static func plannedSetTargetsPatch(
        _ input: [String: Any],
        key: String
    ) -> MetadataPatch<PlannedSetTargetsPatch>? {
        guard let value = input[key] else { return .unchanged }
        if value is NSNull { return .clear }
        guard let object = value as? [String: Any] else { return nil }

        let effort: MetadataPatch<EffortTarget>
        if let rawEffort = object["effort"] {
            if rawEffort is NSNull {
                effort = .clear
            } else {
                guard let parsed = effortTarget(rawEffort) else { return nil }
                effort = .set(parsed)
            }
        } else {
            effort = .unchanged
        }

        let ranges: MetadataPatch<[MetricTargetRange]>
        if let rawRanges = object["ranges"] {
            if rawRanges is NSNull {
                ranges = .clear
            } else {
                guard let parsed = rangeTargets(rawRanges) else { return nil }
                ranges = .set(parsed)
            }
        } else {
            ranges = .unchanged
        }

        let patch = PlannedSetTargetsPatch(effort: effort, ranges: ranges)
        guard patch.isUnchanged == false else { return nil }
        return .set(patch)
    }

    private static func plannedSetPatch(_ input: [String: Any]) -> PlannedSetPatch? {
        guard let values = plannedSetValuesPatch(input, key: "values"),
              let role = setRolePatch(input, key: "role"),
              let targets = plannedSetTargetsPatch(input, key: "targets") else { return nil }
        return PlannedSetPatch(values: values, role: role, targets: targets)
    }

    /// Optional UUID fields may be omitted or null. A supplied malformed ID always rejects the call.
    private static func validOptionalUUID(_ value: Any?) -> Bool {
        value == nil || value is NSNull || uuid(value) != nil
    }

    private static func validOptionalIndex(_ value: Any?) -> Bool {
        value == nil || value is NSNull || exactIntOrNil(value).map { $0 >= 0 } == true
    }
    // MARK: - Metric / unit parsing (tolerant of casual names the model may emit)

    private static let metricAliases: [String: MetricType] = [
        "reps": .reps, "rep": .reps, "load": .load, "weight": .load,
        "duration": .duration, "time": .duration, "distance": .distance,
        "calories": .calories, "cals": .calories, "cal": .calories,
        "heartrate": .heartRate, "heart_rate": .heartRate, "hr": .heartRate, "avghr": .heartRate,
        "hrzonetime": .heartRateZoneTime, "heartratezonetime": .heartRateZoneTime,
        "zonetime": .heartRateZoneTime,
        "cadence": .cadence, "power": .power, "watts": .power, "pace": .pace, "rpe": .rpe,
    ]
    private static let unitAliases: [String: MetricUnit] = [
        "m": .meters, "meter": .meters, "meters": .meters,
        "km": .kilometers, "kilometer": .kilometers, "kilometers": .kilometers,
        "mi": .miles, "mile": .miles, "miles": .miles,
        "kg": .kilograms, "kilogram": .kilograms, "kilograms": .kilograms,
        "lb": .pounds, "lbs": .pounds, "pound": .pounds, "pounds": .pounds,
        "s": .seconds, "sec": .seconds, "second": .seconds, "seconds": .seconds,
        "min": .minutes, "minute": .minutes, "minutes": .minutes,
    ]
    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { !" _-/".contains($0) }
    }
    private static func metric(_ v: Any?) -> MetricType? {
        guard let s = v as? String else { return nil }
        return metricAliases[normalize(s)] ?? MetricType(rawValue: s)
    }
    private static func metricList(_ v: Any?) -> [MetricType]? {
        guard let arr = v as? [String] else { return nil }
        let metrics = arr.compactMap { metric($0) }
        return metrics.count == arr.count ? metrics : nil
    }
    private static func unit(_ v: Any?) -> MetricUnit? {
        guard let s = v as? String else { return nil }
        let normalized = normalize(s)
        if s.contains("/") || normalized.contains("perkilometer") || normalized.contains("permile") {
            return paceUnit(s)
        }
        return unitAliases[normalize(s)] ?? MetricUnit(rawValue: s)
    }
    private static func paceUnit(_ value: Any?) -> MetricUnit? {
        guard let rawValue = value as? String else { return nil }
        switch normalize(rawValue) {
        case "km", "perkm", "minkm", "secondsperkilometer": return .secondsPerKilometer
        case "mi", "permile", "minmi", "secondspermile": return .secondsPerMile
        case "sm", "secondspermeter": return .secondsPerMeter
        default: return nil
        }
    }

    /// A unit for a *value-carrying* argument (`set_metric_value`). Minutes-per-distance paces have no
    /// `MetricUnit`, so they resolve to their seconds-per form together with the ×60 the value needs —
    /// "4.5 min/km" must never be stored as 4.5 seconds per kilometer.
    private static func valueUnit(_ v: Any?) -> (unit: MetricUnit, multiplier: Double)? {
        guard let s = v as? String else { return nil }
        switch normalize(s) {
        case "minkm", "minperkm", "minutesperkilometer": return (.secondsPerKilometer, 60)
        case "minmi", "minpermile", "minutespermile": return (.secondsPerMile, 60)
        default: return unit(s).map { ($0, 1) }
        }
    }

    /// Build a metric-to-unit override dictionary and reject malformed supplied values.
    private static func unitOverrides(_ input: [String: Any]) -> [MetricType: MetricUnit]? {
        var out: [MetricType: MetricUnit] = [:]
        for (key, metric) in [
            ("distance_unit", MetricType.distance),
            ("load_unit", MetricType.load),
            ("duration_unit", MetricType.duration),
        ] where input[key] != nil {
            guard let parsed = unit(input[key]) else { return nil }
            out[metric] = parsed
        }
        if input["pace_unit"] != nil {
            guard let parsed = paceUnit(input["pace_unit"]) else { return nil }
            out[.pace] = parsed
        }
        return out
    }

    private static func doubleOrNil(_ v: Any?) -> Double? {
        if v == nil || v is NSNull { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
    private static func boolOrNil(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }
    private static func stringArrayOrNil(_ v: Any?) -> [String]? {
        if v == nil || v is NSNull { return nil }
        return v as? [String]
    }
    /// A non-blank string, or nil - models routinely send "" for an optional they meant to omit.
    private static func trimmedOrNil(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
