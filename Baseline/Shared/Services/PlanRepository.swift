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
    func scheduledWorkout(_ id: UUID) -> ScheduledWorkout?
    func session(forScheduled id: UUID) -> WorkoutSession?
    func completedLog(forScheduled id: UUID) -> CompletedWorkoutLog?
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
    func completeSession(forScheduled id: UUID, acknowledgingOpenWork: Bool, now: Date) -> SessionCompletion
    func discardSession(forScheduled id: UUID)

    // Slice 2 — typed, versioned mutations (append-only history). Only `delete` is confirmation-gated.
    func versions(limit: Int) -> [PlanVersion]
    func move(_ id: UUID, toDate: Date, timeOfDay: TimeOfDay?, actor: PlanActor, reason: String?) -> MutationResult
    func swap(_ a: UUID, _ b: UUID, actor: PlanActor, reason: String?) -> MutationResult
    func reorder(day: Date, orderedIDs: [UUID], actor: PlanActor, reason: String?) -> MutationResult
    func addWorkout(_ sw: ScheduledWorkout, actor: PlanActor, reason: String?) -> MutationResult
    func duplicate(_ id: UUID, toDate: Date?, actor: PlanActor, reason: String?) -> MutationResult
    func replaceContent(_ id: UUID, with workout: Workout, actor: PlanActor, reason: String?) -> MutationResult
    func editContent(_ id: UUID, actor: PlanActor, reason: String?, _ transform: (inout Workout) -> Void) -> MutationResult
    func setSkipped(_ id: UUID, _ skipped: Bool, actor: PlanActor, reason: String?) -> MutationResult
    func delete(_ id: UUID, actor: PlanActor, reason: String?, proposalID: UUID?) -> MutationResult
    func undo(actor: PlanActor) -> MutationResult
    func restore(versionID: UUID, actor: PlanActor) -> MutationResult

    // Templates — immutable reusable sources. Editing a template makes a new template revision; it never
    // touches already-scheduled workouts (they keep their own revision + template-revision attribution).
    func templates() -> [WorkoutTemplate]
    func template(named name: String) -> WorkoutTemplate?
    @discardableResult func saveAsTemplate(name: String, from workout: Workout, tags: [WorkoutTag]) -> WorkoutTemplate
    @discardableResult func updateTemplate(_ id: UUID, from workout: Workout) -> WorkoutTemplate?
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
    private let calendar = Calendar.planWeek

    init(context: ModelContext) { self.context = context }

    // MARK: Reads

    func programs() -> [Program] {
        (fetchAll() as [SDProgram]).map(map)
    }

    func week(containing date: Date, filter: ProgramFilter) -> TrainingWeek {
        let start = calendar.weekStart(for: date)
        let end = calendar.date(byAdding: .day, value: 7, to: start)!
        let scheduled = scheduled(in: start ..< end, filter: filter)
        let days = (0..<7).map { offset -> TrainingDay in
            let d = calendar.date(byAdding: .day, value: offset, to: start)!
            let sessions = scheduled.filter { calendar.isDate($0.date, inSameDayAs: d) }
                .sorted { ($0.timeOfDay?.rawValue ?? "") < ($1.timeOfDay?.rawValue ?? "") }
            return TrainingDay(date: d, sessions: sessions)
        }
        return TrainingWeek(startDate: start, days: days)
    }

    func day(_ date: Date, filter: ProgramFilter) -> TrainingDay {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return TrainingDay(date: start, sessions: scheduled(in: start ..< end, filter: filter))
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
            return map(live)   // idempotent — a session is already live
        }
        let sd = SDWorkoutSession(scheduledWorkoutID: id, startedAt: now,
                                  statusRaw: SessionStatus.active.rawValue, logJSON: PlanCoding.data(sw.workout.startLog()))
        context.insert(sd); save()
        return map(sd)
    }

    @discardableResult func resumeSession(forScheduled id: UUID) -> WorkoutSession? {
        guard let sd = latestSession(id) else { return nil }
        sd.statusRaw = SessionStatus.active.rawValue; save()
        return map(sd)
    }

    func updateSessionLog(forScheduled id: UUID, _ transform: (inout WorkoutLog) -> Void) {
        guard let sd = latestSession(id), var log = PlanCoding.value(WorkoutLog.self, sd.logJSON) else { return }
        transform(&log)
        sd.logJSON = PlanCoding.data(log); save()
    }

    func completeSession(forScheduled id: UUID, acknowledgingOpenWork: Bool, now: Date = Date()) -> SessionCompletion {
        guard let sd = latestSession(id), let session = map(sd), let sw = scheduledWorkout(id) else { return .noActiveSession }
        let open = Self.openWork(plan: sw.workout, log: session.log)
        if open.sets > 0 && !acknowledgingOpenWork { return .unloggedWork(sets: open.sets, exercises: open.exercises) }

        let completed = CompletedWorkoutLog(scheduledWorkoutID: id, finishedAt: now, log: session.log)
        context.insert(SDCompletedLog(id: completed.id, scheduledWorkoutID: id, finishedAt: now, logJSON: PlanCoding.data(session.log)))
        indexCompletedExercises(completed, plan: sw)
        sd.statusRaw = SessionStatus.completed.rawValue
        save()
        return .completed(completed)
    }

    func discardSession(forScheduled id: UUID) {
        guard let sd = latestSession(id) else { return }
        sd.statusRaw = SessionStatus.discarded.rawValue; save()
    }

    // MARK: - Mutations & versioning (Slice 2) — append-only history, typed confirmation

    func versions(limit: Int) -> [PlanVersion] { Array(versionSDs().suffix(limit).compactMap(mapVersion)) }

    func move(_ id: UUID, toDate: Date, timeOfDay: TimeOfDay?, actor: PlanActor, reason: String?) -> MutationResult {
        guard let sd = firstSD(SDScheduledWorkout.self, where: #Predicate { $0.id == id }) else { return .rejected(.notFound) }
        let diff = ScheduleDiff(changes: [.init(kind: .move, summary: "Move \(title(id)) → \(fmtDate(toDate))", scheduledID: id)])
        return apply(.move, actor, reason, diff) { sd.date = toDate; sd.timeOfDayRaw = timeOfDay?.rawValue }
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
        return apply(.delete, actor, reason, diff) { context.delete(sd) }
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

    private func ensureGenesis() {
        if versionSDs().isEmpty { _ = appendVersion(kind: .restore, actor: .user, reason: "genesis", diff: ScheduleDiff()) }
    }

    private func appendVersion(kind: PlanOpKind, actor: PlanActor, reason: String?, diff: ScheduleDiff) -> PlanVersion {
        let last = versionSDs().last?.timestamp ?? .distantPast
        let ts = max(Date(), last.addingTimeInterval(0.001))   // strictly increasing → head is unambiguous
        let op = PlanOperation(id: UUID(), kind: kind, actor: actor, reason: reason, timestamp: ts, diff: diff)
        let snap = snapshot()
        let sd = SDPlanVersion(id: UUID(), timestamp: ts, actorRaw: actor.rawValue,
                               operationJSON: PlanCoding.data(op), snapshotJSON: PlanCoding.data(snap))
        context.insert(sd); save()
        return PlanVersion(id: sd.id, timestamp: ts, actor: actor, operation: op, snapshot: snap)
    }

    private func versionSDs() -> [SDPlanVersion] { (fetchAll() as [SDPlanVersion]).sorted { $0.timestamp < $1.timestamp } }
    private func currentHeadID() -> UUID? { versionSDs().last?.id }
    private func mapVersion(_ sd: SDPlanVersion) -> PlanVersion? {
        guard let op = PlanCoding.value(PlanOperation.self, sd.operationJSON),
              let snap = PlanCoding.value(ScheduleSnapshot.self, sd.snapshotJSON) else { return nil }
        return PlanVersion(id: sd.id, timestamp: sd.timestamp, actor: PlanActor(rawValue: sd.actorRaw) ?? .user, operation: op, snapshot: snap)
    }

    private func snapshot() -> ScheduleSnapshot { ScheduleSnapshot(scheduled: (fetchAll() as [SDScheduledWorkout]).map(intent)) }

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
    private func applySnapshot(_ snap: ScheduleSnapshot) {
        let existing = fetchAll() as [SDScheduledWorkout]
        let wanted = Dictionary(uniqueKeysWithValues: snap.scheduled.map { ($0.id, $0) })
        for sd in existing where wanted[sd.id] == nil { context.delete(sd) }
        for it in snap.scheduled {
            if let sd = existing.first(where: { $0.id == it.id }) { write(it, to: sd) }
            else { let sd = SDScheduledWorkout(); write(it, to: sd); context.insert(sd) }
        }
        save()
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
    private func indexCompletedExercises(_ completed: CompletedWorkoutLog, plan sw: ScheduledWorkout) {
        for perf in completed.log.exercises {
            let instanceID = perf.plannedExerciseID ?? perf.id
            let def = perf.plannedExerciseID.flatMap { sw.workout.exercise($0)?.definitionId }
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
                              status: SessionStatus(rawValue: sd.statusRaw) ?? .active, log: log)
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
