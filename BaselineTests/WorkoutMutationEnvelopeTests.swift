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
            setID: setID,
            patch: .init(values: .set(.init(metrics: [.reps: .set(8)]))),
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
            setID: setID,
            patch: .init(values: .set(.init(metrics: [.reps: .set(8)]))),
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
            setID: setID,
            patch: .init(values: .set(.init(metrics: [.reps: .set(8)]))),
            expectedRevisionToken: scheduled.workoutRevisionID
        ), case .mutated(let second) = store.updateSet(
            setID: setID,
            patch: .init(values: .set(.init(metrics: [.reps: .set(10)]))),
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
            setID: setID,
            patch: .init(values: .set(.init(metrics: [.reps: .set(8)]))),
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
        let accessory = try #require(plan.scheduledWorkout(scheduled.id)?.workout.blocks.first {
            $0.name == "Accessory"
        })
        record(try #require(store.addExercise(
            name: "Bench Press",
            toContainerID: accessory.id,
            atIndex: nil,
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
            exerciseInstanceID: bench.id,
            toBlockID: mainBlock.id,
            toIndex: 0,
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.updateSet(
            setID: benchSet.id,
            patch: .init(values: .set(.init(metrics: [.reps: .set(10)]))),
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.setLoggingConfig(
            exerciseInstanceID: bench.id,
            enabled: [.reps, .load, .rpe],
            units: [.load: .pounds],
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.setMetricValue(
            exerciseInstanceID: bench.id,
            setID: benchSet.id,
            metric: .rpe,
            value: 8,
            unit: nil,
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.removeMetric(
            exerciseInstanceID: bench.id,
            metric: .rpe,
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.replaceExercise(
            exerciseInstanceID: bench.id,
            with: "Deadlift",
            expectedRevisionToken: token
        ).mutationReceipt))
        record(try #require(store.removeExercise(
            exerciseInstanceID: bench.id,
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
            setID: setID,
            patch: .init(values: .set(.init(metrics: [.reps: .set(8)]))),
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
            setID: setID,
            patch: .init(values: .set(.init(metrics: [.reps: .set(8)]))),
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
            setID: setID,
            patch: .init(values: .set(.init(metrics: [.reps: .set(7)]))),
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
        guard case .applied(let logReceipt) = plan.updateSessionLog(scheduled.id, request: logRequest, log: updatedLog) else {
            Issue.record("Expected a performed-log mutation")
            return
        }

        #expect(sessionReceipt.scope == .sessionWorkout)
        #expect(sessionReceipt.undoAvailable)
        #expect(logReceipt.scope == .performedLog)
        #expect(logReceipt.undoAvailable)
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

        guard case .applied(let undoReceipt) = reloadedRepository.undoSessionMutation(
            mutationID: logReceipt.mutationID,
            expectedRevisionToken: logReceipt.afterRevisionToken,
            actor: .agent
        ) else {
            Issue.record("Expected persisted performed-log undo to restore its before snapshot")
            return
        }
        let restoredSession = reloadedRepository.session(forScheduled: scheduled.id)
        #expect(undoReceipt.scope == .performedLog)
        #expect(!undoReceipt.undoAvailable)
        #expect(restoredSession?.log.setLog(
            forPlanned: scheduled.workout.allExercises[0].id,
            plannedSetID: setID
        ) == nil)
        #expect(reloadedRepository.sessionMutationVersions(sessionID: started.id, limit: 10).count == 3)
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

    @Test func settingGuidanceSupersedesEveryPriorGuidanceField() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, blocks, exercises) = harness.boundMetadataWorkout()
        let tools = tools(for: workouts)
        let blockID = try #require(blocks.first)
        let exerciseID = try #require(exercises.first)
        let rich = CoachGuidance(
            goal: "Old goal note",
            tempo: "3-1-1",
            formCues: ["Old cue"],
            commonMistakes: ["Old mistake"],
            progressionNotes: "Old progression"
        )
        _ = plan.editContent(scheduled.id) { workout in
            workout.updateGuidance(rich)
            _ = workout.setBlockGuidance(blockID, rich)
            _ = workout.updateExercise(exerciseID) { $0.guidance = rich }
        }
        workouts.reloadFromPlan()
        var token = try #require(workouts.mutationTarget(.plan)?.revisionToken)

        let workoutSet = try #require(tools.dispatch(.updateWorkoutMetadata(
            title: .unchanged,
            goal: .unchanged,
            guidance: .set("New workout guidance"),
            expectedRevisionToken: token
        )).mutationReceipt)
        token = workoutSet.afterRevisionToken
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.guidance
                == CoachGuidance(formCues: ["New workout guidance"]))

        let blockSet = try #require(tools.dispatch(.updateBlockMetadata(
            blockID: blockID,
            name: .unchanged,
            intent: .unchanged,
            guidance: .set("New block guidance"),
            expectedRevisionToken: token
        )).mutationReceipt)
        token = blockSet.afterRevisionToken
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.first?.guidance
                == CoachGuidance(formCues: ["New block guidance"]))

        _ = try #require(tools.dispatch(.updateExerciseMetadata(
            exerciseInstanceID: exerciseID,
            displayLabel: .unchanged,
            guidance: .set("New exercise guidance"),
            expectedRevisionToken: token
        )).mutationReceipt)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.guidance
                == CoachGuidance(formCues: ["New exercise guidance"]))
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
        #expect(staleUndo.text.localizedCaseInsensitiveContains("latest version"))
        #expect(staleUndo.text.localizedCaseInsensitiveContains("didn't undo newer work"))
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
        #expect(undo.text.localizedCaseInsensitiveContains("discarded"))
        #expect(!undo.text.localizedCaseInsensitiveContains("latest version"))
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

@Suite(.serialized) @MainActor
struct WorkoutSetToolTests {
    private func tools(for workouts: WorkoutStore) throws -> AgentTools {
        AgentTools(
            store: TrainingContextStore(
                defaults: try #require(UserDefaults(suiteName: "wave-four-tools-\(UUID().uuidString)"))
            ),
            base: DecisionEngine.Inputs(),
            workouts: workouts
        )
    }

