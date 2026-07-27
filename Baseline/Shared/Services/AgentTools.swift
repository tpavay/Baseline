import Foundation

/// A field supplied by a tool call can be absent, carry a value, or explicitly carry JSON `null`.
/// Keeping those states distinct prevents a clear request from collapsing into "leave unchanged."
enum MetadataPatch<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case set(Value)
    case clear

    var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}

struct PlannedSetValues: Equatable, Sendable {
    var metrics: [MetricType: Double]

    init(metrics: [MetricType: Double] = [:]) {
        self.metrics = metrics
    }
}

struct PlannedSetValuesPatch: Equatable, Sendable {
    var metrics: [MetricType: MetadataPatch<Double>]

    init(metrics: [MetricType: MetadataPatch<Double>] = [:]) {
        self.metrics = metrics
    }

    var isUnchanged: Bool { metrics.isEmpty }
}

struct PlannedSetTargets: Equatable, Sendable {
    var effort: EffortTarget?
    var ranges: [MetricTargetRange]

    init(effort: EffortTarget? = nil, ranges: [MetricTargetRange] = []) {
        self.effort = effort
        self.ranges = ranges
    }
}

struct PlannedSetTargetsPatch: Equatable, Sendable {
    var effort: MetadataPatch<EffortTarget>
    var ranges: MetadataPatch<[MetricTargetRange]>

    init(
        effort: MetadataPatch<EffortTarget> = .unchanged,
        ranges: MetadataPatch<[MetricTargetRange]> = .unchanged
    ) {
        self.effort = effort
        self.ranges = ranges
    }

    var isUnchanged: Bool { effort.isUnchanged && ranges.isUnchanged }
}

struct PlannedSetPatch: Equatable, Sendable {
    var values: MetadataPatch<PlannedSetValuesPatch>
    var role: MetadataPatch<SetRole>
    var targets: MetadataPatch<PlannedSetTargetsPatch>
    var progressions: MetadataPatch<[MetricProgression]>

    init(
        values: MetadataPatch<PlannedSetValuesPatch> = .unchanged,
        role: MetadataPatch<SetRole> = .unchanged,
        targets: MetadataPatch<PlannedSetTargetsPatch> = .unchanged,
        progressions: MetadataPatch<[MetricProgression]> = .unchanged
    ) {
        self.values = values
        self.role = role
        self.targets = targets
        self.progressions = progressions
    }

    var isUnchanged: Bool {
        values.isUnchanged && role.isUnchanged && targets.isUnchanged && progressions.isUnchanged
    }
}

/// Wave 8 group patch. Label and repetition are required group state (set-only); everything else
/// follows the three-state convention: omitted = leave, set = change, null = clear.
struct WorkoutGroupPatch: Equatable, Sendable {
    var label: MetadataPatch<String>
    var guidance: MetadataPatch<String>
    var phase: MetadataPatch<WorkoutPhase>
    var doseLayer: MetadataPatch<DoseLayer>
    var isOptional: MetadataPatch<Bool>
    var repetition: MetadataPatch<RepetitionRule>
    var cadence: MetadataPatch<StartCadence>
    var totalTargets: MetadataPatch<PlannedSetValuesPatch>
    var adjustments: MetadataPatch<[MetricAdjustment]>

    init(
        label: MetadataPatch<String> = .unchanged,
        guidance: MetadataPatch<String> = .unchanged,
        phase: MetadataPatch<WorkoutPhase> = .unchanged,
        doseLayer: MetadataPatch<DoseLayer> = .unchanged,
        isOptional: MetadataPatch<Bool> = .unchanged,
        repetition: MetadataPatch<RepetitionRule> = .unchanged,
        cadence: MetadataPatch<StartCadence> = .unchanged,
        totalTargets: MetadataPatch<PlannedSetValuesPatch> = .unchanged,
        adjustments: MetadataPatch<[MetricAdjustment]> = .unchanged
    ) {
        self.label = label
        self.guidance = guidance
        self.phase = phase
        self.doseLayer = doseLayer
        self.isOptional = isOptional
        self.repetition = repetition
        self.cadence = cadence
        self.totalTargets = totalTargets
        self.adjustments = adjustments
    }

    var isUnchanged: Bool {
        label.isUnchanged && guidance.isUnchanged && phase.isUnchanged && doseLayer.isUnchanged
            && isOptional.isUnchanged && repetition.isUnchanged && cadence.isUnchanged
            && totalTargets.isUnchanged && adjustments.isUnchanged
    }
}

/// Wave 8 rest patch. Label and placement are required rest state (set-only); duration and guidance
/// are clearable.
struct PlannedRestPatch: Equatable, Sendable {
    var label: MetadataPatch<String>
    var placement: MetadataPatch<RestPlacement>
    var durationSeconds: MetadataPatch<Int>
    var guidance: MetadataPatch<String>

    init(
        label: MetadataPatch<String> = .unchanged,
        placement: MetadataPatch<RestPlacement> = .unchanged,
        durationSeconds: MetadataPatch<Int> = .unchanged,
        guidance: MetadataPatch<String> = .unchanged
    ) {
        self.label = label
        self.placement = placement
        self.durationSeconds = durationSeconds
        self.guidance = guidance
    }

    var isUnchanged: Bool {
        label.isUnchanged && placement.isUnchanged && durationSeconds.isUnchanged
            && guidance.isUnchanged
    }
}

/// Wave 8 set-alternative patch. The label is required alternative state (set-only).
struct SetAlternativePatch: Equatable, Sendable {
    var label: MetadataPatch<String>
    var values: MetadataPatch<PlannedSetValuesPatch>
    var ranges: MetadataPatch<[MetricTargetRange]>

    init(
        label: MetadataPatch<String> = .unchanged,
        values: MetadataPatch<PlannedSetValuesPatch> = .unchanged,
        ranges: MetadataPatch<[MetricTargetRange]> = .unchanged
    ) {
        self.label = label
        self.values = values
        self.ranges = ranges
    }

    var isUnchanged: Bool { label.isUnchanged && values.isUnchanged && ranges.isUnchanged }
}

/// Wave 8 exercise-prescription patch: the per-exercise targets that sit beside the set list.
struct ExercisePrescriptionPatch: Equatable, Sendable {
    var restSeconds: MetadataPatch<Int>
    var tempo: MetadataPatch<String>
    var targetZone: MetadataPatch<Int>
    var intent: MetadataPatch<TrainingIntent>
    var intensityTargets: MetadataPatch<[IntensityTarget]>

    init(
        restSeconds: MetadataPatch<Int> = .unchanged,
        tempo: MetadataPatch<String> = .unchanged,
        targetZone: MetadataPatch<Int> = .unchanged,
        intent: MetadataPatch<TrainingIntent> = .unchanged,
        intensityTargets: MetadataPatch<[IntensityTarget]> = .unchanged
    ) {
        self.restSeconds = restSeconds
        self.tempo = tempo
        self.targetZone = targetZone
        self.intent = intent
        self.intensityTargets = intensityTargets
    }

    var isUnchanged: Bool {
        restSeconds.isUnchanged && tempo.isUnchanged && targetZone.isUnchanged
            && intent.isUnchanged && intensityTargets.isUnchanged
    }
}

/// One typed operation inside an atomic `apply_workout_edits` batch. Each case carries exactly the
/// payload of the matching single tool, minus the revision token — the batch states that once and
/// every operation validates against the same snapshot before one commit, so a later operation's
/// failure can never leave the workout half-edited.
enum WorkoutEditOperation: Equatable, Sendable {
    /// `note` is the workout's one free-form text and writes `Workout.goal`. The workout level has no
    /// coach-guidance payload to carry: guidance is per block, group, rest, and exercise.
    case updateWorkoutMetadata(
        title: MetadataPatch<String>,
        note: MetadataPatch<String>
    )
    case updateBlockMetadata(
        blockID: UUID,
        name: MetadataPatch<String>,
        intent: MetadataPatch<String>,
        guidance: MetadataPatch<String>
    )
    case updateExerciseMetadata(
        exerciseInstanceID: UUID,
        displayLabel: MetadataPatch<String>,
        guidance: MetadataPatch<String>
    )
    case addBlock(name: String, intent: String?, guidance: String?, atIndex: Int?)
    case removeBlock(blockID: UUID)
    case moveBlock(blockID: UUID, toIndex: Int)
    case duplicateBlock(blockID: UUID)
    case addExercise(
        containerID: UUID,
        name: String,
        atIndex: Int?,
        sets: Int?,
        reps: Int?,
        load: Double?,
        durationSeconds: Int?,
        distanceMeters: Double?
    )
    case moveExercise(exerciseInstanceID: UUID, toBlockID: UUID, toIndex: Int)
    case replaceExercise(exerciseInstanceID: UUID, replacement: String)
    case removeExercise(exerciseInstanceID: UUID)
    case reorderExercise(exerciseInstanceID: UUID, toIndex: Int)
    case duplicateExercise(exerciseInstanceID: UUID)
    // Wave 8: advanced nodes and prescriptions, all on the one recursive node API.
    case updateGroup(groupID: UUID, patch: WorkoutGroupPatch)
    case updateChoice(choiceID: UUID, label: MetadataPatch<String>, selectionCount: MetadataPatch<Int>)
    case convertChoiceToGroup(choiceID: UUID)
    case updateRest(restID: UUID, patch: PlannedRestPatch)
    case addRest(
        parentID: UUID,
        atIndex: Int?,
        durationSeconds: Int?,
        placement: RestPlacement,
        label: String?,
        guidance: String?
    )
    case moveNode(nodeID: UUID, toParentID: UUID, toIndex: Int)
    case removeNode(nodeID: UUID)
    case addSetAlternative(setID: UUID, label: String, values: PlannedSetValues, ranges: [MetricTargetRange])
    case updateSetAlternative(alternativeID: UUID, patch: SetAlternativePatch)
    case removeSetAlternative(alternativeID: UUID)
    case updateExercisePrescription(exerciseInstanceID: UUID, patch: ExercisePrescriptionPatch)
    case addSet(
        exerciseInstanceID: UUID,
        afterSetID: UUID?,
        values: PlannedSetValues,
        role: SetRole,
        targets: PlannedSetTargets
    )
    case updateSet(setID: UUID, patch: PlannedSetPatch)
    case removeSet(setID: UUID)
    case moveSet(setID: UUID, beforeSetID: UUID?, toIndex: Int?)
    case duplicateSet(setID: UUID)
    case setMetricValue(exerciseInstanceID: UUID, setID: UUID, metric: MetricType, value: Double, unit: MetricUnit?)
    case removeMetric(exerciseInstanceID: UUID, metric: MetricType)
    case updateLoggingConfig(exerciseInstanceID: UUID, enabledMetrics: [MetricType]?, units: [MetricType: MetricUnit])

