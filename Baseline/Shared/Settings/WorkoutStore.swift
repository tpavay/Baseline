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
        let mutationTarget: (WorkoutEditScope) -> WorkoutMutationTarget?
        let activeSession: () -> WorkoutSession?
        let performedLogMutationTarget: () -> WorkoutMutationTarget?
        /// The optional log is a session-scoped companion write (a purged logged actual) that must be
        /// versioned and undone together with the workout content it belongs to.
        let applyMutation: (WorkoutMutationRequest, Workout, WorkoutLog?) -> WorkoutMutationResult
        let applyLogMutation: (WorkoutMutationRequest, WorkoutLog) -> WorkoutMutationResult
        let undoMutation: (UUID, UUID) -> WorkoutMutationResult
        let undoSessionMutation: (UUID, UUID) -> WorkoutMutationResult
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

        init(
            pushWorkout: @escaping (Workout) -> Void,
            pushSessionWorkout: @escaping (Workout) -> Void,
            pushLog: @escaping (WorkoutLog) -> Void,
            mutationTarget: ((WorkoutEditScope) -> WorkoutMutationTarget?)? = nil,
            activeSession: (() -> WorkoutSession?)? = nil,
            performedLogMutationTarget: (() -> WorkoutMutationTarget?)? = nil,
            applyMutation: ((WorkoutMutationRequest, Workout, WorkoutLog?) -> WorkoutMutationResult)? = nil,
            applyLogMutation: ((WorkoutMutationRequest, WorkoutLog) -> WorkoutMutationResult)? = nil,
            undoMutation: ((UUID, UUID) -> WorkoutMutationResult)? = nil,
            undoSessionMutation: ((UUID, UUID) -> WorkoutMutationResult)? = nil,
            start: @escaping () -> Void,
            complete: @escaping () -> Void,
            discard: @escaping () -> Void,
            isSessionDecisionPending: @escaping () -> Bool,
            resolveSessionDecision: @escaping () -> Void,
            resolveAbandonedSessionDecision: @escaping () -> Void,
            reload: @escaping () -> (workout: Workout, log: WorkoutLog?, startedAt: Date?)?,
            planWorkout: @escaping () -> Workout?
        ) {
            self.pushWorkout = pushWorkout
            self.pushSessionWorkout = pushSessionWorkout
            self.pushLog = pushLog
            let fallbackRevisionToken = UUID()
            self.mutationTarget = mutationTarget ?? { scope in
                let workout = scope == .plan ? planWorkout() : reload()?.workout
                guard let workout else { return nil }
                return WorkoutMutationTarget(
                    scope: .transient,
                    scheduledWorkoutID: nil,
                    sessionID: nil,
                    workoutID: workout.id,
                    revisionToken: fallbackRevisionToken
                )
            }
            self.activeSession = activeSession ?? { nil }
            self.performedLogMutationTarget = performedLogMutationTarget ?? { nil }
            self.applyMutation = applyMutation ?? { request, workout, log in
                if isSessionDecisionPending() {
                    pushSessionWorkout(workout)
                } else {
                    pushWorkout(workout)
                }
                if let log { pushLog(log) }
                let receipt = WorkoutMutationReceipt(
                    mutationID: request.mutationID,
                    scope: .transient,
                    scheduledWorkoutID: nil,
                    sessionID: nil,
                    workoutID: workout.id,
                    beforeRevisionToken: request.expectedRevisionToken,
                    afterRevisionToken: UUID(),
                    diff: request.diff,
                    actor: request.actor,
                    undoAvailable: false
                )
                return .applied(receipt)
            }
            self.applyLogMutation = applyLogMutation ?? { request, log in
                pushLog(log)
                return .applied(WorkoutMutationReceipt(
                    mutationID: request.mutationID,
                    scope: .performedLog,
                    scheduledWorkoutID: request.target.scheduledWorkoutID,
                    sessionID: request.target.sessionID,
                    workoutID: request.target.workoutID,
                    beforeRevisionToken: request.expectedRevisionToken,
                    afterRevisionToken: UUID(),
                    diff: request.diff,
                    actor: request.actor,
                    undoAvailable: false
                ))
            }
            self.undoMutation = undoMutation ?? { _, _ in .rejected(.undoUnavailable) }
            self.undoSessionMutation = undoSessionMutation ?? { _, _ in .rejected(.undoUnavailable) }
            self.start = start
            self.complete = complete
            self.discard = discard
            self.isSessionDecisionPending = isSessionDecisionPending
            self.resolveSessionDecision = resolveSessionDecision
            self.resolveAbandonedSessionDecision = resolveAbandonedSessionDecision
            self.reload = reload
            self.planWorkout = planWorkout
        }
    }
    private var sink: PlanSink?
    private var coalesceContent = false
    private var isSyncing = false                     // true while pulling from the plan → suppress push-back
    private var transientRevisionToken = UUID()
    private struct TransientMutationUndo {
        let receipt: WorkoutMutationReceipt
        let before: Workout
        /// Exact performed facts purged by the mutation. Undo merges these into the current log
        /// without replacing work recorded after the mutation.
        let purgedLogContent: WorkoutLogPurge
    }
    /// Only the newest transient receipt can ever undo (the token guard makes every older one
    /// permanently stale), so only its snapshot is retained. Pruned receipts keep their IDs in
    /// `staleTransientMutationIDs` so a late undo attempt still gets the truthful stale answer.
    private var latestTransientUndo: TransientMutationUndo?
    private var staleTransientMutationIDs: Set<UUID> = []
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
        if let sink {
            sink.pushSessionWorkout(workout)
        } else {
            advanceTransientRevisionAfterDirectWrite()
        }
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
        guard let sink else {
            advanceTransientRevisionAfterDirectWrite()
            return true
        }
        if coalesceContent { pendingPlanEdit = workout } else { sink.pushWorkout(workout) }
        return true
    }

    /// A direct edit is newer than the latest receipt-bound transient mutation. Advancing the token
    /// makes that receipt stale and prevents whole-snapshot undo from erasing the direct edit.
    private func advanceTransientRevisionAfterDirectWrite() {
        transientRevisionToken = UUID()
        invalidateLatestTransientUndo()
    }

    private func invalidateLatestTransientUndo() {
        guard let latestTransientUndo else { return }
        staleTransientMutationIDs.insert(latestTransientUndo.receipt.mutationID)
        self.latestTransientUndo = nil
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
        let definition = resolvedDefinition(for: ex)
        if let id = ex.definitionId {
            if let u = offered(preferences.unitsByExercise[id]?[metric]) { return u }
            if let u = offered(preferences.unitsByCategory[definition.category.rawValue]?[metric]) { return u }
        }
        return unitSystem.displayUnit(metric: metric, exercise: definition)
    }

    /// The definition backing a planned exercise, resolved against the athlete's **own** catalog.
    /// `PlannedExercise.definition` only consults the curated catalog, so a custom movement would
    /// fall through to the generic definition and lose the category the unit rule depends on.
    ///
    /// Runs inside `displayUnit` on the SwiftUI render path, so it stays O(1): the small
    /// `customDefinitions` array first, then the catalog's snapshot dictionary — never the ~900-element
    /// `allDefinitions` concatenation.
    private func resolvedDefinition(for ex: PlannedExercise) -> ExerciseDefinition {
        guard let id = ex.definitionId else { return ex.definition }
        return customDefinitions.first { $0.id == id } ?? ExerciseCatalog.definition(id: id) ?? ex.definition
    }

    /// The display unit for a quantity with no exercise to hang an override on — weekly aggregates,
    /// agent prose about the plan.
    func displayUnit(_ metric: MetricType) -> MetricUnit {
        unitSystem.displayUnit(metric: metric, exercise: nil)
    }

    /// The display unit for a group's **total** target. A total is a single number with room for one
    /// unit, so the group's composition decides it and nothing about the values does: only a group
    /// with at least one distance-bearing movement, all of them endurance, reads in the athlete's
    /// endurance unit. Any floor movement in the mix — or no distance-bearing movement at all, which
    /// is absence of evidence rather than evidence of endurance — puts the whole total back in meters.
    func displayUnit(_ metric: MetricType, forTotalsIn group: WorkoutGroup) -> MetricUnit {
        guard metric == .distance else { return displayUnit(metric) }
        let distanceMovements = group.children.flatMap(\.exercises)
            .map(resolvedDefinition(for:))
            .filter { $0.supported.contains(.distance) }
        guard !distanceMovements.isEmpty,
              distanceMovements.allSatisfy({ $0.category.distanceContext == .endurance }) else { return .meters }
        return displayUnit(metric)
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

    /// True-remove a whole block, purging the performed record of every exercise it contained (nested
    /// ones included) plus its owned group and choice logs, so the same no-orphaned-state guarantee as
    /// the agent `removeBlock` holds for direct-control deletion.
    /// A workout always keeps at least one block, so deleting the last one leaves an empty default.
    func removeBlockFromWorkout(_ blockID: UUID, scope: WorkoutEditScope) {
        let removed = current?.blocks.first { $0.id == blockID }
        edit(scope) { workout in
            workout.removeBlock(blockID)
            if workout.blocks.isEmpty { workout.blocks.append(WorkoutBlock(name: "", isDefault: true)) }
        }
        if currentLog != nil, let removed {
            editLog { log in
                for exercise in removed.exercises { log.removePerformed(forPlanned: exercise.id) }
                log.removeGroups(forPlanned: Set(removed.groups.map(\.id)))
                log.removeChoices(forPlanned: Set(removed.choices.map(\.id)))
            }
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
        case mutated(WorkoutMutationReceipt)
        case notFound(String)
        case ambiguous(String)
        var succeeded: Bool {
            switch self {
            case .done, .mutated: true
            case .notFound, .ambiguous: false
            }
        }
    }

    /// The addressable descriptor returned by `get_current_workout` and required by mutation calls.
    /// Bound stores read it through the plan repository; review-local stores own a transient token.
    func mutationTarget(_ scope: WorkoutEditScope) -> WorkoutMutationTarget? {
        if let sink { return sink.mutationTarget(scope) }
        guard let workout = workout(scope) else { return nil }
        return WorkoutMutationTarget(
            scope: .transient,
            scheduledWorkoutID: nil,
            sessionID: nil,
            workoutID: workout.id,
            revisionToken: transientRevisionToken
        )
    }

    /// Validate and transform one authoritative workout value, then cross the persistence boundary once.
    /// Every ID and domain input is checked by `transform` before this function writes anything.
    ///
    /// `logTransform` is a companion **row purge** of the performed log, applied only after `transform`
    /// succeeds — it runs second by contract, so it may read identifiers the transform resolved. It must
    /// only remove rows: undo re-inserts exactly the rows that disappeared into whatever the log has
    /// become by then, so an in-place modification here would not be undoable.
    private func mutate(
        expectedRevisionToken: UUID?,
        reason: String,
        diff: WorkoutMutationDiff,
        dryRun: Bool = false,
        resolvedEntityIDs: () -> [UUID] = { [] },
        logTransform: ((inout WorkoutLog) -> Void)? = nil,
        transform: (inout Workout) -> EditOutcome?
    ) -> EditOutcome {
        let scope = agentScope
        guard var authoritative = workout(scope), let target = mutationTarget(scope) else {
            return .notFound(sink == nil ? "There's no workout yet." : Self.missingPlanWorkout)
        }
        let before = authoritative
        let displayWasAuthoritative = current == authoritative
        let expected = expectedRevisionToken ?? target.revisionToken
        guard target.revisionToken == expected else {
            return .notFound(Self.staleMutationMessage)
        }
        if let failure = transform(&authoritative) { return failure }
        // A companion log write only accompanies an edit to the workout the log belongs to: the
        // session copy, or an unbound store's single workout. A bound plan edit never rewrites a
        // session's performed history.
        var updatedLog: WorkoutLog?
        if let logTransform, var log = currentLog, sink == nil || scope == .session {
            logTransform(&log)
            if log != currentLog { updatedLog = log }
        }
        var resolvedDiff = diff
        let entityIDs = resolvedEntityIDs()
        if resolvedDiff.changes.count == 1, let change = resolvedDiff.changes.first, !entityIDs.isEmpty {
            resolvedDiff.changes = entityIDs.map { entityID in
                var resolved = change
                resolved.entityID = entityID
                return resolved
            }
        }

        let request = WorkoutMutationRequest(
            mutationID: UUID(),
            target: target,
            expectedRevisionToken: expected,
            actor: .agent,
            reason: reason,
            diff: resolvedDiff,
            dryRun: dryRun
        )
        let result: WorkoutMutationResult
        if let sink {
            result = sink.applyMutation(request, authoritative, dryRun ? nil : updatedLog)
        } else {
            let after = dryRun ? expected : UUID()
            let receipt = WorkoutMutationReceipt(
                mutationID: request.mutationID,
                scope: .transient,
                scheduledWorkoutID: nil,
                sessionID: nil,
                workoutID: authoritative.id,
                beforeRevisionToken: expected,
                afterRevisionToken: after,
                diff: resolvedDiff,
                actor: .agent,
                undoAvailable: !dryRun
            )
            result = dryRun ? .preview(receipt) : .applied(receipt)
        }

        switch result {
        case .applied(let receipt):
            if sink == nil {
                transientRevisionToken = receipt.afterRevisionToken
                invalidateLatestTransientUndo()
                latestTransientUndo = TransientMutationUndo(
                    receipt: receipt,
                    before: before,
                    purgedLogContent: currentLog.flatMap { beforeLog in
                        updatedLog.map { WorkoutLog.purgedContent(before: beforeLog, after: $0) }
                    } ?? WorkoutLogPurge()
                )
            }
            if scope == .session || displayWasAuthoritative { current = authoritative }
            if let updatedLog {
                // The sink already persisted the companion log write; adopt it without re-pushing.
                isSyncing = true
                currentLog = updatedLog
                isSyncing = false
            }
            pendingPlanEdit = nil
            return .mutated(receipt)
        case .preview(let receipt):
            return .mutated(receipt)
        case .rejected(.staleRevision):
            reloadFromPlan()
            return .notFound(Self.staleMutationMessage)
        case .rejected(.activeSessionConflict):
            return .notFound("That workout now has a conflicting active session, so I left it unchanged.")
        case .rejected(.persistenceFailure):
            reloadFromPlan()
            return .notFound("I couldn't save that workout edit, so I rolled it back and left the workout unchanged.")
        case .rejected:
            return .notFound(Self.missingPlanWorkout)
        }
    }

    func undoMutation(mutationID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        guard let sink else {
            guard let applied = latestTransientUndo, applied.receipt.mutationID == mutationID else {
                if staleTransientMutationIDs.contains(mutationID) {
                    return .notFound(Self.staleUndoMessage)
                }
                return .notFound("I couldn't find an undoable workout mutation with that id.")
            }
            guard applied.receipt.undoAvailable,
                  applied.receipt.afterRevisionToken == expectedRevisionToken,
                  transientRevisionToken == expectedRevisionToken,
                  let current,
                  current.id == applied.before.id else {
                return .notFound(Self.staleUndoMessage)
            }
            let undoRequest = WorkoutMutationRequest(
                mutationID: UUID(),
                target: WorkoutMutationTarget(
                    scope: .transient,
                    scheduledWorkoutID: nil,
                    sessionID: nil,
                    workoutID: current.id,
                    revisionToken: expectedRevisionToken
                ),
                expectedRevisionToken: expectedRevisionToken,
                actor: .agent,
                reason: "Undo transient workout mutation \(mutationID.uuidString)",
                diff: WorkoutMutationDiff(changes: [
                    .init(
                        kind: .edit,
                        summary: "Undo: \(applied.receipt.diff.changes.map(\.summary).joined(separator: "; "))",
                        entityID: current.id
                    ),
                ]),
                dryRun: false
            )
            let undoReceipt = WorkoutMutationReceipt(
                mutationID: undoRequest.mutationID,
                scope: .transient,
                scheduledWorkoutID: nil,
                sessionID: nil,
                workoutID: current.id,
                beforeRevisionToken: expectedRevisionToken,
                afterRevisionToken: applied.receipt.beforeRevisionToken,
                diff: undoRequest.diff,
                actor: .agent,
                undoAvailable: false
            )
            self.current = applied.before
            if !applied.purgedLogContent.isEmpty, var log = currentLog {
                log.restore(applied.purgedLogContent)
                currentLog = log
            }
            transientRevisionToken = undoReceipt.afterRevisionToken
            invalidateLatestTransientUndo()
            return .mutated(undoReceipt)
        }
        switch sink.undoMutation(mutationID, expectedRevisionToken) {
        case .applied(let receipt):
            reloadFromPlan()
            return .mutated(receipt)
        case .preview(let receipt):
            return .mutated(receipt)
        case .rejected(.activeSessionConflict):
            return .notFound("That workout has an active-session conflict, so I didn't undo it.")
        case .rejected(.staleRevision):
            reloadFromPlan()
            return .notFound(Self.staleUndoMessage)
        case .rejected(.sessionDiscarded):
            reloadFromPlan()
            return .notFound("That session was discarded, so its record is closed and I didn't undo anything in it.")
        case .rejected(.persistenceFailure):
            reloadFromPlan()
            return .notFound("I couldn't save that undo, so I rolled it back and left the workout unchanged.")
        case .rejected(.undoUnavailable):
            return .notFound("That mutation isn't eligible for another undo.")
        case .rejected:
            return .notFound("I couldn't find an undoable workout mutation with that id.")
        }
    }

    private static let missingPlanWorkout =
        "Today's workout isn't in your plan any more - it looks like it was deleted. Open the Plan tab and add one, and I'll pick it up from there."
    private static let staleMutationMessage =
        "That workout changed after I read it, so I left it untouched. Call get_current_workout again and retry with its new revision_token."
    private static let staleUndoMessage =
        "That edit is no longer the latest version, so I didn't undo newer work. Read the workout again before changing it."


    /// Whether the stored workout is for today. Unstamped (legacy) workouts count as today's; a
    /// workout from an earlier day must not be presented as "today's".
    var currentIsForToday: Bool {
        guard let date = current?.scheduledDate else { return true }
        return Calendar.current.isDateInToday(date)
    }

    // MARK: - Tool-facing operations (name-resolved)

    @discardableResult
    func updateWorkoutMetadata(
        title: MetadataPatch<String>,
        goal: MetadataPatch<String>,
        guidance: MetadataPatch<String>,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard !title.isUnchanged || !goal.isUnchanged || !guidance.isUnchanged else {
            return .notFound("Include at least one workout detail to change.")
        }
        guard title != .clear else {
            return .notFound("A workout title can't be cleared. Set a new title or omit it.")
        }
        let changes = metadataChanges(
            fields: [("workout title", title), ("workout goal", goal), ("workout guidance", guidance)],
            entityID: current?.id
        )
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Update workout metadata",
            diff: .init(changes: changes)
        ) { workout in
            if case .set(let value) = title { workout.rename(value) }
            switch goal {
            case .unchanged: break
            case .set(let value): workout.updateGoal(value)
            case .clear: workout.updateGoal(nil)
            }
            workout.updateGuidance(applyingGuidance(guidance, to: workout.guidance))
            return nil
        }
    }

    @discardableResult
    func updateBlockMetadata(
        blockID: UUID,
        name: MetadataPatch<String>,
        intent: MetadataPatch<String>,
        guidance: MetadataPatch<String>,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard !name.isUnchanged || !intent.isUnchanged || !guidance.isUnchanged else {
            return .notFound("Include at least one block detail to change.")
        }
        guard name != .clear else {
            return .notFound("A block name can't be cleared. Set a new name or omit it.")
        }
        let changes = metadataChanges(
            fields: [("block name", name), ("block intent", intent), ("block guidance", guidance)],
            entityID: blockID
        )
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Update block metadata",
            diff: .init(changes: changes)
        ) { workout in
            guard let block = workout.blocks.first(where: { $0.id == blockID }) else {
                return .notFound(missingTarget("block", name: "", id: blockID))
            }
            if case .set(let value) = name { _ = workout.renameBlock(blockID, to: value) }
            switch intent {
            case .unchanged: break
            case .set(let value): _ = workout.setBlockIntent(blockID, value)
            case .clear: _ = workout.setBlockIntent(blockID, nil)
            }
            _ = workout.setBlockGuidance(blockID, applyingGuidance(guidance, to: block.guidance))
            return nil
        }
    }

    @discardableResult
    func updateExerciseMetadata(
        exerciseInstanceID: UUID,
        displayLabel: MetadataPatch<String>,
        guidance: MetadataPatch<String>,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard !displayLabel.isUnchanged || !guidance.isUnchanged else {
            return .notFound("Include at least one exercise detail to change.")
        }
        let changes = metadataChanges(
            fields: [("exercise display label", displayLabel), ("exercise guidance", guidance)],
            entityID: exerciseInstanceID
        )
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Update exercise metadata",
            diff: .init(changes: changes)
        ) { workout in
            guard let exercise = workout.exercise(exerciseInstanceID) else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            guard workout.updateExercise(exerciseInstanceID, { updated in
                switch displayLabel {
                case .unchanged: break
                case .set(let value): updated.displayLabel = value
                case .clear: updated.displayLabel = nil
                }
                updated.guidance = applyingGuidance(guidance, to: exercise.guidance)
            }) else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            return nil
        }
    }

    private func metadataChanges(
        fields: [(String, MetadataPatch<String>)],
        entityID: UUID?
    ) -> [WorkoutMutationDiff.Change] {
        fields.compactMap { field, patch in
            switch patch {
            case .unchanged: nil
            case .set: .init(kind: .edit, summary: "Set \(field)", entityID: entityID)
            case .clear: .init(kind: .edit, summary: "Clear \(field)", entityID: entityID)
            }
        }
    }

    private func applyingGuidance(
        _ patch: MetadataPatch<String>,
        to current: CoachGuidance?
    ) -> CoachGuidance? {
        switch patch {
        case .unchanged:
            return current
        case .clear:
            return nil
        case .set(let value):
            return CoachGuidance(formCues: [value])
        }
    }

    /// Replace the workout wholesale. Refused while a plan-bound session's decision is open: the plan and
    /// the session copy would disagree, and the new exercise ids would match nothing in the log that is
    /// still open against the old shape. Returns false so callers can say so out loud. A standalone store
    /// has no session copy to contradict, so it keeps its long-standing replace-and-clear behavior.
    @discardableResult
    func create(title: String, goal: String?, expectedRevisionToken: UUID? = nil) -> EditOutcome {
        guard sink == nil || !hasUnresolvedSessionDecision else {
            return .notFound("You're partway through this workout, so I can't replace it — finish or discard the log first and I'll build the new one.")
        }
        var w = Workout(title: title, goal: goal)
        w.scheduledDate = Calendar.current.startOfDay(for: .now)
        w.blocks = [WorkoutBlock(name: "", isDefault: true)]   // implicit default block (hidden until structured)

        if sink != nil || current != nil {
            let outcome = mutate(
                expectedRevisionToken: expectedRevisionToken,
                reason: "Replace workout with \(title)",
                diff: .init(changes: [.init(kind: .replace, summary: "Replace workout with \(title)", entityID: current?.id)])
            ) { existing in
                w.id = existing.id
                existing = w
                return nil
            }
            if outcome.succeeded {
                isSyncing = true
                currentLog = nil
                currentLogStartedAt = nil
                isSyncing = false
            }
            return outcome
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

    private func invalidMetricValue(
        metric: MetricType,
        value: Double,
        exercise: PlannedExercise
    ) -> String? {
        guard exercise.supportedMetrics.contains(metric) else {
            return "\(exercise.exerciseName) doesn't support \(metric.label.lowercased())."
        }
        guard value.isFinite, value >= 0 else {
            return "\(metric.label) must be a finite value of zero or greater."
        }
        if metric == .rpe, value > 10 {
            return "RPE must be between 0 and 10."
        }
        if metric.isInteger, value.rounded() != value {
            return "\(metric.label) must be a whole number."
        }
        return nil
    }

    private func invalidEffortTarget(_ target: EffortTarget) -> String? {
        switch target {
        case .rpe(let value):
            guard value.isFinite, (0...10).contains(value) else {
                return "An RPE target must be between 0 and 10."
            }
        case .rir(let value):
            guard value.isFinite, (0...10).contains(value) else {
                return "A reps-in-reserve target must be between 0 and 10."
            }
        case .toFailure, .maxEffort:
            break
        }
        return nil
    }

    private func invalidTargets(
        _ targets: PlannedSetTargets,
        exercise: PlannedExercise
    ) -> String? {
        if let effort = targets.effort, let failure = invalidEffortTarget(effort) {
            return failure
        }
        for range in targets.ranges {
            if let failure = invalidMetricValue(
                metric: range.metric,
                value: range.lower,
                exercise: exercise
            ) {
                return failure
            }
            if let failure = invalidMetricValue(
                metric: range.metric,
                value: range.upper,
                exercise: exercise
            ) {
                return failure
            }
        }
        return nil
    }

    private func metricValues(_ values: PlannedSetValues) -> MetricValues {
        var result = MetricValues()
        for (metric, value) in values.metrics { result[metric] = value }
        return result
    }

    @discardableResult
    func addBlock(
        name: String,
        intent: String?,
        guidance: String? = nil,
        atIndex: Int? = nil,
        expectedRevisionToken: UUID? = nil
    ) -> EditOutcome {
        var affectedID: UUID?
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Add block \(name)",
            diff: .init(changes: [.init(kind: .add, summary: "Add block \(name)", entityID: nil)]),
            resolvedEntityIDs: { affectedID.map { [$0] } ?? [] }
        ) { workout in
            affectedID = workout.addBlock(
                name: name,
                intent: intent,
                guidance: guidance.map { CoachGuidance(formCues: [$0]) },
                at: atIndex
            )
            guard affectedID != nil else {
                return .notFound("Block position must be between 0 and \(workout.blocks.count).")
            }
            return nil
        }
    }

    @discardableResult
    func removeBlock(blockID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        var removedExerciseIDs: [UUID] = []
        var removedGroupIDs: Set<UUID> = []
        var removedChoiceIDs: Set<UUID> = []
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Remove block",
            diff: .init(changes: [.init(kind: .remove, summary: "Remove block", entityID: blockID)]),
            logTransform: { log in
                for exerciseID in removedExerciseIDs {
                    log.removePerformed(forPlanned: exerciseID)
                }
                log.removeGroups(forPlanned: removedGroupIDs)
                log.removeChoices(forPlanned: removedChoiceIDs)
            }
        ) { workout in
            guard let block = workout.blocks.first(where: { $0.id == blockID }) else {
                return .notFound(missingTarget("block", name: "", id: blockID))
            }
            removedExerciseIDs = block.exercises.map(\.id)
            removedGroupIDs = Set(block.groups.map(\.id))
            removedChoiceIDs = Set(block.choices.map(\.id))
            guard workout.removeBlock(blockID) else {
                return .notFound(missingTarget("block", name: "", id: blockID))
            }
            if workout.blocks.isEmpty {
                workout.blocks.append(WorkoutBlock(name: "", isDefault: true))
            }
            return nil
        }
    }

    @discardableResult
    func moveBlock(blockID: UUID, toIndex: Int, expectedRevisionToken: UUID) -> EditOutcome {
        mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Move block",
            diff: .init(changes: [.init(kind: .move, summary: "Move block", entityID: blockID)])
        ) { workout in
            guard workout.moveBlock(blockID, to: toIndex) else {
                return .notFound("The block doesn't exist or to_index is outside its final order.")
            }
            return nil
        }
    }

    @discardableResult
    func duplicateBlock(blockID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        var duplicateID: UUID?
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Duplicate block",
            diff: .init(changes: [.init(kind: .add, summary: "Duplicate block", entityID: nil)]),
            resolvedEntityIDs: { duplicateID.map { [$0] } ?? [] }
        ) { workout in
            guard let copiedID = workout.duplicateBlock(blockID) else {
                return .notFound(missingTarget("block", name: "", id: blockID))
            }
            duplicateID = copiedID
            return nil
        }
    }

    private func plannedExercise(
        name: String,
        sets: Int?,
        reps: Int?,
        load: Double?,
        durationSeconds: Int?,
        distanceMeters: Double?
    ) -> PlannedExercise {
        let count = max(1, sets ?? 1)
        var exercise = PlannedExercise(exerciseName: name)
        let definition = resolveDefinition(name)
        exercise.definitionId = definition.id == ExerciseCatalog.generic.id ? nil : definition.id
        var selected = Set(preferences.selectedByExercise[definition.id] ?? definition.defaults)
        if reps != nil { selected.insert(.reps) }
        if load != nil { selected.insert(.load) }
        if durationSeconds != nil { selected.insert(.duration) }
        if distanceMeters != nil { selected.insert(.distance) }
        if selected.isEmpty { selected = [.reps, .load] }
        exercise.selectedMetrics = MetricType.allCases.filter { selected.contains($0) }
        exercise.prescription.sets = (0..<count).map { _ in
            PlannedSet(
                reps: clampReps(reps),
                load: clampLoad(load),
                duration: clampDuration(durationSeconds),
                distance: clampLoad(distanceMeters)
            )
        }
        return exercise
    }

    @discardableResult
    func addExercise(
        name: String,
        toBlockID blockID: UUID,
        atIndex: Int?,
        sets: Int?,
        reps: Int?,
        load: Double?,
        durationSeconds: Int?,
        distanceMeters: Double? = nil,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        var recentDefinitionID: String?
        var affectedID: UUID?
        let outcome = mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Add \(name) to block",
            diff: .init(changes: [.init(kind: .add, summary: "Add \(name) to block", entityID: nil)]),
            resolvedEntityIDs: { affectedID.map { [$0] } ?? [] }
        ) { workout in
            guard let block = workout.blocks.first(where: { $0.id == blockID }) else {
                return .notFound(missingTarget("block", name: "", id: blockID))
            }
            let exercise = plannedExercise(
                name: name,
                sets: sets,
                reps: reps,
                load: load,
                durationSeconds: durationSeconds,
                distanceMeters: distanceMeters
            )
            guard workout.addExercise(exercise, toBlock: blockID, at: atIndex) else {
                return .notFound("Exercise position must be between 0 and \(block.nodes.count).")
            }
            recentDefinitionID = exercise.definitionId
            affectedID = exercise.id
            return nil
        }
        if outcome.succeeded, let recentDefinitionID { noteRecent(recentDefinitionID) }
        return outcome
    }

    @discardableResult
    func moveExercise(
        exerciseInstanceID: UUID,
        toBlockID: UUID,
        toIndex: Int,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        var removedChoiceOptionIDs: Set<UUID> = []
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Move exercise",
            diff: .init(changes: [
                .init(kind: .move, summary: "Move exercise", entityID: exerciseInstanceID),
            ]),
            logTransform: { log in
                log.removeChoiceSelections(optionIDs: removedChoiceOptionIDs)
            }
        ) { workout in
            guard workout.exercise(exerciseInstanceID) != nil else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            guard workout.blocks.contains(where: { $0.id == toBlockID }) else {
                return .notFound(missingTarget("block", name: "", id: toBlockID))
            }
            removedChoiceOptionIDs = Set(
                workout.choiceOptionIDs(containingExercise: exerciseInstanceID)
            )
            guard workout.moveExercise(exerciseInstanceID, toBlock: toBlockID, at: toIndex) else {
                return .notFound("to_index is outside the destination block's final order.")
            }
            return nil
        }
    }

    @discardableResult
    func removeExercise(
        exerciseInstanceID: UUID,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        var removedChoiceOptionIDs: Set<UUID> = []
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Remove exercise",
            diff: .init(changes: [
                .init(kind: .remove, summary: "Remove exercise", entityID: exerciseInstanceID),
            ]),
            logTransform: { log in
                log.removePerformed(forPlanned: exerciseInstanceID)
                log.removeChoiceSelections(optionIDs: removedChoiceOptionIDs)
            }
        ) { workout in
            removedChoiceOptionIDs = Set(
                workout.choiceOptionIDs(containingExercise: exerciseInstanceID)
            )
            guard workout.removeExercise(exerciseInstanceID) else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            return nil
        }
    }

    @discardableResult
    func reorderExercise(
        exerciseInstanceID: UUID,
        toIndex: Int,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Reorder exercise",
            diff: .init(changes: [
                .init(kind: .move, summary: "Reorder exercise", entityID: exerciseInstanceID),
            ])
        ) { workout in
            guard workout.reorderExercise(exerciseInstanceID, to: toIndex) else {
                return .notFound("The exercise doesn't exist or to_index is outside its container.")
            }
            return nil
        }
    }

    @discardableResult
    func duplicateExercise(
        exerciseInstanceID: UUID,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        var duplicateID: UUID?
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Duplicate exercise",
            diff: .init(changes: [.init(kind: .add, summary: "Duplicate exercise", entityID: nil)]),
            resolvedEntityIDs: { duplicateID.map { [$0] } ?? [] }
        ) { workout in
            guard let copiedID = workout.duplicateExercise(exerciseInstanceID) else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            duplicateID = copiedID
            return nil
        }
    }

    @discardableResult
    func replaceExercise(
        exerciseInstanceID: UUID,
        with replacement: String,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        var recentDefinitionID: String?
        let outcome = mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Replace exercise with \(replacement)",
            diff: .init(changes: [
                .init(kind: .replace, summary: "Replace exercise with \(replacement)", entityID: exerciseInstanceID),
            ])
        ) { workout in
            guard workout.exercise(exerciseInstanceID) != nil else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            let definition = resolveDefinition(replacement)
            guard definition.id != ExerciseCatalog.generic.id else {
                return .notFound("I couldn't find \"\(replacement)\" in the exercise catalog.")
            }
            guard applyReplacement(definition, to: exerciseInstanceID, in: &workout) else {
                return .notFound("I couldn't replace that exercise.")
            }
            recentDefinitionID = definition.id
            return nil
        }
        if outcome.succeeded, let recentDefinitionID { noteRecent(recentDefinitionID) }
        return outcome
    }

    @discardableResult
    func addSet(
        exerciseInstanceID: UUID,
        afterSetID: UUID?,
        values: PlannedSetValues,
        role: SetRole,
        targets: PlannedSetTargets,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        var addedSetID: UUID?
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Add planned set",
            diff: .init(changes: [.init(kind: .add, summary: "Add planned set", entityID: nil)]),
            resolvedEntityIDs: { addedSetID.map { [$0] } ?? [] }
        ) { workout in
            guard let exercise = workout.exercise(exerciseInstanceID) else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            if let afterSetID, exercise.prescription.sets.contains(where: { $0.id == afterSetID }) == false {
                return .notFound(missingTarget("set", name: "", id: afterSetID))
            }
            for (metric, value) in values.metrics {
                if let failure = invalidMetricValue(metric: metric, value: value, exercise: exercise) {
                    return .notFound(failure)
                }
            }
            if let failure = invalidTargets(targets, exercise: exercise) {
                return .notFound(failure)
            }

            let newSet = PlannedSet(
                values: metricValues(values),
                role: role,
                effortTarget: targets.effort,
                ranges: targets.ranges
            )
            guard workout.addSet(newSet, toExercise: exerciseInstanceID) else {
                return .notFound("I couldn't add that planned set.")
            }
            if let afterSetID,
               let sourceIndex = exercise.prescription.sets.firstIndex(where: { $0.id == afterSetID }),
               workout.moveSet(newSet.id, to: .index(sourceIndex + 1)) == false {
                return .notFound("I couldn't place that planned set after its target.")
            }
            _ = workout.updateExercise(exerciseInstanceID) { updated in
                let addedMetrics = Set(values.metrics.keys).union(targets.ranges.map(\.metric))
                updated.selectedMetrics = MetricType.allCases.filter {
                    updated.selectedMetrics.contains($0) || addedMetrics.contains($0)
                }
            }
            addedSetID = newSet.id
            return nil
        }
    }

    @discardableResult
    func updateSet(
        setID: UUID,
        patch: PlannedSetPatch,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard patch.isUnchanged == false else {
            return .notFound("Include at least one planned-set field to change.")
        }
        guard patch.role != .clear else {
            return .notFound("A planned set role can't be cleared. Set a role or omit it.")
        }
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Update planned set",
            diff: .init(changes: [.init(kind: .edit, summary: "Update planned set", entityID: setID)])
        ) { workout in
            guard let exercise = workout.allExercises.first(where: { exercise in
                exercise.prescription.sets.contains { $0.id == setID }
            }) else {
                return .notFound(missingTarget("set", name: "", id: setID))
            }

            var addedMetrics: Set<MetricType> = []
            if case .set(let valuesPatch) = patch.values {
                for (metric, metricPatch) in valuesPatch.metrics {
                    if case .set(let value) = metricPatch,
                       let failure = invalidMetricValue(metric: metric, value: value, exercise: exercise) {
                        return .notFound(failure)
                    }
                    if case .set = metricPatch { addedMetrics.insert(metric) }
                }
            }
            if case .set(let targetsPatch) = patch.targets {
                if case .set(let effort) = targetsPatch.effort,
                   let failure = invalidEffortTarget(effort) {
                    return .notFound(failure)
                }
                if case .set(let ranges) = targetsPatch.ranges,
                   let failure = invalidTargets(.init(ranges: ranges), exercise: exercise) {
                    return .notFound(failure)
                }
                if case .set(let ranges) = targetsPatch.ranges {
                    addedMetrics.formUnion(ranges.map(\.metric))
                }
            }

            guard workout.updateSet(setID, { updated in
                switch patch.values {
                case .unchanged:
                    break
                case .clear:
                    updated.values = MetricValues()
                case .set(let valuesPatch):
                    for (metric, metricPatch) in valuesPatch.metrics {
                        switch metricPatch {
                        case .unchanged: break
                        case .set(let value): updated.values[metric] = value
                        case .clear: updated.values[metric] = nil
                        }
                    }
                }
                if case .set(let role) = patch.role { updated.role = role }
                switch patch.targets {
                case .unchanged:
                    break
                case .clear:
                    updated.effortTarget = nil
                    updated.ranges = []
                case .set(let targetsPatch):
                    switch targetsPatch.effort {
                    case .unchanged: break
                    case .set(let effort): updated.effortTarget = effort
                    case .clear: updated.effortTarget = nil
                    }
                    switch targetsPatch.ranges {
                    case .unchanged: break
                    case .set(let ranges): updated.ranges = ranges
                    case .clear: updated.ranges = []
                    }
                }
            }) else {
                return .notFound(missingTarget("set", name: "", id: setID))
            }
            if addedMetrics.isEmpty == false {
                _ = workout.updateExercise(exercise.id) { updated in
                    updated.selectedMetrics = MetricType.allCases.filter {
                        updated.selectedMetrics.contains($0) || addedMetrics.contains($0)
                    }
                }
            }
            return nil
        }
    }

    @discardableResult
    func removeSet(setID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        var ownerID: UUID?
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Remove planned set",
            diff: .init(changes: [.init(kind: .remove, summary: "Remove planned set", entityID: setID)]),
            logTransform: { log in
                guard let ownerID else { return }
                log.removeSetLogs(forPlanned: ownerID, plannedSetIDs: [setID])
            }
        ) { workout in
            guard let exercise = workout.allExercises.first(where: { exercise in
                exercise.prescription.sets.contains { $0.id == setID }
            }) else {
                return .notFound(missingTarget("set", name: "", id: setID))
            }
            guard workout.removeSet(setID) else {
                return .notFound("I couldn't remove that planned set.")
            }
            ownerID = exercise.id
            return nil
        }
    }

    @discardableResult
    func moveSet(
        setID: UUID,
        beforeSetID: UUID?,
        toIndex: Int?,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard (beforeSetID != nil) != (toIndex != nil) else {
            return .notFound("Move a set with exactly one of before_set_id or to_index.")
        }
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Move planned set",
            diff: .init(changes: [.init(kind: .move, summary: "Move planned set", entityID: setID)])
        ) { workout in
            let destination = beforeSetID.map(PlannedSetMoveDestination.before)
                ?? toIndex.map(PlannedSetMoveDestination.index)
            guard let destination, workout.moveSet(setID, to: destination) else {
                return .notFound("The set or its destination doesn't exist in the same exercise.")
            }
            return nil
        }
    }

    @discardableResult
    func duplicateSet(setID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        var duplicateID: UUID?
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Duplicate planned set",
            diff: .init(changes: [.init(kind: .add, summary: "Duplicate planned set", entityID: nil)]),
            resolvedEntityIDs: { duplicateID.map { [$0] } ?? [] }
        ) { workout in
            guard let copiedID = workout.duplicateSet(setID) else {
                return .notFound(missingTarget("set", name: "", id: setID))
            }
            duplicateID = copiedID
            return nil
        }
    }

    // MARK: - Logging configuration & values (metric system)

    /// ID-only agent surface for this workout's logging metrics and display units.
    /// Unit changes never rewrite any canonical planned-set value.
    @discardableResult
    func setLoggingConfig(
        exerciseInstanceID: UUID,
        enabled: [MetricType]?,
        units: [MetricType: MetricUnit] = [:],
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard enabled != nil || units.isEmpty == false else {
            return .notFound("Include enabled_metrics or at least one display unit to change.")
        }
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Update exercise logging configuration",
            diff: .init(changes: [
                .init(
                    kind: .edit,
                    summary: "Update exercise logging configuration",
                    entityID: exerciseInstanceID
                ),
            ])
        ) { workout in
            guard let exercise = workout.exercise(exerciseInstanceID) else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            let requested = (enabled ?? []) + Array(units.keys)
            if let unsupported = requested.first(where: { !exercise.supportedMetrics.contains($0) }) {
                return .notFound("\(exercise.exerciseName) doesn't support \(unsupported.label.lowercased()).")
            }
            if let invalidUnit = units.first(where: { metric, unit in
                metric.displayUnits.contains(unit) == false
            }) {
                return .notFound("\(invalidUnit.value.short) isn't a display unit for \(invalidUnit.key.label.lowercased()).")
            }
            guard workout.updateExercise(exerciseInstanceID, { updated in
                if let enabled {
                    updated.selectedMetrics = MetricType.allCases.filter { enabled.contains($0) }
                }
                for (metric, unit) in units { updated.displayUnits[metric] = unit }
            }) else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            return nil
        }
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
    func requireAllOptions(
        choiceNamed name: String,
        expectedRevisionToken: UUID? = nil
    ) -> EditOutcome {
        var affectedID: UUID?
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Require all options in \(name)",
            diff: .init(changes: [.init(kind: .replace, summary: "Require all options in \(name)", entityID: nil)]),
            resolvedEntityIDs: { affectedID.map { [$0] } ?? [] }
        ) { workout in
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let choices = workout.allChoices
            let exact = choices.filter { $0.label.localizedCaseInsensitiveCompare(key) == .orderedSame }
            let matches = exact.isEmpty
                ? choices.filter { $0.label.localizedCaseInsensitiveContains(key) }
                : exact
            guard !matches.isEmpty else {
                return .notFound("I couldn't find a choice matching \"\(name)\".")
            }
            guard matches.count == 1, let choice = matches.first else {
                return .ambiguous(
                    "There are \(matches.count) choices matching \"\(name)\": "
                        + "\(matches.map(\.label).joined(separator: ", ")). Which one?"
                )
            }
            guard workout.convertChoiceToRequiredGroup(choice.id) else {
                return .notFound("I couldn't update \"\(choice.label)\".")
            }
            affectedID = choice.id
            return nil
        }
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

    /// Set one canonical metric value using stable exercise and set IDs from the same workout read.
    /// The value arrives in `unit` and is stored canonically; an omitted unit means the storage unit,
    /// as described by the tool schema. Ensures the metric is selected/visible.
    @discardableResult
    func setMetricValue(
        exerciseInstanceID: UUID,
        setID: UUID,
        metric: MetricType,
        value: Double,
        unit: MetricUnit?,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Set \(metric.label) on planned set",
            diff: .init(changes: [
                .init(
                    kind: .edit,
                    summary: "Set \(metric.label) on planned set",
                    entityID: setID
                ),
            ])
        ) { workout in
            guard let exercise = workout.exercise(exerciseInstanceID) else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            guard exercise.prescription.sets.contains(where: { $0.id == setID }) else {
                return .notFound("That set doesn't belong to the targeted exercise instance.")
            }
            if let unit, metric.parsableUnits.contains(unit) == false {
                return .notFound("\(unit.short) isn't a valid input unit for \(metric.label.lowercased()).")
            }
            let canonical = MetricConvert.toCanonical(
                value,
                metric,
                from: unit ?? metric.canonicalUnit // units:storage
            )
            if let failure = invalidMetricValue(metric: metric, value: canonical, exercise: exercise) {
                return .notFound(failure)
            }
            guard workout.updateExercise(exerciseInstanceID, { updated in
                guard let index = updated.prescription.sets.firstIndex(where: { $0.id == setID }) else {
                    return
                }
                updated.prescription.sets[index].values[metric] = canonical
                if updated.selectedMetrics.contains(metric) == false {
                    updated.selectedMetrics = MetricType.allCases.filter {
                        updated.selectedMetrics.contains($0) || $0 == metric
                    }
                }
            }) else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            return nil
        }
    }

    /// Remove a metric from an exercise this workout — unselect it and clear its values.
    @discardableResult
    func removeMetric(
        exerciseInstanceID: UUID,
        metric: MetricType,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        return mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Remove \(metric.label) from exercise",
            diff: .init(changes: [
                .init(
                    kind: .remove,
                    summary: "Remove \(metric.label) from exercise",
                    entityID: exerciseInstanceID
                ),
            ])
        ) { workout in
            guard workout.exercise(exerciseInstanceID) != nil else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            guard workout.updateExercise(exerciseInstanceID, { updated in
                updated.selectedMetrics.removeAll { $0 == metric }
                updated.displayUnits[metric] = nil
                for index in updated.prescription.sets.indices {
                    updated.prescription.sets[index].values[metric] = nil
                }
            }) else {
                return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
            }
            return nil
        }
    }

    // MARK: - Performed-log tools

    private struct ExerciseSessionContext {
        var exercise: PlannedExercise
        var groupID: UUID?
        var iteration: Int?
    }

    private enum PerformedValuesResult {
        case success([MetricType: Double])
        case failure(String)
    }

    /// The active session payload and all IDs the model needs to target actual work precisely.
    func activeSessionSnapshot() -> ActiveSessionToolSnapshot? {
        guard let sink,
              let session = sink.activeSession(),
              let workout = session.workout ?? current,
              let sessionTarget = mutationTarget(.session),
              let logTarget = sink.performedLogMutationTarget(),
              let scheduledID = logTarget.scheduledWorkoutID,
              let sessionID = logTarget.sessionID,
              sessionID == session.id else { return nil }

        let contexts = exerciseSessionContexts(in: workout, log: session.log)
        var orderedExerciseIDs: [UUID] = []
        for context in contexts where !orderedExerciseIDs.contains(context.exercise.id) {
            orderedExerciseIDs.append(context.exercise.id)
        }

        let exercises = orderedExerciseIDs.compactMap { exerciseID -> ActiveSessionToolSnapshot.Exercise? in
            guard let exercise = contexts.first(where: { $0.exercise.id == exerciseID })?.exercise else { return nil }
            let performed = session.log.performed(forPlanned: exerciseID)
            let targets = contexts.filter { $0.exercise.id == exerciseID }.flatMap { context in
                exercise.prescription.sets.map { set in
                    let actual = session.log.setLog(
                        forPlanned: exerciseID,
                        plannedSetID: set.id,
                        groupID: context.groupID,
                        iteration: context.iteration
                    )
                    return ActiveSessionToolSnapshot.PlannedSetTarget(
                        plannedSetID: set.id,
                        groupID: context.groupID,
                        iteration: context.iteration,
                        plannedValues: set.expectedValues(iteration: context.iteration ?? 1),
                        performedSetID: actual?.id,
                        performedValues: actual?.values ?? MetricValues(),
                        outcome: actual?.outcome ?? .pending
                    )
                }
            }
            let extraSets = (performed?.setLogs ?? []).filter { $0.plannedSetID == nil }.map { set in
                ActiveSessionToolSnapshot.ExtraPerformedSet(
                    performedSetID: set.id,
                    groupID: set.groupID,
                    iteration: set.iteration,
                    values: set.values,
                    outcome: set.outcome
                )
            }
            return ActiveSessionToolSnapshot.Exercise(
                exerciseInstanceID: exercise.id,
                catalogDefinitionID: exercise.definitionId,
                name: exercise.exerciseName,
                selectedMetrics: exercise.selectedMetrics,
                plannedSets: targets,
                extraPerformedSets: extraSets,
                notes: performed?.athleteNotes ?? []
            )
        }

        return ActiveSessionToolSnapshot(
            scope: .performedLog,
            scheduledWorkoutID: scheduledID,
            sessionID: sessionID,
            workoutID: logTarget.workoutID,
            workoutLogID: session.log.id,
            sessionStatus: session.status,
            startedAt: session.startedAt,
            sessionWorkoutRevisionToken: sessionTarget.revisionToken,
            performedLogRevisionToken: logTarget.revisionToken,
            exercises: exercises
        )
    }

    func upsertPerformedSet(
        exerciseInstanceID: UUID,
        plannedSetID: UUID,
        groupID: UUID?,
        iteration: Int?,
        values: [PerformedMetricInput],
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard let workout = current,
              let context = plannedSetContext(
                  exerciseInstanceID: exerciseInstanceID,
                  plannedSetID: plannedSetID,
                  groupID: groupID,
                  iteration: iteration,
                  workout: workout
              ) else {
            return .notFound("I couldn't find that planned set, group, and iteration in the active session.")
        }
        switch parsedPerformedValues(values, for: context.exercise) {
        case .failure(let message):
            return .notFound(message)
        case .success(let parsed):
            return mutatePerformedLog(
                expectedRevisionToken: expectedRevisionToken,
                reason: "Log actual values for \(context.exercise.exerciseName)",
                diff: .init(changes: [
                    .init(kind: .edit, summary: "Log actual values for \(context.exercise.exerciseName)", entityID: plannedSetID),
                ])
            ) { log in
                log.upsertSetLog(
                    forPlanned: exerciseInstanceID,
                    name: context.exercise.exerciseName,
                    plannedSetID: plannedSetID,
                    groupID: groupID,
                    iteration: iteration
                ) { actual in
                    for (metric, value) in parsed { actual.values[metric] = value }
                }
                return nil
            }
        }
    }

    func setPerformedSetOutcome(
        target: PerformedSetTarget,
        outcome: SetLogOutcome,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard let workout = current else { return .notFound("There isn't an active session to log.") }
        switch target {
        case .planned(let exerciseID, let setID, let groupID, let iteration):
            guard let context = plannedSetContext(
                exerciseInstanceID: exerciseID,
                plannedSetID: setID,
                groupID: groupID,
                iteration: iteration,
                workout: workout
            ) else {
                return .notFound("I couldn't find that planned set, group, and iteration in the active session.")
            }
            return mutatePerformedLog(
                expectedRevisionToken: expectedRevisionToken,
                reason: "Set \(context.exercise.exerciseName) outcome to \(outcome.rawValue)",
                diff: .init(changes: [
                    .init(kind: .edit, summary: "Set performed-set outcome to \(outcome.rawValue)", entityID: setID),
                ])
            ) { log in
                log.upsertSetLog(
                    forPlanned: exerciseID,
                    name: context.exercise.exerciseName,
                    plannedSetID: setID,
                    groupID: groupID,
                    iteration: iteration
                ) { $0.outcome = outcome }
                return nil
            }
        case .extra(let performedSetID):
            guard extraSetContext(performedSetID: performedSetID, workout: workout) != nil else {
                return .notFound("I couldn't find that extra performed set in the active session.")
            }
            return mutatePerformedLog(
                expectedRevisionToken: expectedRevisionToken,
                reason: "Set extra performed-set outcome to \(outcome.rawValue)",
                diff: .init(changes: [
                    .init(kind: .edit, summary: "Set extra performed-set outcome to \(outcome.rawValue)", entityID: performedSetID),
                ])
            ) { log in
                log.updateSetLog(performedSetID) { $0.outcome = outcome }
                return nil
            }
        }
    }

    func addExtraPerformedSet(
        exerciseInstanceID: UUID,
        groupID: UUID?,
        iteration: Int?,
        values: [PerformedMetricInput],
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard let workout = current,
              let context = exerciseSessionContexts(in: workout, log: currentLog ?? WorkoutLog()).first(where: {
                  $0.exercise.id == exerciseInstanceID && $0.groupID == groupID && $0.iteration == iteration
              }) else {
            return .notFound("I couldn't find that exercise, group, and iteration in the active session.")
        }
        let parsedResult = parsedPerformedValues(values, for: context.exercise)
        guard case .success(let parsed) = parsedResult else {
            if case .failure(let message) = parsedResult { return .notFound(message) }
            return .notFound("I couldn't interpret those performed values.")
        }
        var metricValues = MetricValues()
        for (metric, value) in parsed { metricValues[metric] = value }
        let extra = SetLog(
            plannedSetID: nil,
            groupID: groupID,
            iteration: iteration,
            values: metricValues
        )
        return mutatePerformedLog(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Add extra performed set for \(context.exercise.exerciseName)",
            diff: .init(changes: [
                .init(kind: .add, summary: "Add extra performed set for \(context.exercise.exerciseName)", entityID: extra.id),
            ])
        ) { log in
            log.logSet(extra, forPlanned: exerciseInstanceID, name: context.exercise.exerciseName)
            return nil
        }
    }

    func updateExtraPerformedSet(
        performedSetID: UUID,
        values: [PerformedMetricInput],
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard let workout = current,
              let context = extraSetContext(performedSetID: performedSetID, workout: workout) else {
            return .notFound("I couldn't find that extra performed set in the active session.")
        }
        switch parsedPerformedValues(values, for: context.exercise) {
        case .failure(let message):
            return .notFound(message)
        case .success(let parsed):
            return mutatePerformedLog(
                expectedRevisionToken: expectedRevisionToken,
                reason: "Update extra performed set for \(context.exercise.exerciseName)",
                diff: .init(changes: [
                    .init(kind: .edit, summary: "Update extra performed set for \(context.exercise.exerciseName)", entityID: performedSetID),
                ])
            ) { log in
                log.updateSetLog(performedSetID) { actual in
                    for (metric, value) in parsed { actual.values[metric] = value }
                }
                return nil
            }
        }
    }

    func deleteExtraPerformedSet(
        performedSetID: UUID,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard let workout = current,
              extraSetContext(performedSetID: performedSetID, workout: workout) != nil else {
            return .notFound("I couldn't find that extra performed set in the active session.")
        }
        return mutatePerformedLog(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Delete extra performed set",
            diff: .init(changes: [
                .init(kind: .remove, summary: "Delete extra performed set", entityID: performedSetID),
            ])
        ) { log in
            log.removeSetLog(performedSetID)
            return nil
        }
    }

    func addExerciseSessionNote(
        exerciseInstanceID: UUID,
        note: String,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound("The exercise session note can't be empty.") }
        guard let exercise = current?.exercise(exerciseInstanceID) else {
            return .notFound("I couldn't find that exercise in the active session.")
        }
        return mutatePerformedLog(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Add session note for \(exercise.exerciseName)",
            diff: .init(changes: [
                .init(kind: .add, summary: "Add session note for \(exercise.exerciseName)", entityID: exerciseInstanceID),
            ])
        ) { log in
            log.addNote(trimmed, forPlanned: exerciseInstanceID, name: exercise.exerciseName)
            return nil
        }
    }

    func undoSessionMutation(mutationID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        guard let sink else { return .notFound("Session mutation undo isn't available in this context.") }
        switch sink.undoSessionMutation(mutationID, expectedRevisionToken) {
        case .applied(let receipt):
            reloadFromPlan()
            return .mutated(receipt)
        case .preview(let receipt):
            return .mutated(receipt)
        case .rejected(.staleRevision):
            reloadFromPlan()
            return .notFound(Self.staleUndoMessage)
        case .rejected(.sessionDiscarded):
            reloadFromPlan()
            return .notFound("That session was discarded, so I didn't undo anything in it.")
        case .rejected(.persistenceFailure):
            reloadFromPlan()
            return .notFound("I couldn't save that undo, so I left the session unchanged.")
        case .rejected(.undoUnavailable):
            return .notFound("That session mutation isn't eligible for another undo.")
        case .rejected:
            return .notFound("I couldn't find an undoable session mutation with that id.")
        }
    }

    private func mutatePerformedLog(
        expectedRevisionToken: UUID,
        reason: String,
        diff: WorkoutMutationDiff,
        transform: (inout WorkoutLog) -> String?
    ) -> EditOutcome {
        guard let sink, let target = sink.performedLogMutationTarget(), var log = currentLog else {
            return .notFound("There isn't an active session to log.")
        }
        guard target.revisionToken == expectedRevisionToken else {
            reloadFromPlan()
            return .notFound(Self.staleMutationMessage)
        }
        let before = log
        if let message = transform(&log) { return .notFound(message) }
        guard log != before else { return .notFound("That performed log already has this value, so nothing changed.") }

        let request = WorkoutMutationRequest(
            mutationID: UUID(),
            target: target,
            expectedRevisionToken: expectedRevisionToken,
            actor: .agent,
            reason: reason,
            diff: diff,
            dryRun: false
        )
        switch editLog(request: request, replacingWith: log) {
        case .applied(let receipt):
            return .mutated(receipt)
        case .preview(let receipt):
            return .mutated(receipt)
        case .rejected(.staleRevision):
            reloadFromPlan()
            return .notFound(Self.staleMutationMessage)
        case .rejected(.sessionDiscarded):
            reloadFromPlan()
            return .notFound("That session was discarded, so its performed log is closed.")
        case .rejected(.persistenceFailure):
            reloadFromPlan()
            return .notFound("I couldn't save that performed-set edit, so I left the session unchanged.")
        case .rejected:
            reloadFromPlan()
            return .notFound("I couldn't apply that performed-set edit to the active session.")
        }
    }

    /// Receipt-backed counterpart to the direct-control `editLog` method.
    /// The repository performs the write, revision advance, and history append atomically.
    private func editLog(
        request: WorkoutMutationRequest,
        replacingWith log: WorkoutLog
    ) -> WorkoutMutationResult {
        guard let sink else { return .rejected(.invalidTarget) }
        let result = sink.applyLogMutation(request, log)
        if case .applied = result {
            isSyncing = true
            currentLog = log
            isSyncing = false
        }
        return result
    }

    private func parsedPerformedValues(
        _ inputs: [PerformedMetricInput],
        for exercise: PlannedExercise
    ) -> PerformedValuesResult {
        guard !inputs.isEmpty else { return .failure("At least one performed metric value is required.") }
        var parsed: [MetricType: Double] = [:]
        for input in inputs {
            guard parsed[input.metric] == nil else {
                return .failure("Each performed metric can appear only once in one tool call.")
            }
            guard exercise.selectedMetrics.contains(input.metric) else {
                return .failure("\(exercise.exerciseName) isn't configured to log \(input.metric.label.lowercased()).")
            }
            guard let value = ImportQuantityParser.canonicalValue(
                for: input.metric,
                valueText: input.valueText
            ) else {
                return .failure(quantityCorrection(metric: input.metric, valueText: input.valueText))
            }
            parsed[input.metric] = value
        }
        return .success(parsed)
    }

    private func quantityCorrection(metric: MetricType, valueText: String) -> String {
        let example: String
        switch metric {
        case .load: example = "185 lb or 84 kg"
        case .distance: example = "400 m or 1 mi"
        case .duration, .heartRateZoneTime: example = "1:19 or 79 seconds"
        case .pace: example = "1:19 per 400 m or 4:30 per km"
        case .heartRate: example = "150 bpm"
        case .cadence: example = "90 rpm"
        case .power: example = "250 watts"
        case .calories: example = "20 cal"
        case .reps: example = "8 reps"
        case .rpe: example = "RPE 8"
        }
        return "I couldn't interpret \"\(valueText)\" as \(metric.label.lowercased()). Include an unambiguous value such as \(example)."
    }

    private func plannedSetContext(
        exerciseInstanceID: UUID,
        plannedSetID: UUID,
        groupID: UUID?,
        iteration: Int?,
        workout: Workout
    ) -> (exercise: PlannedExercise, set: PlannedSet)? {
        guard let context = exerciseSessionContexts(in: workout, log: currentLog ?? WorkoutLog()).first(where: {
            $0.exercise.id == exerciseInstanceID && $0.groupID == groupID && $0.iteration == iteration
        }), let set = context.exercise.prescription.sets.first(where: { $0.id == plannedSetID }) else {
            return nil
        }
        return (context.exercise, set)
    }

    private func extraSetContext(
        performedSetID: UUID,
        workout: Workout
    ) -> (exercise: PlannedExercise, set: SetLog)? {
        guard let log = currentLog else { return nil }
        for performed in log.exercises {
            guard let set = performed.setLogs.first(where: {
                $0.id == performedSetID && $0.plannedSetID == nil
            }), let exerciseID = performed.plannedExerciseID,
                  let context = exerciseSessionContexts(in: workout, log: log).first(where: {
                      $0.exercise.id == exerciseID && $0.groupID == set.groupID && $0.iteration == set.iteration
                  }) else { continue }
            return (context.exercise, set)
        }
        return nil
    }

    private func exerciseSessionContexts(in workout: Workout, log: WorkoutLog) -> [ExerciseSessionContext] {
        let selections = Dictionary(uniqueKeysWithValues: log.choices.map {
            ($0.plannedChoiceID, Set($0.selectedOptionIDs))
        })
        var result: [ExerciseSessionContext] = []

        func selectedOptions(_ choice: WorkoutChoice) -> [WorkoutNode] {
            let selected = selections[choice.id] ?? Set(choice.options.prefix(choice.selectionCount).map(\.id))
            return choice.options.filter { selected.contains($0.id) }
        }

        func appendTopLevel(_ nodes: [WorkoutNode]) {
            for node in nodes {
                switch node {
                case .exercise(let exercise):
                    result.append(.init(exercise: exercise, groupID: nil, iteration: nil))
                case .rest:
                    break
                case .choice(let choice):
                    appendTopLevel(selectedOptions(choice))
                case .group(let group):
                    guard group.execution.isRepeated else {
                        appendTopLevel(group.children)
                        continue
                    }
                    for iteration in 1...group.iterationCount(log: log, isLogging: true) {
                        let exercises = group.exercises(forIteration: iteration, choiceSelections: selections)
                        result.append(contentsOf: exercises.map {
                            .init(exercise: $0, groupID: group.id, iteration: iteration)
                        })
                    }
                }
            }
        }

        for block in workout.blocks { appendTopLevel(block.nodes) }
        return result
    }

    // MARK: - Read

    /// A cheap **index** of the workout this scope describes, for the always-sent context — ID, title,
    /// status, counts, date — WITHOUT the exercise/set detail. Detail is fetched on demand via
    /// get_current_workout, so a 30-exercise workout doesn't inflate every chat request.
    func compactSummary(_ scope: WorkoutEditScope) -> String? {
        guard let w = workout(scope), let target = mutationTarget(scope) else { return nil }
        let status = currentLog == nil ? "not started" : (currentLog?.isComplete == true ? "completed" : "in progress")
        let isForToday = w.scheduledDate.map { Calendar.current.isDateInToday($0) } ?? true
        let date: String = isForToday ? "today"
            : (w.scheduledDate.map { $0.formatted(.dateTime.month().day()) } ?? "unscheduled")
        let exercises = w.allExercises.count
        let blocks = w.blocks.filter { !$0.isDefault || !$0.exercises.isEmpty }.count
        return """
        - ID: \(w.id.uuidString)
        - Scope: \(target.scope.rawValue)
        - Revision token: \(target.revisionToken.uuidString)
        - Title: \(w.title)
        - Status: \(status)
        - \(blocks) block\(blocks == 1 ? "" : "s")
        - \(exercises) exercise\(exercises == 1 ? "" : "s")
        - Scheduled: \(date)
        """
    }

    /// The active session id (the performed log), or nil if the workout hasn't been started.
    var activeSessionID: UUID? { sink?.activeSession()?.id ?? currentLog?.id }

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
        guard let w = workout(scope), let target = mutationTarget(scope) else {
            return "No workout has been created yet."
        }
        var lines = [
            "MUTATION TARGET: scope=\(target.scope.rawValue), scheduled_workout_id=\(target.scheduledWorkoutID?.uuidString ?? "null"), session_id=\(target.sessionID?.uuidString ?? "null"), workout_id=\(target.workoutID.uuidString), revision_token=\(target.revisionToken.uuidString)",
            "WORKOUT [id: \(w.id.uuidString)]: \(w.title)" + (w.goal.map { " - goal: \($0)" } ?? ""),
        ]
        lines.append(contentsOf: guidanceSummary(w.guidance, indent: "  "))
        if w.blocks.isEmpty { lines.append("(no blocks yet)") }
        for (index, block) in w.blocks.enumerated() {
            lines.append("BLOCK \(index + 1) [id: \(block.id.uuidString)]: \(block.name)" + (block.intent.map { " - intent: \($0)" } ?? ""))
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
            lines.append("\(indent)EXERCISE [id: \(exercise.id.uuidString)]: \(heading)\(identity)")
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
                lines.append("\(indent)  Set \(index + 1) [id: \(set.id.uuidString)] [\(set.role.rawValue)]: \(values.isEmpty ? "no values" : values.joined(separator: ", "))")
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
                    return "\(metric.label)=\(MetricFormat.value(value, metric, unit: displayUnit(metric, forTotalsIn: group)))"
                }
                lines.append("\(indent)  Total targets: \(totals.joined(separator: ", "))")
            }
            for adjustment in group.execution.adjustments {
                let unit = displayUnit(adjustment.metric, forTotalsIn: group)
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


    // MARK: - Mutation-failure messages and shared edit mechanics

    private func missingTarget(_ kind: String, name: String, id: UUID?) -> String {
        if let id { return "I couldn't find the \(kind) with id \(id.uuidString) in the workout." }
        return "I couldn't find \"\(name)\" in the workout."
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
