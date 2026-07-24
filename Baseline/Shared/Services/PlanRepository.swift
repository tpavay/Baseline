import Foundation
import SwiftData

/// The **domain-typed gateway** to the Plan store (`docs/implementation/plan-tab.md` §6). Slice 1 covers
/// reads, seeding, and the workout lifecycle; structural mutations + versioning arrive in Slice 2. The
/// manual UI and (later) the agent both go through this — no second write path. Engines never see it.

/// Typed completion result — never a bare Boolean. Open work must be acknowledged before finalizing.
/// (Slice 2 folds this into the `PendingPlanProposal` pattern used for structural mutations.)
enum SessionCompletion: Equatable, Sendable {
    case completed(CompletedWorkoutLog)
    case unloggedWork(sets: Int, exercises: Int)
    case noActiveSession
}

@MainActor
protocol PlanRepository {
    func programs() -> [Program]
    func week(containing date: Date, filter: ProgramFilter) -> TrainingWeek
    func day(_ date: Date, filter: ProgramFilter) -> TrainingDay
    func days(from startDate: Date, through endDate: Date, filter: ProgramFilter) -> [TrainingDay]
    /// Explicit rest-day markers (startOfDay keys) within a half-open range. Markers are global —
    /// a rest day is a property of the athlete's calendar, not of any one program or filter.
    func restDays(in range: Range<Date>) -> Set<Date>
    /// Mark or un-mark a calendar day as an explicit rest day. Idempotent; not versioned — the
    /// marker schedules nothing, so toggling it back is its own undo. Scheduling training onto a
    /// marked day clears the marker: the workout implicitly reverses the rest decision.
    func setRestDay(_ date: Date, _ isRest: Bool)
    func scheduledWorkout(_ id: UUID) -> ScheduledWorkout?
    func session(forScheduled id: UUID) -> WorkoutSession?
    func completedLog(forScheduled id: UUID) -> CompletedWorkoutLog?
    /// The subset of `ids` whose scheduled workout has a completed log — one fetch for a whole range,
    /// so callers resolving completed status across many sessions never query per session.
    func completedScheduledWorkoutIDs(among ids: [UUID]) -> Set<UUID>
    /// The most recent completed actuals for an exercise identity, before a date — the Hevy "previous"
    /// column, per-exercise history, PRs. Reads the normalized index; never decodes a full log.
    func mostRecentPerformance(exerciseDefinitionID: String, before: Date) -> ExercisePerformance?
    func history(exerciseDefinitionID: String, limit: Int) -> [ExercisePerformance]

    @discardableResult func addProgram(_ p: Program) -> Program
    @discardableResult func addScheduled(_ sw: ScheduledWorkout) -> ScheduledWorkout
    /// Edit a scheduled workout's content — creates a NEW immutable revision and repoints; the prior
    /// revision is untouched, so version restore (Slice 2) can bring it back.
    func updateWorkout(scheduledID: UUID, _ transform: (inout Workout) -> Void)

    @discardableResult func startSession(forScheduled id: UUID, now: Date) -> WorkoutSession?
    @discardableResult func resumeSession(forScheduled id: UUID) -> WorkoutSession?
    func updateSessionLog(forScheduled id: UUID, _ transform: (inout WorkoutLog) -> Void)
    /// Store the session's own copy of the planned workout (a mid-workout structural/metric edit). This
    /// is session-scoped only — it never creates a plan revision. Promotion to the plan happens at
    /// completion via the ordinary `updateWorkout` revision path when the athlete opts in.
    func setSessionWorkout(forScheduled id: UUID, _ workout: Workout)
    func completeSession(forScheduled id: UUID, acknowledgingOpenWork: Bool, now: Date) -> SessionCompletion
    func discardSession(forScheduled id: UUID)
    /// Whether this session's promotion decision is still unanswered — the shared answer every bound
    /// editing surface reads on demand.
    func sessionDecisionPending(forScheduled id: UUID) -> Bool
    /// The athlete answered (accepted, declined, discarded) or finished a session that never diverged.
    func resolveSessionDecision(forScheduled id: UUID)
    /// Safety net for a decision the athlete never got to answer — the app was terminated between
    /// completion and the prompt. Resolving it as *declined* is the only safe direction, because they
    /// never said yes; this writes nothing to the plan.
    func resolveAbandonedSessionDecision(forScheduled id: UUID)

    // Slice 2 — typed, versioned mutations (append-only history). Only `delete` is confirmation-gated.
    func versions(limit: Int) -> [PlanVersion]
    func move(_ id: UUID, toDate: Date, timeOfDay: TimeOfDay?, actor: PlanActor, reason: String?) -> MutationResult
    func swap(_ a: UUID, _ b: UUID, actor: PlanActor, reason: String?) -> MutationResult
    func reorder(day: Date, orderedIDs: [UUID], actor: PlanActor, reason: String?) -> MutationResult
    func addWorkout(_ sw: ScheduledWorkout, actor: PlanActor, reason: String?) -> MutationResult
    func duplicate(_ id: UUID, toDate: Date?, actor: PlanActor, reason: String?) -> MutationResult
    func replaceContent(_ id: UUID, with workout: Workout, actor: PlanActor, reason: String?) -> MutationResult
    func editContent(_ id: UUID, actor: PlanActor, reason: String?, _ transform: (inout Workout) -> Void) -> MutationResult
    /// `log` is an optional session-scoped companion write (a purged logged actual) versioned and
    /// undone together with the workout content; plan-scoped mutations never carry one.
    func applyWorkoutMutation(_ request: WorkoutMutationRequest, workout: Workout, log: WorkoutLog?) -> WorkoutMutationResult
    func undoWorkoutMutation(mutationID: UUID, expectedRevisionToken: UUID, actor: PlanActor) -> WorkoutMutationResult
    func updateSessionLog(
        forScheduled id: UUID,
        request: WorkoutMutationRequest,
        log: WorkoutLog
    ) -> WorkoutMutationResult
    func undoSessionMutation(mutationID: UUID, expectedRevisionToken: UUID, actor: PlanActor) -> WorkoutMutationResult
    func sessionMutationVersions(sessionID: UUID, limit: Int) -> [SessionMutationVersion]
    func setSkipped(_ id: UUID, _ skipped: Bool, actor: PlanActor, reason: String?) -> MutationResult
    func delete(_ id: UUID, actor: PlanActor, reason: String?, proposalID: UUID?) -> MutationResult
    /// Fully remove a *provisional* workout — a blank workout scheduled only to start logging right
    /// now, then discarded before it earned a place on the plan. Unlike `discardSession` (which keeps
    /// the scheduled workout so a real session can restart from the saved revision) this leaves the day
    /// truly undecided: the scheduled workout, its sessions, and any completed log are all removed, and
    /// no rest marker is left behind. Silent and immediate — no delete proposal, because the athlete
    /// already confirmed the discard — but versioned so plan history and undo stay consistent with the
    /// matching `addWorkout`.
    func purgeProvisionalWorkout(_ id: UUID, actor: PlanActor, reason: String?) -> MutationResult
    func undo(actor: PlanActor) -> MutationResult
    func restore(versionID: UUID, actor: PlanActor) -> MutationResult

    // Templates — immutable reusable sources. Editing a template makes a new template revision; it never
    // touches already-scheduled workouts (they keep their own revision + template-revision attribution).
    func templates() -> [WorkoutTemplate]
    func template(named name: String) -> WorkoutTemplate?
    func workout(forTemplate id: UUID) -> Workout?
    @discardableResult func saveAsTemplate(name: String, from workout: Workout, tags: [WorkoutTag]) -> WorkoutTemplate
    @discardableResult func updateTemplate(_ id: UUID, from workout: Workout) -> WorkoutTemplate?
    @discardableResult func saveImportedTemplate(name: String, from workout: Workout, tags: [WorkoutTag]) throws -> WorkoutTemplate
    @discardableResult func updateImportedTemplate(_ id: UUID, from workout: Workout) throws -> WorkoutTemplate?
    /// Instantiate a template onto a date as an INDEPENDENT scheduled workout (its own fresh revision),
    /// recording templateID + templateRevisionID for attribution. Versioned + undoable.
    @discardableResult func instantiateTemplate(_ id: UUID, on date: Date, programID: UUID, actor: PlanActor) -> ScheduledWorkout?
}

// Monday-based calendar used for week projections.
extension Calendar {
    static var planWeek: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }
    func weekStart(for date: Date) -> Date {
        let comps = dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return self.date(from: comps) ?? startOfDay(for: date)
    }
}

