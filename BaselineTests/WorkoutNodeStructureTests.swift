import Foundation
import Testing
@testable import Baseline

/// Wave 8: the shared recursive node API and the advanced node/prescription tools built on it.
struct WorkoutNodeStructureTests {

    /// One block holding an exercise, a repeated group (exercise + rest), and a two-option choice.
    private func nested() -> (
        workout: Workout,
        blockID: UUID,
        run: PlannedExercise,
        group: WorkoutGroup,
        sled: PlannedExercise,
        rest: PlannedRest,
        choice: WorkoutChoice,
        echo: PlannedExercise,
        bike: PlannedExercise
    ) {
        let run = PlannedExercise(exerciseName: "Run", prescription: .init(sets: [PlannedSet(distance: 1000)]))
        let sled = PlannedExercise(exerciseName: "Sled Push", prescription: .init(sets: [PlannedSet(distance: 20)]))
        let rest = PlannedRest(durationSeconds: 60, placement: .inline, label: "Rest", guidance: nil)
        let group = WorkoutGroup(
            label: "Circuit",
            execution: GroupExecution(repetition: .count(3)),
            children: [.exercise(sled), .rest(rest)]
        )
        let echo = PlannedExercise(exerciseName: "Echo Bike")
        let bike = PlannedExercise(exerciseName: "Concept2 Bike")
        let choice = WorkoutChoice(label: "Bike modality", options: [.exercise(echo), .exercise(bike)])
        var workout = Workout(title: "Nested")
        let blockID = workout.addBlock(name: "Main")
        workout.addNode(.exercise(run), toBlock: blockID)
        workout.addNode(.group(group), toBlock: blockID)
        workout.addNode(.choice(choice), toBlock: blockID)
        return (workout, blockID, run, group, sled, rest, choice, echo, bike)
    }

    // MARK: - Locate / find on the one recursive walk

    @Test func locatesEveryNodeWithItsParentContainer() throws {
        let (w, blockID, run, group, sled, rest, choice, echo, _) = nested()

        let runLocation = try #require(w.locateNode(run.id))
        #expect(runLocation.container == .block(blockID))
        #expect(runLocation.index == 0)

        let sledLocation = try #require(w.locateNode(sled.id))
        #expect(sledLocation.container == .group(group.id))
        #expect(sledLocation.index == 0)

        let restLocation = try #require(w.locateNode(rest.id))
        #expect(restLocation.container == .group(group.id))
        #expect(restLocation.index == 1)

        let echoLocation = try #require(w.locateNode(echo.id))
        #expect(echoLocation.container == .choice(choice.id))
        #expect(echoLocation.index == 0)

        #expect(w.locateNode(UUID()) == nil)
        #expect(w.findNode(group.id) != nil)
        #expect(w.nodeContainer(blockID) == .block(blockID))
        #expect(w.nodeContainer(group.id) == .group(group.id))
        #expect(w.nodeContainer(choice.id) == .choice(choice.id))
        #expect(w.nodeContainer(run.id) == nil)   // an exercise owns no node list
    }

    @Test func containsNodeSeesTheWholeSubtree() {
        let (w, _, run, group, sled, _, choice, echo, _) = nested()
        let groupNode = w.findNode(group.id)
        #expect(groupNode?.containsNode(sled.id) == true)
        #expect(groupNode?.containsNode(group.id) == true)
        #expect(groupNode?.containsNode(run.id) == false)
        let choiceNode = w.findNode(choice.id)
        #expect(choiceNode?.containsNode(echo.id) == true)
    }

    // MARK: - moveNode: the general reorder-and-reparent operation

    @Test func moveNodeNestsATopLevelExerciseIntoAGroup() throws {
        var (w, blockID, run, group, _, _, _, _, _) = nested()
        let outcome1 = w.moveNode(run.id, into: group.id, at: 1)
        #expect(outcome1 == nil)
        let location = try #require(w.locateNode(run.id))
        #expect(location.container == .group(group.id))
        #expect(location.index == 1)
        // No orphan, no duplicate: the run exists exactly once.
        #expect(w.allExercises.filter { $0.id == run.id }.count == 1)
        #expect(w.blocks.first { $0.id == blockID }?.nodes.count == 2)
    }

    @Test func moveNodePullsANestedExerciseOutOfItsGroup() throws {
        var (w, blockID, _, group, sled, _, _, _, _) = nested()
        let outcome2 = w.moveNode(sled.id, into: blockID, at: 0)
        #expect(outcome2 == nil)
        let location = try #require(w.locateNode(sled.id))
        #expect(location.container == .block(blockID))
        #expect(location.index == 0)
        guard case .group(let updated)? = w.findNode(group.id) else {
            Issue.record("group missing"); return
        }
        #expect(updated.children.count == 1)
    }

    @Test func moveNodeReordersChoiceOptions() throws {
        var (w, _, _, _, _, _, choice, echo, bike) = nested()
        let outcome3 = w.moveNode(bike.id, into: choice.id, at: 0)
        #expect(outcome3 == nil)
        guard case .choice(let updated)? = w.findNode(choice.id) else {
            Issue.record("choice missing"); return
        }
        #expect(updated.options.map(\.id) == [bike.id, echo.id])
    }

    @Test func moveNodeMovesAWholeGroupSubtreeIntact() throws {
        var (w, _, _, group, sled, rest, _, _, _) = nested()
        let second = w.addBlock(name: "Second")
        let outcome4 = w.moveNode(group.id, into: second, at: 0)
        #expect(outcome4 == nil)
        let location = try #require(w.locateNode(group.id))
        #expect(location.container == .block(second))
        guard case .group(let moved)? = w.findNode(group.id) else {
            Issue.record("group missing"); return
        }
        // Children moved with it, identities preserved.
        #expect(moved.children.map(\.id) == [sled.id, rest.id])
    }

    @Test func moveNodeRefusesCycles() {
        var (w, _, _, group, sled, _, choice, _, _) = nested()
        // A group can't move into itself or its own child list.
        let outcome5 = w.moveNode(group.id, into: group.id, at: 0)
        #expect(outcome5 == .cycle)
        // Nest a choice inside the group, then try to move the group into that choice.
        let outcome6 = w.moveNode(choice.id, into: group.id, at: 0)
        #expect(outcome6 == nil)
        let outcome7 = w.moveNode(group.id, into: choice.id, at: 0)
        #expect(outcome7 == .cycle)
        // The workout is unchanged by the rejected moves: sled still lives in the group.
        #expect(w.locateNode(sled.id)?.container == .group(group.id))
    }

