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
            guard let title = input["title"] as? String else { return nil }
            return .createWorkout(title: title, goal: input["goal"] as? String,
                                  replaceExisting: boolOrNil(input["replace_existing"]) ?? false)
        case "add_block":
            guard let name = input["name"] as? String else { return nil }
            return .addBlock(name: name, intent: input["intent"] as? String)
        case "add_exercise":
            guard let block = input["block"] as? String, let name = input["name"] as? String else { return nil }
            return .addExercise(block: block, name: name,
                                sets: intOrNil(input["sets"]), reps: intOrNil(input["reps"]),
                                load: doubleOrNil(input["load"]), durationSeconds: intOrNil(input["duration_seconds"]),
                                distanceMeters: doubleOrNil(input["distance_m"]))
        case "move_exercise":
            guard let exercise = input["exercise"] as? String,
                  let toBlock = input["to_block"] as? String,
                  validOptionalUUID(input["exercise_id"]),
                  validOptionalUUID(input["to_block_id"]) else { return nil }
            return .moveExercise(
                exercise: exercise,
                exerciseID: uuid(input["exercise_id"]),
                toBlock: toBlock,
                toBlockID: uuid(input["to_block_id"])
            )
        case "replace_exercise":
            guard let exercise = input["exercise"] as? String,
                  let replacement = input["replacement"] as? String,
                  validOptionalUUID(input["exercise_id"]) else { return nil }
            return .replaceExercise(
                exercise: exercise,
                exerciseID: uuid(input["exercise_id"]),
                replacement: replacement,
                block: input["block"] as? String,
                replaceAll: boolOrNil(input["replace_all"]) ?? false
            )
        case "require_all_options":
            guard let choice = input["choice"] as? String else { return nil }
            return .requireAllOptions(choice: choice)
        case "remove_exercise":
            guard let exercise = input["exercise"] as? String,
                  validOptionalUUID(input["exercise_id"]) else { return nil }
            return .removeExercise(exercise: exercise, exerciseID: uuid(input["exercise_id"]))
        case "update_set":
            guard let exercise = input["exercise"] as? String,
                  let n = intOrNil(input["set_number"]),
                  validOptionalUUID(input["set_id"]) else { return nil }
            return .updateSet(exercise: exercise, setNumber: n, setID: uuid(input["set_id"]),
                              reps: intOrNil(input["reps"]), load: doubleOrNil(input["load"]),
                              durationSeconds: intOrNil(input["duration_seconds"]),
                              distanceMeters: doubleOrNil(input["distance_m"]), rpe: doubleOrNil(input["rpe"]))
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
            guard let ex = input["exercise"] as? String,
                  validOptionalUUID(input["exercise_id"]) else { return nil }
            return .updateLoggingConfig(
                exercise: ex,
                exerciseID: uuid(input["exercise_id"]),
                enabledMetrics: metricList(input["enabled_metrics"]),
                units: unitOverrides(input)
            )
        case "update_exercise_preference":
            guard let ex = input["exercise"] as? String else { return nil }
            let scope: WorkoutStore.PreferenceScope = (input["scope"] as? String) == "category" ? .category : .exercise
            return .updateExercisePreference(exercise: ex, scope: scope, units: unitOverrides(input), selectedMetrics: metricList(input["enabled_metrics"]))
        case "set_metric_value":
            guard let ex = input["exercise"] as? String, let n = intOrNil(input["set_number"]),
                  let m = metric(input["metric"]), let v = doubleOrNil(input["value"]),
                  validOptionalUUID(input["set_id"]) else { return nil }
            return .setMetricValue(
                exercise: ex,
                setNumber: n,
                setID: uuid(input["set_id"]),
                metric: m,
                value: v,
                unit: unit(input["unit"])
            )
        case "remove_metric":
            guard let ex = input["exercise"] as? String, let m = metric(input["metric"]),
                  validOptionalUUID(input["exercise_id"]) else { return nil }
            return .removeMetric(exercise: ex, exerciseID: uuid(input["exercise_id"]), metric: m)
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

    private static func uuid(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string)
    }

    /// Omitted IDs preserve the legacy name-based path. A supplied malformed ID rejects the call
    /// instead of silently falling back to a potentially ambiguous name.
    private static func validOptionalUUID(_ value: Any?) -> Bool {
        value == nil || value is NSNull || uuid(value) != nil
    }
    // MARK: - Metric / unit parsing (tolerant of casual names the model may emit)

    private static let metricAliases: [String: MetricType] = [
        "reps": .reps, "rep": .reps, "load": .load, "weight": .load,
        "duration": .duration, "time": .duration, "distance": .distance,
        "calories": .calories, "cals": .calories, "cal": .calories,
        "heartrate": .heartRate, "heart_rate": .heartRate, "hr": .heartRate, "avghr": .heartRate,
        "hrzonetime": .heartRateZoneTime, "zonetime": .heartRateZoneTime,
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
        return arr.compactMap { metric($0) }
    }
    private static func unit(_ v: Any?) -> MetricUnit? {
        guard let s = v as? String else { return nil }
        return unitAliases[normalize(s)] ?? MetricUnit(rawValue: s)
    }
    /// Build a metric→unit override dict from the tool's distance_unit / load_unit / duration_unit.
    private static func unitOverrides(_ input: [String: Any]) -> [MetricType: MetricUnit] {
        var out: [MetricType: MetricUnit] = [:]
        if let u = unit(input["distance_unit"]) { out[.distance] = u }
        if let u = unit(input["load_unit"]) { out[.load] = u }
        if let u = unit(input["duration_unit"]) { out[.duration] = u }
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
