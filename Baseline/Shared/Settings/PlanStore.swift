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

    // MARK: Seeding (migrator + tests)

    @discardableResult func addProgram(_ p: Program) -> Program { defer { reload() }; return repo.addProgram(p) }
    @discardableResult func addScheduled(_ sw: ScheduledWorkout) -> ScheduledWorkout { defer { reload() }; return repo.addScheduled(sw) }
}
