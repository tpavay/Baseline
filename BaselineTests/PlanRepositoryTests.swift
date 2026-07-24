import Foundation
import SwiftData
import Testing
@testable import Baseline

/// Slice 1 persistence: the SwiftData-backed repository (reads + lifecycle) and the migrator, exercised
/// against an in-memory container. Everything runs on the main actor (SwiftData `ModelContext`).
@Suite(.serialized) @MainActor
struct PlanRepositoryTests {

    private func makeRepo() -> SwiftDataPlanRepository {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(for: Schema(models),
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return SwiftDataPlanRepository(context: container.mainContext)
    }

    private let cal = Calendar.planWeek
    private var monday: Date { cal.weekStart(for: Date(timeIntervalSince1970: 1_752_000_000)) }

    private func workout(_ title: String) -> Workout {
        var ex = PlannedExercise(exerciseName: "Squat", definitionId: "deadlift")
        ex.prescription.sets = [PlannedSet(reps: 5, load: 100), PlannedSet(reps: 5, load: 100)]
        return Workout(title: title, blocks: [WorkoutBlock(name: "", exercises: [ex], isDefault: true)])
    }

    private func seed(_ repo: SwiftDataPlanRepository, date: Date, program: UUID) -> ScheduledWorkout {
        repo.addScheduled(ScheduledWorkout(programID: program, date: date, origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: workout("W")))
    }

    @Test func weekProjectionBucketsSessionsByDay() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        _ = seed(repo, date: monday, program: prog.id)
        _ = seed(repo, date: cal.date(byAdding: .day, value: 2, to: monday)!, program: prog.id)
        _ = seed(repo, date: cal.date(byAdding: .day, value: 9, to: monday)!, program: prog.id)  // next week — excluded

        let week = repo.week(containing: monday, filter: .allTraining)
        #expect(week.days.count == 7)
        #expect(week.days[0].sessions.count == 1)     // Monday
        #expect(week.days[2].sessions.count == 1)     // Wednesday
        #expect(week.days.flatMap(\.sessions).count == 2)
    }

    @Test func dayRangeIsInclusiveAndPreservesEmptyDays() {
        let repo = makeRepo()
        let program = repo.addProgram(Program(name: "P", createdAt: monday))
        let wednesday = cal.date(byAdding: .day, value: 2, to: monday)!
        _ = seed(repo, date: wednesday, program: program.id)

        let days = repo.days(from: monday, through: wednesday, filter: .allTraining)

        #expect(days.count == 3)
        #expect(days.map(\.date) == [monday, cal.date(byAdding: .day, value: 1, to: monday)!, wednesday])
        #expect(days[0].sessions.isEmpty)
        #expect(days[1].sessions.isEmpty)
        #expect(days[2].sessions.count == 1)
    }

