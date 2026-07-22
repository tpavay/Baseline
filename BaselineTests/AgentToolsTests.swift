import Foundation
import Testing
@testable import Baseline

@MainActor
struct AgentToolsTests {

    private func tools(base: DecisionEngine.Inputs) -> AgentTools {
        let store = TrainingContextStore(defaults: UserDefaults(suiteName: "tools-\(UUID().uuidString)")!)
        return AgentTools(store: store, base: base)
    }

    private var greenBase: DecisionEngine.Inputs {
        DecisionEngine.Inputs(lnRMSSD: 5.0, sleepScore: 100, energy: 5, mood: 5, stress: 5, soreness: 5)
    }

    // MARK: - Exercise catalog tools

    private func catalogTools() -> AgentTools {
        // The catalog is a global façade, so these need no workout/plan/health wiring.
        AgentTools(store: TrainingContextStore(defaults: UserDefaults(suiteName: "cat-\(UUID().uuidString)")!),
                   base: DecisionEngine.Inputs())
    }

    @Test func searchExercisesReturnsCompactRankedMatchesWithAnHonestTotal() {
        let text = catalogTools().dispatch(.searchExercises(query: "bench", muscle: nil, equipment: nil,
                                                            modality: nil, pattern: nil, tag: nil, level: nil)).text
        #expect(text.localizedCaseInsensitiveContains("Bench Press"))
        #expect(text.contains("bench_press"))          // the id the model needs for get_exercise
        #expect(text.localizedCaseInsensitiveContains("match"))
        // Compact rows carry the axes that let the model choose, and nothing more.
        #expect(text.contains("- bench_press · Bench Press"))
        #expect(text.localizedCaseInsensitiveContains("Barbell"))
        #expect(text.localizedCaseInsensitiveContains("Resistance"))
    }

    @Test func searchExercisesWithNoParamsBrowsesTheLibraryAndStatesItsSize() {
        let text = catalogTools().dispatch(.searchExercises(query: nil, muscle: nil, equipment: nil,
                                                            modality: nil, pattern: nil, tag: nil, level: nil)).text
        // The answer to "what exercises do you have?" must be a concrete number, never "no library".
        #expect(text.contains("\(ExerciseCatalog.definitions.count)"))
        #expect(text.localizedCaseInsensitiveContains("catalog"))
        #expect(text.split(separator: "\n").count == ExerciseSearch.resultLimit + 1)   // header + rows
    }

    @Test func searchExercisesFiltersByMuscle() {
        let text = catalogTools().dispatch(.searchExercises(query: nil, muscle: "quads", equipment: nil,
                                                            modality: nil, pattern: nil, tag: nil, level: nil)).text
        #expect(text.localizedCaseInsensitiveContains("Quadriceps"))   // echoes what it searched
        #expect(text.contains("·"))
    }

    @Test func searchExercisesRejectsAnUnknownFilterWithTheValidValues() {
        let text = catalogTools().dispatch(.searchExercises(query: nil, muscle: "banana", equipment: nil,
                                                            modality: nil, pattern: nil, tag: nil, level: nil)).text
        #expect(text.contains("banana"))
        #expect(text.contains("quadriceps"))           // lists what it will accept, so the model recovers
        #expect(!text.contains("·"))                   // and returns no matches
    }

    @Test func searchExercisesReportsAnEmptyResultHonestly() {
        let text = catalogTools().dispatch(.searchExercises(query: "zzzznotamovement", muscle: nil, equipment: nil,
                                                            modality: nil, pattern: nil, tag: nil, level: nil)).text
        #expect(text.localizedCaseInsensitiveContains("no exercises"))
        #expect(!text.contains("·"))
    }

