import Foundation
import Testing
@testable import Baseline

struct WorkoutModelTests {

    /// Push day: an empty warm-up block + a strength block holding a 2-set bench press.
    private func sample() -> (workout: Workout, warmup: UUID, strength: UUID, bench: UUID) {
        var w = Workout(title: "Push day")
        let warm = w.addBlock(name: "Warm-up")
        let str = w.addBlock(name: "Strength", intent: "hypertrophy")
        var bench = PlannedExercise(exerciseName: "Bench press")
        bench.prescription.sets = [PlannedSet(reps: 8, load: 60), PlannedSet(reps: 8, load: 60)]
        w.addExercise(bench, toBlock: str)
        return (w, warm, str, bench.id)
    }

    // MARK: - Block level

    @Test func blockAddRemoveReorder() {
        var w = Workout(title: "x")
        let a = w.addBlock(name: "A"); _ = w.addBlock(name: "B"); let c = w.addBlock(name: "C")
        #expect(w.blocks.map(\.name) == ["A", "B", "C"])
        let moved = w.moveBlock(c, to: 0)
        #expect(moved)
        #expect(w.blocks.map(\.name) == ["C", "A", "B"])
        let removed = w.removeBlock(a)
        #expect(removed)
        #expect(w.blocks.map(\.name) == ["C", "B"])
    }

    @Test func duplicateBlockDeepCopiesIds() {
        var (w, _, str, _) = sample()
        let dup = w.duplicateBlock(str)
        #expect(dup != nil)
        #expect(w.blocks.count == 3)
        let orig = w.blocks.first { $0.id == str }!
        let copy = w.blocks.first { $0.id == dup }!
        #expect(copy.exercises.first?.exerciseName == orig.exercises.first?.exerciseName)
        #expect(copy.exercises.first?.id != orig.exercises.first?.id)                                   // fresh exercise id
        #expect(copy.exercises.first?.prescription.sets.first?.id != orig.exercises.first?.prescription.sets.first?.id) // fresh set id
    }

    // MARK: - Exercise level

    @Test func moveExerciseBetweenBlocks() {
        var (w, warm, str, bench) = sample()
        #expect(w.blocks.first { $0.id == str }?.exercises.count == 1)
        let moved = w.moveExercise(bench, toBlock: warm)
        #expect(moved)
        #expect(w.blocks.first { $0.id == str }?.exercises.isEmpty == true)
        #expect(w.blocks.first { $0.id == warm }?.exercises.first?.id == bench)     // same identity, new home
    }

    @Test func substituteKeepsIdentityAndPosition() {
        var (w, _, _, bench) = sample()
        let ok = w.substituteExercise(bench, withName: "Dumbbell press",
                                      prescription: Prescription(sets: [PlannedSet(reps: 10, load: 25)]))
        #expect(ok)
        let ex = w.allExercises.first { $0.id == bench }
        #expect(ex?.exerciseName == "Dumbbell press")
        #expect(ex?.prescription.sets.count == 1)
    }

    @Test func editingCoachGuidance() {
        var (w, _, _, bench) = sample()
        let ok = w.updateGuidance(bench, CoachGuidance(goal: "Chest strength", formCues: ["Brace"]))
        #expect(ok)
        #expect(w.allExercises.first { $0.id == bench }?.guidance?.formCues == ["Brace"])
    }

    // MARK: - Set level

    @Test func updateSingleSetLeavesOthersUntouched() {
        var (w, _, _, bench) = sample()
        let firstSet = w.allExercises.first { $0.id == bench }!.prescription.sets[0].id
        let ok = w.updateSet(firstSet) { $0.load = 70 }
        #expect(ok)
        let sets = w.allExercises.first { $0.id == bench }!.prescription.sets
        #expect(sets[0].load == 70)
        #expect(sets[1].load == 60)                       // the other set is not rewritten
    }

    @Test func addAndRemoveSet() {
        var (w, _, _, bench) = sample()
        let added = w.addSet(PlannedSet(reps: 6, load: 65), toExercise: bench)
        #expect(added)
        #expect(w.allExercises.first { $0.id == bench }?.prescription.sets.count == 3)
        let last = w.allExercises.first { $0.id == bench }!.prescription.sets.last!.id
        let removed = w.removeSet(last)
        #expect(removed)
        #expect(w.allExercises.first { $0.id == bench }?.prescription.sets.count == 2)
    }

    // MARK: - Planned vs performed

    @Test func startLogLinksBackAndNeverMutatesThePlan() {
        let (w, _, _, bench) = sample()
        var log = w.startLog()
        #expect(log.plannedWorkoutID == w.id)
        #expect(log.exercises.first?.plannedExerciseID == bench)

        // Log actuals + a note onto the performed record.
        log.exercises[0].status = .completed
        log.exercises[0].setLogs = [SetLog(plannedSetID: nil, reps: 8, load: 62.5)]
        log.exercises[0].athleteNotes = ["felt heavy on the last rep"]

        // The plan is untouched — still 2 planned sets at the planned load, no athlete note leaked in.
        #expect(w.allExercises.first?.prescription.sets.count == 2)
        #expect(w.allExercises.first?.prescription.sets.first?.load == 60)
    }

    @Test func performedLogRecordsActualsSeparately() {
        let (w, _, _, bench) = sample()          // bench planned: 2 sets @ 60
        var log = w.startLog()
        log.logSet(SetLog(reps: 8, load: 62.5), forPlanned: bench, name: "Bench press")
        log.setStatus(.completed, forPlanned: bench, name: "Bench press")
        log.addNote("felt good", forPlanned: bench, name: "Bench press")
        let perf = log.performed(forPlanned: bench)
        #expect(perf?.setLogs.first?.load == 62.5)
        #expect(perf?.status == .completed)
        #expect(perf?.athleteNotes == ["felt good"])
        // Plan is untouched by logging actuals.
        #expect(w.allExercises.first?.prescription.sets.first?.load == 60)
    }

    @Test func loggingAnAdHocExerciseCreatesAPerformedRecord() {
        let (w, _, _, _) = sample()
        var log = w.startLog()
        let adhoc = UUID()
        log.logSet(SetLog(reps: 10), forPlanned: adhoc, name: "Ad-hoc curl")
        #expect(log.performed(forPlanned: adhoc)?.exerciseName == "Ad-hoc curl")
    }

    // MARK: - Validation

    @Test func invalidEditsReturnFalse() {
        var (w, _, _, _) = sample()
        let a = w.removeExercise(UUID())
        let b = w.moveBlock(UUID(), to: 0)
        let c = w.updateSet(UUID()) { $0.reps = 5 }
        #expect(!a)
        #expect(!b)
        #expect(!c)
        #expect(w.duplicateBlock(UUID()) == nil)
    }
}
