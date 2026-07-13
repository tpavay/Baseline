import Foundation
import SwiftData
import Testing
@testable import Baseline

/// Slice 2: typed, versioned schedule mutations — append-only history, undo/restore, the stored-proposal
/// confirmation gate, and the active-session guard. Headless, against an in-memory container.
@Suite(.serialized) @MainActor
struct PlanMutationTests {

    private func makeRepo() -> SwiftDataPlanRepository {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(for: Schema(models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return SwiftDataPlanRepository(context: container.mainContext)
    }
    private let cal = Calendar.planWeek
    private var mon: Date { cal.weekStart(for: Date(timeIntervalSince1970: 1_752_000_000)) }
    private func day(_ o: Int) -> Date { cal.date(byAdding: .day, value: o, to: mon)! }

    private func work(_ t: String) -> Workout {
        var ex = PlannedExercise(exerciseName: "Squat", definitionId: "deadlift")
        ex.prescription.sets = [PlannedSet(reps: 5, load: 100)]
        return Workout(title: t, blocks: [WorkoutBlock(name: "", exercises: [ex], isDefault: true)])
    }
    private func seed(_ r: SwiftDataPlanRepository, _ title: String, on date: Date, program: UUID) -> ScheduledWorkout {
        r.addScheduled(ScheduledWorkout(programID: program, date: date, origin: .userCreated,
                                        workoutID: UUID(), workoutRevisionID: UUID(), workout: work(title)))
    }

    @Test func moveIsVersionedAndUndoable() {
        let r = makeRepo(); let p = r.addProgram(Program(name: "P", createdAt: mon))
        let a = seed(r, "A", on: mon, program: p.id)

        #expect(r.move(a.id, toDate: day(2), timeOfDay: nil, actor: .user, reason: nil).isApplied)
        #expect(cal.isDate(r.scheduledWorkout(a.id)!.date, inSameDayAs: day(2)))
        #expect(r.versions(limit: 99).count == 2)   // genesis + move

        #expect(r.undo(actor: .user).isApplied)
        #expect(cal.isDate(r.scheduledWorkout(a.id)!.date, inSameDayAs: mon))   // back to Monday
        #expect(r.versions(limit: 99).count == 3)   // append-only — history grew, not shrank
    }

    @Test func swapExchangesDays() {
        let r = makeRepo(); let p = r.addProgram(Program(name: "P", createdAt: mon))
        let a = seed(r, "A", on: mon, program: p.id)
        let b = seed(r, "B", on: day(3), program: p.id)
        #expect(r.swap(a.id, b.id, actor: .user, reason: nil).isApplied)
        #expect(cal.isDate(r.scheduledWorkout(a.id)!.date, inSameDayAs: day(3)))
        #expect(cal.isDate(r.scheduledWorkout(b.id)!.date, inSameDayAs: mon))
    }

    @Test func deleteRequiresConfirmationThenApplies_andUndoRestores() {
        let r = makeRepo(); let p = r.addProgram(Program(name: "P", createdAt: mon))
        let a = seed(r, "A", on: mon, program: p.id)

        // First call — no proposal → confirmationRequired, nothing removed.
        guard case .confirmationRequired(_, _, let pid) = r.delete(a.id, actor: .user, reason: nil, proposalID: nil) else {
            Issue.record("expected confirmationRequired"); return
        }
        #expect(r.scheduledWorkout(a.id) != nil)

        // Resubmit with the proposal id → applied.
        #expect(r.delete(a.id, actor: .user, reason: nil, proposalID: pid).isApplied)
        #expect(r.scheduledWorkout(a.id) == nil)

        // Undo brings it back (append-only history).
        #expect(r.undo(actor: .user).isApplied)
        #expect(r.scheduledWorkout(a.id) != nil)
    }

    @Test func staleProposalRegeneratesInsteadOfApplying() {
        let r = makeRepo(); let p = r.addProgram(Program(name: "P", createdAt: mon))
        let a = seed(r, "A", on: mon, program: p.id)
        let b = seed(r, "B", on: mon, program: p.id)

        guard case .confirmationRequired(_, _, let pid) = r.delete(a.id, actor: .user, reason: nil, proposalID: nil) else {
            Issue.record("expected confirmationRequired"); return
        }
        // The schedule moves under the proposal → the "yes" must not apply the stale delete.
        #expect(r.move(b.id, toDate: day(1), timeOfDay: nil, actor: .user, reason: nil).isApplied)
        guard case .confirmationRequired = r.delete(a.id, actor: .user, reason: nil, proposalID: pid) else {
            Issue.record("expected regenerated confirmationRequired"); return
        }
        #expect(r.scheduledWorkout(a.id) != nil)   // NOT deleted by the stale yes
    }

    @Test func editContentRevisionsAndUndoRestoresPriorContent() {
        let r = makeRepo(); let p = r.addProgram(Program(name: "P", createdAt: mon))
        let a = seed(r, "W", on: mon, program: p.id)
        let before = r.scheduledWorkout(a.id)!.workoutRevisionID

        #expect(r.editContent(a.id, actor: .user, reason: nil) { $0.rename("W2") }.isApplied)
        #expect(r.scheduledWorkout(a.id)!.workout.title == "W2")
        #expect(r.scheduledWorkout(a.id)!.workoutRevisionID != before)

        #expect(r.undo(actor: .user).isApplied)
        #expect(r.scheduledWorkout(a.id)!.workout.title == "W")            // prior content restored
        #expect(r.scheduledWorkout(a.id)!.workoutRevisionID == before)      // via the immutable old revision
    }

    @Test func restoreToAnEarlierVersion() {
        let r = makeRepo(); let p = r.addProgram(Program(name: "P", createdAt: mon))
        let a = seed(r, "A", on: mon, program: p.id)
        guard case .applied(_, let v1) = r.move(a.id, toDate: day(1), timeOfDay: nil, actor: .user, reason: nil) else { Issue.record("v1"); return }
        #expect(r.move(a.id, toDate: day(4), timeOfDay: nil, actor: .user, reason: nil).isApplied)
        #expect(cal.isDate(r.scheduledWorkout(a.id)!.date, inSameDayAs: day(4)))

        #expect(r.restore(versionID: v1.id, actor: .user).isApplied)
        #expect(cal.isDate(r.scheduledWorkout(a.id)!.date, inSameDayAs: day(1)))   // back to v1's state
    }

    @Test func undoConflictingWithAnActiveSessionIsRejected() {
        let r = makeRepo(); let p = r.addProgram(Program(name: "P", createdAt: mon))
        let a = seed(r, "A", on: mon, program: p.id)
        #expect(r.move(a.id, toDate: day(2), timeOfDay: nil, actor: .user, reason: nil).isApplied)
        _ = r.startSession(forScheduled: a.id, now: day(2))          // live session on A

        // Undo would move A back under the athlete → refused, session untouched.
        #expect(r.undo(actor: .user) == .rejected(.activeSessionConflict))
        #expect(cal.isDate(r.scheduledWorkout(a.id)!.date, inSameDayAs: day(2)))
        #expect(r.session(forScheduled: a.id)?.status == .active)
    }
}

extension MutationResult: Equatable {
    public static func == (l: MutationResult, r: MutationResult) -> Bool {
        switch (l, r) {
        case (.rejected(let a), .rejected(let b)): return a == b
        case (.applied, .applied): return true
        case (.confirmationRequired, .confirmationRequired): return true
        default: return false
        }
    }
}
