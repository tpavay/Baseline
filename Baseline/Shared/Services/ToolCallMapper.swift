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
            return .createWorkout(title: title, goal: input["goal"] as? String)
        case "add_block":
            guard let name = input["name"] as? String else { return nil }
            return .addBlock(name: name, intent: input["intent"] as? String)
        case "add_exercise":
            guard let block = input["block"] as? String, let name = input["name"] as? String else { return nil }
            return .addExercise(block: block, name: name,
                                sets: intOrNil(input["sets"]), reps: intOrNil(input["reps"]),
                                load: doubleOrNil(input["load"]), durationSeconds: intOrNil(input["duration_seconds"]))
        case "move_exercise":
            guard let exercise = input["exercise"] as? String, let toBlock = input["to_block"] as? String else { return nil }
            return .moveExercise(exercise: exercise, toBlock: toBlock)
        case "remove_exercise":
            guard let exercise = input["exercise"] as? String else { return nil }
            return .removeExercise(exercise: exercise)
        case "update_set":
            guard let exercise = input["exercise"] as? String, let n = intOrNil(input["set_number"]) else { return nil }
            return .updateSet(exercise: exercise, setNumber: n,
                              reps: intOrNil(input["reps"]), load: doubleOrNil(input["load"]),
                              durationSeconds: intOrNil(input["duration_seconds"]), rpe: doubleOrNil(input["rpe"]))
        case "get_current_workout":
            return .getCurrentWorkout
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
}