    @Test func hydratesWorkoutContentFromRevision() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)
        let read = repo.scheduledWorkout(sw.id)
        #expect(read?.workout.title == "W")
        #expect(read?.workout.allExercises.first?.prescription.sets.count == 2)
    }

    @Test func programFilterExcludesOtherPrograms() {
        let repo = makeRepo()
        let a = repo.addProgram(Program(name: "A", createdAt: monday))
        let b = repo.addProgram(Program(name: "B", createdAt: monday))
        _ = seed(repo, date: monday, program: a.id)
        _ = seed(repo, date: monday, program: b.id)
        #expect(repo.week(containing: monday, filter: .allTraining).days[0].sessions.count == 2)
        #expect(repo.week(containing: monday, filter: .program(a.id)).days[0].sessions.count == 1)
    }

    @Test func lifecycleStartCompleteKeepsPlanAndFreezesLog() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)

        #expect(repo.session(forScheduled: sw.id) == nil)
        let session = repo.startSession(forScheduled: sw.id, now: monday)
        #expect(session?.status == .active)
        // Idempotent — starting again returns the same live session.
        #expect(repo.startSession(forScheduled: sw.id, now: monday)?.id == session?.id)

        // Unlogged sets → completion warns instead of finalizing.
        if case .unloggedWork(let sets, _) = repo.completeSession(forScheduled: sw.id, acknowledgingOpenWork: false, now: monday) {
            #expect(sets == 2)
        } else { Issue.record("expected unloggedWork") }

        // Acknowledge → completes; a CompletedWorkoutLog exists and the plan is untouched.
        if case .completed = repo.completeSession(forScheduled: sw.id, acknowledgingOpenWork: true, now: monday) {
            #expect(repo.completedLog(forScheduled: sw.id) != nil)
            #expect(repo.scheduledWorkout(sw.id)?.workout.allExercises.first?.prescription.sets.count == 2)
        } else { Issue.record("expected completed") }
    }

    /// Discarding an *empty* workout — one scheduled only to start logging right now — must leave the
    /// day truly undecided. `purgeProvisionalWorkout` removes the whole placeholder (scheduled workout
    /// and its session), so the day shows no stuck workout and carries no stale rest marker.
    @Test func purgingAProvisionalWorkoutLeavesTheDayUndecided() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        // A blank workout scheduled up front, then started — exactly what "Start an empty workout" does.
        let sw = repo.addScheduled(ScheduledWorkout(
            programID: prog.id, date: monday, origin: .userCreated,
            workoutID: UUID(), workoutRevisionID: UUID(),
            workout: Workout(title: "New workout", blocks: [WorkoutBlock(name: "", isDefault: true)])))
        repo.startSession(forScheduled: sw.id, now: monday)
        #expect(repo.day(monday, filter: .allTraining).sessions.count == 1)
        #expect(repo.session(forScheduled: sw.id) != nil)

        #expect(repo.purgeProvisionalWorkout(sw.id, actor: .user, reason: nil).isApplied)

        let day = repo.day(monday, filter: .allTraining)
        #expect(day.sessions.isEmpty)                        // no workout stuck on the day
        #expect(day.isRestDay == false)                      // and no stale rest marker — reads undecided
        #expect(repo.scheduledWorkout(sw.id) == nil)
        #expect(repo.session(forScheduled: sw.id) == nil)    // the session is gone too — no orphan
    }

    /// The bug's other half, pinned as a contrast: plain `discardSession` only marks the session
    /// discarded and deliberately keeps the scheduled workout so a real session can restart from the
    /// saved revision. That is why an empty placeholder needs `purgeProvisionalWorkout`, not discard.
    @Test func discardSessionKeepsTheScheduledWorkoutUnlikePurge() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)
        repo.startSession(forScheduled: sw.id, now: monday)

        repo.discardSession(forScheduled: sw.id)

        #expect(repo.day(monday, filter: .allTraining).sessions.count == 1)
        #expect(repo.scheduledWorkout(sw.id) != nil)
    }

    @Test func editingWorkoutCreatesANewImmutableRevision() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)
        let before = repo.scheduledWorkout(sw.id)!.workoutRevisionID

        repo.updateWorkout(scheduledID: sw.id) { $0.rename("Edited") }
        let after = repo.scheduledWorkout(sw.id)!

        #expect(after.workout.title == "Edited")
        #expect(after.workoutRevisionID != before)   // new revision, old one untouched
        #expect(after.workoutID == sw.workoutID)      // stable identity across revisions
    }

    private func completeDeadlift(_ repo: SwiftDataPlanRepository, _ sw: ScheduledWorkout, load: Double) {
        let ex = sw.workout.allExercises.first { $0.definitionId == "deadlift" }!
        repo.startSession(forScheduled: sw.id, now: sw.date)
        repo.updateSessionLog(forScheduled: sw.id) { log in
            log.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName, plannedSetID: ex.prescription.sets[0].id) { $0.values[.load] = load; $0.completed = true }
        }
        _ = repo.completeSession(forScheduled: sw.id, acknowledgingOpenWork: true, now: sw.date)
    }

    @Test func historyIsNewestFirstAndGlobalAcrossPrograms() {
        let repo = makeRepo()
        let a = repo.addProgram(Program(name: "Block A", createdAt: monday))
        let b = repo.addProgram(Program(name: "Block B", createdAt: monday))
        completeDeadlift(repo, seed(repo, date: monday, program: a.id), load: 100)
        completeDeadlift(repo, seed(repo, date: cal.date(byAdding: .day, value: 3, to: monday)!, program: b.id), load: 110)

        let h = repo.history(exerciseDefinitionID: "deadlift", limit: 10)
        #expect(h.count == 2)                                  // spans both programs
        #expect(h.first!.date > h.last!.date)                  // newest-first
        #expect(h.first?.sets.first?[.load] == 110)            // most recent session
        #expect(Set(h.map(\.programID)) == Set([a.id, b.id]))
    }

    @Test func unidentifiedExerciseNeverMergesIntoHistory() {
        let repo = makeRepo()
        let p = repo.addProgram(Program(name: "P", createdAt: monday))
        // A workout with an identified deadlift + an unnamed one-off (no definitionId).
        var known = PlannedExercise(exerciseName: "Deadlift", definitionId: "deadlift")
        known.prescription.sets = [PlannedSet(reps: 5, load: 100)]
        var oneOff = PlannedExercise(exerciseName: "Mystery Move")   // definitionId nil
        oneOff.prescription.sets = [PlannedSet(reps: 5)]
        let w = Workout(title: "Mixed", blocks: [WorkoutBlock(name: "", exercises: [known, oneOff], isDefault: true)])
        let sw = repo.addScheduled(ScheduledWorkout(programID: p.id, date: monday, origin: .userCreated,
                                                    workoutID: UUID(), workoutRevisionID: UUID(), workout: w))
        completeDeadlift(repo, sw, load: 100)

        #expect(repo.history(exerciseDefinitionID: "deadlift", limit: 10).count == 1)   // only the identified one
        // The one-off produced no queryable identity — no display-name bucket to merge into.
    }

    @Test func completedCollectionFiltersToCompletedOnly() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let a = seed(repo, date: monday, program: prog.id)
        _ = seed(repo, date: monday, program: prog.id)                 // B, left untouched
        repo.startSession(forScheduled: a.id, now: monday)
        _ = repo.completeSession(forScheduled: a.id, acknowledgingOpenWork: true, now: monday)

        let completed = repo.week(containing: monday, filter: .collection(.completed)).days.flatMap(\.sessions)
        #expect(completed.map(\.id) == [a.id])
        // Ad-hoc collection (origin-based) sees both; archived sees none.
        #expect(repo.week(containing: monday, filter: .collection(.adHoc)).days.flatMap(\.sessions).count == 2)
        #expect(repo.week(containing: monday, filter: .collection(.archived)).days.flatMap(\.sessions).isEmpty)
    }

    @Test func previousPerformanceReadsCompletedActualsByIdentity() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)          // exercise definitionId == "deadlift"
        let ex = sw.workout.allExercises.first!

        repo.startSession(forScheduled: sw.id, now: monday)
        repo.updateSessionLog(forScheduled: sw.id) { log in
            log.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName, plannedSetID: ex.prescription.sets[0].id) { s in
                s.values[.load] = 100; s.values.setInt(.reps, 5); s.completed = true
            }
        }
        _ = repo.completeSession(forScheduled: sw.id, acknowledgingOpenWork: true, now: monday)

        let prev = repo.mostRecentPerformance(exerciseDefinitionID: "deadlift", before: cal.date(byAdding: .day, value: 1, to: monday)!)
        #expect(prev?.sets.first?[.load] == 100)
        #expect(repo.mostRecentPerformance(exerciseDefinitionID: "deadlift", before: monday) == nil)   // strictly before
        #expect(repo.mostRecentPerformance(exerciseDefinitionID: "nonexistent", before: cal.date(byAdding: .day, value: 1, to: monday)!) == nil)
    }

    /// A session where the athlete only wrote a note still produces a performed record, and that record
    /// must not become the "previous" hint — it would hide the last session that actually had numbers.
    @Test func previousPerformanceSkipsASessionThatLoggedOnlyANote() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let withSets = seed(repo, date: monday, program: prog.id)
        let setExercise = withSets.workout.allExercises.first!
        repo.startSession(forScheduled: withSets.id, now: monday)
        repo.updateSessionLog(forScheduled: withSets.id) { log in
            log.upsertSetLog(forPlanned: setExercise.id, name: setExercise.exerciseName,
                             plannedSetID: setExercise.prescription.sets[0].id) { s in
                s.values[.load] = 100; s.values.setInt(.reps, 5); s.completed = true
            }
        }
        _ = repo.completeSession(forScheduled: withSets.id, acknowledgingOpenWork: true, now: monday)

        let tuesday = cal.date(byAdding: .day, value: 1, to: monday)!
        let notesOnly = seed(repo, date: tuesday, program: prog.id)
        let notedExercise = notesOnly.workout.allExercises.first!
        repo.startSession(forScheduled: notesOnly.id, now: tuesday)
        repo.updateSessionLog(forScheduled: notesOnly.id) { log in
            log.setNotes("Shoulder felt off, skipped the working sets",
                         forPlanned: notedExercise.id, name: notedExercise.exerciseName)
        }
        _ = repo.completeSession(forScheduled: notesOnly.id, acknowledgingOpenWork: true, now: tuesday)

        let prev = repo.mostRecentPerformance(
            exerciseDefinitionID: "deadlift",
            before: cal.date(byAdding: .day, value: 2, to: monday)!
        )
        #expect(prev?.date == monday)
        #expect(prev?.sets.first?[.load] == 100)

        // History has to agree with the previous hint: an empty card would take the "most recent"
        // position from the session that actually has numbers to compare against.
        let history = repo.history(exerciseDefinitionID: "deadlift", limit: 10)
        #expect(history.map(\.date) == [monday])
    }

    /// Drives the two-step delete (propose → confirm) the UI uses, returning nothing but asserting the
    /// erase applied. Keeps the cascade tests below focused on *what* the delete removes.
    @discardableResult
    private func confirmDelete(_ repo: SwiftDataPlanRepository, _ id: UUID) -> Bool {
        guard case .confirmationRequired(_, _, let proposalID) = repo.delete(id, actor: .user, reason: nil, proposalID: nil) else {
            Issue.record("expected confirmationRequired for delete"); return false
        }
        let applied = repo.delete(id, actor: .user, reason: nil, proposalID: proposalID).isApplied
        #expect(applied)
        return applied
    }

    /// The core fix: deleting a *completed* scheduled workout must cascade to its performed rows. There is
    /// no SwiftData cascade (loose UUID foreign keys), so before the fix the `SDCompletedLog` and its
    /// `SDCompletedExercise` index survived as orphans and kept feeding history/PRs and the Today cards.
    @Test func deletingACompletedWorkoutErasesItsPerformedRows() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)
        completeDeadlift(repo, sw, load: 100)

        // Precondition: the performed footprint exists and is queryable.
        #expect(repo.completedLog(forScheduled: sw.id) != nil)
        #expect(repo.history(exerciseDefinitionID: "deadlift", limit: 10).count == 1)

        confirmDelete(repo, sw.id)

        // The schedule row and its whole performed footprint are gone — no orphans left to feed history.
        #expect(repo.scheduledWorkout(sw.id) == nil)
        #expect(repo.completedLog(forScheduled: sw.id) == nil)
        #expect(repo.history(exerciseDefinitionID: "deadlift", limit: 10).isEmpty)
        #expect(repo.mostRecentPerformance(exerciseDefinitionID: "deadlift", before: cal.date(byAdding: .day, value: 1, to: monday)!) == nil)
    }

    /// The cascade is scoped to the deleted workout only — a sibling completed day keeps its performed
    /// history untouched. This pins "match on scheduledWorkoutID; do not over-delete."
    @Test func deletingOneCompletedWorkoutLeavesSiblingHistoryIntact() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let doomed = seed(repo, date: monday, program: prog.id)
        let kept = seed(repo, date: cal.date(byAdding: .day, value: 2, to: monday)!, program: prog.id)
        completeDeadlift(repo, doomed, load: 100)
        completeDeadlift(repo, kept, load: 140)
        #expect(repo.history(exerciseDefinitionID: "deadlift", limit: 10).count == 2)

        confirmDelete(repo, doomed.id)

        let survivors = repo.history(exerciseDefinitionID: "deadlift", limit: 10)
        #expect(survivors.count == 1)                                   // only the sibling's row remains
        #expect(survivors.first?.sets.first?[.load] == 140)            // and it is the kept one, unchanged
        #expect(repo.completedLog(forScheduled: kept.id) != nil)
        #expect(repo.scheduledWorkout(kept.id) != nil)
    }

    /// Deleting a workout that was never completed has no performed rows to cascade — it must still just
    /// remove the schedule row and touch nothing else (the discard-of-a-not-yet-completed case).
    @Test func deletingAnUncompletedWorkoutRemovesOnlyTheScheduleRow() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)
        let sibling = seed(repo, date: monday, program: prog.id)
        completeDeadlift(repo, sibling, load: 100)

        confirmDelete(repo, sw.id)

        #expect(repo.scheduledWorkout(sw.id) == nil)
        #expect(repo.history(exerciseDefinitionID: "deadlift", limit: 10).count == 1)   // sibling untouched
    }

    /// `purgeProvisionalWorkout` now routes through the same cascade helper, so its previously-omitted
    /// `SDCompletedExercise` index is cleaned up too — a discarded placeholder that had logged a set no
    /// longer leaks an orphan into history.
    @Test func purgeAlsoErasesTheCompletedExerciseIndex() {
        let repo = makeRepo()
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))
        let sw = seed(repo, date: monday, program: prog.id)
        completeDeadlift(repo, sw, load: 100)
        #expect(repo.history(exerciseDefinitionID: "deadlift", limit: 10).count == 1)

        #expect(repo.purgeProvisionalWorkout(sw.id, actor: .user, reason: nil).isApplied)

        #expect(repo.completedLog(forScheduled: sw.id) == nil)
        #expect(repo.history(exerciseDefinitionID: "deadlift", limit: 10).isEmpty)   // no orphaned exercise index
    }

    @Test func migratorSeedsTodaysScheduledWorkoutOnceWithoutWiping() {
        let repo = makeRepo()
        let plan = PlanStore(repo: repo, today: monday)
        let defaults = UserDefaults(suiteName: "mig-\(UUID().uuidString)")!
        let workouts = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
        workouts.create(title: "Legacy day", goal: nil)

        PlanMigrator.migrateIfNeeded(defaults: defaults, into: plan, workouts: workouts, today: monday)
        let today = repo.week(containing: monday, filter: .allTraining).days[0]
        #expect(today.sessions.count == 1)
        #expect(today.sessions.first?.origin == .legacyMigrated)
        #expect(today.sessions.first?.workout.title == "Legacy day")

        // Idempotent — a second run adds nothing, and the legacy workout is still present (not wiped).
        PlanMigrator.migrateIfNeeded(defaults: defaults, into: plan, workouts: workouts, today: monday)
        #expect(repo.week(containing: monday, filter: .allTraining).days[0].sessions.count == 1)
        #expect(workouts.current?.title == "Legacy day")
    }
}
