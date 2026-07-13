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

    // MARK: Seeding

    @discardableResult func addProgram(_ p: Program) -> Program {
        context.insert(SDProgram(id: p.id, name: p.name, isActive: p.isActive, isArchived: p.isArchived,
                                 createdAt: p.createdAt, goalsJSON: p.goals.isEmpty ? nil : PlanCoding.data(p.goals)))
        save()
        return p
    }

    @discardableResult func addScheduled(_ sw: ScheduledWorkout) -> ScheduledWorkout {
        // Persist the current immutable revision if it isn't stored yet, then the schedule row.
        let rid = sw.workoutRevisionID
        if firstSD(SDWorkoutRevision.self, where: #Predicate { $0.id == rid }) == nil {
            context.insert(SDWorkoutRevision(id: sw.workoutRevisionID, workoutID: sw.workoutID,
                                             createdAt: sw.date, workoutJSON: PlanCoding.data(sw.workout)))
        }
        context.insert(SDScheduledWorkout(
            id: sw.id, programID: sw.programID, sectionID: sw.sectionID, originRaw: sw.origin.rawValue,
            date: sw.date, timeOfDayRaw: sw.timeOfDay?.rawValue, skipped: sw.skipped, workoutID: sw.workoutID,
            workoutRevisionID: sw.workoutRevisionID, templateID: sw.templateID,
            tagsJSON: sw.tags.isEmpty ? nil : PlanCoding.data(sw.tags),
            supportsGoalIDsJSON: sw.supportsGoalIDs.isEmpty ? nil : PlanCoding.data(sw.supportsGoalIDs),
            recurrenceJSON: sw.recurrence.map(PlanCoding.data)))
        save()
        return sw
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
                exerciseInstanceID: instanceID, exerciseDefinitionID: def, exerciseName: perf.exerciseName,
                metricsJSON: PlanCoding.data(perf.setLogs.map(\.values))))
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
            sectionID: sd.sectionID, templateID: sd.templateID,
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
        let activeProgramIDs = Set((fetchAll() as [SDProgram]).filter { $0.isActive && !$0.isArchived }.map(\.id))
        return rows.compactMap(hydrate).filter { sw in
            switch filter {
            case .allTraining: return activeProgramIDs.contains(sw.programID)
            case .program(let id): return sw.programID == id
            case .collection: return true   // collections wired in Slice 4
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
