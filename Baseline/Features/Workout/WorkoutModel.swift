import Foundation

/// The **structured workout model** — the first implementation of the editable training hierarchy
/// from `docs/implementation/plan-engine.md`. Pure value types (no SwiftData / SwiftUI yet), so the
/// structure and its editing operations are nailed down and unit-tested before persistence, UI, and
/// agent tools wrap them.
///
/// Two invariants the docs demand, enforced here:
/// - **No layer is atomic.** Blocks, exercises, and sets are all independently editable; exercises
///   move freely between blocks. A `WorkoutBlock` is a *semantic container*, not a lock.
/// - **Planned vs performed stay separate.** Editing a `Workout` never touches a `WorkoutLog`;
///   logging actuals never mutates the plan. `startLog()` is the one bridge, and it only *reads*.
///
/// Order is array position — moves/reorders are unambiguous and reversible without a separate field.

// MARK: - Planned side (intended training — owned by the Plan Engine)

enum TrainingIntent: String, Codable, Sendable, CaseIterable {
    case easy, threshold, intervals, vo2, speed, long, race, strength, recovery, mobility
}

/// A single planned set or interval — addressable on its own so one set can change without
/// rewriting the exercise. Values are stored canonically in a typed `MetricValues`; the named
/// accessors are ergonomic sugar over specific metrics (they never add new stored fields).
struct PlannedSet: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var values = MetricValues()

    init(reps: Int? = nil, load: Double? = nil, duration: Int? = nil,
         distance: Double? = nil, calories: Double? = nil, rpe: Double? = nil) {
        values.setInt(.reps, reps); values[.load] = load; values.setInt(.duration, duration)
        values[.distance] = distance; values[.calories] = calories; values[.rpe] = rpe
    }
    init(values: MetricValues) { self.values = values }

    var reps: Int? { get { values.int(.reps) } set { values.setInt(.reps, newValue) } }
    var load: Double? { get { values[.load] } set { values[.load] = newValue } }
    var duration: Int? { get { values.int(.duration) } set { values.setInt(.duration, newValue) } }
    var distance: Double? { get { values[.distance] } set { values[.distance] = newValue } }
    var calories: Double? { get { values[.calories] } set { values[.calories] = newValue } }
    var rpe: Double? { get { values[.rpe] } set { values[.rpe] = newValue } }
}

/// The structured target for a planned exercise — never free text.
struct Prescription: Codable, Equatable, Sendable {
    var sets: [PlannedSet] = []
    var restSeconds: Int?
    var intent: TrainingIntent?
    var targetZone: Int?       // HR zone 1–5
    var tempo: String?         // e.g. "3-1-1-0"
}

/// Authored "how and why to do it" — kept separate from the prescription and from Athlete Notes.
struct CoachGuidance: Codable, Equatable, Sendable {
    var goal: String?
    var tempo: String?
    var formCues: [String] = []
    var commonMistakes: [String] = []
    var progressionNotes: String?
}

struct PlannedExercise: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var exerciseName: String
    var definitionId: String?                       // stable catalog identity (nil = uncurated)
    var selectedMetrics: [MetricType] = []          // which metrics this instance logs/shows
    var displayUnits: [MetricType: MetricUnit] = [:] // this-instance unit overrides
    var prescription = Prescription()
    var guidance: CoachGuidance?

    /// The catalog definition backing this exercise (generic when uncurated).
    var definition: ExerciseDefinition { definitionId.flatMap(ExerciseCatalog.definition(id:)) ?? ExerciseCatalog.generic }
    var supportedMetrics: [MetricType] { definition.supported }
}

/// A semantic group inside a workout (warm-up, strength, metcon, station work). Explains *purpose*;
/// does not lock its contents.
struct WorkoutBlock: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var intent: String?
    var exercises: [PlannedExercise] = []
}

struct Workout: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var goal: String?
    var scheduledDate: Date?          // the day this workout is for; nil = legacy/unstamped
    var blocks: [WorkoutBlock] = []
}

// MARK: - Editing operations (validated; every level is editable)

extension Workout {

    // Workout level
    mutating func updateGoal(_ goal: String?) { self.goal = goal }
    mutating func rename(_ title: String) { self.title = title }

    // Block level
    @discardableResult
    mutating func addBlock(name: String, intent: String? = nil) -> UUID {
        let block = WorkoutBlock(name: name, intent: intent)
        blocks.append(block)
        return block.id
    }

