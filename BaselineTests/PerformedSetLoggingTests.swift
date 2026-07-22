import Foundation
import SwiftData
import Testing
@testable import Baseline

@Suite(.serialized) @MainActor
struct PerformedSetLoggingTests {
    @Test func activeSessionReturnsEveryPreciseTargetAndIndependentRevision() throws {
        let harness = PerformedLoggingHarness()
        let snapshot = try #require(harness.workouts.activeSessionSnapshot())
        let response = harness.tools.dispatch(.getActiveSession)

        #expect(response.text.contains("ACTIVE SESSION:"))
        #expect(snapshot.scope == .performedLog)
        #expect(snapshot.scheduledWorkoutID == harness.scheduled.id)
        #expect(snapshot.sessionID == harness.sessionID)
        #expect(snapshot.workoutID == harness.scheduled.workoutID)
        #expect(snapshot.workoutLogID == harness.session.log.id)
        #expect(snapshot.performedLogRevisionToken == harness.performedToken)
        #expect(snapshot.sessionWorkoutRevisionToken != snapshot.performedLogRevisionToken)
        #expect(snapshot.exercises.map(\.exerciseInstanceID) == [harness.strengthID, harness.runID])
        #expect(snapshot.exercises[0].plannedSets.map(\.plannedSetID) == [harness.strengthSetID])
        #expect(snapshot.exercises[0].plannedSets[0].outcome == .pending)
        #expect(snapshot.exercises[1].plannedSets.map(\.groupID) == [harness.runGroupID, harness.runGroupID])
        #expect(snapshot.exercises[1].plannedSets.map(\.iteration) == [1, 2])
    }