    /// The public tool name this operation mirrors — a batch error names the failing op with it.
    var toolName: String {
        switch self {
        case .updateWorkoutMetadata: "update_workout_metadata"
        case .updateBlockMetadata: "update_block_metadata"
        case .updateExerciseMetadata: "update_exercise_metadata"
        case .addBlock: "add_block"
        case .removeBlock: "remove_block"
        case .moveBlock: "move_block"
        case .duplicateBlock: "duplicate_block"
        case .addExercise: "add_exercise"
        case .moveExercise: "move_exercise"
        case .replaceExercise: "replace_exercise"
        case .removeExercise: "remove_exercise"
        case .reorderExercise: "reorder_exercise"
        case .duplicateExercise: "duplicate_exercise"
        case .addSet: "add_set"
        case .updateSet: "update_set"
        case .removeSet: "remove_set"
        case .moveSet: "move_set"
        case .duplicateSet: "duplicate_set"
        case .setMetricValue: "set_metric_value"
        case .removeMetric: "remove_metric"
        case .updateLoggingConfig: "update_logging_config"
        case .updateGroup: "update_group"
        case .updateChoice: "update_choice"
        case .convertChoiceToGroup: "convert_choice_to_group"
        case .updateRest: "update_rest"
        case .addRest: "add_rest"
        case .moveNode: "move_node"
        case .removeNode: "remove_node"
        case .addSetAlternative: "add_set_alternative"
        case .updateSetAlternative: "update_set_alternative"
        case .removeSetAlternative: "remove_set_alternative"
        case .updateExercisePrescription: "update_exercise_prescription"
        }
    }
}

/// The raw explicit-taxonomy selector the Wave 7 bulk tools target instances with. Taxonomy values
/// stay raw strings here so the store can answer an unknown value with a correctable message listing
/// the valid values — the same contract `search_exercises` uses — instead of a bare rejection.
struct BulkExerciseSelectorInput: Equatable, Sendable {
    var definitionID: String?
    var muscle: String?
    var equipment: String?
    var modality: String?
    var pattern: String?
    var tag: String?
    var level: String?
    var blockID: UUID?

    init(
        definitionID: String? = nil,
        muscle: String? = nil,
        equipment: String? = nil,
        modality: String? = nil,
        pattern: String? = nil,
        tag: String? = nil,
        level: String? = nil,
        blockID: UUID? = nil
    ) {
        self.definitionID = definitionID
        self.muscle = muscle
        self.equipment = equipment
        self.modality = modality
        self.pattern = pattern
        self.tag = tag
        self.level = level
        self.blockID = blockID
    }

    var isEmpty: Bool {
        definitionID == nil && muscle == nil && equipment == nil && modality == nil
            && pattern == nil && tag == nil && level == nil && blockID == nil
    }
}

/// The Context Engine's **validated tool layer** — the deterministic operations the LLM *proposes*
/// and this *executes*. The model understands language; this owns what actually happens: every call
/// is typed and validated, mutates the structured state, and returns the **recomputed** plan so the
/// conversation always reflects truth. The LLM never edits data or invents a score.
///
/// Workout-content mutations apply immediately through one revision-checked envelope and return a
/// durable receipt. `base` is today's evidence snapshot (HRV/RHR/sleep/check-in) the app supplies.
@MainActor
final class AgentTools {

    /// A validated operation the assistant can request. The backend maps the LLM's JSON tool-calls
    /// into these; nothing else can mutate state through the conversation.
    enum Call: Sendable, Equatable {
        case getToday
        case explain
        case setTimeAvailable(Int?)
        case setEquipment([String]?)
        case setTraveling(Bool?)
        case setIllness(Bool?)
        case setSleep(hours: Double?)
        case setCheckIn(energy: Double?, mood: Double?, stress: Double?, soreness: Double?)
        case setNote(String?)
        case upsertConstraint(id: UUID?, kind: DecisionEngine.Constraint.Kind, location: String, severity: Int, affectsTraining: Bool)
        case resolveConstraint(id: UUID)
        case openAppleHealthSetup
        // Retrieval — the model asks; the app fetches the truth (HealthKit / the reading store)
        // rather than answering from memory. Executed via `execute` (async).
        case getSleep(nightsAgo: Int)
        case getHRVReadings(limit: Int)
        case getRestingHeartRate(days: Int)
        // Workout editing. Stable instance IDs from get_current_workout take precedence over names.
        case createWorkout(title: String, note: String?, replaceExisting: Bool, expectedRevisionToken: UUID? = nil)
        case updateWorkoutMetadata(
            title: MetadataPatch<String>,
            note: MetadataPatch<String>,
            expectedRevisionToken: UUID
        )
        case updateBlockMetadata(
            blockID: UUID,
            name: MetadataPatch<String>,
            intent: MetadataPatch<String>,
            guidance: MetadataPatch<String>,
            expectedRevisionToken: UUID
        )
        case updateExerciseMetadata(
            exerciseInstanceID: UUID,
            displayLabel: MetadataPatch<String>,
            guidance: MetadataPatch<String>,
            expectedRevisionToken: UUID
        )
        case addBlock(name: String, intent: String?, guidance: String?, atIndex: Int?, expectedRevisionToken: UUID)
        case removeBlock(blockID: UUID, expectedRevisionToken: UUID)
        case moveBlock(blockID: UUID, toIndex: Int, expectedRevisionToken: UUID)
        case duplicateBlock(blockID: UUID, expectedRevisionToken: UUID)
        case addExercise(containerID: UUID, name: String, atIndex: Int?, sets: Int?, reps: Int?, load: Double?, durationSeconds: Int?, distanceMeters: Double?, expectedRevisionToken: UUID)
        case moveExercise(exerciseInstanceID: UUID, toBlockID: UUID, toIndex: Int, expectedRevisionToken: UUID)
        case replaceExercise(exerciseInstanceID: UUID, replacement: String, expectedRevisionToken: UUID)
        case requireAllOptions(choice: String, expectedRevisionToken: UUID? = nil)
        case removeExercise(exerciseInstanceID: UUID, expectedRevisionToken: UUID)
        case reorderExercise(exerciseInstanceID: UUID, toIndex: Int, expectedRevisionToken: UUID)
        case duplicateExercise(exerciseInstanceID: UUID, expectedRevisionToken: UUID)
        case addSet(
            exerciseInstanceID: UUID,
            afterSetID: UUID?,
            values: PlannedSetValues,
            role: SetRole,
            targets: PlannedSetTargets,
            expectedRevisionToken: UUID
        )
        case updateSet(setID: UUID, patch: PlannedSetPatch, expectedRevisionToken: UUID)
        case removeSet(setID: UUID, expectedRevisionToken: UUID)
        case moveSet(setID: UUID, beforeSetID: UUID?, toIndex: Int?, expectedRevisionToken: UUID)
        case duplicateSet(setID: UUID, expectedRevisionToken: UUID)
        // Wave 8: advanced nodes and prescriptions — groups, choices, rests, generic nested-node
        // moves, set alternatives, and per-exercise prescription targets.
        case updateGroup(groupID: UUID, patch: WorkoutGroupPatch, expectedRevisionToken: UUID)
        case updateChoice(
            choiceID: UUID,
            label: MetadataPatch<String>,
            selectionCount: MetadataPatch<Int>,
            expectedRevisionToken: UUID
        )
        case convertChoiceToGroup(choiceID: UUID, expectedRevisionToken: UUID)
        case updateRest(restID: UUID, patch: PlannedRestPatch, expectedRevisionToken: UUID)
        case addRest(
            parentID: UUID,
            atIndex: Int?,
            durationSeconds: Int?,
            placement: RestPlacement,
            label: String?,
            guidance: String?,
            expectedRevisionToken: UUID
        )
        case moveNode(nodeID: UUID, toParentID: UUID, toIndex: Int, expectedRevisionToken: UUID)
        case removeNode(nodeID: UUID, expectedRevisionToken: UUID)
        case addSetAlternative(
            setID: UUID,
            label: String,
            values: PlannedSetValues,
            ranges: [MetricTargetRange],
            expectedRevisionToken: UUID
        )
        case updateSetAlternative(alternativeID: UUID, patch: SetAlternativePatch, expectedRevisionToken: UUID)
        case removeSetAlternative(alternativeID: UUID, expectedRevisionToken: UUID)
        case updateExercisePrescription(
            exerciseInstanceID: UUID,
            patch: ExercisePrescriptionPatch,
            expectedRevisionToken: UUID
        )
        // Wave 7: one atomic batch of the primitive edits above, and selector-driven bulk mutations.
        case applyWorkoutEdits(operations: [WorkoutEditOperation], expectedRevisionToken: UUID)
        case convertWorkoutUnits(
            units: [MetricType: MetricUnit],
            selector: BulkExerciseSelectorInput?,
            dryRun: Bool,
            expectedRevisionToken: UUID
        )
        case bulkReplaceExercises(
            selector: BulkExerciseSelectorInput,
            replacementDefinitionID: String,
            dryRun: Bool,
            expectedRevisionToken: UUID
        )
        // Wave 9: deliberate custom exercise creation - two-phase (proposal, then commit with the
        // proposal id) so an inferred classification is always surfaced before it is committed.
        case createCustomExercise(
            draft: WorkoutStore.CustomExerciseDraft,
            proposalID: UUID?,
            expectedRevisionToken: UUID
        )
        case undoWorkoutMutation(mutationID: UUID, expectedRevisionToken: UUID)
        case getCurrentWorkout
        // Performed logging. These mutate WorkoutLog only and use its independent revision token.
        case getActiveSession
        case upsertPerformedSet(
            exerciseInstanceID: UUID,
            plannedSetID: UUID,
            groupID: UUID?,
            iteration: Int?,
            values: [PerformedMetricInput],
            expectedRevisionToken: UUID
        )
        case setPerformedSetOutcome(
            target: PerformedSetTarget,
            outcome: SetLogOutcome,
            expectedRevisionToken: UUID
        )
        case addExtraPerformedSet(
            exerciseInstanceID: UUID,
            groupID: UUID?,
            iteration: Int?,
            values: [PerformedMetricInput],
            expectedRevisionToken: UUID
        )
        case updateExtraPerformedSet(
            performedSetID: UUID,
            values: [PerformedMetricInput],
            expectedRevisionToken: UUID
        )
        case deleteExtraPerformedSet(performedSetID: UUID, expectedRevisionToken: UUID)
        case addExerciseSessionNote(
            exerciseInstanceID: UUID,
            note: String,
            expectedRevisionToken: UUID
        )
        case undoSessionMutation(mutationID: UUID, expectedRevisionToken: UUID)
        case startWorkout
        case completeWorkout(confirm: Bool)
        // Catalog retrieval - the model reads the ~900-exercise library instead of guessing names.
        // Read-only: these never touch state.
        case searchExercises(query: String?, muscle: String?, equipment: String?, modality: String?,
                             pattern: String?, tag: String?, level: String?)
        case getExercise(name: String?, id: String?)
        // Plan (week-level schedule) — reshuffle the week through the same versioned repository ops.
        case getWeekPlan
        case moveWorkout(workout: String, toDay: String)
        case swapWorkouts(a: String, b: String)
        case skipWorkout(workout: String, skipped: Bool)
        case duplicateWorkout(workout: String, toDay: String?)
        case deleteWorkout(workout: String, proposalID: String?)
        case explainModification(workout: String)
        // Templates — save today's workout for reuse; build a workout from one.
        case saveAsTemplate(name: String)
        case createFromTemplate(name: String, day: String)
        case updateTemplate(name: String)
        // Metric system: configure which metrics an exercise logs + display units, and set values.
        case updateLoggingConfig(exerciseInstanceID: UUID, enabledMetrics: [MetricType]?, units: [MetricType: MetricUnit], expectedRevisionToken: UUID)
        case updateExercisePreference(exercise: String, scope: WorkoutStore.PreferenceScope, units: [MetricType: MetricUnit], selectedMetrics: [MetricType]?)
        case setMetricValue(exerciseInstanceID: UUID, setID: UUID, metric: MetricType, value: Double, unit: MetricUnit?, expectedRevisionToken: UUID)
        case removeMetric(exerciseInstanceID: UUID, metric: MetricType, expectedRevisionToken: UUID)

