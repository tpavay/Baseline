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
        #expect(!sessionReceipt.undoAvailable)
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
            #expect(before.performed(forPlanned: scheduled.workout.allExercises[0].id) == nil)
        } else {
            Issue.record("Expected the pre-edit performed-log snapshot")
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
