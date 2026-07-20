import Foundation
import Observation
import SwiftData

/// SwiftUI-facing wrapper over `PlanRepository` — holds the focused week + filter and republishes on
/// change. Views read `week`/`programs`; lifecycle + seeding go through here so the repository stays the
/// single write path. `@MainActor` since it drives the UI and owns a main-context repository.
@Observable @MainActor
final class PlanStore {
    private let repo: PlanRepository
    var filter: ProgramFilter = .allTraining
    private(set) var focusedDate: Date
    private(set) var week: TrainingWeek

    init(repo: PlanRepository, today: Date = Date()) {
        self.repo = repo
        self.focusedDate = today
        self.week = repo.week(containing: today, filter: .allTraining)
    }

    convenience init(context: ModelContext, today: Date = Date()) {
        self.init(repo: SwiftDataPlanRepository(context: context), today: today)
    }

    // MARK: Navigation

    func reload() { week = repo.week(containing: focusedDate, filter: filter) }
    func setFilter(_ f: ProgramFilter) { filter = f; reload() }
    func showWeek(of date: Date) { focusedDate = date; reload() }
    func nextWeek() { shiftWeeks(1) }
    func prevWeek() { shiftWeeks(-1) }
    private func shiftWeeks(_ n: Int) {
        focusedDate = Calendar.planWeek.date(byAdding: .day, value: 7 * n, to: focusedDate) ?? focusedDate
        reload()
    }

    // MARK: Reads

    func programs() -> [Program] { repo.programs() }
    func scheduledWorkout(_ id: UUID) -> ScheduledWorkout? { repo.scheduledWorkout(id) }
    func session(for id: UUID) -> WorkoutSession? { repo.session(forScheduled: id) }
    func completed(for id: UUID) -> CompletedWorkoutLog? { repo.completedLog(forScheduled: id) }
    /// Previous completed actuals for an exercise identity — the Hevy "previous" column.
    func previousPerformance(exerciseDefinitionID: String, before: Date = Date()) -> ExercisePerformance? {
        repo.mostRecentPerformance(exerciseDefinitionID: exerciseDefinitionID, before: before)
    }
    /// Full completed history for an exercise identity, newest-first — the Exercise History screen.
    func history(exerciseDefinitionID: String, limit: Int = 100) -> [ExercisePerformance] {
        repo.history(exerciseDefinitionID: exerciseDefinitionID, limit: limit)
    }
    func programName(_ id: UUID) -> String? { programs().first { $0.id == id }?.name }
    /// Edit a scheduled workout's content (creates a revision). Used by the execution bridge on dismiss.
    func updateWorkout(_ id: UUID, _ transform: (inout Workout) -> Void) { repo.updateWorkout(scheduledID: id, transform); reload() }

    /// Derived status (never stored). Today's physiological modification is injected by the caller.
    func status(for sw: ScheduledWorkout, today: Date = Date(), todayModification: TodayModification? = nil) -> ScheduleStatus {
        ScheduleStatusResolver.status(for: sw, today: today, session: session(for: sw.id),
                                      completed: completed(for: sw.id), todayModification: todayModification)
    }

    // MARK: Lifecycle

    @discardableResult func start(_ id: UUID) -> WorkoutSession? { defer { reload() }; return repo.startSession(forScheduled: id, now: Date()) }
    @discardableResult func resume(_ id: UUID) -> WorkoutSession? { defer { reload() }; return repo.resumeSession(forScheduled: id) }
    @discardableResult func complete(_ id: UUID, acknowledgingOpenWork: Bool) -> SessionCompletion {
        defer { reload() }; return repo.completeSession(forScheduled: id, acknowledgingOpenWork: acknowledgingOpenWork, now: Date())
    }
    func discard(_ id: UUID) { repo.discardSession(forScheduled: id); reload() }
    func updateSessionLog(_ id: UUID, _ transform: (inout WorkoutLog) -> Void) { repo.updateSessionLog(forScheduled: id, transform); reload() }
    /// Store the session's own copy of the planned workout (a session-scoped mid-workout edit; no revision).
    func setSessionWorkout(_ id: UUID, _ workout: Workout) { repo.setSessionWorkout(forScheduled: id, workout) }

