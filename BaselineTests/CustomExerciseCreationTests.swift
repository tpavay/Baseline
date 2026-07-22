import Foundation
import Testing
@testable import Baseline

// MARK: - Wave 9: create_custom_exercise

/// The agent's deliberate custom-creation path must behave exactly like the manual
/// `CustomExerciseForm` → `createCustomDefinition` path - same required fields, same caps, same
/// duplicate handling - plus the two-phase proposal contract that keeps an inferred classification
/// from being silently committed.
@MainActor
struct CustomExerciseCreationTests {

    // MARK: Harness

    private func freshStore() -> WorkoutStore {
        WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "custom-ex-\(UUID().uuidString)")!)
    }

    /// A review-style unbound store holding one workout, the same shape the import screen and the
    /// unbound chat surface use.
    private func reviewStore(source: WorkoutStore? = nil, workout: Workout? = nil) -> WorkoutStore {
        WorkoutStore(
            transientWorkout: workout ?? Workout(title: "Imported", blocks: [WorkoutBlock(name: "Main", exercises: [])]),
            configurationFrom: source ?? freshStore()
        )
    }

    private func draft(
        name: String = "Keg Toss",
        equipment: [Equipment] = [.sandbag],
        primaryMuscles: [Muscle] = [.glutes],
        metrics: [MetricType] = [.reps, .load],
        patterns: [MovementPattern] = [.hinge],
        level: ExerciseLevel? = nil,
        units: [MetricType: MetricUnit] = [:]
    ) -> WorkoutStore.CustomExerciseDraft {
        WorkoutStore.CustomExerciseDraft(
            name: name,
            equipment: equipment,
            primaryMuscles: primaryMuscles,
            secondaryMuscles: [],
            metrics: metrics,
            patterns: patterns,
            tags: [],
            level: level,
            units: units
        )
    }

    private func token(_ store: WorkoutStore) throws -> UUID {
        try #require(store.mutationTarget(store.agentScope)?.revisionToken)
    }

    private func proposalID(in text: String) throws -> UUID {
        let match = try #require(text.firstMatch(of: /proposal_id "([0-9a-fA-F\-]{36})"/))
        return try #require(UUID(uuidString: String(match.1)))
    }

    @discardableResult
    private func commit(
        _ store: WorkoutStore,
        _ draft: WorkoutStore.CustomExerciseDraft
    ) throws -> WorkoutMutationReceipt {
        guard case .proposal(let text) = store.createCustomExercise(
            draft: draft, proposalID: nil, expectedRevisionToken: try token(store)
        ) else { throw TestFailure("expected a proposal") }
        guard case .created(let receipt, _) = store.createCustomExercise(
            draft: draft, proposalID: try proposalID(in: text), expectedRevisionToken: try token(store)
        ) else { throw TestFailure("expected a creation") }
        return receipt
    }

    private struct TestFailure: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: Proposal phase

    @Test func theProposalPhaseCommitsNothingAndMarksEveryInferredPart() throws {
        let store = reviewStore()
        let result = store.createCustomExercise(
            draft: draft(metrics: [.distance, .duration], level: nil),
            proposalID: nil,
            expectedRevisionToken: try token(store)
        )

        guard case .proposal(let text) = result else {
            Issue.record("expected a proposal, got \(result)")
            return
        }
        #expect(store.customDefinitions.isEmpty, "phase 1 must create nothing")
        #expect(text.contains("PROPOSAL"))
        #expect(text.contains("nothing created yet"))
        // The parts domain code inferred are explicitly marked, so the model can relay them for
        // confirmation instead of silently committing a guess.
        #expect(text.contains("Intermediate (DEFAULT"))
        #expect(text.contains("modality: cardio (DERIVED"))
        #expect(text.contains("category:"))
        #expect(text.contains("proposal_id \""))
        #expect(text.contains("confirm every part they didn't state"))
    }

    @Test func aStatedLevelIsNotMarkedAsADefault() throws {
        let store = reviewStore()
        guard case .proposal(let text) = store.createCustomExercise(
            draft: draft(level: .expert), proposalID: nil, expectedRevisionToken: try token(store)
        ) else {
            Issue.record("expected a proposal")
            return
        }
        #expect(text.contains("level: Expert"))
        #expect(!text.contains("DEFAULT"))
    }

    @Test func aCuratedNameCollisionWarnsAboutShadowing() throws {
        let store = reviewStore()
        guard case .proposal(let text) = store.createCustomExercise(
            draft: draft(name: "Deadlift", primaryMuscles: [.hamstrings]),
            proposalID: nil,
            expectedRevisionToken: try token(store)
        ) else {
            Issue.record("expected a proposal")
            return
        }
        #expect(text.contains("WARNING"))
        #expect(text.localizedCaseInsensitiveContains("already has"))
        #expect(text.localizedCaseInsensitiveContains("shadows"))
        #expect(store.customDefinitions.isEmpty)
    }

    @Test func aNearMissSurfacesSimilarCatalogMovements() throws {
        let store = reviewStore()
        // "Benchpress" is not an exact catalog name or alias, but the search still reaches the real
        // movement - the proposal must point there before the athlete confirms a near-duplicate.
        guard case .proposal(let text) = store.createCustomExercise(
            draft: draft(name: "Benchpress", equipment: [.barbell], primaryMuscles: [.chest], patterns: [.push]),
            proposalID: nil,
            expectedRevisionToken: try token(store)
        ) else {
            Issue.record("expected a proposal")
            return
        }
        #expect(text.contains("Similar catalog movements"))
        #expect(text.contains("Bench Press"))
    }

    // MARK: Commit phase

    @Test func commitCreatesExactlyWhatTheManualPathWouldCreate() throws {
        let store = reviewStore()
        let payload = draft(level: .expert)
        try commit(store, payload)

        // The manual path, run with the same form inputs on an independent store.
        let manual = freshStore().createCustomDefinition(
            name: "Keg Toss", supported: [.reps, .load], equipment: [.sandbag],
            primaryMuscles: [.glutes], secondaryMuscles: [], patterns: [.hinge], tags: [], level: .expert
        )

        let created = try #require(store.customDefinitions.first)
        #expect(created.id.hasPrefix("custom_"))
        #expect(created.name == manual.name)
        #expect(created.category == manual.category)
        #expect(created.supported == manual.supported)
        #expect(created.defaults == manual.defaults)
        #expect(created.aliases == manual.aliases)
        #expect(created.equipment == manual.equipment)
        #expect(created.primaryMuscles == manual.primaryMuscles)
        #expect(created.patterns == manual.patterns)
        #expect(created.modality == manual.modality)
        #expect(created.level == manual.level)
    }

    @Test func commitRejectsAWrongOrMissingProposalID() throws {
        let store = reviewStore()
        _ = store.createCustomExercise(draft: draft(), proposalID: nil, expectedRevisionToken: try token(store))

        let result = store.createCustomExercise(
            draft: draft(), proposalID: UUID(), expectedRevisionToken: try token(store)
        )
        guard case .rejected(let message) = result else {
            Issue.record("a mismatched proposal id must reject, got \(result)")
            return
        }
        #expect(message.contains("doesn't match an open proposal"))
        #expect(store.customDefinitions.isEmpty)
    }

    @Test func changedFieldsReProposeInsteadOfCommittingUnconfirmedContent() throws {
        let store = reviewStore()
        guard case .proposal(let text) = store.createCustomExercise(
            draft: draft(), proposalID: nil, expectedRevisionToken: try token(store)
        ) else {
            Issue.record("expected a proposal")
            return
        }
        let id = try proposalID(in: text)

        // The model changed the metrics after the athlete saw the proposal: what was confirmed is
        // not what this call would commit, so nothing is created and a fresh proposal comes back.
        let result = store.createCustomExercise(
            draft: draft(metrics: [.distance]), proposalID: id, expectedRevisionToken: try token(store)
        )
        guard case .proposal(let reproposal) = result else {
            Issue.record("changed fields must re-propose, got \(result)")
            return
        }
        #expect(reproposal.contains("fields changed since that proposal"))
        #expect(store.customDefinitions.isEmpty)
    }

    @Test func anExistingCustomIsReusedExactlyLikeTheManualPath() throws {
        let store = reviewStore()
        let existing = store.createCustomDefinition(
            name: "Keg Toss", supported: [.reps], equipment: [.sandbag], primaryMuscles: [.glutes]
        )

        let result = store.createCustomExercise(
            draft: draft(), proposalID: nil, expectedRevisionToken: try token(store)
        )
        guard case .existing(let message) = result else {
            Issue.record("a same-named custom must be reused, not duplicated - got \(result)")
            return
        }
        #expect(message.contains(existing.id))
        #expect(message.contains("nothing new was created"))
        #expect(store.customDefinitions.count == 1)
    }

    @Test func aStaleRevisionTokenRejectsTruthfullyInBothPhases() throws {
        let store = reviewStore()

        let proposalResult = store.createCustomExercise(
            draft: draft(), proposalID: nil, expectedRevisionToken: UUID()
        )
        guard case .rejected(let message) = proposalResult else {
            Issue.record("a stale token must reject the proposal phase, got \(proposalResult)")
            return
        }
        #expect(message.contains("changed after I read it"))

        guard case .proposal(let text) = store.createCustomExercise(
            draft: draft(), proposalID: nil, expectedRevisionToken: try token(store)
        ) else {
            Issue.record("expected a proposal")
            return
        }
        let commitResult = store.createCustomExercise(
            draft: draft(), proposalID: try proposalID(in: text), expectedRevisionToken: UUID()
        )
        guard case .rejected(let commitMessage) = commitResult else {
            Issue.record("a stale token must reject the commit phase, got \(commitResult)")
            return
        }
        #expect(commitMessage.contains("changed after I read it"))
        #expect(store.customDefinitions.isEmpty)
    }

    // MARK: Validation parity with the manual form

    @Test func validationMatchesTheManualFormGate() throws {
        let store = reviewStore()
        let expectedToken = try token(store)

        func rejection(_ payload: WorkoutStore.CustomExerciseDraft) -> String? {
            guard case .rejected(let message) = store.createCustomExercise(
                draft: payload, proposalID: nil, expectedRevisionToken: expectedToken
            ) else { return nil }
            return message
        }

        #expect(rejection(draft(name: "   "))?.contains("name") == true)
        #expect(rejection(draft(equipment: []))?.contains("equipment") == true)
        #expect(rejection(draft(primaryMuscles: []))?.contains("primary muscle") == true)
        #expect(rejection(draft(metrics: []))?.contains("metric") == true)
        // The manual pattern picker caps at two; three must not sneak through the agent path.
        #expect(rejection(draft(patterns: [.hinge, .carry, .rotation]))?.contains("two movement patterns") == true)
        // A display default for a metric the movement doesn't log is meaningless.
        #expect(rejection(draft(metrics: [.reps], units: [.distance: .miles])) != nil)
        #expect(store.customDefinitions.isEmpty)
    }

    // MARK: Units-bearing defaults

    @Test func aUnitsBearingDefaultReachesTheDisplayUnitRule() throws {
        let store = reviewStore()
        try commit(store, draft(
            name: "Sled Drag Sprint",
            equipment: [.sled],
            metrics: [.distance, .duration],
            patterns: [.gait],
            units: [.distance: .miles]
        ))

        let created = try #require(store.customDefinitions.first)
        var instance = PlannedExercise(exerciseName: created.name)
        instance.definitionId = created.id
        #expect(
            store.displayUnit(.distance, for: instance) == .miles,
            "the stated display default must win for future instances of the new movement"
        )
    }

    @Test func exercisePreferencesResolveCustomOnlyNames() throws {
        // "Use miles for it from now on" said after creation must reach the custom definition -
        // it exists only in the athlete's own catalog, never the curated one.
        let store = reviewStore()
        try commit(store, draft(name: "Sled Drag Sprint", equipment: [.sled], metrics: [.distance], patterns: [.gait]))
        let created = try #require(store.customDefinitions.first)

        let outcome = store.setExercisePreference(
            exerciseNamed: "Sled Drag Sprint", scope: .exercise, units: [.distance: .miles]
        )
        #expect(outcome.succeeded)

        var instance = PlannedExercise(exerciseName: created.name)
        instance.definitionId = created.id
        #expect(store.displayUnit(.distance, for: instance) == .miles)
    }

    // MARK: Immediately usable

    @Test func theNewExerciseIsImmediatelyAddableByName() throws {
        let store = reviewStore()
        try commit(store, draft(name: "Keg Toss"))
        let created = try #require(store.customDefinitions.first)

        #expect(store.resolveDefinition("Keg Toss").id == created.id)

        let blockID = try #require(store.current?.blocks.first?.id)
        let outcome = store.addExercise(
            name: "Keg Toss",
            toContainerID: blockID,
            atIndex: nil,
            sets: nil, reps: nil, load: nil, durationSeconds: nil, distanceMeters: nil,
            expectedRevisionToken: try token(store)
        )
        #expect(outcome.succeeded)
        let added = try #require(store.current?.allExercises.first { $0.exerciseName == "Keg Toss" })
        #expect(added.definitionId == created.id, "the added instance must keep the custom identity, not fall to generic")
    }

    @Test func theNewExerciseIsImmediatelySearchableAndRetrievableByTheAgent() throws {
        let context = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let store = reviewStore()
        let tools = AgentTools(store: context, base: DecisionEngine.Inputs(), workouts: store)
        try commit(store, draft(name: "Keg Toss"))
        let created = try #require(store.customDefinitions.first)

        let detail = tools.dispatch(.getExercise(name: "Keg Toss", id: nil)).text
        #expect(detail.contains(created.id))
        #expect(detail.contains("custom, athlete-created"))

        let search = tools.dispatch(.searchExercises(query: "keg toss", muscle: nil, equipment: nil,
                                                     modality: nil, pattern: nil, tag: nil, level: nil)).text
        #expect(search.contains(created.id))
        #expect(search.contains("custom"))
    }

    // MARK: Undo

    @Test func oneUndoRevertsTheCreationIncludingItsUnitDefaults() throws {
        let source = freshStore()
        let store = reviewStore(source: source)
        let receipt = try commit(store, draft(
            name: "Sled Drag Sprint", equipment: [.sled], metrics: [.distance], patterns: [.gait],
            units: [.distance: .miles]
        ))
        let created = try #require(store.customDefinitions.first)
        #expect(source.customDefinitions.map(\.id) == [created.id], "deliberate catalog changes flow back to the source store")

        let outcome = store.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        )
        #expect(outcome.succeeded)
        #expect(store.customDefinitions.isEmpty, "undo must remove the definition the creation added")
        #expect(source.customDefinitions.isEmpty, "the removal must flow back to the source store too")
        #expect(store.resolveDefinition("Sled Drag Sprint").id == ExerciseCatalog.generic.id)

        var instance = PlannedExercise(exerciseName: created.name)
        instance.definitionId = created.id
        #expect(store.displayUnit(.distance, for: instance) != .miles, "the unit default must not outlive the definition")
    }

    @Test func undoAfterALaterEditIsStaleAndKeepsTheDefinition() throws {
        let store = reviewStore()
        let receipt = try commit(store, draft(name: "Keg Toss"))

        // A later mutation makes the creation receipt no longer the head; undo must reject
        // truthfully and leave the definition (it may already be in use).
        let later = store.updateWorkoutMetadata(
            title: .set("Renamed"), goal: .unchanged, guidance: .unchanged,
            expectedRevisionToken: try token(store)
        )
        #expect(later.succeeded)

        let outcome = store.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        )
        guard case .notFound(let message) = outcome else {
            Issue.record("a stale creation undo must reject, got \(outcome)")
            return
        }
        #expect(message.contains("no longer the latest"))
        #expect(store.customDefinitions.count == 1)
    }

    // MARK: Agent dispatch surface

    @Test func dispatchReturnsAProposalWithoutAReceiptAndACommitWithOne() throws {
        let context = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let store = reviewStore()
        let tools = AgentTools(store: context, base: DecisionEngine.Inputs(), workouts: store)
        let payload = draft(name: "Keg Toss")

        let proposal = tools.dispatch(.createCustomExercise(
            draft: payload, proposalID: nil, expectedRevisionToken: try token(store)
        ))
        #expect(proposal.text.contains("PROPOSAL"))
        #expect(proposal.mutationReceipt == nil)

        let commit = tools.dispatch(.createCustomExercise(
            draft: payload,
            proposalID: try proposalID(in: proposal.text),
            expectedRevisionToken: try token(store)
        ))
        #expect(commit.text.contains("Created custom exercise \"Keg Toss\""))
        #expect(commit.text.contains("MUTATION RECEIPT:"))
        #expect(commit.text.contains("immediately addable"))
        #expect(commit.mutationReceipt != nil)
        #expect(commit.userFacingText.contains("Created custom exercise"))
        #expect(!commit.userFacingText.contains("MUTATION RECEIPT"))
    }
}

