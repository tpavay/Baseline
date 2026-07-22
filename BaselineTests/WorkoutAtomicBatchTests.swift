import Foundation
import SwiftData
import Testing
@testable import Baseline

/// Wave 7: `apply_workout_edits` composes the primitive operations into ONE envelope commit, and the
/// bulk selector tools (`convert_workout_units`, `bulk_replace_exercises`) mutate every matched
/// instance atomically behind an enumerated, non-silent match set.
@Suite(.serialized) @MainActor
struct WorkoutAtomicBatchTests {

    // MARK: - Harness

    /// One plan-bound workout with enough taxonomy variety to exercise selectors:
    /// Strength block (back squat), Conditioning block (two outdoor runs — duplicates by design —
    /// a treadmill run, a rower, and one unclassified "Mystery Run" without catalog identity).
    @MainActor
    private struct Fixture {
        let plan: PlanStore
        let store: WorkoutStore
        let scheduled: ScheduledWorkout
        let strengthBlockID: UUID
        let conditioningBlockID: UUID
        let squatID: UUID
        let squatSetID: UUID
        let runIDs: [UUID]
        let treadmillID: UUID
        let rowID: UUID
        let mysteryID: UUID

        var revision: UUID { plan.scheduledWorkout(scheduled.id)!.workoutRevisionID }
        var workout: Workout { plan.scheduledWorkout(scheduled.id)!.workout }
    }

