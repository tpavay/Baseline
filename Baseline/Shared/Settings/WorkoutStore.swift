import Foundation
import Observation

/// Where a content edit is written.
///
/// Every caller states this, because inferring it from ambient lifecycle state is exactly what let
/// session edits leak into the saved plan: any inferred signal has a window in which it is wrong.
/// The two destinations cannot reach each other — `.session` never writes a plan revision, and
/// `.plan` never writes the session copy.
enum WorkoutEditScope {
    /// The saved plan revision. Coalesced when the binding asked for it, and flushed on dismiss.
    case plan
    /// The session's own copy of the workout. Never coalesced — an abandoned or force-quit session must
    /// still reload with its edits intact — and it reaches the plan only through
    /// `applySessionReconciliation`.
    case session
}

/// Holds the athlete's **current structured workout** and applies validated edits. The conversation's
/// plan-edit tools write here; the workout screen reads here. Local-first (UserDefaults JSON), same
/// pattern as `TrainingContextStore`.
///
/// The model speaks in *names* ("move bench to the warm-up block"); this resolves names → ids and
/// calls the id-based operations on `Workout` (which own the invariants + are unit-tested).
@MainActor
@Observable
final class WorkoutStore {
    /// What to **display**. Assigning it persists locally and nothing more: assignment can never
    /// promote content to the plan, which is what makes the session/plan boundary structural rather
    /// than a matter of some flag holding the right value at the right moment.
    private(set) var current: Workout? {
        didSet { persist(current, Self.key) }
    }

    /// The one buffered plan edit awaiting `flush()`. Only `edit(.plan)` on a coalescing binding fills
    /// it, so `flush` never has to ask what `current` happens to hold — during a live session the
    /// buffer is empty and sheet dismissal writes nothing to the plan by construction.
    private var pendingPlanEdit: Workout?

    /// The single lifecycle signal for callers that have no presentation mode of their own (the agent
    /// tools): a session exists whose reconciliation decision is unresolved.
    ///
    /// It is read from the session record **on demand**, never mirrored into a property here. The fact
    /// describes the session, and two stores are bound to the same scheduled workout at once — the Plan
    /// tab's execution store and the app-level agent store — so a copy held by whichever instance
    /// happened to call `startWorkout` would make the answer depend on which screen the athlete opened
    /// the chat from. It is also not derived: the repository writes it at explicit lifecycle moments.
    var hasUnresolvedSessionDecision: Bool { sink?.isSessionDecisionPending() ?? false }

    /// The scope of an operation arriving from the agent, which cannot state one of its own. It governs
    /// the agent's reads as well as its writes: the coach must describe the workout it is about to
    /// change, or it would confirm an edit while echoing content from somewhere else.
    var agentScope: WorkoutEditScope { hasUnresolvedSessionDecision ? .session : .plan }

    /// The in-progress performed log (actual sets, skips, notes) once a workout is started. Distinct
    /// from `current` (the plan) — logging never mutates the plan.
    private(set) var currentLog: WorkoutLog? {
        didSet {
            persist(currentLog, Self.logKey)
            if let sink, !isSyncing, let l = currentLog, l != oldValue { sink.pushLog(l) }
        }
    }
    /// The persisted start instant drives the live elapsed-time title and survives sheet dismissal.
    private(set) var currentLogStartedAt: Date? {
        didSet { persist(currentLogStartedAt, Self.logStartedAtKey) }
    }

    // MARK: - Plan binding (this store is the shared editing surface; a sink write-throughs to the repo)

    /// The write-through target when this store edits a Plan scheduled workout. Nil = standalone (legacy
    /// ad-hoc), which behaves exactly as before.
    struct PlanSink {
        let pushWorkout: (Workout) -> Void            // edit content → new immutable revision
        let pushSessionWorkout: (Workout) -> Void     // mid-workout edit → session copy only (no revision)
        let pushLog: (WorkoutLog) -> Void             // log a set → the session log
        let start: () -> Void                         // begin the session in the plan
        let complete: () -> Void                      // freeze the completed log
        let discard: () -> Void
        /// The session's own record of whether its promotion decision is still unanswered — one shared
        /// answer for every store bound to this scheduled workout.
        let isSessionDecisionPending: () -> Bool
        let resolveSessionDecision: () -> Void
        let resolveAbandonedSessionDecision: () -> Void
        let reload: () -> (workout: Workout, log: WorkoutLog?, startedAt: Date?)?
        let planWorkout: () -> Workout?               // the saved plan revision (for completion diffing)
    }
    private var sink: PlanSink?
    private var coalesceContent = false
    private var isSyncing = false                     // true while pulling from the plan → suppress push-back
    /// Set once at startup: makes a brand-new today scheduled workout in the plan (for the agent's
    /// create_workout when nothing is scheduled today) and returns a sink bound to it.
    var makeTodayScheduled: ((Workout) -> PlanSink?)?

    func bind(_ sink: PlanSink, coalesceContent: Bool) {
        pendingPlanEdit = nil
        self.sink = sink; self.coalesceContent = coalesceContent
        // A finished session whose prompt was never answered (the app was terminated between the two)
        // must not stay pending forever. Attaching a surface is where that is noticed; declining is the
        // safe resolution, and it writes nothing to the plan.
        sink.resolveAbandonedSessionDecision()
        reloadFromPlan()
    }
    func unbind() { sink = nil; coalesceContent = false; pendingPlanEdit = nil }

    /// Pull the authoritative workout + session back from the plan (suppressing log write-back).
    func reloadFromPlan() {
        guard let s = sink?.reload() else { return }
        pendingPlanEdit = nil
        isSyncing = true
        current = s.workout
        currentLog = s.log
        currentLogStartedAt = s.startedAt
        isSyncing = false
    }

    /// Push the buffered plan edit (the manual editor calls this on dismiss), then clear the buffer.
    ///
    /// It reads only the buffer, never `current`. That is the point: this is the silent path — it fires
    /// on sheet dismissal with no user intent behind it — and a session edit never fills the buffer, so
    /// there is structurally nothing session-shaped for it to promote.
    func flush() {
        guard let sink, let pending = pendingPlanEdit else { return }
        pendingPlanEdit = nil
        sink.pushWorkout(pending)
    }

    /// The workout a plan-scoped edit is built on: the saved plan revision, or the buffered edit still
    /// waiting to be flushed on top of it. Deliberately **not** `current` — `current` shows what the
    /// athlete performed, and a plan write that started from it would carry session content into the
    /// plan wholesale.
    ///
    /// A **bound** store never falls back: if the scheduled workout cannot be resolved (it was deleted),
    /// there is no plan to edit and the operation does nothing, rather than inventing a baseline out of
    /// whatever is on screen. Only an unbound store reads `current`, where the two are the same object.
    private var planBaseline: Workout? {
        if let pendingPlanEdit { return pendingPlanEdit }
        guard let sink else { return current }
        return sink.planWorkout()
    }