        /// A short human-readable summary of what this call did — for the "what Baseline knows"
        /// inspector's activity feed, so the behind-the-scenes mutations are visible.
        var activityLabel: String {
            switch self {
            case .getToday: return "Read today's state"
            case .explain: return "Explained the plan"
            case .setTimeAvailable(let m): return m.map { "Time available → \($0) min" } ?? "Cleared time available"
            case .setEquipment(let e): return "Equipment → \(e?.joined(separator: ", ") ?? "cleared")"
            case .setTraveling(let t): return t == true ? "Traveling → yes" : "Traveling → no"
            case .setIllness(let i): return i == true ? "Marked unwell" : "Marked well"
            case .setSleep(let h): return h.map { "Sleep → \(String(format: "%g", $0)) h" } ?? "Cleared sleep"
            case .setCheckIn(let e, let m, let s, let so):
                let parts = [("energy", e), ("mood", m), ("stress", s), ("soreness", so)]
                    .compactMap { label, v in v.map { "\(label) \(Int($0))" } }
                return "Check-in → " + (parts.isEmpty ? "—" : parts.joined(separator: ", "))
            case .upsertConstraint(_, let kind, let location, let severity, let affects):
                return "Constraint → \(location) (\(kind.rawValue), sev \(severity))\(affects ? "" : ", not limiting")"
            case .setNote: return "Saved a note"
            case .resolveConstraint: return "Resolved a constraint"
            case .openAppleHealthSetup: return "Opened Apple Health setup"
            case .getSleep(let n): return "Retrieved sleep (\(n == 0 ? "last night" : "\(n) nights ago")) from Apple Health"
            case .getHRVReadings(let l): return "Retrieved \(l) recent HRV readings"
            case .getRestingHeartRate(let d): return "Retrieved resting HR (\(d)-day) from Apple Health"
            case .createWorkout(let t, _, _, _): return "Created workout: \(t)"
            case .updateWorkoutMetadata(let title, let note, _):
                return Self.metadataActivityLabel(
                    subject: "workout",
                    fields: [("title", title), ("note", note)]
                )
            case .updateBlockMetadata(_, let name, let intent, let guidance, _):
                return Self.metadataActivityLabel(
                    subject: "block",
                    fields: [("name", name), ("intent", intent), ("guidance", guidance)]
                )
            case .updateExerciseMetadata(_, let displayLabel, let guidance, _):
                return Self.metadataActivityLabel(
                    subject: "exercise",
                    fields: [("display label", displayLabel), ("guidance", guidance)]
                )
            case .addBlock(let name, _, _, _, _): return "Added block: \(name)"
            case .removeBlock: return "Removed a block"
            case .moveBlock: return "Moved a block"
            case .duplicateBlock: return "Duplicated a block"
            case .addExercise(_, let name, _, _, _, _, _, _, _): return "Added \(name)"
            case .moveExercise: return "Moved an exercise"
            case .replaceExercise(_, let replacement, _): return "Replaced an exercise with \(replacement)"
            case .requireAllOptions(let choice, _): return "Made every option required in \(choice)"
            case .removeExercise: return "Removed an exercise"
            case .reorderExercise: return "Reordered an exercise"
            case .duplicateExercise: return "Duplicated an exercise"
            case .addSet: return "Added a planned set"
            case .updateSet: return "Updated a planned set"
            case .removeSet: return "Removed a planned set"
            case .moveSet: return "Moved a planned set"
            case .duplicateSet: return "Duplicated a planned set"
            case .updateGroup: return "Updated a group"
            case .updateChoice: return "Updated a choice"
            case .convertChoiceToGroup: return "Made every option required in a choice"
            case .updateRest: return "Updated a rest"
            case .addRest: return "Added a rest"
            case .moveNode: return "Moved a workout node"
            case .removeNode: return "Removed a workout node"
            case .addSetAlternative: return "Added a set alternative"
            case .updateSetAlternative: return "Updated a set alternative"
            case .removeSetAlternative: return "Removed a set alternative"
            case .updateExercisePrescription: return "Updated an exercise's prescription"
            case .applyWorkoutEdits(let operations, _):
                return "Applied \(operations.count) workout edit\(operations.count == 1 ? "" : "s") atomically"
            case .convertWorkoutUnits: return "Converted workout display units"
            case .bulkReplaceExercises(_, let replacementDefinitionID, _, _):
                return "Bulk-replaced exercises with \(replacementDefinitionID)"
            case .createCustomExercise(let draft, _, _): return "Created custom exercise \(draft.name)"
            case .undoWorkoutMutation: return "Undid a workout edit"
            case .getCurrentWorkout: return "Read the current workout"
            case .getActiveSession: return "Read the active session"
            case .upsertPerformedSet: return "Logged performed-set values"
            case .setPerformedSetOutcome(_, let outcome, _): return "Marked a performed set \(outcome.rawValue)"
            case .addExtraPerformedSet: return "Added an extra performed set"
            case .updateExtraPerformedSet: return "Updated an extra performed set"
            case .deleteExtraPerformedSet: return "Deleted an extra performed set"
            case .addExerciseSessionNote: return "Added an exercise session note"
            case .undoSessionMutation: return "Undid a session edit"
            case .startWorkout: return "Started the workout"
            case .completeWorkout: return "Completed the workout"
            case .searchExercises(let q, let mu, let eq, let mo, let pa, let ta, let lv):
                let terms = [q, mu, eq, mo, pa, ta, lv].compactMap { $0 }
                return "Searched exercises" + (terms.isEmpty ? "" : ": \(terms.joined(separator: ", "))")
            case .getExercise(let name, let id): return "Looked up \(name ?? id ?? "an exercise")"
            case .getWeekPlan: return "Read the week's plan"
            case .moveWorkout(let w, let d): return "Moved \(w) → \(d)"
            case .swapWorkouts(let a, let b): return "Swapped \(a) ↔ \(b)"
            case .skipWorkout(let w, let s): return "\(s ? "Skipped" : "Unskipped") \(w)"
            case .duplicateWorkout(let w, _): return "Duplicated \(w)"
            case .deleteWorkout(let w, _): return "Deleted \(w)"
            case .explainModification(let w): return "Explained \(w)"
            case .saveAsTemplate(let n): return "Saved template \(n)"
            case .createFromTemplate(let n, let d): return "Added \(n) → \(d)"
            case .updateTemplate(let n): return "Updated template \(n)"
            case .updateLoggingConfig: return "Configured exercise metrics"
            case .updateExercisePreference(let e, let s, _, _): return "Saved \(s.rawValue) default for \(e)"
            case .setMetricValue(_, _, let metric, _, _, _): return "Set \(metric.label.lowercased()) on a planned set"
            case .removeMetric(_, let metric, _): return "Removed \(metric.label.lowercased()) from an exercise"
            }
        }

        /// Whether `activityLabel` belongs in the inspector's "what changed" feed. Mutations do, and so
        /// does retrieval that reaches outside the app for the athlete's own data - pulling from Apple
        /// Health is worth showing. Reads of state the inspector already displays, and of the static
        /// exercise catalog, changed nothing and would only be noise.
        ///
        /// Exhaustive by design: a new tool must classify itself here rather than inherit a `default:`.
        var showsInActivityFeed: Bool {
            switch self {
            case .getToday, .explain, .getCurrentWorkout, .getActiveSession, .getWeekPlan, .explainModification,
                 .searchExercises, .getExercise:
                return false
            case .setTimeAvailable, .setEquipment, .setTraveling, .setIllness, .setSleep, .setCheckIn,
                 .setNote, .upsertConstraint, .resolveConstraint, .openAppleHealthSetup, .getSleep,
                 .getHRVReadings, .getRestingHeartRate, .createWorkout, .addBlock, .addExercise,
                 .updateWorkoutMetadata, .updateBlockMetadata, .updateExerciseMetadata,
                 .removeBlock, .moveBlock, .duplicateBlock, .moveExercise, .replaceExercise,
                 .requireAllOptions, .removeExercise, .reorderExercise, .duplicateExercise, .addSet,
                 .updateSet, .removeSet, .moveSet, .duplicateSet,
                 .updateGroup, .updateChoice, .convertChoiceToGroup, .updateRest, .addRest,
                 .moveNode, .removeNode, .addSetAlternative, .updateSetAlternative,
                 .removeSetAlternative, .updateExercisePrescription,
                 .applyWorkoutEdits, .convertWorkoutUnits, .bulkReplaceExercises,
                 .createCustomExercise,
                 .undoWorkoutMutation, .upsertPerformedSet, .setPerformedSetOutcome,
                 .addExtraPerformedSet, .updateExtraPerformedSet, .deleteExtraPerformedSet,
                 .addExerciseSessionNote, .undoSessionMutation,
                 .startWorkout, .completeWorkout, .moveWorkout, .swapWorkouts, .skipWorkout,
                 .duplicateWorkout, .deleteWorkout, .saveAsTemplate, .createFromTemplate,
                 .updateTemplate, .updateLoggingConfig, .updateExercisePreference, .setMetricValue,
                 .removeMetric:
                return true
            }
        }