    private func makeFixture() -> Fixture {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try! ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))
        let program = plan.addProgram(Program(name: "Wave 7", createdAt: .now))

        var squat = PlannedExercise(exerciseName: "Barbell Back Squat", definitionId: "back_squat")
        squat.selectedMetrics = [.reps, .load]
        let squatSet = PlannedSet(reps: 5, load: 100)
        squat.prescription.sets = [squatSet]

        func cardio(_ name: String, _ definitionId: String?, distance: Double) -> PlannedExercise {
            var exercise = PlannedExercise(exerciseName: name, definitionId: definitionId)
            exercise.selectedMetrics = [.duration, .distance]
            exercise.prescription.sets = [PlannedSet(values: MetricValues([.distance: distance]))]
            return exercise
        }
        let runA = cardio("Run", "run", distance: 400)
        let runB = cardio("Run", "run", distance: 800)
        let treadmill = cardio("Treadmill Run", "treadmill_run", distance: 1_000)
        let row = cardio("Row", "row", distance: 500)
        let mystery = cardio("Mystery Run", nil, distance: 250)

        let strength = WorkoutBlock(name: "Strength", exercises: [squat])
        let conditioning = WorkoutBlock(name: "Conditioning", exercises: [runA, runB, treadmill, row, mystery])
        let workout = Workout(title: "Mixed Day", blocks: [strength, conditioning])
        let scheduled = plan.addScheduled(ScheduledWorkout(
            programID: program.id,
            date: .now,
            origin: .userCreated,
            workoutID: workout.id,
            workoutRevisionID: UUID(),
            workout: workout
        ))
        let defaults = UserDefaults(suiteName: "atomic-batch-\(UUID().uuidString)")!
        let store = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        store.bind(plan.sink(forScheduled: scheduled.id), coalesceContent: false)
        return Fixture(
            plan: plan,
            store: store,
            scheduled: scheduled,
            strengthBlockID: strength.id,
            conditioningBlockID: conditioning.id,
            squatID: squat.id,
            squatSetID: squatSet.id,
            runIDs: [runA.id, runB.id],
            treadmillID: treadmill.id,
            rowID: row.id,
            mysteryID: mystery.id
        )
    }

    // MARK: - apply_workout_edits

    @Test func mixedBatchCommitsAtomicallyWithOneReceiptAndOneUndo() throws {
        let fixture = makeFixture()
        let before = fixture.revision

        guard case .mutated(let receipt) = fixture.store.applyWorkoutEdits(
            operations: [
                .updateWorkoutMetadata(title: .set("Upper Body Day"), goal: .unchanged, guidance: .unchanged),
                .updateBlockMetadata(
                    blockID: fixture.strengthBlockID,
                    name: .set("Upper Body"),
                    intent: .unchanged,
                    guidance: .unchanged
                ),
                .setMetricValue(
                    exerciseInstanceID: fixture.squatID,
                    setID: fixture.squatSetID,
                    metric: .load,
                    value: 120,
                    unit: .kilograms
                ),
            ],
            expectedRevisionToken: before
        ) else {
            Issue.record("Expected the batch to apply")
            return
        }

        // One commit: one receipt, one new plan version, every operation's change in one diff.
        let updated = fixture.workout
        #expect(updated.title == "Upper Body Day")
        #expect(updated.blocks.first?.name == "Upper Body")
        #expect(updated.exercise(fixture.squatID)?.prescription.sets.first?.load == 120)
        #expect(receipt.beforeRevisionToken == before)
        #expect(receipt.diff.changes.count == 3)
        #expect(receipt.undoAvailable)
        // The whole batch is exactly one agent plan version — not one per operation.
        let agentVersions = fixture.plan.versions().filter { $0.actor == .agent }
        #expect(agentVersions.count == 1)
        #expect(agentVersions.last?.workoutMutationReceipt == receipt)

        // One undo reverts the entire intent.
        guard case .mutated = fixture.store.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ) else {
            Issue.record("Expected the composite undo to apply")
            return
        }
        let restored = fixture.workout
        #expect(restored.title == "Mixed Day")
        #expect(restored.blocks.first?.name == "Strength")
        #expect(restored.exercise(fixture.squatID)?.prescription.sets.first?.load == 100)
        #expect(fixture.revision == before)
    }

    @Test func invalidOperationRejectsWholeBatchWithPreciseError() throws {
        let fixture = makeFixture()
        let before = fixture.revision
        let versionsBefore = fixture.plan.versions().count

        let outcome = fixture.store.applyWorkoutEdits(
            operations: [
                .updateBlockMetadata(
                    blockID: fixture.strengthBlockID,
                    name: .set("Upper Body"),
                    intent: .unchanged,
                    guidance: .unchanged
                ),
                .removeSet(setID: UUID()),   // no such set — the whole batch must reject
            ],
            expectedRevisionToken: before
        )

        guard case .notFound(let message) = outcome else {
            Issue.record("Expected the batch to reject")
            return
        }
        #expect(message.contains("Operation 2 of 2 (remove_set) failed:"))
        #expect(message.contains("nothing was changed"))
        // Nothing committed: the earlier valid rename did not survive.
        #expect(fixture.workout.blocks.first?.name == "Strength")
        #expect(fixture.revision == before)
        #expect(fixture.plan.versions().count == versionsBefore)
    }

    @Test func staticallyInvalidOperationIsNamedBeforeAnySnapshotWork() throws {
        let fixture = makeFixture()
        let outcome = fixture.store.applyWorkoutEdits(
            operations: [.updateSet(setID: fixture.squatSetID, patch: PlannedSetPatch())],
            expectedRevisionToken: fixture.revision
        )
        guard case .notFound(let message) = outcome else {
            Issue.record("Expected the empty patch to reject")
            return
        }
        #expect(message.contains("Operation 1 of 1 (update_set) failed:"))
        #expect(message.contains("Include at least one planned-set field to change."))
    }

    @Test func staleRevisionTokenRejectsBatchTruthfully() throws {
        let fixture = makeFixture()
        let before = fixture.revision
        let outcome = fixture.store.applyWorkoutEdits(
            operations: [
                .updateWorkoutMetadata(title: .set("New Title"), goal: .unchanged, guidance: .unchanged),
            ],
            expectedRevisionToken: UUID()
        )
        guard case .notFound(let message) = outcome else {
            Issue.record("Expected the stale batch to reject")
            return
        }
        #expect(message.contains("changed after I read it"))
        #expect(fixture.workout.title == "Mixed Day")
        #expect(fixture.revision == before)
    }

    @Test func laterOperationsSeeEarlierOperationsEffects() throws {
        let fixture = makeFixture()
        guard case .mutated(let receipt) = fixture.store.applyWorkoutEdits(
            operations: [
                .addSet(
                    exerciseInstanceID: fixture.squatID,
                    afterSetID: nil,
                    values: PlannedSetValues(metrics: [.reps: 8, .load: 80]),
                    role: .backoff,
                    targets: PlannedSetTargets()
                ),
                .removeSet(setID: fixture.squatSetID),   // removes the original, keeps the new one
            ],
            expectedRevisionToken: fixture.revision
        ) else {
            Issue.record("Expected the ordered batch to apply")
            return
        }
        let sets = fixture.workout.exercise(fixture.squatID)?.prescription.sets
        #expect(sets?.count == 1)
        #expect(sets?.first?.reps == 8)
        #expect(sets?.first?.role == .backoff)
        // The add operation's change carries the resolved fresh set ID, not a placeholder.
        let addChange = receipt.diff.changes.first { $0.summary == "Add planned set" }
        #expect(addChange?.entityID == sets?.first?.id)
    }

    @Test func batchRejectsOversizeAndEmptyOperationLists() throws {
        let fixture = makeFixture()
        guard case .notFound(let emptyMessage) = fixture.store.applyWorkoutEdits(
            operations: [],
            expectedRevisionToken: fixture.revision
        ) else {
            Issue.record("Expected the empty batch to reject")
            return
        }
        #expect(emptyMessage.contains("at least one operation"))

        let oversize = Array(
            repeating: WorkoutEditOperation.duplicateSet(setID: fixture.squatSetID),
            count: WorkoutStore.maxBatchOperations + 1
        )
        guard case .notFound(let oversizeMessage) = fixture.store.applyWorkoutEdits(
            operations: oversize,
            expectedRevisionToken: fixture.revision
        ) else {
            Issue.record("Expected the oversize batch to reject")
            return
        }
        #expect(oversizeMessage.contains("at most \(WorkoutStore.maxBatchOperations)"))
    }

    // MARK: - convert_workout_units

    @Test func convertUpdatesEveryMatchedInstanceIncludingDuplicatesAndKeepsCanonicalValues() throws {
        let fixture = makeFixture()
        let before = fixture.revision

        let result = fixture.store.convertWorkoutUnits(
            units: [.distance: .kilometers],
            selector: nil,
            dryRun: false,
            expectedRevisionToken: before
        )
        guard case .applied(let receipt, let detail) = result else {
            Issue.record("Expected the unit conversion to apply: \(result)")
            return
        }

        let updated = fixture.workout
        // Every distance-logging instance converts — both duplicate runs included, plus the
        // unclassified one (no selector means the whole workout, structurally).
        for id in fixture.runIDs + [fixture.treadmillID, fixture.rowID, fixture.mysteryID] {
            #expect(updated.exercise(id)?.displayUnits[.distance] == .kilometers, "\(id)")
        }
        // The squat logs no distance, so it carries no override.
        #expect(updated.exercise(fixture.squatID)?.displayUnits[.distance] == nil)
        // Display only: every canonical stored value is untouched.
        #expect(updated.exercise(fixture.runIDs[0])?.prescription.sets.first?.values[.distance] == 400)
        #expect(updated.exercise(fixture.runIDs[1])?.prescription.sets.first?.values[.distance] == 800)
        #expect(updated.exercise(fixture.treadmillID)?.prescription.sets.first?.values[.distance] == 1_000)
        #expect(receipt.diff.changes.count == 5)
        #expect(detail.contains("distance → km"))
        #expect(detail.contains(fixture.runIDs[0].uuidString))
        #expect(detail.contains(fixture.runIDs[1].uuidString))

        // One undo reverts the whole bulk intent.
        guard case .mutated = fixture.store.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ) else {
            Issue.record("Expected the bulk-unit undo to apply")
            return
        }
        #expect(fixture.workout.exercise(fixture.runIDs[0])?.displayUnits[.distance] == nil)
        #expect(fixture.revision == before)
    }

    @Test func convertSelectorNarrowsAndDryRunWritesNothing() throws {
        let fixture = makeFixture()
        let before = fixture.revision

        // Dry run with an explicit taxonomy selector: enumerates the exact matched set, writes nothing.
        let preview = fixture.store.convertWorkoutUnits(
            units: [.distance: .miles],
            selector: BulkExerciseSelectorInput(pattern: "gait"),
            dryRun: true,
            expectedRevisionToken: before
        )
        guard case .preview(let detail) = preview else {
            Issue.record("Expected a dry-run preview: \(preview)")
            return
        }
        #expect(detail.contains("DRY RUN"))
        #expect(detail.contains(fixture.runIDs[0].uuidString))
        #expect(detail.contains(fixture.runIDs[1].uuidString))
        #expect(detail.contains(fixture.treadmillID.uuidString))
        // Rowing is cardio but not gait — it must not match a "runs" selector.
        #expect(!detail.contains(fixture.rowID.uuidString))
        // The unclassified instance is surfaced, never silently skipped.
        #expect(detail.contains("Mystery Run"))
        #expect(detail.contains("no catalog identity"))
        #expect(fixture.revision == before)
        #expect(fixture.workout.exercise(fixture.runIDs[0])?.displayUnits[.distance] == nil)

        // Applying the same selector touches exactly the enumerated set.
        guard case .applied(let receipt, _) = fixture.store.convertWorkoutUnits(
            units: [.distance: .miles],
            selector: BulkExerciseSelectorInput(pattern: "gait"),
            dryRun: false,
            expectedRevisionToken: before
        ) else {
            Issue.record("Expected the selector conversion to apply")
            return
        }
        #expect(receipt.diff.changes.count == 3)
        let updated = fixture.workout
        #expect(updated.exercise(fixture.runIDs[0])?.displayUnits[.distance] == .miles)
        #expect(updated.exercise(fixture.treadmillID)?.displayUnits[.distance] == .miles)
        #expect(updated.exercise(fixture.rowID)?.displayUnits[.distance] == nil)
        #expect(updated.exercise(fixture.mysteryID)?.displayUnits[.distance] == nil)
    }

    @Test func convertRejectsUnknownTaxonomyValuesCorrectably() throws {
        let fixture = makeFixture()
        let result = fixture.store.convertWorkoutUnits(
            units: [.distance: .kilometers],
            selector: BulkExerciseSelectorInput(muscle: "banana"),
            dryRun: true,
            expectedRevisionToken: fixture.revision
        )
        guard case .rejected(let message) = result else {
            Issue.record("Expected the unknown taxonomy value to reject")
            return
        }
        #expect(message.contains("\"banana\" isn't a muscle"))
        #expect(message.contains("quadriceps"))
    }

    @Test func convertRejectsNonDisplayMetricsAndStaleTokens() throws {
        let fixture = makeFixture()
        guard case .rejected(let metricMessage) = fixture.store.convertWorkoutUnits(
            units: [.reps: .count],
            selector: nil,
            dryRun: false,
            expectedRevisionToken: fixture.revision
        ) else {
            Issue.record("Expected the non-display metric to reject")
            return
        }
        #expect(metricMessage.contains("only sets distance, load, duration, and pace"))

        guard case .rejected(let staleMessage) = fixture.store.convertWorkoutUnits(
            units: [.distance: .kilometers],
            selector: nil,
            dryRun: false,
            expectedRevisionToken: UUID()
        ) else {
            Issue.record("Expected the stale token to reject")
            return
        }
        #expect(staleMessage.contains("changed after I read it"))
    }

    // MARK: - bulk_replace_exercises

    @Test func bulkReplaceDryRunEnumeratesExactMatchesAndNeverSilentlyOverMatches() throws {
        let fixture = makeFixture()
        let before = fixture.revision

        // The policy-sensitive phrase "all runs" resolved precisely: catalog id "run" matches ONLY
        // the two outdoor runs — not the treadmill variant, not the rower, and not the unclassified
        // "Mystery Run", which is listed for the model to handle individually.
        let preview = fixture.store.bulkReplaceExercises(
            selector: BulkExerciseSelectorInput(definitionID: "run"),
            replacementDefinitionID: "row",
            dryRun: true,
            expectedRevisionToken: before
        )
        guard case .preview(let detail) = preview else {
            Issue.record("Expected a dry-run preview: \(preview)")
            return
        }
        #expect(detail.contains("DRY RUN"))
        #expect(detail.contains("2 exercise instances"))
        #expect(detail.contains(fixture.runIDs[0].uuidString))
        #expect(detail.contains(fixture.runIDs[1].uuidString))
        #expect(!detail.contains(fixture.treadmillID.uuidString))
        #expect(!detail.contains(fixture.rowID.uuidString))
        #expect(detail.contains("Mystery Run"))
        #expect(detail.contains("no catalog identity"))
        #expect(fixture.revision == before)   // a dry run writes nothing
        #expect(fixture.workout.exercise(fixture.runIDs[0])?.definitionId == "run")
    }

    @Test func bulkReplaceBroadSelectorEnumeratesTheWholeAmbiguousSet() throws {
        let fixture = makeFixture()
        // "Cardio" is the over-broad reading of "all runs": the enumeration must expose that the
        // rower is included so the model can confirm rather than guess.
        let preview = fixture.store.bulkReplaceExercises(
            selector: BulkExerciseSelectorInput(modality: "cardio"),
            replacementDefinitionID: "ski_erg",
            dryRun: true,
            expectedRevisionToken: fixture.revision
        )
        guard case .preview(let detail) = preview else {
            Issue.record("Expected a dry-run preview")
            return
        }
        #expect(detail.contains("4 exercise instances"))
        #expect(detail.contains(fixture.rowID.uuidString))
        #expect(detail.contains(fixture.treadmillID.uuidString))
    }

    @Test func bulkReplaceAppliesAtomicallyPreservingInstanceIdentityAndSets() throws {
        let fixture = makeFixture()
        let before = fixture.revision

        guard case .applied(let receipt, let detail) = fixture.store.bulkReplaceExercises(
            selector: BulkExerciseSelectorInput(definitionID: "run"),
            replacementDefinitionID: "row",
            dryRun: false,
            expectedRevisionToken: before
        ) else {
            Issue.record("Expected the bulk replacement to apply")
            return
        }

        let updated = fixture.workout
        for (index, id) in fixture.runIDs.enumerated() {
            let exercise = updated.exercise(id)
            #expect(exercise?.definitionId == "row", "run \(index) should be replaced")
            #expect(exercise?.exerciseName == "Row")
            #expect(exercise?.id == id)   // replacement preserves the instance ID
        }
        // Sets survive replacement, canonical values intact.
        #expect(updated.exercise(fixture.runIDs[0])?.prescription.sets.first?.values[.distance] == 400)
        // Non-matching instances untouched.
        #expect(updated.exercise(fixture.treadmillID)?.definitionId == "treadmill_run")
        #expect(updated.exercise(fixture.mysteryID)?.definitionId == nil)
        #expect(receipt.diff.changes.count == 2)
        #expect(detail.contains("Replaced 2 exercise instances with Row"))

        // One undo reverts the whole semantic replacement.
        guard case .mutated = fixture.store.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ) else {
            Issue.record("Expected the bulk-replace undo to apply")
            return
        }
        #expect(fixture.workout.exercise(fixture.runIDs[0])?.definitionId == "run")
        #expect(fixture.revision == before)
    }

    @Test func bulkReplaceReportsInstancesAlreadyMatchingTheReplacement() throws {
        let fixture = makeFixture()
        // Replacing all cardio with Row: the existing rower is reported as already-Row, not
        // rewritten, and the receipt covers only real changes.
        guard case .applied(let receipt, let detail) = fixture.store.bulkReplaceExercises(
            selector: BulkExerciseSelectorInput(modality: "cardio"),
            replacementDefinitionID: "row",
            dryRun: false,
            expectedRevisionToken: fixture.revision
        ) else {
            Issue.record("Expected the bulk replacement to apply")
            return
        }
        #expect(receipt.diff.changes.count == 3)   // two runs + treadmill; not the existing rower
        #expect(detail.contains("Already Row"))
        #expect(detail.contains(fixture.rowID.uuidString))
    }

    @Test func bulkReplaceRejectsUnknownReplacementAndEmptySelector() throws {
        let fixture = makeFixture()
        guard case .rejected(let unknownMessage) = fixture.store.bulkReplaceExercises(
            selector: BulkExerciseSelectorInput(definitionID: "run"),
            replacementDefinitionID: "not_a_real_movement",
            dryRun: true,
            expectedRevisionToken: fixture.revision
        ) else {
            Issue.record("Expected the unknown replacement id to reject")
            return
        }
        #expect(unknownMessage.contains("isn't a catalog exercise id"))
        #expect(unknownMessage.contains("search_exercises"))

        guard case .rejected(let emptyMessage) = fixture.store.bulkReplaceExercises(
            selector: BulkExerciseSelectorInput(),
            replacementDefinitionID: "row",
            dryRun: true,
            expectedRevisionToken: fixture.revision
        ) else {
            Issue.record("Expected the empty selector to reject")
            return
        }
        #expect(emptyMessage.contains("at least one selector field"))
    }

    @Test func bulkReplaceNoMatchesRejectsWithoutWriting() throws {
        let fixture = makeFixture()
        let before = fixture.revision
        guard case .rejected(let message) = fixture.store.bulkReplaceExercises(
            selector: BulkExerciseSelectorInput(tag: "powerlifting", blockID: fixture.conditioningBlockID),
            replacementDefinitionID: "row",
            dryRun: false,
            expectedRevisionToken: before
        ) else {
            Issue.record("Expected the no-match selector to reject")
            return
        }
        #expect(message.contains("nothing was changed"))
        #expect(fixture.revision == before)
    }
}