/// Codable ⇄ Data helpers for the blob payloads.
enum PlanCoding {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
    static func data(_ v: some Encodable) -> Data { (try? encoder.encode(v)) ?? Data() }
    static func value<T: Decodable>(_ type: T.Type, _ d: Data?) -> T? {
        guard let d, !d.isEmpty else { return nil }
        return try? decoder.decode(type, from: d)
    }
}

@MainActor
final class SwiftDataPlanRepository: PlanRepository {
    private let context: ModelContext
    /// ModelContext does not keep its container alive. The repository owns both so an injected
    /// context can never outlive the persistent store that backs it.
    private let container: ModelContainer
    private let calendar = Calendar.planWeek

    init(context: ModelContext) {
        self.context = context
        container = context.container
    }

    // MARK: Reads

    func programs() -> [Program] {
        (fetchAll() as [SDProgram]).map(map)
    }

    func week(containing date: Date, filter: ProgramFilter) -> TrainingWeek {
        let start = calendar.weekStart(for: date)
        let end = calendar.date(byAdding: .day, value: 7, to: start)!
        let scheduled = scheduled(in: start ..< end, filter: filter)
        let restMarks = restDays(in: start ..< end)
        let days = (0..<7).map { offset -> TrainingDay in
            let d = calendar.date(byAdding: .day, value: offset, to: start)!
            let sessions = scheduled.filter { calendar.isDate($0.date, inSameDayAs: d) }
                .sorted { ($0.timeOfDay?.rawValue ?? "") < ($1.timeOfDay?.rawValue ?? "") }
            return TrainingDay(date: d, sessions: sessions, isRestDay: restMarks.contains(d))
        }
        return TrainingWeek(startDate: start, days: days)
    }

    func day(_ date: Date, filter: ProgramFilter) -> TrainingDay {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return TrainingDay(date: start,
                           sessions: scheduled(in: start ..< end, filter: filter),
                           isRestDay: !restDays(in: start ..< end).isEmpty)
    }