    /// The workout an operation of this scope reads **and** writes. One resolution serves both, so what
    /// the store describes and what it changes can never be two independent lookups that drift apart.
    /// A plan operation never even sees session content, so a leak is impossible by construction.
    func workout(_ scope: WorkoutEditScope) -> Workout? {
        switch scope {
        case .session: current
        case .plan: planBaseline
        }
    }

    /// Adopt an edited workout and write it to the destination the caller named. The payload travels
    /// with the write; nothing downstream re-reads `current` to decide what or where to push.
    ///
    /// Returns whether the write reached its destination, so no caller can confirm a change it did not
    /// make. A no-op because nothing actually changed still counts as reaching it.
    @discardableResult
    private func apply(_ workout: Workout, _ scope: WorkoutEditScope) -> Bool {
        switch scope {
        case .session: applySession(workout)
        case .plan: applyPlan(workout)
        }
    }

    @discardableResult
    private func applySession(_ workout: Workout) -> Bool {
        guard workout != current else { return true }
        current = workout
        sink?.pushSessionWorkout(workout)
        return true
    }

    @discardableResult
    private func applyPlan(_ workout: Workout) -> Bool {
        // A bound store with no resolvable plan revision has nothing to edit — the scheduled workout was
        // deleted. Say so rather than writing against an invented baseline.
        guard let base = planBaseline else { return false }
        guard workout != base else { return true }
        // The display follows a plan edit only when the display *was* the plan. While a session's shape
        // is on screen it keeps showing what was performed: the summary is the past, the plan is the
        // future, and rewriting the performed record to keep them in step would be the worse trade.
        if current == base { current = workout }
        guard let sink else { return true }
        if coalesceContent { pendingPlanEdit = workout } else { sink.pushWorkout(workout) }
        return true
    }

    /// User-level display/metric preferences, keyed by exercise identity and by category — applied to
    /// *future* instances, so "use miles for Stationary Bike from now on" doesn't touch today's.
    struct ExercisePreferences: Codable, Equatable, Sendable {
        var selectedByExercise: [String: [MetricType]] = [:]
        var unitsByExercise: [String: [MetricType: MetricUnit]] = [:]
        var unitsByCategory: [String: [MetricType: MetricUnit]] = [:]
    }
    enum PreferenceScope: String, Sendable { case exercise, category }

    private(set) var preferences: ExercisePreferences {
        didSet {
            persist(preferences, Self.prefKey)
            configurationSource?.preferences = preferences
        }
    }
    /// Athlete-created exercise definitions (deliberate — never auto-created from a typo).
    private(set) var customDefinitions: [ExerciseDefinition] {
        didSet {
            persist(customDefinitions, Self.customKey)
            configurationSource?.customDefinitions = customDefinitions
        }
    }
    /// Recently-added exercise ids, most-recent first — for the catalog picker's "Recent" section.
    private(set) var recentExerciseIds: [String] {
        didSet {
            persist(recentExerciseIds, Self.recentKey)
            configurationSource?.recentExerciseIds = recentExerciseIds
        }
    }

    /// The athlete's global imperial/metric default, **read through** to its single owner rather
    /// than copied. A mirrored `var` here is what let the Plan tab's execution store render metric
    /// to an imperial athlete: it was synced from exactly one line in `RootView`, so every store
    /// built anywhere else silently kept the `.metric` default.
    var unitSystem: UnitSystem { units.unitSystem }

    private let units: any UnitSystemSource
    private let defaults: UserDefaults
    private let persistsState: Bool
    private weak var configurationSource: WorkoutStore?
    private static let key = "workout.current"
    private static let logKey = "workout.currentLog"
    private static let logStartedAtKey = "workout.currentLogStartedAt"
    private static let prefKey = "workout.preferences"
    private static let customKey = "workout.customDefinitions"
    private static let recentKey = "workout.recentExercises"

