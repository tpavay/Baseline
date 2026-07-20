import Foundation
import SwiftData
import Testing
@testable import Baseline

/// In-workout editing: mid-session edits are scoped to the session and reach the saved plan only when
/// the athlete opts in at completion.
///
/// The invariant these tests defend is that a live session and the saved plan can diverge, and that the
/// divergence is described honestly and promoted only on request. Everything here runs against the real
/// SwiftData-backed repository because the plan-vs-session split is a persistence-boundary behavior.
@Suite(.serialized) @MainActor
struct WorkoutSessionEditingTests {
    /// SwiftData contexts do not retain their container; hold them for the suite's lifetime.
    private static var retainedContainers: [ModelContainer] = []
    /// `PlanSink` captures its `PlanStore` weakly, so a test that does not itself hold the store would
    /// silently get a sink whose closures all no-op. Retain them here so every test exercises a live
    /// plan regardless of whether it binds the store to a name.
    private static var retainedPlans: [PlanStore] = []

    private func makePlan() -> PlanStore {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(for: Schema(models),
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.retainedContainers.append(container)
        let plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))
        Self.retainedPlans.append(plan)
        return plan
    }

    private func buffer() -> WorkoutStore {
        WorkoutStore(defaults: UserDefaults(suiteName: "sess-\(UUID().uuidString)")!)
    }

    private func exercise(_ name: String, reps: Int = 5, load: Double = 100) -> PlannedExercise {
        var ex = PlannedExercise(exerciseName: name, definitionId: "deadlift")
        ex.prescription.sets = [PlannedSet(reps: reps, load: load)]
        return ex
    }

    private func workout(_ title: String = "W", _ exercises: [PlannedExercise]? = nil) -> Workout {
        Workout(title: title,
                blocks: [WorkoutBlock(name: "", exercises: exercises ?? [exercise("Squat")], isDefault: true)])
    }

    /// A store bound to a live session on a freshly scheduled workout — the state every test starts in.
    private func startedSession(
        _ w: Workout? = nil
    ) -> (plan: PlanStore, store: WorkoutStore, scheduledID: UUID) {
        let plan = makePlan()
        let program = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: program.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(),
                                           workout: w ?? workout()))
        let sw = plan.todayScheduled()!
        let store = buffer()
        store.bind(plan.sink(forScheduled: sw.id), coalesceContent: false)
        store.startWorkout()
        return (plan, store, sw.id)
    }

    // MARK: - Session-scoped edits

    @Test func midWorkoutEditDoesNotRewriteTheSavedPlan() {
        let (plan, store, id) = startedSession()

        store.edit { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        // The session sees the addition...
        #expect(store.current?.allExercises.count == 2)
        #expect(plan.session(for: id)?.workout?.allExercises.count == 2)
        // ...the saved plan does not.
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.count == 1)
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.first?.exerciseName == "Squat")
    }

    @Test func editsBeforeAnySessionStillEditThePlanDirectly() {
        // The session scoping must not leak into ordinary template editing.
        let plan = makePlan()
        let program = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: program.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: workout()))
        let sw = plan.todayScheduled()!
        let store = buffer()
        store.bind(plan.sink(forScheduled: sw.id), coalesceContent: false)

        store.edit { $0.rename("Renamed") }

        #expect(plan.scheduledWorkout(sw.id)?.workout.title == "Renamed")
    }

    @Test func sessionEditsSurviveAReloadFromThePlan() {
        let (plan, store, id) = startedSession()
        store.edit { $0.addExercise(self.exercise("Row"), toBlock: $0.blocks[0].id) }

        // A fresh buffer bound to the same session must see the session's shape, not the plan's.
        let reopened = buffer()
        reopened.bind(plan.sink(forScheduled: id), coalesceContent: false)

        #expect(reopened.current?.allExercises.map(\.exerciseName) == ["Squat", "Row"])
    }

    // MARK: - True removal and log integrity

    @Test func removingAnExercisePurgesItsLoggedSets() {
        let (plan, store, id) = startedSession(workout("W", [exercise("Squat"), exercise("Bench press")]))
        let squat = store.current!.allExercises[0]
        store.editLog {
            $0.upsertSetLog(forPlanned: squat.id, name: squat.exerciseName,
                            plannedSetID: squat.prescription.sets[0].id) { set in
                set.values[.load] = 105
                set.completed = true
            }
        }
        #expect(store.hasLoggedWork(forExercise: squat.id))

        store.removeExerciseFromWorkout(squat.id)

        // Gone from both sides — no performed record left to resurface at completion.
        #expect(store.current?.allExercises.map(\.exerciseName) == ["Bench press"])
        #expect(store.currentLog?.performed(forPlanned: squat.id) == nil)
        #expect(plan.session(for: id)?.log.performed(forPlanned: squat.id) == nil)
    }

    @Test func removingAnExerciseKeepsItOutOfCompletedHistory() {
        // The integrity guarantee that matters: completion normalizes history from the log, so a
        // removed exercise must not reappear as a completed row.
        let (plan, store, id) = startedSession(workout("W", [exercise("Squat"), exercise("Bench press")]))
        let squat = store.current!.allExercises[0]
        store.editLog {
            $0.upsertSetLog(forPlanned: squat.id, name: squat.exerciseName,
                            plannedSetID: squat.prescription.sets[0].id) { set in
                set.values[.load] = 105
                set.completed = true
            }
        }
        store.removeExerciseFromWorkout(squat.id)
        store.completeWorkout()

        let completed = plan.completed(for: id)
        #expect(completed?.log.performed(forPlanned: squat.id) == nil)
    }

    @Test func removingABlockPurgesEveryExercisesLoggedSets() {
        var w = workout("W", [exercise("Squat")])
        w.blocks.append(WorkoutBlock(name: "Accessory", exercises: [exercise("Curl")], isDefault: false))
        let (_, store, _) = startedSession(w)
        let curl = store.current!.blocks[1].exercises[0]
        store.editLog {
            $0.upsertSetLog(forPlanned: curl.id, name: curl.exerciseName,
                            plannedSetID: curl.prescription.sets[0].id) { set in
                set.values[.reps] = 12
                set.completed = true
            }
        }
        #expect(store.hasLoggedWork(inBlock: store.current!.blocks[1].id))

        store.removeBlockFromWorkout(store.current!.blocks[1].id)

        #expect(store.current?.blocks.count == 1)
        #expect(store.currentLog?.performed(forPlanned: curl.id) == nil)
    }

    @Test func removingTheOnlyBlockLeavesAnEmptyDefaultBlock() {
        let (_, store, _) = startedSession()

        store.removeBlockFromWorkout(store.current!.blocks[0].id)

        // A workout with zero blocks has nowhere to add an exercise back, so one always remains.
        #expect(store.current?.blocks.count == 1)
        #expect(store.current?.allExercises.isEmpty == true)
    }

    // MARK: - Reorder

    @Test func reorderingWithinABlockMovesOnlyThatBlocksNodes() {
        let (_, store, _) = startedSession(
            workout("W", [exercise("A"), exercise("B"), exercise("C")])
        )
        let blockID = store.current!.blocks[0].id

        store.edit { $0.moveNodes(inBlock: blockID, fromOffsets: IndexSet(integer: 2), toOffset: 0) }

        #expect(store.current?.allExercises.map(\.exerciseName) == ["C", "A", "B"])
    }

    @Test func reorderingBlocksMovesWholeBlocks() {
        var w = workout("W", [exercise("A")])
        w.blocks.append(WorkoutBlock(name: "Second", exercises: [exercise("B")], isDefault: false))
        let (_, store, _) = startedSession(w)

        store.edit { $0.moveBlocks(fromOffsets: IndexSet(integer: 1), toOffset: 0) }

        #expect(store.current?.blocks.map(\.name) == ["Second", ""])
        #expect(store.current?.allExercises.map(\.exerciseName) == ["B", "A"])
    }

    @Test func reorderingPreservesLoggedSets() {
        // The log links by plannedExerciseID, never by position — reordering must not disturb it.
        let (_, store, _) = startedSession(workout("W", [exercise("A"), exercise("B")]))
        let second = store.current!.allExercises[1]
        store.editLog {
            $0.upsertSetLog(forPlanned: second.id, name: second.exerciseName,
                            plannedSetID: second.prescription.sets[0].id) { set in
                set.values[.load] = 60
                set.completed = true
            }
        }

        store.edit { $0.moveNodes(inBlock: $0.blocks[0].id, fromOffsets: IndexSet(integer: 1), toOffset: 0) }

        #expect(store.current?.allExercises.map(\.exerciseName) == ["B", "A"])
        #expect(store.currentLog?.performed(forPlanned: second.id)?.setLogs.first?.values[.load] == 60)
    }

    // MARK: - Completion reconciliation

    @Test func anUneditedSessionOffersNoReconciliation() {
        let (_, store, _) = startedSession()
        let ex = store.current!.allExercises[0]
        // Logging actual values is not a plan change and must not trigger the prompt.
        store.editLog {
            $0.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName,
                            plannedSetID: ex.prescription.sets[0].id) { set in
                set.values[.load] = 120
                set.completed = true
            }
        }

        #expect(store.captureSessionReconciliation() == nil)
    }

    @Test func anEditedSessionReportsWhatChanged() {
        let (_, store, _) = startedSession()

        store.edit { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        let reconciliation = store.captureSessionReconciliation()
        #expect(reconciliation?.diff.changes.map(\.kind) == [.added])
        #expect(reconciliation?.diff.summaryLine == "Added Bench press")
    }

    @Test func decliningReconciliationLeavesThePlanUntouched() {
        let (plan, store, id) = startedSession()
        store.edit { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        _ = store.captureSessionReconciliation()   // captured, then discarded — the athlete said no
        store.completeWorkout()

        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat"])
    }

    @Test func acceptingReconciliationPromotesTheSessionToThePlan() {
        let (plan, store, id) = startedSession()
        store.edit { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        let reconciliation = store.captureSessionReconciliation()!
        store.completeWorkout()
        store.applySessionReconciliation(reconciliation)

        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
    }

    @Test func prescriptionChangesAreReportedAsAdjustments() {
        let (_, store, _) = startedSession()
        let setID = store.current!.allExercises[0].prescription.sets[0].id

        store.edit { $0.updateSet(setID) { $0.values[.reps] = 8 } }

        #expect(store.captureSessionReconciliation()?.diff.changes.map(\.kind) == [.adjusted])
    }

    @Test func aRemovedExerciseIsReportedAsRemoved() {
        let (_, store, _) = startedSession(workout("W", [exercise("Squat"), exercise("Bench press")]))

        store.removeExerciseFromWorkout(store.current!.allExercises[0].id)

        #expect(store.captureSessionReconciliation()?.diff.changes.map(\.kind) == [.removed])
    }

    // MARK: - Deleting a planned set

    @Test func deletingAPlannedSetPurgesItsLoggedActual() {
        var squat = exercise("Squat")
        squat.prescription.sets.append(PlannedSet(reps: 5, load: 100))
        let (_, store, _) = startedSession(workout("W", [squat]))
        let planned = store.current!.allExercises[0]
        for set in planned.prescription.sets {
            store.editLog {
                $0.upsertSetLog(forPlanned: planned.id, name: planned.exerciseName,
                                plannedSetID: set.id) { log in
                    log.values[.load] = 100
                    log.completed = true
                }
            }
        }

        store.removePlannedSets([planned.prescription.sets[1].id], fromExercise: planned.id)

        #expect(store.current?.exercise(planned.id)?.prescription.sets.count == 1)
        // The remaining actual is the one whose planned set survived — the deleted row leaves nothing.
        let logs = store.currentLog?.performed(forPlanned: planned.id)?.setLogs ?? []
        #expect(logs.map(\.plannedSetID) == [planned.prescription.sets[0].id])
    }

    @Test func aDeletedPlannedSetDoesNotReachCompletedHistory() {
        // Completion indexes history straight off the log's setLogs, so an orphaned actual would be
        // committed as volume the athlete had already deleted.
        var squat = exercise("Squat")
        squat.prescription.sets.append(PlannedSet(reps: 5, load: 100))
        let (plan, store, id) = startedSession(workout("W", [squat]))
        let planned = store.current!.allExercises[0]
        for set in planned.prescription.sets {
            store.editLog {
                $0.upsertSetLog(forPlanned: planned.id, name: planned.exerciseName,
                                plannedSetID: set.id) { log in
                    log.values[.load] = 100
                    log.completed = true
                }
            }
        }

        store.removePlannedSets([planned.prescription.sets[1].id], fromExercise: planned.id)
        store.completeWorkout()

        #expect(plan.completed(for: id)?.log.performed(forPlanned: planned.id)?.setLogs.count == 1)
    }

    // MARK: - Coalesced editing

    /// The Plan tab binds this store with `coalesceContent: true` so a keystroke doesn't become a write.
    /// Coalescing must never cost the athlete an edit: completion has to see the latest shape.
    @Test func aCoalescedSessionEditIsStillPresentAtCompletion() {
        let plan = makePlan()
        let program = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: program.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: workout()))
        let id = plan.todayScheduled()!.id
        let store = buffer()
        store.bind(plan.sink(forScheduled: id), coalesceContent: true)
        store.startWorkout()

        store.edit { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        // Coalesced: the edit is held in memory rather than written through on every keystroke.
        #expect(plan.session(for: id)?.workout == nil)
        // ...but it is still the session the athlete performed, so it is captured and committed.
        let reconciliation = store.captureSessionReconciliation()
        #expect(reconciliation?.diff.changes.map(\.kind) == [.added])

        store.completeWorkout()

        #expect(plan.session(for: id)?.workout?.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
    }

    // MARK: - The finish flow

    @Test func finishingAnEditedSessionRaisesThePromotionPrompt() async {
        let (_, store, _) = startedSession()
        store.edit { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        let finishing = WorkoutFinishCoordinator()

        let presentation = finishing.finish(store)

        // Completion is synchronous; only the prompt is deferred past the finish alert's dismissal,
        // because SwiftUI silently drops an alert raised from inside another alert's action handler.
        #expect(store.currentLog?.isComplete == true)
        #expect(finishing.pendingReconciliation == nil)
        await presentation?.value
        #expect(finishing.pendingReconciliation?.diff.summaryLine == "Added Bench press")
    }

    @Test func finishingAnUneditedSessionRaisesNoPrompt() async {
        let (_, store, _) = startedSession()
        let ex = store.current!.allExercises[0]
        // Logging actuals is a performed fact, not a plan change — finishing must stay silent.
        store.editLog {
            $0.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName,
                            plannedSetID: ex.prescription.sets[0].id) { set in
                set.values[.load] = 120
                set.completed = true
            }
        }
        let finishing = WorkoutFinishCoordinator()

        let presentation = finishing.finish(store)

        #expect(presentation == nil)
        #expect(store.currentLog?.isComplete == true)
        #expect(finishing.pendingReconciliation == nil)
    }

    @Test func acceptingThePromptFromTheFinishFlowPromotesTheSession() async {
        let (plan, store, id) = startedSession()
        store.edit { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        let finishing = WorkoutFinishCoordinator()

        await finishing.finish(store)?.value
        let pending = finishing.pendingReconciliation!
        finishing.apply(pending, to: store)

        #expect(finishing.pendingReconciliation == nil)
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
    }

}

/// The reconciliation diff itself, exercised without a store or persistence. These are the sentences
/// the completion prompt shows the athlete, so they are asserted directly.
@MainActor
struct WorkoutSessionReconciliationTests {

    private func exercise(_ name: String, reps: Int = 5) -> PlannedExercise {
        var ex = PlannedExercise(exerciseName: name, definitionId: "deadlift")
        ex.prescription.sets = [PlannedSet(reps: reps, load: 100)]
        return ex
    }

    /// A real session copies the plan, so both sides of a diff share block identity. The fixed block id
    /// reproduces that; generating a fresh one per call would make every diff look like a block swap.
    private static let blockID = UUID()

    private func workout(_ exercises: [PlannedExercise]) -> Workout {
        Workout(title: "W",
                blocks: [WorkoutBlock(id: Self.blockID, name: "", exercises: exercises, isDefault: true)])
    }

    @Test func identicalWorkoutsProduceNoChanges() {
        let w = workout([exercise("Squat")])
        #expect(!WorkoutSessionReconciliation.diff(plan: w, session: w).hasChanges)
    }

    @Test func detectsAdditionsAndRemovals() {
        let squat = exercise("Squat")
        let bench = exercise("Bench press")
        let before = workout([squat])
        var after = before
        after.blocks[0].nodes = [.exercise(bench)]

        let diff = WorkoutSessionReconciliation.diff(plan: before, session: after)
        #expect(diff.changes.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.added, .removed])
        #expect(diff.summaryLine.contains("Added Bench press"))
        #expect(diff.summaryLine.contains("Removed Squat"))
    }

    @Test func detectsAReplacementInPlace() {
        // Same node identity, different movement — a replace, not an add plus a remove.
        var squat = exercise("Squat")
        let before = workout([squat])
        squat.exerciseName = "Front squat"
        squat.definitionId = "front_squat"
        let after = workout([squat])

        let diff = WorkoutSessionReconciliation.diff(plan: before, session: after)
        #expect(diff.changes.map(\.kind) == [.replaced])
        #expect(diff.summaryLine == "Replaced Squat with Front squat")
    }

    @Test func detectsAReorderOfTheSharedExercises() {
        let a = exercise("A")
        let b = exercise("B")
        let before = workout([a, b])
        let after = workout([b, a])

        #expect(WorkoutSessionReconciliation.diff(plan: before, session: after).changes.map(\.kind) == [.reordered])
    }

    @Test func addingAnExerciseAloneIsNotReportedAsAReorder() {
        // Appending shifts no shared exercise's relative order, so the summary stays honest.
        let a = exercise("A")
        let before = workout([a])
        let after = workout([a, exercise("B")])

        #expect(WorkoutSessionReconciliation.diff(plan: before, session: after).changes.map(\.kind) == [.added])
    }

    @Test func detectsBlockAdditionAndRemoval() {
        let before = workout([exercise("A")])
        var after = before
        after.blocks.append(WorkoutBlock(name: "Finisher", exercises: [exercise("B")], isDefault: false))

        let added = WorkoutSessionReconciliation.diff(plan: before, session: after)
        #expect(added.changes.map(\.kind) == [.blockAdded])
        #expect(added.summaryLine == "Added block Finisher")

        let removed = WorkoutSessionReconciliation.diff(plan: after, session: before)
        #expect(removed.changes.map(\.kind) == [.blockRemoved])
        #expect(removed.summaryLine == "Removed block Finisher")
    }

    @Test func foldsATopLevelLogSubstitutionIntoTheSessionShape() {
        // "Replace Exercise" during logging is recorded on the log; the session shape must reflect it
        // so the prompt can offer to make the swap permanent.
        let squat = exercise("Squat")
        let base = workout([squat])
        var log = base.startLog()
        log.setExerciseAdjustment(
            plannedExerciseID: squat.id,
            outcome: .substituted,
            substitution: LoggedExerciseSubstitution(
                exerciseName: "Hack squat",
                definitionId: "hack_squat",
                selectedMetrics: squat.selectedMetrics,
                displayUnits: squat.displayUnits,
                prescription: squat.prescription
            ),
            name: squat.exerciseName
        )

        let session = WorkoutSessionReconciliation.effectiveSessionPlan(base: base, log: log)
        #expect(session.allExercises.first?.exerciseName == "Hack squat")

        let diff = WorkoutSessionReconciliation.diff(plan: base, session: session)
        #expect(diff.changes.map(\.kind) == [.replaced])
    }

    @Test func duplicateExerciseIDsDiffWithoutTrapping() {
        // Workouts also arrive from JSON import and agent tools, so a repeated exercise id is
        // data-shaped. Diffing runs the instant the athlete taps Finish Workout — it must not trap.
        let squat = exercise("Squat")
        let before = workout([squat, squat])
        var after = before
        after.blocks[0].nodes.append(.exercise(exercise("Bench press")))

        let diff = WorkoutSessionReconciliation.diff(plan: before, session: after)
        #expect(diff.changes.map(\.kind) == [.added])
    }

    @Test func aSkippedExerciseIsNotAPlanChange() {
        // Skipping means "not today", not "change my plan" — it must never trigger the prompt.
        let squat = exercise("Squat")
        let base = workout([squat])
        var log = base.startLog()
        log.setExerciseAdjustment(plannedExerciseID: squat.id, outcome: .skipped, name: squat.exerciseName)

        let session = WorkoutSessionReconciliation.effectiveSessionPlan(base: base, log: log)
        #expect(!WorkoutSessionReconciliation.diff(plan: base, session: session).hasChanges)
    }
}