    @Test func moveNodeRefusesARestAsChoiceOption() {
        var (w, _, _, group, _, rest, choice, _, _) = nested()
        let outcome8 = w.moveNode(rest.id, into: choice.id, at: 0)
        #expect(outcome8 == .invalidChild)
        #expect(w.locateNode(rest.id)?.container == .group(group.id))
    }

    @Test func moveNodeValidatesBoundsAgainstTheFinalOrder() {
        var (w, blockID, run, _, _, _, _, _, _) = nested()
        // Same-container move: the final order has 3 nodes, so index 3 is out of bounds…
        let outOfBounds = w.moveNode(run.id, into: blockID, at: 3)
        #expect(outOfBounds == .indexOutOfBounds(max: 2))
        // …and index 2 (the end after removal) is valid.
        let outcome9 = w.moveNode(run.id, into: blockID, at: 2)
        #expect(outcome9 == nil)
        #expect(w.blocks.first { $0.id == blockID }?.nodes.last?.id == run.id)
        let outcome10 = w.moveNode(run.id, into: UUID(), at: 0)
        #expect(outcome10 == .containerNotFound)
        let outcome11 = w.moveNode(UUID(), into: blockID, at: 0)
        #expect(outcome11 == .nodeNotFound)
    }

    @Test func moveNodeRefusesToEmptyAChoiceAndClampsSelectionOtherwise() {
        var (w, blockID, _, _, _, _, choice, echo, bike) = nested()
        // Make it a pick-2 choice, then move one option out: selection clamps to the 1 remaining.
        w.updateChoice(choice.id) { $0.selectionCount = 2 }
        let outcome12 = w.moveNode(echo.id, into: blockID, at: 0)
        #expect(outcome12 == nil)
        guard case .choice(let afterOne)? = w.findNode(choice.id) else {
            Issue.record("choice missing"); return
        }
        #expect(afterOne.selectionCount == 1)
        // The last option can't leave.
        let outcome13 = w.moveNode(bike.id, into: blockID, at: 0)
        #expect(outcome13 == .lastChoiceOption)
        #expect(w.locateNode(bike.id)?.container == .choice(choice.id))
    }

    // MARK: - removeNode

    @Test func removeNodeReturnsTheRemovedSubtree() throws {
        var (w, _, _, group, sled, rest, _, _, _) = nested()
        guard case .success(let removed) = w.removeNode(group.id) else {
            Issue.record("remove failed"); return
        }
        #expect(removed.id == group.id)
        #expect(removed.exercises.map(\.id) == [sled.id])
        #expect(w.findNode(group.id) == nil)
        #expect(w.findNode(sled.id) == nil)
        #expect(w.findNode(rest.id) == nil)
    }

    @Test func removeNodeRefusesTheLastChoiceOptionAndClampsSelection() {
        var (w, _, _, _, _, _, choice, echo, bike) = nested()
        w.updateChoice(choice.id) { $0.selectionCount = 2 }
        guard case .success = w.removeNode(echo.id) else {
            Issue.record("remove failed"); return
        }
        guard case .choice(let updated)? = w.findNode(choice.id) else {
            Issue.record("choice missing"); return
        }
        #expect(updated.selectionCount == 1)
        guard case .failure(.lastChoiceOption) = w.removeNode(bike.id) else {
            Issue.record("expected lastChoiceOption"); return
        }
        #expect(w.findNode(bike.id) != nil)
    }

    // MARK: - insertNode

    @Test func insertNodeValidatesContainerAndBounds() {
        var (w, blockID, _, group, _, _, _, _, _) = nested()
        let extra = PlannedRest(durationSeconds: 30, placement: .inline, label: "Breather", guidance: nil)
        let outcome14 = w.insertNode(.rest(extra), into: UUID(), at: nil)
        #expect(outcome14 == false)
        let outcome15 = w.insertNode(.rest(extra), into: blockID, at: 99)
        #expect(outcome15 == false)
        #expect(w.findNode(extra.id) == nil)
        let outcome16 = w.insertNode(.rest(extra), into: group.id, at: 0)
        #expect(outcome16 == true)
        #expect(w.locateNode(extra.id)?.container == .group(group.id))
    }

    // MARK: - Typed updates through the one API

    @Test func typedUpdatesRejectWrongNodeTypes() {
        var (w, _, run, group, _, rest, choice, _, _) = nested()
        let outcome17 = w.updateGroup(run.id) { _ in }
        #expect(outcome17 == false)
        let outcome18 = w.updateChoice(group.id) { _ in }
        #expect(outcome18 == false)
        let outcome19 = w.updateRest(choice.id) { _ in }
        #expect(outcome19 == false)
        let outcome20 = w.updateExercise(rest.id) { _ in }
        #expect(outcome20 == false)
        let outcome21 = w.convertChoiceToRequiredGroup(group.id)
        #expect(outcome21 == false)
    }

    @Test func updateRestAndChoiceEditInPlaceAnywhere() {
        var (w, _, _, _, _, rest, choice, _, _) = nested()
        let restUpdated = w.updateRest(rest.id) { $0.durationSeconds = 90; $0.label = "Walk" }
        #expect(restUpdated)
        guard case .rest(let updatedRest)? = w.findNode(rest.id) else {
            Issue.record("rest missing"); return
        }
        #expect(updatedRest.durationSeconds == 90)
        #expect(updatedRest.label == "Walk")
        let choiceUpdated = w.updateChoice(choice.id) { $0.label = "Erg modality" }
        #expect(choiceUpdated)
        guard case .choice(let updatedChoice)? = w.findNode(choice.id) else {
            Issue.record("choice missing"); return
        }
        #expect(updatedChoice.label == "Erg modality")
    }

    @Test func convertChoiceToRequiredGroupKeepsIdentityAndChildren() throws {
        var (w, _, _, _, _, _, choice, echo, bike) = nested()
        let outcome22 = w.convertChoiceToRequiredGroup(choice.id)
        #expect(outcome22)
        guard case .group(let converted)? = w.findNode(choice.id) else {
            Issue.record("converted group missing"); return
        }
        #expect(converted.id == choice.id)
        #expect(converted.label == choice.label)
        #expect(converted.children.map(\.id) == [echo.id, bike.id])
        #expect(converted.execution.repetition == .once)
    }
}

// MARK: - Store handlers (Wave 8 tools through the shared mutation envelope)

