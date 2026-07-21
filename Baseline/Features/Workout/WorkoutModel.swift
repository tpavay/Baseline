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
    var role: SetRole = .working
    var effortTarget: EffortTarget?
    var ranges: [MetricTargetRange] = []
    var progressions: [MetricProgression] = []
    var alternatives: [PlannedSetAlternative] = []

    init(id: UUID = UUID(), reps: Int? = nil, load: Double? = nil, duration: Int? = nil,
         distance: Double? = nil, calories: Double? = nil, rpe: Double? = nil,
         role: SetRole = .working, effortTarget: EffortTarget? = nil,
         ranges: [MetricTargetRange] = [], progressions: [MetricProgression] = [],
         alternatives: [PlannedSetAlternative] = []) {
        self.id = id
        self.role = role
        self.effortTarget = effortTarget
        self.ranges = ranges
        self.progressions = progressions
        self.alternatives = alternatives
        values.setInt(.reps, reps); values[.load] = load; values.setInt(.duration, duration)
        values[.distance] = distance; values[.calories] = calories; values[.rpe] = rpe
    }
    init(id: UUID = UUID(), values: MetricValues, role: SetRole = .working,
         effortTarget: EffortTarget? = nil, ranges: [MetricTargetRange] = [],
         progressions: [MetricProgression] = [], alternatives: [PlannedSetAlternative] = []) {
        self.id = id
        self.values = values
        self.role = role
        self.effortTarget = effortTarget
        self.ranges = ranges
        self.progressions = progressions
        self.alternatives = alternatives
    }

    private enum CodingKeys: String, CodingKey {
        case id, values, role, effortTarget, ranges, progressions, alternatives
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        values = try container.decode(MetricValues.self, forKey: .values)
        role = try container.decodeIfPresent(SetRole.self, forKey: .role) ?? .working
        effortTarget = try container.decodeIfPresent(EffortTarget.self, forKey: .effortTarget)
        ranges = try container.decodeIfPresent([MetricTargetRange].self, forKey: .ranges) ?? []
        progressions = try container.decodeIfPresent([MetricProgression].self, forKey: .progressions) ?? []
        alternatives = try container.decodeIfPresent([PlannedSetAlternative].self, forKey: .alternatives) ?? []
    }

    func expectedValues(iteration: Int) -> MetricValues {
        var result = values
        for progression in progressions {
            if let base = values[progression.metric] {
                result[progression.metric] = progression.value(base: base, iteration: iteration)
            }
        }
        return result
    }

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
    var intensityTargets: [IntensityTarget] = []

    init(sets: [PlannedSet] = [], restSeconds: Int? = nil, intent: TrainingIntent? = nil,
         targetZone: Int? = nil, tempo: String? = nil, intensityTargets: [IntensityTarget] = []) {
        self.sets = sets
        self.restSeconds = restSeconds
        self.intent = intent
        self.targetZone = targetZone
        self.tempo = tempo
        self.intensityTargets = intensityTargets
    }

    private enum CodingKeys: String, CodingKey {
        case sets, restSeconds, intent, targetZone, tempo, intensityTargets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sets = try container.decodeIfPresent([PlannedSet].self, forKey: .sets) ?? []
        restSeconds = try container.decodeIfPresent(Int.self, forKey: .restSeconds)
        intent = try container.decodeIfPresent(TrainingIntent.self, forKey: .intent)
        targetZone = try container.decodeIfPresent(Int.self, forKey: .targetZone)
        tempo = try container.decodeIfPresent(String.self, forKey: .tempo)
        intensityTargets = try container.decodeIfPresent([IntensityTarget].self, forKey: .intensityTargets) ?? []
    }
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
    /// Optional workout-local wording such as "Station B". The canonical catalog identity remains
    /// `exerciseName`/`definitionId`, so labels never corrupt history or exercise matching.
    var displayLabel: String?
    var definitionId: String?                       // stable catalog identity (nil = uncurated)
    var selectedMetrics: [MetricType] = []          // which metrics this instance logs/shows
    var displayUnits: [MetricType: MetricUnit] = [:] // this-instance unit overrides
    var prescription = Prescription()
    var guidance: CoachGuidance?

    /// The catalog definition backing this exercise (generic when uncurated).
    var definition: ExerciseDefinition { definitionId.flatMap(ExerciseCatalog.definition(id:)) ?? ExerciseCatalog.generic }
    var supportedMetrics: [MetricType] { definition.supported }
}