    @Test func addSetByExerciseIDReturnsReceiptAndUndoRestoresSnapshot() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, exerciseID, setIDs) = try harness.boundWaveFourWorkout()
        let tools = try tools(for: workouts)

        let response = tools.dispatch(.addSet(
            exerciseInstanceID: exerciseID,
            afterSetID: setIDs[0],
            values: .init(metrics: [.duration: 75, .distance: 500]),
            role: .top,
            targets: .init(
                effort: .rpe(8),
                ranges: [
                    .init(metric: .duration, lower: 70, upper: 80),
                    .init(metric: .heartRate, lower: 140, upper: 160),
                ]
            ),
            expectedRevisionToken: scheduled.workoutRevisionID
        ))
        let receipt = try #require(response.mutationReceipt)
        let addedID = try #require(receipt.diff.changes.first?.entityID)
        let edited = try #require(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID))

        #expect(response.text.contains("MUTATION RECEIPT:"))
        #expect(receipt.undoAvailable)
        #expect(edited.prescription.sets.map(\.id) == [setIDs[0], addedID, setIDs[1], setIDs[2]])
        #expect(edited.prescription.sets[1].role == .top)
        #expect(edited.prescription.sets[1].effortTarget == .rpe(8))
        #expect(edited.selectedMetrics.contains(.heartRate))

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))
        #expect(undo.mutationReceipt != nil)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets.map(\.id) == setIDs)
    }

    @Test func updateSetByIDAppliesExplicitClearsAndIsUndoable() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, exerciseID, setIDs) = try harness.boundWaveFourWorkout()
        let tools = try tools(for: workouts)

        let response = tools.dispatch(.updateSet(
            setID: setIDs[0],
            patch: PlannedSetPatch(
                values: .set(.init(metrics: [.duration: .set(75), .distance: .clear])),
                role: .set(.top),
                targets: .clear
            ),
            expectedRevisionToken: scheduled.workoutRevisionID
        ))
        let receipt = try #require(response.mutationReceipt)
        let edited = try #require(
            plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets.first
        )

        #expect(edited.duration == 75)
        #expect(edited.distance == nil)
        #expect(edited.role == .top)
        #expect(edited.effortTarget == nil)
        #expect(edited.ranges.isEmpty)

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))
        #expect(undo.mutationReceipt != nil)
        let restored = try #require(
            plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets.first
        )
        #expect(restored.distance == 400)
        #expect(restored.role == .warmup)
        #expect(restored.effortTarget == .rpe(6))
        #expect(restored.ranges == [.init(metric: .duration, lower: 50, upper: 70)])
    }

    @Test func moveSetByIDReturnsReceiptAndUndoRestoresOrder() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, exerciseID, setIDs) = try harness.boundWaveFourWorkout()
        let tools = try tools(for: workouts)

        let response = tools.dispatch(.moveSet(
            setID: setIDs[2],
            beforeSetID: setIDs[0],
            toIndex: nil,
            expectedRevisionToken: scheduled.workoutRevisionID
        ))
        let receipt = try #require(response.mutationReceipt)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets.map(\.id)
                == [setIDs[2], setIDs[0], setIDs[1]])

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))
        #expect(undo.mutationReceipt != nil)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets.map(\.id) == setIDs)
    }

    @Test func duplicateSetUsesFreshNestedIDsAndIsUndoable() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, exerciseID, setIDs) = try harness.boundWaveFourWorkout()
        let tools = try tools(for: workouts)

        let response = tools.dispatch(.duplicateSet(
            setID: setIDs[0],
            expectedRevisionToken: scheduled.workoutRevisionID
        ))
        let receipt = try #require(response.mutationReceipt)
        let duplicateID = try #require(receipt.diff.changes.first?.entityID)
        let sets = try #require(
            plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets
        )
        let source = try #require(sets.first { $0.id == setIDs[0] })
        let duplicate = try #require(sets.first { $0.id == duplicateID })

        #expect(duplicate.id != source.id)
        #expect(duplicate.values == source.values)
        #expect(duplicate.alternatives.first?.id != source.alternatives.first?.id)
        #expect(sets.map(\.id).prefix(2).elementsEqual([setIDs[0], duplicateID]))

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))
        #expect(undo.mutationReceipt != nil)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets.map(\.id) == setIDs)
    }

    @Test func liveSessionRemoveSetPurgesLoggedActualAndRemainsUndoable() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, exerciseID, setIDs) = try harness.boundWaveFourWorkout()
        let tools = try tools(for: workouts)
        workouts.startWorkout()
        workouts.editLog { log in
            log.upsertSetLog(
                forPlanned: exerciseID,
                name: "Run",
                plannedSetID: setIDs[0]
            ) { performed in
                performed.values[.distance] = 425
                performed.completed = true
            }
        }
        let token = try #require(workouts.mutationTarget(.session)?.revisionToken)

        let response = tools.dispatch(.removeSet(
            setID: setIDs[0],
            expectedRevisionToken: token
        ))
        let receipt = try #require(response.mutationReceipt)

        #expect(receipt.scope == .sessionWorkout)
        #expect(receipt.undoAvailable)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets.map(\.id) == setIDs)
        #expect(plan.session(for: scheduled.id)?.workout?.exercise(exerciseID)?.prescription.sets.map(\.id)
                == [setIDs[1], setIDs[2]])
        #expect(plan.session(for: scheduled.id)?.log.performed(forPlanned: exerciseID)?.setLogs
            .contains { $0.plannedSetID == setIDs[0] } == false)

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))
        #expect(undo.mutationReceipt != nil)
        #expect(plan.session(for: scheduled.id)?.workout?.exercise(exerciseID)?.prescription.sets.map(\.id) == setIDs)
        // Undo is truthful: the purged logged actual comes back with the planned set it belonged to.
        let restoredLog = plan.session(for: scheduled.id)?.log.performed(forPlanned: exerciseID)?.setLogs
            .first { $0.plannedSetID == setIDs[0] }
        #expect(restoredLog?.values[.distance] == 425)
        #expect(restoredLog?.completed == true)
        #expect(workouts.currentLog?.performed(forPlanned: exerciseID)?.setLogs
            .contains { $0.plannedSetID == setIDs[0] } == true)
    }

    @Test func undoRemoveSetRestoresOnlyThePurgedRowAndKeepsWorkLoggedAfterwards() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, exerciseID, setIDs) = try harness.boundWaveFourWorkout()
        let tools = try tools(for: workouts)
        workouts.startWorkout()
        workouts.editLog { log in
            log.upsertSetLog(forPlanned: exerciseID, name: "Run", plannedSetID: setIDs[0]) { performed in
                performed.values[.distance] = 425
                performed.completed = true
            }
        }
        let token = try #require(workouts.mutationTarget(.session)?.revisionToken)
        let response = tools.dispatch(.removeSet(setID: setIDs[0], expectedRevisionToken: token))
        let receipt = try #require(response.mutationReceipt)

        // The athlete keeps training between the removal and the undo.
        workouts.editLog { log in
            log.upsertSetLog(forPlanned: exerciseID, name: "Run", plannedSetID: setIDs[1]) { performed in
                performed.values[.distance] = 610
                performed.completed = true
            }
            log.upsertSetLog(forPlanned: exerciseID, name: "Run", plannedSetID: setIDs[2]) { performed in
                performed.values[.distance] = 815
            }
        }

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))
        #expect(undo.mutationReceipt != nil)
        #expect(plan.session(for: scheduled.id)?.workout?.exercise(exerciseID)?.prescription.sets.map(\.id) == setIDs)

        // The purged row is back — and everything logged after the removal survives untouched.
        let logs = try #require(
            plan.session(for: scheduled.id)?.log.performed(forPlanned: exerciseID)?.setLogs
        )
        #expect(logs.count == 3)
        #expect(logs.first { $0.plannedSetID == setIDs[0] }?.values[.distance] == 425)
        #expect(logs.first { $0.plannedSetID == setIDs[0] }?.completed == true)
        #expect(logs.first { $0.plannedSetID == setIDs[1] }?.values[.distance] == 610)
        #expect(logs.first { $0.plannedSetID == setIDs[1] }?.completed == true)
        #expect(logs.first { $0.plannedSetID == setIDs[2] }?.values[.distance] == 815)
        #expect(workouts.currentLog?.performed(forPlanned: exerciseID)?.setLogs.count == 3)
    }

    @Test func paceDisplayUnitChangeLeavesCanonicalValuesImmutableAndIsUndoable() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, exerciseID, _) = try harness.boundWaveFourWorkout()
        let tools = try tools(for: workouts)
        let beforeValues = try #require(
            plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets.map(\.values)
        )

        let response = tools.dispatch(.updateLoggingConfig(
            exerciseInstanceID: exerciseID,
            enabledMetrics: nil,
            units: [.pace: .secondsPerMile],
            expectedRevisionToken: scheduled.workoutRevisionID
        ))
        let receipt = try #require(response.mutationReceipt)
        let edited = try #require(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID))

        #expect(edited.displayUnits[.pace] == .secondsPerMile)
        #expect(edited.prescription.sets.map(\.values) == beforeValues)

        let undo = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))
        #expect(undo.mutationReceipt != nil)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.displayUnits[.pace]
                == .secondsPerKilometer)
    }

    @Test func IDBasedMetricSetAndRemoveMutationsReturnReceiptsAndUndo() throws {
        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, exerciseID, setIDs) = try harness.boundWaveFourWorkout()
            let tools = try tools(for: workouts)
            let response = tools.dispatch(.setMetricValue(
                exerciseInstanceID: exerciseID,
                setID: setIDs[0],
                metric: .duration,
                value: 2,
                unit: .minutes,
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let receipt = try #require(response.mutationReceipt)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets[0].duration == 120)
            let undo = tools.dispatch(.undoWorkoutMutation(
                mutationID: receipt.mutationID,
                expectedRevisionToken: receipt.afterRevisionToken
            ))
            #expect(undo.mutationReceipt != nil)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets[0].duration == 60)
        }

        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, exerciseID, _) = try harness.boundWaveFourWorkout()
            let tools = try tools(for: workouts)
            let response = tools.dispatch(.removeMetric(
                exerciseInstanceID: exerciseID,
                metric: .pace,
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let receipt = try #require(response.mutationReceipt)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.selectedMetrics.contains(.pace) == false)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets[0].values[.pace] == nil)
            let undo = tools.dispatch(.undoWorkoutMutation(
                mutationID: receipt.mutationID,
                expectedRevisionToken: receipt.afterRevisionToken
            ))
            #expect(undo.mutationReceipt != nil)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.selectedMetrics.contains(.pace) == true)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseID)?.prescription.sets[0].values[.pace] == 0.25)
        }
    }

    @Test func invalidSetRolesRangesTargetsAndPositionsRejectBeforePersistence() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, exerciseID, setIDs) = try harness.boundWaveFourWorkout()
        let original = scheduled.workout
        let versionCount = plan.versions().count

        let invalidRange = workouts.addSet(
            exerciseInstanceID: exerciseID,
            afterSetID: nil,
            values: .init(metrics: [.duration: 60]),
            role: .working,
            targets: .init(ranges: [.init(metric: .duration, lower: -40, upper: 40)]),
            expectedRevisionToken: scheduled.workoutRevisionID
        )
        let invalidTarget = workouts.updateSet(
            setID: setIDs[0],
            patch: .init(targets: .set(.init(effort: .set(.rpe(11))))),
            expectedRevisionToken: scheduled.workoutRevisionID
        )
        let invalidRoleClear = workouts.updateSet(
            setID: setIDs[0],
            patch: .init(role: .clear),
            expectedRevisionToken: scheduled.workoutRevisionID
        )
        let invalidPosition = workouts.moveSet(
            setID: setIDs[0],
            beforeSetID: nil,
            toIndex: 99,
            expectedRevisionToken: scheduled.workoutRevisionID
        )

        #expect(invalidRange.succeeded == false)
        #expect(invalidTarget.succeeded == false)
        #expect(invalidRoleClear.succeeded == false)
        #expect(invalidPosition.succeeded == false)
        #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        #expect(plan.versions().count == versionCount)
    }
}