@MainActor
struct WorkoutNodeStructureStoreTests {

    private func store() -> WorkoutStore {
        WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "wk8-\(UUID().uuidString)")!)
    }

    /// A store whose current workout holds the nested fixture, plus the interesting IDs.
    private func nestedStore() -> (
        store: WorkoutStore,
        blockID: UUID,
        runID: UUID,
        groupID: UUID,
        sledID: UUID,
        restID: UUID,
        choiceID: UUID,
        echoID: UUID,
        bikeID: UUID
    ) {
        let s = store()
        s.create(title: "Nested", goal: nil)
        let run = PlannedExercise(
            exerciseName: "Treadmill Run",
            definitionId: "treadmill_run",
            selectedMetrics: [.distance, .duration],
            prescription: .init(sets: [PlannedSet(distance: 1000)])
        )
        let sled = PlannedExercise(
            exerciseName: "Sled Push",
            definitionId: "sled_push",
            selectedMetrics: [.distance, .load],
            prescription: .init(sets: [PlannedSet(load: 60, distance: 20)])
        )
        let rest = PlannedRest(durationSeconds: 60, placement: .inline, label: "Rest", guidance: nil)
        let group = WorkoutGroup(
            label: "Circuit",
            execution: GroupExecution(repetition: .count(3)),
            children: [.exercise(sled), .rest(rest)]
        )
        let echo = PlannedExercise(exerciseName: "Echo Bike", definitionId: "echo_bike")
        let bike = PlannedExercise(exerciseName: "Concept2 Bike", definitionId: "concept2_bike")
        let choice = WorkoutChoice(label: "Bike modality", options: [.exercise(echo), .exercise(bike)])
        var blockID = UUID()
        s.edit(.plan) { workout in
            blockID = workout.blocks[0].id
            workout.blocks[0].nodes = [.exercise(run), .group(group), .choice(choice)]
        }
        return (s, blockID, run.id, group.id, sled.id, rest.id, choice.id, echo.id, bike.id)
    }

    private func token(_ s: WorkoutStore) throws -> UUID {
        try #require(s.mutationTarget(.plan)?.revisionToken)
    }

    private func requireReceipt(_ outcome: WorkoutStore.EditOutcome) throws -> WorkoutMutationReceipt {
        guard case .mutated(let receipt) = outcome else {
            Issue.record("expected a mutation receipt, got \(outcome)")
            throw TestAbort.abort
        }
        return receipt
    }

    private enum TestAbort: Error { case abort }

    @Test func updateGroupPatchesEveryLeverWithThreeStateSemantics() throws {
        let (s, _, _, groupID, _, _, _, _, _) = nestedStore()
        let outcome = s.updateGroup(
            groupID: groupID,
            patch: WorkoutGroupPatch(
                label: .set("Engine Circuit"),
                guidance: .set("Move with intent"),
                phase: .set(.main),
                doseLayer: .set(.med),
                isOptional: .set(true),
                repetition: .set(.until(seconds: 1200)),
                cadence: .set(StartCadence(intervalSeconds: 60, scope: .child)),
                totalTargets: .set(.init(metrics: [.calories: .set(100)])),
                adjustments: .set([MetricAdjustment(metric: .load, step: 5, minimum: 20, maximum: 60)])
            ),
            expectedRevisionToken: try token(s)
        )
        #expect(outcome.succeeded)
        guard case .group(let updated)? = s.current?.findNode(groupID) else {
            Issue.record("group missing"); return
        }
        #expect(updated.label == "Engine Circuit")
        #expect(updated.phase == .main)
        #expect(updated.doseLayer == .med)
        #expect(updated.isOptional)
        #expect(updated.execution.repetition == .until(seconds: 1200))
        #expect(updated.execution.cadence == StartCadence(intervalSeconds: 60, scope: .child))
        #expect(updated.execution.totalTargets[.calories] == 100)
        #expect(updated.execution.adjustments.count == 1)
        #expect(updated.guidance?.formCues == ["Move with intent"])

        // Clear the nullable levers; leave the rest untouched.
        let cleared = s.updateGroup(
            groupID: groupID,
            patch: WorkoutGroupPatch(
                phase: .clear,
                doseLayer: .clear,
                cadence: .clear,
                totalTargets: .clear,
                adjustments: .clear
            ),
            expectedRevisionToken: try token(s)
        )
        #expect(cleared.succeeded)
        guard case .group(let after)? = s.current?.findNode(groupID) else {
            Issue.record("group missing"); return
        }
        #expect(after.phase == nil)
        #expect(after.doseLayer == nil)
        #expect(after.execution.cadence == nil)
        #expect(after.execution.totalTargets.isEmpty)
        #expect(after.execution.adjustments.isEmpty)
        #expect(after.label == "Engine Circuit")                       // omitted = unchanged
        #expect(after.execution.repetition == .until(seconds: 1200))   // omitted = unchanged
    }

    @Test func updateGroupRejectsInvalidPayloads() throws {
        let (s, _, runID, groupID, _, _, _, _, _) = nestedStore()
        #expect(!s.updateGroup(
            groupID: runID,
            patch: WorkoutGroupPatch(label: .set("Nope")),
            expectedRevisionToken: try token(s)
        ).succeeded)
        #expect(!s.updateGroup(
            groupID: groupID,
            patch: WorkoutGroupPatch(totalTargets: .set(.init(metrics: [.reps: .set(2.5)]))),
            expectedRevisionToken: try token(s)
        ).succeeded)
        #expect(!s.updateGroup(
            groupID: groupID,
            patch: WorkoutGroupPatch(adjustments: .set([
                MetricAdjustment(metric: .load, step: 5, minimum: 60, maximum: 20),
            ])),
            expectedRevisionToken: try token(s)
        ).succeeded)
    }

    @Test func updateChoiceValidatesSelectionCountAgainstOptions() throws {
        let (s, _, _, _, _, _, choiceID, _, _) = nestedStore()
        #expect(!s.updateChoice(
            choiceID: choiceID,
            label: .unchanged,
            selectionCount: .set(3),
            expectedRevisionToken: try token(s)
        ).succeeded)
        #expect(s.updateChoice(
            choiceID: choiceID,
            label: .set("Erg pick"),
            selectionCount: .set(2),
            expectedRevisionToken: try token(s)
        ).succeeded)
        guard case .choice(let updated)? = s.current?.findNode(choiceID) else {
            Issue.record("choice missing"); return
        }
        #expect(updated.label == "Erg pick")
        #expect(updated.selectionCount == 2)
    }

    @Test func convertChoiceToGroupIsUndoable() throws {
        let (s, _, _, _, _, _, choiceID, echoID, bikeID) = nestedStore()
        let receipt = try requireReceipt(s.convertChoiceToGroup(
            choiceID: choiceID,
            expectedRevisionToken: try token(s)
        ))
        guard case .group(let converted)? = s.current?.findNode(choiceID) else {
            Issue.record("converted group missing"); return
        }
        #expect(converted.children.map(\.id) == [echoID, bikeID])

        #expect(s.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ).succeeded)
        guard case .choice(let restored)? = s.current?.findNode(choiceID) else {
            Issue.record("choice not restored"); return
        }
        #expect(restored.options.map(\.id) == [echoID, bikeID])
        #expect(restored.selectionCount == 1)
    }

    @Test func updateRestAndAddRestManageRestNodes() throws {
        let (s, blockID, _, groupID, _, restID, choiceID, _, _) = nestedStore()
        #expect(s.updateRest(
            restID: restID,
            patch: PlannedRestPatch(
                label: .set("Walk it off"),
                placement: .set(.afterEveryRepetition),
                durationSeconds: .set(90),
                guidance: .set("Nasal breathing")
            ),
            expectedRevisionToken: try token(s)
        ).succeeded)
        guard case .rest(let updated)? = s.current?.findNode(restID) else {
            Issue.record("rest missing"); return
        }
        #expect(updated.label == "Walk it off")
        #expect(updated.placement == .afterEveryRepetition)
        #expect(updated.durationSeconds == 90)
        #expect(updated.guidance == "Nasal breathing")

        #expect(s.updateRest(
            restID: restID,
            patch: PlannedRestPatch(durationSeconds: .clear, guidance: .clear),
            expectedRevisionToken: try token(s)
        ).succeeded)
        guard case .rest(let cleared)? = s.current?.findNode(restID) else {
            Issue.record("rest missing"); return
        }
        #expect(cleared.durationSeconds == nil)
        #expect(cleared.guidance == nil)

        // add_rest appends to a group, refuses a choice parent, and validates bounds.
        let added = try requireReceipt(s.addRest(
            parentID: groupID,
            atIndex: 0,
            durationSeconds: 30,
            placement: .inline,
            label: nil,
            guidance: nil,
            expectedRevisionToken: try token(s)
        ))
        let addedRestID = try #require(added.diff.changes.first?.entityID)
        #expect(s.current?.locateNode(addedRestID)?.container == .group(groupID))
        guard case .rest(let addedRest)? = s.current?.findNode(addedRestID) else {
            Issue.record("added rest missing"); return
        }
        #expect(addedRest.label == "Rest")
        #expect(!s.addRest(
            parentID: choiceID, atIndex: nil, durationSeconds: nil, placement: .inline,
            label: nil, guidance: nil, expectedRevisionToken: try token(s)
        ).succeeded)
        #expect(!s.addRest(
            parentID: blockID, atIndex: 99, durationSeconds: nil, placement: .inline,
            label: nil, guidance: nil, expectedRevisionToken: try token(s)
        ).succeeded)
    }

    @Test func moveNodeNestsAndUndoRestoresTheExactStructure() throws {
        let (s, blockID, runID, groupID, _, _, _, _, _) = nestedStore()
        let before = s.current
        let receipt = try requireReceipt(s.moveNode(
            nodeID: runID,
            toParentID: groupID,
            toIndex: 0,
            expectedRevisionToken: try token(s)
        ))
        #expect(s.current?.locateNode(runID)?.container == .group(groupID))

        #expect(s.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ).succeeded)
        #expect(s.current == before)
        #expect(s.current?.locateNode(runID)?.container == .block(blockID))
    }

    @Test func moveNodeRejectsTruthfullyWithoutMutating() throws {
        let (s, _, _, groupID, _, restID, choiceID, _, _) = nestedStore()
        let before = s.current
        guard case .notFound(let cycleMessage) = s.moveNode(
            nodeID: groupID, toParentID: groupID, toIndex: 0, expectedRevisionToken: try token(s)
        ) else {
            Issue.record("expected cycle rejection"); return
        }
        #expect(cycleMessage.contains("into itself or its own children"))
        guard case .notFound(let restMessage) = s.moveNode(
            nodeID: restID, toParentID: choiceID, toIndex: 0, expectedRevisionToken: try token(s)
        ) else {
            Issue.record("expected rest rejection"); return
        }
        #expect(restMessage.contains("can't be a choice option"))
        #expect(s.current == before)
    }

    @Test func moveNodeOutOfAChoiceDropsItsStaleSelection() throws {
        let (s, blockID, _, _, _, _, choiceID, echoID, bikeID) = nestedStore()
        s.startWorkout()
        s.editLog { log in
            log.selectOption(echoID, for: choiceID, selectionCount: 1)
        }
        #expect(s.currentLog?.selectedOptions(for: choiceID) == [echoID])
        #expect(s.moveNode(
            nodeID: echoID,
            toParentID: blockID,
            toIndex: 0,
            expectedRevisionToken: try token(s)
        ).succeeded)
        #expect(s.currentLog?.selectedOptions(for: choiceID).contains(echoID) == false)
        _ = bikeID
    }

    @Test func removeNodePurgesTheSubtreeLogAndUndoRestoresIt() throws {
        let (s, _, _, groupID, sledID, _, choiceID, _, _) = nestedStore()
        s.startWorkout()
        let sledSetID = try #require(s.current?.exercise(sledID)?.prescription.sets.first?.id)
        s.editLog { log in
            log.upsertSetLog(forPlanned: sledID, name: "Sled Push", plannedSetID: sledSetID,
                             groupID: groupID, iteration: 1) { row in
                row.load = 70
                row.outcome = .completed
            }
        }
        #expect(s.currentLog?.performed(forPlanned: sledID)?.setLogs.count == 1)

        let receipt = try requireReceipt(s.removeNode(
            nodeID: groupID,
            expectedRevisionToken: try token(s)
        ))
        #expect(s.current?.findNode(groupID) == nil)
        #expect(s.current?.findNode(sledID) == nil)
        // The performed record went with the structure - nothing can resurrect deleted work.
        #expect(s.currentLog?.performed(forPlanned: sledID) == nil)
        #expect(s.currentLog?.groups.contains { $0.plannedGroupID == groupID } == false)

        #expect(s.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ).succeeded)
        #expect(s.current?.findNode(groupID) != nil)
        #expect(s.currentLog?.performed(forPlanned: sledID)?.setLogs.first?.load == 70)
        _ = choiceID
    }

    @Test func removeNodeRefusesTheLastChoiceOption() throws {
        let (s, _, _, _, _, _, choiceID, echoID, bikeID) = nestedStore()
        #expect(s.removeNode(nodeID: echoID, expectedRevisionToken: try token(s)).succeeded)
        guard case .notFound(let message) = s.removeNode(
            nodeID: bikeID,
            expectedRevisionToken: try token(s)
        ) else {
            Issue.record("expected last-option rejection"); return
        }
        #expect(message.contains("only option"))
        #expect(s.current?.findNode(bikeID) != nil)
        _ = choiceID
    }

    @Test func setAlternativesAreAddressableByAlternativeID() throws {
        let (s, _, runID, _, _, _, _, _, _) = nestedStore()
        let setID = try #require(s.current?.exercise(runID)?.prescription.sets.first?.id)
        let added = try requireReceipt(s.addSetAlternative(
            setID: setID,
            label: "Bike erg",
            values: PlannedSetValues(metrics: [.distance: 2000]),
            ranges: [MetricTargetRange(metric: .duration, lower: 300, upper: 420)],
            expectedRevisionToken: try token(s)
        ))
        let alternativeID = try #require(added.diff.changes.first?.entityID)
        var alternatives = try #require(s.current?.exercise(runID)?.prescription.sets.first?.alternatives)
        #expect(alternatives.first?.id == alternativeID)
        #expect(alternatives.first?.values[.distance] == 2000)
        #expect(alternatives.first?.ranges.count == 1)

        #expect(s.updateSetAlternative(
            alternativeID: alternativeID,
            patch: SetAlternativePatch(
                label: .set("Ski erg"),
                values: .set(.init(metrics: [.distance: .set(1800), .duration: .set(360)])),
                ranges: .clear
            ),
            expectedRevisionToken: try token(s)
        ).succeeded)
        alternatives = try #require(s.current?.exercise(runID)?.prescription.sets.first?.alternatives)
        #expect(alternatives.first?.label == "Ski erg")
        #expect(alternatives.first?.values[.distance] == 1800)
        #expect(alternatives.first?.values[.duration] == 360)
        #expect(alternatives.first?.ranges.isEmpty == true)

        // An unsupported metric for the owning exercise rejects the patch.
        #expect(!s.updateSetAlternative(
            alternativeID: alternativeID,
            patch: SetAlternativePatch(values: .set(.init(metrics: [.load: .set(100)]))),
            expectedRevisionToken: try token(s)
        ).succeeded)

        #expect(s.removeSetAlternative(
            alternativeID: alternativeID,
            expectedRevisionToken: try token(s)
        ).succeeded)
        #expect(s.current?.exercise(runID)?.prescription.sets.first?.alternatives.isEmpty == true)
        #expect(!s.removeSetAlternative(
            alternativeID: alternativeID,
            expectedRevisionToken: try token(s)
        ).succeeded)
    }

    @Test func updateExercisePrescriptionPatchesTargetsWithValidation() throws {
        let (s, _, runID, _, _, _, _, _, _) = nestedStore()
        #expect(s.updateExercisePrescription(
            exerciseInstanceID: runID,
            patch: ExercisePrescriptionPatch(
                restSeconds: .set(120),
                tempo: .set("3-1-1-0"),
                targetZone: .set(4),
                intent: .set(.threshold),
                intensityTargets: .set([
                    .heartRateZone(4),
                    .rpe(lower: 6, upper: 8),
                    .power(lower: 200, upper: 250, unit: .watts),
                    .pace("5k pace"),
                ])
            ),
            expectedRevisionToken: try token(s)
        ).succeeded)
        let prescription = try #require(s.current?.exercise(runID)?.prescription)
        #expect(prescription.restSeconds == 120)
        #expect(prescription.tempo == "3-1-1-0")
        #expect(prescription.targetZone == 4)
        #expect(prescription.intent == .threshold)
        #expect(prescription.intensityTargets.count == 4)

        #expect(!s.updateExercisePrescription(
            exerciseInstanceID: runID,
            patch: ExercisePrescriptionPatch(targetZone: .set(6)),
            expectedRevisionToken: try token(s)
        ).succeeded)
        #expect(!s.updateExercisePrescription(
            exerciseInstanceID: runID,
            patch: ExercisePrescriptionPatch(intensityTargets: .set([.rpe(lower: 9, upper: 3)])),
            expectedRevisionToken: try token(s)
        ).succeeded)

        #expect(s.updateExercisePrescription(
            exerciseInstanceID: runID,
            patch: ExercisePrescriptionPatch(
                restSeconds: .clear,
                tempo: .clear,
                targetZone: .clear,
                intent: .clear,
                intensityTargets: .clear
            ),
            expectedRevisionToken: try token(s)
        ).succeeded)
        let cleared = try #require(s.current?.exercise(runID)?.prescription)
        #expect(cleared.restSeconds == nil)
        #expect(cleared.tempo == nil)
        #expect(cleared.targetZone == nil)
        #expect(cleared.intent == nil)
        #expect(cleared.intensityTargets.isEmpty)
    }

    @Test func updateSetProgressionsSetAndClear() throws {
        let (s, _, _, _, sledID, _, _, _, _) = nestedStore()
        let setID = try #require(s.current?.exercise(sledID)?.prescription.sets.first?.id)
        #expect(s.updateSet(
            setID: setID,
            patch: PlannedSetPatch(progressions: .set([
                MetricProgression(metric: .load, delta: 5, every: 1, unit: .round),
            ])),
            expectedRevisionToken: try token(s)
        ).succeeded)
        #expect(s.current?.exercise(sledID)?.prescription.sets.first?.progressions.count == 1)

        // Unsupported metric on the owning exercise rejects.
        #expect(!s.updateSet(
            setID: setID,
            patch: PlannedSetPatch(progressions: .set([
                MetricProgression(metric: .pace, delta: -2, every: 1, unit: .round),
            ])),
            expectedRevisionToken: try token(s)
        ).succeeded)

        #expect(s.updateSet(
            setID: setID,
            patch: PlannedSetPatch(progressions: .clear),
            expectedRevisionToken: try token(s)
        ).succeeded)
        #expect(s.current?.exercise(sledID)?.prescription.sets.first?.progressions.isEmpty == true)
    }

    @Test func nestedAddExerciseTargetsGroupsAndChoices() throws {
        let (s, _, _, groupID, _, _, choiceID, _, _) = nestedStore()
        let intoGroup = try requireReceipt(s.addExercise(
            name: "Wall Balls",
            toContainerID: groupID,
            atIndex: 0,
            sets: 1,
            reps: 20,
            load: nil,
            durationSeconds: nil,
            expectedRevisionToken: try token(s)
        ))
        let wallBallsID = try #require(intoGroup.diff.changes.first?.entityID)
        #expect(s.current?.locateNode(wallBallsID)?.container == .group(groupID))

        let intoChoice = try requireReceipt(s.addExercise(
            name: "Ski Erg",
            toContainerID: choiceID,
            atIndex: nil,
            sets: 1,
            reps: nil,
            load: nil,
            durationSeconds: 120,
            expectedRevisionToken: try token(s)
        ))
        let skiID = try #require(intoChoice.diff.changes.first?.entityID)
        #expect(s.current?.locateNode(skiID)?.container == .choice(choiceID))
        guard case .choice(let choice)? = s.current?.findNode(choiceID) else {
            Issue.record("choice missing"); return
        }
        #expect(choice.options.count == 3)
    }

    @Test func staleRevisionTokenRejectsWaveEightMutationsTruthfully() throws {
        let (s, _, _, groupID, _, _, _, _, _) = nestedStore()
        let stale = UUID()
        let before = s.current
        guard case .notFound(let message) = s.updateGroup(
            groupID: groupID,
            patch: WorkoutGroupPatch(label: .set("New label")),
            expectedRevisionToken: stale
        ) else {
            Issue.record("expected stale rejection"); return
        }
        #expect(message.contains("changed after I read it"))
        #expect(s.current == before)
    }

    @Test func summaryExposesEveryWaveEightAddressableID() throws {
        let (s, _, runID, groupID, _, restID, choiceID, echoID, _) = nestedStore()
        let setID = try #require(s.current?.exercise(runID)?.prescription.sets.first?.id)
        let added = try requireReceipt(s.addSetAlternative(
            setID: setID,
            label: "Row",
            values: PlannedSetValues(metrics: [.distance: 1000]),
            ranges: [],
            expectedRevisionToken: try token(s)
        ))
        let alternativeID = try #require(added.diff.changes.first?.entityID)
        let summary = s.summary(.plan)
        #expect(summary.contains("REQUIRED GROUP [id: \(groupID.uuidString)]"))
        #expect(summary.contains("CHOICE [id: \(choiceID.uuidString)]"))
        #expect(summary.contains("OPTION 1 [node id: \(echoID.uuidString)]"))
        #expect(summary.contains("REST [id: \(restID.uuidString)]"))
        #expect(summary.contains("[id: \(alternativeID.uuidString)]"))
    }

    @Test func waveEightOperationsComposeInsideTheAtomicBatch() throws {
        let (s, blockID, runID, groupID, _, _, _, _, _) = nestedStore()
        let before = s.current
        // A valid batch: rename the group and nest the run into it, atomically.
        #expect(s.applyWorkoutEdits(
            operations: [
                .updateGroup(groupID: groupID, patch: WorkoutGroupPatch(label: .set("Engine"))),
                .moveNode(nodeID: runID, toParentID: groupID, toIndex: 0),
            ],
            expectedRevisionToken: try token(s)
        ).succeeded)
        guard case .group(let updated)? = s.current?.findNode(groupID) else {
            Issue.record("group missing"); return
        }
        #expect(updated.label == "Engine")
        #expect(s.current?.locateNode(runID)?.container == .group(groupID))

        // A batch with one invalid op commits nothing.
        let beforeFailure = s.current
        guard case .notFound(let message) = s.applyWorkoutEdits(
            operations: [
                .updateGroup(groupID: groupID, patch: WorkoutGroupPatch(label: .set("Other"))),
                .moveNode(nodeID: groupID, toParentID: groupID, toIndex: 0),
            ],
            expectedRevisionToken: try token(s)
        ) else {
            Issue.record("expected batch rejection"); return
        }
        #expect(message.contains("Operation 2 of 2 (move_node) failed"))
        #expect(message.contains("nothing was changed"))
        #expect(s.current == beforeFailure)
        _ = (blockID, before)
    }
}

