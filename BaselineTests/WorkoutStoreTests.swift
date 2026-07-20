import Foundation
import Testing
@testable import Baseline

@MainActor
struct WorkoutStoreTests {

    private func store() -> WorkoutStore {
        WorkoutStore(defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
    }

    @Test func createAddAndMoveByName() {
        let s = store()
        s.create(title: "Push", goal: nil)
        #expect(s.addBlock(name: "Warm-up", intent: nil).succeeded)
        #expect(s.addBlock(name: "Strength", intent: "hypertrophy").succeeded)
        #expect(s.addExercise(name: "Bench press", toBlockNamed: "Strength", sets: 3, reps: 8, load: 60, durationSeconds: nil).succeeded)
        #expect(s.current?.blocks.first { $0.name == "Strength" }?.exercises.first?.exerciseName == "Bench press")
        #expect(s.current?.allExercises.first?.prescription.sets.count == 3)
        // Move by name, case-insensitive + fuzzy ("bench" → "Bench press", "warm-up" → "Warm-up").
        #expect(s.moveExercise(named: "bench", toBlockNamed: "warm-up").succeeded)
        #expect(s.current?.blocks.first { $0.name == "Warm-up" }?.exercises.count == 1)
        #expect(s.current?.blocks.first { $0.name == "Strength" }?.exercises.isEmpty == true)
    }

    @Test func updateSingleSetByNumberLeavesOthers() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "A", intent: nil)
        s.addExercise(name: "Squat", toBlockNamed: "A", sets: 3, reps: 5, load: 100, durationSeconds: nil)
        #expect(s.updateSet(exerciseNamed: "Squat", setNumber: 2, reps: nil, load: 110, durationSeconds: nil, rpe: 9).succeeded)
        let sets = s.current!.allExercises.first!.prescription.sets
        #expect(sets[1].load == 110)
        #expect(sets[1].rpe == 9)
        #expect(sets[0].load == 100)      // untouched
    }

    @Test func unknownNamesAndBadSetsFail() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "Real", intent: nil)     // ≥2 blocks so a bad block name can't fall back to the implicit one
        #expect(!s.moveExercise(named: "ghost", toBlockNamed: "nowhere").succeeded)
        #expect(!s.updateSet(exerciseNamed: "ghost", setNumber: 1, reps: 5, load: nil, durationSeconds: nil, rpe: nil).succeeded)
        #expect(!s.addExercise(name: "X", toBlockNamed: "missing block", sets: 1, reps: nil, load: nil, durationSeconds: nil).succeeded)
    }

    @Test func ambiguousExerciseAsksWhichOne() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "Warm-up", intent: nil)
        s.addBlock(name: "Durability", intent: nil)
        s.addExercise(name: "Copenhagen plank", toBlockNamed: "Warm-up", sets: 1, reps: nil, load: nil, durationSeconds: 30)
        s.addExercise(name: "Copenhagen plank", toBlockNamed: "Durability", sets: 1, reps: nil, load: nil, durationSeconds: 45)
        // "Copenhagen" matches both → the tool must ask, naming the blocks, not silently pick one.
        guard case .ambiguous(let msg) = s.removeExercise(named: "Copenhagen") else {
            Issue.record("expected ambiguous"); return
        }
        #expect(msg.localizedCaseInsensitiveContains("Warm-up"))
        #expect(msg.localizedCaseInsensitiveContains("Durability"))
        // Nothing was removed while ambiguous.
        #expect(s.current?.allExercises.count == 2)
    }

    @Test func replaceAllExercisesPreservesIdentityAndPrescription() throws {
        let s = store()
        s.create(title: "Outdoor Run", goal: nil)
        s.addBlock(name: "Warm-up", intent: nil)
        s.addBlock(name: "Main Run", intent: nil)
        s.addExercise(name: "Treadmill Run", toBlockNamed: "Warm-up", sets: 1, reps: nil, load: nil, durationSeconds: 300)
        s.addExercise(name: "Treadmill Run", toBlockNamed: "Main Run", sets: 1, reps: nil, load: nil, durationSeconds: 1_800)

        let originalIDs = try #require(s.current?.allExercises.map(\.id))
        s.edit(.plan) { workout in
            _ = workout.updateExercise(originalIDs[0]) { $0.prescription.sets[0].rpe = 2 }
            _ = workout.updateExercise(originalIDs[1]) { $0.prescription.sets[0].rpe = 3 }
        }

        let before = try #require(s.current?.allExercises)
        let prescriptions = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.prescription) })

        guard case .ambiguous = s.replaceExercise(named: "Treadmill Run", with: "Run") else {
            Issue.record("A duplicate replacement without a scope should be ambiguous.")
            return
        }
        #expect(s.current?.allExercises.allSatisfy { $0.exerciseName == "Treadmill Run" } == true)

        #expect(s.replaceExercise(named: "Treadmill Run", with: "Run", replaceAll: true).succeeded)
        let after = try #require(s.current?.allExercises)
        #expect(after.count == 2)
        #expect(Set(after.map(\.id)) == Set(before.map(\.id)))
        #expect(after.allSatisfy { $0.exerciseName == "Run" })
        #expect(after.allSatisfy { $0.definitionId == "run" })
        #expect(after.allSatisfy { prescriptions[$0.id] == $0.prescription })
    }

    @Test func startWorkoutAndLoggedActualsPersistWithoutTouchingPlan() {
        let d = UserDefaults(suiteName: "wk-\(UUID().uuidString)")!
        let s1 = WorkoutStore(defaults: d)
        s1.create(title: "x", goal: nil)
        s1.addBlock(name: "A", intent: nil)
        s1.addExercise(name: "Squat", toBlockNamed: "A", sets: 1, reps: 5, load: 100, durationSeconds: nil)
        s1.startWorkout()
        let exID = s1.current!.allExercises.first!.id
        s1.editLog { $0.logSet(SetLog(reps: 5, load: 105), forPlanned: exID, name: "Squat") }
        // Reload from disk: performed log restored, plan intact and separate.
        let s2 = WorkoutStore(defaults: d)
        #expect(s2.currentLog?.performed(forPlanned: exID)?.setLogs.first?.load == 105)
        #expect(s2.current?.allExercises.first?.prescription.sets.first?.load == 100)
    }

    @Test func compactSummaryIndexesWithoutDumpingDetail() {
        let s = store()
        #expect(s.compactSummary(.plan) == nil)                    // no workout yet
        s.create(title: "MED", goal: nil)
        s.addExercise(name: "Row", toBlockNamed: "Main", sets: 3, reps: nil, load: nil, durationSeconds: 600)
        let compact = s.compactSummary(.plan) ?? ""
        #expect(compact.contains("Title: MED"))
        #expect(compact.contains("1 exercise"))
        #expect(compact.contains("not started"))
        #expect(!compact.contains("600"))                   // no set-level detail leaks into the index
    }

    @Test func incompleteWorkCountsUncheckedSetsAcrossExercises() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addExercise(name: "Squat", toBlockNamed: "Main", sets: 2, reps: 5, load: 100, durationSeconds: nil)
        s.addExercise(name: "Bench", toBlockNamed: "Main", sets: 1, reps: 5, load: 60, durationSeconds: nil)
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

    @Test func clampsNegativeNumbersAndRpe() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "A", intent: nil)
        s.addExercise(name: "Squat", toBlockNamed: "A", sets: 1, reps: -5, load: -100, durationSeconds: -30)
        let set = s.current!.allExercises.first!.prescription.sets.first!
        #expect(set.reps == 0)
        #expect(set.load == 0)
        #expect(set.duration == 0)
        s.addExercise(name: "Bench", toBlockNamed: "A", sets: 1, reps: 5, load: 60, durationSeconds: nil)
        #expect(s.updateSet(exerciseNamed: "Bench", setNumber: 1, reps: nil, load: nil, durationSeconds: nil, rpe: 99).succeeded)
        let bench = s.current!.allExercises.first { $0.exerciseName == "Bench" }!
        #expect(bench.prescription.sets.first?.rpe == 10)   // clamped to 0…10
    }

    @Test func distanceIsStoredInMetersNotTheName() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "Stations", intent: nil)
        // "150m overhead carry" — distance is a real metric, not encoded in the name.
        #expect(s.addExercise(name: "Overhead carry", toBlockNamed: "Stations", sets: 1, reps: nil, load: nil, durationSeconds: nil, distanceMeters: 150).succeeded)
        #expect(s.current?.allExercises.first?.prescription.sets.first?.distance == 150)
        #expect(s.current?.allExercises.first?.exerciseName == "Overhead carry")
    }

    @Test func addExercisePopulatesCatalogIdentityAndSelectedMetrics() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "Cardio", intent: nil)
        s.addExercise(name: "Stationary Bike", toBlockNamed: "Cardio", sets: 1, reps: nil, load: nil, durationSeconds: 3600, distanceMeters: nil)
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
        s.addExercise(name: "Stationary Bike", toBlockNamed: "Cardio", sets: 1, reps: nil, load: nil, durationSeconds: 3600, distanceMeters: nil)
        return s
    }

    @Test func durationOnlyBikeHidesDistance() {
        let s = bikeStore()
        #expect(s.setLoggingConfig(exerciseNamed: "Stationary Bike", enabled: [.duration]).succeeded)
        let ex = s.current!.allExercises.first!
        #expect(ex.selectedMetrics == [.duration])
        #expect(!ex.selectedMetrics.contains(.distance))     // no blank distance field
    }

    @Test func switchingKmToMilesPreservesCanonicalMeters() {
        let s = bikeStore()
        s.setMetricValue(exerciseNamed: "Stationary Bike", setNumber: 1, metric: .distance, value: 10, unit: .kilometers)
        let stored = s.current!.allExercises.first!.prescription.sets.first!.values[.distance]!
        #expect(abs(stored - 10_000) < 0.001)                // stored canonical (meters)
        // Switch the display unit to miles — the stored value is untouched.
        s.setLoggingConfig(exerciseNamed: "Stationary Bike", enabled: nil, units: [.distance: .miles])
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
        s.addExercise(name: "Stationary Bike", toBlockNamed: "More", sets: 1, reps: nil, load: nil, durationSeconds: 600, distanceMeters: nil)
        let fresh = s.current!.allExercises.last!
        #expect(s.displayUnit(.distance, for: fresh) == .miles)
    }

    @Test func thisWorkoutConfigDoesNotMutateGlobalDefault() {
        let s = bikeStore()
        #expect(s.setLoggingConfig(exerciseNamed: "Stationary Bike", enabled: [.duration]).succeeded)
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
        #expect(summary.contains("Total targets: Distance=100 m"))
        #expect(summary.contains("Adjustment: Load step 5, minimum 20, maximum 60"))
        #expect(summary.contains("Protect the next intensity day"))
        #expect(summary.contains("Complete every movement"))
        #expect(summary.contains("Keep the rope tight"))
    }

    @Test func transientReviewStoreKeepsDraftEditsIsolatedButSharesDeliberateDefaults() {
        let defaults = UserDefaults(suiteName: "wk-\(UUID().uuidString)")!
        let source = WorkoutStore(defaults: defaults)
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
        #expect(WorkoutStore(defaults: defaults).current?.title == "Today's workout")

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

    @Test func unsupportedMetricIsRejected() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "Strength", intent: nil)
        s.addExercise(name: "Deadlift", toBlockNamed: "Strength", sets: 3, reps: 5, load: 140, durationSeconds: nil, distanceMeters: nil)
        // A deadlift has no pace.
        guard case .notFound(let msg) = s.setMetricValue(exerciseNamed: "Deadlift", setNumber: 1, metric: .pace, value: 5, unit: nil) else {
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
        // A simple workout: any block name lands the exercise in the implicit block.
        #expect(s.addExercise(name: "Deadlift", toBlockNamed: "anything", sets: 3, reps: 5, load: 100, durationSeconds: nil).succeeded)
        #expect(s.current?.allExercises.first?.exerciseName == "Deadlift")
    }

    @Test func persistsAcrossInstances() {
        let d = UserDefaults(suiteName: "wk-\(UUID().uuidString)")!
        let s1 = WorkoutStore(defaults: d)
        s1.create(title: "Persisted", goal: "test")          // implicit default block
        s1.addBlock(name: "A", intent: nil)                  // + explicit block
        let s2 = WorkoutStore(defaults: d)
        #expect(s2.current?.title == "Persisted")
        #expect(s2.current?.blocks.contains { $0.name == "A" } == true)
        #expect(s2.current?.blocks.count == 2)
    }

    // MARK: - Global unit-system default (fallback tier in displayUnit)

    @Test func globalUnitSystemSeedsConvertibleDefaults() {
        let s = store()
        // A bare exercise with no per-instance override and no saved preference.
        let ex = PlannedExercise(exerciseName: "Deadlift", definitionId: "deadlift", selectedMetrics: [.load, .distance])

        s.unitSystem = .imperial
        #expect(s.displayUnit(.load, for: ex) == .pounds)
        #expect(s.displayUnit(.distance, for: ex) == .miles)

        s.unitSystem = .metric
        #expect(s.displayUnit(.load, for: ex) == .kilograms)
        #expect(s.displayUnit(.distance, for: ex) == .kilometers)

        // Non-convertible / duration metrics ignore the system and stay canonical.
        #expect(s.displayUnit(.reps, for: ex) == .count)
        #expect(s.displayUnit(.duration, for: ex) == .seconds)
    }

    @Test func perInstanceAndPreferenceStillWinOverGlobalDefault() {
        let s = store()
        s.unitSystem = .metric
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
        #expect(UnitSystem.imperial.defaultUnit(for: .load) == .pounds)
        #expect(UnitSystem.imperial.defaultUnit(for: .distance) == .miles)
        #expect(UnitSystem.metric.defaultUnit(for: .load) == .kilograms)
        #expect(UnitSystem.metric.defaultUnit(for: .distance) == .kilometers)
        // Duration and single-unit metrics don't vary by system.
        #expect(UnitSystem.imperial.defaultUnit(for: .duration) == nil)
        #expect(UnitSystem.metric.defaultUnit(for: .reps) == nil)
    }
}
