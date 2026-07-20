import Foundation

/// Compares the workout **as it was shaped during a session** against the **saved plan** it started
/// from, so completion can ask whether to promote the session's edits back to the scheduled plan.
///
/// Mid-workout edits (add / true-remove / reorder / replace / metric changes) are session-scoped — they
/// live on the session's own `Workout` copy and its log, never touching the saved scheduled workout
/// until the athlete opts in at completion. This is the pure, view-free diff that drives that
/// opt-in: it is deterministic and unit-tested so the "we noticed changes from your plan" summary is
/// trustworthy.
enum WorkoutSessionReconciliation {

    /// The workout the athlete actually shaped this session: the session's plan copy with any top-level
    /// exercise substitutions (log "Replace Exercise") folded in. Per-round substitutions and skips stay
    /// out — a skip means "not today", not "change my plan", and a per-round swap is a logging fact.
    static func effectiveSessionPlan(base: Workout, log: WorkoutLog) -> Workout {
        var workout = base
        for exercise in base.allExercises {
            let effective = log.effectiveExercise(for: exercise)
            if effective != exercise {
                workout.updateExercise(exercise.id) { $0 = effective }
            }
        }
        return workout
    }

    /// Diff the original plan against the effective session plan. Empty ⇒ nothing changed ⇒ no prompt.
    static func diff(plan original: Workout, session: Workout) -> WorkoutSessionDiff {
        var changes: [WorkoutSessionDiff.Change] = []

        // Block-level structure (a deleted block removes its exercises too, but calling that out
        // directly reads better than a wall of per-exercise "removed" lines).
        let originalBlockIDs = Set(original.blocks.map(\.id))
        let sessionBlockIDs = Set(session.blocks.map(\.id))
        for block in session.blocks where !originalBlockIDs.contains(block.id) {
            changes.append(.init(kind: .blockAdded, summary: "Added block \(blockName(block))"))
        }
        for block in original.blocks where !sessionBlockIDs.contains(block.id) {
            changes.append(.init(kind: .blockRemoved, summary: "Removed block \(blockName(block))"))
        }

        let originalExercises = original.allExercises
        let sessionExercises = session.allExercises
        // Workouts also arrive from JSON import and agent tools, so a duplicated exercise id is
        // data-shaped rather than impossible. Keep the first occurrence instead of trapping at the
        // exact moment the athlete taps Finish Workout.
        let originalByID = Dictionary(originalExercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sessionByID = Dictionary(sessionExercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Added exercises live in a block that already existed (a brand-new block is reported above).
        for exercise in sessionExercises where originalByID[exercise.id] == nil {
            if let blockID = session.blockID(forExercise: exercise.id), originalBlockIDs.contains(blockID) {
                changes.append(.init(kind: .added, summary: "Added \(name(exercise))"))
            }
        }
        for exercise in originalExercises where sessionByID[exercise.id] == nil {
            if let blockID = original.blockID(forExercise: exercise.id), sessionBlockIDs.contains(blockID) {
                changes.append(.init(kind: .removed, summary: "Removed \(name(exercise))"))
            }
        }

        // Same identity, changed content: a replace (different movement) or a prescription/metric change.
        for exercise in sessionExercises {
            guard let before = originalByID[exercise.id] else { continue }
            if before.definitionId != exercise.definitionId || before.exerciseName != exercise.exerciseName {
                changes.append(.init(kind: .replaced, summary: "Replaced \(name(before)) with \(name(exercise))"))
            } else if before.prescription != exercise.prescription
                || before.selectedMetrics != exercise.selectedMetrics
                || before.displayUnits != exercise.displayUnits {
                changes.append(.init(kind: .adjusted, summary: "Adjusted \(name(exercise))"))
            }
        }

        // Reorder: among the exercises common to both (and not otherwise changed), did their relative
        // order move? Adds/removes shift absolute positions, so relative order of the shared set is the
        // honest signal.
        let commonInOriginal = originalExercises.map(\.id).filter { sessionByID[$0] != nil }
        let commonInSession = sessionExercises.map(\.id).filter { originalByID[$0] != nil }
        if commonInOriginal != commonInSession {
            changes.append(.init(kind: .reordered, summary: "Reordered exercises"))
        }

        return WorkoutSessionDiff(changes: changes)
    }

    private static func name(_ exercise: PlannedExercise) -> String {
        let label = exercise.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, !label.isEmpty { return label }
        return exercise.exerciseName
    }

    private static func blockName(_ block: WorkoutBlock) -> String {
        block.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Main" : block.name
    }
}

/// The set of differences between a saved plan and the session as the athlete shaped it. Deterministic
/// and `Equatable` so it can be asserted directly in tests and rendered in the completion prompt.
struct WorkoutSessionDiff: Equatable {
    struct Change: Equatable, Identifiable {
        enum Kind: String, Equatable {
            case added, removed, replaced, adjusted, reordered, blockAdded, blockRemoved
        }
        let kind: Kind
        let summary: String
        var id: String { "\(kind.rawValue):\(summary)" }
    }

    var changes: [Change]

    var hasChanges: Bool { !changes.isEmpty }

    /// A single-line, human summary for the prompt body — "Added Bench Press; Reordered exercises".
    var summaryLine: String {
        changes.map(\.summary).joined(separator: "; ")
    }
}

private extension Workout {
    /// The block that directly contains a top-level exercise node, if any. (Exercises nested inside a
    /// group or choice are not surfaced for mid-workout structural editing, so they return nil.)
    func blockID(forExercise exerciseID: UUID) -> UUID? {
        for block in blocks {
            for node in block.nodes {
                if case .exercise(let exercise) = node, exercise.id == exerciseID { return block.id }
            }
        }
        return nil
    }
}