struct Workout: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var goal: String?
    var guidance: CoachGuidance?
    var scheduledDate: Date?          // the day this workout is for; nil = legacy/unstamped
    var blocks: [WorkoutBlock] = []
}

// MARK: - Editing operations (validated; every level is editable)

extension Workout {

    // Workout level
    mutating func updateGoal(_ goal: String?) { self.goal = goal }
    mutating func updateGuidance(_ guidance: CoachGuidance?) { self.guidance = guidance }
    mutating func rename(_ title: String) { self.title = title }

    // Block level
    @discardableResult
    mutating func addBlock(name: String, intent: String? = nil) -> UUID {
        let block = WorkoutBlock(name: name, intent: intent)
        blocks.append(block)
        return block.id
    }

    /// Add a *user-created* block, discarding the implicit empty default if present — creating your
    /// own structure shouldn't leave a phantom "Main" section beside it. Leaves ≥1 block.
    @discardableResult
    mutating func addUserBlock(name: String, intent: String? = nil) -> UUID {
        if let i = blocks.firstIndex(where: {
            $0.isDefault && $0.exercises.isEmpty
                && $0.name.trimmingCharacters(in: .whitespaces).isEmpty
                && ($0.intent?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }) {
            blocks.remove(at: i)
        }
        return addBlock(name: name, intent: intent)
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

    /// Reorder whole blocks via SwiftUI drag (`.onMove`). Order is array position, so this is a pure
    /// slice move — the offsets/target come straight from the reorder List.
    mutating func moveBlocks(fromOffsets source: IndexSet, toOffset destination: Int) {
        blocks.move(fromOffsets: source, toOffset: destination)
    }

    /// Reorder the top-level nodes *within one block* via drag (`.onMove`). Scoped to a single block so
    /// a drag can never carry an exercise across a block boundary (a deliberate product constraint —
    /// cross-block exercise moves are only reachable through the explicit "Move to Block" action).
    mutating func moveNodes(inBlock blockID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let i = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        blocks[i].nodes.move(fromOffsets: source, toOffset: destination)
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
    mutating func setBlockGuidance(_ id: UUID, _ guidance: CoachGuidance?) -> Bool {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return false }
        blocks[i].guidance = guidance
        return true
    }

    @discardableResult
    mutating func duplicateBlock(_ id: UUID) -> UUID? {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = blocks[i]
        copy.id = UUID()
        copy.name += " (copy)"
        for index in copy.nodes.indices { copy.nodes[index].regenerateIDs() }
        blocks.insert(copy, at: i + 1)
        return copy.id
    }

    // Exercise level
    @discardableResult
    mutating func addExercise(_ exercise: PlannedExercise, toBlock blockID: UUID) -> Bool {
        guard let i = blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        blocks[i].nodes.append(.exercise(exercise))
        return true
    }

    @discardableResult
    mutating func removeExercise(_ id: UUID) -> Bool {
        for index in blocks.indices {
            if blocks[index].nodes.removeExercise(id) { return true }
        }
        return false
    }

    /// Move an exercise to another block (or reposition within one) — the cross-block move the docs
    /// call out. `index` clamps into the destination.
    @discardableResult
    mutating func moveExercise(_ id: UUID, toBlock blockID: UUID, at index: Int? = nil) -> Bool {
        guard let dest = blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        var extracted: PlannedExercise?
        for source in blocks.indices where extracted == nil {
            extracted = blocks[source].nodes.extractExercise(id)
        }
        guard let exercise = extracted else { return false }
        let target = min(max(index ?? blocks[dest].nodes.count, 0), blocks[dest].nodes.count)
        blocks[dest].nodes.insert(.exercise(exercise), at: target)
        return true
    }

    @discardableResult
    mutating func reorderExercise(_ id: UUID, to index: Int) -> Bool {
        for block in blocks.indices {
            if blocks[block].nodes.reorderExercise(id, to: index) { return true }
        }
        return false
    }

    @discardableResult
    mutating func duplicateExercise(_ id: UUID) -> UUID? {
        for block in blocks.indices {
            if let copyID = blocks[block].nodes.duplicateExercise(id) { return copyID }
        }
        return nil
    }

    /// Swap the movement while keeping the exercise's identity + position (so history/undo stay
    /// stable). Prescription is replaced; guidance is dropped unless carried by the caller.
    @discardableResult
    mutating func substituteExercise(_ id: UUID, withName name: String, prescription: Prescription) -> Bool {
        updateExercise(id) {
            $0.exerciseName = name
            $0.prescription = prescription
        }
    }

    @discardableResult
    mutating func updateGuidance(_ exerciseID: UUID, _ guidance: CoachGuidance?) -> Bool {
        updateExercise(exerciseID) { $0.guidance = guidance }
    }

    // Set level — one set changes without rewriting the exercise
    @discardableResult
    mutating func addSet(_ set: PlannedSet, toExercise exerciseID: UUID) -> Bool {
        updateExercise(exerciseID) { $0.prescription.sets.append(set) }
    }

    @discardableResult
    mutating func removeSet(_ setID: UUID) -> Bool {
        guard let exerciseID = allExercises.first(where: { exercise in
            exercise.prescription.sets.contains { $0.id == setID }
        })?.id else { return false }
        return updateExercise(exerciseID) { $0.prescription.sets.removeAll { $0.id == setID } }
    }

    @discardableResult
    mutating func updateSet(_ setID: UUID, _ transform: (inout PlannedSet) -> Void) -> Bool {
        guard let exerciseID = allExercises.first(where: { exercise in
            exercise.prescription.sets.contains { $0.id == setID }
        })?.id else { return false }
        return updateExercise(exerciseID) { exercise in
            guard let index = exercise.prescription.sets.firstIndex(where: { $0.id == setID }) else { return }
            transform(&exercise.prescription.sets[index])
        }
    }

    @discardableResult
    mutating func updateExercise(_ id: UUID, _ transform: (inout PlannedExercise) -> Void) -> Bool {
        for index in blocks.indices {
            if blocks[index].nodes.updateExercise(id, transform) { return true }
        }
        return false
    }

    @discardableResult
    mutating func updateGroup(_ id: UUID, _ transform: (inout WorkoutGroup) -> Void) -> Bool {
        for index in blocks.indices {
            if blocks[index].nodes.updateGroup(id, transform) { return true }
        }
        return false
    }

    /// Converts a parser/user choice into one required sequence without changing child identities.
    /// This is the lossless correction for text such as "B. Deadlifts + lateral burpees."
    @discardableResult
    mutating func convertChoiceToRequiredGroup(_ id: UUID) -> Bool {
        for index in blocks.indices {
            if blocks[index].nodes.convertChoiceToRequiredGroup(id) { return true }
        }
        return false
    }

    @discardableResult
    mutating func addNode(_ node: WorkoutNode, toBlock blockID: UUID) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        blocks[index].nodes.append(node)
        return true
    }

    func exercise(_ id: UUID) -> PlannedExercise? { allExercises.first { $0.id == id } }

    // MARK: - Lookup helpers

    /// All planned exercises across blocks, in order.
    var allExercises: [PlannedExercise] { blocks.flatMap(\.exercises) }
    var allGroups: [WorkoutGroup] { blocks.flatMap(\.groups) }
    var allChoices: [WorkoutChoice] { blocks.flatMap(\.choices) }
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
    var groupID: UUID?
    var iteration: Int?
    var values = MetricValues()
    var outcome: SetLogOutcome = .pending

    /// Compatibility sugar for the existing checkmark flow. A skipped set is handled but is never
    /// reported as completed.
    var completed: Bool {
        get { outcome == .completed }
        set { outcome = newValue ? .completed : .pending }
    }

    var isHandled: Bool { outcome == .completed || outcome == .skipped }

    init(plannedSetID: UUID? = nil, groupID: UUID? = nil, iteration: Int? = nil,
         reps: Int? = nil, load: Double? = nil, duration: Int? = nil,
         distance: Double? = nil, calories: Double? = nil, rpe: Double? = nil,
         outcome: SetLogOutcome = .pending) {
        self.plannedSetID = plannedSetID
        self.groupID = groupID
        self.iteration = iteration
        self.outcome = outcome
        values.setInt(.reps, reps); values[.load] = load; values.setInt(.duration, duration)
        values[.distance] = distance; values[.calories] = calories; values[.rpe] = rpe
    }
    init(plannedSetID: UUID? = nil, groupID: UUID? = nil, iteration: Int? = nil,
         values: MetricValues, outcome: SetLogOutcome = .pending) {
        self.plannedSetID = plannedSetID
        self.groupID = groupID
        self.iteration = iteration
        self.values = values
        self.outcome = outcome
    }

    // Codable-tolerant of the earlier Boolean completion field and the shape before it existed.
    private enum CodingKeys: String, CodingKey {
        case id, plannedSetID, groupID, iteration, values, outcome, completed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        plannedSetID = try c.decodeIfPresent(UUID.self, forKey: .plannedSetID)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        iteration = try c.decodeIfPresent(Int.self, forKey: .iteration)
        values = try c.decode(MetricValues.self, forKey: .values)
        if let decoded = try c.decodeIfPresent(SetLogOutcome.self, forKey: .outcome) {
            outcome = decoded
        } else {
            outcome = try c.decodeIfPresent(Bool.self, forKey: .completed) == true ? .completed : .pending
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(plannedSetID, forKey: .plannedSetID)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encodeIfPresent(iteration, forKey: .iteration)
        try c.encode(values, forKey: .values)
        try c.encode(outcome, forKey: .outcome)
    }

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

struct GroupLog: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var plannedGroupID: UUID
    var targetDurationSeconds: Int?
    var performedDurationSeconds: Int?
    var completedIterations = 0
    var partialReps: Int?
    var isComplete = false
}

struct ChoiceLog: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var plannedChoiceID: UUID
    var selectedOptionIDs: [UUID]
}

/// The performed record for a workout. It references the planned workout but is a distinct object —
/// the plan is never mutated by logging.
struct WorkoutLog: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var plannedWorkoutID: UUID?
    var exercises: [PerformedExercise] = []
    var groups: [GroupLog] = []
    var choices: [ChoiceLog] = []
    var exerciseAdjustments: [ExerciseLogAdjustment] = []
    var athleteNotes: [String] = []
    var isComplete = false

