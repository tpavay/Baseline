import Foundation
import Observation

/// Holds the athlete's **current structured workout** and applies validated edits. The conversation's
/// plan-edit tools write here; the workout screen (later) reads here. Local-first (UserDefaults JSON),
/// same pattern as `TrainingContextStore`.
///
/// The model speaks in *names* ("move bench to the warm-up block"); this resolves names → ids and
/// calls the id-based operations on `Workout` (which own the invariants + are unit-tested). Every
/// mutation is get-copy-mutate-reassign so `@Observable` fires and it persists.
@MainActor
@Observable
final class WorkoutStore {
    private(set) var current: Workout? { didSet { persist(current, Self.key) } }
    /// The in-progress performed log (actual sets, skips, notes) once a workout is started. Distinct
    /// from `current` (the plan) — logging never mutates the plan.
    private(set) var currentLog: WorkoutLog? { didSet { persist(currentLog, Self.logKey) } }

    private let defaults: UserDefaults
    private static let key = "workout.current"
    private static let logKey = "workout.currentLog"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Workout.self, from: $0) }
        currentLog = defaults.data(forKey: Self.logKey).flatMap { try? JSONDecoder().decode(WorkoutLog.self, from: $0) }
    }

    // MARK: - UI-facing edits (id-based; the manual screen drives the same model the agent does)

    /// Apply an id-based structural edit to the plan (add/remove/reorder/move/substitute) and persist.
    func edit(_ transform: (inout Workout) -> Void) {
        guard var w = current else { return }
        transform(&w)
        current = w
    }

    /// Begin performing: create the performed log from the current plan (linked, read-only over it).
    func startWorkout() {
        guard let w = current, currentLog == nil else { return }
        currentLog = w.startLog()
    }

    /// Apply an edit to the performed log (log a set, skip/complete, note) and persist.
    func editLog(_ transform: (inout WorkoutLog) -> Void) {
        guard var l = currentLog else { return }
        transform(&l)
        currentLog = l
    }

    func completeWorkout() { editLog { $0.isComplete = true } }
    func discardLog() { currentLog = nil }

    /// Result of a name-resolved edit — so the tool layer asks the athlete to disambiguate (exactly
    /// what a coach does with two same-named movements) instead of silently guessing.
    enum EditOutcome {
        case done
        case notFound(String)
        case ambiguous(String)
        var succeeded: Bool { if case .done = self { return true } else { return false } }
    }

    /// Whether the stored workout is for today. Unstamped (legacy) workouts count as today's; a
    /// workout from an earlier day must not be presented as "today's".
    var currentIsForToday: Bool {
        guard let date = current?.scheduledDate else { return true }
        return Calendar.current.isDateInToday(date)
    }

    // MARK: - Tool-facing operations (name-resolved)

    func create(title: String, goal: String?) {
        var w = Workout(title: title, goal: goal)
        w.scheduledDate = Calendar.current.startOfDay(for: .now)
        current = w
        currentLog = nil            // a new workout starts with a clean performed log
    }

    // Numeric guards at the tool boundary — the model can propose anything; reps/load/duration can't
    // go negative and RPE is 0–10.
    private func clampReps(_ v: Int?) -> Int? { v.map { max(0, $0) } }
    private func clampLoad(_ v: Double?) -> Double? { v.map { max(0, $0) } }
    private func clampDuration(_ v: Int?) -> Int? { v.map { max(0, $0) } }
    private func clampRPE(_ v: Double?) -> Double? { v.map { min(max($0, 0), 10) } }

    @discardableResult
    func addBlock(name: String, intent: String?) -> Bool {
        guard var w = current else { return false }
        w.addBlock(name: name, intent: intent)
        current = w
        return true
    }

    @discardableResult
    func addExercise(name: String, toBlockNamed block: String,
                     sets: Int?, reps: Int?, load: Double?, durationSeconds: Int?) -> EditOutcome {
        guard var w = current else { return .notFound("There's no workout yet — create one first.") }
        let blockID: UUID
        switch resolveBlock(block, in: w) {
        case .none: return .notFound("I couldn't find a block called \"\(block)\".")
        case .one(let id): blockID = id
        case .many(let opts): return .ambiguous(ambiguity(block, opts, kind: "blocks"))
        }
        let count = max(1, sets ?? 1)
        var exercise = PlannedExercise(exerciseName: name)
        exercise.prescription.sets = (0..<count).map { _ in
            PlannedSet(reps: clampReps(reps), load: clampLoad(load), duration: clampDuration(durationSeconds))
        }
        _ = w.addExercise(exercise, toBlock: blockID)
        current = w
        return .done
    }

    @discardableResult
    func moveExercise(named exercise: String, toBlockNamed block: String) -> EditOutcome {
        guard var w = current else { return .notFound("There's no workout yet.") }
        let exID: UUID
        switch resolveExercise(exercise, in: w) {
        case .none: return .notFound("I couldn't find \"\(exercise)\" in the workout.")
        case .one(let id): exID = id
        case .many(let opts): return .ambiguous(ambiguity(exercise, opts, kind: "exercises"))
        }
        let blockID: UUID
        switch resolveBlock(block, in: w) {
        case .none: return .notFound("I couldn't find a block called \"\(block)\".")
        case .one(let id): blockID = id
        case .many(let opts): return .ambiguous(ambiguity(block, opts, kind: "blocks"))
        }
        _ = w.moveExercise(exID, toBlock: blockID)
        current = w
        return .done
    }

    @discardableResult
    func removeExercise(named exercise: String) -> EditOutcome {
        guard var w = current else { return .notFound("There's no workout yet.") }
        switch resolveExercise(exercise, in: w) {
        case .none: return .notFound("I couldn't find \"\(exercise)\" in the workout.")
        case .many(let opts): return .ambiguous(ambiguity(exercise, opts, kind: "exercises"))
        case .one(let id): _ = w.removeExercise(id); current = w; return .done
        }
    }

    /// Update one set (1-based `setNumber`) of a named exercise. Only the supplied fields change.
    @discardableResult
    func updateSet(exerciseNamed exercise: String, setNumber: Int,
                   reps: Int?, load: Double?, durationSeconds: Int?, rpe: Double?) -> EditOutcome {
        guard var w = current else { return .notFound("There's no workout yet.") }
        let exID: UUID
        switch resolveExercise(exercise, in: w) {
        case .none: return .notFound("I couldn't find \"\(exercise)\" in the workout.")
        case .one(let id): exID = id
        case .many(let opts): return .ambiguous(ambiguity(exercise, opts, kind: "exercises"))
        }
        guard let ex = w.allExercises.first(where: { $0.id == exID }),
              setNumber >= 1, setNumber <= ex.prescription.sets.count else {
            return .notFound("Set \(setNumber) doesn't exist for \(exercise).")
        }
        let setID = ex.prescription.sets[setNumber - 1].id
        _ = w.updateSet(setID) { s in
            if let reps { s.reps = clampReps(reps) }
            if let load { s.load = clampLoad(load) }
            if let durationSeconds { s.duration = clampDuration(durationSeconds) }
            if let rpe { s.rpe = clampRPE(rpe) }
        }
        current = w
        return .done
    }

    // MARK: - Read

    /// A compact, model-and-inspector-friendly rendering of the current workout.
    var summary: String {
        guard let w = current else { return "No workout has been created yet." }
        var lines = ["Workout: \(w.title)" + (w.goal.map { " — goal: \($0)" } ?? "")]
        if w.blocks.isEmpty { lines.append("(no blocks yet)") }
        for block in w.blocks {
            lines.append("• \(block.name)" + (block.intent.map { " (\($0))" } ?? ""))
            if block.exercises.isEmpty { lines.append("    (empty)") }
            for ex in block.exercises {
                lines.append("    - \(ex.exerciseName): \(prescriptionText(ex.prescription))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func prescriptionText(_ p: Prescription) -> String {
        guard !p.sets.isEmpty else { return "no sets" }
        let parts = p.sets.enumerated().map { i, s -> String in
            var bits: [String] = []
            if let r = s.reps { bits.append("\(r) reps") }
            if let l = s.load { bits.append("\(clean(l)) load") }
            if let d = s.duration { bits.append("\(d)s") }
            return "set \(i + 1): " + (bits.isEmpty ? "—" : bits.joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }

    private func clean(_ v: Double) -> String { String(format: "%g", v) }

    // MARK: - Name resolution (exact case-insensitive, else contains) — ambiguity-aware

    private struct Hit { let id: UUID; let label: String; let block: String }
    private enum Match { case none; case one(UUID); case many([Hit]) }

    /// Prefer exact matches; only fall back to substring matches if there are no exact ones. More
    /// than one survivor → ambiguous (ask), never a silent first-match.
    private func classify(_ exact: [Hit], _ fuzzy: [Hit]) -> Match {
        let hits = exact.isEmpty ? fuzzy : exact
        switch hits.count {
        case 0: return .none
        case 1: return .one(hits[0].id)
        default: return .many(hits)
        }
    }

    private func resolveExercise(_ name: String, in w: Workout) -> Match {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var exact: [Hit] = [], fuzzy: [Hit] = []
        for b in w.blocks {
            for ex in b.exercises {
                if ex.exerciseName.localizedCaseInsensitiveCompare(key) == .orderedSame {
                    exact.append(Hit(id: ex.id, label: ex.exerciseName, block: b.name))
                } else if ex.exerciseName.localizedCaseInsensitiveContains(key) {
                    fuzzy.append(Hit(id: ex.id, label: ex.exerciseName, block: b.name))
                }
            }
        }
        return classify(exact, fuzzy)
    }

    private func resolveBlock(_ name: String, in w: Workout) -> Match {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var exact: [Hit] = [], fuzzy: [Hit] = []
        for b in w.blocks {
            if b.name.localizedCaseInsensitiveCompare(key) == .orderedSame {
                exact.append(Hit(id: b.id, label: b.name, block: b.name))
            } else if b.name.localizedCaseInsensitiveContains(key) {
                fuzzy.append(Hit(id: b.id, label: b.name, block: b.name))
            }
        }
        return classify(exact, fuzzy)
    }

    private func ambiguity(_ name: String, _ opts: [Hit], kind: String) -> String {
        let list = opts.map { kind == "exercises" ? "\"\($0.label)\" in \($0.block)" : "\"\($0.label)\"" }
            .joined(separator: ", ")
        return "There are \(opts.count) \(kind) matching \"\(name)\": \(list). Which one?"
    }

    // MARK: - Persistence

    private func persist<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