    /// `units` is required, not defaulted: a display surface that forgets to wire the athlete's unit
    /// system should fail to compile rather than quietly render metric.
    init(units: any UnitSystemSource, defaults: UserDefaults = .standard) {
        self.units = units
        self.defaults = defaults
        persistsState = true
        current = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Workout.self, from: $0) }
        currentLog = defaults.data(forKey: Self.logKey).flatMap { try? JSONDecoder().decode(WorkoutLog.self, from: $0) }
        currentLogStartedAt = defaults.data(forKey: Self.logStartedAtKey).flatMap {
            try? JSONDecoder().decode(Date.self, from: $0)
        }
        preferences = defaults.data(forKey: Self.prefKey).flatMap { try? JSONDecoder().decode(ExercisePreferences.self, from: $0) } ?? ExercisePreferences()
        customDefinitions = defaults.data(forKey: Self.customKey).flatMap { try? JSONDecoder().decode([ExerciseDefinition].self, from: $0) } ?? []
        recentExerciseIds = defaults.data(forKey: Self.recentKey).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    /// A review-local editor store. Workout mutations never replace or persist today's workout, while
    /// deliberate catalog/default changes still flow back to the athlete's real configuration.
    init(transientWorkout: Workout, configurationFrom source: WorkoutStore) {
        units = source.units
        defaults = source.defaults
        persistsState = false
        configurationSource = source
        current = transientWorkout
        currentLog = nil
        currentLogStartedAt = nil
        preferences = source.preferences
        customDefinitions = source.customDefinitions
        recentExerciseIds = source.recentExerciseIds
    }

    // MARK: - Exercise catalog (curated + custom)

    var allDefinitions: [ExerciseDefinition] { ExerciseCatalog.definitions + customDefinitions }

    /// Catalog matches for a query — name, alias, or category. Empty query → all, curated first.
    func searchDefinitions(_ query: String) -> [ExerciseDefinition] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allDefinitions }
        return allDefinitions.filter { d in
            d.name.lowercased().contains(q) || d.aliases.contains { $0.contains(q) } || d.category.rawValue.contains(q)
        }
    }

    var recentDefinitions: [ExerciseDefinition] {
        recentExerciseIds.compactMap { id in allDefinitions.first { $0.id == id } }
    }

    /// Resolve a name to a definition, checking custom first (so agent-added custom exercises keep
    /// their identity), else the curated catalog (generic fallback).
    func resolveDefinition(_ name: String) -> ExerciseDefinition {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let c = customDefinitions.first(where: { $0.name.lowercased() == key || $0.aliases.contains(key) }) { return c }
        return ExerciseCatalog.resolve(name)
    }

    /// Deliberately create a custom definition (reuses one with the same name if it exists).
    @discardableResult
    func createCustomDefinition(
        name: String,
        category: ActivityCategory? = nil,
        supported: [MetricType],
        equipment: [Equipment] = [],
        primaryMuscles: [Muscle] = [],
        secondaryMuscles: [Muscle] = [],
        patterns: [MovementPattern] = [],
        tags: [ExerciseTag] = [],
        level: ExerciseLevel? = .intermediate
    ) -> ExerciseDefinition {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = customDefinitions.first(where: { $0.name.lowercased() == trimmed.lowercased() }) { return existing }
        let metrics = supported.isEmpty ? [.reps, .load] : supported
        let modality = Modality.inferred(fromMetrics: metrics)
        let cat = category ?? ActivityCategory.legacy(modality: modality, patterns: patterns)
        let def = ExerciseDefinition(id: "custom_\(UUID().uuidString.prefix(8))", name: trimmed, category: cat,
                                     supported: metrics, defaults: metrics, aliases: [trimmed.lowercased()],
                                     primaryMuscles: primaryMuscles, secondaryMuscles: secondaryMuscles,
                                     patterns: patterns, equipment: equipment, mechanic: nil,
                                     modality: modality, level: level, tags: tags)
        customDefinitions.append(def)
        return def
    }

    /// Add a fully-built planned exercise (from the catalog picker) to a block, tracking recents.
    func addExercise(_ exercise: PlannedExercise, toBlockID blockID: UUID, scope: WorkoutEditScope) {
        guard var w = workout(scope) else { return }
        _ = w.addExercise(exercise, toBlock: blockID)
        apply(w, scope)
        if let id = exercise.definitionId { noteRecent(id) }
    }

    private func noteRecent(_ id: String) {
        recentExerciseIds.removeAll { $0 == id }
        recentExerciseIds.insert(id, at: 0)
        if recentExerciseIds.count > 12 { recentExerciseIds = Array(recentExerciseIds.prefix(12)) }
    }

    /// The display unit for a metric on a planned exercise: this-instance override → per-exercise
    /// preference → per-category preference → the athlete's unit system (which is category-aware —
    /// see `UnitSystem.displayUnit(metric:exercise:)`). The order is the product rule: a stored
    /// choice is for the athlete with an unusual preference, and it always beats the default.
    ///
    /// Each tier is only honoured if the unit it holds is still one this metric offers. That is a
    /// safety net, not a new tier: it lets a unit be retired (pace no longer shows raw `s/m`) without
    /// old stored state resurrecting it, and it never changes which tier wins.
    func displayUnit(_ metric: MetricType, for ex: PlannedExercise) -> MetricUnit {
        func offered(_ unit: MetricUnit?) -> MetricUnit? {
            unit.flatMap { metric.displayUnits.contains($0) ? $0 : nil }
        }
        if let u = offered(ex.displayUnits[metric]) { return u }
        if let id = ex.definitionId {
            if let u = offered(preferences.unitsByExercise[id]?[metric]) { return u }
            if let cat = ExerciseCatalog.definition(id: id)?.category.rawValue,
               let u = offered(preferences.unitsByCategory[cat]?[metric]) { return u }
        }
        return unitSystem.displayUnit(metric: metric, exercise: ex.definition)
    }

    /// The display unit for a quantity with no exercise to hang an override on — group totals,
    /// weekly aggregates, agent prose about the plan.
    func displayUnit(_ metric: MetricType) -> MetricUnit {
        unitSystem.displayUnit(metric: metric, exercise: nil)
    }

    // MARK: - UI-facing edits (id-based; the manual screen drives the same model the agent does)

    /// Apply an id-based structural edit (add/remove/reorder/move/substitute) and write it to the
    /// destination the caller names — the session's copy while performing, the plan otherwise.
    @discardableResult
    func edit(_ scope: WorkoutEditScope, _ transform: (inout Workout) -> Void) -> Bool {
        guard var w = workout(scope) else { return false }
        transform(&w)
        return apply(w, scope)
    }

    /// Replace a planned movement in place. The exercise identity, position, prescription, and
    /// guidance stay intact; only catalog identity and incompatible logging configuration change.
    @discardableResult
    func replaceExercise(_ exerciseID: UUID, with definition: ExerciseDefinition, scope: WorkoutEditScope) -> Bool {
        guard var workout = workout(scope),
              applyReplacement(definition, to: exerciseID, in: &workout) else { return false }
        apply(workout, scope)
        noteRecent(definition.id)
        return true
    }

    /// Begin performing. Bound → the plan creates the session; unbound → a local performed log.
    func startWorkout() {
        if let sink {
            sink.start()
            reloadFromPlan()
        } else {
            guard let w = current, currentLog == nil else { return }
            currentLogStartedAt = Date()
            currentLog = w.startLog()
        }
    }

    /// Apply an edit to the performed log (log a set, skip/complete, note). Write-through in didSet.
    func editLog(_ transform: (inout WorkoutLog) -> Void) {
        guard var l = currentLog else { return }
        transform(&l)
        currentLog = l
    }

    /// Finish the session. `awaitingReconciliationDecision` says a prompt is about to be shown, which is
    /// the only reason the decision stays open past completion — finishing a workout that matched the
    /// plan resolves it here, because no prompt will ever appear to resolve it later. Required, not
    /// defaulted: a caller that omitted it would silently close a prompt that had not been shown yet.
    func completeWorkout(awaitingReconciliationDecision: Bool) {
        if let sink { sink.complete(); reloadFromPlan() }
        else { editLog { $0.isComplete = true } }
        if !awaitingReconciliationDecision { sink?.resolveSessionDecision() }
    }

    // MARK: - Session ⇄ plan reconciliation (mid-workout edits promote to the plan only on opt-in)

    /// A captured, self-contained answer to "did this session diverge from the saved plan, and what
    /// would promoting it write?". Captured *before* completing so the decision never depends on the
    /// store's post-completion state, and so the prompt can outlive the session it describes.
    struct SessionReconciliation: Equatable {
        let diff: WorkoutSessionDiff
        /// The workout to write to the plan if the athlete says yes.
        let sessionWorkout: Workout
    }

    /// The workout as the athlete shaped it this session — the live copy with top-level log
    /// substitutions folded in. Nil only when there is no current workout at all.
    private var effectiveSessionPlan: Workout? {
        guard let current, let log = currentLog else { return current }
        return WorkoutSessionReconciliation.effectiveSessionPlan(base: current, log: log)
    }

    /// Capture how this session diverged from the saved plan. Nil when unbound (no plan to promote to)
    /// or when nothing changed — in both cases completion shows no prompt.
    /// A pure query: it changes no state, so a second call — or a future "what would change?" preview —
    /// cannot disturb where edits are written.
    func captureSessionReconciliation() -> SessionReconciliation? {
        guard let sink, let plan = sink.planWorkout(), let session = effectiveSessionPlan else { return nil }
        let diff = WorkoutSessionReconciliation.diff(plan: plan, session: session)
        guard diff.hasChanges else { return nil }
        return SessionReconciliation(diff: diff, sessionWorkout: session)
    }

    /// Promote a captured session shape to the saved scheduled workout as a new plan revision — the
    /// completion "Update Plan" opt-in. This is the only path by which a mid-workout edit reaches the
    /// plan. A source `WorkoutTemplate` the workout was instantiated from is a separate, immutable
    /// object and is deliberately left untouched.
    func applySessionReconciliation(_ reconciliation: SessionReconciliation) {
        sink?.resolveSessionDecision()
        sink?.pushWorkout(reconciliation.sessionWorkout)
    }

    /// The athlete kept their original plan. Symmetric with accepting, and it changes routing only:
    /// `current` keeps the shape they actually performed so the completed summary stays honest, while
    /// nothing can promote that shape, because promotion is `applySessionReconciliation`'s alone.
    func declineSessionReconciliation() {
        sink?.resolveSessionDecision()
    }

    /// True-remove a top-level exercise from the workout. During a live session this edits the session
    /// copy and also purges the exercise's performed record, so no orphaned logged sets survive to be
    /// resurfaced at completion. Before a session it edits the plan as an ordinary structural change.
    func removeExerciseFromWorkout(_ exerciseID: UUID, scope: WorkoutEditScope) {
        edit(scope) { $0.removeExercise(exerciseID) }
        if currentLog != nil {
            editLog { $0.removePerformed(forPlanned: exerciseID) }
        }
    }

    /// True-remove planned sets from an exercise's prescription, purging the matching logged actuals for
    /// the same reason `removeExerciseFromWorkout` does: the log table renders rows from the
    /// prescription, so a surviving actual would be invisible yet still committed to completed history.
    func removePlannedSets(_ setIDs: [UUID], fromExercise exerciseID: UUID, scope: WorkoutEditScope) {
        let ids = Set(setIDs)
        guard !ids.isEmpty else { return }
        edit(scope) { workout in
            workout.updateExercise(exerciseID) { planned in
                planned.prescription.sets.removeAll { ids.contains($0.id) }
            }
        }
        if currentLog != nil {
            editLog { $0.removeSetLogs(forPlanned: exerciseID, plannedSetIDs: ids) }
        }
    }

    /// True-remove a whole block, purging the performed record of every exercise it contained so the
    /// same no-orphaned-sets guarantee as `removeExerciseFromWorkout` holds for block deletion.
    /// A workout always keeps at least one block, so deleting the last one leaves an empty default.
    func removeBlockFromWorkout(_ blockID: UUID, scope: WorkoutEditScope) {
        let removedIDs = current?.blocks.first { $0.id == blockID }?.exercises.map(\.id) ?? []
        edit(scope) { workout in
            workout.removeBlock(blockID)
            if workout.blocks.isEmpty { workout.blocks.append(WorkoutBlock(name: "", isDefault: true)) }
        }
        if currentLog != nil, !removedIDs.isEmpty {
            editLog { log in for id in removedIDs { log.removePerformed(forPlanned: id) } }
        }
    }

    /// Whether a top-level exercise has real logged work that a true-remove would discard — the signal
    /// to confirm before removing.
    func hasLoggedWork(forExercise exerciseID: UUID) -> Bool {
        currentLog?.hasLoggedWork(forPlanned: exerciseID) ?? false
    }

    /// Whether a block holds any exercise with real logged work — the confirm signal for block deletion.
    func hasLoggedWork(inBlock blockID: UUID) -> Bool {
        guard let log = currentLog, let block = current?.blocks.first(where: { $0.id == blockID }) else { return false }
        return block.exercises.contains { log.hasLoggedWork(forPlanned: $0.id) }
    }

    func discardLog() {
        guard let sink else {
            isSyncing = true
            currentLog = nil
            currentLogStartedAt = nil
            isSyncing = false
            return
        }
        sink.discard()
        // Reload rather than just dropping the log: a discarded session has no workout copy any more, so
        // the saved plan revision is what the athlete should be looking at and editing again.
        reloadFromPlan()
    }

    /// Result of a name-resolved edit — so the tool layer asks the athlete to disambiguate (exactly
    /// what a coach does with two same-named movements) instead of silently guessing.
    enum EditOutcome {
        case done
        case notFound(String)
        case ambiguous(String)
        var succeeded: Bool { if case .done = self { return true } else { return false } }
    }

    /// An agent-facing operation never confirms a change it did not make: if the write could not reach
    /// its destination the athlete hears why, rather than a fabricated success.
    private func committed(_ applied: Bool) -> EditOutcome {
        applied ? .done : .notFound(Self.missingPlanWorkout)
    }

    private static let missingPlanWorkout =
        "Today's workout isn't in your plan any more - it looks like it was deleted. Open the Plan tab and add one, and I'll pick it up from there."


    /// Whether the stored workout is for today. Unstamped (legacy) workouts count as today's; a
    /// workout from an earlier day must not be presented as "today's".
    var currentIsForToday: Bool {
        guard let date = current?.scheduledDate else { return true }
        return Calendar.current.isDateInToday(date)
    }

    // MARK: - Tool-facing operations (name-resolved)

    /// Replace the workout wholesale. Refused while a plan-bound session's decision is open: the plan and
    /// the session copy would disagree, and the new exercise ids would match nothing in the log that is
    /// still open against the old shape. Returns false so callers can say so out loud. A standalone store
    /// has no session copy to contradict, so it keeps its long-standing replace-and-clear behavior.
    @discardableResult
    func create(title: String, goal: String?) -> EditOutcome {
        guard sink == nil || !hasUnresolvedSessionDecision else {
            return .notFound("You're partway through this workout, so I can't replace it — finish or discard the log first and I'll build the new one.")
        }
        var w = Workout(title: title, goal: goal)
        w.scheduledDate = Calendar.current.startOfDay(for: .now)
        w.blocks = [WorkoutBlock(name: "", isDefault: true)]   // implicit default block (hidden until structured)

        if sink != nil {
            // Bound → replaces today's plan content, but only if there is still a plan to replace.
            guard applyPlan(w) else { return .notFound(Self.missingPlanWorkout) }
            isSyncing = true; current = w; currentLog = nil; currentLogStartedAt = nil; isSyncing = false
        } else if let make = makeTodayScheduled, let newSink = make(w) {
            // Nothing scheduled today yet → the factory already put `w` in the plan; bind without re-pushing.
            sink = newSink; coalesceContent = false; pendingPlanEdit = nil
            isSyncing = true; current = w; currentLog = nil; currentLogStartedAt = nil; isSyncing = false
        } else {
            current = w; currentLog = nil; currentLogStartedAt = nil   // standalone (no plan)
        }
        return .done
    }

    // Numeric guards at the tool boundary — the model can propose anything; reps/load/duration can't
    // go negative and RPE is 0–10.
    private func clampReps(_ v: Int?) -> Int? { v.map { max(0, $0) } }
    private func clampLoad(_ v: Double?) -> Double? { v.map { max(0, $0) } }
    private func clampDuration(_ v: Int?) -> Int? { v.map { max(0, $0) } }
    private func clampRPE(_ v: Double?) -> Double? { v.map { min(max($0, 0), 10) } }

    @discardableResult
    func addBlock(name: String, intent: String?) -> EditOutcome {
        guard var w = workout(agentScope) else { return .notFound("There's no workout yet — create one first.") }
        w.addBlock(name: name, intent: intent)
        return committed(apply(w, agentScope))
    }

    @discardableResult
    func addExercise(name: String, toBlockNamed block: String,
                     sets: Int?, reps: Int?, load: Double?, durationSeconds: Int?,
                     distanceMeters: Double? = nil) -> EditOutcome {
        guard var w = workout(agentScope) else { return .notFound("There's no workout yet — create one first.") }
        let blockID: UUID
        switch resolveBlock(block, in: w) {
        case .none:
            // A simple workout has one implicit block — put it there rather than failing on the name.
            if w.blocks.count == 1 { blockID = w.blocks[0].id }
            else { return .notFound("I couldn't find a block called \"\(block)\".") }
        case .one(let id): blockID = id
        case .many(let opts): return .ambiguous(ambiguity(block, opts, kind: "blocks"))
        }
        let count = max(1, sets ?? 1)
        var exercise = PlannedExercise(exerciseName: name)

        // Resolve stable identity + the metrics this instance should log: the definition's defaults,
        // plus any metric actually provided. Uncurated movements fall back to reps/load.
        let def = resolveDefinition(name)
        exercise.definitionId = def.id == ExerciseCatalog.generic.id ? nil : def.id
        // A saved per-exercise metric preference wins over the catalog default for new instances.
        var selected = Set(preferences.selectedByExercise[def.id] ?? def.defaults)
        if reps != nil { selected.insert(.reps) }
        if load != nil { selected.insert(.load) }
        if durationSeconds != nil { selected.insert(.duration) }
        if distanceMeters != nil { selected.insert(.distance) }
        if selected.isEmpty { selected = [.reps, .load] }
        exercise.selectedMetrics = MetricType.allCases.filter { selected.contains($0) }   // canonical order

        exercise.prescription.sets = (0..<count).map { _ in
            PlannedSet(reps: clampReps(reps), load: clampLoad(load), duration: clampDuration(durationSeconds), distance: clampLoad(distanceMeters))
        }
        _ = w.addExercise(exercise, toBlock: blockID)
        let applied = apply(w, agentScope)
        if let id = exercise.definitionId { noteRecent(id) }
        return committed(applied)
    }

    @discardableResult
    func moveExercise(named exercise: String, toBlockNamed block: String) -> EditOutcome {
        guard var w = workout(agentScope) else { return .notFound("There's no workout yet.") }
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
        return committed(apply(w, agentScope))
    }

    @discardableResult
    func removeExercise(named exercise: String) -> EditOutcome {
        guard var w = workout(agentScope) else { return .notFound("There's no workout yet.") }
        switch resolveExercise(exercise, in: w) {
        case .none: return .notFound("I couldn't find \"\(exercise)\" in the workout.")
        case .many(let opts): return .ambiguous(ambiguity(exercise, opts, kind: "exercises"))
        case .one(let id): _ = w.removeExercise(id); return committed(apply(w, agentScope))
        }
    }

    /// The agent-facing equivalent of the manual Replace Exercise action. A block can qualify one
    /// duplicate, while `replaceAll` intentionally updates every matching instance atomically.
    @discardableResult
    func replaceExercise(
        named exercise: String,
        with replacement: String,
        inBlock block: String? = nil,
        replaceAll: Bool = false
    ) -> EditOutcome {
        guard var workout = workout(agentScope) else { return .notFound("There's no workout yet.") }
        let definition = resolveDefinition(replacement)
        guard definition.id != ExerciseCatalog.generic.id else {
            return .notFound("I couldn't find \"\(replacement)\" in the exercise catalog.")
        }

        let blocks: [WorkoutBlock]
        if let block, !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch resolveBlock(block, in: workout) {
            case .none: return .notFound("I couldn't find a block called \"\(block)\".")
            case .many(let options): return .ambiguous(ambiguity(block, options, kind: "blocks"))
            case .one(let id): blocks = workout.blocks.filter { $0.id == id }
            }
        } else {
            blocks = workout.blocks
        }

        let matches = matchingExercises(exercise, in: blocks)
        guard !matches.isEmpty else {
            return .notFound("I couldn't find \"\(exercise)\" in the workout.")
        }
        guard replaceAll || matches.count == 1 else {
            return .ambiguous(ambiguity(exercise, matches, kind: "exercises"))
        }

        let targets = replaceAll ? matches : [matches[0]]
        for target in targets {
            guard applyReplacement(definition, to: target.id, in: &workout) else {
                return .notFound("I couldn't replace \"\(target.label)\".")
            }
        }
        let applied = apply(workout, agentScope)
        noteRecent(definition.id)
        return committed(applied)
    }

    /// Update one set (1-based `setNumber`) of a named exercise. Only the supplied fields change.
    @discardableResult
    func updateSet(exerciseNamed exercise: String, setNumber: Int,
                   reps: Int?, load: Double?, durationSeconds: Int?, distanceMeters: Double? = nil, rpe: Double?) -> EditOutcome {
        guard var w = workout(agentScope) else { return .notFound("There's no workout yet.") }
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
            if let distanceMeters { s.distance = clampLoad(distanceMeters) }
            if let rpe { s.rpe = clampRPE(rpe) }
        }
        return committed(apply(w, agentScope))
    }

    // MARK: - Logging configuration & values (metric system)

    /// THIS WORKOUT: choose which metrics an exercise logs + per-instance unit overrides. Rejects
    /// metrics the exercise doesn't support.
    @discardableResult
    func setLoggingConfig(exerciseNamed name: String, enabled: [MetricType]?, units: [MetricType: MetricUnit] = [:]) -> EditOutcome {
        guard var w = workout(agentScope) else { return .notFound("There's no workout yet.") }
        let exID: UUID
        switch resolveExercise(name, in: w) {
        case .none: return .notFound("I couldn't find \"\(name)\" in the workout.")
        case .many(let opts): return .ambiguous(ambiguity(name, opts, kind: "exercises"))
        case .one(let id): exID = id
        }
        guard let ex = w.exercise(exID) else { return .notFound("I couldn't find \"\(name)\".") }
        let requested = (enabled ?? []) + Array(units.keys)
        if let bad = requested.first(where: { !ex.supportedMetrics.contains($0) }) {
            return .notFound("\(ex.exerciseName) doesn't support \(bad.label.lowercased()).")
        }
        w.updateExercise(exID) { e in
            if let enabled { e.selectedMetrics = MetricType.allCases.filter { enabled.contains($0) } }
            for (metric, unit) in units where metric.displayUnits.contains(unit) { e.displayUnits[metric] = unit }
        }
        return committed(apply(w, agentScope))
    }

    /// UI edits already know the exact exercise identity, so duplicates must never make a tapped
    /// Metrics/Units menu ambiguous. The name-resolved overload remains the safe agent boundary.
    @discardableResult
    func setLoggingConfig(
        exerciseID: UUID,
        enabled: [MetricType]?,
        units: [MetricType: MetricUnit] = [:],
        scope: WorkoutEditScope
    ) -> Bool {
        guard var workout = workout(scope), let exercise = workout.exercise(exerciseID) else { return false }
        let requested = (enabled ?? []) + Array(units.keys)
        guard requested.allSatisfy(exercise.supportedMetrics.contains) else { return false }
        workout.updateExercise(exerciseID) { updated in
            if let enabled {
                updated.selectedMetrics = MetricType.allCases.filter { enabled.contains($0) }
            }
            for (metric, unit) in units where metric.displayUnits.contains(unit) {
                updated.displayUnits[metric] = unit
            }
        }
        return apply(workout, scope)
    }

    /// Turn an incorrectly inferred either/or choice into one required ordered group. Name matching
    /// is ambiguity-aware so an agent can never silently change the wrong choice.
    func requireAllOptions(choiceNamed name: String) -> EditOutcome {
        guard var workout = workout(agentScope) else { return .notFound("There's no workout yet.") }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let choices = workout.allChoices
        let exact = choices.filter { $0.label.localizedCaseInsensitiveCompare(key) == .orderedSame }
        let matches = exact.isEmpty
            ? choices.filter { $0.label.localizedCaseInsensitiveContains(key) }
            : exact
        guard !matches.isEmpty else { return .notFound("I couldn't find a choice matching \"\(name)\".") }
        guard matches.count == 1, let choice = matches.first else {
            return .ambiguous("There are \(matches.count) choices matching \"\(name)\": \(matches.map(\.label).joined(separator: ", ")). Which one?")
        }
        guard workout.convertChoiceToRequiredGroup(choice.id) else {
            return .notFound("I couldn't update \"\(choice.label)\".")
        }
        return committed(apply(workout, agentScope))
    }

    /// FUTURE DEFAULT: a user preference for an exercise identity (or its whole category). Applies to
    /// new instances only — never the current workout.
    @discardableResult
    func setExercisePreference(exerciseNamed name: String, scope: PreferenceScope,
                               units: [MetricType: MetricUnit] = [:], selected: [MetricType]? = nil) -> EditOutcome {
        let def = ExerciseCatalog.resolve(name)
        guard def.id != ExerciseCatalog.generic.id else {
            return .notFound("I don't recognize \"\(name)\" as a known exercise to set a default for.")
        }
        if let bad = (Array(units.keys) + (selected ?? [])).first(where: { !def.supported.contains($0) }) {
            return .notFound("\(def.name) doesn't support \(bad.label.lowercased()).")
        }
        switch scope {
        case .exercise:
            var u = preferences.unitsByExercise[def.id] ?? [:]
            for (m, unit) in units where m.displayUnits.contains(unit) { u[m] = unit }
            preferences.unitsByExercise[def.id] = u
            if let selected { preferences.selectedByExercise[def.id] = MetricType.allCases.filter { selected.contains($0) } }
        case .category:
            var u = preferences.unitsByCategory[def.category.rawValue] ?? [:]
            for (m, unit) in units where m.displayUnits.contains(unit) { u[m] = unit }
            preferences.unitsByCategory[def.category.rawValue] = u
        }
        return .done
    }

    /// Set one metric's value on a planned set (value given in `unit`, stored canonically). Ensures
    /// the metric is selected/visible. Rejects unsupported metrics.
    @discardableResult
    func setMetricValue(exerciseNamed name: String, setNumber: Int, metric: MetricType, value: Double, unit: MetricUnit?) -> EditOutcome {
        guard var w = workout(agentScope) else { return .notFound("There's no workout yet.") }
        let exID: UUID
        switch resolveExercise(name, in: w) {
        case .none: return .notFound("I couldn't find \"\(name)\" in the workout.")
        case .many(let opts): return .ambiguous(ambiguity(name, opts, kind: "exercises"))
        case .one(let id): exID = id
        }
        guard let ex = w.exercise(exID) else { return .notFound("I couldn't find \"\(name)\".") }
        guard ex.supportedMetrics.contains(metric) else {
            return .notFound("\(ex.exerciseName) doesn't support \(metric.label.lowercased()).")
        }
        guard setNumber >= 1, setNumber <= ex.prescription.sets.count else {
            return .notFound("Set \(setNumber) doesn't exist for \(ex.exerciseName).")
        }
        // Parse side: an agent that names no unit means the storage unit, which is what the tool
        // schema tells it. Nothing here is shown to the athlete.
        let canonical = max(0, MetricConvert.toCanonical(value, metric, from: unit ?? metric.canonicalUnit))  // units:storage
        w.updateExercise(exID) { e in
            e.prescription.sets[setNumber - 1].values[metric] = canonical
            if !e.selectedMetrics.contains(metric) { e.selectedMetrics = MetricType.allCases.filter { e.selectedMetrics.contains($0) || $0 == metric } }
        }
        return committed(apply(w, agentScope))
    }

    /// Remove a metric from an exercise this workout — unselect it and clear its values.
    @discardableResult
    func removeMetric(exerciseNamed name: String, metric: MetricType) -> EditOutcome {
        guard var w = workout(agentScope) else { return .notFound("There's no workout yet.") }
        let exID: UUID
        switch resolveExercise(name, in: w) {
        case .none: return .notFound("I couldn't find \"\(name)\" in the workout.")
        case .many(let opts): return .ambiguous(ambiguity(name, opts, kind: "exercises"))
        case .one(let id): exID = id
        }
        w.updateExercise(exID) { e in
            e.selectedMetrics.removeAll { $0 == metric }
            e.displayUnits[metric] = nil
            for i in e.prescription.sets.indices { e.prescription.sets[i].values[metric] = nil }
        }
        return committed(apply(w, agentScope))
    }

    // MARK: - Read

    /// A cheap **index** of the workout this scope describes, for the always-sent context — ID, title,
    /// status, counts, date — WITHOUT the exercise/set detail. Detail is fetched on demand via
    /// get_current_workout, so a 30-exercise workout doesn't inflate every chat request.
    func compactSummary(_ scope: WorkoutEditScope) -> String? {
        guard let w = workout(scope) else { return nil }
        let status = currentLog == nil ? "not started" : (currentLog?.isComplete == true ? "completed" : "in progress")
        let isForToday = w.scheduledDate.map { Calendar.current.isDateInToday($0) } ?? true
        let date: String = isForToday ? "today"
            : (w.scheduledDate.map { $0.formatted(.dateTime.month().day()) } ?? "unscheduled")
        let exercises = w.allExercises.count
        let blocks = w.blocks.filter { !$0.isDefault || !$0.exercises.isEmpty }.count
        return """
        - ID: \(w.id.uuidString)
        - Title: \(w.title)
        - Status: \(status)
        - \(blocks) block\(blocks == 1 ? "" : "s")
        - \(exercises) exercise\(exercises == 1 ? "" : "s")
        - Scheduled: \(date)
        """
    }

    /// The active session id (the performed log), or nil if the workout hasn't been started.
    var activeSessionID: UUID? { currentLog?.id }

    /// Sets still unchecked, and how many exercises they span — so complete_workout can warn before
    /// finalizing (and start_workout can tell whether a session is already live).
    func incompleteWork() -> (sets: Int, exercises: Int) {
        guard let w = current, let log = currentLog else { return (0, 0) }
        var sets = 0, exercises = 0
        for ex in w.allExercises {
            let perf = log.performed(forPlanned: ex.id)
            let open = ex.prescription.sets.filter { s in
                perf?.setLogs.first { $0.plannedSetID == s.id }?.completed != true
            }.count
            if open > 0 { exercises += 1; sets += open }
        }
        return (sets, exercises)
    }

    /// The full rendering of the workout this scope describes — the same one an edit of this scope would
    /// change, so a confirmation can never echo a workout the tool did not touch.
    func summary(_ scope: WorkoutEditScope) -> String {
        guard let w = workout(scope) else { return "No workout has been created yet." }
        var lines = ["WORKOUT: \(w.title)" + (w.goal.map { " — goal: \($0)" } ?? "")]
        lines.append(contentsOf: guidanceSummary(w.guidance, indent: "  "))
        if w.blocks.isEmpty { lines.append("(no blocks yet)") }
        for (index, block) in w.blocks.enumerated() {
            lines.append("BLOCK \(index + 1): \(block.name)" + (block.intent.map { " — intent: \($0)" } ?? ""))
            lines.append(contentsOf: guidanceSummary(block.guidance, indent: "  "))
            if block.nodes.isEmpty { lines.append("  (empty)") }
            for node in block.nodes {
                appendSummary(node, indent: "  ", to: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func appendSummary(_ node: WorkoutNode, indent: String, to lines: inout [String]) {
        switch node {
        case .exercise(let exercise):
            let label = exercise.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = label.flatMap { $0.isEmpty ? nil : $0 }.map { "\($0) [exercise: \(exercise.exerciseName)]" }
                ?? exercise.exerciseName
            let identity = exercise.definitionId.map { " — catalog id: \($0)" } ?? " — custom/unmatched"
            lines.append("\(indent)EXERCISE: \(heading)\(identity)")
            let metricDescriptions = exercise.selectedMetrics.map { metric in
                let unit = displayUnit(metric, for: exercise)
                return unit.short.isEmpty ? metric.label : "\(metric.label) (\(unit.short))"
            }
            lines.append("\(indent)  Metrics: \(metricDescriptions.isEmpty ? "none" : metricDescriptions.joined(separator: ", "))")
            if let intent = exercise.prescription.intent { lines.append("\(indent)  Intent: \(intent.rawValue)") }
            if let rest = exercise.prescription.restSeconds { lines.append("\(indent)  Rest: \(MetricFormat.duration(Double(rest)))") }
            if let zone = exercise.prescription.targetZone { lines.append("\(indent)  Target HR zone: \(zone)") }
            if let tempo = exercise.prescription.tempo { lines.append("\(indent)  Tempo: \(tempo)") }
            for target in exercise.prescription.intensityTargets {
                lines.append("\(indent)  Target: \(WorkoutPresentationFormatter.intensityLabel(target))")
            }
            if exercise.prescription.sets.isEmpty { lines.append("\(indent)  Sets: none") }
            for (index, set) in exercise.prescription.sets.enumerated() {
                var values: [String] = []
                let metrics = MetricType.allCases.filter {
                    exercise.selectedMetrics.contains($0) || set.values[$0] != nil
                }
                for metric in metrics {
                    if let value = set.values[metric] {
                        values.append("\(metric.label)=\(MetricFormat.value(value, metric, unit: displayUnit(metric, for: exercise)))")
                    } else {
                        values.append("\(metric.label)=blank")
                    }
                }
                lines.append("\(indent)  Set \(index + 1) [\(set.role.rawValue)]: \(values.isEmpty ? "no values" : values.joined(separator: ", "))")
                if let effort = set.effortTarget {
                    lines.append("\(indent)    Effort target: \(effortSummary(effort))")
                }
                for range in set.ranges {
                    let unit = displayUnit(range.metric, for: exercise)
                    lines.append("\(indent)    Range: \(range.metric.label) \(MetricFormat.value(range.lower, range.metric, unit: unit))–\(MetricFormat.value(range.upper, range.metric, unit: unit))")
                }
                for progression in set.progressions {
                    let delta = MetricFormat.value(progression.delta, progression.metric,
                                                   unit: displayUnit(progression.metric, for: exercise))
                    lines.append("\(indent)    Progression: \(progression.metric.label) \(delta) every \(progression.every) \(progression.unit.rawValue)")
                }
                for alternative in set.alternatives {
                    let alternateValues = alternative.values.present.compactMap { metric -> String? in
                        guard let value = alternative.values[metric] else { return nil }
                        return "\(metric.label)=\(MetricFormat.value(value, metric, unit: displayUnit(metric, for: exercise)))"
                    }
                    lines.append("\(indent)    Alternative \(alternative.label): \(alternateValues.isEmpty ? "no values" : alternateValues.joined(separator: ", "))")
                    for range in alternative.ranges {
                        let unit = displayUnit(range.metric, for: exercise)
                        lines.append("\(indent)      Range: \(range.metric.label) \(MetricFormat.value(range.lower, range.metric, unit: unit))–\(MetricFormat.value(range.upper, range.metric, unit: unit))")
                    }
                }
            }
            lines.append(contentsOf: guidanceSummary(exercise.guidance, indent: "\(indent)  "))

        case .group(let group):
            var execution: [String] = []
            switch group.execution.repetition {
            case .once: execution.append("once")
            case .count(let count): execution.append("\(count) repetitions")
            case .until(let seconds): execution.append("for \(MetricFormat.duration(Double(seconds)))")
            }
            if let cadence = group.execution.cadence {
                execution.append("start every \(MetricFormat.duration(Double(cadence.intervalSeconds))) per \(cadence.scope.rawValue)")
            }
            if let summary = WorkoutPresentationFormatter.groupExecutionSummary(group.execution) {
                execution.append(summary)
            }
            if let phase = group.phase { execution.append("phase \(phase.rawValue)") }
            if let dose = group.doseLayer { execution.append("dose \(dose.rawValue.uppercased())") }
            if group.isOptional { execution.append("optional") }
            lines.append("\(indent)REQUIRED GROUP: \(group.label) — \(execution.joined(separator: "; "))")
            if !group.execution.totalTargets.isEmpty {
                let totals = group.execution.totalTargets.present.compactMap { metric -> String? in
                    guard let value = group.execution.totalTargets[metric] else { return nil }
                    return "\(metric.label)=\(MetricFormat.value(value, metric, unit: displayUnit(metric)))"
                }
                lines.append("\(indent)  Total targets: \(totals.joined(separator: ", "))")
            }
            for adjustment in group.execution.adjustments {
                let unit = displayUnit(adjustment.metric)
                func shown(_ v: Double) -> String { MetricFormat.value(v, adjustment.metric, unit: unit) }
                var detail = "\(adjustment.metric.label) step \(shown(adjustment.step))"
                if let minimum = adjustment.minimum { detail += ", minimum \(shown(minimum))" }
                if let maximum = adjustment.maximum { detail += ", maximum \(shown(maximum))" }
                lines.append("\(indent)  Adjustment: \(detail)")
            }
            lines.append(contentsOf: guidanceSummary(group.guidance, indent: "\(indent)  "))
            for child in group.children { appendSummary(child, indent: "\(indent)  ", to: &lines) }

        case .choice(let choice):
            lines.append("\(indent)CHOICE: \(choice.label) — choose \(choice.selectionCount) of \(choice.options.count)")
            for (index, option) in choice.options.enumerated() {
                lines.append("\(indent)  OPTION \(index + 1):")
                appendSummary(option, indent: "\(indent)    ", to: &lines)
            }

        case .rest(let rest):
            let duration = rest.durationSeconds.map { MetricFormat.duration(Double($0)) } ?? "unspecified duration"
            lines.append("\(indent)REST: \(rest.label) — \(duration), \(rest.placement.rawValue)")
            if let guidance = rest.guidance, !guidance.isEmpty { lines.append("\(indent)  Note: \(guidance)") }
        }
    }

    private func guidanceSummary(_ guidance: CoachGuidance?, indent: String) -> [String] {
        guard let guidance else { return [] }
        var lines: [String] = []
        if let goal = guidance.goal, !goal.isEmpty { lines.append("\(indent)Goal note: \(goal)") }
        if let tempo = guidance.tempo, !tempo.isEmpty { lines.append("\(indent)Tempo note: \(tempo)") }
        lines.append(contentsOf: guidance.formCues.filter { !$0.isEmpty }.map { "\(indent)Note: \($0)" })
        lines.append(contentsOf: guidance.commonMistakes.filter { !$0.isEmpty }.map { "\(indent)Avoid: \($0)" })
        if let progression = guidance.progressionNotes, !progression.isEmpty {
            lines.append("\(indent)Progression note: \(progression)")
        }
        return lines
    }

    private func effortSummary(_ effort: EffortTarget) -> String {
        switch effort {
        case .rpe(let value): "RPE \(value.formatted())"
        case .rir(let value): "\(value.formatted()) reps in reserve"
        case .toFailure: "to failure"
        case .maxEffort: "maximum effort"
        }
    }


    // MARK: - Name resolution (exact case-insensitive, else contains) — ambiguity-aware

    private struct Hit { let id: UUID; let label: String; let block: String }
    private enum Match { case none; case one(UUID); case many([Hit]) }

    /// Prefer exact matches; only fall back to substring matches if there are no exact ones. More
    /// than one survivor → ambiguous (ask), never a silent first-match.
    private func classify(_ hits: [Hit]) -> Match {
        switch hits.count {
        case 0: return .none
        case 1: return .one(hits[0].id)
        default: return .many(hits)
        }
    }

    private func resolveExercise(_ name: String, in w: Workout) -> Match {
        classify(matchingExercises(name, in: w.blocks))
    }

    private func matchingExercises(_ name: String, in blocks: [WorkoutBlock]) -> [Hit] {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var exact: [Hit] = [], fuzzy: [Hit] = []
        for b in blocks {
            for ex in b.exercises {
                if ex.exerciseName.localizedCaseInsensitiveCompare(key) == .orderedSame {
                    exact.append(Hit(id: ex.id, label: ex.exerciseName, block: b.name))
                } else if ex.exerciseName.localizedCaseInsensitiveContains(key) {
                    fuzzy.append(Hit(id: ex.id, label: ex.exerciseName, block: b.name))
                }
            }
        }
        return exact.isEmpty ? fuzzy : exact
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
        return classify(exact.isEmpty ? fuzzy : exact)
    }

    private func applyReplacement(
        _ definition: ExerciseDefinition,
        to exerciseID: UUID,
        in workout: inout Workout
    ) -> Bool {
        workout.updateExercise(exerciseID) { planned in
            planned.exerciseName = definition.name
            planned.definitionId = definition.id == ExerciseCatalog.generic.id ? nil : definition.id
            let supported = Set(definition.supported)
            planned.selectedMetrics = planned.selectedMetrics.filter { supported.contains($0) }
            if planned.selectedMetrics.isEmpty { planned.selectedMetrics = definition.defaults }
            planned.displayUnits = planned.displayUnits.filter { supported.contains($0.key) }
        }
    }

    private func ambiguity(_ name: String, _ opts: [Hit], kind: String) -> String {
        let list = opts.map { kind == "exercises" ? "\"\($0.label)\" in \($0.block)" : "\"\($0.label)\"" }
            .joined(separator: ", ")
        return "There are \(opts.count) \(kind) matching \"\(name)\": \(list). Which one?"
    }

    // MARK: - Persistence

    private func persist<T: Encodable>(_ value: T?, _ key: String) {
        guard persistsState else { return }
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