    // MARK: Mutations & versioning (Slice 2) — every schedule change is versioned

    func versions(limit: Int = 100) -> [PlanVersion] { repo.versions(limit: limit) }
    @discardableResult func move(_ id: UUID, toDate: Date, timeOfDay: TimeOfDay? = nil, actor: PlanActor = .user, reason: String? = nil) -> MutationResult { defer { reload() }; return repo.move(id, toDate: toDate, timeOfDay: timeOfDay, actor: actor, reason: reason) }
    @discardableResult func swap(_ a: UUID, _ b: UUID, actor: PlanActor = .user, reason: String? = nil) -> MutationResult { defer { reload() }; return repo.swap(a, b, actor: actor, reason: reason) }
    @discardableResult func reorder(day: Date, orderedIDs: [UUID], actor: PlanActor = .user, reason: String? = nil) -> MutationResult { defer { reload() }; return repo.reorder(day: day, orderedIDs: orderedIDs, actor: actor, reason: reason) }
    @discardableResult func addWorkout(_ sw: ScheduledWorkout, actor: PlanActor = .user, reason: String? = nil) -> MutationResult { defer { reload() }; return repo.addWorkout(sw, actor: actor, reason: reason) }
    @discardableResult func duplicate(_ id: UUID, toDate: Date? = nil, actor: PlanActor = .user, reason: String? = nil) -> MutationResult { defer { reload() }; return repo.duplicate(id, toDate: toDate, actor: actor, reason: reason) }
    @discardableResult func editContent(_ id: UUID, actor: PlanActor = .user, reason: String? = nil, _ transform: (inout Workout) -> Void) -> MutationResult { defer { reload() }; return repo.editContent(id, actor: actor, reason: reason, transform) }
    @discardableResult func setSkipped(_ id: UUID, _ skipped: Bool, actor: PlanActor = .user, reason: String? = nil) -> MutationResult { defer { reload() }; return repo.setSkipped(id, skipped, actor: actor, reason: reason) }
    @discardableResult func delete(_ id: UUID, proposalID: UUID? = nil, actor: PlanActor = .user, reason: String? = nil) -> MutationResult { defer { reload() }; return repo.delete(id, actor: actor, reason: reason, proposalID: proposalID) }
    @discardableResult func undo(actor: PlanActor = .user) -> MutationResult { defer { reload() }; return repo.undo(actor: actor) }
    @discardableResult func restore(versionID: UUID, actor: PlanActor = .user) -> MutationResult { defer { reload() }; return repo.restore(versionID: versionID, actor: actor) }

    // MARK: Templates (immutable reusable sources)

    func templates() -> [WorkoutTemplate] { repo.templates() }
    func template(named name: String) -> WorkoutTemplate? { repo.template(named: name) }
    func templateWorkout(_ id: UUID) -> Workout? { repo.workout(forTemplate: id) }
    func templates(matchingFingerprintOf workout: Workout) -> [WorkoutTemplate] {
        let fingerprint = WorkoutFingerprint.value(for: workout)
        return templates().filter { template in
            templateWorkout(template.id).map { WorkoutFingerprint.value(for: $0) == fingerprint } ?? false
        }
    }
    @discardableResult func saveAsTemplate(name: String, from workout: Workout, tags: [WorkoutTag] = []) -> WorkoutTemplate { repo.saveAsTemplate(name: name, from: workout, tags: tags) }
    @discardableResult func updateTemplate(_ id: UUID, from workout: Workout) -> WorkoutTemplate? { repo.updateTemplate(id, from: workout) }
    @discardableResult func saveImportedTemplate(name: String, workout: Workout, tags: [WorkoutTag] = []) throws -> WorkoutTemplate {
        let saved = try repo.saveImportedTemplate(name: name, from: workout, tags: tags)
        reload()
        return saved
    }
    @discardableResult func updateImportedTemplate(_ id: UUID, workout: Workout) throws -> WorkoutTemplate? {
        let saved = try repo.updateImportedTemplate(id, from: workout)
        reload()
        return saved
    }
    /// Instantiate a template onto a date (its own program, or a new Baseline program). Versioned.
    @discardableResult func instantiateTemplate(_ id: UUID, on date: Date, actor: PlanActor = .user) -> ScheduledWorkout? {
        defer { reload() }
        let programID = programs().first { $0.isActive && !$0.isArchived }?.id
            ?? addProgram(Program(name: "Baseline", createdAt: date)).id
        return repo.instantiateTemplate(id, on: date, programID: programID, actor: actor)
    }