@Suite(.serialized) @MainActor
struct WorkoutStructureToolTests {
    private func topLevelExerciseIDs(in block: WorkoutBlock) -> [UUID] {
        block.nodes.compactMap { node in
            guard case .exercise(let exercise) = node else { return nil }
            return exercise.id
        }
    }

    private func recursiveNodeIDs(in nodes: [WorkoutNode]) -> Set<UUID> {
        nodes.reduce(into: Set<UUID>()) { result, node in
            result.insert(node.id)
            switch node {
            case .group(let group):
                result.formUnion(recursiveNodeIDs(in: group.children))
            case .choice(let choice):
                result.formUnion(recursiveNodeIDs(in: choice.options))
            case .exercise, .rest:
                break
            }
        }
    }

    private func nodeFingerprint(_ node: WorkoutNode) -> String {
        switch node {
        case .exercise(let exercise):
            let sets = exercise.prescription.sets.map { set in
                let values = set.values.present.map { metric in
                    "\(metric.rawValue)=\(set.values[metric] ?? 0)"
                }
                return "\(set.role.rawValue):\(values):\(set.alternatives.map(\.label))"
            }
            return "exercise:\(exercise.exerciseName):\(sets)"
        case .group(let group):
            return "group:\(group.label):[\(group.children.map(nodeFingerprint).joined(separator: ","))]"
        case .choice(let choice):
            return "choice:\(choice.label):\(choice.selectionCount):[\(choice.options.map(nodeFingerprint).joined(separator: ","))]"
        case .rest(let rest):
            return "rest:\(rest.label):\(rest.durationSeconds.map(String.init) ?? "nil"):\(rest.placement.rawValue)"
        }
    }

