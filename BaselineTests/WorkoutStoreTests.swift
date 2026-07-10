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
        #expect(s.addExercise(name: "Bench press", toBlockNamed: "Strength", sets: 3, reps: 8, load: 60, durationSeconds: nil))
        #expect(s.current?.blocks.first { $0.name == "Strength" }?.exercises.first?.exerciseName == "Bench press")
        #expect(s.current?.allExercises.first?.prescription.sets.count == 3)
        // Move by name, case-insensitive + fuzzy ("bench" → "Bench press", "warm-up" → "Warm-up").
        #expect(s.moveExercise(named: "bench", toBlockNamed: "warm-up"))
        #expect(s.current?.blocks.first { $0.name == "Warm-up" }?.exercises.count == 1)
        #expect(s.current?.blocks.first { $0.name == "Strength" }?.exercises.isEmpty == true)
    }

    @Test func updateSingleSetByNumberLeavesOthers() {
        let s = store()
        s.create(title: "x", goal: nil)
        s.addBlock(name: "A", intent: nil)
        s.addExercise(name: "Squat", toBlockNamed: "A", sets: 3, reps: 5, load: 100, durationSeconds: nil)
        #expect(s.updateSet(exerciseNamed: "Squat", setNumber: 2, reps: nil, load: 110, durationSeconds: nil, rpe: 9))
        let sets = s.current!.allExercises.first!.prescription.sets
        #expect(sets[1].load == 110)
        #expect(sets[1].rpe == 9)
        #expect(sets[0].load == 100)      // untouched
    }

    @Test func unknownNamesAndBadSetsFail() {
        let s = store()
        s.create(title: "x", goal: nil)
        #expect(!s.moveExercise(named: "ghost", toBlockNamed: "nowhere"))
        #expect(!s.updateSet(exerciseNamed: "ghost", setNumber: 1, reps: 5, load: nil, durationSeconds: nil, rpe: nil))
        #expect(!s.addExercise(name: "X", toBlockNamed: "missing block", sets: 1, reps: nil, load: nil, durationSeconds: nil))
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
