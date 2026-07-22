import Foundation
import SwiftData
import Testing
@testable import Baseline

@Suite(.serialized) @MainActor
struct WorkoutMutationEnvelopeTests {
    private func makeHarness() -> WorkoutMutationHarness {
        WorkoutMutationHarness()
    }

    @Test func agentEditCreatesVersionedRevisionAndDurableReceipt() {
        let harness = makeHarness()
        let (plan, store, scheduled, setID) = harness.boundWorkout()
        let before = scheduled.workoutRevisionID

        guard case .mutated(let receipt) = store.updateSet(
            exerciseNamed: "Squat",
            setNumber: 1,
            setID: setID,
            reps: 8,
            load: nil,
            durationSeconds: nil,
            rpe: nil,
            expectedRevisionToken: before
        ) else {
            Issue.record("Expected the agent mutation to apply")
            return
        }

        let persisted = plan.scheduledWorkout(scheduled.id)
        let versions = plan.versions()
        #expect(persisted?.workoutRevisionID == receipt.afterRevisionToken)
        #expect(persisted?.workout.allExercises.first?.prescription.sets.first?.reps == 8)
        #expect(receipt.beforeRevisionToken == before)
        #expect(receipt.actor == .agent)
        #expect(receipt.scope == .plan)
        #expect(receipt.undoAvailable)
        #expect(receipt.diff.changes.first?.entityID == setID)
        #expect(versions.count == 2)
        #expect(versions.last?.actor == .agent)
        #expect(versions.last?.operation.id == receipt.mutationID)
        #expect(versions.last?.workoutMutationReceipt == receipt)
    }

    @Test func targetedUndoRestoresSnapshotWhenMutationIsStillHead() {
        let harness = makeHarness()
        let (plan, store, scheduled, setID) = harness.boundWorkout()
        let originalRevision = scheduled.workoutRevisionID

        guard case .mutated(let editReceipt) = store.updateSet(
            exerciseNamed: "Squat",
            setNumber: 1,
            setID: setID,
            reps: 8,
            load: nil,
            durationSeconds: nil,
            rpe: nil,
            expectedRevisionToken: originalRevision
        ) else {
            Issue.record("Expected the edit to apply")
            return
        }
        guard case .mutated(let undoReceipt) = store.undoMutation(
            mutationID: editReceipt.mutationID,
            expectedRevisionToken: editReceipt.afterRevisionToken
        ) else {
            Issue.record("Expected targeted undo to apply")
            return
        }

        let restored = plan.scheduledWorkout(scheduled.id)
        #expect(restored?.workoutRevisionID == originalRevision)
        #expect(restored?.workout.allExercises.first?.prescription.sets.first?.reps == 5)
        #expect(undoReceipt.beforeRevisionToken == editReceipt.afterRevisionToken)
        #expect(undoReceipt.afterRevisionToken == originalRevision)
        #expect(!undoReceipt.undoAvailable)
        #expect(plan.versions().count == 3)
        #expect(plan.versions().last?.operation.kind == .undo)

        let repeatedUndo = plan.undoWorkoutMutation(
            mutationID: undoReceipt.mutationID,
            expectedRevisionToken: undoReceipt.afterRevisionToken
        )
        #expect(repeatedUndo == .rejected(.undoUnavailable))
        #expect(plan.versions().count == 3)
    }

    @Test func targetedUndoRejectsWhenALaterEditIntervened() {
        let harness = makeHarness()
        let (plan, store, scheduled, setID) = harness.boundWorkout()

        guard case .mutated(let first) = store.updateSet(
            exerciseNamed: "Squat",
            setNumber: 1,
            setID: setID,
            reps: 8,
            load: nil,
            durationSeconds: nil,
            rpe: nil,
            expectedRevisionToken: scheduled.workoutRevisionID
        ), case .mutated(let second) = store.updateSet(
            exerciseNamed: "Squat",
            setNumber: 1,
            setID: setID,
            reps: 10,
            load: nil,
            durationSeconds: nil,
            rpe: nil,
            expectedRevisionToken: first.afterRevisionToken
        ) else {
            Issue.record("Expected both edits to apply")
            return
        }

        guard case .notFound(let message) = store.undoMutation(
            mutationID: first.mutationID,
            expectedRevisionToken: first.afterRevisionToken
        ) else {
            Issue.record("Expected stale targeted undo to reject")
            return
        }

        #expect(message.contains("no longer the latest"))
        #expect(plan.scheduledWorkout(scheduled.id)?.workoutRevisionID == second.afterRevisionToken)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.allExercises.first?.prescription.sets.first?.reps == 10)
        #expect(plan.versions().count == 3)
    }

