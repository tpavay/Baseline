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
    /// The finish instant and the log it describes, persisted together.
    ///
    /// A standalone log has no plan record to read a finish time back from, so without this a completed
    /// workout reopened tomorrow would have to guess — and "now" is the one answer that is always wrong.
    /// Carrying the log's identity is what makes the value safe to keep and cheap to reuse: a reload can
    /// tell "already resolved" from "belongs to another session" without re-reading the plan's completed
    /// record, and a value left behind by an earlier session can never be read as this one's.
    private struct LogFinish: Codable, Equatable {
        var logID: UUID
        var finishedAt: Date
    }
    private var logFinish: LogFinish? {
        didSet { persist(logFinish, Self.logFinishKey) }
    }

    /// The instant the current log was finished, or nil when this log is not a completed one.
    var currentLogFinishedAt: Date? {
        guard let logFinish, let log = currentLog, log.isComplete, logFinish.logID == log.id else { return nil }
        return logFinish.finishedAt
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
        let completed: () -> CompletedWorkoutLog?
        let planWorkout: () -> Workout?               // the saved plan revision (for completion diffing)
        /// Freeze this session's live heart-rate trace into the plan's sidecar entity. Separate from
        /// `pushLog` because the series must never travel inside the log blob (see
        /// `SDWorkoutHeartRateSeries`).
        let pushHeartRateSeries: (WorkoutHeartRateTrace, WorkoutHeartRateSummary) -> Void
        /// Read the persisted series back. Deliberately *not* called from `reloadFromPlan`: it decodes
        /// the full sample array, and that runs on ~20 paths. Callers pull it once, when they are about
        /// to draw it.
        let heartRateSeries: () -> WorkoutHeartRateSeries?

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
            completed: (() -> CompletedWorkoutLog?)? = nil,
            planWorkout: @escaping () -> Workout?,
            pushHeartRateSeries: ((WorkoutHeartRateTrace, WorkoutHeartRateSummary) -> Void)? = nil,
            heartRateSeries: (() -> WorkoutHeartRateSeries?)? = nil
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
            self.completed = completed ?? { nil }
            self.planWorkout = planWorkout
            self.pushHeartRateSeries = pushHeartRateSeries ?? { _, _ in }
            self.heartRateSeries = heartRateSeries ?? { nil }
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
        resolveFinishInstantFromPlan()
        isSyncing = false
    }

    /// Read the plan's finish instant for a completed session, at most once per completion.
    ///
    /// `reloadFromPlan` runs on ~20 paths; re-reading the frozen completed record on each of them to
    /// recover a `Date` that cannot change would be a SwiftData fetch and a full log decode for nothing.
    /// A session that is live again (resumed) drops its instant here, so completing it a second time
    /// resolves the new one rather than keeping the first.
    private func resolveFinishInstantFromPlan() {
        guard let log = currentLog, log.isComplete else {
            logFinish = nil
            return
        }
        guard logFinish?.logID != log.id else { return }
        guard let finishedAt = sink?.completed()?.finishedAt else { return }
        logFinish = LogFinish(logID: log.id, finishedAt: finishedAt)
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
    private static let logFinishKey = "workout.currentLogFinish"
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
        logFinish = defaults.data(forKey: Self.logFinishKey).flatMap {
            try? JSONDecoder().decode(LogFinish.self, from: $0)
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
        logFinish = nil
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
        displayUnit(metric, forTotalsAcross: group.children.flatMap(\.exercises))
    }

    /// The same composition rule for a whole workout's total — what a share card's DISTANCE stat is.
    func displayUnit(_ metric: MetricType, forTotalsIn workout: Workout) -> MetricUnit {
        displayUnit(metric, forTotalsAcross: workout.allExercises)
    }

    private func displayUnit(_ metric: MetricType, forTotalsAcross exercises: [PlannedExercise]) -> MetricUnit {
        guard metric == .distance else { return displayUnit(metric) }
        let distanceMovements = exercises
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

    /// Replace a planned movement in place. The exercise identity, position, and guidance stay intact.
    /// The prescription is re-derived to the new movement via `replacingMovement`/`retainingMetrics`:
    /// per-set values, ranges, and progressions keyed to metrics the new movement does not support are
    /// reset to the new movement's schema, while metrics both movements share keep their values.
    @discardableResult
    func replaceExercise(_ exerciseID: UUID, with definition: ExerciseDefinition, scope: WorkoutEditScope) -> Bool {
        guard var workout = workout(scope),
              applyReplacement(definition, to: exerciseID, in: &workout) else { return false }
        apply(workout, scope)
        noteRecent(definition.id)
        return true
    }

    /// Replace the movement for a live-session exercise as a log-side substitution: the saved plan and
    /// template are left untouched, the session's log carries the swap. Re-derives the metric schema to
    /// the new movement and sanitizes both the substitution's prescription and any already-logged
    /// values, so a previous movement's numbers can never ride along or resurface at completion. The one
    /// live-log replace path, built on the same `replacingMovement` as the plan/agent edits.
    func substituteLoggedExercise(
        exerciseID: UUID,
        with definition: ExerciseDefinition,
        groupID: UUID? = nil,
        iteration: Int? = nil
    ) {
        guard let planned = current?.exercise(exerciseID) else { return }
        let base = currentLog?.effectiveExercise(for: planned, groupID: groupID, iteration: iteration) ?? planned
        let replaced = base.replacingMovement(with: definition)
        let substitution = LoggedExerciseSubstitution(
            exerciseName: replaced.exerciseName,
            definitionId: replaced.definitionId,
            selectedMetrics: replaced.selectedMetrics,
            displayUnits: replaced.displayUnits,
            prescription: replaced.prescription
        )
        editLog {
            $0.setExerciseAdjustment(
                plannedExerciseID: exerciseID,
                groupID: groupID,
                iteration: iteration,
                outcome: .substituted,
                substitution: substitution,
                name: planned.exerciseName
            )
            // Sets logged before the swap still hold the old movement's values; strip the ones the new
            // movement can't own so nothing stale resurfaces in the completed/history summary. Scoped to
            // the substitution so a round- or group-scoped replace never touches sets belonging to other
            // rounds that still use the original movement.
            $0.sanitizeSetLogs(
                forPlanned: exerciseID,
                retaining: Set(definition.supported),
                groupID: groupID,
                iteration: iteration
            )
        }
        noteRecent(definition.id)
    }

    /// Begin performing. Bound → the plan creates the session; unbound → a local performed log.
    func startWorkout() {
        if let sink {
            sink.start()
            reloadFromPlan()
        } else {
            guard let w = current, currentLog == nil else { return }
            currentLogStartedAt = Date()
            logFinish = nil
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
        let finishedAt = Date()
        if let log = currentLog, !log.isComplete, logFinish?.logID == log.id { logFinish = nil }
        if let sink { sink.complete(); reloadFromPlan() }
        else { editLog { $0.isComplete = true } }
        // Completing can be refused — no live session to complete, or no log to mark — so the instant is
        // recorded only for a log that actually came out complete. The plan path has already taken the
        // plan's own instant through `reloadFromPlan`; this is the standalone fallback.
        if let log = currentLog, log.isComplete, logFinish == nil {
            logFinish = LogFinish(logID: log.id, finishedAt: finishedAt)
        }
        if !awaitingReconciliationDecision { sink?.resolveSessionDecision() }
    }

    // MARK: - Measured heart rate

    /// The session's captured heart rate, cached against the log it belongs to so a rebind or a
    /// different workout can never show the previous one's trace.
    private var heartRate: (logID: UUID, capture: WorkoutHeartRateCapture)?

    /// The heart rate already resolved for the current log, without touching persistence.
    var currentHeartRate: WorkoutHeartRateCapture? {
        guard let log = currentLog, let heartRate, heartRate.logID == log.id else { return nil }
        return heartRate.capture
    }

    /// Freeze this run's heart rate onto the session — including the answer "there wasn't any".
    ///
    /// Called from the finish sequence *before* `completeWorkout`, because the live monitor is torn
    /// down the instant the log reads complete — after that there is nothing left to capture. The
    /// summary rides on the log (small); the trace goes to its own sidecar entity through the sink.
    ///
    /// Nil is a statement, not a no-op: the log's summary and the resolved capture both describe the
    /// run being finished, and a run that measured nothing must leave neither behind. Skipping the
    /// call would let a previous run's copies ride along into this completion.
    func attachHeartRate(_ capture: WorkoutHeartRateCapture?) {
        guard let log = currentLog else { return }
        editLog { $0.heartRateSummary = capture?.summary }
        guard let capture else {
            heartRate = nil
            return
        }
        sink?.pushHeartRateSeries(capture.trace, capture.summary)
        heartRate = (log.id, capture)
    }

    /// Resolve the persisted heart rate for the current log, decoding the sample array at most once
    /// per log. Callers do this when they are about to draw it — never from `body`, and never from
    /// `reloadFromPlan`, which runs on far too many paths to carry a 3600-element decode.
    @discardableResult
    func loadHeartRate() -> WorkoutHeartRateCapture? {
        if let currentHeartRate { return currentHeartRate }
        guard let log = currentLog, let series = sink?.heartRateSeries(), series.trace.hasSamples else { return nil }
        let capture = WorkoutHeartRateCapture(trace: series.trace, summary: series.summary)
        heartRate = (log.id, capture)
        return capture
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

    /// Whether that work includes logged sets, so a discard warning can name what it is discarding.
    func hasLoggedSets(forExercise exerciseID: UUID) -> Bool {
        currentLog?.hasLoggedSets(forPlanned: exerciseID) ?? false
    }

    /// Whether that work includes a session note the athlete typed.
    func hasSessionNote(forExercise exerciseID: UUID) -> Bool {
        currentLog?.hasSessionNote(forPlanned: exerciseID) ?? false
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
            logFinish = nil
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

    /// Synchronous per-mutation feed: invoked with the resulting workout after every applied agent
    /// mutation and after every undo. The import review flow wires this so each intermediate value
    /// reaches its issue reconciler in order, independent of SwiftUI change coalescing; view-level
    /// `onChange` only sees the last value of a render pass, and a skipped intermediate state would
    /// otherwise be unrestorable after `undo_workout_mutation`.
    @ObservationIgnored var agentMutationObserver: ((Workout) -> Void)?

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
    ///
    /// `finalDiff` replaces the static `diff` after the transform succeeds. A composite batch supplies
    /// it because its per-operation entity IDs (a duplicated block's fresh ID, an added set's ID) only
    /// exist once every transform has run; the single-change remap below can't express that.
    private func mutate(
        expectedRevisionToken: UUID?,
        reason: String,
        diff: WorkoutMutationDiff,
        dryRun: Bool = false,
        resolvedEntityIDs: () -> [UUID] = { [] },
        finalDiff: (() -> WorkoutMutationDiff)? = nil,
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
        if let finalDiff { resolvedDiff = finalDiff() }

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
            agentMutationObserver?(authoritative)
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
            revertCustomExerciseCreation(ifUndone: mutationID)
            agentMutationObserver?(applied.before)
            return .mutated(undoReceipt)
        }
        switch sink.undoMutation(mutationID, expectedRevisionToken) {
        case .applied(let receipt):
            reloadFromPlan()
            revertCustomExerciseCreation(ifUndone: mutationID)
            if let restored = current { agentMutationObserver?(restored) }
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

    // MARK: - Tool-facing operations (each single tool is one `WorkoutEditOperation`)

    @discardableResult
    func updateWorkoutMetadata(
        title: MetadataPatch<String>,
        note: MetadataPatch<String>,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .updateWorkoutMetadata(title: title, note: note),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func updateBlockMetadata(
        blockID: UUID,
        name: MetadataPatch<String>,
        intent: MetadataPatch<String>,
        guidance: MetadataPatch<String>,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .updateBlockMetadata(blockID: blockID, name: name, intent: intent, guidance: guidance),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func updateExerciseMetadata(
        exerciseInstanceID: UUID,
        displayLabel: MetadataPatch<String>,
        guidance: MetadataPatch<String>,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .updateExerciseMetadata(
                exerciseInstanceID: exerciseInstanceID,
                displayLabel: displayLabel,
                guidance: guidance
            ),
            expectedRevisionToken: expectedRevisionToken
        )
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
                logFinish = nil
                isSyncing = false
            }
            return outcome
        } else if let make = makeTodayScheduled, let newSink = make(w) {
            // Nothing scheduled today yet → the factory already put `w` in the plan; bind without re-pushing.
            sink = newSink; coalesceContent = false; pendingPlanEdit = nil
            isSyncing = true
            current = w; currentLog = nil; currentLogStartedAt = nil; logFinish = nil
            isSyncing = false
        } else {
            // standalone (no plan)
            current = w; currentLog = nil; currentLogStartedAt = nil; logFinish = nil
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
        perform(
            .addBlock(name: name, intent: intent, guidance: guidance, atIndex: atIndex),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func removeBlock(blockID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        perform(.removeBlock(blockID: blockID), expectedRevisionToken: expectedRevisionToken)
    }

    @discardableResult
    func moveBlock(blockID: UUID, toIndex: Int, expectedRevisionToken: UUID) -> EditOutcome {
        perform(.moveBlock(blockID: blockID, toIndex: toIndex), expectedRevisionToken: expectedRevisionToken)
    }

    @discardableResult
    func duplicateBlock(blockID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        perform(.duplicateBlock(blockID: blockID), expectedRevisionToken: expectedRevisionToken)
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
        toContainerID containerID: UUID,
        atIndex: Int?,
        sets: Int?,
        reps: Int?,
        load: Double?,
        durationSeconds: Int?,
        distanceMeters: Double? = nil,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .addExercise(
                containerID: containerID,
                name: name,
                atIndex: atIndex,
                sets: sets,
                reps: reps,
                load: load,
                durationSeconds: durationSeconds,
                distanceMeters: distanceMeters
            ),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func moveExercise(
        exerciseInstanceID: UUID,
        toBlockID: UUID,
        toIndex: Int,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .moveExercise(exerciseInstanceID: exerciseInstanceID, toBlockID: toBlockID, toIndex: toIndex),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func removeExercise(
        exerciseInstanceID: UUID,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(.removeExercise(exerciseInstanceID: exerciseInstanceID), expectedRevisionToken: expectedRevisionToken)
    }

    @discardableResult
    func reorderExercise(
        exerciseInstanceID: UUID,
        toIndex: Int,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .reorderExercise(exerciseInstanceID: exerciseInstanceID, toIndex: toIndex),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func duplicateExercise(
        exerciseInstanceID: UUID,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(.duplicateExercise(exerciseInstanceID: exerciseInstanceID), expectedRevisionToken: expectedRevisionToken)
    }

    @discardableResult
    func replaceExercise(
        exerciseInstanceID: UUID,
        with replacement: String,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .replaceExercise(exerciseInstanceID: exerciseInstanceID, replacement: replacement),
            expectedRevisionToken: expectedRevisionToken
        )
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
        perform(
            .addSet(
                exerciseInstanceID: exerciseInstanceID,
                afterSetID: afterSetID,
                values: values,
                role: role,
                targets: targets
            ),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func updateSet(
        setID: UUID,
        patch: PlannedSetPatch,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(.updateSet(setID: setID, patch: patch), expectedRevisionToken: expectedRevisionToken)
    }

    @discardableResult
    func removeSet(setID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        perform(.removeSet(setID: setID), expectedRevisionToken: expectedRevisionToken)
    }

    @discardableResult
    func moveSet(
        setID: UUID,
        beforeSetID: UUID?,
        toIndex: Int?,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .moveSet(setID: setID, beforeSetID: beforeSetID, toIndex: toIndex),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    // MARK: - Wave 8: advanced nodes and prescriptions (thin wrappers over the one edit factory)

    @discardableResult
    func updateGroup(groupID: UUID, patch: WorkoutGroupPatch, expectedRevisionToken: UUID) -> EditOutcome {
        perform(.updateGroup(groupID: groupID, patch: patch), expectedRevisionToken: expectedRevisionToken)
    }

    @discardableResult
    func updateChoice(
        choiceID: UUID,
        label: MetadataPatch<String>,
        selectionCount: MetadataPatch<Int>,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .updateChoice(choiceID: choiceID, label: label, selectionCount: selectionCount),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func convertChoiceToGroup(choiceID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        perform(.convertChoiceToGroup(choiceID: choiceID), expectedRevisionToken: expectedRevisionToken)
    }

    @discardableResult
    func updateRest(restID: UUID, patch: PlannedRestPatch, expectedRevisionToken: UUID) -> EditOutcome {
        perform(.updateRest(restID: restID, patch: patch), expectedRevisionToken: expectedRevisionToken)
    }

    @discardableResult
    func addRest(
        parentID: UUID,
        atIndex: Int?,
        durationSeconds: Int?,
        placement: RestPlacement,
        label: String?,
        guidance: String?,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .addRest(
                parentID: parentID,
                atIndex: atIndex,
                durationSeconds: durationSeconds,
                placement: placement,
                label: label,
                guidance: guidance
            ),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func moveNode(nodeID: UUID, toParentID: UUID, toIndex: Int, expectedRevisionToken: UUID) -> EditOutcome {
        perform(
            .moveNode(nodeID: nodeID, toParentID: toParentID, toIndex: toIndex),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func removeNode(nodeID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        perform(.removeNode(nodeID: nodeID), expectedRevisionToken: expectedRevisionToken)
    }

    @discardableResult
    func addSetAlternative(
        setID: UUID,
        label: String,
        values: PlannedSetValues,
        ranges: [MetricTargetRange],
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .addSetAlternative(setID: setID, label: label, values: values, ranges: ranges),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func updateSetAlternative(
        alternativeID: UUID,
        patch: SetAlternativePatch,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .updateSetAlternative(alternativeID: alternativeID, patch: patch),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func removeSetAlternative(alternativeID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        perform(
            .removeSetAlternative(alternativeID: alternativeID),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func updateExercisePrescription(
        exerciseInstanceID: UUID,
        patch: ExercisePrescriptionPatch,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .updateExercisePrescription(exerciseInstanceID: exerciseInstanceID, patch: patch),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    @discardableResult
    func duplicateSet(setID: UUID, expectedRevisionToken: UUID) -> EditOutcome {
        perform(.duplicateSet(setID: setID), expectedRevisionToken: expectedRevisionToken)
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
        perform(
            .updateLoggingConfig(exerciseInstanceID: exerciseInstanceID, enabledMetrics: enabled, units: units),
            expectedRevisionToken: expectedRevisionToken
        )
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

    /// Apply a logging-config edit to the exercise the athlete is actually looking at. During a live
    /// session a top-level substitution overlays the planned exercise, so an edit written to the plan
    /// would land on a hidden layer the overlay discards — and the plain setter would even validate the
    /// request against the *old* movement, locking out any metric only the new movement supports. When a
    /// substitution is active this updates the substitution itself and validates against the substituted
    /// movement; otherwise it is the ordinary plan/session config edit.
    @discardableResult
    func setLoggingConfigForActiveExercise(
        exerciseID: UUID,
        enabled: [MetricType]?,
        units: [MetricType: MetricUnit] = [:],
        scope: WorkoutEditScope
    ) -> Bool {
        guard let log = currentLog,
              let adjustment = log.exerciseAdjustment(for: exerciseID),
              adjustment.outcome == .substituted,
              var substitution = adjustment.substitution else {
            return setLoggingConfig(exerciseID: exerciseID, enabled: enabled, units: units, scope: scope)
        }
        let definition = substitution.definitionId.flatMap(ExerciseCatalog.definition(id:)) ?? ExerciseCatalog.generic
        let supported = Set(definition.supported)
        let requested = (enabled ?? []) + Array(units.keys)
        guard requested.allSatisfy(supported.contains) else { return false }
        if let enabled {
            substitution.selectedMetrics = MetricType.allCases.filter { enabled.contains($0) }
        }
        for (metric, unit) in units where metric.displayUnits.contains(unit) {
            substitution.displayUnits[metric] = unit
        }
        let plannedName = workout(scope)?.exercise(exerciseID)?.exerciseName ?? substitution.exerciseName
        editLog {
            $0.setExerciseAdjustment(
                plannedExerciseID: exerciseID,
                groupID: adjustment.groupID,
                iteration: adjustment.iteration,
                outcome: .substituted,
                substitution: substitution,
                name: plannedName
            )
        }
        return true
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
        // Resolve through the athlete's own catalog (customs first): "use miles for it from now on"
        // must reach a movement created with create_custom_exercise, not just curated names.
        let def = resolveDefinition(name)
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
        perform(
            .setMetricValue(
                exerciseInstanceID: exerciseInstanceID,
                setID: setID,
                metric: metric,
                value: value,
                unit: unit
            ),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    /// Remove a metric from an exercise this workout — unselect it and clear its values.
    @discardableResult
    func removeMetric(
        exerciseInstanceID: UUID,
        metric: MetricType,
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        perform(
            .removeMetric(exerciseInstanceID: exerciseInstanceID, metric: metric),
            expectedRevisionToken: expectedRevisionToken
        )
    }

    // MARK: - The one edit factory (single tools and the atomic batch share every transform)

    /// One operation's validation and mutation, prepared but not yet applied. A single tool runs one
    /// of these through `mutate`; `applyWorkoutEdits` runs an ordered list of them inside ONE `mutate`
    /// call, so the whole batch is one snapshot check, one persistence write, one receipt, one undo.
    private struct PreparedEdit {
        var reason: String
        var changes: [WorkoutMutationDiff.Change]
        var transform: (inout Workout) -> EditOutcome?
        var logTransform: ((inout WorkoutLog) -> Void)?
        var resolvedEntityIDs: () -> [UUID]
        var onSuccess: (() -> Void)?

        init(
            reason: String,
            changes: [WorkoutMutationDiff.Change],
            transform: @escaping (inout Workout) -> EditOutcome?,
            logTransform: ((inout WorkoutLog) -> Void)? = nil,
            resolvedEntityIDs: @escaping () -> [UUID] = { [] },
            onSuccess: (() -> Void)? = nil
        ) {
            self.reason = reason
            self.changes = changes
            self.transform = transform
            self.logTransform = logTransform
            self.resolvedEntityIDs = resolvedEntityIDs
            self.onSuccess = onSuccess
        }
    }

    /// A prepared operation or its static rejection. (Not `Result`: `EditOutcome` is a tool reply,
    /// not an `Error`.)
    private enum Prepared {
        case success(PreparedEdit)
        case failure(EditOutcome)
    }

    /// Apply one operation through the shared mutation envelope.
    private func perform(_ operation: WorkoutEditOperation, expectedRevisionToken: UUID?) -> EditOutcome {
        switch preparedEdit(for: operation) {
        case .failure(let failure):
            return failure
        case .success(let edit):
            let outcome = mutate(
                expectedRevisionToken: expectedRevisionToken,
                reason: edit.reason,
                diff: WorkoutMutationDiff(changes: edit.changes),
                resolvedEntityIDs: edit.resolvedEntityIDs,
                logTransform: edit.logTransform,
                transform: edit.transform
            )
            if outcome.succeeded { edit.onSuccess?() }
            return outcome
        }
    }

    /// A defensive ceiling far above any real conversational intent; the served schema states the
    /// same limit so the model never learns it by rejection.
    static let maxBatchOperations = 20

    /// ONE atomic composite mutation: every operation validates against the same snapshot and applies
    /// to the same local `Workout` copy in order, then the envelope persists ONCE. If any operation
    /// fails — statically or against the evolving workout — the whole batch rejects, nothing commits,
    /// and the error names exactly which operation failed and why. One receipt and one undo cover the
    /// entire intent.
    @discardableResult
    func applyWorkoutEdits(
        operations: [WorkoutEditOperation],
        expectedRevisionToken: UUID
    ) -> EditOutcome {
        guard operations.isEmpty == false else {
            return .notFound("apply_workout_edits needs at least one operation.")
        }
        guard operations.count <= Self.maxBatchOperations else {
            return .notFound(
                "apply_workout_edits accepts at most \(Self.maxBatchOperations) operations per call. "
                    + "Split the request into more than one batch."
            )
        }
        var edits: [PreparedEdit] = []
        for (index, operation) in operations.enumerated() {
            switch preparedEdit(for: operation) {
            case .failure(let failure):
                return Self.batchRejection(failure, index: index, operation: operation, total: operations.count)
            case .success(let edit):
                edits.append(edit)
            }
        }
        let outcome = mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Apply \(operations.count) workout edits atomically",
            diff: WorkoutMutationDiff(changes: edits.flatMap(\.changes)),
            finalDiff: {
                WorkoutMutationDiff(changes: edits.flatMap { Self.resolvedChanges($0) })
            },
            logTransform: { log in
                for edit in edits { edit.logTransform?(&log) }
            }
        ) { workout in
            for (index, edit) in edits.enumerated() {
                if let failure = edit.transform(&workout) {
                    return Self.batchRejection(
                        failure,
                        index: index,
                        operation: operations[index],
                        total: operations.count
                    )
                }
            }
            return nil
        }
        if outcome.succeeded {
            for edit in edits { edit.onSuccess?() }
        }
        return outcome
    }

    private static func resolvedChanges(_ edit: PreparedEdit) -> [WorkoutMutationDiff.Change] {
        let entityIDs = edit.resolvedEntityIDs()
        guard edit.changes.count == 1, let change = edit.changes.first, entityIDs.isEmpty == false else {
            return edit.changes
        }
        return entityIDs.map { entityID in
            var resolved = change
            resolved.entityID = entityID
            return resolved
        }
    }

    /// A batch failure names the operation precisely and states the all-or-nothing outcome, so the
    /// model can repair one op and resend instead of degrading to partial single edits.
    private static func batchRejection(
        _ failure: EditOutcome,
        index: Int,
        operation: WorkoutEditOperation,
        total: Int
    ) -> EditOutcome {
        let message: String
        let isAmbiguous: Bool
        switch failure {
        case .notFound(let text):
            message = text
            isAmbiguous = false
        case .ambiguous(let text):
            message = text
            isAmbiguous = true
        case .done, .mutated:
            return failure
        }
        let framed = "Operation \(index + 1) of \(total) (\(operation.toolName)) failed: \(message) "
            + "The whole batch was rejected and nothing was changed."
        return isAmbiguous ? .ambiguous(framed) : .notFound(framed)
    }

    /// Builds the validation + transform for one operation. Static preconditions fail here (before
    /// any snapshot work); target resolution and domain validation happen inside `transform`, against
    /// the one authoritative workout value the envelope supplies.
    private func preparedEdit(for operation: WorkoutEditOperation) -> Prepared {
        switch operation {
        case .updateWorkoutMetadata(let title, let note):
            guard !title.isUnchanged || !note.isUnchanged else {
                return .failure(.notFound("Include at least one workout detail to change."))
            }
            guard title != .clear else {
                return .failure(.notFound("A workout title can't be cleared. Set a new title or omit it."))
            }
            return .success(PreparedEdit(
                reason: "Update workout metadata",
                changes: metadataChanges(
                    fields: [("workout title", title), ("workout note", note)],
                    entityID: current?.id
                ),
                transform: { workout in
                    if case .set(let value) = title { workout.rename(value) }
                    switch note {
                    case .unchanged: break
                    case .set(let value): workout.updateGoal(value)
                    case .clear: workout.updateGoal(nil)
                    }
                    return nil
                }
            ))

        case .updateBlockMetadata(let blockID, let name, let intent, let guidance):
            guard !name.isUnchanged || !intent.isUnchanged || !guidance.isUnchanged else {
                return .failure(.notFound("Include at least one block detail to change."))
            }
            guard name != .clear else {
                return .failure(.notFound("A block name can't be cleared. Set a new name or omit it."))
            }
            return .success(PreparedEdit(
                reason: "Update block metadata",
                changes: metadataChanges(
                    fields: [("block name", name), ("block intent", intent), ("block guidance", guidance)],
                    entityID: blockID
                ),
                transform: { [self] workout in
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
            ))

        case .updateExerciseMetadata(let exerciseInstanceID, let displayLabel, let guidance):
            guard !displayLabel.isUnchanged || !guidance.isUnchanged else {
                return .failure(.notFound("Include at least one exercise detail to change."))
            }
            return .success(PreparedEdit(
                reason: "Update exercise metadata",
                changes: metadataChanges(
                    fields: [("exercise display label", displayLabel), ("exercise guidance", guidance)],
                    entityID: exerciseInstanceID
                ),
                transform: { [self] workout in
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
            ))

        case .addBlock(let name, let intent, let guidance, let atIndex):
            var affectedID: UUID?
            return .success(PreparedEdit(
                reason: "Add block \(name)",
                changes: [.init(kind: .add, summary: "Add block \(name)", entityID: nil)],
                transform: { workout in
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
                },
                resolvedEntityIDs: { affectedID.map { [$0] } ?? [] }
            ))

        case .removeBlock(let blockID):
            var removedExerciseIDs: [UUID] = []
            var removedGroupIDs: Set<UUID> = []
            var removedChoiceIDs: Set<UUID> = []
            return .success(PreparedEdit(
                reason: "Remove block",
                changes: [.init(kind: .remove, summary: "Remove block", entityID: blockID)],
                transform: { [self] workout in
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
                },
                logTransform: { log in
                    for exerciseID in removedExerciseIDs {
                        log.removePerformed(forPlanned: exerciseID)
                    }
                    log.removeGroups(forPlanned: removedGroupIDs)
                    log.removeChoices(forPlanned: removedChoiceIDs)
                }
            ))

        case .moveBlock(let blockID, let toIndex):
            return .success(PreparedEdit(
                reason: "Move block",
                changes: [.init(kind: .move, summary: "Move block", entityID: blockID)],
                transform: { workout in
                    guard workout.moveBlock(blockID, to: toIndex) else {
                        return .notFound("The block doesn't exist or to_index is outside its final order.")
                    }
                    return nil
                }
            ))

        case .duplicateBlock(let blockID):
            var duplicateID: UUID?
            return .success(PreparedEdit(
                reason: "Duplicate block",
                changes: [.init(kind: .add, summary: "Duplicate block", entityID: nil)],
                transform: { [self] workout in
                    guard let copiedID = workout.duplicateBlock(blockID) else {
                        return .notFound(missingTarget("block", name: "", id: blockID))
                    }
                    duplicateID = copiedID
                    return nil
                },
                resolvedEntityIDs: { duplicateID.map { [$0] } ?? [] }
            ))

        case .addExercise(let containerID, let name, let atIndex, let sets, let reps, let load, let durationSeconds, let distanceMeters):
            var recentDefinitionID: String?
            var affectedID: UUID?
            return .success(PreparedEdit(
                reason: "Add \(name)",
                changes: [.init(kind: .add, summary: "Add \(name)", entityID: nil)],
                transform: { [self] workout in
                    guard let container = workout.nodeContainer(containerID) else {
                        return .notFound(missingTarget("block, group, or choice", name: "", id: containerID))
                    }
                    let exercise = plannedExercise(
                        name: name,
                        sets: sets,
                        reps: reps,
                        load: load,
                        durationSeconds: durationSeconds,
                        distanceMeters: distanceMeters
                    )
                    let count = workout.nodes(in: container)?.count ?? 0
                    guard workout.insertNode(.exercise(exercise), into: containerID, at: atIndex) else {
                        return .notFound("Exercise position must be between 0 and \(count).")
                    }
                    recentDefinitionID = exercise.definitionId
                    affectedID = exercise.id
                    return nil
                },
                resolvedEntityIDs: { affectedID.map { [$0] } ?? [] },
                onSuccess: { [self] in recentDefinitionID.map { noteRecent($0) } }
            ))

        case .moveExercise(let exerciseInstanceID, let toBlockID, let toIndex):
            var removedChoiceOptionIDs: Set<UUID> = []
            return .success(PreparedEdit(
                reason: "Move exercise",
                changes: [.init(kind: .move, summary: "Move exercise", entityID: exerciseInstanceID)],
                transform: { [self] workout in
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
                },
                logTransform: { log in
                    log.removeChoiceSelections(optionIDs: removedChoiceOptionIDs)
                }
            ))

        case .replaceExercise(let exerciseInstanceID, let replacement):
            var recentDefinitionID: String?
            return .success(PreparedEdit(
                reason: "Replace exercise with \(replacement)",
                changes: [
                    .init(kind: .replace, summary: "Replace exercise with \(replacement)", entityID: exerciseInstanceID),
                ],
                transform: { [self] workout in
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
                },
                onSuccess: { [self] in recentDefinitionID.map { noteRecent($0) } }
            ))

        case .removeExercise(let exerciseInstanceID):
            var removedChoiceOptionIDs: Set<UUID> = []
            return .success(PreparedEdit(
                reason: "Remove exercise",
                changes: [.init(kind: .remove, summary: "Remove exercise", entityID: exerciseInstanceID)],
                transform: { [self] workout in
                    removedChoiceOptionIDs = Set(
                        workout.choiceOptionIDs(containingExercise: exerciseInstanceID)
                    )
                    guard workout.removeExercise(exerciseInstanceID) else {
                        return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
                    }
                    return nil
                },
                logTransform: { log in
                    log.removePerformed(forPlanned: exerciseInstanceID)
                    log.removeChoiceSelections(optionIDs: removedChoiceOptionIDs)
                }
            ))

        case .reorderExercise(let exerciseInstanceID, let toIndex):
            return .success(PreparedEdit(
                reason: "Reorder exercise",
                changes: [.init(kind: .move, summary: "Reorder exercise", entityID: exerciseInstanceID)],
                transform: { workout in
                    guard workout.reorderExercise(exerciseInstanceID, to: toIndex) else {
                        return .notFound("The exercise doesn't exist or to_index is outside its container.")
                    }
                    return nil
                }
            ))

        case .duplicateExercise(let exerciseInstanceID):
            var duplicateID: UUID?
            return .success(PreparedEdit(
                reason: "Duplicate exercise",
                changes: [.init(kind: .add, summary: "Duplicate exercise", entityID: nil)],
                transform: { [self] workout in
                    guard let copiedID = workout.duplicateExercise(exerciseInstanceID) else {
                        return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
                    }
                    duplicateID = copiedID
                    return nil
                },
                resolvedEntityIDs: { duplicateID.map { [$0] } ?? [] }
            ))

        case .addSet(let exerciseInstanceID, let afterSetID, let values, let role, let targets):
            var addedSetID: UUID?
            return .success(PreparedEdit(
                reason: "Add planned set",
                changes: [.init(kind: .add, summary: "Add planned set", entityID: nil)],
                transform: { [self] workout in
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
                },
                resolvedEntityIDs: { addedSetID.map { [$0] } ?? [] }
            ))

        case .updateSet(let setID, let patch):
            guard patch.isUnchanged == false else {
                return .failure(.notFound("Include at least one planned-set field to change."))
            }
            guard patch.role != .clear else {
                return .failure(.notFound("A planned set role can't be cleared. Set a role or omit it."))
            }
            return .success(PreparedEdit(
                reason: "Update planned set",
                changes: [.init(kind: .edit, summary: "Update planned set", entityID: setID)],
                transform: { [self] workout in
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
                    if case .set(let progressions) = patch.progressions {
                        for progression in progressions {
                            if let failure = invalidProgression(progression, exercise: exercise) {
                                return .notFound(failure)
                            }
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
                        switch patch.progressions {
                        case .unchanged: break
                        case .set(let progressions): updated.progressions = progressions
                        case .clear: updated.progressions = []
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
            ))

        case .removeSet(let setID):
            var ownerID: UUID?
            return .success(PreparedEdit(
                reason: "Remove planned set",
                changes: [.init(kind: .remove, summary: "Remove planned set", entityID: setID)],
                transform: { [self] workout in
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
                },
                logTransform: { log in
                    guard let ownerID else { return }
                    log.removeSetLogs(forPlanned: ownerID, plannedSetIDs: [setID])
                }
            ))

        case .moveSet(let setID, let beforeSetID, let toIndex):
            guard (beforeSetID != nil) != (toIndex != nil) else {
                return .failure(.notFound("Move a set with exactly one of before_set_id or to_index."))
            }
            return .success(PreparedEdit(
                reason: "Move planned set",
                changes: [.init(kind: .move, summary: "Move planned set", entityID: setID)],
                transform: { workout in
                    let destination = beforeSetID.map(PlannedSetMoveDestination.before)
                        ?? toIndex.map(PlannedSetMoveDestination.index)
                    guard let destination, workout.moveSet(setID, to: destination) else {
                        return .notFound("The set or its destination doesn't exist in the same exercise.")
                    }
                    return nil
                }
            ))

        case .duplicateSet(let setID):
            var duplicateID: UUID?
            return .success(PreparedEdit(
                reason: "Duplicate planned set",
                changes: [.init(kind: .add, summary: "Duplicate planned set", entityID: nil)],
                transform: { [self] workout in
                    guard let copiedID = workout.duplicateSet(setID) else {
                        return .notFound(missingTarget("set", name: "", id: setID))
                    }
                    duplicateID = copiedID
                    return nil
                },
                resolvedEntityIDs: { duplicateID.map { [$0] } ?? [] }
            ))

        case .setMetricValue(let exerciseInstanceID, let setID, let metric, let value, let unit):
            return .success(PreparedEdit(
                reason: "Set \(metric.label) on planned set",
                changes: [.init(kind: .edit, summary: "Set \(metric.label) on planned set", entityID: setID)],
                transform: { [self] workout in
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
            ))

        case .removeMetric(let exerciseInstanceID, let metric):
            return .success(PreparedEdit(
                reason: "Remove \(metric.label) from exercise",
                changes: [
                    .init(kind: .remove, summary: "Remove \(metric.label) from exercise", entityID: exerciseInstanceID),
                ],
                transform: { [self] workout in
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
            ))

        case .updateLoggingConfig(let exerciseInstanceID, let enabled, let units):
            guard enabled != nil || units.isEmpty == false else {
                return .failure(.notFound("Include enabled_metrics or at least one display unit to change."))
            }
            return .success(PreparedEdit(
                reason: "Update exercise logging configuration",
                changes: [
                    .init(kind: .edit, summary: "Update exercise logging configuration", entityID: exerciseInstanceID),
                ],
                transform: { [self] workout in
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
            ))

        // MARK: Wave 8 — advanced nodes and prescriptions (all on the shared recursive node API)

        case .updateGroup(let groupID, let patch):
            guard patch.isUnchanged == false else {
                return .failure(.notFound("Include at least one group detail to change."))
            }
            guard patch.label != .clear else {
                return .failure(.notFound("A group label can't be cleared. Set a new label or omit it."))
            }
            guard patch.repetition != .clear else {
                return .failure(.notFound(
                    "A group's repetition can't be cleared. Set once, a count, or a duration."
                ))
            }
            return .success(PreparedEdit(
                reason: "Update group",
                changes: [.init(kind: .edit, summary: "Update group", entityID: groupID)],
                transform: { [self] workout in
                    guard case .group(let group)? = workout.findNode(groupID) else {
                        return .notFound(missingTarget("group", name: "", id: groupID))
                    }
                    if case .set(let valuesPatch) = patch.totalTargets {
                        for (metric, metricPatch) in valuesPatch.metrics {
                            if case .set(let value) = metricPatch,
                               let failure = invalidGroupMetricValue(metric: metric, value: value) {
                                return .notFound(failure)
                            }
                        }
                    }
                    if case .set(let adjustments) = patch.adjustments {
                        for adjustment in adjustments {
                            if let failure = invalidAdjustment(adjustment) { return .notFound(failure) }
                        }
                    }
                    guard workout.updateGroup(groupID, { updated in
                        if case .set(let label) = patch.label { updated.label = label }
                        updated.guidance = applyingGuidance(patch.guidance, to: group.guidance)
                        switch patch.phase {
                        case .unchanged: break
                        case .set(let value): updated.phase = value
                        case .clear: updated.phase = nil
                        }
                        switch patch.doseLayer {
                        case .unchanged: break
                        case .set(let value): updated.doseLayer = value
                        case .clear: updated.doseLayer = nil
                        }
                        if case .set(let value) = patch.isOptional { updated.isOptional = value }
                        if case .set(let value) = patch.repetition { updated.execution.repetition = value }
                        switch patch.cadence {
                        case .unchanged: break
                        case .set(let value): updated.execution.cadence = value
                        case .clear: updated.execution.cadence = nil
                        }
                        switch patch.totalTargets {
                        case .unchanged:
                            break
                        case .clear:
                            updated.execution.totalTargets = MetricValues()
                        case .set(let valuesPatch):
                            for (metric, metricPatch) in valuesPatch.metrics {
                                switch metricPatch {
                                case .unchanged: break
                                case .set(let value): updated.execution.totalTargets[metric] = value
                                case .clear: updated.execution.totalTargets[metric] = nil
                                }
                            }
                        }
                        switch patch.adjustments {
                        case .unchanged: break
                        case .set(let value): updated.execution.adjustments = value
                        case .clear: updated.execution.adjustments = []
                        }
                    }) else {
                        return .notFound(missingTarget("group", name: "", id: groupID))
                    }
                    return nil
                }
            ))

        case .updateChoice(let choiceID, let label, let selectionCount):
            guard !label.isUnchanged || !selectionCount.isUnchanged else {
                return .failure(.notFound("Include a label or selection count to change."))
            }
            guard label != .clear else {
                return .failure(.notFound("A choice label can't be cleared. Set a new label or omit it."))
            }
            guard selectionCount != .clear else {
                return .failure(.notFound(
                    "A choice's selection count can't be cleared. Set a value between 1 and its option count."
                ))
            }
            return .success(PreparedEdit(
                reason: "Update choice",
                changes: [.init(kind: .edit, summary: "Update choice", entityID: choiceID)],
                transform: { [self] workout in
                    guard case .choice(let choice)? = workout.findNode(choiceID) else {
                        return .notFound(missingTarget("choice", name: "", id: choiceID))
                    }
                    if case .set(let count) = selectionCount {
                        guard count >= 1, count <= choice.options.count else {
                            return .notFound(
                                "selection_count must be between 1 and \(choice.options.count) for \"\(choice.label)\"."
                            )
                        }
                    }
                    guard workout.updateChoice(choiceID, { updated in
                        if case .set(let value) = label { updated.label = value }
                        if case .set(let count) = selectionCount { updated.selectionCount = count }
                    }) else {
                        return .notFound(missingTarget("choice", name: "", id: choiceID))
                    }
                    return nil
                }
            ))

        case .convertChoiceToGroup(let choiceID):
            return .success(PreparedEdit(
                reason: "Convert choice to required group",
                changes: [
                    .init(kind: .replace, summary: "Convert choice to required group", entityID: choiceID),
                ],
                transform: { [self] workout in
                    guard case .choice? = workout.findNode(choiceID) else {
                        return .notFound(missingTarget("choice", name: "", id: choiceID))
                    }
                    guard workout.convertChoiceToRequiredGroup(choiceID) else {
                        return .notFound(missingTarget("choice", name: "", id: choiceID))
                    }
                    return nil
                }
            ))

        case .updateRest(let restID, let patch):
            guard patch.isUnchanged == false else {
                return .failure(.notFound("Include at least one rest detail to change."))
            }
            guard patch.label != .clear else {
                return .failure(.notFound("A rest label can't be cleared. Set a new label or omit it."))
            }
            guard patch.placement != .clear else {
                return .failure(.notFound(
                    "A rest placement can't be cleared. Set inline, betweenRepetitions, "
                        + "afterEveryRepetition, or afterFinalRepetition."
                ))
            }
            return .success(PreparedEdit(
                reason: "Update rest",
                changes: [.init(kind: .edit, summary: "Update rest", entityID: restID)],
                transform: { [self] workout in
                    guard case .rest? = workout.findNode(restID) else {
                        return .notFound(missingTarget("rest", name: "", id: restID))
                    }
                    if case .set(let seconds) = patch.durationSeconds, seconds < 0 {
                        return .notFound("A rest duration must be zero or more seconds.")
                    }
                    guard workout.updateRest(restID, { updated in
                        if case .set(let value) = patch.label { updated.label = value }
                        if case .set(let value) = patch.placement { updated.placement = value }
                        switch patch.durationSeconds {
                        case .unchanged: break
                        case .set(let value): updated.durationSeconds = value
                        case .clear: updated.durationSeconds = nil
                        }
                        switch patch.guidance {
                        case .unchanged: break
                        case .set(let value): updated.guidance = value
                        case .clear: updated.guidance = nil
                        }
                    }) else {
                        return .notFound(missingTarget("rest", name: "", id: restID))
                    }
                    return nil
                }
            ))

        case .addRest(let parentID, let atIndex, let durationSeconds, let placement, let label, let guidance):
            if let durationSeconds, durationSeconds < 0 {
                return .failure(.notFound("A rest duration must be zero or more seconds."))
            }
            var addedRestID: UUID?
            return .success(PreparedEdit(
                reason: "Add rest",
                changes: [.init(kind: .add, summary: "Add rest", entityID: nil)],
                transform: { [self] workout in
                    guard let container = workout.nodeContainer(parentID) else {
                        return .notFound(missingTarget("block or group", name: "", id: parentID))
                    }
                    if case .choice = container {
                        return .notFound("A rest can't be a choice option. Add it to a block or group instead.")
                    }
                    let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rest = PlannedRest(
                        durationSeconds: durationSeconds,
                        placement: placement,
                        label: trimmedLabel?.isEmpty == false ? trimmedLabel! : "Rest",
                        guidance: guidance
                    )
                    let count = workout.nodes(in: container)?.count ?? 0
                    guard workout.insertNode(.rest(rest), into: parentID, at: atIndex) else {
                        return .notFound("Rest position must be between 0 and \(count).")
                    }
                    addedRestID = rest.id
                    return nil
                },
                resolvedEntityIDs: { addedRestID.map { [$0] } ?? [] }
            ))

        case .moveNode(let nodeID, let toParentID, let toIndex):
            var movedOptionIDs: Set<UUID> = []
            return .success(PreparedEdit(
                reason: "Move workout node",
                changes: [.init(kind: .move, summary: "Move workout node", entityID: nodeID)],
                transform: { [self] workout in
                    let source = workout.locateNode(nodeID)
                    if let failure = workout.moveNode(nodeID, into: toParentID, at: toIndex) {
                        return .notFound(
                            nodeStructureMessage(failure, nodeID: nodeID, containerID: toParentID)
                        )
                    }
                    if case .choice(let choiceID)? = source?.container, choiceID != toParentID {
                        movedOptionIDs = [nodeID]
                    }
                    return nil
                },
                logTransform: { log in
                    log.removeChoiceSelections(optionIDs: movedOptionIDs)
                }
            ))

        case .removeNode(let nodeID):
            var removedExerciseIDs: [UUID] = []
            var removedGroupIDs: Set<UUID> = []
            var removedChoiceIDs: Set<UUID> = []
            var removedOptionIDs: Set<UUID> = []
            return .success(PreparedEdit(
                reason: "Remove workout node",
                changes: [.init(kind: .remove, summary: "Remove workout node", entityID: nodeID)],
                transform: { [self] workout in
                    let source = workout.locateNode(nodeID)
                    switch workout.removeNode(nodeID) {
                    case .failure(let failure):
                        return .notFound(nodeStructureMessage(failure, nodeID: nodeID, containerID: nil))
                    case .success(let removed):
                        removedExerciseIDs = removed.exercises.map(\.id)
                        removedGroupIDs = Set(removed.groups.map(\.id))
                        removedChoiceIDs = Set(removed.choices.map(\.id))
                        if case .choice? = source?.container { removedOptionIDs = [nodeID] }
                        return nil
                    }
                },
                logTransform: { log in
                    for exerciseID in removedExerciseIDs { log.removePerformed(forPlanned: exerciseID) }
                    log.removeGroups(forPlanned: removedGroupIDs)
                    log.removeChoices(forPlanned: removedChoiceIDs)
                    log.removeChoiceSelections(optionIDs: removedOptionIDs)
                }
            ))

        case .addSetAlternative(let setID, let label, let values, let ranges):
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLabel.isEmpty == false else {
                return .failure(.notFound("A set alternative needs a non-empty label."))
            }
            var addedAlternativeID: UUID?
            return .success(PreparedEdit(
                reason: "Add set alternative",
                changes: [.init(kind: .add, summary: "Add set alternative", entityID: nil)],
                transform: { [self] workout in
                    guard let exercise = workout.allExercises.first(where: { exercise in
                        exercise.prescription.sets.contains { $0.id == setID }
                    }) else {
                        return .notFound(missingTarget("set", name: "", id: setID))
                    }
                    for (metric, value) in values.metrics {
                        if let failure = invalidMetricValue(metric: metric, value: value, exercise: exercise) {
                            return .notFound(failure)
                        }
                    }
                    if let failure = invalidTargets(.init(ranges: ranges), exercise: exercise) {
                        return .notFound(failure)
                    }
                    let alternative = PlannedSetAlternative(
                        label: trimmedLabel,
                        values: metricValues(values),
                        ranges: ranges
                    )
                    guard workout.updateSet(setID, { updated in
                        updated.alternatives.append(alternative)
                    }) else {
                        return .notFound(missingTarget("set", name: "", id: setID))
                    }
                    addedAlternativeID = alternative.id
                    return nil
                },
                resolvedEntityIDs: { addedAlternativeID.map { [$0] } ?? [] }
            ))

        case .updateSetAlternative(let alternativeID, let patch):
            guard patch.isUnchanged == false else {
                return .failure(.notFound("Include at least one alternative detail to change."))
            }
            guard patch.label != .clear else {
                return .failure(.notFound("An alternative label can't be cleared. Set a new label or omit it."))
            }
            return .success(PreparedEdit(
                reason: "Update set alternative",
                changes: [.init(kind: .edit, summary: "Update set alternative", entityID: alternativeID)],
                transform: { [self] workout in
                    guard let owner = setAlternativeOwner(alternativeID, in: workout) else {
                        return .notFound(missingTarget("set alternative", name: "", id: alternativeID))
                    }
                    if case .set(let valuesPatch) = patch.values {
                        for (metric, metricPatch) in valuesPatch.metrics {
                            if case .set(let value) = metricPatch,
                               let failure = invalidMetricValue(
                                   metric: metric,
                                   value: value,
                                   exercise: owner.exercise
                               ) {
                                return .notFound(failure)
                            }
                        }
                    }
                    if case .set(let ranges) = patch.ranges,
                       let failure = invalidTargets(.init(ranges: ranges), exercise: owner.exercise) {
                        return .notFound(failure)
                    }
                    guard workout.updateSet(owner.setID, { updated in
                        guard let index = updated.alternatives.firstIndex(where: { $0.id == alternativeID })
                        else { return }
                        if case .set(let value) = patch.label { updated.alternatives[index].label = value }
                        switch patch.values {
                        case .unchanged:
                            break
                        case .clear:
                            updated.alternatives[index].values = MetricValues()
                        case .set(let valuesPatch):
                            for (metric, metricPatch) in valuesPatch.metrics {
                                switch metricPatch {
                                case .unchanged: break
                                case .set(let value): updated.alternatives[index].values[metric] = value
                                case .clear: updated.alternatives[index].values[metric] = nil
                                }
                            }
                        }
                        switch patch.ranges {
                        case .unchanged: break
                        case .set(let value): updated.alternatives[index].ranges = value
                        case .clear: updated.alternatives[index].ranges = []
                        }
                    }) else {
                        return .notFound(missingTarget("set alternative", name: "", id: alternativeID))
                    }
                    return nil
                }
            ))

        case .removeSetAlternative(let alternativeID):
            return .success(PreparedEdit(
                reason: "Remove set alternative",
                changes: [.init(kind: .remove, summary: "Remove set alternative", entityID: alternativeID)],
                transform: { [self] workout in
                    guard let owner = setAlternativeOwner(alternativeID, in: workout) else {
                        return .notFound(missingTarget("set alternative", name: "", id: alternativeID))
                    }
                    guard workout.updateSet(owner.setID, { updated in
                        updated.alternatives.removeAll { $0.id == alternativeID }
                    }) else {
                        return .notFound(missingTarget("set alternative", name: "", id: alternativeID))
                    }
                    return nil
                }
            ))

        case .updateExercisePrescription(let exerciseInstanceID, let patch):
            guard patch.isUnchanged == false else {
                return .failure(.notFound("Include at least one prescription detail to change."))
            }
            return .success(PreparedEdit(
                reason: "Update exercise prescription",
                changes: [
                    .init(kind: .edit, summary: "Update exercise prescription", entityID: exerciseInstanceID),
                ],
                transform: { [self] workout in
                    guard workout.exercise(exerciseInstanceID) != nil else {
                        return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
                    }
                    if case .set(let seconds) = patch.restSeconds, seconds < 0 {
                        return .notFound("rest_seconds must be zero or more.")
                    }
                    if case .set(let zone) = patch.targetZone, (1...5).contains(zone) == false {
                        return .notFound("target_zone must be a heart-rate zone between 1 and 5.")
                    }
                    if case .set(let targets) = patch.intensityTargets {
                        for target in targets {
                            if let failure = invalidIntensityTarget(target) {
                                return .notFound(failure)
                            }
                        }
                    }
                    guard workout.updateExercise(exerciseInstanceID, { updated in
                        switch patch.restSeconds {
                        case .unchanged: break
                        case .set(let value): updated.prescription.restSeconds = value
                        case .clear: updated.prescription.restSeconds = nil
                        }
                        switch patch.tempo {
                        case .unchanged: break
                        case .set(let value): updated.prescription.tempo = value
                        case .clear: updated.prescription.tempo = nil
                        }
                        switch patch.targetZone {
                        case .unchanged: break
                        case .set(let value): updated.prescription.targetZone = value
                        case .clear: updated.prescription.targetZone = nil
                        }
                        switch patch.intent {
                        case .unchanged: break
                        case .set(let value): updated.prescription.intent = value
                        case .clear: updated.prescription.intent = nil
                        }
                        switch patch.intensityTargets {
                        case .unchanged: break
                        case .set(let value): updated.prescription.intensityTargets = value
                        case .clear: updated.prescription.intensityTargets = []
                        }
                    }) else {
                        return .notFound(missingTarget("exercise", name: "", id: exerciseInstanceID))
                    }
                    return nil
                }
            ))
        }
    }

    // MARK: - Wave 8 validation helpers

    /// Group totals aren't scoped to one exercise's supported metrics, so only value sanity applies.
    private func invalidGroupMetricValue(metric: MetricType, value: Double) -> String? {
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

    private func invalidAdjustment(_ adjustment: MetricAdjustment) -> String? {
        guard adjustment.step.isFinite, adjustment.step != 0 else {
            return "An adjustment step must be a finite non-zero value."
        }
        if let minimum = adjustment.minimum, let maximum = adjustment.maximum, minimum > maximum {
            return "An adjustment's minimum can't exceed its maximum."
        }
        return nil
    }

    private func invalidProgression(_ progression: MetricProgression, exercise: PlannedExercise) -> String? {
        guard exercise.supportedMetrics.contains(progression.metric) else {
            return "\(exercise.exerciseName) doesn't support \(progression.metric.label.lowercased())."
        }
        guard progression.delta.isFinite, progression.delta != 0 else {
            return "A progression delta must be a finite non-zero value."
        }
        guard progression.every >= 1 else {
            return "A progression's every must be at least 1."
        }
        return nil
    }

    private func invalidIntensityTarget(_ target: IntensityTarget) -> String? {
        switch target {
        case .heartRateZone(let zone):
            guard (1...5).contains(zone) else {
                return "A heart-rate zone target must be between 1 and 5."
            }
        case .rpe(let lower, let upper):
            guard lower.isFinite, upper.isFinite, lower >= 0, upper <= 10, lower <= upper else {
                return "An RPE intensity range must be within 0-10 with lower not above upper."
            }
        case .power(let lower, let upper, let unit):
            guard lower.isFinite, upper.isFinite, lower >= 0, lower <= upper else {
                return "A power range must be non-negative with lower not above upper."
            }
            guard unit == .watts else { return "Power targets are stated in watts." }
        case .thresholdPercentage(let lower, let upper):
            guard lower.isFinite, upper.isFinite, lower > 0, lower <= upper else {
                return "A threshold percentage range must be positive with lower not above upper."
            }
        case .pace(let text), .descriptive(let text):
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return "An intensity target description can't be empty."
            }
        case .namedZone(let system, let range):
            guard system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return "A named zone target needs both a system and a range."
            }
        }
        return nil
    }

    /// Where an alternative lives: the owning exercise (for metric validation) and its set ID.
    private func setAlternativeOwner(
        _ alternativeID: UUID,
        in workout: Workout
    ) -> (exercise: PlannedExercise, setID: UUID)? {
        for exercise in workout.allExercises {
            for set in exercise.prescription.sets
            where set.alternatives.contains(where: { $0.id == alternativeID }) {
                return (exercise, set.id)
            }
        }
        return nil
    }

    private func nodeStructureMessage(
        _ failure: WorkoutNodeStructureError,
        nodeID: UUID,
        containerID: UUID?
    ) -> String {
        switch failure {
        case .nodeNotFound:
            missingTarget("node", name: "", id: nodeID)
        case .containerNotFound:
            missingTarget("block, group, or choice", name: "", id: containerID)
        case .cycle:
            "A node can't be moved into itself or its own children."
        case .invalidChild:
            "A rest can't be a choice option. Move it into a block or group instead."
        case .indexOutOfBounds(let max):
            "to_index is outside the destination's final order (0 to \(max))."
        case .lastChoiceOption:
            "That's the choice's only option, so moving or removing it would leave the choice empty. "
                + "Remove or convert the choice itself instead."
        }
    }

    // MARK: - Bulk selector mutations (Wave 7)

    /// A bulk tool's result. `applied` and `preview` carry the enumerated match detail so what the
    /// selector actually touched (or would touch) is never silent; `rejected` carries a correctable
    /// message, including unknown-taxonomy-value corrections.
    enum BulkMutationOutcome: Equatable {
        case applied(WorkoutMutationReceipt, detail: String)
        case preview(detail: String)
        case rejected(String)
    }

    /// One resolved instance a selector matched (or could not classify), with the context a model
    /// needs to confirm the match set with the athlete.
    private struct SelectorInstance {
        var id: UUID
        var name: String
        var blockName: String
        var definition: ExerciseDefinition?

        var line: String {
            let location = blockName.trimmingCharacters(in: .whitespacesAndNewlines)
            let place = location.isEmpty ? "" : " in \(location)"
            let identity = definition.map { " (catalog id: \($0.id))" } ?? " (no catalog identity)"
            return "- \(name) [id: \(id.uuidString)]\(identity)\(place)"
        }
    }

    private struct SelectorMatches {
        var matched: [SelectorInstance]
        /// Instances a taxonomy-constrained selector could not classify because they carry no catalog
        /// identity. Reported, never silently skipped.
        var unclassified: [SelectorInstance]
    }

    /// Resolve a selector against one workout snapshot. Taxonomy values parse through the exact same
    /// `ExerciseSearch` rules the catalog search uses, so an unknown value comes back as a correctable
    /// message listing the valid values, and matching semantics can't drift from `search_exercises`.
    private enum SelectorResolution {
        case success(SelectorMatches)
        case failure(String)
    }

    private func resolveSelector(
        _ selector: BulkExerciseSelectorInput?,
        in workout: Workout
    ) -> SelectorResolution {
        var query = ExerciseSearch.Query()
        if let selector {
            switch ExerciseSearch.parse(
                muscle: selector.muscle,
                equipment: selector.equipment,
                modality: selector.modality,
                pattern: selector.pattern,
                tag: selector.tag,
                level: selector.level
            ) {
            case .failure(let unknown):
                return .failure(
                    "\"\(unknown.value)\" isn't a \(unknown.field) Baseline knows. "
                        + "Valid \(unknown.field) values: \(unknown.valid.joined(separator: ", "))."
                )
            case .success(let parsed):
                query = parsed
            }
            if let blockID = selector.blockID, workout.blocks.contains(where: { $0.id == blockID }) == false {
                return .failure(missingTarget("block", name: "", id: blockID))
            }
        }
        // A selector that constrains identity or taxonomy can only match classified instances; a
        // purely structural selector (block-only or absent) matches every instance it scopes to.
        let requiresIdentity = selector.map { $0.definitionID != nil || query.isEmpty == false } ?? false

        var matched: [SelectorInstance] = []
        var unclassified: [SelectorInstance] = []
        for block in workout.blocks {
            if let blockID = selector?.blockID, block.id != blockID { continue }
            for exercise in block.exercises {
                let definition = exercise.definitionId.flatMap { id in
                    customDefinitions.first { $0.id == id } ?? ExerciseCatalog.definition(id: id)
                }
                let label = exercise.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                let instance = SelectorInstance(
                    id: exercise.id,
                    name: label.flatMap { $0.isEmpty ? nil : $0 } ?? exercise.exerciseName,
                    blockName: block.name,
                    definition: definition
                )
                guard requiresIdentity else {
                    matched.append(instance)
                    continue
                }
                guard let definition else {
                    unclassified.append(instance)
                    continue
                }
                if let wanted = selector?.definitionID, definition.id != wanted { continue }
                guard ExerciseSearch.matches(definition, query) else { continue }
                matched.append(instance)
            }
        }
        return .success(SelectorMatches(matched: matched, unclassified: unclassified))
    }

    private static func selectorSummary(_ selector: BulkExerciseSelectorInput?) -> String {
        guard let selector else { return "every exercise in the workout" }
        var parts: [String] = []
        if let value = selector.definitionID { parts.append("catalog id \(value)") }
        if let value = selector.muscle { parts.append("muscle \(value)") }
        if let value = selector.equipment { parts.append("equipment \(value)") }
        if let value = selector.modality { parts.append("modality \(value)") }
        if let value = selector.pattern { parts.append("pattern \(value)") }
        if let value = selector.tag { parts.append("tag \(value)") }
        if let value = selector.level { parts.append("level \(value)") }
        if selector.blockID != nil { parts.append("one block") }
        return parts.isEmpty ? "every exercise in the workout" : parts.joined(separator: " + ")
    }

    private static func unclassifiedLines(_ instances: [SelectorInstance]) -> [String] {
        guard instances.isEmpty == false else { return [] }
        return ["Not matched — no catalog identity, so a taxonomy selector can't classify them (handle these individually):"]
            + instances.map(\.line)
    }

    /// Bulk display-unit override: sets the per-instance display unit for each requested metric on
    /// every matched instance that supports it, in ONE atomic, undoable mutation. Metric values stay
    /// canonical — this never rewrites a stored quantity, so nothing here converts anything; display
    /// conversion stays where it always was, in `displayUnit(_:for:)` and `MetricConvert`.
    func convertWorkoutUnits(
        units: [MetricType: MetricUnit],
        selector: BulkExerciseSelectorInput?,
        dryRun: Bool,
        expectedRevisionToken: UUID
    ) -> BulkMutationOutcome {
        guard units.isEmpty == false else {
            return .rejected("Include at least one display unit to set (distance, load, duration, or pace).")
        }
        let convertible: Set<MetricType> = [.distance, .load, .duration, .pace]
        for (metric, unit) in units {
            guard convertible.contains(metric) else {
                return .rejected(
                    "convert_workout_units only sets distance, load, duration, and pace display units; "
                        + "\(metric.label.lowercased()) has no alternate display unit."
                )
            }
            guard metric.displayUnits.contains(unit) else {
                return .rejected("\(unit.short) isn't a display unit for \(metric.label.lowercased()).")
            }
        }
        let scope = agentScope
        guard let workout = workout(scope), mutationTarget(scope) != nil else {
            return .rejected(sink == nil ? "There's no workout yet." : Self.missingPlanWorkout)
        }
        guard mutationTarget(scope)?.revisionToken == expectedRevisionToken else {
            return .rejected(Self.staleMutationMessage)
        }
        let matches: SelectorMatches
        switch resolveSelector(selector, in: workout) {
        case .failure(let message): return .rejected(message)
        case .success(let resolved): matches = resolved
        }

        // Which requested metrics actually apply per matched instance, in canonical metric order.
        let ordered = MetricType.allCases.compactMap { metric in units[metric].map { (metric, $0) } }
        var applicable: [(instance: SelectorInstance, units: [(MetricType, MetricUnit)])] = []
        for instance in matches.matched {
            guard let exercise = workout.exercise(instance.id) else { continue }
            let supported = ordered.filter { exercise.supportedMetrics.contains($0.0) }
            if supported.isEmpty == false { applicable.append((instance, supported)) }
        }

        let requestedList = ordered
            .map { "\($0.0.label.lowercased()) → \($0.1.short)" }
            .joined(separator: ", ")
        guard applicable.isEmpty == false else {
            let lines = [
                "No exercise matching \(Self.selectorSummary(selector)) supports \(requestedList), so nothing was changed.",
            ] + Self.unclassifiedLines(matches.unclassified)
            return .rejected(lines.joined(separator: "\n"))
        }

        func enumeration(_ header: String) -> String {
            var lines = [header]
            lines += applicable.map { entry in
                let applied = entry.units.map { "\($0.0.label.lowercased()) → \($0.1.short)" }.joined(separator: ", ")
                return entry.instance.line + ": \(applied)"
            }
            lines += Self.unclassifiedLines(matches.unclassified)
            return lines.joined(separator: "\n")
        }

        let count = applicable.count
        if dryRun {
            var detail = enumeration(
                "DRY RUN — convert_workout_units would set \(requestedList) on \(count) exercise "
                    + "instance\(count == 1 ? "" : "s"); nothing was changed:"
            )
            detail += "\nIf this is exactly the athlete's intent, call convert_workout_units again with "
                + "dry_run false and the same expected_revision_token. Display only — stored values stay canonical."
            return .preview(detail: detail)
        }

        let changes = applicable.map { entry in
            let applied = entry.units.map { "\($0.0.label.lowercased()) → \($0.1.short)" }.joined(separator: ", ")
            return WorkoutMutationDiff.Change(
                kind: .edit,
                summary: "Set display \(applied) on \(entry.instance.name)",
                entityID: entry.instance.id
            )
        }
        let outcome = mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Convert workout display units",
            diff: WorkoutMutationDiff(changes: changes)
        ) { workout in
            for entry in applicable {
                guard workout.updateExercise(entry.instance.id, { updated in
                    for (metric, unit) in entry.units { updated.displayUnits[metric] = unit }
                }) else {
                    return .notFound(missingTarget("exercise", name: entry.instance.name, id: entry.instance.id))
                }
            }
            return nil
        }
        switch outcome {
        case .mutated(let receipt):
            let detail = enumeration(
                "Set \(requestedList) display on \(count) exercise instance\(count == 1 ? "" : "s") "
                    + "(stored values stay canonical):"
            )
            return .applied(receipt, detail: detail)
        case .notFound(let message), .ambiguous(let message):
            return .rejected(message)
        case .done:
            return .rejected("I couldn't apply that unit change.")
        }
    }

    /// Semantic bulk replacement: every instance the explicit taxonomy selector matches becomes the
    /// one replacement definition, atomically, preserving each instance's ID, sets, targets, notes,
    /// and order — `replace_exercise` semantics applied N times inside one envelope commit. The
    /// dry-run (and the applied receipt) enumerate the exact matched instance IDs and names, so the
    /// model confirms against the real match set instead of guessing what "all runs" means.
    func bulkReplaceExercises(
        selector: BulkExerciseSelectorInput,
        replacementDefinitionID: String,
        dryRun: Bool,
        expectedRevisionToken: UUID
    ) -> BulkMutationOutcome {
        guard selector.isEmpty == false else {
            return .rejected(
                "bulk_replace_exercises needs at least one selector field "
                    + "(definition_id, muscle, equipment, modality, pattern, tag, level, or block_id)."
            )
        }
        let replacement = customDefinitions.first { $0.id == replacementDefinitionID }
            ?? ExerciseCatalog.definition(id: replacementDefinitionID)
        guard let replacement else {
            return .rejected(
                "\"\(replacementDefinitionID)\" isn't a catalog exercise id. "
                    + "Use search_exercises or get_exercise to find the exact id — don't guess one."
            )
        }
        let scope = agentScope
        guard let workout = workout(scope), mutationTarget(scope) != nil else {
            return .rejected(sink == nil ? "There's no workout yet." : Self.missingPlanWorkout)
        }
        guard mutationTarget(scope)?.revisionToken == expectedRevisionToken else {
            return .rejected(Self.staleMutationMessage)
        }
        let matches: SelectorMatches
        switch resolveSelector(selector, in: workout) {
        case .failure(let message): return .rejected(message)
        case .success(let resolved): matches = resolved
        }

        var toReplace: [SelectorInstance] = []
        var alreadyReplacement: [SelectorInstance] = []
        for instance in matches.matched {
            if instance.definition?.id == replacement.id {
                alreadyReplacement.append(instance)
            } else {
                toReplace.append(instance)
            }
        }

        func excludedLines() -> [String] {
            var lines = Self.unclassifiedLines(matches.unclassified)
            if alreadyReplacement.isEmpty == false {
                lines.append("Already \(replacement.name), so unchanged:")
                lines += alreadyReplacement.map(\.line)
            }
            return lines
        }

        guard toReplace.isEmpty == false else {
            let lines = [
                "No exercise matching \(Self.selectorSummary(selector)) needs replacing, so nothing was changed.",
            ] + excludedLines()
            return .rejected(lines.joined(separator: "\n"))
        }

        let count = toReplace.count
        if dryRun {
            var lines = [
                "DRY RUN — bulk_replace_exercises matched \(count) exercise instance\(count == 1 ? "" : "s") "
                    + "for \(Self.selectorSummary(selector)); nothing was changed:",
            ]
            lines += toReplace.map(\.line)
            lines += excludedLines()
            lines.append(
                "Each would become \(replacement.name) (\(replacement.id)), keeping its sets, targets, "
                    + "notes, and order. If this exact set is what the athlete means, call "
                    + "bulk_replace_exercises again with dry_run false and the same "
                    + "expected_revision_token. If the athlete's phrasing could mean a different set, "
                    + "confirm with them first."
            )
            return .preview(detail: lines.joined(separator: "\n"))
        }

        let changes = toReplace.map { instance in
            WorkoutMutationDiff.Change(
                kind: .replace,
                summary: "Replace \(instance.name) with \(replacement.name)",
                entityID: instance.id
            )
        }
        let outcome = mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Bulk replace \(count) exercises with \(replacement.name)",
            diff: WorkoutMutationDiff(changes: changes)
        ) { workout in
            for instance in toReplace {
                guard applyReplacement(replacement, to: instance.id, in: &workout) else {
                    return .notFound(missingTarget("exercise", name: instance.name, id: instance.id))
                }
            }
            return nil
        }
        switch outcome {
        case .mutated(let receipt):
            noteRecent(replacement.id)
            var lines = ["Replaced \(count) exercise instance\(count == 1 ? "" : "s") with \(replacement.name):"]
            lines += toReplace.map(\.line)
            lines += excludedLines()
            return .applied(receipt, detail: lines.joined(separator: "\n"))
        case .notFound(let message), .ambiguous(let message):
            return .rejected(message)
        case .done:
            return .rejected("I couldn't apply that replacement.")
        }
    }

    // MARK: - Wave 9: deliberate custom exercise creation (two-phase proposal → envelope commit)

    /// The validated wire payload for `create_custom_exercise`. `level` stays nil when the athlete
    /// didn't state one - the commit defaults it to intermediate and the proposal marks it as a
    /// default, so an inferred value is never committed as if the athlete chose it.
    struct CustomExerciseDraft: Sendable, Equatable {
        var name: String
        var equipment: [Equipment]
        var primaryMuscles: [Muscle]
        var secondaryMuscles: [Muscle]
        var metrics: [MetricType]
        var patterns: [MovementPattern]
        var tags: [ExerciseTag]
        var level: ExerciseLevel?
        /// Future display-unit defaults for the new movement (the Wave 4 unit vocabulary), applied
        /// to `preferences.unitsByExercise` on commit.
        var units: [MetricType: MetricUnit]
    }

    enum CustomExerciseCreationOutcome: Equatable {
        /// Phase 1: the exact definition a confirming call would commit. Nothing was created.
        case proposal(String)
        /// The movement already exists; nothing was created and the reply names the existing one.
        case existing(String)
        case created(WorkoutMutationReceipt, String)
        case rejected(String)
    }

    private var pendingCustomExerciseProposal: (id: UUID, draft: CustomExerciseDraft)?
    /// The newest committed creation, so undoing exactly that mutation receipt also removes the
    /// definition (and its unit defaults). Older creations become permanently unreachable through
    /// the envelope's plan-head staleness rule, so one record is enough.
    private var latestCustomExerciseCreation: (mutationID: UUID, definitionID: String)?

    func createCustomExercise(
        draft: CustomExerciseDraft,
        proposalID: UUID?,
        expectedRevisionToken: UUID
    ) -> CustomExerciseCreationOutcome {
        if let message = validationFailure(for: draft) { return .rejected(message) }
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // The manual path's duplicate rule (`createCustomDefinition` reuses an existing same-named
        // custom) surfaced honestly, instead of silently returning an old definition under a
        // "created" claim.
        let key = trimmedName.lowercased()
        if let existing = customDefinitions.first(where: { $0.name.lowercased() == key || $0.aliases.contains(key) }) {
            pendingCustomExerciseProposal = nil
            return .existing(
                "A custom exercise named \"\(existing.name)\" already exists (id \(existing.id)) - "
                    + "nothing new was created. Use it directly: add_exercise and replace_exercise "
                    + "resolve it by that name. \(classificationSummary(of: existing))"
            )
        }

        // Envelope preconditions checked up front, so even the read-only proposal phase is truthful
        // about a missing workout or a stale revision token.
        guard let target = mutationTarget(agentScope) else {
            return .rejected(sink == nil ? "There's no workout yet." : Self.missingPlanWorkout)
        }
        guard target.revisionToken == expectedRevisionToken else {
            return .rejected(Self.staleMutationMessage)
        }

        guard let proposalID else {
            let id = UUID()
            pendingCustomExerciseProposal = (id, draft)
            return .proposal(proposalText(for: draft, name: trimmedName, proposalID: id))
        }
        guard let pending = pendingCustomExerciseProposal, pending.id == proposalID else {
            return .rejected(
                "That proposal id doesn't match an open proposal, so nothing was created. "
                    + "Call create_custom_exercise again without proposal_id for a fresh proposal."
            )
        }
        guard pending.draft == draft else {
            // The fields changed after the proposal: what the athlete confirmed is not what this
            // call would commit. Re-propose so the confirmation covers the actual content.
            let id = UUID()
            pendingCustomExerciseProposal = (id, draft)
            return .proposal(
                "The fields changed since that proposal, so nothing was created - confirm this "
                    + "updated classification instead.\n"
                    + proposalText(for: draft, name: trimmedName, proposalID: id)
            )
        }

        // The workout itself is untouched; the envelope contributes the revision-token guard, the
        // persisted receipt, and receipt-addressed undo for a deliberate catalog change. The
        // definition is created only after the envelope accepts the mutation, so a rejected write
        // never leaves a half-committed catalog entry.
        let outcome = mutate(
            expectedRevisionToken: expectedRevisionToken,
            reason: "Create custom exercise \(trimmedName)",
            diff: WorkoutMutationDiff(changes: [
                .init(kind: .add, summary: "Create custom exercise \"\(trimmedName)\"", entityID: target.workoutID),
            ])
        ) { _ in nil }
        switch outcome {
        case .mutated(let receipt):
            let definition = createCustomDefinition(
                name: trimmedName,
                supported: draft.metrics,
                equipment: draft.equipment,
                primaryMuscles: draft.primaryMuscles,
                secondaryMuscles: draft.secondaryMuscles,
                patterns: draft.patterns,
                tags: draft.tags,
                level: draft.level ?? .intermediate
            )
            if !draft.units.isEmpty { preferences.unitsByExercise[definition.id] = draft.units }
            latestCustomExerciseCreation = (receipt.mutationID, definition.id)
            pendingCustomExerciseProposal = nil
            return .created(
                receipt,
                "Created custom exercise \"\(definition.name)\" (id \(definition.id)). "
                    + "\(classificationSummary(of: definition)) It's immediately addable by that "
                    + "exact name with add_exercise or replace_exercise."
            )
        case .notFound(let message), .ambiguous(let message):
            return .rejected(message)
        case .done:
            return .rejected("I couldn't create that custom exercise.")
        }
    }

    /// Mirrors `CustomExerciseForm`'s create gate and picker caps exactly: name, at least one
    /// equipment value, one primary muscle, and one metric are required; patterns cap at two. The
    /// agent path must not accept a definition the manual form would refuse.
    private func validationFailure(for draft: CustomExerciseDraft) -> String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A custom exercise needs a name."
        }
        if draft.equipment.isEmpty {
            return "A custom exercise needs at least one equipment value (bodyweight counts)."
        }
        if draft.primaryMuscles.isEmpty {
            return "A custom exercise needs at least one primary muscle."
        }
        if draft.metrics.isEmpty {
            return "A custom exercise needs at least one metric it can log."
        }
        if draft.patterns.count > 2 {
            return "A custom exercise carries at most two movement patterns - keep the dominant one or two."
        }
        for (metric, unit) in draft.units {
            guard draft.metrics.contains(metric) else {
                return "A display default for \(metric.label.lowercased()) needs \(metric.label.lowercased()) in the metrics list."
            }
            guard metric.displayUnits.contains(unit) else {
                return "\(unit.rawValue) isn't a display unit \(metric.label.lowercased()) offers."
            }
        }
        return nil
    }

    private func proposalText(for draft: CustomExerciseDraft, name: String, proposalID: UUID) -> String {
        let modality = Modality.inferred(fromMetrics: draft.metrics)
        let category = ActivityCategory.legacy(modality: modality, patterns: draft.patterns)
        var lines = ["PROPOSAL - nothing created yet. Custom exercise \"\(name)\" would be committed as:"]
        lines.append("- equipment: \(draft.equipment.map(\.displayName).joined(separator: ", "))")
        lines.append("- primary muscles: \(draft.primaryMuscles.map(\.displayName).joined(separator: ", "))")
        if !draft.secondaryMuscles.isEmpty {
            lines.append("- secondary muscles: \(draft.secondaryMuscles.map(\.displayName).joined(separator: ", "))")
        }
        lines.append("- metrics it logs: \(draft.metrics.map(\.label).joined(separator: ", "))")
        if !draft.patterns.isEmpty {
            lines.append("- movement patterns: \(draft.patterns.map(\.displayName).joined(separator: ", "))")
        }
        if !draft.tags.isEmpty {
            lines.append("- tags: \(draft.tags.map(\.displayName).joined(separator: ", "))")
        }
        if let level = draft.level {
            lines.append("- level: \(level.displayName)")
        } else {
            lines.append("- level: Intermediate (DEFAULT - the athlete didn't state one)")
        }
        lines.append("- modality: \(modality.rawValue) (DERIVED from its metrics)")
        lines.append("- category: \(category.rawValue) (DERIVED)")
        if !draft.units.isEmpty {
            let units = draft.units
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.label.lowercased()) in \($0.value.rawValue)" }
            lines.append("- display defaults: \(units.joined(separator: ", "))")
        }
        lines.append(contentsOf: curatedCatalogNotes(for: name))
        lines.append(
            "Relay this classification to the athlete and confirm every part they didn't state "
                + "themselves - then call create_custom_exercise again with the same fields plus "
                + "proposal_id \"\(proposalID.uuidString)\"."
        )
        return lines.joined(separator: "\n")
    }

    /// The curated catalog's view of the proposed name: an exact name/alias hit is a shadowing
    /// warning, and near-misses are surfaced because the right fix is usually the real movement.
    private func curatedCatalogNotes(for name: String) -> [String] {
        let key = name.lowercased()
        if let curated = ExerciseCatalog.lookUp(name: name, id: nil),
           curated.name.lowercased() == key || curated.aliases.contains(key) {
            return [
                "WARNING: the catalog already has \"\(curated.name)\" (id \(curated.id)). Prefer using "
                    + "it - a custom with the same name shadows the catalog entry whenever the name is used.",
            ]
        }
        guard case .success(let query) = ExerciseSearch.parse(text: name) else { return [] }
        let similar = ExerciseCatalog.search(query).matches.prefix(3)
        guard !similar.isEmpty else { return [] }
        let rows = similar.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
        return ["Similar catalog movements: \(rows). If one of these is the movement, use it instead of creating a custom."]
    }

    private func classificationSummary(of definition: ExerciseDefinition) -> String {
        var parts = [
            "equipment: \(definition.equipment.map(\.displayName).joined(separator: ", "))",
            "primary muscles: \(definition.primaryMuscles.map(\.displayName).joined(separator: ", "))",
            "metrics: \(definition.supported.map(\.label).joined(separator: ", "))",
        ]
        if let level = definition.level { parts.append("level: \(level.displayName)") }
        if let modality = definition.modality { parts.append("modality: \(modality.rawValue)") }
        parts.append("category: \(definition.category.rawValue)")
        return "Classification - \(parts.joined(separator: "; "))."
    }

    /// The undo companion for a committed creation: when `undo_workout_mutation` reverts exactly
    /// that receipt, the definition it created (and its unit defaults) must disappear with it.
    private func revertCustomExerciseCreation(ifUndone mutationID: UUID) {
        guard let creation = latestCustomExerciseCreation, creation.mutationID == mutationID else { return }
        customDefinitions.removeAll { $0.id == creation.definitionID }
        preferences.unitsByExercise[creation.definitionID] = nil
        recentExerciseIds.removeAll { $0 == creation.definitionID }
        latestCustomExerciseCreation = nil
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
    ///
    /// The fallback covers a standalone (unbound) session, which has no plan session row to ask — but
    /// only while its log is still live. A completed log is not an active session: reporting one let
    /// callers that gate on "is a session running" act on a workout that had already finished.
    var activeSessionID: UUID? {
        if let session = sink?.activeSession() { return session.id }
        guard let log = currentLog, log.isComplete == false else { return nil }
        return log.id
    }

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
            "WORKOUT [id: \(w.id.uuidString)]: \(w.title)",
        ]
        // The workout's one note, under the same name the tool schema and the athlete's field use.
        // There is no workout-level guidance line to follow it - guidance starts at the block.
        lines.append(contentsOf: noteSummary(w.goal, label: "Note", indent: "  "))
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
                    lines.append("\(indent)    Alternative \(alternative.label) [id: \(alternative.id.uuidString)]: \(alternateValues.isEmpty ? "no values" : alternateValues.joined(separator: ", "))")
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
            lines.append("\(indent)REQUIRED GROUP [id: \(group.id.uuidString)]: \(group.label) — \(execution.joined(separator: "; "))")
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
            lines.append("\(indent)CHOICE [id: \(choice.id.uuidString)]: \(choice.label) — choose \(choice.selectionCount) of \(choice.options.count)")
            for (index, option) in choice.options.enumerated() {
                lines.append("\(indent)  OPTION \(index + 1) [node id: \(option.id.uuidString)]:")
                appendSummary(option, indent: "\(indent)    ", to: &lines)
            }

        case .rest(let rest):
            let duration = rest.durationSeconds.map { MetricFormat.duration(Double($0)) } ?? "unspecified duration"
            lines.append("\(indent)REST [id: \(rest.id.uuidString)]: \(rest.label) — \(duration), \(rest.placement.rawValue)")
            if let guidance = rest.guidance, !guidance.isEmpty { lines.append("\(indent)  Note: \(guidance)") }
        }
    }

    /// A free-form note inside a line-oriented summary: one labelled line, then the note's remaining
    /// lines indented under it. The athlete's note may run to several paragraphs, and a model asked to
    /// revise it echoes back what it read — flattening the breaks here would silently destroy them.
    private func noteSummary(_ note: String?, label: String, indent: String) -> [String] {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let noteLines = note.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = noteLines.first else { return [] }
        return ["\(indent)\(label): \(first)"]
            + noteLines.dropFirst().map { $0.isEmpty ? "" : "\(indent)  \($0)" }
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
        workout.replaceExercise(exerciseID, with: definition)
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