    init(id: UUID = UUID(), plannedWorkoutID: UUID? = nil, exercises: [PerformedExercise] = [],
         groups: [GroupLog] = [], choices: [ChoiceLog] = [],
         exerciseAdjustments: [ExerciseLogAdjustment] = [], athleteNotes: [String] = [],
         isComplete: Bool = false) {
        self.id = id
        self.plannedWorkoutID = plannedWorkoutID
        self.exercises = exercises
        self.groups = groups
        self.choices = choices
        self.exerciseAdjustments = exerciseAdjustments
        self.athleteNotes = athleteNotes
        self.isComplete = isComplete
    }

    private enum CodingKeys: String, CodingKey {
        case id, plannedWorkoutID, exercises, groups, choices, exerciseAdjustments, athleteNotes, isComplete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        plannedWorkoutID = try container.decodeIfPresent(UUID.self, forKey: .plannedWorkoutID)
        exercises = try container.decodeIfPresent([PerformedExercise].self, forKey: .exercises) ?? []
        groups = try container.decodeIfPresent([GroupLog].self, forKey: .groups) ?? []
        choices = try container.decodeIfPresent([ChoiceLog].self, forKey: .choices) ?? []
        exerciseAdjustments = try container.decodeIfPresent(
            [ExerciseLogAdjustment].self,
            forKey: .exerciseAdjustments
        ) ?? []
        athleteNotes = try container.decodeIfPresent([String].self, forKey: .athleteNotes) ?? []
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
    }
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

