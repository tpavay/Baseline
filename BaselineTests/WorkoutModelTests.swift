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

    @Test func moveSetValidatesItsOwningExerciseAndDestination() throws {
        var (workout, _, strength, benchID) = sample()
        let benchSets = try #require(workout.exercise(benchID)?.prescription.sets)
        var row = PlannedExercise(exerciseName: "Row")
        row.prescription.sets = [PlannedSet(duration: 60)]
        let added = workout.addExercise(row, toBlock: strength)
        #expect(added)
        let rowSetID = try #require(row.prescription.sets.first?.id)

        let movedToFront = workout.moveSet(benchSets[1].id, to: .index(0))
        #expect(movedToFront)
        #expect(workout.exercise(benchID)?.prescription.sets.map(\.id) == [benchSets[1].id, benchSets[0].id])
        let movedBeforeSibling = workout.moveSet(benchSets[1].id, to: .before(benchSets[0].id))
        let movedAcrossExercise = workout.moveSet(benchSets[0].id, to: .before(rowSetID))
        let movedOutOfRange = workout.moveSet(benchSets[0].id, to: .index(2))
        #expect(movedBeforeSibling)
        #expect(movedAcrossExercise == false)
        #expect(movedOutOfRange == false)
    }

    @Test func duplicateSetDeepCopiesSetAndAlternativeIDs() throws {
        var (workout, _, _, benchID) = sample()
        let alternative = PlannedSetAlternative(
            label: "Lighter",
            values: MetricValues([.load: 50])
        )
        let sourceID = try #require(workout.exercise(benchID)?.prescription.sets.first?.id)
        #expect(workout.updateSet(sourceID) { $0.alternatives = [alternative] })

        let duplicated = workout.duplicateSet(sourceID)
        let copyID = try #require(duplicated)
        let sets = try #require(workout.exercise(benchID)?.prescription.sets)
        let source = try #require(sets.first { $0.id == sourceID })
        let copy = try #require(sets.first { $0.id == copyID })

        #expect(copy.id != source.id)
        #expect(copy.values == source.values)
        #expect(copy.role == source.role)
        #expect(copy.alternatives.first?.id != source.alternatives.first?.id)
        #expect(copy.alternatives.first?.values == source.alternatives.first?.values)
        #expect(Array(sets.map(\.id).prefix(2)) == [sourceID, copyID])
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

    @Test func upsertSetLogEditsInPlaceKeyedByPlannedSet() {
        let (w, _, _, bench) = sample()
        var log = w.startLog()
        let plannedSetID = w.exercise(bench)!.prescription.sets[0].id

        // First upsert creates the actual; second edits the same one (no duplicate).
        log.upsertSetLog(forPlanned: bench, name: "Bench press", plannedSetID: plannedSetID) { $0.reps = 8 }
        log.upsertSetLog(forPlanned: bench, name: "Bench press", plannedSetID: plannedSetID) { $0.load = 65 }
        let logs = log.performed(forPlanned: bench)?.setLogs ?? []
        #expect(logs.count == 1)
        #expect(logs.first?.reps == 8)
        #expect(logs.first?.load == 65)
        #expect(log.setLog(forPlanned: bench, plannedSetID: plannedSetID)?.load == 65)
    }

    @Test func checkingEverySetIsWhatAutoCompletesTheExercise() {
        // Mirrors WorkoutView.toggleComplete: an exercise completes only once every planned set is
        // checked — completion is a set-level gesture, not an exercise-level button.
        let (w, _, _, bench) = sample()
        var log = w.startLog()
        let ids = w.exercise(bench)!.prescription.sets.map(\.id)

        func allChecked() -> Bool { ids.allSatisfy { log.setLog(forPlanned: bench, plannedSetID: $0)?.completed == true } }

        log.upsertSetLog(forPlanned: bench, name: "Bench press", plannedSetID: ids[0]) { $0.completed = true }
        #expect(!allChecked())          // one of two — not done yet
        #expect(log.performed(forPlanned: bench)?.status == .pending)

        log.upsertSetLog(forPlanned: bench, name: "Bench press", plannedSetID: ids[1]) { $0.completed = true }
        log.setStatus(allChecked() ? .completed : .pending, forPlanned: bench, name: "Bench press")
        #expect(log.performed(forPlanned: bench)?.status == .completed)

        // The plan is never touched by checking sets off.
        #expect(w.exercise(bench)?.prescription.sets.count == 2)
    }

    @Test func setLogCompletedSurvivesLegacyDecodeWithoutTheField() throws {
        // Dev logs written before `completed` existed must still decode (default false).
        let legacy = #"{"id":"\#(UUID().uuidString)","values":{"reps":8}}"#
        let decoded = try JSONDecoder().decode(SetLog.self, from: Data(legacy.utf8))
        #expect(decoded.completed == false)
        #expect(decoded.outcome == .pending)
        #expect(decoded.reps == 8)
    }

    @Test func setLogMigratesLegacyCompletionAndPersistsSkippedOutcome() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","values":{"reps":8},"completed":true}"#
        let completed = try JSONDecoder().decode(SetLog.self, from: Data(legacy.utf8))
        #expect(completed.outcome == .completed)
        #expect(completed.isHandled)

        let skipped = SetLog(reps: 8, outcome: .skipped)
        let decoded = try JSONDecoder().decode(SetLog.self, from: JSONEncoder().encode(skipped))
        #expect(decoded.outcome == .skipped)
        #expect(decoded.completed == false)
        #expect(decoded.isHandled)
    }

    @Test func exerciseSubstitutionCanApplyToOnlyOneRound() {
        let exercise = PlannedExercise(
            exerciseName: "Run",
            definitionId: "run",
            selectedMetrics: [.distance],
            prescription: Prescription(sets: [PlannedSet(distance: 100)])
        )
        let groupID = UUID()
        var log = WorkoutLog(exercises: [
            PerformedExercise(plannedExerciseID: exercise.id, exerciseName: exercise.exerciseName),
        ])
        let substitution = LoggedExerciseSubstitution(
            exerciseName: "Treadmill Run",
            definitionId: "treadmill_run",
            selectedMetrics: [.distance],
            displayUnits: [:],
            prescription: exercise.prescription
        )

        log.setExerciseAdjustment(
            plannedExerciseID: exercise.id,
            groupID: groupID,
            iteration: 2,
            outcome: .substituted,
            substitution: substitution,
            name: exercise.exerciseName
        )

        #expect(log.effectiveExercise(for: exercise, groupID: groupID, iteration: 1).definitionId == "run")
        #expect(log.effectiveExercise(for: exercise, groupID: groupID, iteration: 2).definitionId == "treadmill_run")
        #expect(log.performed(forPlanned: exercise.id)?.status == .modified)
    }

    @Test func oneRoundCanRestoreOriginalAfterAllRoundsWereRemoved() {
        let exerciseID = UUID()
        let groupID = UUID()
        var log = WorkoutLog(exercises: [
            PerformedExercise(plannedExerciseID: exerciseID, exerciseName: "Run"),
        ])
        log.setExerciseAdjustment(
            plannedExerciseID: exerciseID,
            groupID: groupID,
            outcome: .skipped,
            name: "Run"
        )
        #expect(log.isExerciseSkipped(exerciseID, groupID: groupID, iteration: 1))
        #expect(log.isExerciseSkipped(exerciseID, groupID: groupID, iteration: 2))

        log.restoreExercise(
            plannedExerciseID: exerciseID,
            groupID: groupID,
            iteration: 2,
            name: "Run"
        )
        #expect(log.isExerciseSkipped(exerciseID, groupID: groupID, iteration: 1))
        #expect(log.isExerciseSkipped(exerciseID, groupID: groupID, iteration: 2) == false)

        log.restoreExercise(plannedExerciseID: exerciseID, groupID: groupID, name: "Run")
        #expect(log.isExerciseSkipped(exerciseID, groupID: groupID, iteration: 1) == false)
        #expect(log.exerciseAdjustments.isEmpty)
    }

    @Test func legacyFlatBlockDecodesAsExerciseNodes() throws {
        struct LegacyBlock: Encodable {
            let id: UUID
            let name: String
            let intent: String?
            let exercises: [PlannedExercise]
            let isDefault: Bool
        }
        let exercise = PlannedExercise(exerciseName: "Run", prescription: Prescription(sets: [PlannedSet(duration: 600)]))
        let data = try JSONEncoder().encode(LegacyBlock(id: UUID(), name: "Main", intent: nil,
                                                       exercises: [exercise], isDefault: true))
        let block = try JSONDecoder().decode(WorkoutBlock.self, from: data)
        #expect(block.nodes.count == 1)
        #expect(block.exercises.first?.id == exercise.id)
    }

    @Test func progressionProducesExpectedRoundTargetsWithoutChangingTemplate() {
        let set = PlannedSet(calories: 10, progressions: [
            MetricProgression(metric: .calories, delta: 1, every: 1, unit: .round),
        ])
        #expect(set.expectedValues(iteration: 1)[.calories] == 10)
        #expect(set.expectedValues(iteration: 7)[.calories] == 16)
        #expect(set.calories == 10)
    }

    @Test func repeatedGroupActualsAreKeyedByIteration() throws {
        let exerciseID = UUID()
        let setID = UUID()
        let groupID = UUID()
        var log = WorkoutLog(exercises: [PerformedExercise(plannedExerciseID: exerciseID, exerciseName: "Wall Balls")])
        log.upsertSetLog(forPlanned: exerciseID, name: "Wall Balls", plannedSetID: setID,
                         groupID: groupID, iteration: 1) { $0.reps = 12 }
        log.upsertSetLog(forPlanned: exerciseID, name: "Wall Balls", plannedSetID: setID,
                         groupID: groupID, iteration: 2) { $0.reps = 15 }
        #expect(log.performed(forPlanned: exerciseID)?.setLogs.count == 2)
        #expect(log.setLog(forPlanned: exerciseID, plannedSetID: setID, groupID: groupID, iteration: 1)?.reps == 12)
        #expect(log.setLog(forPlanned: exerciseID, plannedSetID: setID, groupID: groupID, iteration: 2)?.reps == 15)
    }

    @Test func startLogSnapshotsGroupsAndDefaultsChoices() throws {
        let bikeErg = PlannedExercise(exerciseName: "BikeErg")
        let echo = PlannedExercise(exerciseName: "Echo Bike")
        let choice = WorkoutChoice(label: "Choose a bike", options: [.exercise(bikeErg), .exercise(echo)])
        let group = WorkoutGroup(label: "AMRAP", execution: GroupExecution(repetition: .until(seconds: 4_200)),
                                 children: [.choice(choice)])
        let workout = Workout(title: "Hybrid", blocks: [WorkoutBlock(name: "Main", nodes: [.group(group)])])
        let log = workout.startLog()
        #expect(log.groups.first?.targetDurationSeconds == 4_200)
        #expect(log.selectedOptions(for: choice.id) == [bikeErg.id])
    }

    @Test func addUserBlockDropsTheEmptyDefaultButKeepsAPopulatedOne() {
        // Empty default → replaced by the user's block (no phantom "Main").
        var flat = Workout(title: "Flat")
        flat.blocks = [WorkoutBlock(name: "", isDefault: true)]
        let id = flat.addUserBlock(name: "")
        #expect(flat.blocks.count == 1)
        #expect(flat.blocks.first?.id == id)
        #expect(flat.blocks.first?.isDefault == false)

        // Default holding loose exercises → kept; the user's block is added alongside.
        var loose = Workout(title: "Loose")
        var def = WorkoutBlock(name: "", isDefault: true)
        def.nodes = [.exercise(PlannedExercise(exerciseName: "Curl"))]
        loose.blocks = [def]
        loose.addUserBlock(name: "")
        #expect(loose.blocks.count == 2)
        #expect(loose.blocks.contains { $0.isDefault && $0.exercises.count == 1 })
    }

    @Test func workoutDisplayLabelRoundTripsWithoutChangingCatalogIdentity() throws {
        let exercise = PlannedExercise(
            exerciseName: "Deadlift",
            displayLabel: "Option B",
            definitionId: "deadlift",
            selectedMetrics: [.reps, .load]
        )
        let workout = Workout(
            title: "Imported",
            blocks: [WorkoutBlock(name: "Main", exercises: [exercise])]
        )

        let decoded = try JSONDecoder().decode(Workout.self, from: JSONEncoder().encode(workout))
        let restored = try #require(decoded.allExercises.first)

        #expect(restored.displayLabel == "Option B")
        #expect(restored.exerciseName == "Deadlift")
        #expect(restored.definitionId == "deadlift")
    }

    @Test func convertingChoiceToRequiredGroupPreservesOrderIdentityAndPrescription() throws {
        let deadlift = PlannedExercise(
            exerciseName: "Deadlift",
            definitionId: "deadlift",
            prescription: Prescription(sets: [PlannedSet(reps: 12)])
        )
        let burpee = PlannedExercise(
            exerciseName: "Lateral Burpee Over Barbell",
            definitionId: "lateral_burpee_over_barbell",
            prescription: Prescription(sets: [PlannedSet(reps: 12)])
        )
        let choice = WorkoutChoice(
            label: "Option B",
            options: [.exercise(deadlift), .exercise(burpee)]
        )
        var workout = Workout(
            title: "AMRAP",
            blocks: [WorkoutBlock(name: "Main", nodes: [.choice(choice)])]
        )

        let converted = workout.convertChoiceToRequiredGroup(choice.id)
        #expect(converted)
        let group = try #require(workout.allGroups.first)

        #expect(workout.allChoices.isEmpty)
        #expect(group.id == choice.id)
        #expect(group.children.map(\.id) == [deadlift.id, burpee.id])
        #expect(group.children.flatMap(\.exercises).map { $0.prescription.sets.first?.reps } == [12, 12])
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
