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

    /// Copy a planned set for reuse without sharing any addressable identity with the source.
    func deepCopyWithFreshIDs() -> PlannedSet {
        var copy = self
        copy.id = UUID()
        for index in copy.alternatives.indices {
            copy.alternatives[index].id = UUID()
        }
        return copy
    }

    /// A copy whose every metric-keyed field — values, target ranges, progressions, and each
    /// alternative's values/ranges — is restricted to `allowed`. Applied when the backing movement is
    /// replaced so no target or logged number keyed to a metric the new movement doesn't support can
    /// survive under it.
    func retainingMetrics(_ allowed: Set<MetricType>) -> PlannedSet {
        var copy = self
        copy.values = values.retainingOnly(allowed)
        copy.ranges = ranges.filter { allowed.contains($0.metric) }
        copy.progressions = progressions.filter { allowed.contains($0.metric) }
        copy.alternatives = alternatives.map { alternative in
            var updated = alternative
            updated.values = alternative.values.retainingOnly(allowed)
            updated.ranges = alternative.ranges.filter { allowed.contains($0.metric) }
            return updated
        }
        return copy
    }
}

enum PlannedSetMoveDestination: Equatable, Sendable {
    case before(UUID)
    case index(Int)
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

    /// A copy with every set's metric-keyed data restricted to `allowed`. See `PlannedSet.retainingMetrics`.
    func retainingMetrics(_ allowed: Set<MetricType>) -> Prescription {
        var copy = self
        copy.sets = sets.map { $0.retainingMetrics(allowed) }
        return copy
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

extension CoachGuidance {
    /// Every note this guidance carries, in display order, as one block of text. Blank components are
    /// dropped; the rest is returned exactly as stored, so a field bound to this value round-trips
    /// whatever the athlete typed instead of normalizing it away between keystrokes.
    var notesText: String {
        var notes: [String] = []
        Self.append(goal, to: &notes)
        Self.append(tempo, to: &notes)
        notes.append(contentsOf: formCues.filter(Self.isMeaningful))
        notes.append(contentsOf: commonMistakes.filter(Self.isMeaningful))
        Self.append(progressionNotes, to: &notes)
        return notes.joined(separator: "\n\n")
    }

    /// The guidance one edited notes field represents. The raw text is stored; only the emptiness test
    /// trims, so trailing spaces and newlines survive.
    static func notes(from text: String) -> CoachGuidance? {
        isMeaningful(text) ? CoachGuidance(formCues: [text]) : nil
    }

    private static func append(_ note: String?, to notes: inout [String]) {
        guard let note, isMeaningful(note) else { return }
        notes.append(note)
    }

    private static func isMeaningful(_ note: String) -> Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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

    /// The single definition of what "replace this exercise" means, kept view- and store-free so every
    /// entry point agrees. It swaps catalog identity, re-derives the instance's metric schema to the new
    /// movement (keeping the metrics both movements share, falling back to the new movement's defaults
    /// when the overlap is empty), drops unit overrides the new movement can't use, and sanitizes every
    /// per-set value so a previous movement's numbers can never linger under a metric the new movement
    /// doesn't support. The instance keeps its identity and position — only the movement changes.
    func replacingMovement(with definition: ExerciseDefinition) -> PlannedExercise {
        var updated = self
        updated.exerciseName = definition.name
        updated.definitionId = definition.id == ExerciseCatalog.generic.id ? nil : definition.id
        let supported = Set(definition.supported)
        updated.selectedMetrics = selectedMetrics.filter { supported.contains($0) }
        if updated.selectedMetrics.isEmpty { updated.selectedMetrics = definition.defaults }
        updated.displayUnits = displayUnits.filter { supported.contains($0.key) }
        updated.prescription = prescription.retainingMetrics(supported)
        return updated
    }
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

    /// Insert a block at a validated zero-based position, or append when no position is supplied.
    /// Returns nil without changing the workout when the requested position is outside `0...count`.
    @discardableResult
    mutating func addBlock(
        name: String,
        intent: String?,
        guidance: CoachGuidance?,
        at index: Int?
    ) -> UUID? {
        let target = index ?? blocks.endIndex
        guard target >= blocks.startIndex, target <= blocks.endIndex else { return nil }
        let block = WorkoutBlock(name: name, intent: intent, guidance: guidance)
        blocks.insert(block, at: target)
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

    /// Insert a top-level exercise at a validated zero-based position in a block, or append when the
    /// position is omitted. Nested-parent insertion belongs to the general node-editing surface.
    @discardableResult
    mutating func addExercise(
        _ exercise: PlannedExercise,
        toBlock blockID: UUID,
        at index: Int?
    ) -> Bool {
        guard let blockIndex = blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        let target = index ?? blocks[blockIndex].nodes.endIndex
        guard target >= blocks[blockIndex].nodes.startIndex,
              target <= blocks[blockIndex].nodes.endIndex else { return false }
        blocks[blockIndex].nodes.insert(.exercise(exercise), at: target)
        return true
    }

    @discardableResult
    mutating func removeExercise(_ id: UUID) -> Bool {
        guard case .exercise? = findNode(id), let source = locateNode(id) else { return false }
        guard extractNode(id) != nil else { return false }
        if case .choice = source.container {
            updateChoice(source.container.id) { choice in
                choice.selectionCount = min(choice.selectionCount, max(choice.options.count, 1))
            }
        }
        return true
    }

    /// Move an exercise to another block (or reposition within one). An explicit position is the
    /// zero-based final index and is validated before extraction, so a rejected move is atomic.
    /// Deliberately looser than `moveNode`: the manual "Move to Block" action may empty a choice,
    /// and the selection count is clamped to keep the choice invariant intact.
    @discardableResult
    mutating func moveExercise(_ id: UUID, toBlock blockID: UUID, at index: Int? = nil) -> Bool {
        guard case .exercise? = findNode(id), let source = locateNode(id) else { return false }
        guard let destinationCount = blocks.first(where: { $0.id == blockID })?.nodes.count else {
            return false
        }
        if let index {
            let finalCount = destinationCount - (source.container == .block(blockID) ? 1 : 0)
            guard index >= 0, index <= finalCount else { return false }
        }
        guard let extracted = extractNode(id) else { return false }
        guard insertNode(extracted, into: blockID, at: index) else {
            // Unreachable after the validation above; restore so a bug can never orphan the node.
            _ = insertNode(extracted, into: source.container.id, at: nil)
            return false
        }
        if case .choice = source.container {
            updateChoice(source.container.id) { choice in
                choice.selectionCount = min(choice.selectionCount, max(choice.options.count, 1))
            }
        }
        return true
    }

    @discardableResult
    mutating func reorderExercise(_ id: UUID, to index: Int) -> Bool {
        mutateNodeLists { nodes, _ in
            guard let source = nodes.firstIndex(where: { node in
                if case .exercise(let exercise) = node { return exercise.id == id }
                return false
            }) else { return nil }
            guard index >= 0, index < nodes.count else { return false }
            let node = nodes.remove(at: source)
            nodes.insert(node, at: index)
            return true
        } ?? false
    }

    @discardableResult
    mutating func duplicateExercise(_ id: UUID) -> UUID? {
        mutateNodeLists { nodes, _ in
            guard let index = nodes.firstIndex(where: { node in
                if case .exercise(let exercise) = node { return exercise.id == id }
                return false
            }) else { return nil }
            var copy = nodes[index]
            copy.regenerateIDs()
            nodes.insert(copy, at: index + 1)
            return copy.id
        }
    }

    /// Replace the movement backing an exercise in place, keeping identity + position so history/undo
    /// stay stable. Delegates to `PlannedExercise.replacingMovement`, the one definition of replace that
    /// the live-log substitution and the plan/agent edits also build on.
    @discardableResult
    mutating func replaceExercise(_ id: UUID, with definition: ExerciseDefinition) -> Bool {
        updateExercise(id) { $0 = $0.replacingMovement(with: definition) }
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

    /// Move a set within its owning exercise after validating the complete destination.
    /// Set IDs cannot cross exercises through this helper.
    @discardableResult
    mutating func moveSet(_ setID: UUID, to destination: PlannedSetMoveDestination) -> Bool {
        guard let exerciseID = allExercises.first(where: { exercise in
            exercise.prescription.sets.contains { $0.id == setID }
        })?.id, let exercise = exercise(exerciseID) else { return false }

        let sets = exercise.prescription.sets
        guard let sourceIndex = sets.firstIndex(where: { $0.id == setID }) else { return false }
        switch destination {
        case .before(let beforeSetID):
            guard beforeSetID != setID, sets.contains(where: { $0.id == beforeSetID }) else {
                return false
            }
        case .index(let index):
            guard sets.indices.contains(index) else { return false }
        }

        return updateExercise(exerciseID) { updated in
            let moved = updated.prescription.sets.remove(at: sourceIndex)
            switch destination {
            case .before(let beforeSetID):
                guard let destinationIndex = updated.prescription.sets.firstIndex(where: {
                    $0.id == beforeSetID
                }) else { return }
                updated.prescription.sets.insert(moved, at: destinationIndex)
            case .index(let index):
                updated.prescription.sets.insert(
                    moved,
                    at: min(index, updated.prescription.sets.endIndex)
                )
            }
        }
    }

    /// Duplicate a planned set immediately after its source using fresh set and alternative IDs.
    @discardableResult
    mutating func duplicateSet(_ setID: UUID) -> UUID? {
        guard let exerciseID = allExercises.first(where: { exercise in
            exercise.prescription.sets.contains { $0.id == setID }
        })?.id, let exercise = exercise(exerciseID),
              let sourceIndex = exercise.prescription.sets.firstIndex(where: { $0.id == setID }) else {
            return nil
        }
        let copy = exercise.prescription.sets[sourceIndex].deepCopyWithFreshIDs()
        guard updateExercise(exerciseID, { updated in
            updated.prescription.sets.insert(copy, at: sourceIndex + 1)
        }) else { return nil }
        return copy.id
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

    // `updateExercise`, `updateGroup`, `updateChoice`, `updateRest`, and
    // `convertChoiceToRequiredGroup` live in WorkoutNode.swift, implemented on the one shared
    // recursive node API alongside the generic locate/extract/insert/move/remove operations.

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

    /// The session notes for this exercise as one block of editable text.
    var notesText: String { WorkoutLog.notesText(athleteNotes) }
}

/// One logged actual removed by a structural session edit, with enough context to re-insert exactly
/// this row into whatever the log has become by the time the edit is undone.
struct PurgedSetLog: Codable, Equatable, Sendable {
    var plannedExerciseID: UUID
    var exerciseName: String
    /// The row's position in its exercise's `setLogs` at purge time, so undo restores it in place.
    var index: Int
    var setLog: SetLog
}

/// One whole performed exercise removed by a structural edit, including status, notes, and rows.
/// The original position lets undo restore the record without replacing unrelated later log work.
struct PurgedPerformedExercise: Codable, Equatable, Sendable {
    var index: Int
    var exercise: PerformedExercise
}

/// One performed-only adjustment removed with its exercise, including its original list position.
struct PurgedExerciseAdjustment: Codable, Equatable, Sendable {
    var index: Int
    var adjustment: ExerciseLogAdjustment
}

struct PurgedGroupLog: Codable, Equatable, Sendable {
    var index: Int
    var group: GroupLog
}

struct PurgedChoiceLog: Codable, Equatable, Sendable {
    var index: Int
    var choice: ChoiceLog
}

struct PurgedChoiceSelection: Codable, Equatable, Sendable {
    var plannedChoiceID: UUID
    var before: [UUID]
    var after: [UUID]
}

/// Exact performed content removed alongside a workout-structure mutation.
/// Whole exercise records and adjustments are captured in addition to individual set rows so an
/// undo can restore every logged fact without replacing the current log snapshot.
struct WorkoutLogPurge: Codable, Equatable, Sendable {
    var performedExercises: [PurgedPerformedExercise] = []
    var setLogs: [PurgedSetLog] = []
    var adjustments: [PurgedExerciseAdjustment] = []
    var groups: [PurgedGroupLog] = []
    var choices: [PurgedChoiceLog] = []
    var choiceSelections: [PurgedChoiceSelection] = []

    var isEmpty: Bool {
        performedExercises.isEmpty && setLogs.isEmpty && adjustments.isEmpty
            && groups.isEmpty && choices.isEmpty && choiceSelections.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case performedExercises, setLogs, adjustments, groups, choices, choiceSelections
    }

    init(
        performedExercises: [PurgedPerformedExercise] = [],
        setLogs: [PurgedSetLog] = [],
        adjustments: [PurgedExerciseAdjustment] = [],
        groups: [PurgedGroupLog] = [],
        choices: [PurgedChoiceLog] = [],
        choiceSelections: [PurgedChoiceSelection] = []
    ) {
        self.performedExercises = performedExercises
        self.setLogs = setLogs
        self.adjustments = adjustments
        self.groups = groups
        self.choices = choices
        self.choiceSelections = choiceSelections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        performedExercises = try container.decodeIfPresent(
            [PurgedPerformedExercise].self,
            forKey: .performedExercises
        ) ?? []
        setLogs = try container.decodeIfPresent([PurgedSetLog].self, forKey: .setLogs) ?? []
        adjustments = try container.decodeIfPresent(
            [PurgedExerciseAdjustment].self,
            forKey: .adjustments
        ) ?? []
        groups = try container.decodeIfPresent([PurgedGroupLog].self, forKey: .groups) ?? []
        choices = try container.decodeIfPresent([PurgedChoiceLog].self, forKey: .choices) ?? []
        choiceSelections = try container.decodeIfPresent(
            [PurgedChoiceSelection].self,
            forKey: .choiceSelections
        ) ?? []
    }
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

    /// Replace one exercise's session notes with the athlete's edited text. Session notes are facts
    /// about the performance, so they live here and never on the planned `CoachGuidance` — that split
    /// is what keeps an in-session note from riding along when a session is promoted to the plan.
    /// Clearing the field never conjures a performed record for an exercise that has none.
    mutating func setNotes(_ text: String, forPlanned plannedID: UUID, name: String) {
        let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !isBlank || performed(forPlanned: plannedID) != nil else { return }
        exercises[index(forPlanned: plannedID, name: name)].athleteNotes = isBlank ? [] : [text]
    }

    /// Replace the workout-level session notes with the athlete's edited text.
    mutating func setNotes(_ text: String) {
        athleteNotes = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [text]
    }

    /// The workout-level session notes as one block of editable text.
    var notesText: String { Self.notesText(athleteNotes) }

    static func notesText(_ notes: [String]) -> String {
        notes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
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

    mutating func removeGroups(forPlanned plannedIDs: Set<UUID>) {
        groups.removeAll { plannedIDs.contains($0.plannedGroupID) }
    }

    mutating func removeChoices(forPlanned plannedIDs: Set<UUID>) {
        choices.removeAll { plannedIDs.contains($0.plannedChoiceID) }
    }

    mutating func removeChoiceSelections(optionIDs: Set<UUID>) {
        for index in choices.indices {
            choices[index].selectedOptionIDs.removeAll { optionIDs.contains($0) }
        }
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

    /// Strip metric values outside `retaining` from logged sets of a planned exercise, keeping the
    /// rows. Used when a live substitution swaps the movement to a different schema: sets logged before
    /// the swap still carry the old movement's numbers (a lift's reps/load), which would otherwise
    /// resurface in the completed/history summary. Sanitizing keeps the row and its outcome while
    /// dropping the values the new movement can't own.
    ///
    /// Scoped like `setExerciseAdjustment`: a round-scoped substitution (`iteration != nil`) touches
    /// only the sets of that round, so replacing one round of an EMOM/rounds group with a
    /// schema-changing movement never strips the values still owned by the other rounds' original
    /// movement. A group-wide replace (`groupID != nil, iteration == nil`) sanitizes every set of that
    /// group; a non-grouped exercise (both nil) sanitizes all of its sets.
    mutating func sanitizeSetLogs(
        forPlanned plannedID: UUID,
        retaining: Set<MetricType>,
        groupID: UUID? = nil,
        iteration: Int? = nil
    ) {
        guard let index = exercises.firstIndex(where: { $0.plannedExerciseID == plannedID }) else { return }
        for logIndex in exercises[index].setLogs.indices {
            let log = exercises[index].setLogs[logIndex]
            let inScope: Bool
            if iteration != nil {
                inScope = log.groupID == groupID && log.iteration == iteration
            } else if groupID != nil {
                inScope = log.groupID == groupID
            } else {
                inScope = true
            }
            guard inScope else { continue }
            exercises[index].setLogs[logIndex].values =
                exercises[index].setLogs[logIndex].values.retainingOnly(retaining)
        }
    }

    /// Whether the log holds anything the athlete recorded for a planned exercise — logged sets or a
    /// session note. This is the signal for confirming before a destructive true-remove would discard
    /// real logged work, and a note they typed is real logged work.
    func hasLoggedWork(forPlanned plannedID: UUID) -> Bool {
        guard let performed = performed(forPlanned: plannedID) else { return false }
        return performed.setLogs.contains { !$0.values.isEmpty || $0.completed }
            || !performed.notesText.isEmpty
    }

    /// Whether any logged *set* exists for a planned exercise, which is what a discard warning needs to
    /// say honestly what is about to be lost.
    func hasLoggedSets(forPlanned plannedID: UUID) -> Bool {
        performed(forPlanned: plannedID)?.setLogs.contains { !$0.values.isEmpty || $0.completed } ?? false
    }

    /// The set-log rows present in `before` but gone from `after` — the exact actuals a structural
    /// purge (e.g. remove_set) discarded. Captured row-by-row rather than as a whole-log snapshot so
    /// an undo can put these rows back without clobbering work logged after the purge.
    static func purgedSetLogs(before: WorkoutLog, after: WorkoutLog) -> [PurgedSetLog] {
        before.exercises.flatMap { exercise -> [PurgedSetLog] in
            guard let plannedID = exercise.plannedExerciseID else { return [] }
            let surviving = Set(
                after.exercises.first { $0.plannedExerciseID == plannedID }?.setLogs.map(\.id) ?? []
            )
            return exercise.setLogs.enumerated().compactMap { index, row in
                surviving.contains(row.id) ? nil : PurgedSetLog(
                    plannedExerciseID: plannedID,
                    exerciseName: exercise.exerciseName,
                    index: index,
                    setLog: row
                )
            }
        }
    }

    /// The complete performed content present before a structural edit but absent afterwards.
    /// A removed exercise is captured whole, while set-only edits keep the narrower row snapshot.
    static func purgedContent(before: WorkoutLog, after: WorkoutLog) -> WorkoutLogPurge {
        let survivingExerciseIDs = Set(after.exercises.map(\.id))
        let removedExercises = before.exercises.enumerated().compactMap { index, exercise in
            survivingExerciseIDs.contains(exercise.id)
                ? nil
                : PurgedPerformedExercise(index: index, exercise: exercise)
        }
        let removedPlannedIDs = Set(removedExercises.compactMap(\.exercise.plannedExerciseID))
        let rows = purgedSetLogs(before: before, after: after).filter {
            removedPlannedIDs.contains($0.plannedExerciseID) == false
        }
        let survivingAdjustmentIDs = Set(after.exerciseAdjustments.map(\.id))
        let adjustments = before.exerciseAdjustments.enumerated().compactMap { index, adjustment in
            survivingAdjustmentIDs.contains(adjustment.id)
                ? nil
                : PurgedExerciseAdjustment(index: index, adjustment: adjustment)
        }
        let survivingGroupIDs = Set(after.groups.map(\.id))
        let groups = before.groups.enumerated().compactMap { index, group in
            survivingGroupIDs.contains(group.id) ? nil : PurgedGroupLog(index: index, group: group)
        }
        let survivingChoiceIDs = Set(after.choices.map(\.id))
        let choices = before.choices.enumerated().compactMap { index, choice in
            survivingChoiceIDs.contains(choice.id) ? nil : PurgedChoiceLog(index: index, choice: choice)
        }
        let removedChoiceIDs = Set(choices.map(\.choice.id))
        let choiceSelections = before.choices.compactMap { choice -> PurgedChoiceSelection? in
            guard removedChoiceIDs.contains(choice.id) == false,
                  let surviving = after.choices.first(where: { $0.id == choice.id }) else { return nil }
            guard choice.selectedOptionIDs != surviving.selectedOptionIDs else { return nil }
            return PurgedChoiceSelection(
                plannedChoiceID: choice.plannedChoiceID,
                before: choice.selectedOptionIDs,
                after: surviving.selectedOptionIDs
            )
        }
        return WorkoutLogPurge(
            performedExercises: removedExercises,
            setLogs: rows,
            adjustments: adjustments,
            groups: groups,
            choices: choices,
            choiceSelections: choiceSelections
        )
    }

    /// Re-insert purged rows into the log **as it stands now**, near their original positions.
    /// Everything logged since the purge is preserved; a row is skipped rather than duplicated if the
    /// same actual (by id) or a newer actual for the same planned set has appeared meanwhile.
    mutating func restore(_ purged: [PurgedSetLog]) {
        for row in purged {
            let i = index(forPlanned: row.plannedExerciseID, name: row.exerciseName)
            guard !exercises[i].setLogs.contains(where: { existing in
                existing.id == row.setLog.id || (
                    row.setLog.plannedSetID != nil
                        && existing.plannedSetID == row.setLog.plannedSetID
                        && existing.groupID == row.setLog.groupID
                        && existing.iteration == row.setLog.iteration
                )
            }) else { continue }
            exercises[i].setLogs.insert(row.setLog, at: min(row.index, exercises[i].setLogs.count))
        }
    }

    /// Restore only content removed by a structural edit into the log as it exists at undo time.
    /// Later rows, notes, statuses, and adjustments remain authoritative and are never replaced.
    mutating func restore(_ purge: WorkoutLogPurge) {
        for removed in purge.performedExercises {
            guard let plannedID = removed.exercise.plannedExerciseID else { continue }
            if let existingIndex = exercises.firstIndex(where: { $0.plannedExerciseID == plannedID }) {
                let original = removed.exercise
                if exercises[existingIndex].status == .pending {
                    exercises[existingIndex].status = original.status
                }
                if exercises[existingIndex].substitutionFor == nil {
                    exercises[existingIndex].substitutionFor = original.substitutionFor
                }
                if exercises[existingIndex].reason == nil {
                    exercises[existingIndex].reason = original.reason
                }
                for note in original.athleteNotes where !exercises[existingIndex].athleteNotes.contains(note) {
                    exercises[existingIndex].athleteNotes.append(note)
                }
                let rows = original.setLogs.enumerated().map { index, row in
                    PurgedSetLog(
                        plannedExerciseID: plannedID,
                        exerciseName: original.exerciseName,
                        index: index,
                        setLog: row
                    )
                }
                restore(rows)
            } else {
                exercises.insert(removed.exercise, at: min(removed.index, exercises.endIndex))
            }
        }
        restore(purge.setLogs)
        for removed in purge.adjustments where !exerciseAdjustments.contains(where: {
            $0.id == removed.adjustment.id
        }) {
            exerciseAdjustments.insert(
                removed.adjustment,
                at: min(removed.index, exerciseAdjustments.endIndex)
            )
        }
        for removed in purge.groups where !groups.contains(where: {
            $0.id == removed.group.id || $0.plannedGroupID == removed.group.plannedGroupID
        }) {
            groups.insert(removed.group, at: min(removed.index, groups.endIndex))
        }
        for removed in purge.choices where !choices.contains(where: {
            $0.id == removed.choice.id || $0.plannedChoiceID == removed.choice.plannedChoiceID
        }) {
            choices.insert(removed.choice, at: min(removed.index, choices.endIndex))
        }
        for removed in purge.choiceSelections {
            guard let choiceIndex = choices.firstIndex(where: {
                $0.plannedChoiceID == removed.plannedChoiceID
            }), choices[choiceIndex].selectedOptionIDs == removed.after else {
                continue
            }
            choices[choiceIndex].selectedOptionIDs = removed.before
        }
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
    func choiceOptionIDs(containingExercise exerciseID: UUID) -> [UUID] {
        blocks.flatMap { $0.nodes.choiceOptionIDs(containingExercise: exerciseID) }
    }

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
