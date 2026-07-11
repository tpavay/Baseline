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
        #expect(s.addBlock(name: "Warm-up", intent: nil))
        #expect(s.addBlock(name: "Strength", intent: "hypertrophy"))
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
        #expect(s.compactSummary == nil)                    // no workout yet
        s.create(title: "MED", goal: nil)
        s.addExercise(name: "Row", toBlockNamed: "Main", sets: 3, reps: nil, load: nil, durationSeconds: 600)
        let compact = s.compactSummary ?? ""
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
        s.addExercise(ex, toBlockID: s.current!.blocks.first!.id)
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
}