    @discardableResult
    mutating func removeBlock(_ id: UUID) -> Bool {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return false }
        blocks.remove(at: i)
        return true
    }

    @discardableResult
    mutating func moveBlock(_ id: UUID, to index: Int) -> Bool {
        guard let from = blocks.firstIndex(where: { $0.id == id }),
              index >= 0, index <= blocks.count - 1 else { return false }
        let block = blocks.remove(at: from)
        blocks.insert(block, at: index)
        return true
    }

    @discardableResult
    mutating func renameBlock(_ id: UUID, to name: String) -> Bool {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return false }
        blocks[i].name = name
        return true
    }

    @discardableResult
    mutating func setBlockIntent(_ id: UUID, _ intent: String?) -> Bool {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return false }
        blocks[i].intent = intent
        return true
    }

    @discardableResult
    mutating func duplicateBlock(_ id: UUID) -> UUID? {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = blocks[i]
        copy.id = UUID()
        copy.name += " (copy)"
        copy.exercises = copy.exercises.map { ex in
            var e = ex; e.id = UUID()
            e.prescription.sets = e.prescription.sets.map { var s = $0; s.id = UUID(); return s }
            return e
        }
        blocks.insert(copy, at: i + 1)
        return copy.id
    }

    // Exercise level
    @discardableResult
    mutating func addExercise(_ exercise: PlannedExercise, toBlock blockID: UUID) -> Bool {
        guard let i = blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        blocks[i].exercises.append(exercise)
        return true
    }

    @discardableResult
    mutating func removeExercise(_ id: UUID) -> Bool {
        guard let loc = locate(id) else { return false }
        blocks[loc.block].exercises.remove(at: loc.exercise)
        return true
    }

    /// Move an exercise to another block (or reposition within one) — the cross-block move the docs
    /// call out. `index` clamps into the destination.
    @discardableResult
    mutating func moveExercise(_ id: UUID, toBlock blockID: UUID, at index: Int? = nil) -> Bool {
        guard let loc = locate(id), let dest = blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        let exercise = blocks[loc.block].exercises.remove(at: loc.exercise)
        let target = min(max(index ?? blocks[dest].exercises.count, 0), blocks[dest].exercises.count)
        blocks[dest].exercises.insert(exercise, at: target)
        return true
    }

    @discardableResult
    mutating func reorderExercise(_ id: UUID, to index: Int) -> Bool {
        guard let loc = locate(id) else { return false }
        var exercises = blocks[loc.block].exercises
        guard index >= 0, index <= exercises.count - 1 else { return false }
        let exercise = exercises.remove(at: loc.exercise)
        exercises.insert(exercise, at: index)
        blocks[loc.block].exercises = exercises
        return true
    }

    /// Swap the movement while keeping the exercise's identity + position (so history/undo stay
    /// stable). Prescription is replaced; guidance is dropped unless carried by the caller.
    @discardableResult
    mutating func substituteExercise(_ id: UUID, withName name: String, prescription: Prescription) -> Bool {
        guard let loc = locate(id) else { return false }
        blocks[loc.block].exercises[loc.exercise].exerciseName = name
        blocks[loc.block].exercises[loc.exercise].prescription = prescription
        return true
    }

    @discardableResult
    mutating func updateGuidance(_ exerciseID: UUID, _ guidance: CoachGuidance?) -> Bool {
        guard let loc = locate(exerciseID) else { return false }
        blocks[loc.block].exercises[loc.exercise].guidance = guidance
        return true
    }

    // Set level — one set changes without rewriting the exercise
    @discardableResult
    mutating func addSet(_ set: PlannedSet, toExercise exerciseID: UUID) -> Bool {
        guard let loc = locate(exerciseID) else { return false }
        blocks[loc.block].exercises[loc.exercise].prescription.sets.append(set)
        return true
    }

    @discardableResult
    mutating func removeSet(_ setID: UUID) -> Bool {
        guard let loc = locateSet(setID) else { return false }
        blocks[loc.block].exercises[loc.exercise].prescription.sets.remove(at: loc.set)
        return true
    }

    @discardableResult
    mutating func updateSet(_ setID: UUID, _ transform: (inout PlannedSet) -> Void) -> Bool {
        guard let loc = locateSet(setID) else { return false }
        transform(&blocks[loc.block].exercises[loc.exercise].prescription.sets[loc.set])
        return true
    }

    @discardableResult
    mutating func updateExercise(_ id: UUID, _ transform: (inout PlannedExercise) -> Void) -> Bool {
        guard let loc = locate(id) else { return false }
        transform(&blocks[loc.block].exercises[loc.exercise])
        return true
    }

    func exercise(_ id: UUID) -> PlannedExercise? { allExercises.first { $0.id == id } }

    // MARK: - Lookup helpers

    private func locate(_ exerciseID: UUID) -> (block: Int, exercise: Int)? {
        for (b, block) in blocks.enumerated() {
            if let e = block.exercises.firstIndex(where: { $0.id == exerciseID }) { return (b, e) }
        }
        return nil
    }

    private func locateSet(_ setID: UUID) -> (block: Int, exercise: Int, set: Int)? {
        for (b, block) in blocks.enumerated() {
            for (e, ex) in block.exercises.enumerated() {
                if let s = ex.prescription.sets.firstIndex(where: { $0.id == setID }) { return (b, e, s) }
            }
        }
        return nil
    }

    /// All planned exercises across blocks, in order.
    var allExercises: [PlannedExercise] { blocks.flatMap(\.exercises) }
}