        /// Receipt-bound edits record activity only after the shared mutation envelope confirms a
        /// write. This keeps stale and missing-target calls out of the "what changed" feed.
        var requiresWorkoutMutationReceiptForActivity: Bool {
            switch self {
            case .updateWorkoutMetadata, .updateBlockMetadata, .updateExerciseMetadata,
                 .addBlock, .addExercise, .moveExercise, .replaceExercise, .requireAllOptions,
                 .removeBlock, .moveBlock, .duplicateBlock, .removeExercise, .reorderExercise,
                 .duplicateExercise, .addSet, .updateSet, .removeSet, .moveSet, .duplicateSet,
                 .updateGroup, .updateChoice, .convertChoiceToGroup, .updateRest, .addRest,
                 .moveNode, .removeNode, .addSetAlternative, .updateSetAlternative,
                 .removeSetAlternative, .updateExercisePrescription,
                 .applyWorkoutEdits, .convertWorkoutUnits, .bulkReplaceExercises,
                 .createCustomExercise,
                 .undoWorkoutMutation, .updateLoggingConfig,
                 .setMetricValue, .removeMetric, .upsertPerformedSet, .setPerformedSetOutcome,
                 .addExtraPerformedSet, .updateExtraPerformedSet, .deleteExtraPerformedSet,
                 .addExerciseSessionNote, .undoSessionMutation:
                return true
            default:
                return false
            }
        }

        private static func metadataActivityLabel(
            subject: String,
            fields: [(String, MetadataPatch<String>)]
        ) -> String {
            let changed = fields.filter { !$0.1.isUnchanged }
            guard changed.count == 1, let (field, patch) = changed.first else {
                return "Updated \(subject) " + changed.map(\.0).joined(separator: ", ")
            }
            switch patch {
            case .unchanged:
                return "Updated \(subject)"
            case .clear:
                return "Cleared \(subject) \(field)"
            case .set(let value):
                if field == "title" || field == "name" { return "Renamed \(subject) to \(value)" }
                if field == "display label" { return "Labeled \(subject) \(value)" }
                if field == "guidance" { return "Updated \(subject) guidance" }
                return "Set \(subject) \(field) to \(value)"
            }
        }
    }

    struct Response: Sendable {
        let text: String                       // what the model sees back (may carry machine payload)
        let userFacingText: String             // the human sentence a chat bubble may show the athlete
        let decision: DecisionEngine.Result?
        let plan: PlanningEngine.Plan?
        let mutationReceipt: WorkoutMutationReceipt?

        init(
            text: String,
            decision: DecisionEngine.Result?,
            plan: PlanningEngine.Plan?,
            mutationReceipt: WorkoutMutationReceipt? = nil,
            userFacingText: String? = nil
        ) {
            self.text = text
            self.userFacingText = userFacingText ?? text
            self.decision = decision
            self.plan = plan
            self.mutationReceipt = mutationReceipt
        }
    }

    private let store: TrainingContextStore
    var base: DecisionEngine.Inputs             // today's evidence; refreshed by the app after a reading
    var style: PlanningEngine.Style

    /// Live app state the model needs to answer "how do I…" and to *do* things (not just describe
    /// them). `health` powers Apple Health capability status + the connect action; `hrvConfigured`
    /// reflects whether a reading source is set up.
    private let health: HealthService?
    private let hrvConfigured: Bool
    private let readings: [Reading]              // recent HRV readings, newest first — for retrieval
    private let workouts: WorkoutStore?         // today's structured workout the chat can edit
    private let plan: PlanStore?                // the week-level schedule the chat can reshuffle

    init(store: TrainingContextStore, base: DecisionEngine.Inputs = .init(), style: PlanningEngine.Style = .balanced,
         health: HealthService? = nil, hrvConfigured: Bool = false, readings: [Reading] = [], workouts: WorkoutStore? = nil,
         plan: PlanStore? = nil) {
        self.store = store
        self.base = base
        self.style = style
        self.health = health
        self.hrvConfigured = hrvConfigured
        self.readings = readings
        self.workouts = workouts
        self.plan = plan
    }

    // MARK: - Async execution (retrieval tools do real I/O; state tools stay synchronous)

    /// The entry point the conversation runtime calls. Retrieval tools fetch from HealthKit / the
    /// reading store; everything else falls through to the synchronous `dispatch`.
    func execute(_ call: Call) async -> Response {
        switch call {
        case .getSleep(let nightsAgo): return await retrieveSleep(nightsAgo: nightsAgo)
        case .getHRVReadings(let limit): return retrieveReadings(limit: limit)
        case .getRestingHeartRate(let days): return await retrieveRestingHR(days: days)
        default: return dispatch(call)
        }
    }

    private func retrieveSleep(nightsAgo: Int) async -> Response {
        guard let health, health.isAvailable else {
            return Response(text: "Apple Health isn't available on this device, so I can't pull sleep.", decision: nil, plan: nil)
        }
        guard health.requested else {
            return Response(text: "Apple Health isn't set up yet, so there's nothing to read — that's different from the athlete having no sleep logged. Offer to connect it with open_apple_health_setup.", decision: nil, plan: nil)
        }
        let when = nightsAgo == 0 ? "last night" : "\(nightsAgo) night\(nightsAgo == 1 ? "" : "s") ago"
        guard let s = await health.sleepSummary(nightsAgo: nightsAgo) else {
            return Response(text: "Apple Health has no sleep recorded for \(when).", decision: nil, plan: nil)
        }
        // Raw Apple Health numbers, kept distinct from Baseline's own computed score.
        let h = Int(s.hours), m = Int((s.hours - Double(h)) * 60)
        var parts = ["\(h)h \(m)m asleep"]
        if let d = s.deepHours { parts.append("\(Int((d * 60).rounded())) min deep") }
        if let r = s.remHours { parts.append("\(Int((r * 60).rounded())) min REM") }
        if let e = s.efficiency { parts.append("\(Int((e * 100).rounded()))% efficiency") }
        var text = "Apple Health, \(when): " + parts.joined(separator: ", ") + "."
        if let score = ReadinessScore.sleepScore(hours: s.hours, efficiency: s.efficiency) {
            text += " Baseline's own sleep score (computed from this, not an Apple number): \(Int(score.rounded()))/100."
        }
        return Response(text: text, decision: nil, plan: nil)
    }

    private func retrieveReadings(limit: Int) -> Response {
        let recent = readings.prefix(max(1, min(limit, 30)))
        guard !recent.isEmpty else {
            return Response(text: "No HRV readings are on file yet — the athlete hasn't taken one in Baseline.", decision: nil, plan: nil)
        }
        let list = recent.map {
            "\($0.date.formatted(date: .abbreviated, time: .shortened)) — RMSSD \(Int($0.rmssd.rounded())) ms, HR \(Int($0.meanHR.rounded())) bpm (\($0.kind.title))"
        }.joined(separator: "; ")
        return Response(text: "Recent Baseline HRV readings, newest first: \(list).", decision: nil, plan: nil)
    }

    private func retrieveRestingHR(days: Int) async -> Response {
        guard let health, health.isAvailable else {
            return Response(text: "Apple Health isn't available on this device, so I can't pull resting heart rate.", decision: nil, plan: nil)
        }
        guard health.requested else {
            return Response(text: "Apple Health isn't set up yet, so there's no resting heart rate to read (NOT 'no data'). Offer to connect it with open_apple_health_setup.", decision: nil, plan: nil)
        }
        let d = max(1, min(days, 90))
        let samples = await health.restingHeartRate(days: d)
        guard let latest = samples.first else {
            return Response(text: "Apple Health has no resting heart-rate samples in the last \(d) days.", decision: nil, plan: nil)
        }
        let avg = samples.map(\.bpm).reduce(0, +) / Double(samples.count)
        let list = samples.prefix(7).map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \(Int($0.bpm.rounded())) bpm" }.joined(separator: "; ")
        return Response(text: "Apple Health resting HR — latest \(Int(latest.bpm.rounded())) bpm, \(d)-day average \(Int(avg.rounded())) bpm. Recent: \(list).", decision: nil, plan: nil)
    }

    // MARK: - Dispatch