    /// Find-or-create the actual for one planned set and edit it in place — the training table edits
    /// cells directly (Hevy-style) rather than appending free-floating logs.
    mutating func upsertSetLog(forPlanned plannedID: UUID, name: String, plannedSetID: UUID,
                               groupID: UUID? = nil, iteration: Int? = nil,
                               _ transform: (inout SetLog) -> Void) {
        let i = index(forPlanned: plannedID, name: name)
        if let s = exercises[i].setLogs.firstIndex(where: {
            $0.plannedSetID == plannedSetID && $0.groupID == groupID && $0.iteration == iteration
        }) {
            transform(&exercises[i].setLogs[s])
        } else {
            var new = SetLog(plannedSetID: plannedSetID, groupID: groupID, iteration: iteration)
            transform(&new)
            exercises[i].setLogs.append(new)
        }
    }

    func setLog(forPlanned plannedID: UUID, plannedSetID: UUID,
                groupID: UUID? = nil, iteration: Int? = nil) -> SetLog? {
        performed(forPlanned: plannedID)?.setLogs.first {
            $0.plannedSetID == plannedSetID && $0.groupID == groupID && $0.iteration == iteration
        }
    }

    mutating func updateGroupLog(_ groupID: UUID, _ transform: (inout GroupLog) -> Void) {
        guard let index = groups.firstIndex(where: { $0.plannedGroupID == groupID }) else { return }
        transform(&groups[index])
    }