    @Test func staleExpectedRevisionRejectsWithoutAnyWrite() {
        let harness = makeHarness()
        let (plan, store, scheduled, setID) = harness.boundWorkout()

        let result = store.updateSet(
            exerciseNamed: "Squat",
            setNumber: 1,
            setID: setID,
            reps: 8,
            load: nil,
            durationSeconds: nil,
            rpe: nil,
            expectedRevisionToken: UUID()
        )

        guard case .notFound(let message) = result else {
            Issue.record("Expected a stale mutation to reject")
            return
        }
        #expect(message.contains("changed after I read it"))
        #expect(plan.scheduledWorkout(scheduled.id)?.workoutRevisionID == scheduled.workoutRevisionID)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.allExercises.first?.prescription.sets.first?.reps == 5)
        #expect(plan.versions().isEmpty)
    }

    @Test func everyExistingWorkoutContentToolUsesTheSharedVersionedEnvelope() throws {
        let harness = makeHarness()
        let (plan, store, scheduled, _) = harness.boundWorkout(includeChoice: true)
        var token = scheduled.workoutRevisionID
        var receipts: [WorkoutMutationReceipt] = []

        func record(_ receipt: WorkoutMutationReceipt) {
            #expect(receipt.beforeRevisionToken == token)
            #expect(receipt.actor == .agent)
            #expect(receipt.scope == .plan)
            #expect(receipt.undoAvailable)
            token = receipt.afterRevisionToken
            receipts.append(receipt)
        }

        record(try #require(store.updateWorkoutMetadata(
            title: .set("Updated strength"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: token
        ).mutationReceipt))
        let mainBlock = try #require(plan.scheduledWorkout(scheduled.id)?.workout.blocks.first)
        record(try #require(store.updateBlockMetadata(
            blockID: mainBlock.id,
            name: .unchanged,
            intent: .set("Strength"),
            guidance: .unchanged,
            expectedRevisionToken: token
        ).mutationReceipt))
        let squat = try #require(plan.scheduledWorkout(scheduled.id)?.workout.allExercises.first)
        record(try #require(store.updateExerciseMetadata(
            exerciseInstanceID: squat.id,
            displayLabel: .set("Primary squat"),
            guidance: .unchanged,
            expectedRevisionToken: token
        ).mutationReceipt))

        record(try #require(store.addBlock(
            name: "Accessory",
            intent: nil,
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.addExercise(
            name: "Bench Press",
            toBlockNamed: "Accessory",
            sets: 1,
            reps: 8,
            load: 60,
            durationSeconds: nil,
            expectedRevisionToken: token
        ).mutationReceipt))

        let bench = try #require(plan.scheduledWorkout(scheduled.id)?.workout.allExercises.first {
            $0.exerciseName.localizedCaseInsensitiveCompare("Bench Press") == .orderedSame
        })
        let benchSet = try #require(bench.prescription.sets.first)
        record(try #require(store.moveExercise(
            named: bench.exerciseName,
            exerciseID: bench.id,
            toBlockNamed: "Main",
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.updateSet(
            exerciseNamed: bench.exerciseName,
            setNumber: 1,
            setID: benchSet.id,
            reps: 10,
            load: nil,
            durationSeconds: nil,
            rpe: nil,
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.setLoggingConfig(
            exerciseNamed: bench.exerciseName,
            exerciseID: bench.id,
            enabled: [.reps, .load, .rpe],
            units: [.load: .pounds],
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.setMetricValue(
            exerciseNamed: bench.exerciseName,
            setNumber: 1,
            setID: benchSet.id,
            metric: .rpe,
            value: 8,
            unit: nil,
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.removeMetric(
            exerciseNamed: bench.exerciseName,
            exerciseID: bench.id,
            metric: .rpe,
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.replaceExercise(
            named: bench.exerciseName,
            exerciseID: bench.id,
            with: "Deadlift",
            replaceAll: false,
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.removeExercise(
            named: "Deadlift",
            exerciseID: bench.id,
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.requireAllOptions(
            choiceNamed: "Conditioning",
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.create(
            title: "Replacement",
            goal: "Fresh intent",
            expectedRevisionToken: token
        ).mutationReceipt))

        let versions = plan.versions()
        #expect(versions.count == receipts.count + 1)
        #expect(versions.dropFirst().map(\.operation.id) == receipts.map(\.mutationID))
        #expect(versions.dropFirst().compactMap(\.workoutMutationReceipt) == receipts)
    }

    @Test func targetedUndoRejectsWhenAnotherWorkoutWasManuallyEditedAfterTheEdit() {
        let harness = makeHarness()
        let (plan, store, scheduled, setID) = harness.boundWorkout()
        let otherWorkout = Workout(
            title: "Conditioning",
            blocks: [WorkoutBlock(name: "Main", isDefault: true)]
        )
        let other = plan.addScheduled(ScheduledWorkout(
            programID: scheduled.programID,
            date: .now,
            origin: .userCreated,
            workoutID: otherWorkout.id,
            workoutRevisionID: UUID(),
            workout: otherWorkout
        ))

        guard case .mutated(let receipt) = store.updateSet(
            exerciseNamed: "Squat",
            setNumber: 1,
            setID: setID,
            reps: 8,
            load: nil,
            durationSeconds: nil,
            rpe: nil,
            expectedRevisionToken: scheduled.workoutRevisionID
        ) else {
            Issue.record("Expected the agent edit to apply")
            return
        }
        plan.updateWorkout(other.id) { $0.rename("Conditioning B") }
        guard let manualRevision = plan.scheduledWorkout(other.id)?.workoutRevisionID,
              manualRevision != other.workoutRevisionID else {
            Issue.record("Expected the manual edit to move the other workout's revision pointer")
            return
        }

        let result = plan.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        )

        #expect(result == .rejected(.staleRevision))
        #expect(plan.scheduledWorkout(scheduled.id)?.workoutRevisionID == receipt.afterRevisionToken)
        #expect(plan.scheduledWorkout(other.id)?.workoutRevisionID == manualRevision)
        #expect(plan.scheduledWorkout(other.id)?.workout.title == "Conditioning B")
    }

    @Test func targetedUndoRejectsAsStaleWhenASessionStartsAfterTheEdit() {
        let harness = makeHarness()
        let (plan, store, scheduled, setID) = harness.boundWorkout()
        guard case .mutated(let receipt) = store.updateSet(
            exerciseNamed: "Squat",
            setNumber: 1,
            setID: setID,
            reps: 8,
            load: nil,
            durationSeconds: nil,
            rpe: nil,
            expectedRevisionToken: scheduled.workoutRevisionID
        ) else {
            Issue.record("Expected the edit to apply")
            return
        }
        _ = plan.start(scheduled.id)

        let result = plan.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        )

        #expect(result == .rejected(.staleRevision))
        #expect(plan.scheduledWorkout(scheduled.id)?.workoutRevisionID == receipt.afterRevisionToken)
        #expect(plan.versions().count == 2)
    }

    @Test func dryRunReturnsDiffWithoutWriting() {
        let harness = makeHarness()
        let (plan, _, scheduled, _) = harness.boundWorkout()
        var proposed = scheduled.workout
        proposed.rename("Preview only")
        let request = harness.request(
            target: .init(
                scope: .plan,
                scheduledWorkoutID: scheduled.id,
                sessionID: nil,
                workoutID: scheduled.workoutID,
                revisionToken: scheduled.workoutRevisionID
            ),
            expectedRevisionToken: scheduled.workoutRevisionID,
            summary: "Rename workout",
            dryRun: true
        )

        guard case .preview(let receipt) = plan.editContent(request, workout: proposed) else {
            Issue.record("Expected a dry-run receipt")
            return
        }

        #expect(receipt.diff == request.diff)
        #expect(receipt.beforeRevisionToken == scheduled.workoutRevisionID)
        #expect(receipt.afterRevisionToken == scheduled.workoutRevisionID)
        #expect(!receipt.undoAvailable)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.title == scheduled.workout.title)
        #expect(plan.versions().isEmpty)
    }

    @Test func sessionWorkoutAndPerformedLogHistorySurviveRepositoryReload() {
        let harness = makeHarness()
        let (plan, store, scheduled, setID) = harness.boundWorkout()
        store.startWorkout()
        guard let started = plan.session(for: scheduled.id),
              let performedToken = started.performedLogRevisionID else {
            Issue.record("Expected a persisted active session")
            return
        }

        guard case .mutated(let sessionReceipt) = store.updateSet(
            exerciseNamed: "Squat",
            setNumber: 1,
            setID: setID,
            reps: 7,
            load: nil,
            durationSeconds: nil,
            rpe: nil,
            expectedRevisionToken: scheduled.workoutRevisionID
        ) else {
            Issue.record("Expected a session-scoped workout mutation")
            return
        }

        var updatedLog = started.log
        updatedLog.upsertSetLog(
            forPlanned: scheduled.workout.allExercises[0].id,
            name: "Squat",
            plannedSetID: setID
        ) { set in
            set.completed = true
            set.values[.reps] = 5
        }
        let logRequest = harness.request(
            target: .init(
                scope: .performedLog,
                scheduledWorkoutID: scheduled.id,
                sessionID: started.id,
                workoutID: scheduled.workoutID,
                revisionToken: performedToken
            ),
            expectedRevisionToken: performedToken,
            summary: "Complete Squat set"
        )
        guard case .applied(let logReceipt) = plan.applyPerformedLogMutation(logRequest, log: updatedLog) else {
            Issue.record("Expected a performed-log mutation")
            return
        }

        #expect(sessionReceipt.scope == .sessionWorkout)
        #expect(sessionReceipt.undoAvailable)
        #expect(logReceipt.scope == .performedLog)
        #expect(!logReceipt.undoAvailable)
        #expect(plan.scheduledWorkout(scheduled.id)?.workoutRevisionID == scheduled.workoutRevisionID)

        let reloadedRepository = SwiftDataPlanRepository(context: ModelContext(harness.container))
        let history = reloadedRepository.sessionMutationVersions(sessionID: started.id, limit: 10)
        guard history.count == 2 else {
            Issue.record("Expected both session mutation versions after reload")
            return
        }
        #expect(history.map(\.mutationID) == [sessionReceipt.mutationID, logReceipt.mutationID])
        #expect(history.map(\.kind) == [.sessionWorkout, .performedLog])
        #expect(history[0].afterRevisionToken == sessionReceipt.afterRevisionToken)
        #expect(history[1].afterRevisionToken == logReceipt.afterRevisionToken)
        #expect(history[0].receipt == sessionReceipt)
        #expect(history[1].receipt == logReceipt)
        if case .sessionWorkout(let before) = history[0].beforeSnapshot {
            #expect(before.allExercises.first?.prescription.sets.first?.reps == 5)
        } else {
            Issue.record("Expected the pre-edit workout snapshot")
        }
        if case .performedLog(let before) = history[1].beforeSnapshot {
            // startLog() seeds a pending performed record per planned exercise, so the pre-edit
            // snapshot holds that record with nothing logged yet - not an absent one.
            let preEdit = before.performed(forPlanned: scheduled.workout.allExercises[0].id)
            #expect(preEdit?.setLogs.isEmpty == true)
            #expect(preEdit?.status == .pending)
        } else {
            Issue.record("Expected the pre-edit performed-log snapshot")
        }
    }
}

@Suite(.serialized) @MainActor
struct WorkoutMetadataToolTests {
    private func tools(for workouts: WorkoutStore) -> AgentTools {
        AgentTools(
            store: TrainingContextStore(
                defaults: UserDefaults(suiteName: "metadata-tools-\(UUID().uuidString)")!
            ),
            base: DecisionEngine.Inputs(),
            workouts: workouts
        )
    }

    @Test func updateWorkoutMetadataReturnsReceiptAndUndoRestoresPriorState() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, _, _) = harness.boundMetadataWorkout()
        let tools = tools(for: workouts)

        let response = tools.dispatch(.updateWorkoutMetadata(
            title: .set("Race prep"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: scheduled.workoutRevisionID
        ))
        let receipt = try #require(response.mutationReceipt)

        #expect(response.text.contains("MUTATION RECEIPT:"))
        #expect(receipt.scope == .plan)
        #expect(receipt.undoAvailable)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.title == "Race prep")

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))

        #expect(undo.mutationReceipt != nil)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.title == "Original workout")
    }

    @Test func updateBlockMetadataTargetsDuplicateNameByIDAndUndoRestoresPriorState() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, blocks, _) = harness.boundMetadataWorkout()
        let tools = tools(for: workouts)
        let targetID = try #require(blocks.last)

        let response = tools.dispatch(.updateBlockMetadata(
            blockID: targetID,
            name: .set("Speed"),
            intent: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: scheduled.workoutRevisionID
        ))
        let receipt = try #require(response.mutationReceipt)
        let edited = try #require(plan.scheduledWorkout(scheduled.id)?.workout)

        #expect(edited.blocks.first?.name == "Main")
        #expect(edited.blocks.last?.name == "Speed")
        #expect(receipt.diff.changes.allSatisfy { $0.entityID == targetID })

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))

        #expect(undo.mutationReceipt != nil)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.map(\.name) == ["Main", "Main"])
    }

    @Test func updateExerciseMetadataTargetsDuplicateNameByIDAndUndoRestoresPriorState() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, _, exercises) = harness.boundMetadataWorkout()
        let tools = tools(for: workouts)
        let firstID = try #require(exercises.first)
        let targetID = try #require(exercises.last)

        let response = tools.dispatch(.updateExerciseMetadata(
            exerciseInstanceID: targetID,
            displayLabel: .set("Finisher run"),
            guidance: .unchanged,
            expectedRevisionToken: scheduled.workoutRevisionID
        ))
        let receipt = try #require(response.mutationReceipt)
        let edited = try #require(plan.scheduledWorkout(scheduled.id)?.workout)

        #expect(edited.exercise(firstID)?.displayLabel == "First run")
        #expect(edited.exercise(targetID)?.displayLabel == "Finisher run")
        #expect(receipt.diff.changes.allSatisfy { $0.entityID == targetID })

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))

        #expect(undo.mutationReceipt != nil)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(targetID)?.displayLabel == "Second run")
    }

    @Test func nullableMetadataSupportsSetClearAndOmitted() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, blocks, exercises) = harness.boundMetadataWorkout()
        let tools = tools(for: workouts)
        let blockID = try #require(blocks.first)
        let exerciseID = try #require(exercises.first)
        var token = scheduled.workoutRevisionID

        let workoutSet = try #require(tools.dispatch(.updateWorkoutMetadata(
            title: .unchanged,
            goal: .set("Set goal"),
            guidance: .unchanged,
            expectedRevisionToken: token
        )).mutationReceipt)
        token = workoutSet.afterRevisionToken
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.guidance?.formCues == ["Original workout guidance"])
        let workoutGuidanceSet = try #require(tools.dispatch(.updateWorkoutMetadata(
            title: .unchanged,
            goal: .unchanged,
            guidance: .set("Set workout guidance"),
            expectedRevisionToken: token
        )).mutationReceipt)
        token = workoutGuidanceSet.afterRevisionToken
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.goal == "Set goal")
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.guidance?.formCues == ["Set workout guidance"])
        let workoutClear = try #require(tools.dispatch(.updateWorkoutMetadata(
            title: .unchanged,
            goal: .clear,
            guidance: .clear,
            expectedRevisionToken: token
        )).mutationReceipt)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.goal == nil)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.guidance == nil)
        let workoutUndo = try #require(tools.dispatch(.undoWorkoutMutation(
            mutationID: workoutClear.mutationID,
            expectedRevisionToken: workoutClear.afterRevisionToken
        )).mutationReceipt)
        token = workoutUndo.afterRevisionToken
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.goal == "Set goal")
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.guidance?.formCues == ["Set workout guidance"])

        let blockIntentSet = try #require(tools.dispatch(.updateBlockMetadata(
            blockID: blockID,
            name: .unchanged,
            intent: .set("Set intent"),
            guidance: .unchanged,
            expectedRevisionToken: token
        )).mutationReceipt)
        token = blockIntentSet.afterRevisionToken
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.first?.guidance?.formCues == ["Original block guidance"])
        let blockGuidanceSet = try #require(tools.dispatch(.updateBlockMetadata(
            blockID: blockID,
            name: .unchanged,
            intent: .unchanged,
            guidance: .set("Set block guidance"),
            expectedRevisionToken: token
        )).mutationReceipt)
        token = blockGuidanceSet.afterRevisionToken
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.first?.intent == "Set intent")
        let blockClear = try #require(tools.dispatch(.updateBlockMetadata(
            blockID: blockID,
            name: .unchanged,
            intent: .clear,
            guidance: .clear,
            expectedRevisionToken: token
        )).mutationReceipt)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.first?.name == "Main")
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.first?.intent == nil)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.first?.guidance == nil)
        let blockUndo = try #require(tools.dispatch(.undoWorkoutMutation(
            mutationID: blockClear.mutationID,
            expectedRevisionToken: blockClear.afterRevisionToken
        )).mutationReceipt)
        token = blockUndo.afterRevisionToken
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.first?.intent == "Set intent")
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.first?.guidance?.formCues == ["Set block guidance"])

        let exerciseLabelSet = try #require(tools.dispatch(.updateExerciseMetadata(
            exerciseInstanceID: exerciseID,
            displayLabel: .set("Set label"),
            guidance: .unchanged,
            expectedRevisionToken: token
        )).mutationReceipt)
        token = exerciseLabelSet.afterRevisionToken
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.guidance?.formCues == ["Original first guidance"])
        let exerciseGuidanceSet = try #require(tools.dispatch(.updateExerciseMetadata(
            exerciseInstanceID: exerciseID,
            displayLabel: .unchanged,
            guidance: .set("Set exercise guidance"),
            expectedRevisionToken: token
        )).mutationReceipt)
        token = exerciseGuidanceSet.afterRevisionToken
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.displayLabel == "Set label")
        let exerciseClear = try #require(tools.dispatch(.updateExerciseMetadata(
            exerciseInstanceID: exerciseID,
            displayLabel: .clear,
            guidance: .clear,
            expectedRevisionToken: token
        )).mutationReceipt)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.displayLabel == nil)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.guidance == nil)
        _ = try #require(tools.dispatch(.undoWorkoutMutation(
            mutationID: exerciseClear.mutationID,
            expectedRevisionToken: exerciseClear.afterRevisionToken
        )).mutationReceipt)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.displayLabel == "Set label")
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.guidance?.formCues == ["Set exercise guidance"])
    }

    @Test func activeSessionMetadataReceiptUndoRestoresOnlySessionWorkout() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, _, _) = harness.boundMetadataWorkout()
        let tools = tools(for: workouts)
        workouts.startWorkout()
        let beforeSession = try #require(plan.session(for: scheduled.id))
        let beforeLog = beforeSession.log
        let sessionToken = try #require(workouts.mutationTarget(.session)?.revisionToken)

        let response = tools.dispatch(.updateWorkoutMetadata(
            title: .set("Session-only title"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: sessionToken
        ))
        let receipt = try #require(response.mutationReceipt)

        #expect(receipt.scope == .sessionWorkout)
        #expect(receipt.undoAvailable)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.title == "Original workout")
        #expect(plan.session(for: scheduled.id)?.workout?.title == "Session-only title")
        #expect(plan.session(for: scheduled.id)?.log == beforeLog)

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))
        let undoReceipt = try #require(undo.mutationReceipt)

        #expect(undoReceipt.scope == .sessionWorkout)
        #expect(undoReceipt.undoAvailable == false)
        #expect(undoReceipt.afterRevisionToken == receipt.beforeRevisionToken)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.title == "Original workout")
        #expect(plan.session(for: scheduled.id)?.workout?.title == "Original workout")
        #expect(plan.session(for: scheduled.id)?.log == beforeLog)
        let history = plan.sessionMutationVersions(sessionID: beforeSession.id)
        #expect(history.count == 2)
        #expect(history.map(\.mutationID) == [receipt.mutationID, undoReceipt.mutationID])
    }

    @Test func transientImportMetadataSupportsTargetedUndoAndRejectsStaleUndo() throws {
        let harness = WorkoutMutationHarness()
        let (_, _, scheduled, _, _) = harness.boundMetadataWorkout()
        let configuration = WorkoutStore(
            units: StubUnitSystem(),
            defaults: UserDefaults(suiteName: "metadata-import-source-\(UUID().uuidString)")!
        )
        let review = WorkoutStore(transientWorkout: scheduled.workout, configurationFrom: configuration)
        let tools = tools(for: review)
        let original = scheduled.workout
        var token = try #require(review.mutationTarget(.plan)?.revisionToken)

        let edit = try #require(tools.dispatch(.updateWorkoutMetadata(
            title: .set("Imported workout"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: token
        )).mutationReceipt)
        #expect(edit.scope == .transient)
        #expect(edit.undoAvailable)
        #expect(review.current?.title == "Imported workout")

        let undo = try #require(tools.dispatch(.undoWorkoutMutation(
            mutationID: edit.mutationID,
            expectedRevisionToken: edit.afterRevisionToken
        )).mutationReceipt)
        #expect(undo.scope == .transient)
        #expect(!undo.undoAvailable)
        #expect(review.current == original)
        token = undo.afterRevisionToken

        let first = try #require(tools.dispatch(.updateWorkoutMetadata(
            title: .set("First title"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: token
        )).mutationReceipt)
        let second = try #require(tools.dispatch(.updateWorkoutMetadata(
            title: .set("Second title"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: first.afterRevisionToken
        )).mutationReceipt)
        let staleUndo = tools.dispatch(.undoWorkoutMutation(
            mutationID: first.mutationID,
            expectedRevisionToken: first.afterRevisionToken
        ))
        #expect(staleUndo.mutationReceipt == nil)
        #expect(review.current?.title == "Second title")

        _ = try #require(tools.dispatch(.undoWorkoutMutation(
            mutationID: second.mutationID,
            expectedRevisionToken: second.afterRevisionToken
        )).mutationReceipt)
        #expect(review.current?.title == "First title")

        let manualPredecessorToken = try #require(review.mutationTarget(.plan)?.revisionToken)
        let beforeManualEdit = try #require(tools.dispatch(.updateWorkoutMetadata(
            title: .set("Agent title before manual edit"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: manualPredecessorToken
        )).mutationReceipt)
        #expect(review.edit(.plan) { workout in
            workout.updateGoal("Manual import-review goal")
        })
        let staleAfterManualEdit = tools.dispatch(.undoWorkoutMutation(
            mutationID: beforeManualEdit.mutationID,
            expectedRevisionToken: beforeManualEdit.afterRevisionToken
        ))
        #expect(staleAfterManualEdit.mutationReceipt == nil)
        #expect(staleAfterManualEdit.text.localizedCaseInsensitiveContains("latest version"))
        #expect(staleAfterManualEdit.text.localizedCaseInsensitiveContains("didn't undo newer work"))
        #expect(review.current?.title == "Agent title before manual edit")
        #expect(review.current?.goal == "Manual import-review goal")
    }

    @Test func discardedSessionRejectsMetadataUndoWithoutWriting() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, _, _) = harness.boundMetadataWorkout()
        let tools = tools(for: workouts)
        workouts.startWorkout()
        let session = try #require(plan.session(for: scheduled.id))
        let token = try #require(workouts.mutationTarget(.session)?.revisionToken)
        let edit = try #require(tools.dispatch(.updateWorkoutMetadata(
            title: .set("Discarded session title"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: token
        )).mutationReceipt)

        workouts.discardLog()
        #expect(plan.session(for: scheduled.id)?.status == .discarded)
        let historyCount = plan.sessionMutationVersions(sessionID: session.id).count
        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: edit.mutationID,
            expectedRevisionToken: edit.afterRevisionToken
        ))

        #expect(undo.mutationReceipt == nil)
        #expect(plan.session(for: scheduled.id)?.status == .discarded)
        #expect(plan.session(for: scheduled.id)?.workout?.title == "Discarded session title")
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.title == "Original workout")
        #expect(plan.sessionMutationVersions(sessionID: session.id).count == historyCount)
    }

    @Test func invalidMetadataTargetsAndStaleTokensNeverWrite() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, _, _) = harness.boundMetadataWorkout()
        let tools = tools(for: workouts)
        let original = scheduled.workout
        let versionCount = plan.versions().count
        let stale = UUID()

        let responses = [
            tools.dispatch(.updateWorkoutMetadata(
                title: .set("Stale title"),
                goal: .unchanged,
                guidance: .unchanged,
                expectedRevisionToken: stale
            )),
            tools.dispatch(.updateBlockMetadata(
                blockID: scheduled.workout.blocks[0].id,
                name: .set("Stale block"),
                intent: .unchanged,
                guidance: .unchanged,
                expectedRevisionToken: stale
            )),
            tools.dispatch(.updateExerciseMetadata(
                exerciseInstanceID: scheduled.workout.allExercises[0].id,
                displayLabel: .set("Stale label"),
                guidance: .unchanged,
                expectedRevisionToken: stale
            )),
            tools.dispatch(.updateBlockMetadata(
                blockID: UUID(),
                name: .set("Missing block"),
                intent: .unchanged,
                guidance: .unchanged,
                expectedRevisionToken: scheduled.workoutRevisionID
            )),
            tools.dispatch(.updateExerciseMetadata(
                exerciseInstanceID: UUID(),
                displayLabel: .set("Missing exercise"),
                guidance: .unchanged,
                expectedRevisionToken: scheduled.workoutRevisionID
            )),
            tools.dispatch(.updateWorkoutMetadata(
                title: .unchanged,
                goal: .unchanged,
                guidance: .unchanged,
                expectedRevisionToken: scheduled.workoutRevisionID
            )),
        ]

        #expect(responses.allSatisfy { $0.mutationReceipt == nil })
        #expect(responses.allSatisfy { ConversationService.shouldRecordActivity(
            .updateWorkoutMetadata(
                title: .set("Representative rejection"),
                goal: .unchanged,
                guidance: .unchanged,
                expectedRevisionToken: stale
            ),
            response: $0
        ) == false })
        #expect(plan.scheduledWorkout(scheduled.id)?.workoutRevisionID == scheduled.workoutRevisionID)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        #expect(plan.versions().count == versionCount)
    }
}