// MARK: - Mapper (Wave 8 payloads)

struct WorkoutNodeStructureMapperTests {
    private let revision = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let nodeID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    private let parentID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    private var tokenInput: String { revision.uuidString }

    @Test func mapsUpdateGroupWithThreeStatePatches() {
        let mapped = ToolCallMapper.map(name: "update_group", input: [
            "group_id": nodeID.uuidString,
            "label": "Engine",
            "guidance": NSNull(),
            "phase": "main",
            "dose": NSNull(),
            "is_optional": true,
            "repetition": ["type": "count", "count": 4],
            "cadence": ["interval_seconds": 60, "scope": "child"],
            "total_targets": ["calories": 100, "duration": NSNull()],
            "adjustments": [["metric": "load", "step": 5, "minimum": 20, "maximum": 60]],
            "expected_revision_token": tokenInput,
        ])
        #expect(mapped == .updateGroup(
            groupID: nodeID,
            patch: WorkoutGroupPatch(
                label: .set("Engine"),
                guidance: .clear,
                phase: .set(.main),
                doseLayer: .clear,
                isOptional: .set(true),
                repetition: .set(.count(4)),
                cadence: .set(StartCadence(intervalSeconds: 60, scope: .child)),
                totalTargets: .set(.init(metrics: [.calories: .set(100), .duration: .clear])),
                adjustments: .set([MetricAdjustment(metric: .load, step: 5, minimum: 20, maximum: 60)])
            ),
            expectedRevisionToken: revision
        ))
    }

    @Test func rejectsMalformedGroupPayloads() {
        // No changes at all.
        #expect(ToolCallMapper.map(name: "update_group", input: [
            "group_id": nodeID.uuidString, "expected_revision_token": tokenInput,
        ]) == nil)
        // Repetition is required state: null can't clear it.
        #expect(ToolCallMapper.map(name: "update_group", input: [
            "group_id": nodeID.uuidString, "repetition": NSNull(), "expected_revision_token": tokenInput,
        ]) == nil)
        // Unknown phase value.
        #expect(ToolCallMapper.map(name: "update_group", input: [
            "group_id": nodeID.uuidString, "phase": "sprint", "expected_revision_token": tokenInput,
        ]) == nil)
        // A count repetition below 1.
        #expect(ToolCallMapper.map(name: "update_group", input: [
            "group_id": nodeID.uuidString, "repetition": ["type": "count", "count": 0],
            "expected_revision_token": tokenInput,
        ]) == nil)
        // Label is required state.
        #expect(ToolCallMapper.map(name: "update_group", input: [
            "group_id": nodeID.uuidString, "label": NSNull(), "expected_revision_token": tokenInput,
        ]) == nil)
    }

    @Test func mapsChoiceRestAndConversionTools() {
        #expect(ToolCallMapper.map(name: "update_choice", input: [
            "choice_id": nodeID.uuidString, "label": "Erg pick", "selection_count": 2,
            "expected_revision_token": tokenInput,
        ]) == .updateChoice(
            choiceID: nodeID, label: .set("Erg pick"), selectionCount: .set(2),
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "update_choice", input: [
            "choice_id": nodeID.uuidString, "selection_count": 0, "expected_revision_token": tokenInput,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_choice", input: [
            "choice_id": nodeID.uuidString, "expected_revision_token": tokenInput,
        ]) == nil)

        #expect(ToolCallMapper.map(name: "convert_choice_to_group", input: [
            "choice_id": nodeID.uuidString, "expected_revision_token": tokenInput,
        ]) == .convertChoiceToGroup(choiceID: nodeID, expectedRevisionToken: revision))

        #expect(ToolCallMapper.map(name: "update_rest", input: [
            "rest_id": nodeID.uuidString,
            "label": "Walk",
            "placement": "afterEveryRepetition",
            "duration_seconds": NSNull(),
            "guidance": "Easy pace",
            "expected_revision_token": tokenInput,
        ]) == .updateRest(
            restID: nodeID,
            patch: PlannedRestPatch(
                label: .set("Walk"),
                placement: .set(.afterEveryRepetition),
                durationSeconds: .clear,
                guidance: .set("Easy pace")
            ),
            expectedRevisionToken: revision
        ))
        // Placement is required state; unknown values reject.
        #expect(ToolCallMapper.map(name: "update_rest", input: [
            "rest_id": nodeID.uuidString, "placement": NSNull(), "expected_revision_token": tokenInput,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_rest", input: [
            "rest_id": nodeID.uuidString, "placement": "sometimes", "expected_revision_token": tokenInput,
        ]) == nil)

        #expect(ToolCallMapper.map(name: "add_rest", input: [
            "parent_id": parentID.uuidString, "at_index": 1, "duration_seconds": 45,
            "placement": "betweenRepetitions", "label": "Breather",
            "expected_revision_token": tokenInput,
        ]) == .addRest(
            parentID: parentID, atIndex: 1, durationSeconds: 45, placement: .betweenRepetitions,
            label: "Breather", guidance: nil, expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "add_rest", input: [
            "parent_id": parentID.uuidString, "duration_seconds": -5,
            "expected_revision_token": tokenInput,
        ]) == nil)
    }

    @Test func mapsGenericNodeMoveAndRemove() {
        #expect(ToolCallMapper.map(name: "move_node", input: [
            "node_id": nodeID.uuidString, "to_parent_id": parentID.uuidString, "to_index": 2,
            "expected_revision_token": tokenInput,
        ]) == .moveNode(nodeID: nodeID, toParentID: parentID, toIndex: 2, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "move_node", input: [
            "node_id": nodeID.uuidString, "to_parent_id": parentID.uuidString, "to_index": -1,
            "expected_revision_token": tokenInput,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "move_node", input: [
            "node_id": nodeID.uuidString, "to_parent_id": "not-a-uuid", "to_index": 0,
            "expected_revision_token": tokenInput,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "remove_node", input: [
            "node_id": nodeID.uuidString, "expected_revision_token": tokenInput,
        ]) == .removeNode(nodeID: nodeID, expectedRevisionToken: revision))
        #expect(ToolCallMapper.map(name: "remove_node", input: [
            "expected_revision_token": tokenInput,
        ]) == nil)
    }

    @Test func mapsSetAlternativeTools() {
        #expect(ToolCallMapper.map(name: "add_set_alternative", input: [
            "set_id": nodeID.uuidString,
            "label": "Ski erg",
            "values": ["distance": 1800],
            "ranges": [["metric": "duration", "lower": 300, "upper": 420]],
            "expected_revision_token": tokenInput,
        ]) == .addSetAlternative(
            setID: nodeID,
            label: "Ski erg",
            values: PlannedSetValues(metrics: [.distance: 1800]),
            ranges: [MetricTargetRange(metric: .duration, lower: 300, upper: 420)],
            expectedRevisionToken: revision
        ))
        // Missing label rejects; inverted range rejects.
        #expect(ToolCallMapper.map(name: "add_set_alternative", input: [
            "set_id": nodeID.uuidString, "expected_revision_token": tokenInput,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "add_set_alternative", input: [
            "set_id": nodeID.uuidString, "label": "x",
            "ranges": [["metric": "duration", "lower": 500, "upper": 400]],
            "expected_revision_token": tokenInput,
        ]) == nil)

        #expect(ToolCallMapper.map(name: "update_set_alternative", input: [
            "alternative_id": nodeID.uuidString,
            "values": ["distance": NSNull(), "duration": 360],
            "ranges": NSNull(),
            "expected_revision_token": tokenInput,
        ]) == .updateSetAlternative(
            alternativeID: nodeID,
            patch: SetAlternativePatch(
                values: .set(.init(metrics: [.distance: .clear, .duration: .set(360)])),
                ranges: .clear
            ),
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "update_set_alternative", input: [
            "alternative_id": nodeID.uuidString, "label": NSNull(), "expected_revision_token": tokenInput,
        ]) == nil)

        #expect(ToolCallMapper.map(name: "remove_set_alternative", input: [
            "alternative_id": nodeID.uuidString, "expected_revision_token": tokenInput,
        ]) == .removeSetAlternative(alternativeID: nodeID, expectedRevisionToken: revision))
    }

    @Test func mapsExercisePrescriptionWithTypedIntensityTargets() {
        let mapped = ToolCallMapper.map(name: "update_exercise_prescription", input: [
            "exercise_instance_id": nodeID.uuidString,
            "rest_seconds": 120,
            "tempo": NSNull(),
            "target_zone": 4,
            "intent": "threshold",
            "intensity_targets": [
                ["type": "heartRateZone", "zone": 4],
                ["type": "rpe", "lower": 6, "upper": 8],
                ["type": "power", "lower": 200, "upper": 250, "unit": "watts"],
                ["type": "pace", "text": "5k pace"],
                ["type": "namedZone", "system": "Coggan", "range": "Z2"],
                ["type": "descriptive", "text": "comfortably hard"],
                ["type": "thresholdPercentage", "lower": 90, "upper": 95],
            ],
            "expected_revision_token": tokenInput,
        ])
        #expect(mapped == .updateExercisePrescription(
            exerciseInstanceID: nodeID,
            patch: ExercisePrescriptionPatch(
                restSeconds: .set(120),
                tempo: .clear,
                targetZone: .set(4),
                intent: .set(.threshold),
                intensityTargets: .set([
                    .heartRateZone(4),
                    .rpe(lower: 6, upper: 8),
                    .power(lower: 200, upper: 250, unit: .watts),
                    .pace("5k pace"),
                    .namedZone(system: "Coggan", range: "Z2"),
                    .descriptive("comfortably hard"),
                    .thresholdPercentage(lower: 90, upper: 95),
                ])
            ),
            expectedRevisionToken: revision
        ))

        // A power target in anything but watts is never silently accepted.
        #expect(ToolCallMapper.map(name: "update_exercise_prescription", input: [
            "exercise_instance_id": nodeID.uuidString,
            "intensity_targets": [["type": "power", "lower": 200, "upper": 250, "unit": "horsepower"]],
            "expected_revision_token": tokenInput,
        ]) == nil)
        // An unknown target type rejects the whole call rather than dropping the target.
        #expect(ToolCallMapper.map(name: "update_exercise_prescription", input: [
            "exercise_instance_id": nodeID.uuidString,
            "intensity_targets": [["type": "vibes"]],
            "expected_revision_token": tokenInput,
        ]) == nil)
        // Zone 6 rejects at the boundary.
        #expect(ToolCallMapper.map(name: "update_exercise_prescription", input: [
            "exercise_instance_id": nodeID.uuidString,
            "intensity_targets": [["type": "heartRateZone", "zone": 6]],
            "expected_revision_token": tokenInput,
        ]) == nil)
        // No changes rejects.
        #expect(ToolCallMapper.map(name: "update_exercise_prescription", input: [
            "exercise_instance_id": nodeID.uuidString, "expected_revision_token": tokenInput,
        ]) == nil)
    }

    @Test func mapsUpdateSetProgressionsAndNestedAddExercise() {
        #expect(ToolCallMapper.map(name: "update_set", input: [
            "set_id": nodeID.uuidString,
            "patch": ["progressions": [["metric": "load", "delta": 5, "unit": "round"]]],
            "expected_revision_token": tokenInput,
        ]) == .updateSet(
            setID: nodeID,
            patch: PlannedSetPatch(progressions: .set([
                MetricProgression(metric: .load, delta: 5, every: 1, unit: .round),
            ])),
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "update_set", input: [
            "set_id": nodeID.uuidString,
            "patch": ["progressions": NSNull()],
            "expected_revision_token": tokenInput,
        ]) == .updateSet(
            setID: nodeID,
            patch: PlannedSetPatch(progressions: .clear),
            expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "update_set", input: [
            "set_id": nodeID.uuidString,
            "patch": ["progressions": [["metric": "load", "delta": 5, "unit": "week"]]],
            "expected_revision_token": tokenInput,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "update_set", input: [
            "set_id": nodeID.uuidString,
            "patch": ["progressions": [["metric": "load", "delta": 5, "every": 0, "unit": "round"]]],
            "expected_revision_token": tokenInput,
        ]) == nil)

        // add_exercise: exactly one destination.
        #expect(ToolCallMapper.map(name: "add_exercise", input: [
            "parent_id": parentID.uuidString, "name": "Wall Balls", "expected_revision_token": tokenInput,
        ]) == .addExercise(
            containerID: parentID, name: "Wall Balls", atIndex: nil, sets: nil, reps: nil,
            load: nil, durationSeconds: nil, distanceMeters: nil, expectedRevisionToken: revision
        ))
        #expect(ToolCallMapper.map(name: "add_exercise", input: [
            "name": "Wall Balls", "expected_revision_token": tokenInput,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "add_exercise", input: [
            "block_id": nodeID.uuidString, "parent_id": parentID.uuidString, "name": "Wall Balls",
            "expected_revision_token": tokenInput,
        ]) == nil)
    }

    @Test func waveEightOperationsParseInsideTheAtomicBatch() {
        let mapped = ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [
                ["op": "update_group", "group_id": nodeID.uuidString, "label": "Engine"],
                [
                    "op": "move_node", "node_id": nodeID.uuidString,
                    "to_parent_id": parentID.uuidString, "to_index": 0,
                ],
                ["op": "remove_set_alternative", "alternative_id": parentID.uuidString],
            ],
            "expected_revision_token": tokenInput,
        ])
        #expect(mapped == .applyWorkoutEdits(
            operations: [
                .updateGroup(groupID: nodeID, patch: WorkoutGroupPatch(label: .set("Engine"))),
                .moveNode(nodeID: nodeID, toParentID: parentID, toIndex: 0),
                .removeSetAlternative(alternativeID: parentID),
            ],
            expectedRevisionToken: revision
        ))
        // A malformed Wave 8 op rejects the whole batch.
        #expect(ToolCallMapper.map(name: "apply_workout_edits", input: [
            "operations": [["op": "update_group", "group_id": nodeID.uuidString]],
            "expected_revision_token": tokenInput,
        ]) == nil)
    }

    @Test func waveEightMutationsRequireRevisionTokens() {
        // Every new mutation without expected_revision_token is rejected outright.
        #expect(ToolCallMapper.map(name: "update_group", input: [
            "group_id": nodeID.uuidString, "label": "Engine",
        ]) == nil)
        #expect(ToolCallMapper.map(name: "move_node", input: [
            "node_id": nodeID.uuidString, "to_parent_id": parentID.uuidString, "to_index": 0,
        ]) == nil)
        #expect(ToolCallMapper.map(name: "remove_node", input: ["node_id": nodeID.uuidString]) == nil)
        #expect(ToolCallMapper.map(name: "update_exercise_prescription", input: [
            "exercise_instance_id": nodeID.uuidString, "rest_seconds": 60,
        ]) == nil)
    }
}