    @Test func getExerciseReturnsFullDetailIncludingMusclesAndMetrics() {
        let text = catalogTools().dispatch(.getExercise(name: "deadlift", id: nil)).text
        #expect(text.hasPrefix("Deadlift (id deadlift)"))
        #expect(text.localizedCaseInsensitiveContains("Primary muscles: Glutes"))
        #expect(text.localizedCaseInsensitiveContains("Hamstrings"))
        #expect(text.localizedCaseInsensitiveContains("Equipment: Barbell"))
        #expect(text.localizedCaseInsensitiveContains("Movement pattern: Hinge"))
        #expect(text.localizedCaseInsensitiveContains("Modality: Resistance"))
        #expect(text.localizedCaseInsensitiveContains("Compound"))
        #expect(text.localizedCaseInsensitiveContains("Powerlifting"))
        // Metrics use the raw values the metric tools take, plus the defaults.
        #expect(text.contains("Logs: reps, load, rpe"))
        #expect(text.contains("defaults: reps, load, rpe"))
    }

    @Test func getExerciseResolvesByIDAndAlias() {
        #expect(catalogTools().dispatch(.getExercise(name: nil, id: "bench_press")).text.hasPrefix("Bench Press"))
        #expect(catalogTools().dispatch(.getExercise(name: "air squat", id: nil)).text.hasPrefix("Bodyweight Squat"))
    }

    @Test func getExerciseMissTellsTheModelToSearchRatherThanInvent() {
        let text = catalogTools().dispatch(.getExercise(name: "zzzznotamovement", id: nil)).text
        #expect(text.localizedCaseInsensitiveContains("isn't in Baseline's exercise catalog"))
        #expect(text.contains("search_exercises"))
        #expect(!text.contains("(id generic)"))        // never pass the generic fallback off as a real hit
    }

    @Test func getExerciseWithNeitherParameterNamesWhatItNeeded() {
        // The schema has no required[], so the either/or lands here - and a rejection the model can act
        // on beats the runtime's generic "that tool call wasn't valid".
        let text = catalogTools().dispatch(.getExercise(name: nil, id: nil)).text
        #expect(text.contains("name"))
        #expect(text.contains("id"))
        #expect(text.contains("search_exercises"))
        #expect(!text.contains("(id generic)"))
    }