@MainActor
private final class WorkoutMutationHarness {
    let container: ModelContainer
    let plan: PlanStore

    init() {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try! ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))
    }

    func boundWorkout(includeChoice: Bool = false) -> (PlanStore, WorkoutStore, ScheduledWorkout, UUID) {
        let program = plan.addProgram(Program(name: "Test", createdAt: .now))
        var exercise = PlannedExercise(exerciseName: "Squat", definitionId: "back_squat")
        let set = PlannedSet(reps: 5, load: 100)
        exercise.prescription.sets = [set]
        var workout = Workout(
            title: "Strength",
            blocks: [WorkoutBlock(name: "Main", exercises: [exercise], isDefault: true)]
        )
        if includeChoice {
            workout.blocks[0].nodes.append(.choice(WorkoutChoice(label: "Conditioning", options: [
                .exercise(PlannedExercise(exerciseName: "Run", definitionId: "run")),
                .exercise(PlannedExercise(exerciseName: "Row", definitionId: "rowing")),
            ])))
        }
        let scheduled = plan.addScheduled(ScheduledWorkout(
            programID: program.id,
            date: .now,
            origin: .userCreated,
            workoutID: workout.id,
            workoutRevisionID: UUID(),
            workout: workout
        ))
        let defaults = UserDefaults(suiteName: "mutation-envelope-\(UUID().uuidString)")!
        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        return (plan, store, scheduled, set.id)
    }

    func boundMetadataWorkout() -> (PlanStore, WorkoutStore, ScheduledWorkout, [UUID], [UUID]) {
        let program = plan.addProgram(Program(name: "Metadata test", createdAt: .now))
        let firstExercise = PlannedExercise(
            exerciseName: "Run",
            displayLabel: "First run",
            definitionId: "run",
            guidance: CoachGuidance(formCues: ["Original first guidance"])
        )
        let secondExercise = PlannedExercise(
            exerciseName: "Run",
            displayLabel: "Second run",
            definitionId: "run",
            guidance: CoachGuidance(formCues: ["Original second guidance"])
        )
        let firstBlock = WorkoutBlock(
            name: "Main",
            intent: "Original intent",
            exercises: [firstExercise],
            guidance: CoachGuidance(formCues: ["Original block guidance"])
        )
        let secondBlock = WorkoutBlock(
            name: "Main",
            intent: "Original second intent",
            exercises: [secondExercise],
            guidance: CoachGuidance(formCues: ["Original second block guidance"])
        )
        let workout = Workout(
            title: "Original workout",
            goal: "Original goal",
            guidance: CoachGuidance(formCues: ["Original workout guidance"]),
            blocks: [firstBlock, secondBlock]
        )
        let scheduled = plan.addScheduled(ScheduledWorkout(
            programID: program.id,
            date: .now,
            origin: .userCreated,
            workoutID: workout.id,
            workoutRevisionID: UUID(),
            workout: workout
        ))
        let defaults = UserDefaults(suiteName: "mutation-metadata-\(UUID().uuidString)")!
        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        return (
            plan,
            store,
            scheduled,
            [firstBlock.id, secondBlock.id],
            [firstExercise.id, secondExercise.id]
        )
    }

    func request(
        target: WorkoutMutationTarget,
        expectedRevisionToken: UUID,
        summary: String,
        dryRun: Bool = false
    ) -> WorkoutMutationRequest {
        WorkoutMutationRequest(
            mutationID: UUID(),
            target: target,
            expectedRevisionToken: expectedRevisionToken,
            actor: .agent,
            reason: summary,
            diff: .init(changes: [.init(kind: .edit, summary: summary, entityID: nil)]),
            dryRun: dryRun
        )
    }
}

private extension WorkoutStore.EditOutcome {
    var mutationReceipt: WorkoutMutationReceipt? {
        guard case .mutated(let receipt) = self else { return nil }
        return receipt
    }
}
