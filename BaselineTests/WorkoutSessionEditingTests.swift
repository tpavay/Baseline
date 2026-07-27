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
/// Collects the workouts a stub sink was asked to push, so a test can assert nothing was written.
@MainActor
private final class WorkoutBox {
    var workouts: [Workout] = []
}

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
        WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "sess-\(UUID().uuidString)")!)
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

    /// Drive the finish sequence the app actually runs: capture, complete, and answer the prompt when
    /// one appears. Tests that call `completeWorkout` directly can reach states the product cannot.
    private func finishAndDecline(_ store: WorkoutStore) async {
        let coordinator = WorkoutFinishCoordinator()
        await coordinator.finish(store)?.value
        if coordinator.pendingReconciliation != nil { coordinator.decline(store) }
    }

    private func finishAndAccept(_ store: WorkoutStore) async {
        let coordinator = WorkoutFinishCoordinator()
        await coordinator.finish(store)?.value
        if let pending = coordinator.pendingReconciliation { coordinator.apply(pending, to: store) }
    }

    // MARK: - Session-scoped edits

    @Test func midWorkoutEditDoesNotRewriteTheSavedPlan() {
        let (plan, store, id) = startedSession()

        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

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

        store.edit(.plan) { $0.rename("Renamed") }

        #expect(plan.scheduledWorkout(sw.id)?.workout.title == "Renamed")
    }

    @Test func sessionEditsSurviveAReloadFromThePlan() {
        let (plan, store, id) = startedSession()
        store.edit(.session) { $0.addExercise(self.exercise("Row"), toBlock: $0.blocks[0].id) }

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

        store.removeExerciseFromWorkout(squat.id, scope: .session)

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
        store.removeExerciseFromWorkout(squat.id, scope: .session)
        store.completeWorkout(awaitingReconciliationDecision: false)

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

        store.removeBlockFromWorkout(store.current!.blocks[1].id, scope: .session)

        #expect(store.current?.blocks.count == 1)
        #expect(store.currentLog?.performed(forPlanned: curl.id) == nil)
    }

    @Test func removingABlockPurgesItsGroupChoiceAndNestedExerciseLogs() {
        // Direct-control block deletion must leave no orphaned state behind — nested performed
        // records, group rounds, and choice selections all go with the block, the same guarantee
        // the agent removeBlock path makes.
        var w = workout("W", [exercise("Squat")])
        let nested = exercise("Curl")
        let group = WorkoutGroup(label: "Superset", children: [.exercise(nested)])
        let selected = exercise("Row")
        let choice = WorkoutChoice(label: "Finisher",
                                   options: [.exercise(selected), .exercise(exercise("Bike"))])
        w.blocks.append(WorkoutBlock(name: "Conditioning",
                                     nodes: [.group(group), .choice(choice)],
                                     isDefault: false))
        let (_, store, _) = startedSession(w)

        store.editLog { log in
            log.upsertSetLog(forPlanned: nested.id, name: nested.exerciseName,
                             plannedSetID: nested.prescription.sets[0].id) { set in
                set.values[.reps] = 10
                set.completed = true
            }
            log.upsertGroupLog(group.id) { $0.completedIterations = 2 }
            log.selectOption(selected.id, for: choice.id, selectionCount: 1)
        }
        #expect(store.currentLog?.groups.isEmpty == false)
        #expect(store.currentLog?.choices.isEmpty == false)

        store.removeBlockFromWorkout(store.current!.blocks[1].id, scope: .session)

        #expect(store.current?.blocks.count == 1)
        #expect(store.currentLog?.performed(forPlanned: nested.id) == nil)
        #expect(store.currentLog?.groups.isEmpty == true)
        #expect(store.currentLog?.choices.isEmpty == true)
    }

    @Test func removingTheOnlyBlockLeavesAnEmptyDefaultBlock() {
        let (_, store, _) = startedSession()

        store.removeBlockFromWorkout(store.current!.blocks[0].id, scope: .session)

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

        store.edit(.session) { $0.moveNodes(inBlock: blockID, fromOffsets: IndexSet(integer: 2), toOffset: 0) }

        #expect(store.current?.allExercises.map(\.exerciseName) == ["C", "A", "B"])
    }

    @Test func reorderingBlocksMovesWholeBlocks() {
        var w = workout("W", [exercise("A")])
        w.blocks.append(WorkoutBlock(name: "Second", exercises: [exercise("B")], isDefault: false))
        let (_, store, _) = startedSession(w)

        store.edit(.session) { $0.moveBlocks(fromOffsets: IndexSet(integer: 1), toOffset: 0) }

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

        store.edit(.session) { $0.moveNodes(inBlock: $0.blocks[0].id, fromOffsets: IndexSet(integer: 1), toOffset: 0) }

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

    /// Notes typed on the logging and completed surfaces are performed facts. They live on the log, so
    /// even the athlete who does opt in to "Update Plan" alongside a real structural edit cannot
    /// overwrite their coach guidance with "shoulder felt off today".
    @Test func sessionNotesCannotReachThePlanThroughReconciliation() async {
        var planned = exercise("Squat")
        planned.guidance = CoachGuidance(formCues: ["Coach: sit between the hips"])
        let (plan, store, id) = startedSession(workout("W", [planned]))
        let ex = store.current!.allExercises[0]

        store.editLog {
            $0.setNotes("Shoulder felt off today")
            $0.setNotes("Kept the last set light", forPlanned: ex.id, name: ex.exerciseName)
        }
        #expect(store.captureSessionReconciliation() == nil)

        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        await finishAndAccept(store)

        let promoted = plan.scheduledWorkout(id)?.workout
        #expect(promoted?.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
        #expect(promoted?.goal == nil)
        #expect(promoted?.allExercises.first?.guidance?.formCues == ["Coach: sit between the hips"])
        #expect(store.currentLog?.notesText == "Shoulder felt off today")
        #expect(store.currentLog?.performed(forPlanned: ex.id)?.notesText == "Kept the last set light")
    }

    @Test func anEditedSessionReportsWhatChanged() {
        let (_, store, _) = startedSession()

        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        let reconciliation = store.captureSessionReconciliation()
        #expect(reconciliation?.diff.changes.map(\.kind) == [.added])
        #expect(reconciliation?.diff.summaryLine == "Added Bench press")
    }

    @Test func decliningReconciliationLeavesThePlanUntouched() async {
        let (plan, store, id) = startedSession()
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        await finishAndDecline(store)

        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat"])
    }

    @Test func acceptingReconciliationPromotesTheSessionToThePlan() async {
        let (plan, store, id) = startedSession()
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        await finishAndAccept(store)

        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
    }

    @Test func prescriptionChangesAreReportedAsAdjustments() {
        let (_, store, _) = startedSession()
        let setID = store.current!.allExercises[0].prescription.sets[0].id

        store.edit(.session) { $0.updateSet(setID) { $0.values[.reps] = 8 } }

        #expect(store.captureSessionReconciliation()?.diff.changes.map(\.kind) == [.adjusted])
    }

    @Test func aRemovedExerciseIsReportedAsRemoved() {
        let (_, store, _) = startedSession(workout("W", [exercise("Squat"), exercise("Bench press")]))

        store.removeExerciseFromWorkout(store.current!.allExercises[0].id, scope: .session)

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

        store.removePlannedSets([planned.prescription.sets[1].id], fromExercise: planned.id, scope: .session)

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

        store.removePlannedSets([planned.prescription.sets[1].id], fromExercise: planned.id, scope: .session)
        store.completeWorkout(awaitingReconciliationDecision: false)

        #expect(plan.completed(for: id)?.log.performed(forPlanned: planned.id)?.setLogs.count == 1)
    }

    // MARK: - The plan-tab binding (content edits coalesce; session edits never do)

    /// The scheduled workout as the Plan tab opens it: coalesced content edits, flushed on dismiss.
    private func planTabSession(
        _ w: Workout? = nil
    ) -> (plan: PlanStore, store: WorkoutStore, scheduledID: UUID) {
        let plan = makePlan()
        let program = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: program.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(),
                                           workout: w ?? workout()))
        let id = plan.todayScheduled()!.id
        let store = buffer()
        store.bind(plan.sink(forScheduled: id), coalesceContent: true)
        return (plan, store, id)
    }

    @Test func aSessionEditIsPersistedImmediatelyEvenOnTheCoalescingBinding() {
        // Coalescing is a plan-editing optimisation only. A session edit has to hit the session copy as
        // it happens, or a force-quit mid-workout loses every add, removal, and reorder — while the log,
        // which is never coalesced, keeps the performed rows that belonged to them.
        let (plan, store, id) = planTabSession()
        store.startWorkout()

        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        #expect(plan.session(for: id)?.workout?.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
        // A fresh store — the app relaunching mid-session — reads the edit straight back.
        let reopened = buffer()
        reopened.bind(plan.sink(forScheduled: id), coalesceContent: true)
        #expect(reopened.current?.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
    }

    @Test func preSessionEditingStillCoalescesAndFlushesToThePlan() {
        let (plan, store, id) = planTabSession()

        store.edit(.plan) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        // Held until the sheet dismisses, exactly as before — no session is involved.
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.count == 1)
        store.flush()
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
    }

    /// Dismissing the workout sheet mid-session must write nothing to the plan — not because a flag
    /// happened to hold the right value, but because a session edit never fills the flush buffer.
    @Test func flushingMidSessionCreatesNoPlanRevision() {
        let (plan, store, id) = planTabSession()
        store.startWorkout()
        let revisionBefore = plan.scheduledWorkout(id)?.workoutRevisionID

        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        store.removeExerciseFromWorkout(store.current!.allExercises[0].id, scope: .session)
        // The edits really happened — the session copy has them, so an unchanged plan means routing.
        #expect(plan.session(for: id)?.workout?.allExercises.map(\.exerciseName) == ["Bench press"])

        store.flush()

        #expect(plan.scheduledWorkout(id)?.workoutRevisionID == revisionBefore)
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat"])
    }

    /// The hard invariant: `applySessionReconciliation` is the only path that may promote a session shape.
    @Test func decliningReconciliationThenFlushingLeavesThePlanUntouched() async {
        let (plan, store, id) = planTabSession()
        store.startWorkout()
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        let revisionBefore = plan.scheduledWorkout(id)?.workoutRevisionID
        #expect(plan.session(for: id)?.workout?.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])

        await finishAndDecline(store)              // the athlete tapped "Keep Original"
        store.flush()                              // ...and then dismissed the sheet

        #expect(plan.scheduledWorkout(id)?.workoutRevisionID == revisionBefore)
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat"])
    }

    @Test func acceptingReconciliationThenFlushingPromotesExactlyOnce() async {
        let (plan, store, id) = planTabSession()
        store.startWorkout()
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        let revisionBefore = plan.scheduledWorkout(id)?.workoutRevisionID

        await finishAndAccept(store)
        let revisionAfterPromotion = plan.scheduledWorkout(id)?.workoutRevisionID
        store.flush()

        // One revision for the promotion, and none for the dismissal that followed it.
        #expect(revisionAfterPromotion != revisionBefore)
        #expect(plan.scheduledWorkout(id)?.workoutRevisionID == revisionAfterPromotion)
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
    }

    /// Declining settles the decision without touching content, so the summary still shows the workout
    /// the athlete actually performed — added exercises present, removed ones gone.
    @Test func decliningLeavesTheCompletedSummaryOnThePerformedShape() async {
        let (_, store, _) = startedSession(workout("W", [exercise("Squat"), exercise("Bench press")]))
        store.edit(.session) { $0.addExercise(self.exercise("Curl"), toBlock: $0.blocks[0].id) }
        store.removeExerciseFromWorkout(store.current!.allExercises[1].id, scope: .session)

        await finishAndDecline(store)

        #expect(store.current?.allExercises.map(\.exerciseName) == ["Squat", "Curl"])
    }

    /// The agent has no presentation mode, so it follows the one explicit lifecycle signal: session
    /// while the decision is open, plan once it is settled.
    @Test func anAgentEditAfterDecliningReachesThePlanAndNotTheFinishedSession() async {
        let (plan, store, id) = startedSession()
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        await finishAndDecline(store)
        let sessionShape = plan.session(for: id)?.workout?.allExercises.map(\.exerciseName)

        store.addBlock(name: "Finisher", intent: nil)

        #expect(plan.scheduledWorkout(id)?.workout.blocks.contains { $0.name == "Finisher" } == true)
        // ...built on the plan, so it cannot carry the exercise the athlete just declined.
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat"])
        // The frozen session is history, not an editing surface — the edit must not rewrite it.
        #expect(plan.session(for: id)?.workout?.allExercises.map(\.exerciseName) == sessionShape)
        #expect(plan.session(for: id)?.workout?.blocks.contains { $0.name == "Finisher" } != true)
    }

    @Test func anAgentEditAfterAcceptingReachesThePlanOnTopOfThePromotedShape() async {
        let (plan, store, id) = startedSession()
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        await finishAndAccept(store)
        store.addBlock(name: "Finisher", intent: nil)

        #expect(plan.scheduledWorkout(id)?.workout.blocks.contains { $0.name == "Finisher" } == true)
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
    }

    /// The notes the athlete types on the logging screen have to be there when they come back to it —
    /// a relaunch, or reopening the completed summary. Both levels persist with the session log.
    @Test func sessionNotesSurviveALaunchAndComeBackToTheSameFields() async {
        let (plan, store, id) = startedSession()
        let ex = store.current!.allExercises[0]
        store.editLog {
            $0.setNotes("Legs heavy from yesterday")
            $0.setNotes("Dropped to 90kg", forPlanned: ex.id, name: ex.exerciseName)
        }

        let relaunched = buffer()
        relaunched.bind(plan.sink(forScheduled: id), coalesceContent: false)

        #expect(relaunched.currentLog?.notesText == "Legs heavy from yesterday")
        #expect(relaunched.currentLog?.performed(forPlanned: ex.id)?.notesText == "Dropped to 90kg")

        await finishAndDecline(relaunched)
        #expect(relaunched.currentLog?.notesText == "Legs heavy from yesterday")
        #expect(plan.completed(for: id)?.log.notesText == "Legs heavy from yesterday")
    }

    /// A note the athlete typed is logged work: removing the exercise mid-session must warn before it
    /// discards one, exactly as it does for logged sets.
    @Test func aTypedSessionNoteCountsAsLoggedWork() {
        let (_, store, _) = startedSession()
        let ex = store.current!.allExercises[0]

        #expect(store.hasLoggedWork(forExercise: ex.id) == false)

        store.editLog { $0.setNotes("Tweaked my back on the warm-up", forPlanned: ex.id, name: ex.exerciseName) }

        #expect(store.hasLoggedWork(forExercise: ex.id))
        #expect(store.hasSessionNote(forExercise: ex.id))
        #expect(store.hasLoggedSets(forExercise: ex.id) == false)
        #expect(store.hasLoggedWork(inBlock: store.current!.blocks[0].id))

        // Sets and a note together: the discard warning reads both flags, so both stay true.
        store.editLog {
            $0.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName,
                            plannedSetID: ex.prescription.sets[0].id) { set in
                set.values[.load] = 100
                set.completed = true
            }
        }
        #expect(store.hasLoggedSets(forExercise: ex.id))
        #expect(store.hasSessionNote(forExercise: ex.id))
    }

    /// A fresh store bound after the workout is over — the app relaunching, then the agent asked to
    /// change today's plan. Nothing in the completed session may be rewritten.
    @Test func aStoreReboundAfterCompletionEditsThePlanNotTheFinishedSession() async {
        let (plan, store, id) = startedSession()
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        await finishAndDecline(store)
        let sessionShape = plan.session(for: id)?.workout?.allExercises.map(\.exerciseName)

        let relaunched = buffer()
        relaunched.bind(plan.sink(forScheduled: id), coalesceContent: false)
        relaunched.addBlock(name: "Finisher", intent: nil)

        #expect(plan.scheduledWorkout(id)?.workout.blocks.contains { $0.name == "Finisher" } == true)
        #expect(plan.session(for: id)?.workout?.allExercises.map(\.exerciseName) == sessionShape)
        #expect(plan.session(for: id)?.workout?.blocks.contains { $0.name == "Finisher" } != true)
    }

    // MARK: - One decision, shared by every store bound to the workout

    /// The Plan tab's execution store and the app-level agent store are bound to the same scheduled
    /// workout at once. The unresolved-decision fact belongs to the session, so they must not disagree —
    /// otherwise where an agent edit lands depends on which screen the chat was opened from.
    @Test func everyStoreBoundToTheSameWorkoutAgreesAboutTheDecision() {
        let (plan, exec, id) = planTabSession()
        let appLevel = buffer()
        appLevel.bind(plan.sink(forScheduled: id), coalesceContent: false)   // as RootView binds at launch

        exec.startWorkout()

        #expect(exec.hasUnresolvedSessionDecision)
        #expect(appLevel.hasUnresolvedSessionDecision)

        _ = exec.captureSessionReconciliation()
        exec.completeWorkout(awaitingReconciliationDecision: true)
        exec.declineSessionReconciliation()

        #expect(!exec.hasUnresolvedSessionDecision)
        #expect(!appLevel.hasUnresolvedSessionDecision)
    }

    // MARK: - What the coach says matches what the coach changed

    private func agentTools(_ workouts: WorkoutStore, _ plan: PlanStore? = nil) -> AgentTools {
        AgentTools(store: TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!),
                   base: DecisionEngine.Inputs(),
                   workouts: workouts,
                   plan: plan)
    }

    /// The confirmation must describe the workout the tool actually changed. Echoing the declined
    /// session content back — while omitting what was just added — would be the coach stating something
    /// false about the athlete's own plan.
    @Test func anAgentConfirmationAfterDecliningDescribesThePlanNotTheDeclinedSession() async throws {
        let (plan, exec, id) = planTabSession()
        let appLevel = buffer()
        appLevel.bind(plan.sink(forScheduled: id), coalesceContent: false)
        exec.startWorkout()
        exec.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        await finishAndDecline(exec)
        appLevel.reloadFromPlan()

        let token = try #require(appLevel.mutationTarget(appLevel.agentScope)?.revisionToken)
        let response = agentTools(appLevel).dispatch(.addBlock(
            name: "Finisher",
            intent: nil,
            guidance: nil,
            atIndex: nil,
            expectedRevisionToken: token
        ))

        #expect(response.text.contains("Finisher"))
        #expect(!response.text.contains("Bench press"))
        #expect(!(appLevel.compactSummary(appLevel.agentScope) ?? "").isEmpty)
    }

    /// The one door that outlives the session: a template instantiates into every future workout built
    /// from it, so declined content saved there would escape the session permanently.
    @Test func savingATemplateAfterDecliningCapturesThePlanNotTheDeclinedSession() async {
        let (plan, exec, id) = planTabSession()
        let appLevel = buffer()
        appLevel.bind(plan.sink(forScheduled: id), coalesceContent: false)
        exec.startWorkout()
        exec.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        await finishAndDecline(exec)
        appLevel.reloadFromPlan()

        _ = agentTools(appLevel, plan).dispatch(.saveAsTemplate(name: "Push A"))

        let saved = plan.template(named: "Push A")
        #expect(saved != nil)
        #expect(plan.templateWorkout(saved!.id)?.allExercises.map(\.exerciseName) == ["Squat"])
    }

    @Test func updatingATemplateAfterDecliningCapturesThePlanNotTheDeclinedSession() async {
        let (plan, exec, id) = planTabSession()
        let appLevel = buffer()
        appLevel.bind(plan.sink(forScheduled: id), coalesceContent: false)
        let seed = plan.saveAsTemplate(name: "Push A", from: workout("Seed", [exercise("Row")]))
        exec.startWorkout()
        exec.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        await finishAndDecline(exec)
        appLevel.reloadFromPlan()

        #expect(plan.templateWorkout(seed.id)?.allExercises.map(\.exerciseName) == ["Row"])

        _ = agentTools(appLevel, plan).dispatch(.updateTemplate(name: "Push A"))

        // Distinct seed content, so this proves both halves: the update ran, and it took the plan.
        #expect(plan.templateWorkout(seed.id)?.allExercises.map(\.exerciseName) == ["Squat"])
    }

    /// The mirror: while the session owns the editing surface, the coach reads and echoes the session.
    @Test func anAgentConfirmationDuringALiveSessionDescribesTheSession() throws {
        let (plan, exec, id) = planTabSession()
        let appLevel = buffer()
        appLevel.bind(plan.sink(forScheduled: id), coalesceContent: false)
        exec.startWorkout()
        exec.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        appLevel.reloadFromPlan()

        let token = try #require(appLevel.mutationTarget(appLevel.agentScope)?.revisionToken)
        let response = agentTools(appLevel).dispatch(.addBlock(
            name: "Finisher",
            intent: nil,
            guidance: nil,
            atIndex: nil,
            expectedRevisionToken: token
        ))

        #expect(response.text.contains("Finisher"))
        #expect(response.text.contains("Bench press"))
    }

    /// A bound store whose scheduled workout has been deleted has no plan to edit. It must do nothing
    /// rather than treat whatever is on screen as the plan — the last way session content could become
    /// a plan payload.
    @Test func aBoundStoreWithNoResolvablePlanWorkoutDoesNotFallBackToCurrent() {
        let pushes = WorkoutBox()
        let sessionShape = workout("Session shape", [exercise("Squat"), exercise("Bench press")])
        let sink = WorkoutStore.PlanSink(
            pushWorkout: { pushes.workouts.append($0) },
            pushSessionWorkout: { _ in },
            pushLog: { _ in },
            start: {}, complete: {}, discard: {},
            isSessionDecisionPending: { false },
            resolveSessionDecision: {},
            resolveAbandonedSessionDecision: {},
            reload: { (sessionShape, nil, nil) },
            planWorkout: { nil }                      // the scheduled workout is gone
        )
        let store = buffer()
        store.bind(sink, coalesceContent: false)

        store.edit(.plan) { $0.rename("Renamed") }

        #expect(pushes.workouts.isEmpty)
        #expect(store.current?.title == "Session shape")
        #expect(store.summary(.plan) == "No workout has been created yet.")
    }

    /// The last door: a plan-scoped write used to build its payload from `current`, which still holds the
    /// performed shape after a decline. No relaunch needed — this is the chat opened from the Today tab.
    @Test func aPlanEditAfterDecliningCannotCarryTheDeclinedSessionContent() async {
        let (plan, exec, id) = planTabSession()
        let appLevel = buffer()
        appLevel.bind(plan.sink(forScheduled: id), coalesceContent: false)
        exec.startWorkout()
        exec.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        await finishAndDecline(exec)
        appLevel.reloadFromPlan()                       // ConversationView does this before dispatching
        appLevel.addBlock(name: "Finisher", intent: nil)

        // The plan is the original content plus the plan edit — and nothing else.
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat"])
        #expect(plan.scheduledWorkout(id)?.workout.blocks.contains { $0.name == "Finisher" } == true)
    }

    /// A session reached through resume (or one that was live across an app update, whose stored flag
    /// predates the field) is still unanswered, so its edits belong to the session.
    @Test func aResumedSessionRoutesEditsToTheSessionNotThePlan() {
        let (plan, store, id) = planTabSession()
        store.startWorkout()
        plan.resolveSessionDecision(id)                 // simulate a row that lost the fact
        #expect(!store.hasUnresolvedSessionDecision)

        _ = plan.resume(id)

        #expect(store.hasUnresolvedSessionDecision)
        let revisionBefore = plan.scheduledWorkout(id)?.workoutRevisionID
        store.addBlock(name: "Finisher", intent: nil)
        #expect(plan.session(for: id)?.workout?.blocks.contains { $0.name == "Finisher" } == true)
        #expect(plan.scheduledWorkout(id)?.workoutRevisionID == revisionBefore)
    }

    @Test func anAgentEditThroughTheAppLevelStoreMidSessionIsSessionScoped() {
        let (plan, exec, id) = planTabSession()
        let appLevel = buffer()
        appLevel.bind(plan.sink(forScheduled: id), coalesceContent: false)
        exec.startWorkout()
        let revisionBefore = plan.scheduledWorkout(id)?.workoutRevisionID

        appLevel.reloadFromPlan()                       // as the chat surface does before dispatching
        appLevel.addBlock(name: "Finisher", intent: nil)

        #expect(plan.session(for: id)?.workout?.blocks.contains { $0.name == "Finisher" } == true)
        #expect(plan.scheduledWorkout(id)?.workoutRevisionID == revisionBefore)
        #expect(plan.scheduledWorkout(id)?.workout.blocks.contains { $0.name == "Finisher" } != true)
    }

    /// The common path: the workout was performed as planned, so no prompt appears. Completion has to
    /// settle the decision itself, or the finished session stays the editing surface indefinitely.
    @Test func anEditAfterAnUneditedSessionReachesThePlan() {
        let (plan, store, id) = startedSession()
        let finishing = WorkoutFinishCoordinator()

        #expect(finishing.finish(store) == nil)         // nothing diverged ⇒ no prompt
        #expect(!store.hasUnresolvedSessionDecision)

        store.addBlock(name: "Finisher", intent: nil)

        #expect(plan.scheduledWorkout(id)?.workout.blocks.contains { $0.name == "Finisher" } == true)
        #expect(plan.session(for: id)?.workout?.blocks.contains { $0.name == "Finisher" } != true)
    }

    /// Terminated between finishing and answering the prompt: the decision must not stay open forever,
    /// and resolving it as declined must not write anything to the plan.
    @Test func aCompletedSessionWhosePromptWasNeverAnsweredIsTreatedAsDeclined() {
        let (plan, store, id) = startedSession()
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        _ = store.captureSessionReconciliation()
        store.completeWorkout(awaitingReconciliationDecision: true)
        #expect(store.hasUnresolvedSessionDecision)
        let revisionBefore = plan.scheduledWorkout(id)?.workoutRevisionID

        let relaunched = buffer()
        relaunched.bind(plan.sink(forScheduled: id), coalesceContent: false)

        #expect(!relaunched.hasUnresolvedSessionDecision)
        #expect(plan.scheduledWorkout(id)?.workoutRevisionID == revisionBefore)
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat"])
    }

    /// A bound store whose scheduled workout has been deleted has nowhere to write. The agent must say
    /// so rather than reporting a creation that only ever existed in the local buffer.
    @Test func creatingAWorkoutReportsFailureWhenThePlanWorkoutIsGone() {
        let plan = makePlan()
        let program = plan.addProgram(Program(name: "P", createdAt: Date()))
        plan.addScheduled(ScheduledWorkout(programID: program.id, date: Date(), origin: .userCreated,
                                           workoutID: UUID(), workoutRevisionID: UUID(), workout: workout()))
        let sw = plan.todayScheduled()!
        let store = buffer()
        store.bind(plan.sink(forScheduled: sw.id), coalesceContent: false)

        guard case .confirmationRequired(_, _, let proposalID) = plan.delete(sw.id) else {
            Issue.record("deleting a scheduled workout should ask for confirmation"); return
        }
        #expect(plan.delete(sw.id, proposalID: proposalID).isApplied)

        let response = agentTools(store, plan).dispatch(.createWorkout(title: "Something else", note: nil,
                                                                      replaceExisting: true))

        #expect(response.text.contains("isn't in your plan any more"))
        #expect(!response.text.contains("Created workout"))
        #expect(plan.todayScheduled() == nil)
        #expect(plan.scheduledWorkout(sw.id) == nil)
    }

    @Test func replacingTheWorkoutIsRefusedWhileASessionOwnsIt() {
        let (plan, store, id) = startedSession()

        #expect(!store.create(title: "Something else", goal: nil).succeeded)

        // Neither side was touched, and the log still matches the workout it was started against.
        #expect(store.current?.allExercises.map(\.exerciseName) == ["Squat"])
        #expect(plan.scheduledWorkout(id)?.workout.title == "W")
        #expect(store.currentLog != nil)
    }

    @Test func discardingASessionReturnsTheStoreToTheSavedPlan() {
        let (plan, store, id) = planTabSession()
        store.startWorkout()
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }

        store.discardLog()

        // The session's shape went with the session; later edits are ordinary plan edits again.
        #expect(store.current?.allExercises.map(\.exerciseName) == ["Squat"])
        store.edit(.plan) { $0.rename("Renamed") }
        store.flush()
        #expect(plan.scheduledWorkout(id)?.workout.title == "Renamed")
    }

    // MARK: - The finish flow

    @Test func finishingAnEditedSessionRaisesThePromotionPrompt() async {
        let (_, store, _) = startedSession()
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
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
        store.edit(.session) { $0.addExercise(self.exercise("Bench press"), toBlock: $0.blocks[0].id) }
        let finishing = WorkoutFinishCoordinator()

        await finishing.finish(store)?.value
        let pending = finishing.pendingReconciliation!
        finishing.apply(pending, to: store)

        #expect(finishing.pendingReconciliation == nil)
        #expect(plan.scheduledWorkout(id)?.workout.allExercises.map(\.exerciseName) == ["Squat", "Bench press"])
    }

}

/// Which destination each surface writes to. Asserted for every mode so the mapping is a stated
/// decision rather than a default that can quietly flip.
@MainActor
struct WorkoutEditScopeMappingTests {

    @Test func performedSurfacesEditTheSessionAndPlanSurfacesEditThePlan() {
        #expect(WorkoutPresentationMode.log.editScope == .session)
        #expect(WorkoutPresentationMode.completed.editScope == .session)
        #expect(WorkoutPresentationMode.editTemplate.editScope == .plan)
        #expect(WorkoutPresentationMode.view.editScope == .plan)
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
