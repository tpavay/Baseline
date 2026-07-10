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

    @Test func persistsAcrossInstances() {
        let d = UserDefaults(suiteName: "wk-\(UUID().uuidString)")!
        let s1 = WorkoutStore(defaults: d)
        s1.create(title: "Persisted", goal: "test")
        s1.addBlock(name: "A", intent: nil)
        let s2 = WorkoutStore(defaults: d)
        #expect(s2.current?.title == "Persisted")
        #expect(s2.current?.blocks.count == 1)
    }
}
