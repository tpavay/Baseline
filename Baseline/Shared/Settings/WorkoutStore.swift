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
    private(set) var current: Workout? {
        didSet {
            persist(current, Self.key)
            // Bound to a Plan scheduled workout → write content through (a new revision). Coalesced for
            // the manual editor (flush on dismiss, no keystroke revisions); immediate for the agent.
            if let sink, !coalesceContent, !isSyncing, let c = current, c != oldValue { sink.pushWorkout(c) }
        }
    }
    /// The in-progress performed log (actual sets, skips, notes) once a workout is started. Distinct
    /// from `current` (the plan) — logging never mutates the plan.
    private(set) var currentLog: WorkoutLog? {
        didSet {
            persist(currentLog, Self.logKey)
            if let sink, !isSyncing, let l = currentLog, l != oldValue { sink.pushLog(l) }
        }
    }

    // MARK: - Plan binding (this store is the shared editing surface; a sink write-throughs to the repo)

    /// The write-through target when this store edits a Plan scheduled workout. Nil = standalone (legacy
    /// ad-hoc), which behaves exactly as before.
    struct PlanSink {
        let pushWorkout: (Workout) -> Void            // edit content → new immutable revision
        let pushLog: (WorkoutLog) -> Void             // log a set → the session log
        let start: () -> Void                         // begin the session in the plan
        let complete: () -> Void                      // freeze the completed log
        let discard: () -> Void
        let reload: () -> (workout: Workout, log: WorkoutLog?)?
    }
    private var sink: PlanSink?
    private var coalesceContent = false
    private var isSyncing = false                     // true while pulling from the plan → suppress push-back
    /// Set once at startup: makes a brand-new today scheduled workout in the plan (for the agent's
    /// create_workout when nothing is scheduled today) and returns a sink bound to it.
    var makeTodayScheduled: ((Workout) -> PlanSink?)?

    func bind(_ sink: PlanSink, coalesceContent: Bool) {
        self.sink = sink; self.coalesceContent = coalesceContent
        reloadFromPlan()
    }
    func unbind() { sink = nil; coalesceContent = false }

    /// Pull the authoritative workout + session back from the plan (suppressing write-back).
    func reloadFromPlan() {
        guard let s = sink?.reload() else { return }
        isSyncing = true; current = s.workout; currentLog = s.log; isSyncing = false
    }

    /// Push coalesced content edits to the plan on demand (the manual editor calls this on dismiss).
    func flush() { if let sink, let c = current { sink.pushWorkout(c) } }

    /// User-level display/metric preferences, keyed by exercise identity and by category — applied to
    /// *future* instances, so "use miles for Stationary Bike from now on" doesn't touch today's.
    struct ExercisePreferences: Codable, Equatable, Sendable {
        var selectedByExercise: [String: [MetricType]] = [:]
        var unitsByExercise: [String: [MetricType: MetricUnit]] = [:]
        var unitsByCategory: [String: [MetricType: MetricUnit]] = [:]
    }
    enum PreferenceScope: String, Sendable { case exercise, category }

    private(set) var preferences: ExercisePreferences { didSet { persist(preferences, Self.prefKey) } }
    /// Athlete-created exercise definitions (deliberate — never auto-created from a typo).
    private(set) var customDefinitions: [ExerciseDefinition] { didSet { persist(customDefinitions, Self.customKey) } }
    /// Recently-added exercise ids, most-recent first — for the catalog picker's "Recent" section.
    private(set) var recentExerciseIds: [String] { didSet { persist(recentExerciseIds, Self.recentKey) } }

    private let defaults: UserDefaults
    private static let key = "workout.current"
    private static let logKey = "workout.currentLog"
    private static let prefKey = "workout.preferences"
    private static let customKey = "workout.customDefinitions"
    private static let recentKey = "workout.recentExercises"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Workout.self, from: $0) }
        currentLog = defaults.data(forKey: Self.logKey).flatMap { try? JSONDecoder().decode(WorkoutLog.self, from: $0) }
        preferences = defaults.data(forKey: Self.prefKey).flatMap { try? JSONDecoder().decode(ExercisePreferences.self, from: $0) } ?? ExercisePreferences()
        customDefinitions = defaults.data(forKey: Self.customKey).flatMap { try? JSONDecoder().decode([ExerciseDefinition].self, from: $0) } ?? []
        recentExerciseIds = defaults.data(forKey: Self.recentKey).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
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
    func createCustomDefinition(name: String, category: ActivityCategory, supported: [MetricType]) -> ExerciseDefinition {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = customDefinitions.first(where: { $0.name.lowercased() == trimmed.lowercased() }) { return existing }
        let metrics = supported.isEmpty ? [.reps, .load] : supported
        let def = ExerciseDefinition(id: "custom_\(UUID().uuidString.prefix(8))", name: trimmed, category: category,
                                     supported: metrics, defaults: metrics, aliases: [trimmed.lowercased()])
        customDefinitions.append(def)
        return def
    }

    /// Add a fully-built planned exercise (from the catalog picker) to a block, tracking recents.
    func addExercise(_ exercise: PlannedExercise, toBlockID blockID: UUID) {
        guard var w = current else { return }
        _ = w.addExercise(exercise, toBlock: blockID)
        current = w
        if let id = exercise.definitionId { noteRecent(id) }
    }

    private func noteRecent(_ id: String) {
        recentExerciseIds.removeAll { $0 == id }
        recentExerciseIds.insert(id, at: 0)
        if recentExerciseIds.count > 12 { recentExerciseIds = Array(recentExerciseIds.prefix(12)) }
    }

    /// The display unit for a metric on a planned exercise: this-instance override → per-exercise
    /// preference → per-category preference → canonical.
    func displayUnit(_ metric: MetricType, for ex: PlannedExercise) -> MetricUnit {
        if let u = ex.displayUnits[metric] { return u }
        if let id = ex.definitionId {
            if let u = preferences.unitsByExercise[id]?[metric] { return u }
            if let cat = ExerciseCatalog.definition(id: id)?.category.rawValue, let u = preferences.unitsByCategory[cat]?[metric] { return u }
        }
        return metric.canonicalUnit
    }

    // MARK: - UI-facing edits (id-based; the manual screen drives the same model the agent does)

    /// Apply an id-based structural edit to the plan (add/remove/reorder/move/substitute). Write-through
    /// to the plan (if bound) happens in `current`'s didSet.
    func edit(_ transform: (inout Workout) -> Void) {
        guard var w = current else { return }
        transform(&w)
        current = w
    }

    /// Begin performing. Bound → the plan creates the session; unbound → a local performed log.
    func startWorkout() {
        if let sink {
            sink.start()
            isSyncing = true; currentLog = sink.reload()?.log; isSyncing = false
        } else {
            guard let w = current, currentLog == nil else { return }
            currentLog = w.startLog()
        }
    }

    /// Apply an edit to the performed log (log a set, skip/complete, note). Write-through in didSet.
    func editLog(_ transform: (inout WorkoutLog) -> Void) {
        guard var l = currentLog else { return }
        transform(&l)
        currentLog = l
    }

    func completeWorkout() {
        if let sink { sink.complete(); reloadFromPlan() }
        else { editLog { $0.isComplete = true } }
    }
    func discardLog() {
        sink?.discard()
        isSyncing = true; currentLog = nil; isSyncing = false
    }

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
        w.blocks = [WorkoutBlock(name: "", isDefault: true)]   // implicit default block (hidden until structured)

        if sink != nil {
            current = w             // already bound → didSet write-throughs (replaces today's content)
            isSyncing = true; currentLog = nil; isSyncing = false
        } else if let make = makeTodayScheduled, let newSink = make(w) {
            // Nothing scheduled today yet → the factory already put `w` in the plan; bind without re-pushing.
            sink = newSink; coalesceContent = false
            isSyncing = true; current = w; currentLog = nil; isSyncing = false
        } else {
            current = w; currentLog = nil   // standalone (no plan)
        }
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
                     sets: Int?, reps: Int?, load: Double?, durationSeconds: Int?,
                     distanceMeters: Double? = nil) -> EditOutcome {
        guard var w = current else { return .notFound("There's no workout yet — create one first.") }
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
        current = w
        if let id = exercise.definitionId { noteRecent(id) }
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
                   reps: Int?, load: Double?, durationSeconds: Int?, distanceMeters: Double? = nil, rpe: Double?) -> EditOutcome {
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
            if let distanceMeters { s.distance = clampLoad(distanceMeters) }
            if let rpe { s.rpe = clampRPE(rpe) }
        }
        current = w
        return .done
    }

    // MARK: - Logging configuration & values (metric system)

    /// THIS WORKOUT: choose which metrics an exercise logs + per-instance unit overrides. Rejects
    /// metrics the exercise doesn't support.
    @discardableResult
    func setLoggingConfig(exerciseNamed name: String, enabled: [MetricType]?, units: [MetricType: MetricUnit] = [:]) -> EditOutcome {
        guard var w = current else { return .notFound("There's no workout yet.") }
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
        current = w
        return .done
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
        guard var w = current else { return .notFound("There's no workout yet.") }
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
        let canonical = max(0, MetricConvert.toCanonical(value, metric, from: unit ?? metric.canonicalUnit))
        w.updateExercise(exID) { e in
            e.prescription.sets[setNumber - 1].values[metric] = canonical
            if !e.selectedMetrics.contains(metric) { e.selectedMetrics = MetricType.allCases.filter { e.selectedMetrics.contains($0) || $0 == metric } }
        }
        current = w
        return .done
    }

    /// Remove a metric from an exercise this workout — unselect it and clear its values.
    @discardableResult
    func removeMetric(exerciseNamed name: String, metric: MetricType) -> EditOutcome {
        guard var w = current else { return .notFound("There's no workout yet.") }
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
        current = w
        return .done
    }

    // MARK: - Read

    /// A compact, model-and-inspector-friendly rendering of the current workout.
    /// A cheap **index** of the current workout for the always-sent context — ID, title, status,
    /// counts, date — WITHOUT the exercise/set detail. Detail is fetched on demand via
    /// get_current_workout, so a 30-exercise workout doesn't inflate every chat request.
    var compactSummary: String? {
        guard let w = current else { return nil }
        let status = currentLog == nil ? "not started" : (currentLog?.isComplete == true ? "completed" : "in progress")
        let date: String = currentIsForToday ? "today"
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