    func dispatch(_ call: Call) -> Response {
        switch call {
        case .getToday:
            return respond(prefix: nil)
        case .explain:
            let (d, p) = today()
            return Response(text: explanation(d, p), decision: d, plan: p)
        case .setTimeAvailable(let minutes):
            let clamped = minutes.map { max(0, $0) }
            store.setTimeAvailable(clamped)
            return respond(prefix: clamped.map { "\($0) min today." } ?? "Time cleared.")
        case .setEquipment(let equipment):
            store.setEquipment(equipment)
            return respond(prefix: "Equipment updated.")
        case .setTraveling(let traveling):
            store.setTraveling(traveling)
            return respond(prefix: traveling == true ? "Traveling — noted." : "Not traveling.")
        case .setIllness(let ill):
            store.setIllness(ill)
            return respond(prefix: ill == true ? "Sorry you're under the weather — noted." : "Glad you're well.")
        case .setSleep(let hours):
            store.setSleep(hours: hours)
            return respond(prefix: hours.map { "Logged \(String(format: "%g", max(0, $0))) h sleep." } ?? "Sleep cleared.")
        case .setCheckIn(let energy, let mood, let stress, let soreness):
            guard energy != nil || mood != nil || stress != nil || soreness != nil else {
                return Response(text: "Tell me what you felt (energy, mood, stress, or soreness) and I'll log it.", decision: nil, plan: nil)
            }
            store.setCheckIn(energy: energy, mood: mood, stress: stress, soreness: soreness)
            return respond(prefix: "Check-in logged.")
        case .setNote(let note):
            store.setNote(note)
            return respond(prefix: "Noted.")
        case .upsertConstraint(let id, let kind, let location, let severity, let affects):
            let loc = location.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !loc.isEmpty else {
                return Response(text: "I need a body location to log that.", decision: nil, plan: nil)
            }
            store.upsertConstraint(id: id, kind: kind, location: loc, severity: severity, affectsTraining: affects)
            return respond(prefix: "Logged \(loc) — \(kind.rawValue), severity \(min(max(severity, 0), 3))\(affects ? "" : " (not affecting training)").")
        case .resolveConstraint(let id):
            guard store.resolveConstraint(id: id) else {
                return Response(text: "I couldn't find that one to resolve.", decision: nil, plan: nil)
            }
            return respond(prefix: "Marked resolved.")
        case .openAppleHealthSetup:
            guard let health, health.isAvailable else {
                return Response(text: "Apple Health isn't available on this device.", decision: nil, plan: nil)
            }
            Task { await health.requestReadAccess() }
            return Response(text: "Opening Apple Health - grant read access in the sheet and I'll fold your sleep and resting HR into today's plan.", decision: nil, plan: nil)
        case .createWorkout(let title, let note, let replace, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            if let existing = currentWorkout, !replace {
                return Response(text: "There's already a workout (\"\(existing.title)\"). Creating a new one will replace it and discard the current one - confirm and I'll do it.", decision: nil, plan: nil)
            }
            return outcome(
                workouts.create(title: title, goal: note, expectedRevisionToken: expectedRevisionToken),
                success: "Created workout \"\(title)\"."
            )
        case .updateWorkoutMetadata(let title, let note, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.updateWorkoutMetadata(
                    title: title,
                    note: note,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "\(call.activityLabel)."
            )
        case .updateBlockMetadata(let blockID, let name, let intent, let guidance, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.updateBlockMetadata(
                    blockID: blockID,
                    name: name,
                    intent: intent,
                    guidance: guidance,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "\(call.activityLabel)."
            )
        case .updateExerciseMetadata(
            let exerciseInstanceID,
            let displayLabel,
            let guidance,
            let expectedRevisionToken
        ):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.updateExerciseMetadata(
                    exerciseInstanceID: exerciseInstanceID,
                    displayLabel: displayLabel,
                    guidance: guidance,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "\(call.activityLabel)."
            )
        case .addBlock(let name, let intent, let guidance, let atIndex, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.addBlock(
                    name: name,
                    intent: intent,
                    guidance: guidance,
                    atIndex: atIndex,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Added block \"\(name)\"."
            )
        case .removeBlock(let blockID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.removeBlock(blockID: blockID, expectedRevisionToken: expectedRevisionToken),
                success: "Removed the block."
            )
        case .moveBlock(let blockID, let toIndex, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.moveBlock(
                    blockID: blockID,
                    toIndex: toIndex,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Moved the block."
            )
        case .duplicateBlock(let blockID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.duplicateBlock(
                    blockID: blockID,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Duplicated the block."
            )
        case .addExercise(
            let containerID,
            let name,
            let atIndex,
            let sets,
            let reps,
            let load,
            let dur,
            let dist,
            let expectedRevisionToken
        ):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.addExercise(
                    name: name,
                    toContainerID: containerID,
                    atIndex: atIndex,
                    sets: sets,
                    reps: reps,
                    load: load,
                    durationSeconds: dur,
                    distanceMeters: dist,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Added \(name)."
            )
        case .moveExercise(let exerciseInstanceID, let toBlockID, let toIndex, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.moveExercise(
                    exerciseInstanceID: exerciseInstanceID,
                    toBlockID: toBlockID,
                    toIndex: toIndex,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Moved the exercise."
            )
        case .replaceExercise(let exerciseInstanceID, let replacement, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.replaceExercise(
                    exerciseInstanceID: exerciseInstanceID,
                    with: replacement,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Replaced the exercise with \(replacement)."
            )
        case .requireAllOptions(let choice, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.requireAllOptions(choiceNamed: choice, expectedRevisionToken: expectedRevisionToken),
                success: "Changed \(choice) from a choice to one required sequence."
            )
        case .removeExercise(let exerciseInstanceID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.removeExercise(
                    exerciseInstanceID: exerciseInstanceID,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Removed the exercise."
            )
        case .reorderExercise(let exerciseInstanceID, let toIndex, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.reorderExercise(
                    exerciseInstanceID: exerciseInstanceID,
                    toIndex: toIndex,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Reordered the exercise."
            )
        case .duplicateExercise(let exerciseInstanceID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.duplicateExercise(
                    exerciseInstanceID: exerciseInstanceID,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Duplicated the exercise."
            )
        case .addSet(
            let exerciseInstanceID,
            let afterSetID,
            let values,
            let role,
            let targets,
            let expectedRevisionToken
        ):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.addSet(
                    exerciseInstanceID: exerciseInstanceID,
                    afterSetID: afterSetID,
                    values: values,
                    role: role,
                    targets: targets,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Added a planned set."
            )
        case .updateSet(let setID, let patch, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.updateSet(
                    setID: setID,
                    patch: patch,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Updated the planned set."
            )
        case .removeSet(let setID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.removeSet(setID: setID, expectedRevisionToken: expectedRevisionToken),
                success: "Removed the planned set."
            )
        case .moveSet(let setID, let beforeSetID, let toIndex, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.moveSet(
                    setID: setID,
                    beforeSetID: beforeSetID,
                    toIndex: toIndex,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Moved the planned set."
            )
        case .duplicateSet(let setID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.duplicateSet(setID: setID, expectedRevisionToken: expectedRevisionToken),
                success: "Duplicated the planned set."
            )
        case .updateGroup(let groupID, let patch, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.updateGroup(
                    groupID: groupID,
                    patch: patch,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Updated the group."
            )
        case .updateChoice(let choiceID, let label, let selectionCount, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.updateChoice(
                    choiceID: choiceID,
                    label: label,
                    selectionCount: selectionCount,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Updated the choice."
            )
        case .convertChoiceToGroup(let choiceID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.convertChoiceToGroup(
                    choiceID: choiceID,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Converted the choice into one required sequence."
            )
        case .updateRest(let restID, let patch, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.updateRest(
                    restID: restID,
                    patch: patch,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Updated the rest."
            )
        case .addRest(
            let parentID,
            let atIndex,
            let durationSeconds,
            let placement,
            let label,
            let guidance,
            let expectedRevisionToken
        ):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.addRest(
                    parentID: parentID,
                    atIndex: atIndex,
                    durationSeconds: durationSeconds,
                    placement: placement,
                    label: label,
                    guidance: guidance,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Added the rest."
            )
        case .moveNode(let nodeID, let toParentID, let toIndex, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.moveNode(
                    nodeID: nodeID,
                    toParentID: toParentID,
                    toIndex: toIndex,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Moved the workout node."
            )
        case .removeNode(let nodeID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.removeNode(nodeID: nodeID, expectedRevisionToken: expectedRevisionToken),
                success: "Removed the workout node."
            )
        case .addSetAlternative(let setID, let label, let values, let ranges, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.addSetAlternative(
                    setID: setID,
                    label: label,
                    values: values,
                    ranges: ranges,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Added the set alternative."
            )
        case .updateSetAlternative(let alternativeID, let patch, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.updateSetAlternative(
                    alternativeID: alternativeID,
                    patch: patch,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Updated the set alternative."
            )
        case .removeSetAlternative(let alternativeID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.removeSetAlternative(
                    alternativeID: alternativeID,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Removed the set alternative."
            )
        case .updateExercisePrescription(let exerciseInstanceID, let patch, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.updateExercisePrescription(
                    exerciseInstanceID: exerciseInstanceID,
                    patch: patch,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Updated the exercise's prescription."
            )
        case .applyWorkoutEdits(let operations, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.applyWorkoutEdits(
                    operations: operations,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Applied all \(operations.count) edit\(operations.count == 1 ? "" : "s") as one atomic mutation."
            )
        case .convertWorkoutUnits(let units, let selector, let dryRun, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return bulkOutcome(
                workouts.convertWorkoutUnits(
                    units: units,
                    selector: selector,
                    dryRun: dryRun,
                    expectedRevisionToken: expectedRevisionToken
                )
            )
        case .bulkReplaceExercises(let selector, let replacementDefinitionID, let dryRun, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return bulkOutcome(
                workouts.bulkReplaceExercises(
                    selector: selector,
                    replacementDefinitionID: replacementDefinitionID,
                    dryRun: dryRun,
                    expectedRevisionToken: expectedRevisionToken
                )
            )
        case .createCustomExercise(let draft, let proposalID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            switch workouts.createCustomExercise(
                draft: draft,
                proposalID: proposalID,
                expectedRevisionToken: expectedRevisionToken
            ) {
            case .proposal(let text), .existing(let text):
                return Response(text: text, decision: nil, plan: nil)
            case .created(let receipt, let text):
                return workoutResponse(prefix: text, receipt: receipt)
            case .rejected(let message):
                return Response(text: message, decision: nil, plan: nil)
            }
        case .undoWorkoutMutation(let mutationID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.undoMutation(
                    mutationID: mutationID,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Undid that workout edit."
            )
        case .getCurrentWorkout:
            guard workouts != nil else { return workoutUnavailable() }
            return Response(text: currentWorkoutSummary ?? "No workout has been created yet.", decision: nil, plan: nil)
        case .getActiveSession:
            guard let workouts else { return workoutUnavailable() }
            guard let snapshot = activeSessionText(workouts) else {
                return Response(
                    text: "There isn't an active workout session. Start the workout before logging performed sets.",
                    decision: nil,
                    plan: nil
                )
            }
            return Response(text: snapshot, decision: nil, plan: nil)
        case .upsertPerformedSet(
            let exerciseInstanceID,
            let plannedSetID,
            let groupID,
            let iteration,
            let values,
            let expectedRevisionToken
        ):
            guard let workouts else { return workoutUnavailable() }
            return sessionOutcome(
                workouts.upsertPerformedSet(
                    exerciseInstanceID: exerciseInstanceID,
                    plannedSetID: plannedSetID,
                    groupID: groupID,
                    iteration: iteration,
                    values: values,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Logged the performed-set values."
            )
        case .setPerformedSetOutcome(let target, let outcome, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return sessionOutcome(
                workouts.setPerformedSetOutcome(
                    target: target,
                    outcome: outcome,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Marked the performed set \(outcome.rawValue)."
            )
        case .addExtraPerformedSet(
            let exerciseInstanceID,
            let groupID,
            let iteration,
            let values,
            let expectedRevisionToken
        ):
            guard let workouts else { return workoutUnavailable() }
            return sessionOutcome(
                workouts.addExtraPerformedSet(
                    exerciseInstanceID: exerciseInstanceID,
                    groupID: groupID,
                    iteration: iteration,
                    values: values,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Added the extra performed set."
            )
        case .updateExtraPerformedSet(let performedSetID, let values, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return sessionOutcome(
                workouts.updateExtraPerformedSet(
                    performedSetID: performedSetID,
                    values: values,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Updated the extra performed set."
            )
        case .deleteExtraPerformedSet(let performedSetID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return sessionOutcome(
                workouts.deleteExtraPerformedSet(
                    performedSetID: performedSetID,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Deleted the extra performed set."
            )
        case .addExerciseSessionNote(let exerciseInstanceID, let note, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return sessionOutcome(
                workouts.addExerciseSessionNote(
                    exerciseInstanceID: exerciseInstanceID,
                    note: note,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Added the exercise session note."
            )
        case .undoSessionMutation(let mutationID, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return sessionOutcome(
                workouts.undoSessionMutation(
                    mutationID: mutationID,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Undid that session edit."
            )
        case .startWorkout:
            guard let workouts else { return workoutUnavailable() }
            guard currentWorkout != nil else {
                return Response(text: "There's no workout built yet, so there's nothing to start — want me to create one?", decision: nil, plan: nil)
            }
            // Safe to begin immediately: workout exists and no session is active. Idempotent if it is.
            if workouts.activeSessionID != nil {
                return Response(text: "That workout is already in progress — logging is live. (session \(workouts.activeSessionID!.uuidString))", decision: nil, plan: nil)
            }
            workouts.startWorkout()
            let sid = workouts.activeSessionID?.uuidString ?? "—"
            return Response(text: "Started the workout — logging is live and the sets are ready to check off. (session \(sid))", decision: nil, plan: nil)
        case .completeWorkout(let confirm):
            guard let workouts else { return workoutUnavailable() }
            guard currentWorkout != nil else {
                return Response(text: "There's no workout to finish yet.", decision: nil, plan: nil)
            }
            // Never finalize a workout that was never started, or one with open sets, without a
            // deliberate confirm — completion is one-way for the session's status.
            guard workouts.activeSessionID != nil else {
                // No live session covers two different situations, and telling a workout the athlete
                // just finished that it was never started is simply wrong.
                if workouts.currentLog?.isComplete == true {
                    return Response(text: "That workout is already complete. Want me to start it again?", decision: nil, plan: nil)
                }
                return Response(text: "That workout hasn't been started, so there's nothing to complete yet. Want me to start it?", decision: nil, plan: nil)
            }
            let open = workouts.incompleteWork()
            if open.sets > 0 && !confirm {
                let s = open.sets == 1 ? "set" : "sets"
                let e = open.exercises == 1 ? "exercise" : "exercises"
                return Response(text: "You still have \(open.sets) unlogged \(s) across \(open.exercises) \(e). Want me to finish the workout anyway?", decision: nil, plan: nil)
            }
            // Finishing through the agent shows no promotion prompt, so the decision is settled here.
            //
            // Known Phase-1 limitation (tracked follow-up): this path bypasses
            // `WorkoutFinishCoordinator.finish(_:heartRate:)`, so it does not capture the live
            // heart-rate trace — finishing through the coach while a strap is streaming loses the
            // trace and its summary. The recorder and monitor are owned by `WorkoutView` today; the
            // fix is to route this path through the same capture step once that ownership moves.
            workouts.completeWorkout(awaitingReconciliationDecision: false)
            return Response(text: "Marked the workout complete — nice work.", decision: nil, plan: nil)
        case .getWeekPlan:
            guard let plan else { return workoutUnavailable() }
            return Response(text: weekPlanSummary(plan), decision: nil, plan: nil)
        case .moveWorkout(let workout, let toDay):
            return resolvePlan(workout) { sw, plan in
                guard let date = self.dayDate(toDay, plan) else { return Response(text: "I couldn't tell which day \"\(toDay)\" is.", decision: nil, plan: nil) }
                return self.planOutcome(plan.move(sw.id, toDate: date), verb: "Moved \(sw.workout.title) to \(self.dayLabel(date)).")
            }
        case .swapWorkouts(let a, let b):
            guard let plan else { return workoutUnavailable() }
            switch (resolveScheduled(a, plan), resolveScheduled(b, plan)) {
            case (.one(let x), .one(let y)): return planOutcome(plan.swap(x, y), verb: "Swapped \(a) and \(b).")
            case (.many(let m), _): return Response(text: ambiguityText(a, m), decision: nil, plan: nil)
            case (_, .many(let m)): return Response(text: ambiguityText(b, m), decision: nil, plan: nil)
            default: return Response(text: "I couldn't find both of those in this week.", decision: nil, plan: nil)
            }
        case .skipWorkout(let workout, let skipped):
            return resolvePlan(workout) { sw, plan in
                self.planOutcome(plan.setSkipped(sw.id, skipped), verb: "\(skipped ? "Skipped" : "Unskipped") \(sw.workout.title).")
            }
        case .duplicateWorkout(let workout, let toDay):
            return resolvePlan(workout) { sw, plan in
                let date = toDay.flatMap { self.dayDate($0, plan) }
                return self.planOutcome(plan.duplicate(sw.id, toDate: date), verb: "Duplicated \(sw.workout.title)\(date.map { " to \(self.dayLabel($0))" } ?? "").")
            }
        case .deleteWorkout(let workout, let proposalID):
            return resolvePlan(workout) { sw, plan in
                let result = plan.delete(sw.id, proposalID: proposalID.flatMap(UUID.init(uuidString:)))
                switch result {
                case .applied: return Response(text: "Deleted \(sw.workout.title). You can undo it on the Plan tab.", decision: nil, plan: nil)
                case .confirmationRequired(let warnings, _, let pid):
                    return Response(text: "\(warnings.first?.message ?? "This is destructive.") To confirm, call delete_workout again with proposal_id \"\(pid.uuidString)\".", decision: nil, plan: nil)
                case .rejected: return Response(text: "I couldn't delete that.", decision: nil, plan: nil)
                }
            }
        case .explainModification(let workout):
            return resolvePlan(workout) { sw, plan in
                Response(text: self.explainModification(sw, plan), decision: nil, plan: nil)
            }
        case .saveAsTemplate(let name):
            guard let plan else { return workoutUnavailable() }
            // The same scoped resolution every other tool uses. After a decline that means the plan:
            // the athlete just rejected that session shape, so persisting it as a reusable template —
            // which would then instantiate into every future workout built from it — would contradict
            // the choice they made.
            guard let w = currentWorkout else { return Response(text: "There's no workout to save as a template yet.", decision: nil, plan: nil) }
            if plan.template(named: name) != nil {
                return Response(text: "A template named \"\(name)\" already exists. Say \"update it\" to replace it, or give me a different name.", decision: nil, plan: nil)
            }
            _ = plan.saveAsTemplate(name: name, from: w)
            return Response(text: "Saved \(name) as a template — you can reuse it any day.", decision: nil, plan: nil)
        case .updateTemplate(let name):
            guard let plan else { return workoutUnavailable() }
            guard let w = currentWorkout else { return Response(text: "There's no workout to update the template from.", decision: nil, plan: nil) }
            let matches = matchTemplates(name, plan)
            switch matches.count {
            case 0: return Response(text: "I don't have a template called \"\(name)\".", decision: nil, plan: nil)
            case 1: _ = plan.updateTemplate(matches[0].id, from: w); return Response(text: "Updated the \(matches[0].name) template from this workout. Already-scheduled ones stay as they are.", decision: nil, plan: nil)
            default: return Response(text: templateAmbiguity(name, matches), decision: nil, plan: nil)
            }
        case .createFromTemplate(let name, let day):
            guard let plan else { return workoutUnavailable() }
            let matches = matchTemplates(name, plan)
            switch matches.count {
            case 0: return Response(text: "I don't have a template called \"\(name)\".", decision: nil, plan: nil)
            case 1:
                guard let date = dayDate(day, plan) else { return Response(text: "I couldn't tell which day \"\(day)\" is.", decision: nil, plan: nil) }
                guard let sw = plan.instantiateTemplate(matches[0].id, on: date) else { return Response(text: "I couldn't build that workout.", decision: nil, plan: nil) }
                return Response(text: "Added \(sw.workout.title) on \(dayLabel(date)) from the \(matches[0].name) template.", decision: nil, plan: nil)
            default: return Response(text: templateAmbiguity(name, matches), decision: nil, plan: nil)
            }
        case .updateLoggingConfig(let exerciseInstanceID, let enabled, let units, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.setLoggingConfig(
                    exerciseInstanceID: exerciseInstanceID,
                    enabled: enabled,
                    units: units,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Updated the exercise logging configuration."
            )
        case .updateExercisePreference(let ex, let scope, let units, let selected):
            guard let workouts else { return workoutUnavailable() }
            let r = workouts.setExercisePreference(exerciseNamed: ex, scope: scope, units: units, selected: selected)
            if case .done = r {
                return Response(text: "Saved that as your \(scope == .category ? "category" : "default") preference for \(ex) — it applies to future \(ex) instances, not today's.", decision: nil, plan: nil)
            }
            return outcome(r, success: "")
        case .setMetricValue(let exerciseInstanceID, let setID, let metric, let value, let unit, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.setMetricValue(
                    exerciseInstanceID: exerciseInstanceID,
                    setID: setID,
                    metric: metric,
                    value: value,
                    unit: unit,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Set \(metric.label.lowercased()) on the planned set."
            )
        case .removeMetric(let exerciseInstanceID, let metric, let expectedRevisionToken):
            guard let workouts else { return workoutUnavailable() }
            return outcome(
                workouts.removeMetric(
                    exerciseInstanceID: exerciseInstanceID,
                    metric: metric,
                    expectedRevisionToken: expectedRevisionToken
                ),
                success: "Removed \(metric.label.lowercased()) from the exercise."
            )
        case .searchExercises(let query, let muscle, let equipment, let modality, let pattern, let tag, let level):
            switch ExerciseSearch.parse(text: query, muscle: muscle, equipment: equipment, modality: modality,
                                        pattern: pattern, tag: tag, level: level) {
            case .failure(let bad):
                return Response(text: "\"\(bad.value)\" isn't a \(bad.field) Baseline knows. Valid \(bad.field) values: \(bad.valid.joined(separator: ", ")). Search again with one of those, or use the query parameter for free text.",
                                decision: nil, plan: nil)
            case .success(let q):
                let results = catalogWithCustoms.map { ExerciseSearch.run(q, in: $0) } ?? ExerciseCatalog.search(q)
                return Response(text: searchSummary(results, q), decision: nil, plan: nil)
            }
        case .getExercise(let name, let id):
            guard let asked = name ?? id else {
                return Response(text: "get_exercise needs either a name or an id - it was called with neither. Pass the exercise's name, or the id from a search_exercises row.", decision: nil, plan: nil)
            }
            let def = catalogWithCustoms.map { ExerciseSearch.lookUp(name: name, id: id, in: $0) }
                ?? ExerciseCatalog.lookUp(name: name, id: id)
            guard let def else {
                return Response(text: "\"\(asked)\" isn't in Baseline's exercise catalog. Try search_exercises to find the closest real movement - don't invent one.", decision: nil, plan: nil)
            }
            return Response(text: exerciseDetail(def), decision: nil, plan: nil)
        case .getSleep, .getHRVReadings, .getRestingHeartRate:
            // Retrieval is async — routed through `execute`, never here.
            return Response(text: "", decision: nil, plan: nil)
        }
    }

    // MARK: - Exercise catalog retrieval - compact rows; the model reads every one of these

    private func searchSummary(_ r: ExerciseSearch.Results, _ q: ExerciseSearch.Query) -> String {
        guard !r.matches.isEmpty else {
            return "No exercises in Baseline's catalog match \(describe(q)). The catalog is broad (\(ExerciseCatalog.definitions.count) movements) - try a looser query or drop a filter."
        }
        let header: String
        if r.isBrowseSample {
            header = "Baseline's exercise catalog holds \(r.total) exercises. A representative sample across the library (\(r.matches.count) of \(r.total)) - search by name, muscle, equipment, pattern, tag, or level to narrow it:"
        } else if r.truncated {
            header = "\(r.total) exercises match \(describe(q)). Showing the \(r.matches.count) best - say there are \(r.total) in total, don't imply these are all of them:"
        } else {
            let word = r.total == 1 ? "exercise matches" : "exercises match"
            header = "\(r.total) \(word) \(describe(q)):"
        }
        return ([header] + r.matches.map(compactRow)).joined(separator: "\n")
    }

    /// The athlete's own catalog view: custom definitions ahead of the curated library, matching
    /// `WorkoutStore.resolveDefinition`'s custom-first rule, so a movement created with
    /// create_custom_exercise is immediately searchable and retrievable. Nil while the athlete has
    /// no customs - the shared curated snapshot already answers, index-free of rebuild cost.
    private var catalogWithCustoms: ExerciseCatalogSnapshot? {
        guard let customs = workouts?.customDefinitions, !customs.isEmpty else { return nil }
        return ExerciseCatalogSnapshot(customs + ExerciseCatalog.definitions)
    }

    /// One match, compact: identity + the axes that let the model pick between near-duplicates.
    private func compactRow(_ d: ExerciseDefinition) -> String {
        var fields = [d.id, d.name]
        fields.append(d.primaryMuscles.isEmpty ? "-" : d.primaryMuscles.map(\.displayName).joined(separator: ", "))
        fields.append(d.equipment.isEmpty ? "-" : d.equipment.map(\.displayName).joined(separator: ", "))
        fields.append(d.modality?.displayName ?? "-")
        if d.id.hasPrefix("custom_") { fields.append("custom") }
        return "- " + fields.joined(separator: " · ")
    }

    private func exerciseDetail(_ d: ExerciseDefinition) -> String {
        func list(_ xs: [String]) -> String { xs.isEmpty ? "none" : xs.joined(separator: ", ") }
        var lines = ["\(d.name) (id \(d.id))\(d.id.hasPrefix("custom_") ? " - custom, athlete-created" : "")"]
        lines.append("Primary muscles: \(list(d.primaryMuscles.map(\.displayName)))")
        lines.append("Secondary muscles: \(list(d.secondaryMuscles.map(\.displayName)))")
        lines.append("Equipment: \(list(d.equipment.map(\.displayName)))")
        lines.append("Movement pattern: \(list(d.patterns.map(\.displayName)))")
        lines.append("Modality: \(d.modality?.displayName ?? "unclassified"); mechanic: \(d.mechanic?.displayName ?? "unclassified"); level: \(d.level?.displayName ?? "unclassified")")
        lines.append("Tags: \(list(d.tags.map(\.displayName)))")
        // Metric raw values, not display names - these are what the metric tools take.
        lines.append("Logs: \(list(d.supported.map(\.rawValue))) (defaults: \(list(d.defaults.map(\.rawValue))))")
        return lines.joined(separator: "\n")
    }

    /// Echo the query back so the model states what it actually searched, not what it meant to.
    private func describe(_ q: ExerciseSearch.Query) -> String {
        var parts: [String] = []
        if let t = q.text { parts.append("\"\(t)\"") }
        if let m = q.muscle { parts.append("muscle \(m.displayName)") }
        if let e = q.equipment { parts.append("equipment \(e.displayName)") }
        if let m = q.modality { parts.append("modality \(m.displayName)") }
        if let p = q.pattern { parts.append("pattern \(p.displayName)") }
        if let t = q.tag { parts.append("tag \(t.displayName)") }
        if let l = q.level { parts.append("level \(l.displayName)") }
        return parts.isEmpty ? "your search" : parts.joined(separator: " + ")
    }

    private func workoutUnavailable() -> Response {
        Response(text: "Workout editing isn't available in this context.", decision: nil, plan: nil)
    }

    // MARK: - Plan (week-level) helpers — resolve by name, route to the versioned repository ops

    private enum PlanMatch { case none; case one(UUID); case many([ScheduledWorkout]) }

    private func resolveScheduled(_ name: String, _ plan: PlanStore) -> PlanMatch {
        let all = plan.week.days.flatMap(\.sessions)
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        let exact = all.filter { $0.workout.title.lowercased() == n }
        let hits = exact.isEmpty ? all.filter { $0.workout.title.lowercased().contains(n) } : exact
        switch hits.count { case 0: return .none; case 1: return .one(hits[0].id); default: return .many(hits) }
    }

    /// Resolve a workout by name in the current week; ambiguity-aware (asks which one, never guesses).
    private func resolvePlan(_ name: String, _ body: (ScheduledWorkout, PlanStore) -> Response) -> Response {
        guard let plan else { return workoutUnavailable() }
        switch resolveScheduled(name, plan) {
        case .none: return Response(text: "I couldn't find \"\(name)\" in this week's plan.", decision: nil, plan: nil)
        case .many(let m): return Response(text: ambiguityText(name, m), decision: nil, plan: nil)
        case .one(let id):
            guard let sw = plan.scheduledWorkout(id) else { return Response(text: "I couldn't load \"\(name)\".", decision: nil, plan: nil) }
            return body(sw, plan)
        }
    }

    private func ambiguityText(_ name: String, _ m: [ScheduledWorkout]) -> String {
        "There's more than one \"\(name)\" this week: " + m.map { "\($0.workout.title) on \(dayLabel($0.date))" }.joined(separator: ", ") + ". Which one?"
    }

    private func planOutcome(_ r: MutationResult, verb: String) -> Response {
        switch r {
        case .applied: return Response(text: verb, decision: nil, plan: nil)
        case .confirmationRequired(let w, _, _): return Response(text: w.first?.message ?? "That needs confirmation.", decision: nil, plan: nil)
        case .rejected(.activeSessionConflict): return Response(text: "That workout is in progress — finish or discard the session before reshuffling it.", decision: nil, plan: nil)
        case .rejected: return Response(text: "I couldn't make that change.", decision: nil, plan: nil)
        }
    }

    /// Map a day token (weekday name, or `yyyy-MM-dd`) to a date in the current plan week.
    private func dayDate(_ token: String, _ plan: PlanStore) -> Date? {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        for d in plan.week.days.map(\.date) {
            let wide = d.formatted(.dateTime.weekday(.wide)).lowercased()
            let abbr = d.formatted(.dateTime.weekday(.abbreviated)).lowercased()
            if t == wide || t == abbr || (t.count >= 3 && wide.hasPrefix(t)) { return d }
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: t).map { Calendar.planWeek.startOfDay(for: $0) }
    }

    private func dayLabel(_ d: Date) -> String { d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }

    private func statusWord(_ s: ScheduleStatus) -> String {
        switch s {
        case .today: "today"; case .inProgress: "in progress"; case .paused: "paused"; case .completed: "completed"
        case .skipped: "skipped"; case .missed: "missed"; case .planned: "planned"; case .modifiedIntent: "modified"
        }
    }

    private func matchTemplates(_ name: String, _ plan: PlanStore) -> [WorkoutTemplate] {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        let all = plan.templates()
        let exact = all.filter { $0.name.lowercased() == n }
        return exact.isEmpty ? all.filter { $0.name.lowercased().contains(n) } : exact
    }
    private func templateAmbiguity(_ name: String, _ m: [WorkoutTemplate]) -> String {
        "There's more than one template matching \"\(name)\": " + m.map(\.name).joined(separator: ", ") + ". Which one?"
    }

    private func weekPlanSummary(_ plan: PlanStore) -> String {
        var lines = ["This week's plan (\(plan.week.startDate.formatted(.dateTime.month().day())) start):"]
        for day in plan.week.days where !day.sessions.isEmpty {
            let items = day.sessions.map { "\($0.workout.title) (\(statusWord(plan.status(for: $0, today: Date()))))" }.joined(separator: ", ")
            lines.append("- \(day.date.formatted(.dateTime.weekday(.wide))): \(items)")
        }
        if lines.count == 1 { lines.append("- nothing scheduled yet") }
        return lines.joined(separator: "\n")
    }

    /// Honest rationale: today's status from the engine (as-planned in v1 unless a real diff exists),
    /// past/future from execution state and version history — never invented.
    private func explainModification(_ sw: ScheduledWorkout, _ plan: PlanStore) -> String {
        let title = sw.workout.title
        switch plan.status(for: sw, today: Date()) {
        case .today(.asPlanned): return "\(title) is set as planned for today — no modification."
        case .today(.modified(let reasons)): return "\(title) was modified today: \(reasons.joined(separator: ", "))."
        case .today(.constraintActive): return "\(title) reflects an active constraint today."
        case .today(.swapSuggested): return "\(title) has a suggested swap today."
        case .today(.reducedVolume(let p)): return "\(title) has reduced volume today\(p.map { " (−\($0)%)" } ?? "")."
        case .completed: return "\(title) is completed."
        case .inProgress, .paused: return "\(title) is in progress."
        case .skipped: return "\(title) was skipped."
        case .missed: return "\(title) was missed."
        case .planned: return "\(title) is planned as-is; nothing's been changed."
        case .modifiedIntent(let a): return "\(title) was changed by \(a.rawValue)."
        }
    }

    /// Turn a name-resolved edit into a reply: on success echo the refreshed workout; on not-found
    /// or ambiguity, hand the model the message so it asks the athlete which one (never guesses).
    private func outcome(_ o: WorkoutStore.EditOutcome, success: String) -> Response {
        switch o {
        case .done: return workoutResponse(prefix: success)
        case .mutated(let receipt): return workoutResponse(prefix: success, receipt: receipt)
        case .notFound(let m), .ambiguous(let m): return Response(text: m, decision: nil, plan: nil)
        }
    }

    /// A bulk mutation's reply carries its own enumeration of exactly what matched: an applied bulk
    /// edit echoes the receipt plus the refreshed workout, a dry run reports the matched set and
    /// changes nothing, and a rejection hands the model the correctable message.
    private func bulkOutcome(_ result: WorkoutStore.BulkMutationOutcome) -> Response {
        switch result {
        case .applied(let receipt, let detail):
            return workoutResponse(prefix: detail, receipt: receipt)
        case .preview(let detail):
            return Response(text: detail, decision: nil, plan: nil)
        case .rejected(let message):
            return Response(text: message, decision: nil, plan: nil)
        }
    }

    // MARK: - The one resolution every workout tool uses

    /// "The current workout", resolved once through the store's scope. Every agent-facing read, write,
    /// and echo goes through these, so no tool can hold a private notion of which workout it means —
    /// the read source and the write source are the same lookup, not two that usually agree.
    private var currentWorkout: Workout? { workouts.map { $0.workout($0.agentScope) } ?? nil }
    private var currentWorkoutSummary: String? { workouts.map { $0.summary($0.agentScope) } }
    private var currentWorkoutIndex: String? { workouts.flatMap { $0.compactSummary($0.agentScope) } }

    /// After a workout edit, hand the model the refreshed structure so its reply reflects the truth.
    private func workoutResponse(prefix: String, receipt: WorkoutMutationReceipt? = nil) -> Response {
        let receiptText = receipt.flatMap { value -> String? in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value) else { return nil }
            return "MUTATION RECEIPT: " + String(decoding: data, as: UTF8.self)
        }
        let text = [prefix, receiptText, currentWorkoutSummary].compactMap { $0 }.joined(separator: "\n")
        return Response(text: text, decision: nil, plan: nil, mutationReceipt: receipt, userFacingText: prefix)
    }

    private func sessionOutcome(_ outcome: WorkoutStore.EditOutcome, success: String) -> Response {
        switch outcome {
        case .done:
            return sessionResponse(prefix: success)
        case .mutated(let receipt):
            return sessionResponse(prefix: success, receipt: receipt)
        case .notFound(let message), .ambiguous(let message):
            return Response(text: message, decision: nil, plan: nil)
        }
    }

    private func sessionResponse(prefix: String, receipt: WorkoutMutationReceipt? = nil) -> Response {
        let receiptText = receipt.flatMap { value -> String? in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value) else { return nil }
            return "MUTATION RECEIPT: " + String(decoding: data, as: UTF8.self)
        }
        let snapshot = workouts.flatMap(activeSessionText)
        let text = [prefix, receiptText, snapshot].compactMap { $0 }.joined(separator: "\n")
        return Response(
            text: text,
            decision: nil,
            plan: nil,
            mutationReceipt: receipt,
            userFacingText: prefix
        )
    }

    private func activeSessionText(_ workouts: WorkoutStore) -> String? {
        guard let snapshot = workouts.activeSessionSnapshot() else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return "ACTIVE SESSION: " + String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helpers

    private func today() -> (DecisionEngine.Result, PlanningEngine.Plan) {
        store.rolloverIfNeeded()   // never plan today off yesterday's context
        return PlanAssembler.assemble(base: base, dailyContext: store.daily, constraints: store.activeConstraints, style: style)
    }

    /// The model's **memory**: today's plan plus the durable structured state that persists across
    /// conversations (constraints + logged context). The raw transcript resets each session by
    /// design — this is what makes a fresh conversation still know the athlete. Sent as the system
    /// context on every request.
    func contextSummary() -> String {
        let (d, p) = today()
        var lines = [planLine(d, p)]

        let constraints = store.activeConstraintRecords
        if !constraints.isEmpty {
            let list = constraints.map {
                "\($0.location) (\($0.kind.rawValue), severity \($0.severity)/3\($0.affectsTraining ? "" : ", not limiting training")) [id \($0.id.uuidString)]"
            }.joined(separator: "; ")
            lines.append("Active constraints (persist until resolved — to change or clear one, pass its id; don't create a duplicate): \(list).")
        }

        let dc = store.daily
        var ctx: [String] = []
        if let s = dc.sleepHours { ctx.append("slept \(String(format: "%g", s))h") }
        if let e = dc.energy { ctx.append("energy \(Int(e))/5") }
        if let m = dc.mood { ctx.append("mood \(Int(m))/5") }
        if let s = dc.stress { ctx.append("stress \(Int(s))/5") }
        if let so = dc.soreness { ctx.append("soreness \(Int(so))/5") }
        if let t = dc.timeAvailableMinutes { ctx.append("\(t) min available") }
        if let eq = dc.equipment, !eq.isEmpty { ctx.append("equipment: \(eq.joined(separator: ", "))") }
        if dc.traveling == true { ctx.append("traveling") }
        if dc.illness == true { ctx.append("feeling unwell") }
        if let n = dc.note, !n.isEmpty { ctx.append("note: \(n)") }
        if !ctx.isEmpty { lines.append("Logged for today: \(ctx.joined(separator: "; ")).") }

        if constraints.isEmpty && ctx.isEmpty {
            lines.append("Nothing else has been recorded yet — no injuries, sleep, check-in, or context on file.")
        }

        // A compact INDEX of the current workout — enough to know it exists and its status, never the
        // full exercise/set detail (that would inflate every request). Detail is fetched on demand via
        // get_current_workout. Never deny a workout the index shows.
        if let compact = currentWorkoutIndex {
            lines.append("Current workout (call get_current_workout for its exercises/sets; never answer content from memory):\n\(compact)\nTo begin it call start_workout; to finish it call complete_workout.")
        } else {
            lines.append("No workout has been built yet. If the athlete wants one, use create_workout (or build it up with add_block/add_exercise).")
        }

        lines.append(unitSystemLine())
        lines.append(capabilityLine())
        lines.append(retrievableLine())
        return lines.joined(separator: "\n")
    }

    /// The athlete's unit system, stated outright. Without it the model's only frame is the canonical
    /// storage units the prompt describes, so it narrates kg and metres to an imperial athlete even
    /// while the screens beside it read lb and miles. Distance is stated as the two cases it really
    /// has, because "distances in miles" would have the coach call a 20 m sled push 0.01 mi.
    private func unitSystemLine() -> String {
        let system = workouts?.unitSystem ?? .metric
        let load = system.displayUnit(metric: .load, exercise: nil).short
        let endurance = system.displayUnit(metric: .distance, exercise: nil).short
        let pace = system.displayUnit(metric: .pace, exercise: nil).short
        return "Units: the athlete uses \(system.rawValue) — write loads in \(load), running/riding/rowing "
            + "distances in \(endurance), and pace as minutes\(pace). Sled, carry and strength distances read in "
            + "meters for everyone. A specific exercise may override any of these. Convert before you speak; "
            + "never quote a stored canonical value."
    }

    /// The honest menu of what the model can actually fetch on request — so it offers exactly these
    /// and never over-claims (e.g. promising resting-HR retrieval it has no tool for).
    private func retrievableLine() -> String {
        var items = ["recent HRV readings (get_hrv_readings)"]
        // Health-backed retrieval is only real once setup was requested — advertising it before then
        // would let the model claim "no sleep recorded" when the truth is "not connected".
        if let health, health.isAvailable, health.requested {
            items.insert("sleep for a recent night (get_sleep)", at: 0)
            items.append("resting heart-rate trend (get_resting_heart_rate)")
        }
        // The catalog is listed here too: this line is exhaustive ("nothing else"), so leaving it out
        // would tell the model it can't look up exercises at all.
        items.append("Baseline's \(ExerciseCatalog.definitions.count)-exercise catalog (search_exercises, get_exercise)")
        return "You can look these up when the athlete asks — nothing else: " + items.joined(separator: ", ") + "."
    }

    /// Live capability state, so the model answers "how do I…" from fact — not guesses — and knows
    /// which action tools it can invoke.
    private func capabilityLine() -> String {
        var caps: [String] = []
        if let health {
            if !health.isAvailable {
                caps.append("Apple Health not available on this device")
            } else if health.requested {
                caps.append("Apple Health access set up (Apple doesn't reveal read-grant status, so data may still be empty)")
            } else {
                caps.append("Apple Health supported but not set up — call open_apple_health_setup to connect it (imports sleep + resting HR, raises certainty)")
            }
        }
        caps.append("HRV reading supported via chest strap or phone camera\(hrvConfigured ? " (set up)" : " (not set up yet)") — a 2:30 morning reading on the Today screen adds autonomic evidence")
        return "Baseline capabilities right now: " + caps.joined(separator: "; ") + "."
    }

    private func respond(prefix: String?) -> Response {
        let (d, p) = today()
        let text = [prefix, planLine(d, p)].compactMap { $0 }.joined(separator: " ")
        return Response(text: text, decision: d, plan: p)
    }

    /// Tier-aware so the model never receives a score it hasn't earned — the same honesty the Today
    /// screen enforces. No evidence → say so and gather; partial → plan without a number; established
    /// → the full readiness number.
    private func planLine(_ d: DecisionEngine.Result, _ p: PlanningEngine.Plan) -> String {
        switch d.evidenceTier {
        case .none:
            return "Not enough evidence yet for a real readiness. Gather something about today — sleep, how they feel, an HRV reading, or any injury/constraint — before stating a plan or a score."
        case .partial:
            return "Plan: \(p.summary) (certainty \(d.certainty.rawValue); no readiness number yet — evidence is still thin, don't invent one)."
        case .established:
            return "Plan: \(p.summary) (readiness \(d.score), \(d.band.rawValue); certainty \(d.certainty.rawValue))."
        }
    }

    private func explanation(_ d: DecisionEngine.Result, _ p: PlanningEngine.Plan) -> String {
        guard d.evidenceTier != .none else { return planLine(d, p) }
        var s = planLine(d, p)
        if let lim = d.primaryLimiter { s += " Main limiter: \(lim.title.lowercased())." }
        if !p.why.isEmpty { s += " Why: " + p.why.joined(separator: " ") }
        if !p.avoid.isEmpty { s += " Avoid: " + p.avoid.joined(separator: ", ") + "." }
        return s
    }
}
