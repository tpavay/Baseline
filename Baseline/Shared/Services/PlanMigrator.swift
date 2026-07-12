import Foundation

/// One-time migration of the legacy single-workout `WorkoutStore` (UserDefaults JSON) into the new
/// schedule store (`docs/implementation/plan-tab.md` §5). Idempotent, and it **never wipes** the source:
/// the old JSON stays intact (read-only recovery) — we only flip a done-flag once the new rows are
/// written. Slice 1 seeds today's `ScheduledWorkout` (+ any in-flight or completed log) in a `Baseline`
/// ad-hoc program with origin `.legacyMigrated`.
enum PlanMigrator {
    static let flagKey = "plan.migrated.v1"

    @MainActor
    static func migrateIfNeeded(defaults: UserDefaults = .standard, into plan: PlanStore,
                                workouts: WorkoutStore, today: Date = Date()) {
        guard !defaults.bool(forKey: flagKey) else { return }
        defer { defaults.set(true, forKey: flagKey) }   // old JSON is untouched; only the flag is set

        guard let workout = workouts.current else { return }
        let program = plan.addProgram(Program(name: "Baseline", createdAt: today))
        let scheduled = plan.addScheduled(ScheduledWorkout(
            programID: program.id, date: today, origin: .legacyMigrated,
            workoutID: workout.id, workoutRevisionID: UUID(), workout: workout))

        // Carry over an in-flight or completed log through the public lifecycle API.
        if let log = workouts.currentLog {
            _ = plan.start(scheduled.id)                      // creates an active session (fresh log)
            plan.updateSessionLog(scheduled.id) { $0 = log }  // overwrite with the migrated actuals
            if log.isComplete { _ = plan.complete(scheduled.id, acknowledgingOpenWork: true) }
        }
    }
}