    @Test func athletePhrasingBecomesCanonicalActualsWithoutChangingThePlan() throws {
        let harness = PerformedLoggingHarness()
        let planBefore = harness.scheduled.workout
        let planRevisionBefore = harness.scheduled.workoutRevisionID

        let strength = harness.tools.dispatch(.upsertPerformedSet(
            exerciseInstanceID: harness.strengthID,
            plannedSetID: harness.strengthSetID,
            groupID: nil,
            iteration: nil,
            values: [
                .init(metric: .reps, valueText: "8"),
                .init(metric: .load, valueText: "185 lb"),
            ],
            expectedRevisionToken: harness.performedToken
        ))
        let strengthReceipt = try #require(strength.mutationReceipt)
        #expect(strengthReceipt.scope == .performedLog)
        #expect(strengthReceipt.undoAvailable)

        let run = harness.tools.dispatch(.upsertPerformedSet(
            exerciseInstanceID: harness.runID,
            plannedSetID: harness.runSetID,
            groupID: harness.runGroupID,
            iteration: 2,
            values: [
                .init(metric: .distance, valueText: "400 m"),
                .init(metric: .pace, valueText: "1:19 per 400 m"),
            ],
            expectedRevisionToken: strengthReceipt.afterRevisionToken
        ))
        _ = try #require(run.mutationReceipt)

        let session = try #require(harness.plan.session(for: harness.scheduled.id))
        let strengthActual = try #require(session.log.setLog(
            forPlanned: harness.strengthID,
            plannedSetID: harness.strengthSetID
        ))
        let runActual = try #require(session.log.setLog(
            forPlanned: harness.runID,
            plannedSetID: harness.runSetID,
            groupID: harness.runGroupID,
            iteration: 2
        ))
        #expect(strengthActual.reps == 8)
        #expect(abs((strengthActual.load ?? 0) - (185 * MetricConvert.kgPerPound)) < 0.0001)
        #expect(runActual.distance == 400)
        #expect(abs((runActual.values[.pace] ?? 0) - (79.0 / 400.0)) < 0.000_001)

        #expect(harness.plan.scheduledWorkout(harness.scheduled.id)?.workout == planBefore)
        #expect(harness.plan.scheduledWorkout(harness.scheduled.id)?.workoutRevisionID == planRevisionBefore)
        #expect(session.workout == nil)
        #expect(harness.workouts.current?.exercise(harness.strengthID)?.prescription.sets[0].load == 100)
        #expect(harness.workouts.current?.exercise(harness.runID)?.prescription.sets[0].values[.pace] == nil)
        #expect(harness.plan.sessionMutationVersions(sessionID: session.id).allSatisfy {
            $0.kind == .performedLog
        })
    }

    @Test func unqualifiedDimensionalNumberRejectsWithoutAnyWrite() throws {
        let harness = PerformedLoggingHarness()
        let before = harness.session.log
        let response = harness.tools.dispatch(.upsertPerformedSet(
            exerciseInstanceID: harness.strengthID,
            plannedSetID: harness.strengthSetID,
            groupID: nil,
            iteration: nil,
            values: [.init(metric: .load, valueText: "185")],
            expectedRevisionToken: harness.performedToken
        ))

        #expect(response.mutationReceipt == nil)
        #expect(response.text.contains("185 lb or 84 kg"))
        #expect(harness.plan.session(for: harness.scheduled.id)?.log == before)
        #expect(harness.plan.session(for: harness.scheduled.id)?.performedLogRevisionID == harness.performedToken)
        #expect(harness.plan.sessionMutationVersions(sessionID: harness.sessionID).isEmpty)
    }

    @Test func outcomesRestoreAndExerciseNotesPersistInThePerformedLog() throws {
        let harness = PerformedLoggingHarness()
        var token = harness.performedToken

        for outcome in [SetLogOutcome.completed, .skipped, .pending] {
            let response = harness.tools.dispatch(.setPerformedSetOutcome(
                target: .planned(
                    exerciseInstanceID: harness.strengthID,
                    plannedSetID: harness.strengthSetID,
                    groupID: nil,
                    iteration: nil
                ),
                outcome: outcome,
                expectedRevisionToken: token
            ))
            token = try #require(response.mutationReceipt).afterRevisionToken
            #expect(harness.plan.session(for: harness.scheduled.id)?.log.setLog(
                forPlanned: harness.strengthID,
                plannedSetID: harness.strengthSetID
            )?.outcome == outcome)
        }

        let note = harness.tools.dispatch(.addExerciseSessionNote(
            exerciseInstanceID: harness.strengthID,
            note: "Left shoulder felt stable",
            expectedRevisionToken: token
        ))
        _ = try #require(note.mutationReceipt)
        #expect(harness.plan.session(for: harness.scheduled.id)?.log
            .performed(forPlanned: harness.strengthID)?.athleteNotes == ["Left shoulder felt stable"])
        #expect(harness.plan.scheduledWorkout(harness.scheduled.id)?.workout
            .exercise(harness.strengthID)?.guidance == nil)
    }

    @Test func extraPerformedSetSupportsCreateUpdateOutcomeRestoreAndDelete() throws {
        let harness = PerformedLoggingHarness()
        let add = harness.tools.dispatch(.addExtraPerformedSet(
            exerciseInstanceID: harness.strengthID,
            groupID: nil,
            iteration: nil,
            values: [
                .init(metric: .reps, valueText: "6 reps"),
                .init(metric: .load, valueText: "175 lb"),
            ],
            expectedRevisionToken: harness.performedToken
        ))
        var token = try #require(add.mutationReceipt).afterRevisionToken
        let extraID = try #require(harness.workouts.activeSessionSnapshot()?
            .exercises.first { $0.exerciseInstanceID == harness.strengthID }?
            .extraPerformedSets.first?.performedSetID)

        let update = harness.tools.dispatch(.updateExtraPerformedSet(
            performedSetID: extraID,
            values: [.init(metric: .load, valueText: "180 lb")],
            expectedRevisionToken: token
        ))
        token = try #require(update.mutationReceipt).afterRevisionToken
        let updated = try #require(harness.workouts.activeSessionSnapshot()?
            .exercises.first { $0.exerciseInstanceID == harness.strengthID }?
            .extraPerformedSets.first)
        #expect(updated.values.int(.reps) == 6)
        #expect(abs((updated.values[.load] ?? 0) - (180 * MetricConvert.kgPerPound)) < 0.0001)

        for outcome in [SetLogOutcome.skipped, .pending] {
            let response = harness.tools.dispatch(.setPerformedSetOutcome(
                target: .extra(performedSetID: extraID),
                outcome: outcome,
                expectedRevisionToken: token
            ))
            token = try #require(response.mutationReceipt).afterRevisionToken
        }
        #expect(harness.workouts.activeSessionSnapshot()?.exercises[0]
            .extraPerformedSets.first?.outcome == .pending)

        let delete = harness.tools.dispatch(.deleteExtraPerformedSet(
            performedSetID: extraID,
            expectedRevisionToken: token
        ))
        _ = try #require(delete.mutationReceipt)
        #expect(harness.workouts.activeSessionSnapshot()?.exercises[0].extraPerformedSets.isEmpty == true)
        #expect(harness.plan.scheduledWorkout(harness.scheduled.id)?.workout
            .exercise(harness.strengthID)?.prescription.sets.count == 1)
    }

    @Test func undoRestoresBeforeSnapshotAndRejectsAStaleReceiptTruthfully() throws {
        let harness = PerformedLoggingHarness()
        let before = harness.session.log
        let edit = harness.tools.dispatch(.upsertPerformedSet(
            exerciseInstanceID: harness.strengthID,
            plannedSetID: harness.strengthSetID,
            groupID: nil,
            iteration: nil,
            values: [.init(metric: .load, valueText: "185 lb")],
            expectedRevisionToken: harness.performedToken
        ))
        let editReceipt = try #require(edit.mutationReceipt)

        let undo = harness.tools.dispatch(.undoSessionMutation(
            mutationID: editReceipt.mutationID,
            expectedRevisionToken: editReceipt.afterRevisionToken
        ))
        let undoReceipt = try #require(undo.mutationReceipt)
        #expect(undoReceipt.scope == .performedLog)
        #expect(!undoReceipt.undoAvailable)
        #expect(harness.plan.session(for: harness.scheduled.id)?.log == before)

        let second = harness.tools.dispatch(.upsertPerformedSet(
            exerciseInstanceID: harness.strengthID,
            plannedSetID: harness.strengthSetID,
            groupID: nil,
            iteration: nil,
            values: [.init(metric: .load, valueText: "190 lb")],
            expectedRevisionToken: undoReceipt.afterRevisionToken
        ))
        let secondReceipt = try #require(second.mutationReceipt)
        let later = harness.tools.dispatch(.addExerciseSessionNote(
            exerciseInstanceID: harness.strengthID,
            note: "Last set moved slowly",
            expectedRevisionToken: secondReceipt.afterRevisionToken
        ))
        let laterReceipt = try #require(later.mutationReceipt)

        let stale = harness.tools.dispatch(.undoSessionMutation(
            mutationID: secondReceipt.mutationID,
            expectedRevisionToken: secondReceipt.afterRevisionToken
        ))
        #expect(stale.mutationReceipt == nil)
        #expect(stale.text.contains("no longer the latest"))
        #expect(harness.plan.session(for: harness.scheduled.id)?.performedLogRevisionID == laterReceipt.afterRevisionToken)
        #expect(harness.plan.session(for: harness.scheduled.id)?.log
            .performed(forPlanned: harness.strengthID)?.athleteNotes == ["Last set moved slowly"])
    }
}