    mutating func upsertGroupLog(_ groupID: UUID, targetDurationSeconds: Int? = nil,
                                 _ transform: (inout GroupLog) -> Void) {
        if let index = groups.firstIndex(where: { $0.plannedGroupID == groupID }) {
            transform(&groups[index])
        } else {
            var group = GroupLog(plannedGroupID: groupID, targetDurationSeconds: targetDurationSeconds)
            transform(&group)
            groups.append(group)
        }
    }

    func selectedOptions(for choiceID: UUID) -> Set<UUID> {
        Set(choices.first { $0.plannedChoiceID == choiceID }?.selectedOptionIDs ?? [])
    }

    mutating func selectOption(_ optionID: UUID, for choiceID: UUID, selectionCount: Int) {
        guard let index = choices.firstIndex(where: { $0.plannedChoiceID == choiceID }) else {
            choices.append(ChoiceLog(plannedChoiceID: choiceID, selectedOptionIDs: [optionID]))
            return
        }
        if selectionCount <= 1 {
            choices[index].selectedOptionIDs = [optionID]
        } else if choices[index].selectedOptionIDs.contains(optionID) {
            choices[index].selectedOptionIDs.removeAll { $0 == optionID }
        } else if choices[index].selectedOptionIDs.count < selectionCount {
            choices[index].selectedOptionIDs.append(optionID)
        }
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

    /// True-remove the performed record for a planned exercise, including any logged sets and
    /// adjustments. Used when an exercise is structurally deleted from the session mid-workout so the
    /// log never keeps orphaned sets that the UI can't show but completion would otherwise resurface.
    mutating func removePerformed(forPlanned plannedID: UUID) {
        exercises.removeAll { $0.plannedExerciseID == plannedID }
        exerciseAdjustments.removeAll { $0.plannedExerciseID == plannedID }
    }

    /// True-remove the logged sets that belong to planned sets which no longer exist. Deleting a planned
    /// set is a structural edit like deleting an exercise: the log table can no longer render the row, so
    /// leaving the actual behind would let completion commit work the athlete deleted.
    mutating func removeSetLogs(forPlanned plannedID: UUID, plannedSetIDs: Set<UUID>) {
        guard let index = exercises.firstIndex(where: { $0.plannedExerciseID == plannedID }) else { return }
        exercises[index].setLogs.removeAll { log in
            guard let plannedSetID = log.plannedSetID else { return false }
            return plannedSetIDs.contains(plannedSetID)
        }
    }

    /// Whether the log holds any actually-logged set for a planned exercise — the signal for confirming
    /// before a destructive true-remove would discard real logged work.
    func hasLoggedWork(forPlanned plannedID: UUID) -> Bool {
        performed(forPlanned: plannedID)?.setLogs.contains { !$0.values.isEmpty || $0.completed } ?? false
    }

    func exerciseAdjustment(
        for plannedExerciseID: UUID,
        groupID: UUID? = nil,
        iteration: Int? = nil
    ) -> ExerciseLogAdjustment? {
        if let groupID, let iteration,
           let exact = exerciseAdjustments.last(where: {
               $0.plannedExerciseID == plannedExerciseID
                   && $0.groupID == groupID
                   && $0.iteration == iteration
           }) {
            return exact
        }
        if let groupID,
           let groupWide = exerciseAdjustments.last(where: {
               $0.plannedExerciseID == plannedExerciseID
                   && $0.groupID == groupID
                   && $0.iteration == nil
           }) {
            return groupWide
        }
        return exerciseAdjustments.last {
            $0.plannedExerciseID == plannedExerciseID
                && $0.groupID == nil
                && $0.iteration == nil
        }
    }

    func effectiveExercise(
        for planned: PlannedExercise,
        groupID: UUID? = nil,
        iteration: Int? = nil
    ) -> PlannedExercise {
        guard let adjustment = exerciseAdjustment(
            for: planned.id,
            groupID: groupID,
            iteration: iteration
        ), adjustment.outcome == .substituted, let substitution = adjustment.substitution else {
            return planned
        }
        return substitution.applying(to: planned)
    }

    func isExerciseSkipped(
        _ plannedExerciseID: UUID,
        groupID: UUID? = nil,
        iteration: Int? = nil
    ) -> Bool {
        exerciseAdjustment(
            for: plannedExerciseID,
            groupID: groupID,
            iteration: iteration
        )?.outcome == .skipped
    }

    mutating func setExerciseAdjustment(
        plannedExerciseID: UUID,
        groupID: UUID? = nil,
        iteration: Int? = nil,
        outcome: ExerciseLogAdjustment.Outcome,
        substitution: LoggedExerciseSubstitution? = nil,
        name: String
    ) {
        if iteration == nil {
            exerciseAdjustments.removeAll {
                $0.plannedExerciseID == plannedExerciseID && $0.groupID == groupID
            }
        } else {
            exerciseAdjustments.removeAll {
                $0.plannedExerciseID == plannedExerciseID
                    && $0.groupID == groupID
                    && $0.iteration == iteration
            }
        }
        exerciseAdjustments.append(
            ExerciseLogAdjustment(
                plannedExerciseID: plannedExerciseID,
                groupID: groupID,
                iteration: iteration,
                outcome: outcome,
                substitution: substitution
            )
        )

        let status: PerformedStatus = switch outcome {
        case .original: .pending
        case .skipped: iteration == nil ? .skipped : .modified
        case .substituted: iteration == nil ? .substituted : .modified
        }
        setStatus(status, forPlanned: plannedExerciseID, name: name)
    }

    mutating func restoreExercise(
        plannedExerciseID: UUID,
        groupID: UUID? = nil,
        iteration: Int? = nil,
        name: String
    ) {
        if let iteration {
            exerciseAdjustments.removeAll {
                $0.plannedExerciseID == plannedExerciseID
                    && $0.groupID == groupID
                    && $0.iteration == iteration
            }
            if exerciseAdjustments.contains(where: {
                $0.plannedExerciseID == plannedExerciseID
                    && $0.groupID == groupID
                    && $0.iteration == nil
            }) {
                exerciseAdjustments.append(
                    ExerciseLogAdjustment(
                        plannedExerciseID: plannedExerciseID,
                        groupID: groupID,
                        iteration: iteration,
                        outcome: .original
                    )
                )
            }
        } else {
            exerciseAdjustments.removeAll {
                $0.plannedExerciseID == plannedExerciseID && $0.groupID == groupID
            }
        }

        let stillAdjusted = exerciseAdjustments.contains {
            $0.plannedExerciseID == plannedExerciseID && $0.outcome != .original
        }
        setStatus(stillAdjusted ? .modified : .pending, forPlanned: plannedExerciseID, name: name)
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
        let groupLogs = allGroups.map {
            GroupLog(plannedGroupID: $0.id, targetDurationSeconds: $0.execution.repetition.durationSeconds)
        }
        let choiceLogs = allChoices.map {
            ChoiceLog(plannedChoiceID: $0.id, selectedOptionIDs: Array($0.options.prefix($0.selectionCount).map(\.id)))
        }
        return WorkoutLog(plannedWorkoutID: id, exercises: performed, groups: groupLogs, choices: choiceLogs)
    }
}