    @Test func catalogReadsStayOutOfTheWhatChangedFeed() {
        // The inspector's feed is what the conversation *changed*. A search changes nothing, so it
        // belongs with the other pure reads, not with the mutations.
        #expect(!AgentTools.Call.searchExercises(query: "bench", muscle: nil, equipment: nil,
                                                 modality: nil, pattern: nil, tag: nil,
                                                 level: nil).showsInActivityFeed)
        #expect(!AgentTools.Call.getExercise(name: "deadlift", id: nil).showsInActivityFeed)
        #expect(!AgentTools.Call.getWeekPlan.showsInActivityFeed)
        // Mutations and Health retrieval still show: the athlete should see those.
        #expect(AgentTools.Call.addBlock(
            name: "Strength",
            intent: nil,
            guidance: nil,
            atIndex: nil,
            expectedRevisionToken: UUID()
        ).showsInActivityFeed)
        #expect(AgentTools.Call.getSleep(nightsAgo: 0).showsInActivityFeed)
    }

    @Test func receiptBoundActivityRecordsOnlyConfirmedMetadataWrites() throws {
        let context = TrainingContextStore(
            defaults: UserDefaults(suiteName: "activity-receipt-\(UUID().uuidString)")!
        )
        let workouts = WorkoutStore(
            units: StubUnitSystem(),
            defaults: UserDefaults(suiteName: "activity-workout-\(UUID().uuidString)")!
        )
        let tools = AgentTools(store: context, base: DecisionEngine.Inputs(), workouts: workouts)
        let unavailableCall = AgentTools.Call.updateWorkoutMetadata(
            title: .set("Race prep"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: UUID()
        )
        let unavailableResponse = tools.dispatch(unavailableCall)

        #expect(ConversationService.shouldRecordActivity(unavailableCall, response: unavailableResponse) == false)

        _ = tools.dispatch(.createWorkout(title: "Original", goal: nil, replaceExisting: false))
        let revision = try #require(workouts.mutationTarget(.plan)?.revisionToken)
        let appliedCall = AgentTools.Call.updateWorkoutMetadata(
            title: .set("Race prep"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: revision
        )
        let appliedResponse = tools.dispatch(appliedCall)

        #expect(appliedResponse.mutationReceipt != nil)
        #expect(ConversationService.shouldRecordActivity(appliedCall, response: appliedResponse))
        #expect(appliedCall.activityLabel == "Renamed workout to Race prep")
        #expect(appliedResponse.userFacingText == "Renamed workout to Race prep.")
    }

    @Test func catalogToolsAreReadOnly() {
        let ctx = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let wk = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
        let t = AgentTools(store: ctx, base: DecisionEngine.Inputs(), workouts: wk)
        _ = t.dispatch(.createWorkout(title: "Push", goal: nil, replaceExisting: false))
        _ = t.dispatch(.searchExercises(query: "bench", muscle: nil, equipment: nil, modality: nil,
                                        pattern: nil, tag: nil, level: nil))
        _ = t.dispatch(.getExercise(name: "deadlift", id: nil))
        #expect(wk.current?.title == "Push")
        #expect(wk.current?.allExercises.isEmpty == true)   // searching never adds anything
    }

    @Test func theModelIsToldTheCatalogIsRetrievable() {
        // The "look these up - nothing else" line is exhaustive; omitting the catalog would suppress it.
        let summary = catalogTools().contextSummary()
        #expect(summary.contains("search_exercises"))
        #expect(summary.contains("\(ExerciseCatalog.definitions.count)-exercise catalog"))
    }

    // MARK: - Workout editing tools

    @Test func workoutToolsEditThroughTheStore() throws {
        let ctx = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let wk = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
        let t = AgentTools(store: ctx, base: DecisionEngine.Inputs(), workouts: wk)
        _ = t.dispatch(.createWorkout(title: "Push", goal: nil, replaceExisting: false))
        let createToken = try #require(wk.mutationTarget(.plan)?.revisionToken)
        _ = t.dispatch(.addBlock(
            name: "Strength",
            intent: nil,
            guidance: nil,
            atIndex: nil,
            expectedRevisionToken: createToken
        ))
        let strengthID = try #require(wk.current?.blocks.first { $0.name == "Strength" }?.id)
        let blockToken = try #require(wk.mutationTarget(.plan)?.revisionToken)
        let r = t.dispatch(.addExercise(
            blockID: strengthID,
            name: "Bench press",
            atIndex: nil,
            sets: 3,
            reps: 8,
            load: 60,
            durationSeconds: nil,
            distanceMeters: nil,
            expectedRevisionToken: blockToken
        ))
        #expect(r.text.localizedCaseInsensitiveContains("bench press"))       // reply echoes the updated workout
        #expect(r.text.contains("MUTATION RECEIPT:"))
        #expect(r.userFacingText == "Added Bench press.")                     // athlete bubble: sentence only
        #expect(!r.userFacingText.contains("MUTATION RECEIPT"))
        #expect(!r.userFacingText.contains("MUTATION TARGET"))
        #expect(r.mutationReceipt?.actor == .agent)
        #expect(r.mutationReceipt?.diff.changes.first?.kind == .add)
        #expect(wk.current?.allExercises.first?.exerciseName == "Bench press")
        #expect(t.dispatch(.getCurrentWorkout).text.localizedCaseInsensitiveContains("strength"))
    }

    @Test func currentWorkoutIDsEnableExactDuplicateMutation() throws {
        let context = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let workouts = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
        let tools = AgentTools(store: context, base: DecisionEngine.Inputs(), workouts: workouts)
        _ = tools.dispatch(.createWorkout(title: "Intervals", goal: nil, replaceExisting: false))
        let createToken = try #require(workouts.mutationTarget(.plan)?.revisionToken)
        _ = tools.dispatch(.addBlock(
            name: "Overload",
            intent: nil,
            guidance: nil,
            atIndex: nil,
            expectedRevisionToken: createToken
        ))
        let overloadID = try #require(workouts.current?.blocks.first { $0.name == "Overload" }?.id)
        let blockToken = try #require(workouts.mutationTarget(.plan)?.revisionToken)
        _ = tools.dispatch(.addExercise(
            blockID: overloadID, name: "Run", atIndex: nil, sets: 1, reps: nil, load: nil,
            durationSeconds: 60, distanceMeters: nil,
            expectedRevisionToken: blockToken
        ))
        let firstExerciseToken = try #require(workouts.mutationTarget(.plan)?.revisionToken)
        _ = tools.dispatch(.addExercise(
            blockID: overloadID, name: "Run", atIndex: nil, sets: 1, reps: nil, load: nil,
            durationSeconds: 120, distanceMeters: nil,
            expectedRevisionToken: firstExerciseToken
        ))

        let block = try #require(workouts.current?.blocks.first { $0.name == "Overload" })
        let first = try #require(block.exercises.first)
        let second = try #require(block.exercises.last)
        let firstSet = try #require(first.prescription.sets.first)
        let summary = tools.dispatch(.getCurrentWorkout).text

        #expect(summary.contains(block.id.uuidString))
        #expect(summary.contains(first.id.uuidString))
        #expect(summary.contains(second.id.uuidString))
        #expect(summary.contains(firstSet.id.uuidString))

        let removeToken = try #require(workouts.mutationTarget(.plan)?.revisionToken)
        let response = tools.dispatch(.removeExercise(
            exerciseInstanceID: second.id,
            expectedRevisionToken: removeToken
        ))

        #expect(response.text.localizedCaseInsensitiveContains("removed the exercise"))
        #expect(workouts.current?.exercise(first.id) != nil)
        #expect(workouts.current?.exercise(second.id) == nil)
    }

    @Test func createWorkoutRefusesToReplaceWithoutConfirmation() {
        let ctx = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let wk = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
        let t = AgentTools(store: ctx, base: DecisionEngine.Inputs(), workouts: wk)
        _ = t.dispatch(.createWorkout(title: "First", goal: nil, replaceExisting: false))
        // Second create without confirmation → refused; existing workout preserved.
        let r = t.dispatch(.createWorkout(title: "Second", goal: nil, replaceExisting: false))
        #expect(r.text.localizedCaseInsensitiveContains("already"))
        #expect(wk.current?.title == "First")
        // With confirmation → replaced.
        _ = t.dispatch(.createWorkout(title: "Second", goal: nil, replaceExisting: true))
        #expect(wk.current?.title == "Second")
    }

    @Test func replaceExerciseTargetsOneOfTwoSameNamedInstancesByID() throws {
        let ctx = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let wk = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
        let tools = AgentTools(store: ctx, base: DecisionEngine.Inputs(), workouts: wk)
        _ = tools.dispatch(.createWorkout(title: "Outdoor Run", goal: nil, replaceExisting: false))
        let createToken = try #require(wk.mutationTarget(.plan)?.revisionToken)
        _ = tools.dispatch(.addBlock(
            name: "Warm-up", intent: nil, guidance: nil, atIndex: nil,
            expectedRevisionToken: createToken
        ))
        let warmupToken = try #require(wk.mutationTarget(.plan)?.revisionToken)
        _ = tools.dispatch(.addBlock(
            name: "Main Run", intent: nil, guidance: nil, atIndex: nil,
            expectedRevisionToken: warmupToken
        ))
        let warmupID = try #require(wk.current?.blocks.first { $0.name == "Warm-up" }?.id)
        let mainID = try #require(wk.current?.blocks.first { $0.name == "Main Run" }?.id)
        let mainToken = try #require(wk.mutationTarget(.plan)?.revisionToken)
        _ = tools.dispatch(.addExercise(
            blockID: warmupID, name: "Treadmill Run", atIndex: nil, sets: 1, reps: nil,
            load: nil, durationSeconds: 300, distanceMeters: nil,
            expectedRevisionToken: mainToken
        ))
        let firstExerciseToken = try #require(wk.mutationTarget(.plan)?.revisionToken)
        _ = tools.dispatch(.addExercise(
            blockID: mainID, name: "Treadmill Run", atIndex: nil, sets: 1, reps: nil,
            load: nil, durationSeconds: 1_800, distanceMeters: nil,
            expectedRevisionToken: firstExerciseToken
        ))
        let before = try #require(wk.current?.allExercises)
        let target = try #require(before.last)

        let replaceToken = try #require(wk.mutationTarget(.plan)?.revisionToken)
        let response = tools.dispatch(.replaceExercise(
            exerciseInstanceID: target.id,
            replacement: "Run",
            expectedRevisionToken: replaceToken
        ))

        let after = try #require(wk.current?.allExercises)
        #expect(response.text.localizedCaseInsensitiveContains("replaced the exercise"))
        #expect(after.count == before.count)
        #expect(Set(after.map(\.id)) == Set(before.map(\.id)))
        #expect(after.first?.exerciseName == "Treadmill Run")
        #expect(after.last?.exerciseName == "Run")
    }

    @Test func requireAllOptionsToolPreservesEveryImportedMovement() {
        let context = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let workouts = WorkoutStore(units: StubUnitSystem(), defaults: UserDefaults(suiteName: "wk-\(UUID().uuidString)")!)
        workouts.create(title: "AMRAP", goal: nil)
        let deadlift = PlannedExercise(
            id: UUID(),
            exerciseName: "Deadlift",
            definitionId: "deadlift",
            selectedMetrics: [.reps, .load],
            prescription: Prescription(
                sets: [PlannedSet(id: UUID(), reps: 12)],
                intensityTargets: [.descriptive("Load target: Bodyweight")]
            ),
            guidance: CoachGuidance(formCues: ["Brace before each rep"])
        )
        let burpee = PlannedExercise(
            id: UUID(),
            exerciseName: "Lateral Burpee Over Barbell",
            definitionId: "lateral_burpee_over_barbell",
            selectedMetrics: [.reps],
            prescription: Prescription(sets: [PlannedSet(id: UUID(), reps: 12)])
        )
        workouts.edit(.plan) { workout in
            workout.blocks[0].nodes.append(.choice(WorkoutChoice(label: "Option B", options: [
                .exercise(deadlift),
                .exercise(burpee),
            ])))
        }
        let tools = AgentTools(store: context, base: DecisionEngine.Inputs(), workouts: workouts)

        let response = tools.dispatch(.requireAllOptions(choice: "Option B"))

        #expect(response.text.localizedCaseInsensitiveContains("required sequence"))
        #expect(workouts.current?.allChoices.isEmpty == true)
        #expect(workouts.current?.allExercises == [deadlift, burpee])
        #expect(workouts.current?.allGroups.first?.children.map(\.id) == [deadlift.id, burpee.id])
    }

    @Test func importConversationScopeAllowsDraftEditsButRejectsUnrelatedMutations() {
        let service = ConversationService(
            tools: tools(base: DecisionEngine.Inputs()),
            scope: .workoutImport
        )

        #expect(service.permits(.replaceExercise(
            exerciseInstanceID: UUID(),
            replacement: "Echo Bike",
            expectedRevisionToken: UUID()
        )))
        #expect(service.permits(.updateLoggingConfig(
            exerciseInstanceID: UUID(),
            enabledMetrics: [.distance, .load],
            units: [.load: .pounds],
            expectedRevisionToken: UUID()
        )))
        #expect(service.permits(.updateWorkoutMetadata(
            title: .set("Imported workout"),
            goal: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: UUID()
        )))
        #expect(service.permits(.updateBlockMetadata(
            blockID: UUID(),
            name: .set("Main"),
            intent: .unchanged,
            guidance: .unchanged,
            expectedRevisionToken: UUID()
        )))
        #expect(service.permits(.updateExerciseMetadata(
            exerciseInstanceID: UUID(),
            displayLabel: .set("Station A"),
            guidance: .unchanged,
            expectedRevisionToken: UUID()
        )))
        #expect(service.permits(.undoWorkoutMutation(
            mutationID: UUID(),
            expectedRevisionToken: UUID()
        )))
        // Wave 7 composite/bulk edits act only on the draft workout, so they belong in the scope.
        #expect(service.permits(.applyWorkoutEdits(
            operations: [.removeSet(setID: UUID())],
            expectedRevisionToken: UUID()
        )))
        #expect(service.permits(.convertWorkoutUnits(
            units: [.distance: .kilometers],
            selector: nil,
            dryRun: true,
            expectedRevisionToken: UUID()
        )))
        #expect(service.permits(.bulkReplaceExercises(
            selector: BulkExerciseSelectorInput(definitionID: "run"),
            replacementDefinitionID: "row",
            dryRun: true,
            expectedRevisionToken: UUID()
        )))
        #expect(!service.permits(.updateExercisePreference(
            exercise: "Sled Pull",
            scope: .exercise,
            units: [.load: .pounds],
            selectedMetrics: [.distance, .load]
        )))
        // Fixing a draft means naming exercises, and the prompt tells the model to search before it
        // adds one it's unsure of - refusing the catalog here would leave it guessing against the
        // generic fallback. Both reads change nothing the scope guards.
        #expect(service.permits(.searchExercises(query: "bike", muscle: nil, equipment: nil,
                                                 modality: nil, pattern: nil, tag: nil, level: nil)))
        #expect(service.permits(.getExercise(name: "Echo Bike", id: nil)))

        #expect(!service.permits(.setSleep(hours: 4)))
        #expect(!service.permits(.moveWorkout(workout: "AMRAP", toDay: "Friday")))
        #expect(!service.permits(.startWorkout))
        #expect(!service.permits(.saveAsTemplate(name: "Imported")))
    }

    @Test func workoutEditWithoutStoreIsGraceful() {
        let r = tools(base: DecisionEngine.Inputs()).dispatch(.addBlock(
            name: "X",
            intent: nil,
            guidance: nil,
            atIndex: nil,
            expectedRevisionToken: UUID()
        ))
        #expect(r.text.localizedCaseInsensitiveContains("workout"))
    }

    // MARK: - Context summary (the model's durable state — verification for the memory fix)

    @Test func contextSummarySurfacesSavedConstraintAndContext() {
        let t = tools(base: DecisionEngine.Inputs())
        _ = t.dispatch(.upsertConstraint(id: nil, kind: .injury, location: "right achilles", severity: 2, affectsTraining: true))
        _ = t.dispatch(.setSleep(hours: 4))
        let summary = t.contextSummary()
        #expect(summary.localizedCaseInsensitiveContains("achilles"))
        #expect(summary.contains("slept 4h"))
    }

    @Test func freshToolsOnSameStoreStillKnowTheConstraint() {
        // Starting a new conversation must not erase structured context.
        let store = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        _ = AgentTools(store: store, base: DecisionEngine.Inputs())
            .dispatch(.upsertConstraint(id: nil, kind: .pain, location: "left calf", severity: 2, affectsTraining: true))
        // A brand-new AgentTools (i.e. a fresh chat) over the same store still sees it.
        let summary = AgentTools(store: store, base: DecisionEngine.Inputs()).contextSummary()
        #expect(summary.localizedCaseInsensitiveContains("calf"))
    }

    @Test func reMentioningAConstraintUpdatesInsteadOfDuplicating() {
        let store = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let t = AgentTools(store: store, base: DecisionEngine.Inputs())
        // "My right calf hurts" then "actually it's not limiting training" — same body part twice.
        _ = t.dispatch(.upsertConstraint(id: nil, kind: .pain, location: "right calf", severity: 1, affectsTraining: true))
        _ = t.dispatch(.upsertConstraint(id: nil, kind: .pain, location: "Right Calf", severity: 1, affectsTraining: false))
        #expect(store.activeConstraintRecords.count == 1)                 // folded, not duplicated
        #expect(store.activeConstraintRecords.first?.affectsTraining == false)
    }

    // MARK: - Retrieval (retrieve-don't-memorize)

    @Test func retrievesHRVReadingsFromTheStore() async {
        let store = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let r = Reading(); r.rmssd = 88; r.meanHR = 52
        let t = AgentTools(store: store, base: DecisionEngine.Inputs(), readings: [r])
        let resp = await t.execute(.getHRVReadings(limit: 5))
        #expect(resp.text.contains("88"))
    }

    @Test func retrievesEmptyReadingsHonestly() async {
        let resp = await tools(base: DecisionEngine.Inputs()).execute(.getHRVReadings(limit: 5))
        #expect(resp.text.localizedCaseInsensitiveContains("no HRV readings"))
    }

    @Test func sleepRetrievalWithoutHealthReportsUnavailable() async {
        // No HealthService wired → honest "can't pull", never a fabricated number.
        let resp = await tools(base: DecisionEngine.Inputs()).execute(.getSleep(nightsAgo: 0))
        #expect(resp.text.localizedCaseInsensitiveContains("apple health"))
    }

    @Test func restingHRRetrievalWithoutHealthReportsUnavailable() async {
        let resp = await tools(base: DecisionEngine.Inputs()).execute(.getRestingHeartRate(days: 7))
        #expect(resp.text.localizedCaseInsensitiveContains("resting heart rate"))
    }

    @Test func retrievableLineOffersOnlyWhatItCanFetch() {
        // Without Health, only HRV readings are retrievable (no sleep/RHR over-claim).
        let noHealth = tools(base: DecisionEngine.Inputs()).contextSummary()
        #expect(noHealth.localizedCaseInsensitiveContains("get_hrv_readings"))
        #expect(!noHealth.localizedCaseInsensitiveContains("get_resting_heart_rate"))
    }

    @Test func healthPresentButNotSetUpNeitherAdvertisesNorConflates() async {
        let store = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let health = HealthService(defaults: UserDefaults(suiteName: "hk-\(UUID().uuidString)")!)  // requested == false
        let t = AgentTools(store: store, base: DecisionEngine.Inputs(), health: health)
        // Not advertised until setup is requested.
        let summary = t.contextSummary()
        #expect(!summary.localizedCaseInsensitiveContains("get_sleep"))
        #expect(!summary.localizedCaseInsensitiveContains("get_resting_heart_rate"))
        // Retrieval reports "not set up" — never conflated with "no data recorded".
        let resp = await t.execute(.getSleep(nightsAgo: 0))
        #expect(resp.text.localizedCaseInsensitiveContains("set up"))
        #expect(!resp.text.localizedCaseInsensitiveContains("no sleep recorded"))
    }

    @Test func contextSummaryReportsCapabilities() {
        // With a health service present, the model is told Apple Health status + the connect action.
        let store = TrainingContextStore(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        let t = AgentTools(store: store, base: DecisionEngine.Inputs(), health: HealthService(), hrvConfigured: false)
        let summary = t.contextSummary()
        #expect(summary.localizedCaseInsensitiveContains("Apple Health"))
        #expect(summary.localizedCaseInsensitiveContains("HRV reading"))
        // Mapper accepts the action tool.
        #expect(ToolCallMapper.map(name: "open_apple_health_setup", input: [:]) == .openAppleHealthSetup)
    }

    @Test func contextSummaryDoesNotInventUnknowns() {
        let summary = tools(base: DecisionEngine.Inputs()).contextSummary()
        #expect(summary.localizedCaseInsensitiveContains("nothing"))   // says nothing is on file
        #expect(!summary.localizedCaseInsensitiveContains("achilles"))
        #expect(!summary.localizedCaseInsensitiveContains("slept"))
    }

    @Test func checkInFromChatMovesOffNoEvidence() {
        // Day-one user with no HRV/sleep — "wiped out, super stressed" must produce a real plan,
        // not evaporate into a note. This is the conversation-first promise.
        let t = tools(base: DecisionEngine.Inputs())
        #expect(t.dispatch(.getToday).decision?.evidenceTier == DecisionEngine.EvidenceTier.none)
        let r = t.dispatch(.setCheckIn(energy: 1, mood: 2, stress: 1, soreness: nil))
        #expect(r.decision?.evidenceTier != DecisionEngine.EvidenceTier.none)
        #expect(r.decision?.domains.contains { $0.domain == .subjective } == true)
        #expect(r.text.contains("Check-in"))
    }

    @Test func reportedShortSleepCapsThePlan() {
        let t = tools(base: DecisionEngine.Inputs())
        let r = t.dispatch(.setSleep(hours: 4))
        #expect(r.decision?.appliedCaps.contains { $0.reason == "poorSleep" } == true)
        #expect(r.decision?.domains.contains { $0.domain == .sleep } == true)
    }

    @Test func emptyCheckInAsksRatherThanLogs() {
        let t = tools(base: DecisionEngine.Inputs())
        let r = t.dispatch(.setCheckIn(energy: nil, mood: nil, stress: nil, soreness: nil))
        #expect(r.decision == nil)                              // nothing logged
        #expect(r.text.localizedCaseInsensitiveContains("tell me"))
    }

    @Test func getTodayReturnsThePlan() {
        let r = tools(base: greenBase).dispatch(.getToday)
        #expect(r.plan != nil)
        #expect(r.decision?.band == .green)
        #expect(r.text.contains("Plan:"))
    }

    @Test func setTimeRecomputesWithNote() {
        let t = tools(base: greenBase)
        let r = t.dispatch(.setTimeAvailable(25))
        #expect(r.plan?.why.contains { $0.contains("25 min") } == true)
        #expect(r.text.contains("25 min"))
    }

    @Test func loggingAConstraintRerouteThePlan() {
        let t = tools(base: greenBase)
        let r = t.dispatch(.upsertConstraint(id: nil, kind: .injury, location: "Right Achilles",
                                             severity: 2, affectsTraining: true))
        #expect(r.plan?.type == .lowImpact)                                   // green body, rerouted
        #expect(r.plan?.avoid.contains { $0.localizedCaseInsensitiveContains("achilles") } == true)
    }

    @Test func nonTrainingConstraintDoesNotChangeThePlan() {
        let t = tools(base: greenBase)
        let r = t.dispatch(.upsertConstraint(id: nil, kind: .injury, location: "Left pinky",
                                             severity: 3, affectsTraining: false))
        #expect(r.decision?.band == .green)                                   // honored — no gate
    }

    @Test func upsertRejectsEmptyLocation() {
        let t = tools(base: greenBase)
        let r = t.dispatch(.upsertConstraint(id: nil, kind: .pain, location: "  ",
                                             severity: 2, affectsTraining: true))
        #expect(r.plan == nil)                                                // rejected, no mutation
        #expect(r.text.localizedCaseInsensitiveContains("location"))
    }

    @Test func illnessDowngradesThePlan() {
        let r = tools(base: greenBase).dispatch(.setIllness(true))
        #expect(r.decision?.band == .red)
        #expect(r.plan?.type == .activeRecovery)           // sick user no longer gets "intensity on"
    }

    @Test func resolvingMissingConstraintReportsFailure() {
        let r = tools(base: greenBase).dispatch(.resolveConstraint(id: UUID()))
        #expect(r.plan == nil)                             // nothing mutated
        #expect(r.text.localizedCaseInsensitiveContains("couldn't find"))
    }

    @Test func negativeTimeIsSanitizedInTheMessage() {
        let r = tools(base: greenBase).dispatch(.setTimeAvailable(-20))
        #expect(!r.text.contains("-20"))                   // no lie: stored 0, reports 0
        #expect(r.text.contains("0 min"))
    }

    @Test func explainDescribesLimiterAndAvoid() {
        // A capped day so there's a limiter to explain.
        let base = DecisionEngine.Inputs(lnRMSSD: 5.0, energy: 5, mood: 5, stress: 5, soreness: 1)
        let r = tools(base: base).dispatch(.explain)
        #expect(r.text.localizedCaseInsensitiveContains("limiter"))
        #expect(r.text.localizedCaseInsensitiveContains("avoid"))
    }
}