    // MARK: Editing-surface binding (WorkoutStore write-throughs here — one mutation path)

    /// Today's first scheduled workout across active programs, if any.
    func todayScheduled(_ date: Date = Date()) -> ScheduledWorkout? { repo.day(date, filter: .allTraining).sessions.first }

    /// A sink that write-throughs a WorkoutStore's edits/lifecycle to a scheduled workout in the repo.
    func sink(forScheduled id: UUID) -> WorkoutStore.PlanSink {
        WorkoutStore.PlanSink(
            pushWorkout: { [weak self] w in self?.updateWorkout(id) { $0 = w } },
            pushSessionWorkout: { [weak self] w in self?.setSessionWorkout(id, w) },
            pushLog: { [weak self] l in self?.updateSessionLog(id) { $0 = l } },
            start: { [weak self] in _ = self?.start(id) },
            complete: { [weak self] in _ = self?.complete(id, acknowledgingOpenWork: true) },
            discard: { [weak self] in self?.discard(id) },
            reload: { [weak self] in
                guard let self, let sw = self.scheduledWorkout(id) else { return nil }
                let session = self.session(for: id)
                guard let session, session.status != .discarded else {
                    return (sw.workout, nil, nil)
                }
                // A live/completed session carries its own (possibly edited) workout copy — what the
                // athlete performed, and what the summary must show; fall back to the saved plan revision
                // when the session hasn't been edited. Nothing here decides write routing: an edit names
                // its own destination.
                return (session.workout ?? sw.workout, session.log, session.startedAt)
            },
            planWorkout: { [weak self] in self?.scheduledWorkout(id)?.workout })
    }

    /// Create a brand-new scheduled workout for today (used when the agent builds one and nothing is
    /// scheduled yet), returning a sink bound to it. Lands in the first active program, or a new
    /// `Baseline` program if none exists.
    func addTodayScheduled(workout: Workout, date: Date = Date()) -> WorkoutStore.PlanSink {
        let sw = newScheduledWorkout(on: date, workout: workout, origin: .baselineGenerated)
        return sink(forScheduled: sw.id)
    }

    /// Manually create a scheduled workout on a given day (the timeline "+ Add workout" flow). Blank by
    /// default — an implicit block ready for exercises. Versioned + undoable. Lands in the first active
    /// program, or a new `Baseline` program if none exists.
    @discardableResult
    func newScheduledWorkout(on date: Date, title: String = "New workout",
                             workout: Workout? = nil, origin: WorkoutOrigin = .userCreated) -> ScheduledWorkout {
        let programID = programs().first { $0.isActive && !$0.isArchived }?.id
            ?? addProgram(Program(name: "Baseline", createdAt: date)).id
        let day = Calendar.planWeek.startOfDay(for: date)
        let w: Workout = workout ?? {
            var w = Workout(title: title); w.scheduledDate = day
            w.blocks = [WorkoutBlock(name: "", isDefault: true)]   // implicit default block, ready for exercises
            return w
        }()
        let sw = ScheduledWorkout(programID: programID, date: day, origin: origin,
                                  workoutID: w.id, workoutRevisionID: UUID(), workout: w)
        _ = addWorkout(sw)   // versioned mutation — undoable
        return sw
    }

    // MARK: Seeding (migrator + tests)

    @discardableResult func addProgram(_ p: Program) -> Program { defer { reload() }; return repo.addProgram(p) }
    @discardableResult func addScheduled(_ sw: ScheduledWorkout) -> ScheduledWorkout { defer { reload() }; return repo.addScheduled(sw) }
}