@MainActor
private final class PerformedLoggingHarness {
    let container: ModelContainer
    let plan: PlanStore
    let workouts: WorkoutStore
    let tools: AgentTools
    let scheduled: ScheduledWorkout
    let strengthID: UUID
    let strengthSetID: UUID
    let runID: UUID
    let runSetID: UUID
    let runGroupID: UUID

    init() {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try! ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))
        let program = plan.addProgram(Program(name: "Performed logging", createdAt: .now))

        var strength = PlannedExercise(exerciseName: "Back Squat", definitionId: "back_squat")
        strength.selectedMetrics = [.reps, .load]
        let strengthSet = PlannedSet(reps: 5, load: 100)
        strength.prescription.sets = [strengthSet]

        var run = PlannedExercise(exerciseName: "Run", definitionId: "run")
        run.selectedMetrics = [.distance, .pace]
        let runSet = PlannedSet(distance: 400)
        run.prescription.sets = [runSet]
        let runGroup = WorkoutGroup(
            label: "Intervals",
            execution: GroupExecution(repetition: .count(2)),
            children: [.exercise(run)]
        )

        let workout = Workout(
            title: "Training",
            blocks: [WorkoutBlock(
                name: "Main",
                nodes: [.exercise(strength), .group(runGroup)],
                isDefault: true
            )]
        )
        scheduled = plan.addScheduled(ScheduledWorkout(
            programID: program.id,
            date: .now,
            origin: .userCreated,
            workoutID: workout.id,
            workoutRevisionID: UUID(),
            workout: workout
        ))
        strengthID = strength.id
        strengthSetID = strengthSet.id
        runID = run.id
        runSetID = runSet.id
        runGroupID = runGroup.id

        let defaults = UserDefaults(suiteName: "performed-logging-\(UUID().uuidString)")!
        workouts = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        workouts.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        tools = AgentTools(
            store: TrainingContextStore(defaults: defaults),
            base: DecisionEngine.Inputs(),
            workouts: workouts
        )
        workouts.startWorkout()
    }

    var session: WorkoutSession { plan.session(for: scheduled.id)! }
    var sessionID: UUID { session.id }
    var performedToken: UUID { session.performedLogRevisionID! }
}
