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
    private(set) var current: Workout? { didSet { persist() } }

    private let defaults: UserDefaults
    private static let key = "workout.current"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Workout.self, from: $0) }
    }

    // MARK: - Tool-facing operations (name-resolved)

    func create(title: String, goal: String?) {
        current = Workout(title: title, goal: goal)
    }

    @discardableResult
    func addBlock(name: String, intent: String?) -> Bool {
        guard var w = current else { return false }
        w.addBlock(name: name, intent: intent)
        current = w
        return true
    }

    @discardableResult
    func addExercise(name: String, toBlockNamed block: String,
                     sets: Int?, reps: Int?, load: Double?, durationSeconds: Int?) -> Bool {
        guard var w = current, let blockID = blockID(named: block, in: w) else { return false }
        let count = max(1, sets ?? 1)
        let template = PlannedSet(reps: reps, load: load, duration: durationSeconds)
        var exercise = PlannedExercise(exerciseName: name)
        exercise.prescription.sets = (0..<count).map { _ in PlannedSet(reps: template.reps, load: template.load, duration: template.duration) }
        let ok = w.addExercise(exercise, toBlock: blockID)
        if ok { current = w }
        return ok
    }

    @discardableResult
    func moveExercise(named exercise: String, toBlockNamed block: String) -> Bool {
        guard var w = current, let exID = exerciseID(named: exercise, in: w), let blockID = blockID(named: block, in: w) else { return false }
        let ok = w.moveExercise(exID, toBlock: blockID)
        if ok { current = w }
        return ok
    }

    @discardableResult
    func removeExercise(named exercise: String) -> Bool {
        guard var w = current, let exID = exerciseID(named: exercise, in: w) else { return false }
        let ok = w.removeExercise(exID)
        if ok { current = w }
        return ok
    }

    /// Update one set (1-based `setNumber`) of a named exercise. Only the supplied fields change.
    @discardableResult
    func updateSet(exerciseNamed exercise: String, setNumber: Int,
                   reps: Int?, load: Double?, durationSeconds: Int?, rpe: Double?) -> Bool {
        guard var w = current, let exID = exerciseID(named: exercise, in: w),
              let ex = w.allExercises.first(where: { $0.id == exID }),
              setNumber >= 1, setNumber <= ex.prescription.sets.count else { return false }
        let setID = ex.prescription.sets[setNumber - 1].id
        let ok = w.updateSet(setID) { s in
            if let reps { s.reps = reps }
            if let load { s.load = load }
            if let durationSeconds { s.duration = durationSeconds }
            if let rpe { s.rpe = rpe }
        }
        if ok { current = w }
        return ok
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

    // MARK: - Name resolution (exact case-insensitive, else contains)

    private func blockID(named name: String, in w: Workout) -> UUID? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.blocks.first { $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }?.id
            ?? w.blocks.first { $0.name.localizedCaseInsensitiveContains(key) }?.id
    }

    private func exerciseID(named name: String, in w: Workout) -> UUID? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = w.allExercises
        return all.first { $0.exerciseName.localizedCaseInsensitiveCompare(key) == .orderedSame }?.id
            ?? all.first { $0.exerciseName.localizedCaseInsensitiveContains(key) }?.id
    }

    // MARK: - Persistence

    private func persist() {
        if let current, let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: Self.key)
        } else if current == nil {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