    func days(from startDate: Date, through endDate: Date, filter: ProgramFilter) -> [TrainingDay] {
        let start = calendar.startOfDay(for: min(startDate, endDate))
        let last = calendar.startOfDay(for: max(startDate, endDate))
        guard let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        let sessions = scheduled(in: start ..< end, filter: filter)
        let sessionsByDate = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.date) }
        let restMarks = restDays(in: start ..< end)
        let count = calendar.dateComponents([.day], from: start, to: last).day ?? 0

        return (0...count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return TrainingDay(date: date,
                               sessions: sessionsByDate[date, default: []],
                               isRestDay: restMarks.contains(date))
        }
    }

    func restDays(in range: Range<Date>) -> Set<Date> {
        let start = range.lowerBound
        let end = range.upperBound
        let marks = fetch(SDRestDay.self, where: #Predicate { $0.date >= start && $0.date < end })
        return Set(marks.map { calendar.startOfDay(for: $0.date) })
    }

    func setRestDay(_ date: Date, _ isRest: Bool) {
        if isRest {
            let day = calendar.startOfDay(for: date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return }
            guard fetch(SDRestDay.self, where: #Predicate { $0.date >= day && $0.date < next }).isEmpty else { return }
            context.insert(SDRestDay(date: day))
        } else {
            clearRestMarker(on: date)
        }
        save()
    }

    /// Scheduling training onto a day implicitly reverses a rest decision, so every write that lands
    /// a workout on a date drops the marker there — removing that workout later must return the day
    /// to empty, never resurrect a stale "Rest day". Callers save as part of their own transaction.
    private func clearRestMarker(on date: Date) {
        let day = calendar.startOfDay(for: date)
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return }
        fetch(SDRestDay.self, where: #Predicate { $0.date >= day && $0.date < next }).forEach(context.delete)
    }

    func scheduledWorkout(_ id: UUID) -> ScheduledWorkout? {
        firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == id }).flatMap(hydrate)
    }

    func session(forScheduled id: UUID) -> WorkoutSession? {
        latestSession(id).flatMap(map)
    }

    func completedLog(forScheduled id: UUID) -> CompletedWorkoutLog? {
        let logs = fetch(SDCompletedLog.self, where: #Predicate { $0.scheduledWorkoutID == id })
            .sorted { $0.finishedAt > $1.finishedAt }
        return logs.first.flatMap(map)
    }

    func completedScheduledWorkoutIDs(among ids: [UUID]) -> Set<UUID> {
        guard ids.isEmpty == false else { return [] }
        let candidates = ids
        let logs = fetch(SDCompletedLog.self, where: #Predicate { candidates.contains($0.scheduledWorkoutID) })
        return Set(logs.map(\.scheduledWorkoutID))
    }

    func mostRecentPerformance(exerciseDefinitionID: String, before: Date) -> ExercisePerformance? {
        let defID: String? = exerciseDefinitionID
        return fetch(SDCompletedExercise.self, where: #Predicate { $0.exerciseDefinitionID == defID && $0.date < before })
            .sorted { $0.date > $1.date }.first.flatMap(mapPerformance)
    }

    func history(exerciseDefinitionID: String, limit: Int) -> [ExercisePerformance] {
        let defID: String? = exerciseDefinitionID
        return Array(fetch(SDCompletedExercise.self, where: #Predicate { $0.exerciseDefinitionID == defID })
            .sorted { $0.date > $1.date }.prefix(limit).compactMap(mapPerformance))
    }

    private func mapPerformance(_ sd: SDCompletedExercise) -> ExercisePerformance {
        ExercisePerformance(id: sd.id, completedLogID: sd.completedLogID, date: sd.date,
                            programID: sd.programID, workoutTitle: sd.workoutTitle,
                            exerciseInstanceID: sd.exerciseInstanceID, exerciseDefinitionID: sd.exerciseDefinitionID,
                            exerciseName: sd.exerciseName, sets: PlanCoding.value([MetricValues].self, sd.metricsJSON) ?? [])
    }

    // MARK: Seeding

    @discardableResult func addProgram(_ p: Program) -> Program {
        context.insert(SDProgram(id: p.id, name: p.name, isActive: p.isActive, isArchived: p.isArchived,
                                 createdAt: p.createdAt, goalsJSON: p.goals.isEmpty ? nil : PlanCoding.data(p.goals)))
        save()
        return p
    }

    @discardableResult func addScheduled(_ sw: ScheduledWorkout) -> ScheduledWorkout {
        insertScheduled(sw); save(); return sw   // unversioned seeding (migrator/tests); addWorkout is the versioned path
    }

    func updateWorkout(scheduledID: UUID, _ transform: (inout Workout) -> Void) {
        guard let sd = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == scheduledID }),
              var workout = scheduledWorkout(scheduledID)?.workout else { return }
        transform(&workout)
        let revision = SDWorkoutRevision(workoutID: sd.workoutID, createdAt: Date(), workoutJSON: PlanCoding.data(workout))
        context.insert(revision)
        sd.workoutRevisionID = revision.id
        save()
    }

    // MARK: Lifecycle

    @discardableResult func startSession(forScheduled id: UUID, now: Date = Date()) -> WorkoutSession? {
        guard let sw = scheduledWorkout(id) else { return nil }
        if let live = latestSession(id), live.statusRaw == SessionStatus.active.rawValue || live.statusRaw == SessionStatus.paused.rawValue {
            // Idempotent — a session is already live. Still mark the decision pending: a live session has
            // by definition not been answered, and it may predate the field or have been reached only
            // through resume, in which case nobody has ever written it.
            markDecisionPending(live)
            return map(live)
        }
        let sd = SDWorkoutSession(scheduledWorkoutID: id, startedAt: now,
                                  statusRaw: SessionStatus.active.rawValue, logJSON: PlanCoding.data(sw.workout.startLog()),
                                  performedLogRevisionID: UUID(),
                                  reconciliationPending: true)
        context.insert(sd); save()
        return map(sd)
    }

    @discardableResult func resumeSession(forScheduled id: UUID) -> WorkoutSession? {
        guard let sd = latestSession(id) else { return nil }
        sd.statusRaw = SessionStatus.active.rawValue
        sd.reconciliationPending = true      // live again ⇒ its decision is open again
        save()
        return map(sd)
    }

    /// Every path that yields a *live* session marks the decision open, however that session was
    /// reached. Nil stays "not pending" for completed rows written before the field existed, so an old
    /// finished session cannot suddenly claim an unanswered decision.
    private func markDecisionPending(_ sd: SDWorkoutSession) {
        guard sd.reconciliationPending != true else { return }
        sd.reconciliationPending = true
        save()
    }

    func updateSessionLog(forScheduled id: UUID, _ transform: (inout WorkoutLog) -> Void) {
        guard let sd = latestSession(id), var log = PlanCoding.value(WorkoutLog.self, sd.logJSON) else { return }
        transform(&log)
        sd.logJSON = PlanCoding.data(log)
        sd.performedLogRevisionID = UUID()
        save()
    }

    func setSessionWorkout(forScheduled id: UUID, _ workout: Workout) {
        guard let sd = latestSession(id) else { return }
        sd.sessionWorkoutJSON = PlanCoding.data(workout)
        sd.sessionWorkoutRevisionID = UUID()
        save()
    }

    func completeSession(forScheduled id: UUID, acknowledgingOpenWork: Bool, now: Date = Date()) -> SessionCompletion {
        guard let sd = latestSession(id), let session = map(sd), let sw = scheduledWorkout(id) else { return .noActiveSession }
        // The session may have been edited mid-workout; the athlete performed against that copy, so open
        // work and history indexing resolve against it — not the untouched saved plan.
        let effectivePlan = session.workout ?? sw.workout
        let open = Self.openWork(plan: effectivePlan, log: session.log)
        if open.sets > 0 && !acknowledgingOpenWork { return .unloggedWork(sets: open.sets, exercises: open.exercises) }

        var completedLog = session.log
        completedLog.isComplete = true
        let completed = CompletedWorkoutLog(scheduledWorkoutID: id, finishedAt: now, log: completedLog)
        context.insert(SDCompletedLog(
            id: completed.id,
            scheduledWorkoutID: id,
            finishedAt: now,
            logJSON: PlanCoding.data(completedLog)
        ))
        indexCompletedExercises(completed, plan: sw, resolving: effectivePlan)
        sd.logJSON = PlanCoding.data(completedLog)
        sd.statusRaw = SessionStatus.completed.rawValue
        save()
        return .completed(completed)
    }

    func discardSession(forScheduled id: UUID) {
        guard let sd = latestSession(id) else { return }
        sd.statusRaw = SessionStatus.discarded.rawValue
        sd.reconciliationPending = false
        save()
    }

    func sessionDecisionPending(forScheduled id: UUID) -> Bool {
        latestSession(id)?.reconciliationPending ?? false
    }

    func resolveSessionDecision(forScheduled id: UUID) {
        guard let sd = latestSession(id), sd.reconciliationPending == true else { return }
        sd.reconciliationPending = false
        save()
    }

    func resolveAbandonedSessionDecision(forScheduled id: UUID) {
        guard let sd = latestSession(id), sd.statusRaw == SessionStatus.completed.rawValue else { return }
        resolveSessionDecision(forScheduled: id)
    }

    // MARK: - Mutations & versioning (Slice 2) — append-only history, typed confirmation

    func versions(limit: Int) -> [PlanVersion] { Array(versionSDs().suffix(limit).compactMap(mapVersion)) }

    func move(_ id: UUID, toDate: Date, timeOfDay: TimeOfDay?, actor: PlanActor, reason: String?) -> MutationResult {
        guard let sd = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == id }) else { return .rejected(.notFound) }
        let diff = ScheduleDiff(changes: [.init(kind: .move, summary: "Move \(title(id)) → \(fmtDate(toDate))", scheduledID: id)])
        return apply(.move, actor, reason, diff) {
            sd.date = toDate; sd.timeOfDayRaw = timeOfDay?.rawValue
            clearRestMarker(on: toDate)
        }
    }

    func swap(_ a: UUID, _ b: UUID, actor: PlanActor, reason: String?) -> MutationResult {
        guard let A = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == a }),
              let B = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == b }) else { return .rejected(.notFound) }
        let diff = ScheduleDiff(changes: [
            .init(kind: .move, summary: "Swap \(title(a)) ↔ \(title(b))", scheduledID: a),
            .init(kind: .move, summary: "", scheduledID: b)])
        return apply(.swap, actor, reason, diff) {
            let (ad, at) = (A.date, A.timeOfDayRaw)
            A.date = B.date; A.timeOfDayRaw = B.timeOfDayRaw
            B.date = ad; B.timeOfDayRaw = at
            clearRestMarker(on: A.date); clearRestMarker(on: B.date)
        }
    }

    func reorder(day: Date, orderedIDs: [UUID], actor: PlanActor, reason: String?) -> MutationResult {
        let slots: [TimeOfDay] = [.morning, .midday, .evening]
        let diff = ScheduleDiff(changes: [.init(kind: .edit, summary: "Reorder \(fmtDate(day))", scheduledID: nil)])
        return apply(.reorder, actor, reason, diff) {
            for (i, id) in orderedIDs.enumerated() {
                guard let sd = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == id }) else { continue }
                sd.timeOfDayRaw = (i < slots.count ? slots[i] : .evening).rawValue
            }
        }
    }

    func addWorkout(_ sw: ScheduledWorkout, actor: PlanActor, reason: String?) -> MutationResult {
        let diff = ScheduleDiff(changes: [.init(kind: .add, summary: "Add \(sw.workout.title)", scheduledID: sw.id)])
        return apply(.add, actor, reason, diff) { insertScheduled(sw) }
    }

    func duplicate(_ id: UUID, toDate: Date?, actor: PlanActor, reason: String?) -> MutationResult {
        guard let src = scheduledWorkout(id) else { return .rejected(.notFound) }
        var copy = src; copy.id = UUID(); copy.date = toDate ?? src.date; copy.skipped = false   // shares the revision
        let diff = ScheduleDiff(changes: [.init(kind: .add, summary: "Duplicate \(src.workout.title)", scheduledID: copy.id)])
        return apply(.duplicate, actor, reason, diff) { insertScheduled(copy) }
    }

    func replaceContent(_ id: UUID, with workout: Workout, actor: PlanActor, reason: String?) -> MutationResult {
        editContent(id, actor: actor, reason: reason) { $0 = workout }
    }

    func editContent(_ id: UUID, actor: PlanActor, reason: String?, _ transform: (inout Workout) -> Void) -> MutationResult {
        guard let sd = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == id }),
              var w = scheduledWorkout(id)?.workout else { return .rejected(.notFound) }
        transform(&w)
        let diff = ScheduleDiff(changes: [.init(kind: .edit, summary: "Edit \(w.title)", scheduledID: id)])
        return apply(.editContent, actor, reason, diff) {
            let rev = SDWorkoutRevision(workoutID: sd.workoutID, createdAt: Date(), workoutJSON: PlanCoding.data(w))
            context.insert(rev); sd.workoutRevisionID = rev.id
        }
    }

    /// The one repository transaction for conversational workout edits. The store has already resolved
    /// and validated domain IDs against one local value; this boundary repeats the identity and revision
    /// checks against persisted authoritative state immediately before its single save.
    func applyWorkoutMutation(_ request: WorkoutMutationRequest, workout: Workout, log: WorkoutLog?) -> WorkoutMutationResult {
        guard validAgentMutation(request),
              request.dryRun || !mutationIDExists(request.mutationID) else {
            return .rejected(.invalidTarget)
        }
        switch request.target.scope {
        case .plan:
            // Plan revisions never carry a session's performed log; the store only supplies one for
            // session-scoped mutations.
            guard log == nil else { return .rejected(.invalidTarget) }
            return applyPlanWorkoutMutation(request, workout: workout)
        case .sessionWorkout:
            return applySessionWorkoutMutation(request, workout: workout, log: log)
        case .performedLog, .transient:
            return .rejected(.invalidTarget)
        }
    }

    private func applyPlanWorkoutMutation(
        _ request: WorkoutMutationRequest,
        workout: Workout
    ) -> WorkoutMutationResult {
        guard let scheduledID = request.target.scheduledWorkoutID,
              request.target.sessionID == nil,
              let sd = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == scheduledID }),
              let authoritative = scheduledWorkout(scheduledID) else {
            return .rejected(.notFound)
        }
        guard sd.workoutID == request.target.workoutID, workout.id == authoritative.workout.id else {
            return .rejected(.invalidTarget)
        }
        guard request.target.revisionToken == request.expectedRevisionToken,
              sd.workoutRevisionID == request.expectedRevisionToken else {
            return .rejected(.staleRevision)
        }

        if request.dryRun {
            return .preview(receipt(
                request,
                before: sd.workoutRevisionID,
                after: sd.workoutRevisionID,
                undoAvailable: false
            ))
        }

        ensureGenesis(saveAfter: false)
        let before = sd.workoutRevisionID
        let revision = SDWorkoutRevision(
            workoutID: sd.workoutID,
            createdAt: Date(),
            workoutJSON: PlanCoding.data(workout)
        )
        context.insert(revision)
        sd.workoutRevisionID = revision.id
        let receipt = receipt(request, before: before, after: revision.id, undoAvailable: true)
        let scheduleDiff = scheduleDiff(for: request.diff, scheduledID: scheduledID)
        _ = appendVersion(
            kind: .editContent,
            actor: request.actor,
            reason: request.reason,
            diff: scheduleDiff,
            operationID: request.mutationID,
            workoutMutationReceipt: receipt,
            saveAfter: false
        )
        guard commitWorkoutMutation() else { return .rejected(.persistenceFailure) }
        return .applied(receipt)
    }

    private func applySessionWorkoutMutation(
        _ request: WorkoutMutationRequest,
        workout: Workout,
        log: WorkoutLog?
    ) -> WorkoutMutationResult {
        guard let scheduledID = request.target.scheduledWorkoutID,
              let sessionID = request.target.sessionID,
              let sd = latestSession(scheduledID), sd.id == sessionID,
              let scheduled = scheduledWorkout(scheduledID) else {
            return .rejected(.notFound)
        }
        let before = PlanCoding.value(Workout.self, sd.sessionWorkoutJSON) ?? scheduled.workout
        guard request.target.workoutID == scheduled.workoutID, workout.id == before.id else {
            return .rejected(.invalidTarget)
        }
        let currentToken = sd.sessionWorkoutRevisionID ?? scheduled.workoutRevisionID
        guard request.target.revisionToken == request.expectedRevisionToken,
              currentToken == request.expectedRevisionToken else {
            return .rejected(.staleRevision)
        }
        if request.dryRun {
            return .preview(receipt(request, before: currentToken, after: currentToken, undoAvailable: false))
        }

        let after = UUID()
        let mutationReceipt = receipt(request, before: currentToken, after: after, undoAvailable: true)
        var purge = WorkoutLogPurge()
        if let log {
            if let beforeLog = PlanCoding.value(WorkoutLog.self, sd.logJSON) {
                purge = WorkoutLog.purgedContent(before: beforeLog, after: log)
            }
            sd.logJSON = PlanCoding.data(log)
            sd.performedLogRevisionID = UUID()
        }
        sd.sessionWorkoutJSON = PlanCoding.data(workout)
        sd.sessionWorkoutRevisionID = after
        insertSessionMutation(
            request,
            sessionID: sessionID,
            kind: .sessionWorkout,
            beforeSnapshot: purge.isEmpty
                ? .sessionWorkout(before)
                : .sessionWorkoutAndPurgedLogContent(before, purge),
            afterRevisionToken: after,
            receipt: mutationReceipt
        )
        guard commitWorkoutMutation() else { return .rejected(.persistenceFailure) }
        return .applied(mutationReceipt)
    }

    /// The receipt-backed performed-log write boundary.
    ///
    /// Direct UI edits use the transform overload above.
    /// Agent edits use this overload so the log write, revision token, and append-only history row
    /// commit in one SwiftData transaction.
    func updateSessionLog(
        forScheduled id: UUID,
        request: WorkoutMutationRequest,
        log: WorkoutLog
    ) -> WorkoutMutationResult {
        guard validAgentMutation(request),
              request.dryRun || !mutationIDExists(request.mutationID),
              request.target.scope == .performedLog,
              let scheduledID = request.target.scheduledWorkoutID,
              scheduledID == id,
              let sessionID = request.target.sessionID,
              let sd = latestSession(scheduledID), sd.id == sessionID,
              sd.statusRaw == SessionStatus.active.rawValue || sd.statusRaw == SessionStatus.paused.rawValue,
              let before = PlanCoding.value(WorkoutLog.self, sd.logJSON),
              let scheduled = scheduledWorkout(scheduledID),
              request.target.workoutID == scheduled.workoutID,
              log.id == before.id,
              log.plannedWorkoutID == before.plannedWorkoutID else {
            return .rejected(.notFound)
        }
        let currentToken = sd.performedLogRevisionID ?? sd.id
        guard request.target.revisionToken == request.expectedRevisionToken,
              currentToken == request.expectedRevisionToken else {
            return .rejected(.staleRevision)
        }

        if request.dryRun {
            return .preview(receipt(request, before: currentToken, after: currentToken, undoAvailable: false))
        }

        let after = UUID()
        let mutationReceipt = receipt(request, before: currentToken, after: after, undoAvailable: true)
        sd.logJSON = PlanCoding.data(log)
        sd.performedLogRevisionID = after
        insertSessionMutation(
            request,
            sessionID: sessionID,
            kind: .performedLog,
            beforeSnapshot: .performedLog(before),
            afterRevisionToken: after,
            receipt: mutationReceipt
        )
        guard commitWorkoutMutation() else { return .rejected(.persistenceFailure) }
        return .applied(mutationReceipt)
    }

    func undoSessionMutation(
        mutationID: UUID,
        expectedRevisionToken: UUID,
        actor: PlanActor
    ) -> WorkoutMutationResult {
        guard actor == .agent,
              let row = firstSD(SDSessionMutationVersion.self, where: #Predicate { $0.mutationID == mutationID }),
              let applied = mapSessionMutation(row) else {
            return .rejected(.notFound)
        }
        switch applied.kind {
        case .sessionWorkout:
            return undoSessionWorkoutMutation(
                mutationID: mutationID,
                expectedRevisionToken: expectedRevisionToken,
                actor: actor
            )
        case .performedLog:
            return undoPerformedLogMutation(
                applied,
                expectedRevisionToken: expectedRevisionToken,
                actor: actor
            )
        }
    }

    private func undoPerformedLogMutation(
        _ applied: SessionMutationVersion,
        expectedRevisionToken: UUID,
        actor: PlanActor
    ) -> WorkoutMutationResult {
        guard applied.receipt.undoAvailable else { return .rejected(.undoUnavailable) }
        guard applied.receipt.scope == .performedLog,
              applied.receipt.afterRevisionToken == expectedRevisionToken,
              let scheduledID = applied.receipt.scheduledWorkoutID,
              let sessionID = applied.receipt.sessionID,
              let session = latestSession(scheduledID),
              session.id == sessionID else {
            return .rejected(.staleRevision)
        }
        guard session.statusRaw != SessionStatus.discarded.rawValue else {
            return .rejected(.sessionDiscarded)
        }
        guard session.statusRaw == SessionStatus.active.rawValue || session.statusRaw == SessionStatus.paused.rawValue,
              (session.performedLogRevisionID ?? session.id) == expectedRevisionToken,
              let current = PlanCoding.value(WorkoutLog.self, session.logJSON) else {
            return .rejected(.staleRevision)
        }
        guard case .performedLog(let restored) = applied.beforeSnapshot,
              restored.id == current.id,
              restored.plannedWorkoutID == current.plannedWorkoutID else {
            return .rejected(.staleRevision)
        }

        let undoDiff = WorkoutMutationDiff(changes: [
            .init(
                kind: .edit,
                summary: "Undo: \(applied.diff.changes.map(\.summary).joined(separator: "; "))",
                entityID: current.id
            ),
        ])
        let undoRequest = WorkoutMutationRequest(
            mutationID: UUID(),
            target: WorkoutMutationTarget(
                scope: .performedLog,
                scheduledWorkoutID: scheduledID,
                sessionID: sessionID,
                workoutID: applied.receipt.workoutID,
                revisionToken: expectedRevisionToken
            ),
            expectedRevisionToken: expectedRevisionToken,
            actor: actor,
            reason: "Undo session mutation \(applied.mutationID.uuidString)",
            diff: undoDiff,
            dryRun: false
        )
        let undoReceipt = receipt(
            undoRequest,
            before: expectedRevisionToken,
            after: applied.receipt.beforeRevisionToken,
            undoAvailable: false
        )
        session.logJSON = PlanCoding.data(restored)
        session.performedLogRevisionID = undoReceipt.afterRevisionToken
        insertSessionMutation(
            undoRequest,
            sessionID: sessionID,
            kind: .performedLog,
            beforeSnapshot: .performedLog(current),
            afterRevisionToken: undoReceipt.afterRevisionToken,
            receipt: undoReceipt
        )
        guard commitWorkoutMutation() else { return .rejected(.persistenceFailure) }
        return .applied(undoReceipt)
    }

    func undoWorkoutMutation(
        mutationID: UUID,
        expectedRevisionToken: UUID,
        actor: PlanActor
    ) -> WorkoutMutationResult {
        guard actor == .agent else { return .rejected(.invalidTarget) }
        let versions = versionSDs()
        guard let appliedIndex = versions.firstIndex(where: { version in
            PlanCoding.value(WorkoutMutationReceipt.self, version.workoutMutationReceiptJSON)?.mutationID
                == mutationID
        }) else {
            return undoSessionWorkoutMutation(
                mutationID: mutationID,
                expectedRevisionToken: expectedRevisionToken,
                actor: actor
            )
        }
        guard let appliedReceipt = PlanCoding.value(
            WorkoutMutationReceipt.self,
            versions[appliedIndex].workoutMutationReceiptJSON
        ) else {
            return .rejected(.invalidTarget)
        }
        guard appliedReceipt.undoAvailable else { return .rejected(.undoUnavailable) }
        guard appliedIndex > 0,
              appliedIndex == versions.count - 1,
              appliedReceipt.scope == .plan,
              appliedReceipt.afterRevisionToken == expectedRevisionToken,
              let scheduledID = appliedReceipt.scheduledWorkoutID,
              let scheduled = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == scheduledID }),
              scheduled.workoutRevisionID == expectedRevisionToken,
              let headSnapshot = PlanCoding.value(ScheduleSnapshot.self, versions[appliedIndex].snapshotJSON),
              scheduleMatchesCurrent(headSnapshot),
              let target = PlanCoding.value(ScheduleSnapshot.self, versions[appliedIndex - 1].snapshotJSON),
              let restoredIntent = target.scheduled.first(where: { $0.id == scheduledID }) else {
            return .rejected(.staleRevision)
        }
        if conflictsWithActiveSession(target) { return .rejected(.staleRevision) }

        let undoDiff = WorkoutMutationDiff(changes: [
            .init(kind: .edit, summary: "Undo: \(appliedReceipt.diff.changes.map(\.summary).joined(separator: "; "))", entityID: scheduledID),
        ])
        let undoRequest = WorkoutMutationRequest(
            mutationID: UUID(),
            target: WorkoutMutationTarget(
                scope: .plan,
                scheduledWorkoutID: scheduledID,
                sessionID: nil,
                workoutID: appliedReceipt.workoutID,
                revisionToken: expectedRevisionToken
            ),
            expectedRevisionToken: expectedRevisionToken,
            actor: actor,
            reason: "Undo workout mutation \(mutationID.uuidString)",
            diff: undoDiff,
            dryRun: false
        )
        let undoReceipt = receipt(
            undoRequest,
            before: expectedRevisionToken,
            after: restoredIntent.workoutRevisionID,
            undoAvailable: false
        )
        applySnapshot(target, saveAfter: false)
        _ = appendVersion(
            kind: .undo,
            actor: actor,
            reason: undoRequest.reason,
            diff: scheduleDiff(for: undoDiff, scheduledID: scheduledID),
            operationID: undoRequest.mutationID,
            workoutMutationReceipt: undoReceipt,
            snapshot: target,
            saveAfter: false
        )
        guard commitWorkoutMutation() else { return .rejected(.persistenceFailure) }
        return .applied(undoReceipt)
    }

    private func undoSessionWorkoutMutation(
        mutationID: UUID,
        expectedRevisionToken: UUID,
        actor: PlanActor
    ) -> WorkoutMutationResult {
        guard let row = firstSD(SDSessionMutationVersion.self, where: #Predicate { $0.mutationID == mutationID }),
              let applied = mapSessionMutation(row) else {
            return .rejected(.notFound)
        }
        guard applied.receipt.undoAvailable else { return .rejected(.undoUnavailable) }
        guard applied.kind == .sessionWorkout,
              applied.receipt.scope == .sessionWorkout,
              applied.receipt.afterRevisionToken == expectedRevisionToken,
              let scheduledID = applied.receipt.scheduledWorkoutID,
              let sessionID = applied.receipt.sessionID,
              let session = latestSession(scheduledID),
              session.id == sessionID else {
            return .rejected(.staleRevision)
        }
        guard session.statusRaw != SessionStatus.discarded.rawValue else {
            return .rejected(.sessionDiscarded)
        }
        guard let scheduled = scheduledWorkout(scheduledID) else {
            return .rejected(.staleRevision)
        }
        let currentToken = session.sessionWorkoutRevisionID ?? scheduled.workoutRevisionID
        guard currentToken == expectedRevisionToken else {
            return .rejected(.staleRevision)
        }
        let restored: Workout
        let purge: WorkoutLogPurge
        switch applied.beforeSnapshot {
        case .sessionWorkout(let workout):
            restored = workout
            purge = WorkoutLogPurge()
        case .sessionWorkoutAndPurgedSetLogs(let workout, let rows):
            restored = workout
            purge = WorkoutLogPurge(setLogs: rows)
        case .sessionWorkoutAndPurgedLogContent(let workout, let content):
            restored = workout
            purge = content
        case .performedLog:
            return .rejected(.staleRevision)
        }
        let current = PlanCoding.value(Workout.self, session.sessionWorkoutJSON) ?? scheduled.workout
        let undoDiff = WorkoutMutationDiff(changes: [
            .init(
                kind: .edit,
                summary: "Undo: \(applied.diff.changes.map(\.summary).joined(separator: "; "))",
                entityID: scheduledID
            ),
        ])
        let undoRequest = WorkoutMutationRequest(
            mutationID: UUID(),
            target: WorkoutMutationTarget(
                scope: .sessionWorkout,
                scheduledWorkoutID: scheduledID,
                sessionID: sessionID,
                workoutID: applied.receipt.workoutID,
                revisionToken: expectedRevisionToken
            ),
            expectedRevisionToken: expectedRevisionToken,
            actor: actor,
            reason: "Undo session workout mutation \(mutationID.uuidString)",
            diff: undoDiff,
            dryRun: false
        )
        let undoReceipt = receipt(
            undoRequest,
            before: expectedRevisionToken,
            after: applied.receipt.beforeRevisionToken,
            undoAvailable: false
        )
        session.sessionWorkoutJSON = PlanCoding.data(restored)
        session.sessionWorkoutRevisionID = applied.receipt.beforeRevisionToken
        if !purge.isEmpty, var log = PlanCoding.value(WorkoutLog.self, session.logJSON) {
            log.restore(purge)
            session.logJSON = PlanCoding.data(log)
            session.performedLogRevisionID = UUID()
        }
        insertSessionMutation(
            undoRequest,
            sessionID: sessionID,
            kind: .sessionWorkout,
            beforeSnapshot: .sessionWorkout(current),
            afterRevisionToken: undoReceipt.afterRevisionToken,
            receipt: undoReceipt
        )
        guard commitWorkoutMutation() else { return .rejected(.persistenceFailure) }
        return .applied(undoReceipt)
    }

    func sessionMutationVersions(sessionID: UUID, limit: Int) -> [SessionMutationVersion] {
        let rows = fetch(SDSessionMutationVersion.self, where: #Predicate { $0.sessionID == sessionID })
            .sorted { $0.timestamp < $1.timestamp }
        return Array(rows.suffix(max(0, limit)).compactMap(mapSessionMutation))
    }

    func setSkipped(_ id: UUID, _ skipped: Bool, actor: PlanActor, reason: String?) -> MutationResult {
        guard let sd = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == id }) else { return .rejected(.notFound) }
        let diff = ScheduleDiff(changes: [.init(kind: .edit, summary: "\(skipped ? "Skip" : "Unskip") \(title(id))", scheduledID: id)])
        return apply(skipped ? .skip : .unskip, actor, reason, diff) { sd.skipped = skipped }
    }

    func delete(_ id: UUID, actor: PlanActor, reason: String?, proposalID: UUID?) -> MutationResult {
        guard let sd = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == id }) else { return .rejected(.notFound) }
        guard let proposalID else { return makeDeleteProposal(sd) }
        guard let prop = firstSD(SDPendingProposal.self, where: #Predicate { $0.id == proposalID }) else { return .rejected(.proposalExpired) }
        if prop.expectedHeadVersionID != currentHeadID() {   // schedule moved under the proposal → regenerate
            context.delete(prop); save(); return makeDeleteProposal(sd)
        }
        context.delete(prop)
        let diff = ScheduleDiff(changes: [.init(kind: .remove, summary: "Delete \(title(id))", scheduledID: id)])
        // Erase the whole footprint, not just the schedule row: a completed session's performed rows have
        // no cascade (see `deletePerformedFootprint`), so leaving them behind keeps a deleted session
        // contributing to history/PRs and the Today "This Week"/"Movement Balance" cards indefinitely.
        return apply(.delete, actor, reason, diff) {
            deletePerformedFootprint(scheduledWorkoutID: id)
            context.delete(sd)
        }
    }

    func purgeProvisionalWorkout(_ id: UUID, actor: PlanActor, reason: String?) -> MutationResult {
        guard let sd = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == id }) else { return .rejected(.notFound) }
        let diff = ScheduleDiff(changes: [.init(kind: .remove, summary: "Discard \(title(id))", scheduledID: id)])
        // Remove the whole footprint of the placeholder — sessions and any completed log/exercise index
        // included — so no orphaned row survives to resurface the day as occupied or pollute history.
        return apply(.delete, actor, reason, diff) {
            deletePerformedFootprint(scheduledWorkoutID: id)
            context.delete(sd)
        }
    }

    /// Erases the full performed footprint of a scheduled workout — its session(s), completed log(s), and
    /// the normalized completed-exercise rows those logs indexed — matching only on this workout's id.
    /// The Plan entities carry no SwiftData cascade relationships (they link by loose `UUID` foreign keys,
    /// see `PlanEntities.swift`), so deleting only the schedule row strands these rows as orphans that keep
    /// feeding history/PRs (`history`/`mostRecentPerformance`) and the Today weekly cards. `delete` and
    /// `purgeProvisionalWorkout` both route through here so their deleted schedule rows stop contributing
    /// everywhere. Note `applySnapshot` (undo/restore) deletes `SDScheduledWorkout` rows directly and does
    /// NOT cascade the performed footprint — a known, separately-tracked gap, not a case this helper covers.
    private func deletePerformedFootprint(scheduledWorkoutID id: UUID) {
        for log in fetch(SDCompletedLog.self, where: #Predicate { $0.scheduledWorkoutID == id }) {
            let logID = log.id
            fetch(SDCompletedExercise.self, where: #Predicate { $0.completedLogID == logID }).forEach(context.delete)
            context.delete(log)
        }
        fetch(SDWorkoutSession.self, where: #Predicate { $0.scheduledWorkoutID == id }).forEach(context.delete)
    }

    func undo(actor: PlanActor) -> MutationResult {
        let vs = versionSDs()
        guard vs.count >= 2, let target = PlanCoding.value(ScheduleSnapshot.self, vs[vs.count - 2].snapshotJSON) else { return .rejected(.nothingToUndo) }
        if conflictsWithActiveSession(target) { return .rejected(.activeSessionConflict) }
        applySnapshot(target)
        let diff = ScheduleDiff(changes: [.init(kind: .edit, summary: "Undo last change", scheduledID: nil)])
        return .applied(diff: diff, version: appendVersion(kind: .undo, actor: actor, reason: nil, diff: diff))
    }

    func restore(versionID: UUID, actor: PlanActor) -> MutationResult {
        guard let sd = firstSD(SDPlanVersion.self, where: #Predicate { $0.id == versionID }),
              let snap = PlanCoding.value(ScheduleSnapshot.self, sd.snapshotJSON) else { return .rejected(.notFound) }
        if conflictsWithActiveSession(snap) { return .rejected(.activeSessionConflict) }
        applySnapshot(snap)
        let diff = ScheduleDiff(changes: [.init(kind: .edit, summary: "Restore version", scheduledID: nil)])
        return .applied(diff: diff, version: appendVersion(kind: .restore, actor: actor, reason: "restore \(versionID)", diff: diff))
    }

    // MARK: - Templates (immutable reusable sources)

    func templates() -> [WorkoutTemplate] {
        (fetchAll() as [SDWorkoutTemplate]).map(mapTemplate).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func template(named name: String) -> WorkoutTemplate? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return templates().first { $0.name.lowercased() == key }
    }

    func workout(forTemplate id: UUID) -> Workout? {
        guard let template = firstSD(SDWorkoutTemplate.self, where: #Predicate { $0.id == id }) else { return nil }
        let revisionID = template.currentRevisionID
        return firstSD(SDWorkoutRevision.self, where: #Predicate { $0.id == revisionID })
            .flatMap { PlanCoding.value(Workout.self, $0.workoutJSON) }
    }

    @discardableResult func saveAsTemplate(name: String, from workout: Workout, tags: [WorkoutTag]) -> WorkoutTemplate {
        // The template's content is its own immutable revision (independent of any scheduled workout).
        let rev = SDWorkoutRevision(workoutID: UUID(), createdAt: Date(), workoutJSON: PlanCoding.data(workout))
        context.insert(rev)
        let sd = SDWorkoutTemplate(name: name.trimmingCharacters(in: .whitespaces), currentRevisionID: rev.id,
                                   tagsJSON: tags.isEmpty ? nil : PlanCoding.data(tags))
        context.insert(sd); save()
        return mapTemplate(sd)
    }

    @discardableResult func updateTemplate(_ id: UUID, from workout: Workout) -> WorkoutTemplate? {
        guard let sd = firstSD(SDWorkoutTemplate.self, where: #Predicate { $0.id == id }) else { return nil }
        let rev = SDWorkoutRevision(workoutID: UUID(), createdAt: Date(), workoutJSON: PlanCoding.data(workout))
        context.insert(rev)               // new immutable template revision; the old one is kept (attribution)
        sd.currentRevisionID = rev.id      // last-write-wins on the pointer (v1: no conflict detection)
        save()
        return mapTemplate(sd)
    }

    @discardableResult func saveImportedTemplate(name: String, from workout: Workout, tags: [WorkoutTag]) throws -> WorkoutTemplate {
        let rev = SDWorkoutRevision(workoutID: UUID(), createdAt: Date(), workoutJSON: try PlanCoding.encoder.encode(workout))
        context.insert(rev)
        let sd = SDWorkoutTemplate(name: name.trimmingCharacters(in: .whitespacesAndNewlines), currentRevisionID: rev.id,
                                   tagsJSON: tags.isEmpty ? nil : try PlanCoding.encoder.encode(tags))
        context.insert(sd)
        try context.save()
        return mapTemplate(sd)
    }

    @discardableResult func updateImportedTemplate(_ id: UUID, from workout: Workout) throws -> WorkoutTemplate? {
        guard let sd = firstSD(SDWorkoutTemplate.self, where: #Predicate { $0.id == id }) else { return nil }
        let rev = SDWorkoutRevision(workoutID: UUID(), createdAt: Date(), workoutJSON: try PlanCoding.encoder.encode(workout))
        context.insert(rev)
        sd.name = workout.title.trimmingCharacters(in: .whitespacesAndNewlines)
        sd.currentRevisionID = rev.id
        try context.save()
        return mapTemplate(sd)
    }

    @discardableResult func instantiateTemplate(_ id: UUID, on date: Date, programID: UUID, actor: PlanActor) -> ScheduledWorkout? {
        guard let sd = firstSD(SDWorkoutTemplate.self, where: #Predicate { $0.id == id }) else { return nil }
        let rid = sd.currentRevisionID
        guard let rev = firstSD(SDWorkoutRevision.self, where: #Predicate { $0.id == rid }),
              let content = PlanCoding.value(Workout.self, rev.workoutJSON) else { return nil }
        // Independent copy: fresh workout identity + fresh revision, with template attribution.
        var workout = content; workout.id = UUID()
        workout.scheduledDate = Calendar.planWeek.startOfDay(for: date)
        let sw = ScheduledWorkout(programID: programID, date: Calendar.planWeek.startOfDay(for: date),
                                  origin: .userCreated, workoutID: workout.id, workoutRevisionID: UUID(),
                                  workout: workout, templateID: sd.id, templateRevisionID: sd.currentRevisionID,
                                  tags: PlanCoding.value([WorkoutTag].self, sd.tagsJSON) ?? [])
        guard case .applied = addWorkout(sw, actor: actor, reason: "from template \(sd.name)") else { return nil }
        return sw
    }

    private func mapTemplate(_ sd: SDWorkoutTemplate) -> WorkoutTemplate {
        WorkoutTemplate(id: sd.id, name: sd.name, currentRevisionID: sd.currentRevisionID,
                        tags: PlanCoding.value([WorkoutTag].self, sd.tagsJSON) ?? [])
    }

    // MARK: Versioning internals

    private func validAgentMutation(_ request: WorkoutMutationRequest) -> Bool {
        request.actor == .agent
            && !request.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !request.diff.changes.isEmpty
            && request.diff.changes.allSatisfy {
                !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    private func mutationIDExists(_ mutationID: UUID) -> Bool {
        versionSDs().contains { version in
            PlanCoding.value(
                WorkoutMutationReceipt.self,
                version.workoutMutationReceiptJSON
            )?.mutationID == mutationID
        } || firstSD(SDSessionMutationVersion.self, where: #Predicate { $0.mutationID == mutationID }) != nil
    }

    private func receipt(
        _ request: WorkoutMutationRequest,
        before: UUID,
        after: UUID,
        undoAvailable: Bool
    ) -> WorkoutMutationReceipt {
        WorkoutMutationReceipt(
            mutationID: request.mutationID,
            scope: request.target.scope,
            scheduledWorkoutID: request.target.scheduledWorkoutID,
            sessionID: request.target.sessionID,
            workoutID: request.target.workoutID,
            beforeRevisionToken: before,
            afterRevisionToken: after,
            diff: request.diff,
            actor: request.actor,
            undoAvailable: undoAvailable
        )
    }

    private func scheduleDiff(for diff: WorkoutMutationDiff, scheduledID: UUID) -> ScheduleDiff {
        ScheduleDiff(changes: diff.changes.map { change in
            .init(kind: .edit, summary: change.summary, scheduledID: scheduledID)
        })
    }

    private func insertSessionMutation(
        _ request: WorkoutMutationRequest,
        sessionID: UUID,
        kind: SessionMutationKind,
        beforeSnapshot: SessionMutationSnapshot,
        afterRevisionToken: UUID,
        receipt: WorkoutMutationReceipt
    ) {
        context.insert(SDSessionMutationVersion(
            sessionID: sessionID,
            mutationID: request.mutationID,
            kindRaw: kind.rawValue,
            beforeSnapshotJSON: PlanCoding.data(beforeSnapshot),
            afterRevisionToken: afterRevisionToken,
            actorRaw: request.actor.rawValue,
            timestamp: Date(),
            diffJSON: PlanCoding.data(request.diff),
            workoutMutationReceiptJSON: PlanCoding.data(receipt)
        ))
    }

    private func mapSessionMutation(_ row: SDSessionMutationVersion) -> SessionMutationVersion? {
        guard let kind = SessionMutationKind(rawValue: row.kindRaw),
              let before = PlanCoding.value(SessionMutationSnapshot.self, row.beforeSnapshotJSON),
              let diff = PlanCoding.value(WorkoutMutationDiff.self, row.diffJSON),
              let receipt = PlanCoding.value(
                  WorkoutMutationReceipt.self,
                  row.workoutMutationReceiptJSON
              ) else {
            return nil
        }
        return SessionMutationVersion(
            id: row.id,
            sessionID: row.sessionID,
            mutationID: row.mutationID,
            kind: kind,
            beforeSnapshot: before,
            afterRevisionToken: row.afterRevisionToken,
            actor: PlanActor(rawValue: row.actorRaw) ?? .agent,
            timestamp: row.timestamp,
            diff: diff,
            receipt: receipt
        )
    }

    /// Mutation receipts are returned only after SwiftData confirms the entire envelope commit.
    /// Rolling back on failure prevents callers from offering Undo for a revision that never landed.
    private func commitWorkoutMutation() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    private func makeDeleteProposal(_ sd: SDScheduledWorkout) -> MutationResult {
        let name = title(sd.id)
        let diff = ScheduleDiff(changes: [.init(kind: .remove, summary: "Delete \(name)", scheduledID: sd.id)])
        let warnings = [PlanWarning(kind: .destructive, message: "This permanently removes \(name) from the plan.")]
        let prop = SDPendingProposal(operationJSON: PlanCoding.data(ProposedPlanOperation.delete(sd.id)),
                                     expectedHeadVersionID: currentHeadID(), diffJSON: PlanCoding.data(diff),
                                     warningsJSON: PlanCoding.data(warnings), createdAt: Date(), expiresAt: Date().addingTimeInterval(600))
        context.insert(prop); save()
        return .confirmationRequired(warnings: warnings, proposedDiff: diff, proposalID: prop.id)
    }

    /// Apply a direct (non-gated) mutation: seed genesis if needed, mutate, then append a post-op version.
    private func apply(_ kind: PlanOpKind, _ actor: PlanActor, _ reason: String?, _ diff: ScheduleDiff, _ body: () -> Void) -> MutationResult {
        ensureGenesis()
        body(); save()
        return .applied(diff: diff, version: appendVersion(kind: kind, actor: actor, reason: reason, diff: diff))
    }

    private func ensureGenesis(saveAfter: Bool = true) {
        if versionSDs().isEmpty {
            _ = appendVersion(
                kind: .restore,
                actor: .user,
                reason: "genesis",
                diff: ScheduleDiff(),
                saveAfter: saveAfter
            )
        }
    }

    private func appendVersion(
        kind: PlanOpKind,
        actor: PlanActor,
        reason: String?,
        diff: ScheduleDiff,
        operationID: UUID = UUID(),
        workoutMutationReceipt: WorkoutMutationReceipt? = nil,
        snapshot explicitSnapshot: ScheduleSnapshot? = nil,
        saveAfter: Bool = true
    ) -> PlanVersion {
        let last = versionSDs().last?.timestamp ?? .distantPast
        let ts = max(Date(), last.addingTimeInterval(0.001))   // strictly increasing → head is unambiguous
        let op = PlanOperation(id: operationID, kind: kind, actor: actor, reason: reason, timestamp: ts, diff: diff)
        let snap = explicitSnapshot ?? snapshot()
        let sd = SDPlanVersion(id: UUID(), timestamp: ts, actorRaw: actor.rawValue,
                               operationJSON: PlanCoding.data(op), snapshotJSON: PlanCoding.data(snap),
                               workoutMutationReceiptJSON: workoutMutationReceipt.map { PlanCoding.data($0) })
        context.insert(sd)
        if saveAfter { save() }
        return PlanVersion(
            id: sd.id,
            timestamp: ts,
            actor: actor,
            operation: op,
            snapshot: snap,
            workoutMutationReceipt: workoutMutationReceipt
        )
    }

    private func versionSDs() -> [SDPlanVersion] { (fetchAll() as [SDPlanVersion]).sorted { $0.timestamp < $1.timestamp } }
    private func currentHeadID() -> UUID? { versionSDs().last?.id }
    private func mapVersion(_ sd: SDPlanVersion) -> PlanVersion? {
        guard let op = PlanCoding.value(PlanOperation.self, sd.operationJSON),
              let snap = PlanCoding.value(ScheduleSnapshot.self, sd.snapshotJSON) else { return nil }
        return PlanVersion(
            id: sd.id,
            timestamp: sd.timestamp,
            actor: PlanActor(rawValue: sd.actorRaw) ?? .user,
            operation: op,
            snapshot: snap,
            workoutMutationReceipt: PlanCoding.value(WorkoutMutationReceipt.self, sd.workoutMutationReceiptJSON)
        )
    }

    private func snapshot() -> ScheduleSnapshot { ScheduleSnapshot(scheduled: (fetchAll() as [SDScheduledWorkout]).map(intent)) }

    /// True when the live schedule still matches a recorded snapshot. Targeted undo restores the whole
    /// schedule, so any drift the version log never saw (e.g. a manual editor save, which moves a
    /// revision pointer without appending a version) makes the undo stale — restoring the prior
    /// snapshot would silently revert that later work.
    private func scheduleMatchesCurrent(_ snap: ScheduleSnapshot) -> Bool {
        Dictionary(uniqueKeysWithValues: snapshot().scheduled.map { ($0.id, $0) })
            == Dictionary(uniqueKeysWithValues: snap.scheduled.map { ($0.id, $0) })
    }

    private func intent(_ sd: SDScheduledWorkout) -> ScheduledIntent {
        ScheduledIntent(id: sd.id, programID: sd.programID, sectionID: sd.sectionID, date: sd.date,
                        timeOfDay: sd.timeOfDayRaw.flatMap(TimeOfDay.init(rawValue:)),
                        origin: WorkoutOrigin(rawValue: sd.originRaw) ?? .userCreated,
                        workoutID: sd.workoutID, workoutRevisionID: sd.workoutRevisionID,
                        templateID: sd.templateID, templateRevisionID: sd.templateRevisionID,
                        tags: PlanCoding.value([WorkoutTag].self, sd.tagsJSON) ?? [],
                        supportsGoalIDs: PlanCoding.value([UUID].self, sd.supportsGoalIDsJSON) ?? [], skipped: sd.skipped)
    }

    /// Reconcile the schedule rows to exactly match a snapshot (upsert wanted, delete the rest). Touches
    /// only plan intent — never sessions/logs.
    private func applySnapshot(_ snap: ScheduleSnapshot, saveAfter: Bool = true) {
        let existing = fetchAll() as [SDScheduledWorkout]
        let wanted = Dictionary(uniqueKeysWithValues: snap.scheduled.map { ($0.id, $0) })
        for sd in existing where wanted[sd.id] == nil { context.delete(sd) }
        for it in snap.scheduled {
            clearRestMarker(on: it.date)
            if let sd = existing.first(where: { $0.id == it.id }) { write(it, to: sd) }
            else { let sd = SDScheduledWorkout(); write(it, to: sd); context.insert(sd) }
        }
        if saveAfter { save() }
    }

    private func write(_ it: ScheduledIntent, to sd: SDScheduledWorkout) {
        sd.id = it.id; sd.programID = it.programID; sd.sectionID = it.sectionID; sd.date = it.date
        sd.timeOfDayRaw = it.timeOfDay?.rawValue; sd.originRaw = it.origin.rawValue
        sd.workoutID = it.workoutID; sd.workoutRevisionID = it.workoutRevisionID
        sd.templateID = it.templateID; sd.templateRevisionID = it.templateRevisionID
        sd.tagsJSON = it.tags.isEmpty ? nil : PlanCoding.data(it.tags)
        sd.supportsGoalIDsJSON = it.supportsGoalIDs.isEmpty ? nil : PlanCoding.data(it.supportsGoalIDs)
        sd.skipped = it.skipped
    }

    /// A restore/undo conflicts if a workout with a live session would be removed or changed by it.
    private func conflictsWithActiveSession(_ target: ScheduleSnapshot) -> Bool {
        let live = Set((fetchAll() as [SDWorkoutSession])
            .filter { $0.statusRaw == SessionStatus.active.rawValue || $0.statusRaw == SessionStatus.paused.rawValue }
            .map(\.scheduledWorkoutID))
        guard !live.isEmpty else { return false }
        let targetByID = Dictionary(uniqueKeysWithValues: target.scheduled.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: snapshot().scheduled.map { ($0.id, $0) })
        for id in live where targetByID[id] != currentByID[id] { return true }
        return false
    }

    private func insertScheduled(_ sw: ScheduledWorkout) {
        clearRestMarker(on: sw.date)
        let rid = sw.workoutRevisionID
        if firstSD(SDWorkoutRevision.self, where: #Predicate { $0.id == rid }) == nil {
            context.insert(SDWorkoutRevision(id: rid, workoutID: sw.workoutID, createdAt: sw.date, workoutJSON: PlanCoding.data(sw.workout)))
        }
        context.insert(SDScheduledWorkout(
            id: sw.id, programID: sw.programID, sectionID: sw.sectionID, originRaw: sw.origin.rawValue,
            date: sw.date, timeOfDayRaw: sw.timeOfDay?.rawValue, skipped: sw.skipped, workoutID: sw.workoutID,
            workoutRevisionID: sw.workoutRevisionID, templateID: sw.templateID, templateRevisionID: sw.templateRevisionID,
            tagsJSON: sw.tags.isEmpty ? nil : PlanCoding.data(sw.tags),
            supportsGoalIDsJSON: sw.supportsGoalIDs.isEmpty ? nil : PlanCoding.data(sw.supportsGoalIDs),
            recurrenceJSON: sw.recurrence.map(PlanCoding.data)))
    }

    private func title(_ id: UUID) -> String { scheduledWorkout(id)?.workout.title ?? "this workout" }
    private func fmtDate(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

    /// Planned sets whose actual isn't checked complete, and how many exercises they span.
    static func openWork(plan: Workout, log: WorkoutLog) -> (sets: Int, exercises: Int) {
        var sets = 0, exercises = 0
        for ex in plan.allExercises {
            let perf = log.performed(forPlanned: ex.id)
            let open = ex.prescription.sets.filter { s in perf?.setLogs.first { $0.plannedSetID == s.id }?.completed != true }.count
            if open > 0 { exercises += 1; sets += open }
        }
        return (sets, exercises)
    }

    /// Write one normalized `SDCompletedExercise` per performed exercise so history/PRs/previous never
    /// decode a full log blob. `exerciseInstanceID` is the stable per-exercise identity.
    private func indexCompletedExercises(_ completed: CompletedWorkoutLog, plan sw: ScheduledWorkout, resolving effectivePlan: Workout) {
        for perf in completed.log.exercises {
            let instanceID = perf.plannedExerciseID ?? perf.id
            // Resolve identity against the effective session plan so an exercise added or replaced
            // mid-workout keeps its catalog identity in history even if the athlete declines to update
            // the saved plan at completion.
            let def = perf.plannedExerciseID.flatMap { effectivePlan.exercise($0)?.definitionId }
            context.insert(SDCompletedExercise(
                completedLogID: completed.id, date: completed.finishedAt, programID: sw.programID,
                workoutTitle: sw.workout.title, exerciseInstanceID: instanceID, exerciseDefinitionID: def,
                exerciseName: perf.exerciseName, metricsJSON: PlanCoding.data(perf.setLogs.map(\.values))))
        }
    }

    // MARK: - Mapping (SD → domain)

    private func map(_ sd: SDProgram) -> Program {
        Program(id: sd.id, name: sd.name, isActive: sd.isActive, isArchived: sd.isArchived,
                createdAt: sd.createdAt, goals: PlanCoding.value([ProgramGoal].self, sd.goalsJSON) ?? [])
    }

    private func hydrate(_ sd: SDScheduledWorkout) -> ScheduledWorkout? {
        let rid = sd.workoutRevisionID
        guard let rev = firstSD(SDWorkoutRevision.self, where: #Predicate { $0.id == rid }),
              let workout = PlanCoding.value(Workout.self, rev.workoutJSON) else { return nil }
        return ScheduledWorkout(
            id: sd.id, programID: sd.programID, date: sd.date,
            timeOfDay: sd.timeOfDayRaw.flatMap(TimeOfDay.init(rawValue:)),
            origin: WorkoutOrigin(rawValue: sd.originRaw) ?? .userCreated,
            workoutID: sd.workoutID, workoutRevisionID: sd.workoutRevisionID, workout: workout,
            sectionID: sd.sectionID, templateID: sd.templateID, templateRevisionID: sd.templateRevisionID,
            tags: PlanCoding.value([WorkoutTag].self, sd.tagsJSON) ?? [],
            supportsGoalIDs: PlanCoding.value([UUID].self, sd.supportsGoalIDsJSON) ?? [],
            recurrence: PlanCoding.value(RecurrenceRule.self, sd.recurrenceJSON), skipped: sd.skipped)
    }

    private func map(_ sd: SDWorkoutSession) -> WorkoutSession? {
        guard let log = PlanCoding.value(WorkoutLog.self, sd.logJSON) else { return nil }
        return WorkoutSession(id: sd.id, scheduledWorkoutID: sd.scheduledWorkoutID, startedAt: sd.startedAt,
                              status: SessionStatus(rawValue: sd.statusRaw) ?? .active, log: log,
                              workout: PlanCoding.value(Workout.self, sd.sessionWorkoutJSON),
                              sessionWorkoutRevisionID: sd.sessionWorkoutRevisionID,
                              performedLogRevisionID: sd.performedLogRevisionID,
                              reconciliationPending: sd.reconciliationPending ?? false)
    }

    private func map(_ sd: SDCompletedLog) -> CompletedWorkoutLog? {
        guard let log = PlanCoding.value(WorkoutLog.self, sd.logJSON) else { return nil }
        return CompletedWorkoutLog(id: sd.id, scheduledWorkoutID: sd.scheduledWorkoutID, finishedAt: sd.finishedAt, log: log)
    }

    // MARK: - Fetch helpers

    private func scheduled(in range: Range<Date>, filter: ProgramFilter) -> [ScheduledWorkout] {
        let lo = range.lowerBound, hi = range.upperBound
        let rows = fetch(SDScheduledWorkout.self, where: #Predicate { $0.date >= lo && $0.date < hi })
        let programs = fetchAll() as [SDProgram]
        let activeIDs = Set(programs.filter { $0.isActive && !$0.isArchived }.map(\.id))
        let archivedIDs = Set(programs.filter(\.isArchived).map(\.id))
        return rows.compactMap(hydrate).filter { sw in
            switch filter {
            case .allTraining: return activeIDs.contains(sw.programID)
            case .program(let id): return sw.programID == id
            case .collection(.archived): return archivedIDs.contains(sw.programID)
            case .collection(.completed): return completedLog(forScheduled: sw.id) != nil
            case .collection(.adHoc): return [.userCreated, .legacyMigrated, .baselineGenerated].contains(sw.origin)
            }
        }.sorted { $0.date < $1.date }
    }

    private func latestSession(_ scheduledID: UUID) -> SDWorkoutSession? {
        fetch(SDWorkoutSession.self, where: #Predicate { $0.scheduledWorkoutID == scheduledID })
            .sorted { $0.startedAt > $1.startedAt }.first
    }

    private func fetchAll<T: PersistentModel>() -> [T] { (try? context.fetch(FetchDescriptor<T>())) ?? [] }
    private func fetch<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>) -> [T] {
        (try? context.fetch(FetchDescriptor<T>(predicate: predicate))) ?? []
    }
    private func firstSD<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>) -> T? {
        var d = FetchDescriptor<T>(predicate: predicate); d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }
    private func save() { try? context.save() }
}
