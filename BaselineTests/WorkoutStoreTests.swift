import Foundation
import Testing
@testable import Baseline

@MainActor
struct WorkoutStoreTests {

    private func store() -> WorkoutStore {
        WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
    }

    /// Test setup through the ID-based mutation path: resolves the named block (falling back to the
    /// workout's first block) and the current revision token so tests read like the old one-liner.
    @discardableResult
    private func addExercise(
        _ s: WorkoutStore,
        name: String,
        inBlockNamed blockName: String? = nil,
        sets: Int? = nil,
        reps: Int? = nil,
        load: Double? = nil,
        durationSeconds: Int? = nil,
        distanceMeters: Double? = nil
    ) -> WorkoutStore.EditOutcome {
        guard let workout = s.current,
              let blockID = blockName.flatMap({ named in workout.blocks.first { $0.name == named }?.id })
                ?? workout.blocks.first?.id,
              let token = s.mutationTarget(.plan)?.revisionToken else {
            return .notFound("test setup: no current workout")
        }
        return s.addExercise(
            name: name,
            toBlockID: blockID,
            atIndex: nil,
            sets: sets,
            reps: reps,
            load: load,
            durationSeconds: durationSeconds,
            distanceMeters: distanceMeters,
            expectedRevisionToken: token
        )
    }