    private func tools(for workouts: WorkoutStore) throws -> AgentTools {
        AgentTools(
            store: TrainingContextStore(
                defaults: try #require(UserDefaults(suiteName: "wave-five-tools-\(UUID().uuidString)"))
            ),
            base: DecisionEngine.Inputs(),
            workouts: workouts
        )
    }

    private func receipt(
        from response: AgentTools.Response,
        scope: WorkoutMutationScope = .plan,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> WorkoutMutationReceipt {
        let receipt = try #require(response.mutationReceipt, sourceLocation: sourceLocation)
        #expect(receipt.scope == scope, sourceLocation: sourceLocation)
        #expect(receipt.actor == .agent, sourceLocation: sourceLocation)
        #expect(receipt.undoAvailable, sourceLocation: sourceLocation)
        return receipt
    }

    private func undo(
        _ receipt: WorkoutMutationReceipt,
        using tools: AgentTools,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let response = tools.dispatch(.undoWorkoutMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ))
        let undoReceipt = try #require(response.mutationReceipt, sourceLocation: sourceLocation)
        #expect(undoReceipt.undoAvailable == false, sourceLocation: sourceLocation)
    }

    @Test func everyBlockStructureMutationReturnsReceiptAndUndoRestoresSnapshot() throws {
        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, _, _) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let original = scheduled.workout
            let response = tools.dispatch(.addBlock(
                name: "Warm-up",
                intent: "prepare",
                guidance: "Move with control",
                atIndex: 1,
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let edit = try receipt(from: response)
            let added = try #require(
                plan.scheduledWorkout(scheduled.id)?.workout.blocks.first { $0.name == "Warm-up" }
            )
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.map(\.name)
                    == ["Main", "Warm-up", "Accessory"])
            #expect(added.intent == "prepare")
            #expect(added.guidance?.formCues == ["Move with control"])
            try undo(edit, using: tools)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        }

        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, blockIDs, _) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let original = scheduled.workout
            let response = tools.dispatch(.moveBlock(
                blockID: blockIDs[1],
                toIndex: 0,
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let edit = try receipt(from: response)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.map(\.id)
                    == [blockIDs[1], blockIDs[0]])
            try undo(edit, using: tools)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        }

        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, blockIDs, _) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let original = scheduled.workout
            let source = try #require(original.blocks.first { $0.id == blockIDs[0] })
            let response = tools.dispatch(.duplicateBlock(
                blockID: blockIDs[0],
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let edit = try receipt(from: response)
            let duplicateID = try #require(edit.diff.changes.first?.entityID)
            let duplicate = try #require(
                plan.scheduledWorkout(scheduled.id)?.workout.blocks.first { $0.id == duplicateID }
            )
            #expect(duplicate.id != source.id)
            #expect(duplicate.nodes.map(nodeFingerprint) == source.nodes.map(nodeFingerprint))
            #expect(recursiveNodeIDs(in: duplicate.nodes).count == recursiveNodeIDs(in: source.nodes).count)
            #expect(duplicate.exercises.count == source.exercises.count)
            #expect(duplicate.exercises.flatMap(\.prescription.sets).count
                    == source.exercises.flatMap(\.prescription.sets).count)
            #expect(duplicate.exercises.flatMap(\.prescription.sets).flatMap(\.alternatives).count
                    == source.exercises.flatMap(\.prescription.sets).flatMap(\.alternatives).count)
            #expect(recursiveNodeIDs(in: duplicate.nodes).isDisjoint(
                with: recursiveNodeIDs(in: source.nodes)
            ))
            #expect(Set(duplicate.exercises.map(\.id)).isDisjoint(with: Set(source.exercises.map(\.id))))
            #expect(Set(duplicate.exercises.flatMap(\.prescription.sets).map(\.id)).isDisjoint(
                with: Set(source.exercises.flatMap(\.prescription.sets).map(\.id))
            ))
            #expect(Set(duplicate.exercises.flatMap(\.prescription.sets).flatMap(\.alternatives).map(\.id))
                .isDisjoint(with: Set(
                    source.exercises.flatMap(\.prescription.sets).flatMap(\.alternatives).map(\.id)
                )))
            try undo(edit, using: tools)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        }

        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, blockIDs, _) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let original = scheduled.workout
            let response = tools.dispatch(.removeBlock(
                blockID: blockIDs[0],
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let edit = try receipt(from: response)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.blocks.map(\.id) == [blockIDs[1]])
            try undo(edit, using: tools)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        }
    }

    @Test func everyExerciseStructureMutationTargetsIDsAndIsUndoable() throws {
        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, blockIDs, exerciseIDs) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let original = scheduled.workout
            let response = tools.dispatch(.addExercise(
                containerID: blockIDs[0],
                name: "Row",
                atIndex: 1,
                sets: 2,
                reps: nil,
                load: nil,
                durationSeconds: 45,
                distanceMeters: nil,
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let edit = try receipt(from: response)
            let edited = try #require(plan.scheduledWorkout(scheduled.id)?.workout)
            #expect(edited.blocks[0].exercises.map(\.id)[0] == exerciseIDs[0])
            #expect(edited.blocks[0].exercises[1].exerciseName == "Row")
            #expect(edited.blocks[0].exercises.map(\.id)[2] == exerciseIDs[1])
            #expect(edited.blocks[0].exercises[1].prescription.sets.count == 2)
            try undo(edit, using: tools)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        }

        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, blockIDs, exerciseIDs) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let original = scheduled.workout
            let response = tools.dispatch(.moveExercise(
                exerciseInstanceID: exerciseIDs[1],
                toBlockID: blockIDs[1],
                toIndex: 0,
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let edit = try receipt(from: response)
            let edited = try #require(plan.scheduledWorkout(scheduled.id)?.workout)
            #expect(topLevelExerciseIDs(in: edited.blocks[0]) == [exerciseIDs[0]])
            #expect(topLevelExerciseIDs(in: edited.blocks[1]) == [exerciseIDs[1], exerciseIDs[2]])
            try undo(edit, using: tools)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        }

        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, _, exerciseIDs) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let original = scheduled.workout
            let response = tools.dispatch(.reorderExercise(
                exerciseInstanceID: exerciseIDs[1],
                toIndex: 0,
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let edit = try receipt(from: response)
            let edited = try #require(plan.scheduledWorkout(scheduled.id)?.workout)
            #expect(topLevelExerciseIDs(in: edited.blocks[0]) == [exerciseIDs[1], exerciseIDs[0]])
            try undo(edit, using: tools)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        }

        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, _, exerciseIDs) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let original = scheduled.workout
            let source = try #require(original.exercise(exerciseIDs[1]))
            let response = tools.dispatch(.duplicateExercise(
                exerciseInstanceID: exerciseIDs[1],
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let edit = try receipt(from: response)
            let duplicateID = try #require(edit.diff.changes.first?.entityID)
            let duplicate = try #require(plan.scheduledWorkout(scheduled.id)?.workout.exercise(duplicateID))
            #expect(duplicate.id != source.id)
            #expect(Set(duplicate.prescription.sets.map(\.id)).isDisjoint(
                with: Set(source.prescription.sets.map(\.id))
            ))
            #expect(Set(duplicate.prescription.sets.flatMap(\.alternatives).map(\.id)).isDisjoint(
                with: Set(source.prescription.sets.flatMap(\.alternatives).map(\.id))
            ))
            let edited = try #require(plan.scheduledWorkout(scheduled.id)?.workout)
            #expect(topLevelExerciseIDs(in: edited.blocks[0]) == [exerciseIDs[0], exerciseIDs[1], duplicateID])
            try undo(edit, using: tools)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        }

        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, _, exerciseIDs) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let original = scheduled.workout
            let response = tools.dispatch(.replaceExercise(
                exerciseInstanceID: exerciseIDs[1],
                replacement: "Deadlift",
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let edit = try receipt(from: response)
            let edited = try #require(plan.scheduledWorkout(scheduled.id)?.workout)
            #expect(edited.exercise(exerciseIDs[0])?.exerciseName == "Run")
            #expect(edited.exercise(exerciseIDs[1])?.exerciseName == "Deadlift")
            #expect(edited.exercise(exerciseIDs[1])?.id == exerciseIDs[1])
            try undo(edit, using: tools)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        }

        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, _, exerciseIDs) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let original = scheduled.workout
            let response = tools.dispatch(.removeExercise(
                exerciseInstanceID: exerciseIDs[1],
                expectedRevisionToken: scheduled.workoutRevisionID
            ))
            let edit = try receipt(from: response)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseIDs[0]) != nil)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(exerciseIDs[1]) == nil)
            try undo(edit, using: tools)
            #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        }
    }

    @Test func everyInvalidStructureTargetTokenAndPositionRejectsWithoutPersistence() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, blockIDs, exerciseIDs) = try harness.boundWaveFiveWorkout()
        let tools = try tools(for: workouts)
        let original = scheduled.workout
        let versionCount = plan.versions().count
        let missingID = UUID()
        let staleToken = UUID()
        let validToken = scheduled.workoutRevisionID
        let rejectedCalls: [AgentTools.Call] = [
            .addBlock(name: "Invalid", intent: nil, guidance: nil, atIndex: 99, expectedRevisionToken: validToken),
            .addBlock(name: "Stale", intent: nil, guidance: nil, atIndex: nil, expectedRevisionToken: staleToken),
            .removeBlock(blockID: missingID, expectedRevisionToken: validToken),
            .removeBlock(blockID: blockIDs[0], expectedRevisionToken: staleToken),
            .moveBlock(blockID: missingID, toIndex: 0, expectedRevisionToken: validToken),
            .moveBlock(blockID: blockIDs[0], toIndex: 2, expectedRevisionToken: validToken),
            .moveBlock(blockID: blockIDs[0], toIndex: 1, expectedRevisionToken: staleToken),
            .duplicateBlock(blockID: missingID, expectedRevisionToken: validToken),
            .duplicateBlock(blockID: blockIDs[0], expectedRevisionToken: staleToken),
            .addExercise(containerID: missingID, name: "Row", atIndex: nil, sets: nil, reps: nil, load: nil,
                         durationSeconds: nil, distanceMeters: nil, expectedRevisionToken: validToken),
            .addExercise(containerID: blockIDs[0], name: "Row", atIndex: 99, sets: nil, reps: nil, load: nil,
                         durationSeconds: nil, distanceMeters: nil, expectedRevisionToken: validToken),
            .addExercise(containerID: blockIDs[0], name: "Row", atIndex: nil, sets: nil, reps: nil, load: nil,
                         durationSeconds: nil, distanceMeters: nil, expectedRevisionToken: staleToken),
            .moveExercise(exerciseInstanceID: missingID, toBlockID: blockIDs[1], toIndex: 0,
                          expectedRevisionToken: validToken),
            .moveExercise(exerciseInstanceID: exerciseIDs[0], toBlockID: missingID, toIndex: 0,
                          expectedRevisionToken: validToken),
            .moveExercise(exerciseInstanceID: exerciseIDs[0], toBlockID: blockIDs[1], toIndex: 2,
                          expectedRevisionToken: validToken),
            .moveExercise(exerciseInstanceID: exerciseIDs[0], toBlockID: blockIDs[1], toIndex: 0,
                          expectedRevisionToken: staleToken),
            .removeExercise(exerciseInstanceID: missingID, expectedRevisionToken: validToken),
            .removeExercise(exerciseInstanceID: exerciseIDs[0], expectedRevisionToken: staleToken),
            .reorderExercise(exerciseInstanceID: missingID, toIndex: 0, expectedRevisionToken: validToken),
            .reorderExercise(exerciseInstanceID: exerciseIDs[0], toIndex: 99,
                             expectedRevisionToken: validToken),
            .reorderExercise(exerciseInstanceID: exerciseIDs[0], toIndex: 1,
                             expectedRevisionToken: staleToken),
            .duplicateExercise(exerciseInstanceID: missingID, expectedRevisionToken: validToken),
            .duplicateExercise(exerciseInstanceID: exerciseIDs[0], expectedRevisionToken: staleToken),
            .replaceExercise(exerciseInstanceID: missingID, replacement: "Deadlift",
                             expectedRevisionToken: validToken),
            .replaceExercise(exerciseInstanceID: exerciseIDs[0], replacement: "Deadlift",
                             expectedRevisionToken: staleToken),
        ]

        for call in rejectedCalls {
            #expect(tools.dispatch(call).mutationReceipt == nil)
        }
        #expect(plan.scheduledWorkout(scheduled.id)?.workout == original)
        #expect(plan.versions().count == versionCount)
    }

    @Test func liveSessionExerciseRemovalPurgesAndUndoRestoresEveryLoggedFact() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, _, exerciseIDs) = try harness.boundWaveFiveWorkout()
        let tools = try tools(for: workouts)
        let targetID = exerciseIDs[1]
        let setID = try #require(workouts.current?.exercise(targetID)?.prescription.sets.first?.id)
        workouts.startWorkout()
        workouts.editLog { log in
            log.upsertSetLog(forPlanned: targetID, name: "Run", plannedSetID: setID) { performed in
                performed.values[.duration] = 123
                performed.completed = true
            }
            log.setStatus(.substituted, forPlanned: targetID, name: "Run")
            log.addNote("Felt smooth", forPlanned: targetID, name: "Run")
            log.exerciseAdjustments.append(ExerciseLogAdjustment(
                plannedExerciseID: targetID,
                groupID: nil,
                iteration: nil,
                outcome: .skipped,
                substitution: nil
            ))
        }
        let token = try #require(workouts.mutationTarget(.session)?.revisionToken)
        let response = tools.dispatch(.removeExercise(
            exerciseInstanceID: targetID,
            expectedRevisionToken: token
        ))
        let edit = try receipt(from: response, scope: .sessionWorkout)

        #expect(plan.scheduledWorkout(scheduled.id)?.workout.exercise(targetID) != nil)
        #expect(plan.session(for: scheduled.id)?.workout?.exercise(targetID) == nil)
        #expect(plan.session(for: scheduled.id)?.log.performed(forPlanned: targetID) == nil)
        #expect(plan.session(for: scheduled.id)?.log.exerciseAdjustments.contains {
            $0.plannedExerciseID == targetID
        } == false)

        let survivingID = exerciseIDs[0]
        let survivingSetID = try #require(
            plan.session(for: scheduled.id)?.workout?.exercise(survivingID)?.prescription.sets.first?.id
        )
        workouts.editLog { log in
            log.upsertSetLog(forPlanned: survivingID, name: "Run", plannedSetID: survivingSetID) {
                $0.values[.duration] = 321
                $0.completed = true
            }
            log.addNote("Logged after removal", forPlanned: survivingID, name: "Run")
        }
        let laterSurvivingWork = try #require(
            plan.session(for: scheduled.id)?.log.performed(forPlanned: survivingID)
        )

        try undo(edit, using: tools)
        let restored = try #require(plan.session(for: scheduled.id)?.log.performed(forPlanned: targetID))
        #expect(plan.session(for: scheduled.id)?.workout?.exercise(targetID) != nil)
        #expect(restored.status == .substituted)
        #expect(restored.athleteNotes == ["Felt smooth"])
        #expect(restored.setLogs.first?.plannedSetID == setID)
        #expect(restored.setLogs.first?.values[.duration] == 123)
        #expect(restored.setLogs.first?.completed == true)
        #expect(plan.session(for: scheduled.id)?.log.exerciseAdjustments.contains {
            $0.plannedExerciseID == targetID && $0.outcome == .skipped
        } == true)
        #expect(plan.session(for: scheduled.id)?.log.performed(forPlanned: survivingID) == laterSurvivingWork)
    }

    @Test func liveSessionBlockRemovalPurgesAllOwnedRowsAndUndoRestoresThem() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, blockIDs, exerciseIDs) = try harness.boundWaveFiveWorkout()
        let tools = try tools(for: workouts)
        let removedBlock = try #require(workouts.current?.blocks.first { $0.id == blockIDs[0] })
        let removedIDs = removedBlock.exercises.map(\.id)
        #expect(removedIDs.count > 2)
        let removedSetIDs = try removedIDs.map { exerciseID in
            try #require(workouts.current?.exercise(exerciseID)?.prescription.sets.first?.id)
        }
        workouts.startWorkout()
        workouts.editLog { log in
            for (offset, exerciseID) in removedIDs.enumerated() {
                let setID = removedSetIDs[offset]
                log.upsertSetLog(forPlanned: exerciseID, name: "Run", plannedSetID: setID) { performed in
                    performed.values[.duration] = Double(70 + offset)
                    performed.completed = true
                }
            }
            for group in removedBlock.groups {
                log.updateGroupLog(group.id) {
                    $0.performedDurationSeconds = 240
                    $0.completedIterations = 3
                    $0.isComplete = true
                }
            }
            if let choice = removedBlock.choices.first,
               let lastOptionID = choice.options.last?.id {
                log.selectOption(lastOptionID, for: choice.id, selectionCount: choice.selectionCount)
            }
        }
        let removedGroupLogs = try #require(plan.session(for: scheduled.id)?.log.groups).filter {
            Set(removedBlock.groups.map(\.id)).contains($0.plannedGroupID)
        }
        let removedChoiceLogs = try #require(plan.session(for: scheduled.id)?.log.choices).filter {
            Set(removedBlock.choices.map(\.id)).contains($0.plannedChoiceID)
        }
        let token = try #require(workouts.mutationTarget(.session)?.revisionToken)
        let response = tools.dispatch(.removeBlock(
            blockID: blockIDs[0],
            expectedRevisionToken: token
        ))
        let edit = try receipt(from: response, scope: .sessionWorkout)

        #expect(plan.session(for: scheduled.id)?.workout?.blocks.map(\.id) == [blockIDs[1]])
        for exerciseID in removedIDs {
            #expect(plan.session(for: scheduled.id)?.log.performed(forPlanned: exerciseID) == nil)
        }
        for group in removedBlock.groups {
            #expect(plan.session(for: scheduled.id)?.log.groups.contains {
                $0.plannedGroupID == group.id
            } == false)
        }
        for choice in removedBlock.choices {
            #expect(plan.session(for: scheduled.id)?.log.choices.contains {
                $0.plannedChoiceID == choice.id
            } == false)
        }

        let survivingID = exerciseIDs[2]
        let survivingSetID = try #require(
            plan.session(for: scheduled.id)?.workout?.exercise(survivingID)?.prescription.sets.first?.id
        )
        workouts.editLog { log in
            log.upsertSetLog(forPlanned: survivingID, name: "Row", plannedSetID: survivingSetID) {
                $0.values[.duration] = 999
                $0.completed = true
            }
            log.setStatus(.completed, forPlanned: survivingID, name: "Row")
        }
        let laterSurvivingWork = try #require(
            plan.session(for: scheduled.id)?.log.performed(forPlanned: survivingID)
        )

        try undo(edit, using: tools)
        #expect(plan.session(for: scheduled.id)?.workout?.blocks.map(\.id) == blockIDs)
        for (offset, exerciseID) in removedIDs.enumerated() {
            let restored = try #require(
                plan.session(for: scheduled.id)?.log.performed(forPlanned: exerciseID)?.setLogs.first
            )
            #expect(restored.values[.duration] == Double(70 + offset))
            #expect(restored.completed == true)
        }
        for group in removedGroupLogs {
            #expect(plan.session(for: scheduled.id)?.log.groups.first {
                $0.plannedGroupID == group.plannedGroupID
            } == group)
        }
        for choice in removedChoiceLogs {
            #expect(plan.session(for: scheduled.id)?.log.choices.first {
                $0.plannedChoiceID == choice.plannedChoiceID
            } == choice)
        }
        #expect(plan.session(for: scheduled.id)?.log.performed(forPlanned: survivingID) == laterSurvivingWork)
    }

    @Test func liveSessionChoiceExerciseRemovalPurgesAndRestoresItsSelection() throws {
        let harness = WorkoutMutationHarness()
        let (plan, workouts, scheduled, blockIDs, _) = try harness.boundWaveFiveWorkout()
        let tools = try tools(for: workouts)
        let block = try #require(workouts.current?.blocks.first { $0.id == blockIDs[0] })
        let choice = try #require(block.choices.first)
        guard case .exercise(let selectedExercise) = try #require(choice.options.first) else {
            Issue.record("The fixture's selected choice option must be an exercise.")
            return
        }
        workouts.startWorkout()
        let originalChoiceLog = try #require(
            plan.session(for: scheduled.id)?.log.choices.first { $0.plannedChoiceID == choice.id }
        )
        #expect(originalChoiceLog.selectedOptionIDs.contains(selectedExercise.id))

        let token = try #require(workouts.mutationTarget(.session)?.revisionToken)
        let response = tools.dispatch(.removeExercise(
            exerciseInstanceID: selectedExercise.id,
            expectedRevisionToken: token
        ))
        let edit = try receipt(from: response, scope: .sessionWorkout)
        let purgedChoiceLog = try #require(
            plan.session(for: scheduled.id)?.log.choices.first { $0.plannedChoiceID == choice.id }
        )
        #expect(purgedChoiceLog.selectedOptionIDs.contains(selectedExercise.id) == false)
        #expect(plan.session(for: scheduled.id)?.log.performed(forPlanned: selectedExercise.id) == nil)

        try undo(edit, using: tools)
        #expect(plan.session(for: scheduled.id)?.log.choices.first {
            $0.plannedChoiceID == choice.id
        } == originalChoiceLog)
        #expect(plan.session(for: scheduled.id)?.log.performed(forPlanned: selectedExercise.id) != nil)
    }

    @Test func choiceSelectionLoggedAfterRemovalOrMoveWinsOverUndo() throws {
        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, blockIDs, _) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let block = try #require(workouts.current?.blocks.first { $0.id == blockIDs[0] })
            let choice = try #require(block.choices.first)
            guard case .exercise(let selectedExercise) = try #require(choice.options.first) else {
                Issue.record("The fixture's selected choice option must be an exercise.")
                return
            }
            let laterOptionID = try #require(choice.options.last?.id)
            workouts.startWorkout()
            let token = try #require(workouts.mutationTarget(.session)?.revisionToken)
            let edit = try receipt(from: tools.dispatch(.removeExercise(
                exerciseInstanceID: selectedExercise.id,
                expectedRevisionToken: token
            )), scope: .sessionWorkout)
            workouts.editLog { log in
                log.selectOption(laterOptionID, for: choice.id, selectionCount: choice.selectionCount)
            }
            let laterChoice = try #require(
                plan.session(for: scheduled.id)?.log.choices.first { $0.plannedChoiceID == choice.id }
            )

            try undo(edit, using: tools)
            #expect(plan.session(for: scheduled.id)?.log.choices.first {
                $0.plannedChoiceID == choice.id
            } == laterChoice)
        }

        do {
            let harness = WorkoutMutationHarness()
            let (plan, workouts, scheduled, blockIDs, _) = try harness.boundWaveFiveWorkout()
            let tools = try tools(for: workouts)
            let block = try #require(workouts.current?.blocks.first { $0.id == blockIDs[0] })
            let choice = try #require(block.choices.first)
            guard case .exercise(let selectedExercise) = try #require(choice.options.first) else {
                Issue.record("The fixture's selected choice option must be an exercise.")
                return
            }
            let laterOptionID = try #require(choice.options.last?.id)
            workouts.startWorkout()
            let token = try #require(workouts.mutationTarget(.session)?.revisionToken)
            let edit = try receipt(from: tools.dispatch(.moveExercise(
                exerciseInstanceID: selectedExercise.id,
                toBlockID: blockIDs[1],
                toIndex: 1,
                expectedRevisionToken: token
            )), scope: .sessionWorkout)
            workouts.editLog { log in
                log.selectOption(laterOptionID, for: choice.id, selectionCount: choice.selectionCount)
            }
            let laterChoice = try #require(
                plan.session(for: scheduled.id)?.log.choices.first { $0.plannedChoiceID == choice.id }
            )

            try undo(edit, using: tools)
            #expect(plan.session(for: scheduled.id)?.log.choices.first {
                $0.plannedChoiceID == choice.id
            } == laterChoice)
        }
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

    func boundWaveFourWorkout() throws -> (PlanStore, WorkoutStore, ScheduledWorkout, UUID, [UUID]) {
        let program = plan.addProgram(Program(name: "Wave 4", createdAt: .now))
        let firstSet = PlannedSet(
            values: MetricValues([.duration: 60, .distance: 400, .pace: 0.25]),
            role: .warmup,
            effortTarget: .rpe(6),
            ranges: [.init(metric: .duration, lower: 50, upper: 70)],
            alternatives: [.init(label: "Short", values: MetricValues([.distance: 200]))]
        )
        let secondSet = PlannedSet(duration: 90, distance: 600, role: .working)
        let thirdSet = PlannedSet(duration: 120, distance: 800, role: .working)
        let exercise = PlannedExercise(
            exerciseName: "Run",
            definitionId: "run",
            selectedMetrics: [.duration, .distance, .pace, .heartRateZoneTime],
            displayUnits: [.pace: .secondsPerKilometer],
            prescription: Prescription(sets: [firstSet, secondSet, thirdSet])
        )
        let workout = Workout(
            title: "Intervals",
            blocks: [WorkoutBlock(name: "Main", exercises: [exercise], isDefault: true)]
        )
        let scheduled = plan.addScheduled(ScheduledWorkout(
            programID: program.id,
            date: .now,
            origin: .userCreated,
            workoutID: workout.id,
            workoutRevisionID: UUID(),
            workout: workout
        ))
        let defaults = try #require(UserDefaults(suiteName: "mutation-wave-four-\(UUID().uuidString)"))
        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        return (plan, store, scheduled, exercise.id, [firstSet.id, secondSet.id, thirdSet.id])
    }

    func boundWaveFiveWorkout() throws -> (
        PlanStore,
        WorkoutStore,
        ScheduledWorkout,
        [UUID],
        [UUID]
    ) {
        let program = plan.addProgram(Program(name: "Wave 5", createdAt: .now))
        let firstSet = PlannedSet(
            duration: 60,
            alternatives: [.init(label: "Short", values: MetricValues([.duration: 30]))]
        )
        let secondSet = PlannedSet(
            duration: 120,
            alternatives: [.init(label: "Long", values: MetricValues([.duration: 180]))]
        )
        let firstRun = PlannedExercise(
            exerciseName: "Run",
            definitionId: "run",
            selectedMetrics: [.duration],
            prescription: Prescription(sets: [firstSet])
        )
        let secondRun = PlannedExercise(
            exerciseName: "Run",
            definitionId: "run",
            selectedMetrics: [.duration],
            prescription: Prescription(sets: [secondSet])
        )
        let row = PlannedExercise(
            exerciseName: "Row",
            definitionId: "rowing",
            selectedMetrics: [.duration],
            prescription: Prescription(sets: [PlannedSet(duration: 90)])
        )
        let groupedRun = PlannedExercise(
            exerciseName: "Grouped Run",
            definitionId: "run",
            selectedMetrics: [.duration],
            prescription: Prescription(sets: [
                PlannedSet(
                    duration: 45,
                    alternatives: [.init(label: "Short", values: MetricValues([.duration: 20]))]
                ),
            ])
        )
        let choiceRun = PlannedExercise(
            exerciseName: "Choice Run",
            definitionId: "run",
            selectedMetrics: [.duration],
            prescription: Prescription(sets: [PlannedSet(duration: 30)])
        )
        let nestedRun = PlannedExercise(
            exerciseName: "Nested Run",
            definitionId: "run",
            selectedMetrics: [.duration],
            prescription: Prescription(sets: [PlannedSet(duration: 20)])
        )
        let group = WorkoutGroup(
            label: "Circuit",
            children: [
                .exercise(groupedRun),
                .rest(PlannedRest(durationSeconds: 30)),
            ]
        )
        let nestedGroup = WorkoutGroup(label: "Nested", children: [.exercise(nestedRun)])
        let choice = WorkoutChoice(
            label: "Choose one",
            options: [.exercise(choiceRun), .group(nestedGroup)]
        )
        let main = WorkoutBlock(
            name: "Main",
            nodes: [
                .exercise(firstRun),
                .exercise(secondRun),
                .group(group),
                .choice(choice),
                .rest(PlannedRest(durationSeconds: 60)),
            ]
        )
        let accessory = WorkoutBlock(name: "Accessory", exercises: [row])
        let workout = Workout(title: "Structure", blocks: [main, accessory])
        let scheduled = plan.addScheduled(ScheduledWorkout(
            programID: program.id,
            date: .now,
            origin: .userCreated,
            workoutID: workout.id,
            workoutRevisionID: UUID(),
            workout: workout
        ))
        let defaults = try #require(UserDefaults(suiteName: "mutation-wave-five-\(UUID().uuidString)"))
        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        return (
            plan,
            store,
            scheduled,
            [main.id, accessory.id],
            [firstRun.id, secondRun.id, row.id]
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