// MARK: - Import review integration

/// The import-fix conversation edits the same transient review store the editor shows. Fixing an
/// unknown exercise through agent tools must reconcile the blocking issue and unblock save - and
/// undoing that fix must bring the issue (and the save block) back.
@MainActor
struct CustomExerciseImportReviewTests {

    private func makeModel(session: ImportSession) -> WorkoutImportViewModel {
        WorkoutImportViewModel(
            normalizer: PassthroughNormalizer(),
            recognizer: StubRecognizer(),
            parser: StubParser(),
            initialSession: session
        )
    }

    private func unknownExerciseFixture() -> (model: WorkoutImportViewModel, reviewStore: WorkoutStore, source: WorkoutStore, exerciseID: UUID) {
        let exerciseID = UUID()
        let draft = Workout(title: "Imported", blocks: [WorkoutBlock(name: "Main", exercises: [
            PlannedExercise(id: exerciseID, exerciseName: "Mystery machine", definitionId: nil),
        ])])
        let model = makeModel(session: ImportSession(
            draft: .init(workout: draft),
            issues: [.init(
                code: .unknownExercise,
                severity: .blocking,
                message: "Choose an exercise for Mystery machine.",
                exerciseID: exerciseID,
                candidates: ["echo_bike"]
            )],
            status: .reviewing
        ))
        let source = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "import-src-\(UUID().uuidString)")!)
        let review = WorkoutStore(transientWorkout: draft, configurationFrom: source)
        return (model, review, source, exerciseID)
    }

    @Test func creatingACustomAndReplacingResolvesTheBlockingIssueAndUnblocksSave() throws {
        let (model, review, source, exerciseID) = unknownExerciseFixture()
        #expect(model.session.canSave == false)

        let context = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let tools = AgentTools(store: context, base: DecisionEngine.Inputs(), workouts: review)
        let payload = WorkoutStore.CustomExerciseDraft(
            name: "Mystery Machine Sprint",
            equipment: [.other],
            primaryMuscles: [.fullBody],
            secondaryMuscles: [],
            metrics: [.duration],
            patterns: [],
            tags: [],
            level: nil,
            units: [:]
        )
        let token = try #require(review.mutationTarget(review.agentScope)?.revisionToken)
        let proposal = tools.dispatch(.createCustomExercise(draft: payload, proposalID: nil, expectedRevisionToken: token))
        let match = try #require(proposal.text.firstMatch(of: /proposal_id "([0-9a-fA-F\-]{36})"/))
        let commitToken = try #require(review.mutationTarget(review.agentScope)?.revisionToken)
        let commit = tools.dispatch(.createCustomExercise(
            draft: payload,
            proposalID: try #require(UUID(uuidString: String(match.1))),
            expectedRevisionToken: commitToken
        ))
        #expect(commit.mutationReceipt != nil)
        #expect(source.customDefinitions.count == 1, "the deliberate creation flows back to the athlete's real catalog")

        let replaceToken = try #require(review.mutationTarget(review.agentScope)?.revisionToken)
        let replace = tools.dispatch(.replaceExercise(
            exerciseInstanceID: exerciseID,
            replacement: "Mystery Machine Sprint",
            expectedRevisionToken: replaceToken
        ))
        #expect(replace.mutationReceipt != nil)

        // The review screen syncs the store into the import document on every store change.
        model.synchronizeDraft(from: review)
        #expect(model.session.issues.isEmpty, "resolving the exercise must reconcile its blocking issue")
        #expect(model.session.canSave, "with no blocking issues the reviewed draft may save")
        #expect(model.session.draft?.workout.exercise(exerciseID)?.definitionId == source.customDefinitions.first?.id)
    }

    @Test func undoingTheFixRestoresTheBlockingIssueAndKeepsSaveBlocked() throws {
        let (model, review, _, exerciseID) = unknownExerciseFixture()
        #expect(model.session.canSave == false)

        let replaceToken = try #require(review.mutationTarget(review.agentScope)?.revisionToken)
        let fixed = review.replaceExercise(
            exerciseInstanceID: exerciseID,
            with: "Echo Bike",
            expectedRevisionToken: replaceToken
        )
        guard case .mutated(let receipt) = fixed else {
            Issue.record("expected the replacement to apply, got \(fixed)")
            return
        }
        model.synchronizeDraft(from: review)
        #expect(model.session.issues.isEmpty)
        #expect(model.session.canSave)

        // The athlete changes their mind: the receipt-addressed undo restores the pre-fix draft,
        // and the blocking issue must come back with it - reconcile alone only ever clears.
        #expect(review.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ).succeeded)
        model.synchronizeDraft(from: review)

        #expect(model.session.issues.count == 1, "the undone fix must resurface its blocking issue")
        #expect(model.session.issues.first?.code == .unknownExercise)
        #expect(model.session.canSave == false, "a partially-valid import must not save")
    }

    /// Two agent mutations can land in one model round while SwiftUI coalesces `onChange` to the
    /// final value only. The store's `agentMutationObserver` must feed every intermediate value to
    /// the view model, so undoing back to a state the view never rendered still restores the
    /// blocking issue that state had.
    @Test func coalescedRendersStillRestoreAnIntermediateIssueStateOnUndo() throws {
        let (model, review, _, exerciseID) = unknownExerciseFixture()
        review.agentMutationObserver = { [weak model] in model?.replaceDraftWorkout($0) }
        #expect(model.session.canSave == false)

        // First mutation leaves the blocking issue open; the second fixes it. No view sync happens
        // between them - the observer is the only per-mutation delivery.
        let retitleToken = try #require(review.mutationTarget(review.agentScope)?.revisionToken)
        #expect(review.updateWorkoutMetadata(
            title: .set("Imported Sprint Day"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: retitleToken
        ).succeeded)
        let fixToken = try #require(review.mutationTarget(review.agentScope)?.revisionToken)
        let fixed = review.replaceExercise(
            exerciseInstanceID: exerciseID,
            with: "Echo Bike",
            expectedRevisionToken: fixToken
        )
        guard case .mutated(let receipt) = fixed else {
            Issue.record("expected the replacement to apply, got \(fixed)")
            return
        }

        // The coalesced render delivers only the final value; by then the issue is already resolved.
        model.synchronizeDraft(from: review)
        #expect(model.session.issues.isEmpty)
        #expect(model.session.canSave)

        // Undo regresses the draft to the retitled-but-unresolved intermediate state the view never
        // rendered. Its blocking issue must resurface, and the single dismissal sync must keep it.
        #expect(review.undoMutation(
            mutationID: receipt.mutationID,
            expectedRevisionToken: receipt.afterRevisionToken
        ).succeeded)
        model.synchronizeDraft(from: review)

        #expect(model.session.issues.count == 1, "the intermediate state's blocking issue must resurface")
        #expect(model.session.issues.first?.code == .unknownExercise)
        #expect(model.session.canSave == false, "a partially-valid import must not save")
    }

    @Test func agentIssueContextListsOpenIssuesAndGoesQuietWhenResolved() throws {
        let (model, review, _, exerciseID) = unknownExerciseFixture()

        let block = try #require(model.agentIssueContext)
        #expect(block.contains("OPEN IMPORT ISSUES"))
        #expect(block.contains("[blocking]"))
        #expect(block.contains("Choose an exercise for Mystery machine."))
        #expect(block.contains(exerciseID.uuidString))
        #expect(block.contains("echo_bike"))

        let token = try #require(review.mutationTarget(review.agentScope)?.revisionToken)
        #expect(review.replaceExercise(
            exerciseInstanceID: exerciseID,
            with: "Echo Bike",
            expectedRevisionToken: token
        ).succeeded)
        model.synchronizeDraft(from: review)
        #expect(model.agentIssueContext == nil, "a resolved draft must stop reporting issues to the model")
    }
}

// MARK: - Import fixtures (file-private mirrors of the WorkoutImportTests stubs)

private struct PassthroughNormalizer: WorkoutImageNormalizing {
    func normalize(_ data: Data) async throws -> ImportedWorkoutImage {
        ImportedWorkoutImage(data: data, pixelWidth: 1, pixelHeight: 1)
    }
}

private struct StubRecognizer: WorkoutTextRecognizing {
    func recognize(image: ImportedWorkoutImage, sourceImageIndex: Int,
                   customWords: [String]) async throws -> [WorkoutTextObservation] {
        []
    }
}

private struct StubParser: WorkoutParsing {
    func parse(observations: [WorkoutTextObservation], catalogHints: [String]) async throws -> WorkoutParserResponse {
        WorkoutParserResponse(document: .init(title: "Unused", blocks: []), model: "test")
    }
}