    @Test func createAddAndMoveByID() throws {
        let s = store()
        s.create(title: "Push", goal: nil)
        #expect(s.addBlock(name: "Warm-up", intent: nil).succeeded)
        #expect(s.addBlock(name: "Strength", intent: "hypertrophy").succeeded)
        #expect(addExercise(s, name: "Bench press", inBlockNamed: "Strength", sets: 3, reps: 8, load: 60).succeeded)
        #expect(s.current?.blocks.first { $0.name == "Strength" }?.exercises.first?.exerciseName == "Bench press")
        #expect(s.current?.allExercises.first?.prescription.sets.count == 3)
        let benchID = try #require(s.current?.allExercises.first?.id)
        let warmupID = try #require(s.current?.blocks.first { $0.name == "Warm-up" }?.id)
        #expect(s.moveExercise(
            exerciseInstanceID: benchID,
            toBlockID: warmupID,
            toIndex: 0,
            expectedRevisionToken: try #require(s.mutationTarget(.plan)?.revisionToken)
        ).succeeded)
        #expect(s.current?.blocks.first { $0.name == "Warm-up" }?.exercises.count == 1)
        #expect(s.current?.blocks.first { $0.name == "Strength" }?.exercises.isEmpty == true)
    }

    @Test func updateSingleSetByIDLeavesOthers() throws {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "A", intent: nil)
        addExercise(s, name: "Squat", inBlockNamed: "A", sets: 3, reps: 5, load: 100)
        let setID = try #require(s.current?.allExercises.first?.prescription.sets[1].id)
        let token = try #require(s.mutationTarget(.plan)?.revisionToken)
        #expect(s.updateSet(
            setID: setID,
            patch: .init(values: .set(.init(metrics: [.load: .set(110), .rpe: .set(9)]))),
            expectedRevisionToken: token
        ).succeeded)
        let sets = s.current!.allExercises.first!.prescription.sets
        #expect(sets[1].load == 110)
        #expect(sets[1].rpe == 9)
        #expect(sets[0].load == 100)      // untouched
    }

    @Test func unknownIDsAndBadSetsFail() throws {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "Real", intent: nil)
        let token = try #require(s.mutationTarget(.plan)?.revisionToken)
        // Failed mutations are atomic, so the same token stays valid across every rejection.
        #expect(!s.moveExercise(
            exerciseInstanceID: UUID(), toBlockID: UUID(), toIndex: 0, expectedRevisionToken: token
        ).succeeded)
        #expect(!s.updateSet(
            setID: UUID(),
            patch: .init(values: .set(.init(metrics: [.reps: .set(5)]))),
            expectedRevisionToken: token
        ).succeeded)
        #expect(!s.addExercise(
            name: "X", toBlockID: UUID(), atIndex: nil,
            sets: 1, reps: nil, load: nil, durationSeconds: nil,
            expectedRevisionToken: token
        ).succeeded)
    }

    @Test func idBasedExerciseMutationsTargetOneDuplicate() throws {
        let store = store()
        store.create(title: "Intervals", goal: nil)
        store.addBlock(name: "Overload", intent: nil)
        store.addBlock(name: "Recovery", intent: nil)
        addExercise(store, name: "Run", inBlockNamed: "Overload", sets: 1, durationSeconds: 60)
        addExercise(store, name: "Run", inBlockNamed: "Overload", sets: 1, durationSeconds: 120)

        let runs = try #require(store.current?.blocks.first { $0.name == "Overload" }?.exercises)
        let first = try #require(runs.first)
        let second = try #require(runs.last)
        let recoveryID = try #require(store.current?.blocks.first { $0.name == "Recovery" }?.id)

        #expect(store.setLoggingConfig(
            exerciseInstanceID: second.id,
            enabled: [.duration],
            expectedRevisionToken: try #require(store.mutationTarget(.plan)?.revisionToken)
        ).succeeded)
        #expect(store.current?.exercise(first.id)?.selectedMetrics != [.duration])
        #expect(store.current?.exercise(second.id)?.selectedMetrics == [.duration])

        #expect(store.replaceExercise(
            exerciseInstanceID: first.id,
            with: "Treadmill Run",
            expectedRevisionToken: try #require(store.mutationTarget(.plan)?.revisionToken)
        ).succeeded)
        #expect(store.current?.exercise(first.id)?.exerciseName == "Treadmill Run")
        #expect(store.current?.exercise(second.id)?.exerciseName == "Run")

        #expect(store.moveExercise(
            exerciseInstanceID: second.id,
            toBlockID: recoveryID,
            toIndex: 0,
            expectedRevisionToken: try #require(store.mutationTarget(.plan)?.revisionToken)
        ).succeeded)
        #expect(store.current?.blocks.first { $0.id == recoveryID }?.exercises.map(\.id) == [second.id])

        #expect(store.removeMetric(
            exerciseInstanceID: second.id,
            metric: .duration,
            expectedRevisionToken: try #require(store.mutationTarget(.plan)?.revisionToken)
        ).succeeded)
        #expect(store.current?.exercise(second.id)?.selectedMetrics.contains(.duration) == false)

        #expect(store.removeExercise(
            exerciseInstanceID: first.id,
            expectedRevisionToken: try #require(store.mutationTarget(.plan)?.revisionToken)
        ).succeeded)
        #expect(store.current?.exercise(first.id) == nil)
        #expect(store.current?.exercise(second.id) != nil)
    }

    @Test func idBasedSetMutationsTargetOneDuplicate() throws {
        let store = store()
        store.create(title: "Intervals", goal: nil)
        store.addBlock(name: "Overload", intent: nil)
        addExercise(store, name: "Run", inBlockNamed: "Overload", sets: 1, durationSeconds: 60)
        addExercise(store, name: "Run", inBlockNamed: "Overload", sets: 1, durationSeconds: 120)

        let runs = try #require(store.current?.blocks.first { $0.name == "Overload" }?.exercises)
        let first = try #require(runs.first)
        let second = try #require(runs.last)
        let secondSetID = try #require(second.prescription.sets.first?.id)

        #expect(store.updateSet(
            setID: secondSetID,
            patch: .init(values: .set(.init(metrics: [.duration: .set(180)]))),
            expectedRevisionToken: try #require(store.mutationTarget(.plan)?.revisionToken)
        ).succeeded)
        #expect(store.current?.exercise(first.id)?.prescription.sets.first?.duration == 60)
        #expect(store.current?.exercise(second.id)?.prescription.sets.first?.duration == 180)

        #expect(store.setMetricValue(
            exerciseInstanceID: second.id,
            setID: secondSetID,
            metric: .distance,
            value: 1,
            unit: .kilometers,
            expectedRevisionToken: try #require(store.mutationTarget(.plan)?.revisionToken)
        ).succeeded)
        #expect(store.current?.exercise(first.id)?.prescription.sets.first?.distance == nil)
        #expect(store.current?.exercise(second.id)?.prescription.sets.first?.distance == 1_000)
    }

    @Test func transientUndoRemoveSetRestoresPurgedRowAndKeepsLaterLogs() throws {
        let s = store()
        s.create(title: "Intervals", goal: nil)
        addExercise(s, name: "Run", sets: 3, durationSeconds: 60)
        let run = try #require(s.current?.allExercises.first)
        let setIDs = run.prescription.sets.map(\.id)
        s.startWorkout()
        s.editLog { log in
            log.upsertSetLog(forPlanned: run.id, name: "Run", plannedSetID: setIDs[0]) { performed in
                performed.values[.duration] = 61
                performed.completed = true
            }
        }
        let token = try #require(s.mutationTarget(.plan)?.revisionToken)
        guard case .mutated(let receipt) = s.removeSet(setID: setIDs[0], expectedRevisionToken: token) else {
            Issue.record("expected the removal to apply"); return
        }
        #expect(s.currentLog?.performed(forPlanned: run.id)?.setLogs
            .contains { $0.plannedSetID == setIDs[0] } == false)

        // Work logged after the removal must survive the undo.
        s.editLog { log in
            log.upsertSetLog(forPlanned: run.id, name: "Run", plannedSetID: setIDs[1]) { performed in
                performed.values[.duration] = 62
                performed.completed = true
            }
        }

        #expect(s.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ).succeeded)
        #expect(s.current?.allExercises.first?.prescription.sets.map(\.id) == setIDs)
        let logs = try #require(s.currentLog?.performed(forPlanned: run.id)?.setLogs)
        #expect(logs.count == 2)
        #expect(logs.first { $0.plannedSetID == setIDs[0] }?.values[.duration] == 61)
        #expect(logs.first { $0.plannedSetID == setIDs[0] }?.completed == true)
        #expect(logs.first { $0.plannedSetID == setIDs[1] }?.values[.duration] == 62)
    }

    @Test func replaceExercisePreservesIdentityAndPrescription() throws {
        let s = store()
        s.create(title: "Outdoor Run", goal: nil)
        s.addBlock(name: "Warm-up", intent: nil)
        s.addBlock(name: "Main Run", intent: nil)
        addExercise(s, name: "Treadmill Run", inBlockNamed: "Warm-up", sets: 1, durationSeconds: 300)
        addExercise(s, name: "Treadmill Run", inBlockNamed: "Main Run", sets: 1, durationSeconds: 1_800)

        let originalIDs = try #require(s.current?.allExercises.map(\.id))
        s.edit(.plan) { workout in
            _ = workout.updateExercise(originalIDs[0]) { $0.prescription.sets[0].rpe = 2 }
            _ = workout.updateExercise(originalIDs[1]) { $0.prescription.sets[0].rpe = 3 }
        }

        let before = try #require(s.current?.allExercises)
        let prescriptions = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.prescription) })

        for id in originalIDs {
            #expect(s.replaceExercise(
                exerciseInstanceID: id,
                with: "Run",
                expectedRevisionToken: try #require(s.mutationTarget(.plan)?.revisionToken)
            ).succeeded)
        }
        let after = try #require(s.current?.allExercises)
        #expect(after.count == 2)
        #expect(Set(after.map(\.id)) == Set(before.map(\.id)))
        #expect(after.allSatisfy { $0.exerciseName == "Run" })
        #expect(after.allSatisfy { $0.definitionId == "run" })
        #expect(after.allSatisfy { prescriptions[$0.id] == $0.prescription })
    }

    @Test func startWorkoutAndLoggedActualsPersistWithoutTouchingPlan() {
        let d = UserDefaults(suiteName: "wk-\(UUID().uuidString)")!
        let s1 = WorkoutStore(units: StubUnitSystem(), defaults: d)
        s1.create(title: "x", goal: nil)
        s1.addBlock(name: "A", intent: nil)
        addExercise(s1, name: "Squat", inBlockNamed: "A", sets: 1, reps: 5, load: 100)
        s1.startWorkout()
        let exID = s1.current!.allExercises.first!.id
        s1.editLog { $0.logSet(SetLog(reps: 5, load: 105), forPlanned: exID, name: "Squat") }
        // Reload from disk: performed log restored, plan intact and separate.
        let s2 = WorkoutStore(units: StubUnitSystem(), defaults: d)
        #expect(s2.currentLog?.performed(forPlanned: exID)?.setLogs.first?.load == 105)
        #expect(s2.current?.allExercises.first?.prescription.sets.first?.load == 100)
    }

    @Test func compactSummaryIndexesWithoutDumpingDetail() {
        let s = store()
        #expect(s.compactSummary(.plan) == nil)                    // no workout yet
        s.create(title: "MED", goal: nil)
        addExercise(s, name: "Row", sets: 3, durationSeconds: 600)
        let compact = s.compactSummary(.plan) ?? ""
        #expect(compact.contains("Title: MED"))
        #expect(compact.contains("1 exercise"))
        #expect(compact.contains("not started"))
        #expect(!compact.contains("Row"))
        #expect(!compact.contains("Duration:"))            // no exercise or set-level detail leaks into the index
    }

    @Test func incompleteWorkCountsUncheckedSetsAcrossExercises() {
        let s = store()
        s.create(title: "x", goal: nil)
        addExercise(s, name: "Squat", sets: 2, reps: 5, load: 100)
        addExercise(s, name: "Bench", sets: 1, reps: 5, load: 60)
        #expect(s.incompleteWork().sets == 0)               // not started → nothing to complete
        s.startWorkout()
        #expect(s.incompleteWork() == (sets: 3, exercises: 2))
        // Check off both Squat sets → only Bench's one set remains open.
        let squat = s.current!.allExercises.first { $0.exerciseName == "Squat" }!
        s.editLog { log in
            for set in squat.prescription.sets {
                log.upsertSetLog(forPlanned: squat.id, name: "Squat", plannedSetID: set.id) { $0.completed = true }
            }
        }
        #expect(s.incompleteWork() == (sets: 1, exercises: 1))
    }

    @Test func clampsNegativeNumbersAndRejectsOutOfRangeRpe() throws {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "A", intent: nil)
        addExercise(s, name: "Squat", inBlockNamed: "A", sets: 1, reps: -5, load: -100, durationSeconds: -30)
        let set = s.current!.allExercises.first!.prescription.sets.first!
        #expect(set.reps == 0)
        #expect(set.load == 0)
        #expect(set.duration == 0)
        addExercise(s, name: "Bench", inBlockNamed: "A", sets: 1, reps: 5, load: 60)
        let benchSetID = try #require(
            s.current?.allExercises.first { $0.exerciseName == "Bench" }?.prescription.sets.first?.id
        )
        // The ID-based set patch validates instead of silently clamping: RPE stays 0…10.
        guard case .notFound(let message) = s.updateSet(
            setID: benchSetID,
            patch: .init(values: .set(.init(metrics: [.rpe: .set(99)]))),
            expectedRevisionToken: try #require(s.mutationTarget(.plan)?.revisionToken)
        ) else {
            Issue.record("expected an out-of-range RPE to be rejected"); return
        }
        #expect(message.contains("RPE"))
        let bench = s.current!.allExercises.first { $0.exerciseName == "Bench" }!
        #expect(bench.prescription.sets.first?.rpe == nil)   // untouched
    }

    @Test func distanceIsStoredInMetersNotTheName() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "Stations", intent: nil)
        // "150m overhead carry" — distance is a real metric, not encoded in the name.
        #expect(addExercise(s, name: "Overhead carry", inBlockNamed: "Stations", sets: 1, distanceMeters: 150).succeeded)
        #expect(s.current?.allExercises.first?.prescription.sets.first?.distance == 150)
        #expect(s.current?.allExercises.first?.exerciseName == "Overhead carry")
    }

    @Test func addExercisePopulatesCatalogIdentityAndSelectedMetrics() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "Cardio", intent: nil)
        addExercise(s, name: "Stationary Bike", inBlockNamed: "Cardio", sets: 1, durationSeconds: 3600)
        let ex = s.current!.allExercises.first!
        #expect(ex.definitionId == "stationary_bike")            // resolved to a stable identity
        #expect(ex.selectedMetrics.contains(.duration))
        #expect(ex.selectedMetrics.contains(.distance))          // catalog default, even though only duration was passed
    }

    // MARK: - Metric logging config, units, and scope (acceptance criteria)

    /// Adds a Stationary Bike, then configures it to log duration only.
    private func bikeStore() -> WorkoutStore {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "Cardio", intent: nil)
        addExercise(s, name: "Stationary Bike", inBlockNamed: "Cardio", sets: 1, durationSeconds: 3600)
        return s
    }

    @Test func durationOnlyBikeHidesDistance() throws {
        let s = bikeStore()
        let bikeID = try #require(s.current?.allExercises.first?.id)
        #expect(s.setLoggingConfig(
            exerciseInstanceID: bikeID,
            enabled: [.duration],
            expectedRevisionToken: try #require(s.mutationTarget(.plan)?.revisionToken)
        ).succeeded)
        let ex = s.current!.allExercises.first!
        #expect(ex.selectedMetrics == [.duration])
        #expect(!ex.selectedMetrics.contains(.distance))     // no blank distance field
    }

    @Test func switchingKmToMilesPreservesCanonicalMeters() throws {
        let s = bikeStore()
        let bike = try #require(s.current?.allExercises.first)
        let setID = try #require(bike.prescription.sets.first?.id)
        s.setMetricValue(
            exerciseInstanceID: bike.id,
            setID: setID,
            metric: .distance,
            value: 10,
            unit: .kilometers,
            expectedRevisionToken: try #require(s.mutationTarget(.plan)?.revisionToken)
        )
        let stored = s.current!.allExercises.first!.prescription.sets.first!.values[.distance]!
        #expect(abs(stored - 10_000) < 0.001)                // stored canonical (meters)
        // Switch the display unit to miles — the stored value is untouched.
        s.setLoggingConfig(
            exerciseInstanceID: bike.id,
            enabled: nil,
            units: [.distance: .miles],
            expectedRevisionToken: try #require(s.mutationTarget(.plan)?.revisionToken)
        )
        let ex = s.current!.allExercises.first!
        #expect(s.displayUnit(.distance, for: ex) == .miles)
        #expect(abs(ex.prescription.sets.first!.values[.distance]! - 10_000) < 0.001)  // unchanged
    }

    @Test func exercisePreferenceAffectsFutureInstancesOnly() {
        let s = bikeStore()
        // "Use miles for Stationary Bike from now on."
        #expect(s.setExercisePreference(exerciseNamed: "Stationary Bike", scope: .exercise, units: [.distance: .miles]).succeeded)
        // Today's existing instance is NOT changed (no per-instance override set).
        let existing = s.current!.allExercises.first!
        #expect(existing.displayUnits[.distance] == nil)
        // A NEW instance resolves to miles via the preference.
        s.addBlock(name: "More", intent: nil)
        addExercise(s, name: "Stationary Bike", inBlockNamed: "More", sets: 1, durationSeconds: 600)
        let fresh = s.current!.allExercises.last!
        #expect(s.displayUnit(.distance, for: fresh) == .miles)
    }

    @Test func thisWorkoutConfigDoesNotMutateGlobalDefault() throws {
        let s = bikeStore()
        #expect(s.setLoggingConfig(
            exerciseInstanceID: try #require(s.current?.allExercises.first?.id),
            enabled: [.duration],
            expectedRevisionToken: try #require(s.mutationTarget(.plan)?.revisionToken)
        ).succeeded)
        // The global/default preference is untouched by a this-workout change.
        #expect(s.preferences.selectedByExercise["stationary_bike"] == nil)
    }

    @Test func idBasedMetricConfigTargetsOneDuplicateExercise() throws {
        let s = store()
        s.create(title: "Bike intervals", goal: nil)
        let blockID = try #require(s.current?.blocks.first?.id)
        let first = PlannedExercise(
            exerciseName: "Stationary Bike",
            definitionId: "stationary_bike",
            selectedMetrics: [.duration, .distance]
        )
        let second = PlannedExercise(
            exerciseName: "Stationary Bike",
            definitionId: "stationary_bike",
            selectedMetrics: [.duration, .distance]
        )
        s.addExercise(first, toBlockID: blockID, scope: .plan)
        s.addExercise(second, toBlockID: blockID, scope: .plan)

        #expect(s.setLoggingConfig(exerciseID: second.id, enabled: [.duration], units: [:], scope: .plan))
        #expect(s.current?.exercise(first.id)?.selectedMetrics == [.duration, .distance])
        #expect(s.current?.exercise(second.id)?.selectedMetrics == [.duration])
    }

    @Test func agentSummaryPreservesNestedStructureNotesLabelsTargetsMetricsAndUnits() {
        let s = store()
        s.create(title: "Aerobic capacity", goal: "Consolidate")
        let sled = PlannedExercise(
            exerciseName: "Sled Pull",
            displayLabel: "Option B sled",
            definitionId: "sled_pull",
            selectedMetrics: [.distance, .load],
            // Pin both units so this structural test is independent of the global unit-system
            // default (metric now defaults distance to km — see the displayUnit fallback tests).
            displayUnits: [.load: .pounds, .distance: .meters],
            prescription: Prescription(
                sets: [PlannedSet(
                    distance: 25,
                    effortTarget: .rpe(7),
                    alternatives: [PlannedSetAlternative(
                        label: "Short course",
                        values: MetricValues([.distance: 15]),
                        ranges: [MetricTargetRange(metric: .load, lower: 20, upper: 30)]
                    )]
                )],
                intensityTargets: [.descriptive("Load target: Race weight")]
            ),
            guidance: CoachGuidance(formCues: ["Keep the rope tight"])
        )
        let group = WorkoutGroup(
            label: "Option B",
            phase: .main,
            execution: GroupExecution(
                repetition: .count(4),
                totalTargets: MetricValues([.distance: 100]),
                adjustments: [MetricAdjustment(metric: .load, step: 5, minimum: 20, maximum: 60)]
            ),
            children: [.exercise(sled)],
            guidance: CoachGuidance(formCues: ["Complete every movement"]),
            doseLayer: .med,
            isOptional: true
        )
        let choice = WorkoutChoice(label: "Bike modality", options: [
            .exercise(PlannedExercise(exerciseName: "Echo Bike", definitionId: "echo_bike")),
            .exercise(PlannedExercise(exerciseName: "Concept2 Bike", definitionId: "concept2_bike")),
        ])
        s.edit(.plan) { workout in
            workout.guidance = CoachGuidance(formCues: ["Protect the next intensity day"])
            workout.blocks[0].guidance = CoachGuidance(formCues: ["Stay aerobic"])
            workout.blocks[0].nodes = [.group(group), .choice(choice)]
        }

        let summary = s.summary(.plan)

        #expect(summary.contains("REQUIRED GROUP: Option B"))
        #expect(summary.contains("CHOICE: Bike modality — choose 1 of 2"))
        #expect(summary.contains("Option B sled [exercise: Sled Pull]"))
        #expect(summary.contains("Metrics: Distance (m), Load (lb)"))
        #expect(summary.contains("Distance=25 m"))
        #expect(summary.contains("Load=blank"))
        #expect(summary.contains("Target: Load target: Race weight"))
        #expect(summary.contains("Effort target: RPE 7"))
        #expect(summary.contains("Alternative Short course: Distance=15 m"))
        #expect(summary.contains("Range: Load"))
        #expect(summary.contains("phase main"))
        #expect(summary.contains("dose MED"))
        #expect(summary.contains("optional"))
        // Group-level values have no single exercise to hang a unit override on, so the group's
        // composition decides: this one is a sled pull, i.e. floor work, i.e. metres.
        #expect(summary.contains("Total targets: Distance=100 m"))
        #expect(summary.contains("Adjustment: Load step 5 kg, minimum 20 kg, maximum 60 kg"))
        #expect(summary.contains("Protect the next intensity day"))
        #expect(summary.contains("Complete every movement"))
        #expect(summary.contains("Keep the rope tight"))
    }

    @Test func transientReviewStoreKeepsDraftEditsIsolatedButSharesDeliberateDefaults() {
        let defaults = UserDefaults(suiteName: "wk-\(UUID().uuidString)")!
        let source = WorkoutStore(units: StubUnitSystem(), defaults: defaults)
        source.create(title: "Today's workout", goal: nil)
        let imported = Workout(
            title: "Imported draft",
            blocks: [WorkoutBlock(name: "Main", exercises: [
                PlannedExercise(exerciseName: "Stationary Bike", definitionId: "stationary_bike"),
            ])]
        )
        let review = WorkoutStore(transientWorkout: imported, configurationFrom: source)

        review.edit(.plan) { $0.rename("Edited import") }
        #expect(review.current?.title == "Edited import")
        #expect(source.current?.title == "Today's workout")
        #expect(WorkoutStore(units: StubUnitSystem(), defaults: defaults).current?.title == "Today's workout")

        #expect(review.setExercisePreference(
            exerciseNamed: "Stationary Bike",
            scope: .exercise,
            units: [.distance: .miles]
        ).succeeded)
        #expect(source.preferences.unitsByExercise["stationary_bike"]?[.distance] == .miles)

        let custom = review.createCustomDefinition(
            name: "Heavy Rope Drag",
            category: .carry,
            supported: [.distance, .load]
        )
        #expect(source.customDefinitions.contains { $0.id == custom.id })
    }

    @Test func requireAllOptionsConvertsOnlyTheNamedChoice() {
        let s = store()
        s.create(title: "AMRAP", goal: nil)
        let choice = WorkoutChoice(label: "Option B", options: [
            .exercise(PlannedExercise(exerciseName: "Deadlift", definitionId: "deadlift")),
            .exercise(PlannedExercise(
                exerciseName: "Lateral Burpee Over Barbell",
                definitionId: "lateral_burpee_over_barbell"
            )),
        ])
        s.edit(.plan) { workout in
            workout.blocks[0].nodes.append(.choice(choice))
        }

        #expect(s.requireAllOptions(choiceNamed: "option b").succeeded)
        #expect(s.current?.allChoices.isEmpty == true)
        #expect(s.current?.allGroups.first?.children.count == 2)
        #expect(!s.requireAllOptions(choiceNamed: "missing").succeeded)
    }

    @Test func unsupportedMetricIsRejected() throws {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "Strength", intent: nil)
        addExercise(s, name: "Deadlift", inBlockNamed: "Strength", sets: 3, reps: 5, load: 140)
        let deadlift = try #require(s.current?.allExercises.first)
        // A deadlift has no pace.
        guard case .notFound(let msg) = s.setMetricValue(
            exerciseInstanceID: deadlift.id,
            setID: try #require(deadlift.prescription.sets.first?.id),
            metric: .pace,
            value: 5,
            unit: nil,
            expectedRevisionToken: try #require(s.mutationTarget(.plan)?.revisionToken)
        ) else {
            Issue.record("expected rejection"); return
        }
        #expect(msg.localizedCaseInsensitiveContains("pace"))
    }

    // MARK: - Catalog-first add (search / custom / recent)

    @Test func searchCustomAndRecentTracking() {
        let s = store()
        #expect(s.searchDefinitions("bike").contains { $0.id == "stationary_bike" })
        #expect(s.searchDefinitions("").count >= ExerciseCatalog.definitions.count)   // empty → all
        // Custom is deliberate and resolvable by name.
        let def = s.createCustomDefinition(name: "Sled Drag", category: .carry, supported: [.distance, .load])
        #expect(def.id.hasPrefix("custom_"))
        #expect(s.searchDefinitions("sled").contains { $0.id == def.id })
        #expect(s.resolveDefinition("Sled Drag").id == def.id)
        #expect(s.createCustomDefinition(name: "Sled Drag", category: .carry, supported: []).id == def.id)  // dedup by name
        // Adding tracks recents.
        s.create(title: "x", goal: nil); s.addBlock(name: "A", intent: nil)
        var ex = PlannedExercise(exerciseName: "Deadlift"); ex.definitionId = "deadlift"
        s.addExercise(ex, toBlockID: s.current!.blocks.first!.id, scope: .plan)
        #expect(s.recentExerciseIds.first == "deadlift")
    }

    @Test func createStampsTodayAndClearsLog() {
        let s = store()
        s.create(title: "a", goal: nil)
        s.addBlock(name: "A", intent: nil)
        s.startWorkout()
        #expect(s.currentLog != nil)
        #expect(s.currentIsForToday)
        #expect(s.current?.scheduledDate != nil)
        s.create(title: "b", goal: nil)                     // replacing clears the prior performed log
        #expect(s.currentLog == nil)
    }

    @Test func createGivesImplicitDefaultBlock() {
        let s = store()
        s.create(title: "x", goal: nil)
        #expect(s.current?.blocks.count == 1)
        #expect(s.current?.blocks.first?.isDefault == true)
        #expect(s.current?.blocks.first?.name.isEmpty == true)
        #expect(addExercise(s, name: "Deadlift", sets: 3, reps: 5, load: 100).succeeded)
        #expect(s.current?.allExercises.first?.exerciseName == "Deadlift")
    }

    @Test func persistsAcrossInstances() {
        let d = UserDefaults(suiteName: "wk-\(UUID().uuidString)")!
        let s1 = WorkoutStore(units: StubUnitSystem(), defaults: d)
        s1.create(title: "Persisted", goal: "test")          // implicit default block
        s1.addBlock(name: "A", intent: nil)                  // + explicit block
        let s2 = WorkoutStore(units: StubUnitSystem(), defaults: d)
        #expect(s2.current?.title == "Persisted")
        #expect(s2.current?.blocks.contains { $0.name == "A" } == true)
        #expect(s2.current?.blocks.count == 2)
    }

    // MARK: - Global unit-system default (fallback tier in displayUnit)

    @Test func globalUnitSystemSeedsConvertibleDefaults() {
        let units = StubUnitSystem()
        let s = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
        // A bare exercise with no per-instance override and no saved preference.
        let lift = PlannedExercise(exerciseName: "Deadlift", definitionId: "deadlift", selectedMetrics: [.load, .distance])
        let run = PlannedExercise(exerciseName: "Run", definitionId: "run", selectedMetrics: [.distance, .pace])

        units.unitSystem = .imperial
        #expect(s.displayUnit(.load, for: lift) == .pounds)
        #expect(s.displayUnit(.distance, for: run) == .miles)
        #expect(s.displayUnit(.pace, for: run) == .secondsPerMile)
        // Floor work is meters in both systems — a deadlift carry is not measured in miles.
        #expect(s.displayUnit(.distance, for: lift) == .meters)

        units.unitSystem = .metric
        #expect(s.displayUnit(.load, for: lift) == .kilograms)
        #expect(s.displayUnit(.distance, for: run) == .kilometers)
        #expect(s.displayUnit(.pace, for: run) == .secondsPerKilometer)
        #expect(s.displayUnit(.distance, for: lift) == .meters)

        // Non-convertible / duration metrics ignore the system and stay canonical.
        #expect(s.displayUnit(.reps, for: lift) == .count)
        #expect(s.displayUnit(.duration, for: lift) == .seconds)
    }

    @Test func perInstanceAndPreferenceStillWinOverGlobalDefault() {
        let s = WorkoutStore(units: StubUnitSystem(.metric),
                             defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
        // Per-instance override beats the global default.
        let overridden = PlannedExercise(
            exerciseName: "Sled Pull", definitionId: "sled_pull",
            selectedMetrics: [.load], displayUnits: [.load: .pounds]
        )
        #expect(s.displayUnit(.load, for: overridden) == .pounds)

        // A saved per-exercise preference also beats the global default for a fresh instance.
        #expect(s.setExercisePreference(exerciseNamed: "Stationary Bike", scope: .exercise, units: [.distance: .miles]).succeeded)
        let fresh = PlannedExercise(exerciseName: "Stationary Bike", definitionId: "stationary_bike", selectedMetrics: [.distance])
        #expect(s.displayUnit(.distance, for: fresh) == .miles)   // preference (miles), not metric-default km
    }

    @Test func unitSystemPerDimensionMapping() {
        let run = ExerciseCatalog.definition(id: "run")
        #expect(UnitSystem.imperial.displayUnit(metric: .load, exercise: nil) == .pounds)
        #expect(UnitSystem.imperial.displayUnit(metric: .distance, exercise: run) == .miles)
        #expect(UnitSystem.metric.displayUnit(metric: .load, exercise: nil) == .kilograms)
        #expect(UnitSystem.metric.displayUnit(metric: .distance, exercise: run) == .kilometers)
        // Duration and single-unit metrics don't vary by system.
        #expect(UnitSystem.imperial.displayUnit(metric: .duration, exercise: nil) == .seconds)
        #expect(UnitSystem.metric.displayUnit(metric: .reps, exercise: nil) == .count)
    }
}