// MARK: - Performed side (actual training — owned by Workout Execution)

enum PerformedStatus: String, Codable, Sendable {
    case pending, completed, skipped, substituted, modified
}

/// An actually-logged set — links back to a planned set, never overwrites it. Same typed
/// `MetricValues` storage + accessors as `PlannedSet`.
struct SetLog: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var plannedSetID: UUID?
    var values = MetricValues()

    init(plannedSetID: UUID? = nil, reps: Int? = nil, load: Double? = nil, duration: Int? = nil,
         distance: Double? = nil, calories: Double? = nil, rpe: Double? = nil) {
        self.plannedSetID = plannedSetID
        values.setInt(.reps, reps); values[.load] = load; values.setInt(.duration, duration)
        values[.distance] = distance; values[.calories] = calories; values[.rpe] = rpe
    }
    init(plannedSetID: UUID? = nil, values: MetricValues) { self.plannedSetID = plannedSetID; self.values = values }

    var reps: Int? { get { values.int(.reps) } set { values.setInt(.reps, newValue) } }
    var load: Double? { get { values[.load] } set { values[.load] = newValue } }
    var duration: Int? { get { values.int(.duration) } set { values.setInt(.duration, newValue) } }
    var distance: Double? { get { values[.distance] } set { values[.distance] = newValue } }
    var calories: Double? { get { values[.calories] } set { values[.calories] = newValue } }
    var rpe: Double? { get { values[.rpe] } set { values[.rpe] = newValue } }
}

struct PerformedExercise: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var plannedExerciseID: UUID?          // link to the plan; nil for ad-hoc adds
    var exerciseName: String
    var status: PerformedStatus = .pending
    var substitutionFor: UUID?
    var reason: String?
    var setLogs: [SetLog] = []
    var athleteNotes: [String] = []
}

/// The performed record for a workout. It references the planned workout but is a distinct object —
/// the plan is never mutated by logging.
struct WorkoutLog: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var plannedWorkoutID: UUID?
    var exercises: [PerformedExercise] = []
    var athleteNotes: [String] = []
    var isComplete = false
}

extension WorkoutLog {
    /// The performed record for a planned exercise, creating a pending one if absent (e.g. an
    /// exercise added to the plan mid-session).
    private mutating func index(forPlanned plannedID: UUID, name: String) -> Int {
        if let i = exercises.firstIndex(where: { $0.plannedExerciseID == plannedID }) { return i }
        exercises.append(PerformedExercise(plannedExerciseID: plannedID, exerciseName: name))
        return exercises.count - 1
    }

    func performed(forPlanned plannedID: UUID) -> PerformedExercise? {
        exercises.first { $0.plannedExerciseID == plannedID }
    }

    mutating func logSet(_ set: SetLog, forPlanned plannedID: UUID, name: String) {
        exercises[index(forPlanned: plannedID, name: name)].setLogs.append(set)
    }

    mutating func setStatus(_ status: PerformedStatus, forPlanned plannedID: UUID, name: String, reason: String? = nil) {
        let i = index(forPlanned: plannedID, name: name)
        exercises[i].status = status
        if let reason { exercises[i].reason = reason }
    }

    mutating func addNote(_ note: String, forPlanned plannedID: UUID, name: String) {
        exercises[index(forPlanned: plannedID, name: name)].athleteNotes.append(note)
    }

    mutating func updateSetLog(_ id: UUID, _ transform: (inout SetLog) -> Void) {
        for e in exercises.indices {
            if let s = exercises[e].setLogs.firstIndex(where: { $0.id == id }) { transform(&exercises[e].setLogs[s]); return }
        }
    }

    mutating func removeSetLog(_ id: UUID) {
        for e in exercises.indices { exercises[e].setLogs.removeAll { $0.id == id } }
    }
}

extension Workout {
    /// Begin performing this workout: a fresh `WorkoutLog` with one pending `PerformedExercise` per
    /// planned exercise, each linked back by id. Read-only over the plan — the returned log is what
    /// the athlete edits during execution.
    func startLog() -> WorkoutLog {
        let performed = allExercises.map {
            PerformedExercise(plannedExerciseID: $0.id, exerciseName: $0.exerciseName)
        }
        return WorkoutLog(plannedWorkoutID: id, exercises: performed)
    }
}
