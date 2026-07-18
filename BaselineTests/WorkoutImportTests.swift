import Foundation
import SwiftData
import Testing
@testable import Baseline

private final class WorkoutImportTestsBundleMarker: NSObject {}

private struct RealisticWorkoutOCRFixture: Decodable {
    var schemaVersion: Int
    var pages: [WorkoutImportSourcePage]
    var expectedTerms: [String]
}

private func realisticFivePageRequest(
    fixture: RealisticWorkoutOCRFixture
) throws -> WorkoutImportRemoteStartRequest {
    var pages = fixture.pages
    let verticalPositions = [0.20, 0.30, 0.36, 0.16, 0.18]
    for index in pages.indices {
        let text = ("Fixture page \(index + 1) coaching context. " + String(
            repeating: "Keep every instruction attached to its intended workout scope and preserve the athlete-facing detail. ",
            count: 18
        )).trimmingCharacters(in: .whitespaces)
        pages[index].observations.append(WorkoutTextObservation(
            id: "p\(index)-long-context",
            text: text,
            confidence: 0.98,
            boundingBox: .init(
                x: 0.08,
                y: verticalPositions[index],
                width: 0.84,
                height: 0.04
            ),
            sourceImageIndex: index
        ))
    }
    let source = try WorkoutImportSourceDocumentBuilder.build(pages: pages)
    return WorkoutImportRemoteStartRequest(
        clientJobID: "11111111-1111-4111-8111-111111111111",
        requestID: "22222222-2222-4222-8222-222222222222",
        jobHash: WorkoutImportStableIdentity.digest(source.sections.map(\.id)),
        sections: source.sections,
        catalogHints: [
            "Echo Bike",
            "Sled Pull",
            "Deadlift",
            "Lateral Burpee Over Barbell",
            "Dumbbell Push Press",
            "SkiErg",
        ]
    )
}

@Suite("Workout import parser errors")
struct WorkoutImportParserErrorTests {
    @Test func firebaseDeadlineIsReportedSeparatelyFromOtherRemoteFailures() {
        let deadline = NSError(domain: "com.firebase.functions", code: 4)
        let unavailable = NSError(domain: "com.firebase.functions", code: 14)
        let incompatible = NSError(domain: "com.firebase.functions", code: 9)
        let unrelatedDeadline = NSError(domain: NSURLErrorDomain, code: 4)

        #expect(FirebaseWorkoutParser.mapRemoteError(deadline) as? WorkoutParserError == .timedOut)
        #expect(FirebaseWorkoutParser.mapRemoteError(unavailable) as? WorkoutParserError == .remoteFailure)
        #expect(FirebaseWorkoutParser.mapRemoteError(incompatible) as? WorkoutParserError == .schemaIncompatible)
        #expect(FirebaseWorkoutParser.mapRemoteError(unrelatedDeadline) as? WorkoutParserError == .remoteFailure)
        #expect(FirebaseWorkoutParser.mapRemoteError(CancellationError()) is CancellationError)
        #expect(WorkoutParserError.timedOut.localizedDescription == "Parsing took too long. Try again in a moment.")
        #expect(FirebaseWorkoutParser.callableTimeoutSeconds == 195)
    }

    @Test @MainActor
    func parserAppliesTheExtendedTimeoutToTheCallableItActuallyUses() async throws {
        let callable = RecordingWorkoutImportRemoteCallable(result: [
            "document": [
                "title": "Imported",
                "notes": [],
                "blocks": [["name": "Main", "notes": [], "exercises": []]],
            ],
            "model": "test-model",
        ])
        let parser = FirebaseWorkoutParser(makeCallable: { callable })

        let response = try await parser.parse(observations: [], catalogHints: [])

        #expect(callable.timeoutAtCall == 195)
        #expect(callable.payloadAtCall != nil)
        #expect(response.document.title == "Imported")
        #expect(response.model == "test-model")
    }
}

private final class RecordingWorkoutImportRemoteCallable: WorkoutImportRemoteCalling, @unchecked Sendable {
    var timeoutInterval: TimeInterval = 70
    private(set) var timeoutAtCall: TimeInterval?
    private(set) var payloadAtCall: String?
    private let result: Any

    init(result: Any) {
        self.result = result
    }

    func call(payload: String) async throws -> Any {
        timeoutAtCall = timeoutInterval
        payloadAtCall = payload
        return result
    }
}

@Suite("Workout import domain")
struct WorkoutImportTests {
    @Test func pendingImportResolutionScopesResumeToTheOpenedDay() {
        let calendar = Calendar.planWeek
        let tuesday = Date(timeIntervalSince1970: 1_700_000_000)
        let wednesday = tuesday.addingTimeInterval(24 * 60 * 60)
        let tuesdayDraft = WorkoutImportPendingSummary(
            jobID: UUID(), scheduleDate: tuesday, stage: .reviewing, isReviewable: true
        )
        let wednesdayDraft = WorkoutImportPendingSummary(
            jobID: UUID(), scheduleDate: wednesday, stage: .reviewing, isReviewable: true
        )

        // No unfinished import → fresh selection.
        #expect(PendingImportResolution.decide(pendings: [], targetDay: wednesday, calendar: calendar) == .fresh)

        // No target day (non-day entry) → resume the most recent.
        #expect(
            PendingImportResolution.decide(pendings: [tuesdayDraft], targetDay: nil, calendar: calendar)
                == .resume(tuesdayDraft.jobID)
        )

        // A draft for the opened day → silently resume that one, not the newer other-day draft.
        #expect(
            PendingImportResolution.decide(
                pendings: [wednesdayDraft, tuesdayDraft], targetDay: wednesday, calendar: calendar
            ) == .resume(wednesdayDraft.jobID)
        )

        // Only another day's draft exists → prompt instead of silently reappearing here.
        #expect(
            PendingImportResolution.decide(pendings: [tuesdayDraft], targetDay: wednesday, calendar: calendar)
                == .promptOther(tuesdayDraft)
        )
    }

    @Test func providerCatalogHintsKeepCanonicalIdentityAndBoundedAliases() {
        let catalog = ExerciseCatalog.definitions.filter { ["bike_erg", "echo_bike"].contains($0.id) }

        let hints = WorkoutImportCoordinator.providerCatalogHints(catalog)

        #expect(hints == [
            "BikeErg | aliases: bike erg; concept2 bike; c2 bike",
            "Echo Bike | aliases: rogue echo bike; assault bike; air bike",
        ])
        #expect(hints.allSatisfy { $0.count <= 120 })
    }

    @Test func canonicalServerDocumentDecodesEveryAcceptedMetricAndUnitIntoTheDraft() throws {
        let testBundle = Bundle(for: WorkoutImportTestsBundleMarker.self)
        let fixtureURL = try #require(testBundle.url(
            forResource: "canonical-assembled-document",
            withExtension: "json"
        ))
        #expect(fixtureURL.standardizedFileURL.path.hasPrefix(
            testBundle.bundleURL.standardizedFileURL.path + "/"
        ))
        let document = try JSONDecoder().decode(
            ParsedWorkoutDocument.self,
            from: Data(contentsOf: fixtureURL)
        )
        let result = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let group = try #require(result.draft.workout.allGroups.first)
        let exercise = try #require(result.draft.workout.allExercises.first { $0.prescription.sets.count == 16 })
        let expectedValues: [(MetricType, Double)] = [
            (.reps, 12),
            (.load, 20),
            (.load, 4.5359237),
            (.duration, 30),
            (.duration, 120),
            (.distance, 100),
            (.distance, 1_000),
            (.distance, 1_609.344),
            (.calories, 15),
            (.heartRate, 150),
            (.heartRateZoneTime, 30),
            (.heartRateZoneTime, 120),
            (.cadence, 90),
            (.power, 250),
            (.pace, 0.3),
            (.rpe, 7),
        ]

        #expect(result.issues.contains { $0.severity == .blocking } == false)
        #expect(exercise.selectedMetrics == MetricType.allCases)
        #expect(exercise.prescription.sets.count == expectedValues.count)
        for (index, expected) in expectedValues.enumerated() {
            let actual = exercise.prescription.sets[index].values[expected.0]
            #expect(abs((actual ?? .infinity) - expected.1) < 0.0001)
        }
        let firstSet = try #require(exercise.prescription.sets.first)
        let alternative = try #require(firstSet.alternatives.first)
        #expect(alternative.label == "Scaled")
        #expect(alternative.values[.distance] == 50)
        #expect(firstSet.ranges.first?.upper == 15)
        #expect(firstSet.progressions.first?.delta == 1)
        #expect(firstSet.effortTarget == .rpe(7))
        #expect(exercise.prescription.intensityTargets == [.power(lower: 200, upper: 300, unit: .watts)])
        #expect(group.execution.repetition.fixedCount == 2)
        #expect(group.execution.cadence == .init(intervalSeconds: 60, scope: .cycle))
        #expect(group.execution.adjustments == [
            .init(metric: .duration, step: 600, minimum: 3_600, maximum: 4_800),
        ])
        #expect(group.phase == .main)
        #expect(group.doseLayer == .med)
        #expect(group.isOptional)
        #expect(result.draft.workout.allChoices.count == 1)
        #expect(group.children.contains { node in
            if case .rest = node { return true }
            return false
        })
        #expect(result.evidence.contains { $0.sourceObservationIDs == ["o-exercise"] })
        #expect(result.issues.contains { $0.code == .ambiguousStructure })
    }

    @Test func invalidPowerIntensityUnitDoesNotSilentlyBecomeWatts() throws {
        let source = ParsedIntensityTarget(type: "power", lower: 200, upper: 300, unit: "bananas")
        let document = ParsedWorkoutDocument(title: "Power", blocks: [
            ParsedWorkoutBlock(name: "Main", exercises: [
                ParsedWorkoutExercise(
                    name: "Run",
                    sets: [],
                    intensityTargets: [source]
                ),
            ]),
        ])
        let result = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let exercise = try #require(result.draft.workout.allExercises.first)
        let issue = try #require(result.issues.first {
            $0.code == .unsupportedIntensityTarget && $0.severity == .blocking
        })
        let unresolved = try #require(issue.unresolvedIntensity)

        #expect(exercise.prescription.intensityTargets == [
            .descriptive("Unresolved power target: 200-300 bananas"),
        ])
        #expect(issue.exerciseID == exercise.id)
        #expect(issue.setID == nil)
        #expect(issue.metric == nil)
        #expect(unresolved.source == source)
        #expect(unresolved.marker == exercise.prescription.intensityTargets.first)
        #expect(unresolved.occurrence == 1)
        #expect(issue.message == "Run: choose a supported unit for the power target (200-300 bananas), or remove this unresolved target.")
        let roundTripped = try JSONDecoder().decode(
            WorkoutImportIssue.self,
            from: JSONEncoder().encode(issue)
        )
        #expect(roundTripped == issue)
        #expect(ImportSession(draft: result.draft, issues: result.issues).canSave == false)
    }

    @Test func unitlessDimensionalMetricsStayUnresolvedInsteadOfUsingCanonicalUnits() throws {
        let expectedMetrics: [MetricType] = [
            .load, .duration, .distance, .heartRateZoneTime, .cadence, .power, .pace,
        ]
        let exercise = ParsedWorkoutExercise(
            name: "Run",
            sets: expectedMetrics.map { metric in
                ParsedWorkoutSet(metrics: [.init(type: metric.rawValue, value: 10)])
            }
        )

        let result = WorkoutImportDraftBuilder.build(
            ParsedWorkoutDocument(title: "Missing units", blocks: [
                ParsedWorkoutBlock(name: "Main", exercises: [exercise]),
            ]),
            catalog: ExerciseCatalog.definitions
        )
        let draftExercise = try #require(result.draft.workout.allExercises.first)
        let unresolved = result.issues.filter {
            $0.code == .unsupportedMetric && $0.severity == .blocking
        }

        #expect(unresolved.compactMap(\.metric) == expectedMetrics)
        #expect(draftExercise.prescription.sets.allSatisfy { set in
            expectedMetrics.allSatisfy { set.values[$0] == nil }
        })
        #expect(ImportSession(draft: result.draft, issues: result.issues).canSave == false)
    }

    @Test func unitlessSafeMetricsAndUnitEncodedTypeAliasesRemainDeterministic() throws {
        let document = ParsedWorkoutDocument(title: "Encoded units", blocks: [
            ParsedWorkoutBlock(name: "Main", exercises: [
                ParsedWorkoutExercise(name: "Run", sets: [
                    .init(metrics: [.init(type: "reps", value: 12)]),
                    .init(metrics: [.init(type: "calories", value: 20)]),
                    .init(metrics: [.init(type: "heartRate", value: 150)]),
                    .init(metrics: [.init(type: "rpe", value: 7)]),
                    .init(metrics: [.init(type: "seconds", value: 30)]),
                    .init(metrics: [.init(type: "meters", value: 400)]),
                    .init(metrics: [.init(type: "rpm", value: 90)]),
                    .init(metrics: [.init(type: "watts", value: 250)]),
                ]),
            ]),
        ])

        let result = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let sets = try #require(result.draft.workout.allExercises.first?.prescription.sets)

        #expect(result.issues.contains { $0.severity == .blocking } == false)
        #expect(sets[0].values[.reps] == 12)
        #expect(sets[1].values[.calories] == 20)
        #expect(sets[2].values[.heartRate] == 150)
        #expect(sets[3].values[.rpe] == 7)
        #expect(sets[4].values[.duration] == 30)
        #expect(sets[5].values[.distance] == 400)
        #expect(sets[6].values[.cadence] == 90)
        #expect(sets[7].values[.power] == 250)
    }

    @Test func explicitUnitsCannotContradictUnitEncodedMetricTypes() throws {
        let result = WorkoutImportDraftBuilder.build(
            ParsedWorkoutDocument(title: "Contradictory units", blocks: [
                ParsedWorkoutBlock(name: "Main", exercises: [
                    ParsedWorkoutExercise(name: "Run", sets: [
                        .init(metrics: [.init(type: "seconds", value: 30, unit: "minutes")]),
                        .init(metrics: [.init(type: "meters", value: 400, unit: "mi")]),
                        .init(metrics: [.init(type: "seconds", value: 45, unit: "seconds")]),
                    ]),
                ]),
            ]),
            catalog: ExerciseCatalog.definitions
        )
        let exercise = try #require(result.draft.workout.allExercises.first)
        let blocking = result.issues.filter { $0.code == .unsupportedMetric && $0.severity == .blocking }

        #expect(blocking.compactMap(\.metric) == [.duration, .distance])
        #expect(exercise.prescription.sets[0].values[.duration] == nil)
        #expect(exercise.prescription.sets[1].values[.distance] == nil)
        #expect(exercise.prescription.sets[2].values[.duration] == 45)
    }

    @Test func legacyImportIssuesDecodeWithoutUnresolvedIntensityMetadata() throws {
        let json = #"{"id":"2A6AB8C6-F298-4F56-A0D2-FF6D05947121","code":"unsupportedMetric","severity":"blocking","message":"Confirm distance.","candidates":[]}"#

        let issue = try JSONDecoder().decode(WorkoutImportIssue.self, from: Data(json.utf8))

        #expect(issue.code == .unsupportedMetric)
        #expect(issue.unresolvedIntensity == nil)
    }

    @Test func exactAliasesAutoMatchAndUnitsBecomeCanonical() throws {
        let document = ParsedWorkoutDocument(title: "HYROX", blocks: [
            ParsedWorkoutBlock(name: "Main", exercises: [
                ParsedWorkoutExercise(name: "farmer's carry", sets: [
                    ParsedWorkoutSet(metrics: [
                        .init(type: "distance", value: 1, unit: "km"),
                        .init(type: "load", value: 50, unit: "lb"),
                    ]),
                ], sourceObservationIDs: ["line-1"]),
            ]),
        ])

        let result = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let exercise = try #require(result.draft.workout.allExercises.first)
        let set = try #require(exercise.prescription.sets.first)
        #expect(exercise.definitionId == "farmers_carry")
        #expect(result.issues.isEmpty)
        #expect(set.values[.distance] == 1_000)
        #expect(abs((set.values[.load] ?? 0) - 22.6796185) < 0.0001)
        #expect(exercise.displayUnits[.distance] == .kilometers)
        #expect(exercise.displayUnits[.load] == .pounds)
    }

    @Test func unknownExerciseBlocksSavingWithoutCreatingCatalogData() throws {
        let document = ParsedWorkoutDocument(title: "Odd workout", blocks: [
            ParsedWorkoutBlock(name: "", exercises: [
                ParsedWorkoutExercise(name: "Moon hops", sets: [.init(metrics: [.init(type: "reps", value: 10)])]),
            ]),
        ])
        let result = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let exercise = try #require(result.draft.workout.allExercises.first)
        #expect(exercise.definitionId == nil)
        #expect(result.issues.contains { $0.code == .unknownExercise && $0.severity == .blocking })
        #expect(ImportSession(draft: result.draft, issues: result.issues).canSave == false)
    }

    @Test func contextualRunNamesAndSquatAliasesResolveToCanonicalIdentities() {
        let exercises = [
            ParsedWorkoutExercise(name: "Run - warmup", sets: []),
            ParsedWorkoutExercise(name: "Run - main", sets: []),
            ParsedWorkoutExercise(name: "100m strides", sets: []),
            ParsedWorkoutExercise(name: "Run - cooldown", sets: []),
            ParsedWorkoutExercise(name: "Air Squats", sets: []),
            ParsedWorkoutExercise(name: "Jump Squats", sets: []),
        ]
        let result = WorkoutImportDraftBuilder.build(
            .init(title: "Run + finisher", blocks: [.init(name: "Main", exercises: exercises)]),
            catalog: ExerciseCatalog.definitions
        )

        #expect(result.draft.workout.allExercises.map(\.definitionId) == [
            "run", "run", "run", "run", "bodyweight_squat", "jump_squat",
        ])
        #expect(result.draft.workout.allExercises.map(\.exerciseName) == [
            "Run", "Run", "Run", "Run", "Bodyweight Squat", "Jump Squat",
        ])
        #expect(result.issues.isEmpty)
    }

    @Test func unsupportedAndInvalidMetricsBecomeTypedIssues() {
        let document = ParsedWorkoutDocument(title: "Bad values", blocks: [
            ParsedWorkoutBlock(name: "", exercises: [
                ParsedWorkoutExercise(name: "Run", sets: [.init(metrics: [
                    .init(type: "stride color", value: 4),
                    .init(type: "distance", value: -.infinity, unit: "m"),
                ])]),
            ]),
        ])
        let result = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let exercise = result.draft.workout.allExercises.first
        let invalidIssue = result.issues.first { $0.code == .invalidValue }
        #expect(result.issues.contains { $0.code == .unsupportedMetric })
        #expect(invalidIssue?.severity == .blocking)
        #expect(invalidIssue?.exerciseID == exercise?.id)
        #expect(invalidIssue?.setID == exercise?.prescription.sets.first?.id)
        #expect(invalidIssue?.metric == .distance)
        #expect(exercise?.selectedMetrics.contains(.distance) == true)
    }

    @Test func unknownUnitIssueTargetsTheExactAffectedSet() throws {
        let document = ParsedWorkoutDocument(title: "Track", blocks: [
            ParsedWorkoutBlock(name: "Main", exercises: [
                ParsedWorkoutExercise(name: "Run", sets: [
                    .init(metrics: [.init(type: "distance", value: 400, unit: "m")]),
                    .init(metrics: [.init(type: "distance", value: 100, unit: "yd")]),
                ]),
            ]),
        ])

        let result = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let exercise = try #require(result.draft.workout.allExercises.first)
        let issue = try #require(result.issues.first { $0.severity == .blocking && $0.metric == .distance })

        #expect(exercise.prescription.sets[0].distance == 400)
        #expect(exercise.prescription.sets[1].distance == nil)
        #expect(issue.exerciseID == exercise.id)
        #expect(issue.setID == exercise.prescription.sets[1].id)
        #expect(issue.alternativeID == nil)
    }

    @Test func unknownUnitInsideAlternativeTargetsTheStableAlternativeIdentity() throws {
        let document = ParsedWorkoutDocument(title: "Intervals", blocks: [
            ParsedWorkoutBlock(name: "Main", exercises: [
                ParsedWorkoutExercise(name: "Run", sets: [
                    .init(
                        metrics: [.init(type: "distance", value: 400, unit: "m")],
                        alternatives: [
                            .init(label: "Short course", metrics: [
                                .init(type: "distance", value: 100, unit: "yd"),
                            ]),
                        ]
                    ),
                ]),
            ]),
        ])

        let result = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let exercise = try #require(result.draft.workout.allExercises.first)
        let set = try #require(exercise.prescription.sets.first)
        let alternative = try #require(set.alternatives.first)
        let issue = try #require(result.issues.first { $0.severity == .blocking })

        #expect(set.distance == 400)
        #expect(alternative.values[.distance] == nil)
        #expect(issue.setID == set.id)
        #expect(issue.alternativeID == alternative.id)
        #expect(issue.metric == .distance)
        #expect(issue.message.contains("set 1"))
        #expect(issue.message.contains("Short course"))
    }

    @Test func materializationRefreshesEveryIdentityAndFingerprintIgnoresThem() throws {
        let original = Workout(title: "Strength", blocks: [
            WorkoutBlock(name: "Main", exercises: [
                PlannedExercise(exerciseName: "Deadlift", definitionId: "deadlift",
                                selectedMetrics: [.reps, .load],
                                prescription: Prescription(sets: [PlannedSet(
                                    reps: 5,
                                    load: 100,
                                    alternatives: [PlannedSetAlternative(
                                        label: "Lighter",
                                        values: MetricValues([.load: 80])
                                    )]
                                )])),
            ]),
        ])
        let materialized = WorkoutImportMaterializer.materialize(.init(workout: original))
        #expect(materialized.id != original.id)
        #expect(materialized.blocks[0].id != original.blocks[0].id)
        #expect(materialized.allExercises[0].id != original.allExercises[0].id)
        #expect(materialized.allExercises[0].prescription.sets[0].id != original.allExercises[0].prescription.sets[0].id)
        #expect(materialized.allExercises[0].prescription.sets[0].alternatives[0].id
                != original.allExercises[0].prescription.sets[0].alternatives[0].id)
        #expect(WorkoutFingerprint.value(for: materialized) == WorkoutFingerprint.value(for: original))
    }

    @Test func legacySetAlternativeDecodesWithAStableGeneratedIdentity() throws {
        let legacy = #"{"label":"Short course","values":{"distance":100},"ranges":[]}"#
        let decoded = try JSONDecoder().decode(PlannedSetAlternative.self, from: Data(legacy.utf8))
        let roundTripped = try JSONDecoder().decode(
            PlannedSetAlternative.self,
            from: JSONEncoder().encode(decoded)
        )

        #expect(decoded.label == "Short course")
        #expect(decoded.values[.distance] == 100)
        #expect(roundTripped.id == decoded.id)
    }

    @Test func progressiveAmrapBuildsNativeGroupChoiceAndRoundFormula() throws {
        let ski = ParsedWorkoutExercise(name: "SkiErg", sets: [.init(metrics: [
            .init(type: "calories", value: 10, progressionDelta: 1, progressionEvery: 1, progressionUnit: "round"),
        ])])
        let choice = ParsedWorkoutChoice(label: "Choose bike", options: [
            .exercise(.init(name: "Concept2 Bike", sets: [.init(metrics: [.init(type: "duration", value: 360, unit: "seconds")])])),
            .exercise(.init(name: "Stationary Bike", sets: [.init(metrics: [.init(type: "duration", value: 360, unit: "seconds")])])),
        ])
        let amrap = ParsedWorkoutGroup(label: "70-minute AMRAP", durationSeconds: 4_200,
                                       scoring: "roundsAndReps",
                                       adjustments: [.init(metric: "duration", step: 600)],
                                       children: [.exercise(ski), .choice(choice)])
        let document = ParsedWorkoutDocument(title: "Progressive AMRAP", blocks: [
            ParsedWorkoutBlock(name: "Main", nodes: [.group(amrap)]),
        ])
        let result = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let group = try #require(result.draft.workout.allGroups.first)
        #expect(group.execution.repetition.durationSeconds == 4_200)
        #expect(group.execution.adjustments.first?.step == 600)
        #expect(result.draft.workout.allChoices.count == 1)
        let set = try #require(result.draft.workout.allExercises.first { $0.definitionId == "ski_erg" }?.prescription.sets.first)
        #expect(set.expectedValues(iteration: 6)[.calories] == 15)
    }

    @Test func tempoIntervalsKeepRestBetweenRepetitions() throws {
        let run = ParsedWorkoutExercise(name: "Run", sets: [.init(metrics: [.init(type: "duration", value: 780, unit: "seconds")])],
                                        intensityTargets: [.init(type: "descriptive", value: "Tempo pace")])
        let group = ParsedWorkoutGroup(label: "Tempo", repeatCount: 3, children: [
            .exercise(run),
            .rest(.init(durationSeconds: 90, placement: "betweenRepetitions")),
        ])
        let result = WorkoutImportDraftBuilder.build(.init(title: "Tempo", blocks: [
            .init(name: "Main", nodes: [.group(group)]),
        ]), catalog: ExerciseCatalog.definitions)
        let built = try #require(result.draft.workout.allGroups.first)
        #expect(built.execution.repetition.fixedCount == 3)
        guard case .rest(let rest) = built.children.last else { Issue.record("Expected rest node"); return }
        #expect(rest.durationSeconds == 90)
        #expect(rest.placement == .betweenRepetitions)
    }

    @Test func stridesKeepActiveRecoveryAsASeparateRangedInterval() throws {
        let strides = ParsedWorkoutExercise(
            name: "Run",
            sets: [.init(metrics: [.init(type: "distance", value: 100, unit: "m")])],
            intent: "speed"
        )
        let easyJog = ParsedWorkoutExercise(
            name: "Run",
            sets: [.init(metrics: [.init(type: "duration", value: 40, unit: "seconds", upperValue: 50)])],
            intent: "recovery"
        )
        let group = ParsedWorkoutGroup(label: "Strides", repeatCount: 6,
                                       children: [.exercise(strides), .exercise(easyJog)])
        let result = WorkoutImportDraftBuilder.build(
            .init(title: "Run", blocks: [.init(name: "Main", nodes: [.group(group)])]),
            catalog: ExerciseCatalog.definitions
        )

        let built = try #require(result.draft.workout.allGroups.first)
        #expect(built.execution.repetition.fixedCount == 6)
        let exercises = built.children.flatMap(\.exercises)
        #expect(exercises.count == 2)
        #expect(exercises[0].prescription.sets[0].distance == 100)
        #expect(exercises[0].prescription.sets[0].duration == nil)
        #expect(exercises[1].prescription.intent == .recovery)
        #expect(exercises[1].prescription.sets[0].ranges == [
            MetricTargetRange(metric: .duration, lower: 40, upper: 50),
        ])
    }

    @Test func materializesAndRoundTripsNotesAtEveryLevel() throws {
        let longWorkoutNote = "Start conservatively and keep transitions smooth.\n\nIf breathing becomes ragged, reduce the machine pace before changing the strength work."
        let longBlockNote = "Complete this block continuously. The listed loads are ceilings, not targets, and clean movement takes priority."
        let groupNote = "Move directly from the run into the carry."
        let exerciseNote = "Keep the ribs stacked and use short, controlled steps."
        let group = ParsedWorkoutGroup(
            label: "Three rounds",
            repeatCount: 3,
            children: [
                .exercise(.init(name: "Farmer's Carry", sets: [], notes: [exerciseNote])),
            ],
            notes: [groupNote]
        )
        let document = ParsedWorkoutDocument(
            title: "Long coaching session",
            notes: [longWorkoutNote],
            blocks: [.init(name: "Main", nodes: [.group(group)], notes: [longBlockNote])]
        )

        let workout = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions).draft.workout
        #expect(workout.guidance?.formCues == [longWorkoutNote])
        #expect(workout.blocks.first?.guidance?.formCues == [longBlockNote])
        #expect(workout.allGroups.first?.guidance?.formCues == [groupNote])
        #expect(workout.allExercises.first?.guidance?.formCues == [exerciseNote])

        let decoded = try JSONDecoder().decode(Workout.self, from: JSONEncoder().encode(workout))
        #expect(decoded == workout)
    }

    @Test func notesParticipateInDuplicateFingerprinting() {
        let first = Workout(title: "Intervals", guidance: CoachGuidance(formCues: ["Hold back on round one"]))
        let second = Workout(title: "Intervals", guidance: CoachGuidance(formCues: ["Attack round one"]))
        #expect(WorkoutFingerprint.value(for: first) != WorkoutFingerprint.value(for: second))
    }

    @Test func qualitativeLoadsStayStructuredWithoutInventingAWeight() throws {
        let document = ParsedWorkoutDocument(title: "Aerobic capacity", blocks: [
            ParsedWorkoutBlock(name: "Option B", exercises: [
                ParsedWorkoutExercise(
                    name: "Deadlift",
                    sets: [.init(metrics: [.init(type: "reps", value: 12)])],
                    notes: ["Put your bodyweight on the bar."]
                ),
                ParsedWorkoutExercise(
                    name: "Sled Pull",
                    sets: [.init(metrics: [.init(type: "distance", value: 25, unit: "m")])],
                    intensityTargets: [.init(type: "descriptive", value: "Load target: Race weight")]
                ),
            ]),
        ])

        let result = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let deadlift = try #require(result.draft.workout.allExercises.first { $0.definitionId == "deadlift" })
        let sled = try #require(result.draft.workout.allExercises.first { $0.definitionId == "sled_pull" })

        #expect(deadlift.selectedMetrics.contains(.load))
        #expect(deadlift.prescription.sets.first?.load == nil)
        #expect(deadlift.prescription.intensityTargets.contains(.descriptive("Load target: Bodyweight")))
        #expect(sled.selectedMetrics.contains(.load))
        #expect(sled.prescription.sets.first?.load == nil)
        #expect(sled.prescription.intensityTargets.contains(.descriptive("Load target: Race weight")))
        #expect(result.issues.isEmpty)
    }

    @Test func plusJoinedOptionIsRequiredWorkNotAnInventedEitherOrExercise() throws {
        let sourceID = "option-b"
        let parsedChoice = ParsedWorkoutChoice(
            label: "Option B: Deadlifts or Lateral Burpees",
            options: [
                .exercise(.init(
                    name: "Deadlift",
                    sets: [.init(metrics: [.init(type: "reps", value: 12)])],
                    sourceObservationIDs: [sourceID]
                )),
                .exercise(.init(
                    name: "Lateral Burpee Over Barbell",
                    sets: [.init(metrics: [.init(type: "reps", value: 12)])],
                    sourceObservationIDs: [sourceID]
                )),
            ],
            sourceObservationIDs: [sourceID]
        )
        let document = ParsedWorkoutDocument(
            title: "AMRAP",
            blocks: [.init(name: "Main", nodes: [.choice(parsedChoice)])]
        )
        let observation = WorkoutTextObservation(
            id: sourceID,
            text: "B. 12 Deadlifts @ Bodyweight + 12 lateral burpees over barbell.",
            confidence: 0.99,
            boundingBox: .init(x: 0.1, y: 0.3, width: 0.8, height: 0.08)
        )

        let normalized = WorkoutImportSemanticNormalizer.normalize(document, observations: [observation])
        let result = WorkoutImportDraftBuilder.build(normalized, catalog: ExerciseCatalog.definitions)
        let group = try #require(result.draft.workout.allGroups.first)

        #expect(group.label == "Option B")
        #expect(group.children.count == 2)
        #expect(result.draft.workout.allChoices.isEmpty)
        #expect(result.draft.workout.allExercises.map(\.definitionId) == [
            "deadlift", "lateral_burpee_over_barbell",
        ])
    }

    @Test func explicitOrRemainsAChoiceAndAlternateAAndBBecomesASequence() throws {
        let choice = ParsedWorkoutChoice(
            label: "Bike",
            options: [
                .exercise(.init(name: "Concept2 Bike", sets: [], sourceObservationIDs: ["bike"])),
                .exercise(.init(name: "Echo Bike", sets: [], sourceObservationIDs: ["bike"])),
            ],
            sourceObservationIDs: ["bike"]
        )
        let alternate = ParsedWorkoutChoice(
            label: "A & B",
            options: [
                .exercise(.init(name: "Sled Pull", sets: [], sourceObservationIDs: ["alternate"])),
                .exercise(.init(name: "Deadlift", sets: [], sourceObservationIDs: ["alternate"])),
            ],
            sourceObservationIDs: ["alternate"]
        )
        let document = ParsedWorkoutDocument(
            title: "Choices",
            blocks: [.init(name: "Main", nodes: [.choice(choice), .choice(alternate)])]
        )
        let observations = [
            WorkoutTextObservation(
                id: "bike",
                text: "C2 Bike or Echo Bike",
                confidence: 1,
                boundingBox: .init(x: 0, y: 0.8, width: 1, height: 0.1)
            ),
            WorkoutTextObservation(
                id: "alternate",
                text: "A & B",
                confidence: 1,
                boundingBox: .init(x: 0, y: 0.1, width: 1, height: 0.1)
            ),
        ]

        let result = WorkoutImportDraftBuilder.build(
            WorkoutImportSemanticNormalizer.normalize(document, observations: observations),
            catalog: ExerciseCatalog.definitions
        ).draft.workout

        #expect(result.allChoices.count == 1)
        #expect(result.allChoices.first?.label == "Bike")
        #expect(result.allGroups.count == 1)
        #expect(result.allGroups.first?.label == "A & B")
    }

    @Test func explicitOrTakesPrecedenceWhenEachChoiceOptionContainsRequiredPlusWork() throws {
        let choice = ParsedWorkoutChoice(
            label: "Choose a pair",
            options: [
                .group(.init(label: "Run + Ski", children: [
                    .exercise(.init(name: "Run", sets: [])),
                    .exercise(.init(name: "SkiErg", sets: [])),
                ])),
                .group(.init(label: "Bike + Row", children: [
                    .exercise(.init(name: "Echo Bike", sets: [])),
                    .exercise(.init(name: "RowErg", sets: [])),
                ])),
            ],
            sourceObservationIDs: ["mixed-choice"]
        )
        let document = ParsedWorkoutDocument(
            title: "Mixed choice",
            blocks: [.init(name: "Main", nodes: [.choice(choice)])]
        )
        let source = WorkoutTextObservation(
            id: "mixed-choice",
            text: "Choose Run + Ski or Bike + Row",
            confidence: 1,
            boundingBox: .init(x: 0, y: 0.2, width: 1, height: 0.1)
        )

        let normalized = WorkoutImportSemanticNormalizer.normalize(document, observations: [source])
        let workout = WorkoutImportDraftBuilder.build(
            normalized,
            catalog: ExerciseCatalog.definitions
        ).draft.workout

        #expect(workout.allChoices.count == 1)
        #expect(workout.allChoices.first?.label == "Choose a pair")
        #expect(workout.allGroups.count == 2)
    }
}

@Suite("Workout import review issue reconciliation")
@MainActor
struct WorkoutImportIssueReconciliationTests {
    @Test func duplicateUnresolvedIntensitiesResolveTheSelectedIssueAndRebaseTheRemainingIssue() throws {
        let source = ParsedIntensityTarget(type: "power", lower: 200, upper: 300, unit: "bananas")
        let built = WorkoutImportDraftBuilder.build(
            ParsedWorkoutDocument(title: "Power", blocks: [
                ParsedWorkoutBlock(name: "Main", exercises: [
                    ParsedWorkoutExercise(name: "Run", sets: [], intensityTargets: [source, source]),
                    ParsedWorkoutExercise(
                        name: "Run",
                        sets: [],
                        intensityTargets: [.init(type: "power", lower: 150, upper: 150, unit: "watts")]
                    ),
                ]),
            ]),
            catalog: ExerciseCatalog.definitions
        )
        let issues = built.issues.filter { $0.code == .unsupportedIntensityTarget }.sorted {
            ($0.unresolvedIntensity?.occurrence ?? .max) < ($1.unresolvedIntensity?.occurrence ?? .max)
        }
        #expect(issues.compactMap { $0.unresolvedIntensity?.occurrence } == [1, 2])
        let firstIssue = try #require(issues.first)
        let secondIssue = try #require(issues.last)
        let marker = try #require(firstIssue.unresolvedIntensity?.marker)
        let exercise = try #require(built.draft.workout.allExercises.first)
        let otherExercise = try #require(built.draft.workout.allExercises.last)
        let model = makeModel(session: ImportSession(
            draft: built.draft,
            issues: built.issues,
            status: .reviewing
        ))
        let defaults = try #require(UserDefaults(suiteName: "import-intensity-\(UUID().uuidString)"))
        let configuration = WorkoutStore(defaults: defaults)
        let reviewStore = WorkoutStore(transientWorkout: built.draft.workout, configurationFrom: configuration)

        #expect(firstIssue.exerciseID == exercise.id)
        #expect(secondIssue.exerciseID == exercise.id)
        #expect(model.canUseWatts(for: firstIssue))
        #expect(model.session.canSave == false)

        reviewStore.edit { workout in
            workout.rename("Only the workout title changed")
            _ = workout.updateExercise(otherExercise.id) { exercise in
                exercise.prescription.intensityTargets = [.power(lower: 175, upper: 175, unit: .watts)]
            }
        }
        model.synchronizeDraft(from: reviewStore)
        #expect(model.session.issues.map(\.id) == issues.map(\.id))
        #expect(model.session.issues.compactMap { $0.unresolvedIntensity?.occurrence } == [1, 2])
        #expect(model.session.canSave == false)

        #expect(model.useWatts(for: firstIssue, in: reviewStore))
        let remainingIssue = try #require(model.session.issues.first)
        #expect(model.session.issues.count == 1)
        #expect(remainingIssue.id == secondIssue.id)
        #expect(remainingIssue.unresolvedIntensity?.occurrence == 1)
        #expect(model.session.canSave == false)
        let afterCorrection = try #require(reviewStore.current)
        let correctedExercise = try #require(afterCorrection.exercise(exercise.id))
        #expect(correctedExercise.prescription.intensityTargets == [
            .power(lower: 200, upper: 300, unit: .watts),
            marker,
        ])
        #expect(afterCorrection.title == "Only the workout title changed")
        #expect(afterCorrection.exercise(otherExercise.id)?.prescription.intensityTargets == [
            .power(lower: 175, upper: 175, unit: .watts),
        ])

        #expect(model.removeIntensityTarget(for: remainingIssue, in: reviewStore))
        #expect(model.session.issues.isEmpty)
        #expect(model.session.canSave)
        let resolvedWorkout = try #require(reviewStore.current)
        #expect(resolvedWorkout.exercise(exercise.id)?.prescription.intensityTargets == [
            .power(lower: 200, upper: 300, unit: .watts),
        ])
        #expect(resolvedWorkout.title == "Only the workout title changed")
        #expect(resolvedWorkout.exercise(otherExercise.id)?.prescription.intensityTargets == [
            .power(lower: 175, upper: 175, unit: .watts),
        ])
    }

    @Test func synchronizingOneExternalDuplicateMarkerRemovalKeepsOneBlockingIssue() throws {
        let source = ParsedIntensityTarget(type: "power", lower: 200, upper: 300, unit: "bananas")
        let built = WorkoutImportDraftBuilder.build(
            ParsedWorkoutDocument(title: "Power", blocks: [
                ParsedWorkoutBlock(name: "Main", exercises: [
                    ParsedWorkoutExercise(name: "Run", sets: [], intensityTargets: [source, source]),
                ]),
            ]),
            catalog: ExerciseCatalog.definitions
        )
        let exercise = try #require(built.draft.workout.allExercises.first)
        let marker = try #require(built.issues.first?.unresolvedIntensity?.marker)
        let model = makeModel(session: ImportSession(
            draft: built.draft,
            issues: built.issues,
            status: .reviewing
        ))
        let defaults = try #require(UserDefaults(suiteName: "import-external-intensity-\(UUID().uuidString)"))
        let configuration = WorkoutStore(defaults: defaults)
        let reviewStore = WorkoutStore(transientWorkout: built.draft.workout, configurationFrom: configuration)

        reviewStore.edit { workout in
            _ = workout.updateExercise(exercise.id) { exercise in
                guard let index = exercise.prescription.intensityTargets.firstIndex(of: marker) else { return }
                exercise.prescription.intensityTargets.remove(at: index)
            }
        }
        model.synchronizeDraft(from: reviewStore)

        #expect(model.session.issues.count == 1)
        #expect(model.session.issues.first?.unresolvedIntensity?.occurrence == 1)
        #expect(model.session.blockingIssues.count == 1)
        #expect(model.session.canSave == false)
    }

    @Test func sharedReviewStoreReplacementClearsOnlyTheMatchingUnknownExerciseIssue() throws {
        let exerciseID = UUID()
        let draft = Workout(title: "Imported", blocks: [WorkoutBlock(name: "Main", exercises: [
            PlannedExercise(id: exerciseID, exerciseName: "Air machine", definitionId: nil),
        ])])
        let model = makeModel(session: ImportSession(
            draft: .init(workout: draft),
            issues: [.init(
                code: .unknownExercise,
                severity: .blocking,
                message: "Choose an exercise.",
                exerciseID: exerciseID
            )],
            status: .reviewing
        ))
        let source = WorkoutStore(defaults: UserDefaults(suiteName: "import-review-\(UUID().uuidString)")!)
        let review = WorkoutStore(transientWorkout: draft, configurationFrom: source)

        #expect(review.replaceExercise(exerciseID, with: ExerciseCatalog.definition(id: "echo_bike")!))
        model.synchronizeDraft(from: review)

        #expect(model.session.issues.isEmpty)
        #expect(model.session.draft?.workout.exercise(exerciseID)?.definitionId == "echo_bike")
        #expect(model.session.canSave)
    }

    @Test func unknownUnitStaysBlockingAfterUnrelatedEditsUntilValueIsEnteredOrMetricRemoved() throws {
        let exerciseID = UUID()
        let validSetID = UUID()
        let affectedSetID = UUID()
        let exercise = PlannedExercise(
            id: exerciseID,
            exerciseName: "Run",
            definitionId: "run",
            selectedMetrics: [.distance],
            prescription: Prescription(sets: [
                PlannedSet(id: validSetID, distance: 400),
                PlannedSet(id: affectedSetID),
            ])
        )
        let draft = Workout(title: "Imported", blocks: [WorkoutBlock(name: "Main", exercises: [exercise])])
        let issue = WorkoutImportIssue(
            code: .unsupportedMetric,
            severity: .blocking,
            message: "Confirm the unit and value for distance.",
            exerciseID: exerciseID,
            setID: affectedSetID,
            metric: .distance
        )
        let model = makeModel(session: ImportSession(
            draft: .init(workout: draft),
            issues: [issue],
            status: .reviewing
        ))

        var renamed = draft
        renamed.rename("Unrelated title edit")
        model.replaceDraftWorkout(renamed)
        #expect(model.session.issues == [issue])
        #expect(!model.session.canSave)

        var fixed = renamed
        let updatedSet = fixed.updateSet(affectedSetID) { $0.values[.distance] = 100 }
        #expect(updatedSet)
        model.replaceDraftWorkout(fixed)
        #expect(model.session.issues.isEmpty)
        #expect(model.session.canSave)

        let removalModel = makeModel(session: ImportSession(
            draft: .init(workout: draft),
            issues: [issue],
            status: .reviewing
        ))
        var intentionallyRemoved = draft
        let removedMetric = intentionallyRemoved.updateExercise(exerciseID) { $0.selectedMetrics = [] }
        #expect(removedMetric)
        removalModel.replaceDraftWorkout(intentionallyRemoved)
        #expect(removalModel.session.issues.isEmpty)
    }

    @Test func alternativeIssueIgnoresTheValidParentAndClearsOnlyWhenAlternativeIsFixedOrRemoved() throws {
        let built = WorkoutImportDraftBuilder.build(
            ParsedWorkoutDocument(title: "Intervals", blocks: [
                ParsedWorkoutBlock(name: "Main", exercises: [
                    ParsedWorkoutExercise(name: "Run", sets: [
                        .init(
                            metrics: [.init(type: "distance", value: 400, unit: "m")],
                            alternatives: [
                                .init(label: "Short course", metrics: [
                                    .init(type: "distance", value: 100, unit: "yd"),
                                ]),
                            ]
                        ),
                    ]),
                ]),
            ]),
            catalog: ExerciseCatalog.definitions
        )
        let issue = try #require(built.issues.first { $0.severity == .blocking })
        let exercise = try #require(built.draft.workout.allExercises.first)
        let set = try #require(exercise.prescription.sets.first)
        let alternative = try #require(set.alternatives.first)
        let model = makeModel(session: ImportSession(
            draft: built.draft,
            issues: built.issues,
            status: .reviewing
        ))

        var unrelated = built.draft.workout
        unrelated.rename("Only the title changed")
        #expect(unrelated.updateSet(set.id) { $0.values[.distance] = 800 })
        model.replaceDraftWorkout(unrelated)
        #expect(model.session.issues.contains(issue))
        #expect(!model.session.canSave)

        var fixed = unrelated
        #expect(fixed.updateSet(set.id) { set in
            let index = set.alternatives.firstIndex { $0.id == alternative.id }
            if let index { set.alternatives[index].values[.distance] = 100 }
        })
        model.replaceDraftWorkout(fixed)
        #expect(model.session.issues.isEmpty)
        #expect(model.session.canSave)

        let removalModel = makeModel(session: ImportSession(
            draft: built.draft,
            issues: built.issues,
            status: .reviewing
        ))
        var removed = built.draft.workout
        #expect(removed.updateSet(set.id) { $0.alternatives.removeAll { $0.id == alternative.id } })
        removalModel.replaceDraftWorkout(removed)
        #expect(removalModel.session.issues.isEmpty)
    }

    @Test func invalidValueStaysBlockingUntilItsExactSetMetricIsFixed() throws {
        let built = WorkoutImportDraftBuilder.build(
            ParsedWorkoutDocument(title: "Track", blocks: [
                ParsedWorkoutBlock(name: "Main", exercises: [
                    ParsedWorkoutExercise(name: "Run", sets: [
                        .init(metrics: [.init(type: "distance", value: -.infinity, unit: "m")]),
                        .init(metrics: [.init(type: "distance", value: 400, unit: "m")]),
                    ]),
                ]),
            ]),
            catalog: ExerciseCatalog.definitions
        )
        let issue = try #require(built.issues.first { $0.code == .invalidValue })
        let exercise = try #require(built.draft.workout.allExercises.first)
        let affectedSet = try #require(exercise.prescription.sets.first)
        let otherSet = try #require(exercise.prescription.sets.last)
        #expect(issue.message.contains("set 1"))
        let model = makeModel(session: ImportSession(
            draft: built.draft,
            issues: built.issues,
            status: .reviewing
        ))

        var unrelated = built.draft.workout
        unrelated.rename("Unrelated title")
        #expect(unrelated.updateSet(otherSet.id) { $0.values[.distance] = 800 })
        model.replaceDraftWorkout(unrelated)
        #expect(model.session.issues.contains(issue))
        #expect(!model.session.canSave)

        var fixed = unrelated
        #expect(fixed.updateSet(affectedSet.id) { $0.values[.distance] = 100 })
        model.replaceDraftWorkout(fixed)
        #expect(model.session.issues.isEmpty)
        #expect(model.session.canSave)
    }

    @Test func structuralAndEmptyWorkoutIssuesClearOnlyAfterTheirRelevantEdits() throws {
        let emptyIssue = WorkoutImportIssue(
            code: .emptyWorkout,
            severity: .blocking,
            message: "Add an exercise."
        )
        let empty = Workout(title: "Imported", blocks: [WorkoutBlock(name: "Main")])
        let emptyModel = makeModel(session: ImportSession(
            draft: .init(workout: empty),
            issues: [emptyIssue],
            status: .reviewing
        ))
        var filled = empty
        let addedExercise = filled.addExercise(
            PlannedExercise(exerciseName: "Run", definitionId: "run"),
            toBlock: filled.blocks[0].id
        )
        #expect(addedExercise)
        emptyModel.replaceDraftWorkout(filled)
        #expect(emptyModel.session.issues.isEmpty)

        let choiceID = UUID()
        let choice = WorkoutChoice(id: choiceID, label: "A & B", options: [
            .exercise(PlannedExercise(exerciseName: "Run", definitionId: "run")),
            .exercise(PlannedExercise(exerciseName: "SkiErg", definitionId: "ski_erg")),
        ])
        let ambiguous = Workout(title: "Imported", blocks: [
            WorkoutBlock(name: "Main", nodes: [.choice(choice)]),
        ])
        let structuralIssue = WorkoutImportIssue(
            code: .ambiguousStructure,
            severity: .blocking,
            message: "Confirm whether both are required.",
            nodeID: choiceID
        )
        let structureModel = makeModel(session: ImportSession(
            draft: .init(workout: ambiguous),
            issues: [structuralIssue],
            status: .reviewing
        ))
        var required = ambiguous
        let converted = required.convertChoiceToRequiredGroup(choiceID)
        #expect(converted)
        structureModel.replaceDraftWorkout(required)
        #expect(structureModel.session.issues.isEmpty)
        #expect(structureModel.session.canSave)

        let groupID = UUID()
        let ambiguousGroup = WorkoutGroup(
            id: groupID,
            label: "Intervals",
            execution: GroupExecution(repetition: .count(3)),
            children: [.exercise(PlannedExercise(exerciseName: "Run", definitionId: "run"))]
        )
        let grouped = Workout(title: "Imported", blocks: [
            WorkoutBlock(name: "Main", nodes: [.group(ambiguousGroup)]),
        ])
        let groupIssue = WorkoutImportIssue(
            code: .ambiguousStructure,
            severity: .warning,
            message: "Confirm the interval structure.",
            nodeID: groupID
        )
        let groupModel = makeModel(session: ImportSession(
            draft: .init(workout: grouped),
            issues: [groupIssue],
            status: .reviewing
        ))
        var unrelated = grouped
        unrelated.rename("Only the workout title changed")
        groupModel.replaceDraftWorkout(unrelated)
        #expect(groupModel.session.issues == [groupIssue])

        var reviewedStructure = unrelated
        let updatedGroup = reviewedStructure.updateGroup(groupID) { $0.execution.repetition = .count(4) }
        #expect(updatedGroup)
        groupModel.replaceDraftWorkout(reviewedStructure)
        #expect(groupModel.session.issues.isEmpty)

        let deletionModel = makeModel(session: ImportSession(
            draft: .init(workout: grouped),
            issues: [groupIssue],
            status: .reviewing
        ))
        var deleted = grouped
        deleted.blocks[0].nodes = []
        deletionModel.replaceDraftWorkout(deleted)
        #expect(deletionModel.session.issues.isEmpty)
    }

    private func makeModel(session: ImportSession) -> WorkoutImportViewModel {
        WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: RecordingWorkoutParser(),
            initialSession: session
        )
    }
}

@Suite("Workout import source pipeline")
@MainActor
struct WorkoutImportSourcePipelineTests {
    @Test func importDismissalChangesFromCancelToCloseOnlyAfterDurableHandoff() {
        let localOnly = WorkoutImportViewModel(initialJob: WorkoutImportJob(
            stage: .waitingForHandoff,
            expectedPageCount: 5
        ))
        #expect(!localOnly.hasDurableCheckpoint)

        let handedOff = WorkoutImportViewModel(initialJob: WorkoutImportJob(
            stage: .processingSections,
            expectedPageCount: 5,
            serverProgress: .init(
                serverJobID: "server-job",
                status: WorkoutImportRemoteJobState.processing.rawValue,
                completedSections: 0,
                totalSections: 2
            )
        ))
        #expect(handedOff.hasDurableCheckpoint)

        let draft = WorkoutTemplateDraft(workout: Workout(
            title: "Workout",
            blocks: [WorkoutBlock(
                name: "Workout",
                exercises: [PlannedExercise(exerciseName: "Run", definitionId: "run")]
            )]
        ))
        let reviewing = WorkoutImportViewModel(initialJob: WorkoutImportJob(
            stage: .reviewing,
            expectedPageCount: 5,
            draft: draft
        ))
        #expect(reviewing.hasDurableCheckpoint)
    }

    @Test(.timeLimit(.minutes(1)))
    func optInProductionVisionSmokeBuildsExercisesFromRealPhotos() async throws {
        guard let value = ProcessInfo.processInfo.environment["BASELINE_IMPORT_SMOKE_IMAGES"],
              !value.isEmpty else { return }
        let paths = value.split(separator: ";").map(String.init)
        #expect(!paths.isEmpty)

        let normalizer = WorkoutImageNormalizer()
        let recognizer = VisionWorkoutTextRecognizer()
        let customWords = ExerciseCatalog.definitions.flatMap { [$0.name] + $0.aliases }
        var pages: [WorkoutImportSourcePage] = []
        for (index, path) in paths.enumerated() {
            let requestedURL = URL(fileURLWithPath: path)
            let url: URL
            if FileManager.default.fileExists(atPath: requestedURL.path) {
                url = requestedURL
            } else {
                url = try #require(Bundle.main.url(
                    forResource: requestedURL.lastPathComponent,
                    withExtension: nil
                ))
            }
            let data = try Data(contentsOf: url)
            let image = try await normalizer.normalize(data)
            let observations = try await recognizer.recognize(
                image: image,
                sourceImageIndex: index,
                customWords: customWords
            )
            pages.append(WorkoutImportSourcePage(
                index: index,
                relativeFilename: "pages/\(index).jpg",
                digest: WorkoutImportStableIdentity.digest([String(index), String(data.count)]),
                pixelWidth: image.pixelWidth,
                pixelHeight: image.pixelHeight,
                stage: .recognized,
                observations: observations
            ))
        }

        let source = try WorkoutImportSourceDocumentBuilder.build(pages: pages)
        let document = WorkoutImportFallbackBuilder.build(
            sections: source.sections,
            catalog: ExerciseCatalog.definitions
        )
        let built = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let definitionIDs = Set(built.draft.workout.allExercises.compactMap(\.definitionId))

        #expect(!built.draft.workout.allExercises.isEmpty)
        #expect(definitionIDs.contains("sled_pull"))
        #expect(definitionIDs.contains("deadlift"))
        #expect(definitionIDs.contains("echo_bike"))
        #expect(!String(data: try JSONEncoder().encode(document), encoding: .utf8)!
            .contains("Recognized text"))
    }

    @Test func pendingRetryCopyShowsSavedProgressAndRequiresTheAppToRemainOpen() {
        #expect(
            WorkoutImportProgressCopy.retryingDetail(completed: 2, total: 4) ==
                "Progress saved: 2 of 4 sections. Keep Baseline open until the retry is handed off."
        )
        #expect(
            WorkoutImportProgressCopy.retryingDetail(completed: 0, total: 0) ==
                "Keep Baseline open until the retry is handed off."
        )
    }

    @Test func observationsRoundTripSourceImageIndexAndDefaultOldPayloadsToFirstImage() throws {
        let observation = WorkoutTextObservation(
            id: "line",
            text: "Run 400 m",
            confidence: 0.97,
            boundingBox: .init(x: 0.1, y: 0.2, width: 0.4, height: 0.05),
            sourceImageIndex: 7
        )
        let decoded = try JSONDecoder().decode(
            WorkoutTextObservation.self,
            from: JSONEncoder().encode(observation)
        )
        #expect(decoded.sourceImageIndex == 7)

        let legacy = #"{"id":"old","text":"Run","confidence":0.9,"boundingBox":{"x":0,"y":0,"width":1,"height":0.1}}"#
        let legacyDecoded = try JSONDecoder().decode(WorkoutTextObservation.self, from: Data(legacy.utf8))
        #expect(legacyDecoded.sourceImageIndex == 0)
    }

    @Test func legacyParsedDocumentsWithoutNotesDecodeWithEmptyNoteCollections() throws {
        let legacy = #"{"title":"Legacy","blocks":[{"name":"Main","exercises":[]}]}"#
        let document = try JSONDecoder().decode(ParsedWorkoutDocument.self, from: Data(legacy.utf8))

        #expect(document.notes.isEmpty)
        #expect(document.blocks.first?.notes.isEmpty == true)
    }

    @Test func deterministicFallbackCreatesOnlyCatalogBackedExercisesInSourceOrder() throws {
        let first = WorkoutTextObservation(
            id: "first-line",
            text: "Run 400 m",
            confidence: 0.98,
            boundingBox: .init(x: 0.1, y: 0.7, width: 0.6, height: 0.06),
            sourceImageIndex: 0
        )
        let second = WorkoutTextObservation(
            id: "second-line",
            text: "12 Deadlifts @ bodyweight",
            confidence: 0.97,
            boundingBox: .init(x: 0.1, y: 0.5, width: 0.7, height: 0.06),
            sourceImageIndex: 1
        )
        let sections = [
            WorkoutImportSourceSection(
                id: "section-2",
                order: 1,
                observations: [second],
                contextBefore: [],
                characterCount: second.text.count
            ),
            WorkoutImportSourceSection(
                id: "section-1",
                order: 0,
                observations: [first],
                contextBefore: [],
                characterCount: first.text.count
            ),
        ]

        let document = WorkoutImportFallbackBuilder.build(sections: sections)

        #expect(document.title == "Workout")
        #expect(document.blocks.map(\.name) == ["Workout"])
        let exercises = document.blocks.flatMap(\.exercises)
        #expect(exercises.map(\.name) == ["Run", "Deadlift"])
        #expect(exercises[0].sets.first?.metrics.first?.type == "distance")
        #expect(exercises[0].sets.first?.metrics.first?.value == 400)
        #expect(exercises[1].sets.first?.metrics.first?.type == "reps")
        #expect(exercises[1].sets.first?.metrics.first?.value == 12)
        #expect(exercises[0].sourceObservationIDs == ["first-line"])
        #expect(exercises[1].sourceObservationIDs == ["second-line"])
        #expect(exercises[1].notes == ["12 Deadlifts @ bodyweight"])
        #expect(!String(data: try JSONEncoder().encode(document), encoding: .utf8)!
            .contains("Recognized text"))
    }

    @Test func deterministicFallbackRejectsCatalogWordsInsideCoachingNotes() {
        let notes = [
            "Avoid running today so you are ready for tomorrow's intensity session.",
            "Running 3 days per week is too much during recovery.",
            "Running 60 minutes is too much during recovery.",
            "Recovery after 60 minutes of running should be the priority.",
        ]
        let observations = notes.enumerated().map { index, text in
            WorkoutTextObservation(
                id: "coaching-note-\(index)",
                text: text,
                confidence: 0.99,
                boundingBox: .init(x: 0.1, y: 0.5, width: 0.8, height: 0.08),
                sourceImageIndex: 0
            )
        }
        let section = WorkoutImportSourceSection(
            id: "coaching-section",
            order: 0,
            observations: observations,
            contextBefore: [],
            characterCount: notes.reduce(0) { $0 + $1.count }
        )

        let document = WorkoutImportFallbackBuilder.build(sections: [section])

        #expect(document.blocks.isEmpty)
    }

    @Test func deterministicFallbackRetainsAValidTimedPrescription() throws {
        let observation = WorkoutTextObservation(
            id: "timed-run",
            text: "Run 60 minutes at an easy pace",
            confidence: 0.99,
            boundingBox: .init(x: 0.1, y: 0.5, width: 0.8, height: 0.08),
            sourceImageIndex: 0
        )
        let section = WorkoutImportSourceSection(
            id: "timed-section",
            order: 0,
            observations: [observation],
            contextBefore: [],
            characterCount: observation.text.count
        )

        let document = WorkoutImportFallbackBuilder.build(sections: [section])
        let exercise = try #require(document.blocks.first?.exercises.first)

        #expect(exercise.name == "Run")
        #expect(exercise.sets.first?.metrics.first?.type == "duration")
        #expect(exercise.sets.first?.metrics.first?.value == 60)
    }

    @Test func reviewCloseRemainsUnavailableUntilLatestEditsArePersisted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportReviewPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FailingReviewSaveWorkoutImportRepository(root: root)
        let draft = WorkoutTemplateDraft(workout: Workout(
            title: "Original",
            blocks: [WorkoutBlock(
                name: "Workout",
                exercises: [PlannedExercise(exerciseName: "Run", definitionId: "run")]
            )]
        ))
        let job = WorkoutImportJob(stage: .reviewing, expectedPageCount: 1, draft: draft)
        try await repository.create(job)
        let model = WorkoutImportViewModel(
            repository: repository,
            initialSession: ImportSession(id: job.id, draft: draft, status: .reviewing),
            initialJob: job
        )
        #expect(model.reviewDraftIsPersisted)

        model.updateWorkout { $0.rename("Latest athlete edit") }
        #expect(!model.reviewDraftIsPersisted)
        #expect(!model.hasDurableCheckpoint)
        await model.waitForPendingReviewPersistence()
        #expect(!model.reviewDraftIsPersisted)
        #expect(model.reviewPersistenceError != nil)

        await repository.allowSaves()
        model.retryReviewDraftPersistence()
        await model.waitForPendingReviewPersistence()
        #expect(model.reviewDraftIsPersisted)
        #expect(model.reviewPersistenceError == nil)
        #expect(try await repository.load(job.id)?.draft?.workout.title == "Latest athlete edit")
        await model.cancel().value
    }

    @Test func issueEvidenceResolvesToTheCorrectCropsAcrossMultiplePhotos() throws {
        let exerciseID = UUID()
        let issue = WorkoutImportIssue(
            code: .missingMetricValue,
            severity: .warning,
            message: "Enter the sled load.",
            exerciseID: exerciseID
        )
        let observations = [
            WorkoutTextObservation(
                id: "first",
                text: "25m Sled Pull",
                confidence: 0.98,
                boundingBox: .init(x: 0.2, y: 0.7, width: 0.5, height: 0.08),
                sourceImageIndex: 0
            ),
            WorkoutTextObservation(
                id: "third",
                text: "@ race weight",
                confidence: 0.97,
                boundingBox: .init(x: 0.25, y: 0.4, width: 0.4, height: 0.06),
                sourceImageIndex: 2
            ),
        ]
        let session = ImportSession(
            sourceImages: (0..<3).map { _ in ImportedWorkoutImage(data: Data([1]), pixelWidth: 100, pixelHeight: 200) },
            observations: observations,
            issues: [issue],
            evidence: [.init(exerciseID: exerciseID, nodeID: exerciseID, sourceObservationIDs: ["first", "third"])]
        )

        let crops = WorkoutImportEvidenceResolver.crops(for: issue, in: session)

        #expect(crops.map(\.sourceImageIndex) == [0, 2])
        let first = try #require(crops.first?.normalizedBounds)
        let third = try #require(crops.last?.normalizedBounds)
        #expect(abs(first.origin.x - 0.18) < 0.000_001)
        #expect(abs(first.origin.y - 0.205) < 0.000_001)
        #expect(abs(first.width - 0.54) < 0.000_001)
        #expect(abs(first.height - 0.11) < 0.000_001)
        #expect(abs(third.origin.x - 0.23) < 0.000_001)
        #expect(abs(third.origin.y - 0.525) < 0.000_001)
        #expect(abs(third.width - 0.44) < 0.000_001)
        #expect(abs(third.height - 0.09) < 0.000_001)
    }

    @Test func importsImagesInSourceOrder() async throws {
        let parser = RecordingWorkoutParser()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser
        )

        await model.importImages([Data([1]), Data([2]), Data([3])], catalog: ExerciseCatalog.definitions).value

        #expect(model.session.sourcePages.map(\.index) == [0, 1, 2])
        #expect(await model.sourceImageData(at: 0) == Data([1]))
        #expect(await model.sourceImageData(at: 2) == Data([3]))
        #expect(model.session.diagnostics.imageCount == 3)
        #expect(parser.received.map(\.sourceImageIndex) == [0, 1, 2])
        #expect(parser.received.map(\.text) == ["page-1", "page-2", "page-3"])
        guard case .reviewing = model.session.status else {
            Issue.record("Expected the ordered batch to reach review")
            return
        }
        model.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func photoLoaderPersistsEachOriginalBeforeLoadingTheNext() async {
        let loader = GatedSecondImageLoader()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: RecordingWorkoutParser()
        )

        let task = model.importImages(count: 2, catalog: ExerciseCatalog.definitions) { index in
            await loader.load(index)
        }
        let sessionID = model.session.id
        await loader.waitUntilSecondLoadStarts()

        let folder = temporaryImportFolder(sessionID)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "sources/0.source").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "sources/1.source").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "pages/0.jpg").path))
        #expect(model.session.status == .loadingImages(completed: 1, total: 2))

        await loader.releaseSecondLoad()
        await task.value
        guard case .reviewing = model.session.status else {
            Issue.record("Expected the incrementally loaded batch to reach review")
            return
        }
        model.cancel()
    }

    @Test func singleImageEntryPointUsesTheBatchPipeline() async {
        let parser = RecordingWorkoutParser()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser
        )

        await model.importImage(Data([9]), catalog: ExerciseCatalog.definitions).value

        #expect(model.session.diagnostics.imageCount == 1)
        #expect(parser.received.map(\.sourceImageIndex) == [0])
        model.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func supersededImportCannotOverwriteOrDeleteTheCurrentBatch() async {
        let normalizer = SupersedingWorkoutImageNormalizer()
        let parser = RecordingWorkoutParser()
        let model = WorkoutImportViewModel(
            normalizer: normalizer,
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser
        )

        let supersededTask = model.importImage(Data([1]), catalog: ExerciseCatalog.definitions)
        await normalizer.waitUntilFirstImportStarts()

        let currentTask = model.importImage(Data([2]), catalog: ExerciseCatalog.definitions)
        let currentSessionID = model.session.id
        await currentTask.value
        await normalizer.releaseFirstImport()
        await supersededTask.value

        #expect(model.session.id == currentSessionID)
        #expect(model.session.sourcePages.map(\.index) == [0])
        #expect(await model.sourceImageData(at: 0) == Data([2]))
        #expect(parser.received.map(\.text) == ["page-2"])
        guard case .reviewing = model.session.status else {
            Issue.record("Expected the current import to remain ready for review")
            return
        }
        model.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func lateSupersededParserResponseCannotOverwriteTheCurrentDraft() async {
        let parser = LateSupersededWorkoutParser()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser
        )

        let supersededTask = model.importImage(Data([1]), catalog: ExerciseCatalog.definitions)
        await parser.waitUntilFirstParseStarts()

        let currentTask = model.importImage(Data([2]), catalog: ExerciseCatalog.definitions)
        let currentSessionID = model.session.id
        await currentTask.value
        let currentFolder = temporaryImportFolder(currentSessionID)
        #expect(FileManager.default.fileExists(atPath: currentFolder.path))

        parser.releaseFirstParse()
        await supersededTask.value

        #expect(model.session.id == currentSessionID)
        #expect(model.session.draft?.workout.title == "Current import")
        #expect(model.session.diagnostics.parserModel == "current-model")
        #expect(model.session.sourcePages.map(\.index) == [0])
        #expect(await model.sourceImageData(at: 0) == Data([2]))
        #expect(FileManager.default.fileExists(atPath: currentFolder.path))
        model.cancel()
    }

    @Test(arguments: [0, WorkoutImageImportLimits.maximumImageCount + 1])
    func rejectsImageCountsOutsideTheAcceptedRange(count: Int) async {
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: RecordingWorkoutParser()
        )
        let images = (0..<count).map { Data([UInt8($0 % 255)]) }

        await model.importImages(images, catalog: ExerciseCatalog.definitions).value

        guard case .failed = model.session.status else {
            Issue.record("Expected \(count) images to be rejected")
            return
        }
        #expect(model.session.draft == nil)
        #expect(model.session.sourceImages.isEmpty)
    }

    @Test func acceptsTheMaximumImageCount() async {
        let parser = RecordingWorkoutParser()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser
        )
        let images = (0..<WorkoutImageImportLimits.maximumImageCount).map { Data([UInt8($0)]) }

        await model.importImages(images, catalog: ExerciseCatalog.definitions).value

        #expect(model.session.sourcePages.count == WorkoutImageImportLimits.maximumImageCount)
        #expect(parser.received.map(\.sourceImageIndex) == Array(0..<WorkoutImageImportLimits.maximumImageCount))
        guard case .reviewing = model.session.status else {
            Issue.record("Expected ten ordered images to reach review")
            return
        }
        model.cancel()
    }

    @Test func aNoTextPageContinuesAndRetainsTheProtectedBatchForReview() async {
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: FailingSecondWorkoutTextRecognizer(),
            parser: RecordingWorkoutParser()
        )
        let importTask = model.importImages([Data([1]), Data([2])], catalog: ExerciseCatalog.definitions)
        let sessionID = model.session.id
        await importTask.value

        guard case .reviewing = model.session.status else {
            Issue.record("Expected one readable page to continue to review")
            return
        }
        #expect(model.session.draft != nil)
        #expect(model.session.sourcePages.map(\.stage) == [.recognized, .noText])
        #expect(model.session.issues.contains { $0.message.contains("no readable workout text") })
        #expect(model.session.sourceImages.isEmpty)
        let sessionFolder = temporaryImportFolder(sessionID)
        #expect(FileManager.default.fileExists(atPath: sessionFolder.path))
        await model.cancel().value
        #expect(!FileManager.default.fileExists(atPath: sessionFolder.path))
    }

    @Test func aNormalizationFailureOnPageTwoRetainsTheCompletedCheckpoint() async {
        let parser = RecordingWorkoutParser()
        let model = WorkoutImportViewModel(
            normalizer: FailingSecondWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser
        )

        let task = model.importImages([Data([1]), Data([2])], catalog: ExerciseCatalog.definitions)
        let sessionID = model.session.id
        await task.value

        guard case .failed = model.session.status else {
            Issue.record("Expected normalization failure")
            return
        }
        #expect(model.session.draft == nil)
        #expect(model.session.sourceImages.isEmpty)
        #expect(model.session.sourcePages.map(\.stage) == [.recognized, .failed])
        #expect(parser.callCount == 0)
        #expect(FileManager.default.fileExists(atPath: temporaryImportFolder(sessionID).path))
        await model.cancel().value
        #expect(!FileManager.default.fileExists(atPath: temporaryImportFolder(sessionID).path))
    }

    @Test func aRemoteParserFailureWithoutCatalogExercisesDoesNotOpenTheEditor() async {
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: FailingWorkoutParser()
        )

        let task = model.importImages([Data([1]), Data([2])], catalog: ExerciseCatalog.definitions)
        let sessionID = model.session.id
        await task.value

        guard case .failed = model.session.status else {
            Issue.record("Expected an unusable fallback to remain outside the editor")
            return
        }
        #expect(model.session.draft == nil)
        #expect(model.session.sourceImages.isEmpty)
        #expect(!model.session.observations.isEmpty)
        #expect(model.canRetry)
        #expect(model.currentJob?.parsedDocument == nil)
        #expect(FileManager.default.fileExists(atPath: temporaryImportFolder(sessionID).path))
        await model.cancel().value
        #expect(!FileManager.default.fileExists(atPath: temporaryImportFolder(sessionID).path))
    }

    @Test func aParserDeadlineWithoutCatalogExercisesStaysRetryableAndOutsideTheEditor() async {
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: TimedOutWorkoutParser()
        )

        await model.importImage(Data([1]), catalog: ExerciseCatalog.definitions).value

        guard case .failed = model.session.status else {
            Issue.record("Expected parser timeout to stay outside the editor")
            return
        }
        #expect(model.session.draft == nil)
        #expect(model.session.sourceImages.isEmpty)
        #expect(!model.session.observations.isEmpty)
        #expect(model.canRetry)
        #expect(model.session.issues.isEmpty)
        await model.cancel().value
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelDuringOCRRemovesTheBatchAndNeverCallsTheParser() async {
        let recognizer = GatedWorkoutTextRecognizer()
        let parser = RecordingWorkoutParser()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: recognizer,
            parser: parser
        )

        let task = model.importImages([Data([1]), Data([2])], catalog: ExerciseCatalog.definitions)
        let sessionID = model.session.id
        await recognizer.waitUntilRecognitionStarts()
        #expect(FileManager.default.fileExists(atPath: temporaryImportFolder(sessionID).path))

        let cleanup = model.cancel()
        await recognizer.releaseRecognition()
        await task.value
        await cleanup.value

        #expect(parser.callCount == 0)
        #expect(model.session.sourceImages.isEmpty)
        #expect(model.session.observations.isEmpty)
        #expect(model.session.evidence.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temporaryImportFolder(sessionID).path))
    }

    @Test func successfulSaveRemovesSourceFilesAndInMemoryEvidence() async throws {
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: RecordingWorkoutParser()
        )
        await model.importImages([Data([1]), Data([2])], catalog: ExerciseCatalog.definitions).value
        let sessionID = model.session.id
        #expect(FileManager.default.fileExists(atPath: temporaryImportFolder(sessionID).path))

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))

        #expect(model.saveNewTemplate(in: plan) != nil)
        await model.waitForPendingCleanup()
        #expect(model.session.sourceImages.isEmpty)
        #expect(model.session.observations.isEmpty)
        #expect(model.session.evidence.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temporaryImportFolder(sessionID).path))
    }

    @Test func reviewedSavePersistsTheAuthoritativeEditorDraft() throws {
        let original = Workout(title: "Before final edit", blocks: [
            WorkoutBlock(name: "Main", exercises: [
                PlannedExercise(exerciseName: "Run", definitionId: "run"),
            ]),
        ])
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: RecordingWorkoutParser(),
            initialSession: ImportSession(draft: .init(workout: original), status: .reviewing)
        )
        let defaults = try #require(UserDefaults(suiteName: "import-save-\(UUID().uuidString)"))
        let configuration = WorkoutStore(defaults: defaults)
        let reviewStore = WorkoutStore(transientWorkout: original, configurationFrom: configuration)
        reviewStore.edit { workout in
            workout.rename("Final editor value")
            workout.guidance = CoachGuidance(formCues: ["Saved from the shared editor"])
        }

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))

        #expect(model.session.draft?.workout.title == "Before final edit")
        #expect(model.saveReviewedDraft(from: reviewStore, in: plan) == .saved)
        let saved = try #require(model.savedTemplate)
        let persisted = try #require(plan.templateWorkout(saved.id))
        #expect(persisted.title == "Final editor value")
        #expect(persisted.guidance?.formCues == ["Saved from the shared editor"])
    }

    @Test func protectedTemporaryBatchIsRemovedTogether() throws {
        let sessionID = UUID()
        let image = ImportedWorkoutImage(data: Data([1, 2, 3]), pixelWidth: 1, pixelHeight: 1)
        let first = try WorkoutImportTemporaryFiles.writeProtected(image, sessionID: sessionID, sourceImageIndex: 0)
        let second = try WorkoutImportTemporaryFiles.writeProtected(image, sessionID: sessionID, sourceImageIndex: 1)
        defer { WorkoutImportTemporaryFiles.remove(sessionID: sessionID) }

        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(WorkoutImportTemporaryFiles.protectedWriteOptions.contains(.completeFileProtection))
        let protection = try FileManager.default.attributesOfItem(atPath: first.path)[.protectionKey] as? FileProtectionType
        if let protection { #expect(protection == .complete) }

        WorkoutImportTemporaryFiles.remove(sessionID: sessionID)
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
    }

    @Test func fileBackedTransferIsProtectedExcludedFromBackupAndBoundedBeforeCopy() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImageTransferSecurityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = sandbox.appending(path: "source")
        let transferRoot = sandbox.appending(path: "transfers", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try Data(count: WorkoutImageImportLimits.maximumSourceBytes).write(to: source)

        let copied = try WorkoutImageTransferFiles.copyProtectedFile(
            at: source,
            root: transferRoot,
            fileManager: .default
        )

        #expect(try copied.resourceValues(forKeys: [.fileSizeKey]).fileSize == WorkoutImageImportLimits.maximumSourceBytes)
        #expect(try copied.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try transferRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let protection = try FileManager.default.attributesOfItem(atPath: copied.path)[.protectionKey] as? FileProtectionType
        if let protection { #expect(protection == .complete) }

        try Data(count: WorkoutImageImportLimits.maximumSourceBytes + 1).write(to: source)
        #expect(throws: WorkoutImagePipelineError.self) {
            try WorkoutImageTransferFiles.copyProtectedFile(
                at: source,
                root: transferRoot,
                fileManager: .default
            )
        }
    }

    @Test func abandonedAndCancelledFileTransfersAreRemoved() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImageTransferCleanupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = sandbox.appending(path: "source")
        let transferRoot = sandbox.appending(path: "transfers", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: source)
        let copied = try WorkoutImageTransferFiles.copyProtectedFile(
            at: source,
            root: transferRoot,
            fileManager: .default
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorkoutImageTransferFiles.loadDataAndRemove(
                at: copied,
                fileManager: .default
            )
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: copied.deletingLastPathComponent().path))

        _ = try WorkoutImageTransferFiles.copyProtectedFile(
            at: source,
            root: transferRoot,
            fileManager: .default
        )
        WorkoutImageTransferFiles.removeAll(root: transferRoot, fileManager: .default)
        #expect(!FileManager.default.fileExists(atPath: transferRoot.path))
    }
}

@Suite("Resumable workout import jobs")
struct ResumableWorkoutImportJobTests {
    @Test func scheduleDateRoundTripsThroughThePersistedManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportScheduleDateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let job = WorkoutImportJob(stage: .recognizingText, scheduleDate: day)
        try await repository.create(job)

        let reloaded = try #require(try await repository.load(job.id))
        let restoredDay = try #require(reloaded.scheduleDate)
        #expect(abs(restoredDay.timeIntervalSince1970 - day.timeIntervalSince1970) < 0.001)
    }

    @Test func activeJobsReturnsEveryUnexpiredJobMostRecentFirst() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportActiveJobsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let older = WorkoutImportJob(
            stage: .recognizingText,
            startedAt: now.addingTimeInterval(-100), lastUpdated: now.addingTimeInterval(-100),
            expiresAt: now.addingTimeInterval(1_000)
        )
        let newer = WorkoutImportJob(
            stage: .recognizingText,
            startedAt: now.addingTimeInterval(-10), lastUpdated: now.addingTimeInterval(-10),
            expiresAt: now.addingTimeInterval(1_000)
        )
        let expired = WorkoutImportJob(
            stage: .recognizingText,
            startedAt: now.addingTimeInterval(-200), lastUpdated: now.addingTimeInterval(-200),
            expiresAt: now.addingTimeInterval(-1)
        )
        try await repository.create(older)
        try await repository.create(newer)
        try await repository.create(expired)

        let active = await repository.activeJobs(now: now)
        #expect(active.map(\.id) == [newer.id, older.id])
    }

    @Test func pendingImportsSurfaceScheduleDateAndReviewability() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportPendingSummaryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let coordinator = WorkoutImportCoordinator(repository: repository)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let reviewable = WorkoutImportJob(
            stage: .reviewing,
            scheduleDate: day,
            draft: WorkoutTemplateDraft(workout: Workout(
                title: "Imported",
                blocks: [WorkoutBlock(name: "Workout", exercises: [PlannedExercise(exerciseName: "Run", definitionId: "run")])]
            )),
            startedAt: now, lastUpdated: now,
            expiresAt: now.addingTimeInterval(1_000)
        )
        try await repository.create(reviewable)

        let summaries = await coordinator.pendingImports(now: now)
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.jobID == reviewable.id)
        #expect(summary.isReviewable)
        let scheduled = try #require(summary.scheduleDate)
        #expect(abs(scheduled.timeIntervalSince1970 - day.timeIntervalSince1970) < 0.001)
    }

    @Test @MainActor func startingAnImportPersistsItsTargetDayOntoTheJob() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportStartScheduleDateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let model = WorkoutImportViewModel(
            scheduleDate: day,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: RecordingWorkoutParser(),
            repository: repository
        )

        await model.importImages([Data([1])], catalog: ExerciseCatalog.definitions).value
        let jobID = model.session.id
        let persisted = try #require(try await repository.load(jobID))
        let scheduled = try #require(persisted.scheduleDate)
        #expect(abs(scheduled.timeIntervalSince1970 - day.timeIntervalSince1970) < 0.001)
        model.cancel()
    }

    @Test func deterministicRecoveryBuildsAUsableDraftFromTheSharedFivePhotoFixture() throws {
        let bundle = Bundle(for: WorkoutImportTestsBundleMarker.self)
        let fixtureURL = try #require(bundle.url(
            forResource: "realistic-five-page-ocr",
            withExtension: "json"
        ))
        let fixture = try JSONDecoder().decode(
            RealisticWorkoutOCRFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        let source = try WorkoutImportSourceDocumentBuilder.build(pages: fixture.pages)
        let document = WorkoutImportFallbackBuilder.build(
            sections: source.sections,
            catalog: ExerciseCatalog.definitions
        )
        let built = WorkoutImportDraftBuilder.build(document, catalog: ExerciseCatalog.definitions)
        let exercises = built.draft.workout.allExercises
        let definitionIDs = Set(exercises.compactMap(\.definitionId))

        #expect(document.title == "Aerobic Capacity (Low Impact) Block 12 - Week 3")
        #expect(document.blocks.map(\.name) == ["Workout"])
        #expect(definitionIDs.isSuperset(of: [
            "bike_erg", "echo_bike", "sled_pull", "deadlift",
            "lateral_burpee_over_barbell", "stair_stepper", "box_step_over",
            "hand_release_push_up", "dual_dumbbell_push_press", "wall_balls",
            "ski_erg", "hanging_leg_raise", "plank",
        ]))
        #expect(!exercises.isEmpty)
        #expect(built.issues.isEmpty)
        #expect(!document.blocks.contains { $0.name.lowercased().hasPrefix("imported") })
        #expect(!String(data: try JSONEncoder().encode(document), encoding: .utf8)!
            .contains("Recognized text"))
    }

    @Test func realisticFivePageFixtureBuildsSerializesAndMaterializesWithoutLosingTrainingSemantics() throws {
        let bundle = Bundle(for: WorkoutImportTestsBundleMarker.self)
        let fixtureURL = try #require(bundle.url(
            forResource: "realistic-five-page-ocr",
            withExtension: "json"
        ))
        let fixture = try JSONDecoder().decode(
            RealisticWorkoutOCRFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        #expect(fixture.schemaVersion == 1)
        #expect(fixture.pages.map(\.index) == [0, 1, 2, 3, 4])

        let source = try WorkoutImportSourceDocumentBuilder.build(pages: fixture.pages)
        let sourceText = source.lines.map(\.text).joined(separator: "\n")
        for term in fixture.expectedTerms {
            #expect(sourceText.localizedCaseInsensitiveContains(term))
        }
        let request = try realisticFivePageRequest(fixture: fixture)
        let serialized = try request.encodedPayload()
        #expect(try JSONDecoder().decode(WorkoutImportRemoteStartRequest.self, from: serialized) == request)
        let pinnedRequestURL = try #require(bundle.url(
            forResource: "realistic-five-page-request",
            withExtension: "json"
        ))
        var canonicalSerializedRequest = serialized
        canonicalSerializedRequest.append(0x0A)
        let pinnedRequest = try Data(contentsOf: pinnedRequestURL)
        let decodedPinnedRequest = try JSONDecoder().decode(
            WorkoutImportRemoteStartRequest.self,
            from: pinnedRequest
        )
        #expect(decodedPinnedRequest.sections.map(\.startFragmentPath) == request.sections.map(\.startFragmentPath))
        #expect(decodedPinnedRequest.sections.map(\.endFragmentPath) == request.sections.map(\.endFragmentPath))
        #expect(decodedPinnedRequest.sections.map(\.characterCount) == request.sections.map(\.characterCount))
        #expect(canonicalSerializedRequest == pinnedRequest)
        #expect(request.sections.count == 3)
        #expect(request.sections[1].continuationFromSectionID == request.sections[0].id)
        #expect(request.sections[2].continuationFromSectionID == request.sections[1].id)
        #expect(request.sections[0].endFragmentPath == request.sections[1].startFragmentPath)
        #expect(request.sections[1].endFragmentPath == request.sections[2].startFragmentPath)
        #expect(request.sections[0].endFragmentPath.count == 2)
        #expect(request.sections[1].endFragmentPath.count == 2)
        let optionSections = request.sections.filter { section in
            section.observations.contains { $0.id == "p2-sled" || $0.id == "p2-deadlift" }
        }
        #expect(optionSections.count == 1)
        #expect(Set(try #require(optionSections.first).observations.map(\.id)).isSuperset(of: [
            "p2-sled", "p2-deadlift", "p2-instruction",
        ]))

        let responseURL = try #require(bundle.url(
            forResource: "realistic-five-page-response",
            withExtension: "json"
        ))
        let parsed = try JSONDecoder().decode(
            ParsedWorkoutDocument.self,
            from: Data(contentsOf: responseURL)
        )
        let exactTextByID = Dictionary(uniqueKeysWithValues: request.sections
            .flatMap(\.observations)
            .map { ($0.id, $0.text) })
        var allNotes = parsed.notes
        var allSourceObservationIDs = Set<String>()
        func collect(_ node: ParsedWorkoutNode) {
            switch node {
            case .exercise(let exercise):
                allNotes.append(contentsOf: exercise.notes)
                allSourceObservationIDs.formUnion(exercise.sourceObservationIDs)
            case .group(let group):
                allNotes.append(contentsOf: group.notes)
                allSourceObservationIDs.formUnion(group.sourceObservationIDs)
                group.children.forEach(collect)
            case .choice(let choice):
                allSourceObservationIDs.formUnion(choice.sourceObservationIDs)
                choice.options.forEach(collect)
            case .rest(let rest):
                allSourceObservationIDs.formUnion(rest.sourceObservationIDs)
            }
        }
        for block in parsed.blocks {
            allNotes.append(contentsOf: block.notes)
            allSourceObservationIDs.formUnion(block.sourceObservationIDs)
            block.nodes.forEach(collect)
        }
        for identifier in [
            "p0-note-1", "p0-note-2", "p1-above", "p1-below",
            "p0-long-context", "p1-long-context", "p2-long-context",
            "p3-long-context", "p4-long-context",
        ] {
            #expect(allNotes.contains(try #require(exactTextByID[identifier])))
        }
        // ParsedWorkoutDocument is the authoritative OCR provenance boundary before native
        // materialization intentionally removes source identifiers from the persisted workout.
        #expect(allSourceObservationIDs == Set(request.sections.flatMap(\.observations).map(\.id)))
        #expect(parsed.blocks.map(\.name) == [
            "Minimum Effective Dose (MED)",
            "Performance Layer",
            "Maximum Daily Volume (MDV)",
            "Coach's Note",
        ])
        #expect(parsed.notes.contains { $0.contains("treated conservatively") })
        #expect(parsed.notes.contains { $0.contains("Below 60%") })
        guard case .group(let amrap) = try #require(parsed.blocks[0].nodes.first) else {
            Issue.record("Expected one reconstructed AMRAP parent group.")
            return
        }
        #expect(amrap.label == "70 minute AMRAP")
        #expect(amrap.children.count == 2)
        guard case .group(let aerobicIntervals) = try #require(amrap.children.first) else {
            Issue.record("Expected the repeated aerobic intervals group.")
            return
        }
        #expect(aerobicIntervals.repeatCount == 6)
        guard case .choice(let bikeChoice) = try #require(aerobicIntervals.children.first) else {
            Issue.record("Expected one BikeErg or Echo Bike choice per interval.")
            return
        }
        #expect(bikeChoice.selectionCount == 1)
        #expect(bikeChoice.options.count == 2)
        let bikeOptionExercises = bikeChoice.options.map(\.exercises)
        #expect(bikeOptionExercises.map(\.count) == [2, 2])
        #expect(bikeOptionExercises.allSatisfy { option in
            option[0].sets.first?.metrics.first?.value == 50
                && option[0].intensityTargets.first?.lower == 6
                && option[0].intensityTargets.first?.upper == 8
                && option[1].sets.first?.metrics.first?.value == 20
                && option[1].intensityTargets.first?.lower == 3
        })
        let echoRecovery = try #require(bikeOptionExercises.last?.last)
        #expect(echoRecovery.notes.contains { $0.contains("arms only") })
        guard case .group(let alternatingWork) = try #require(amrap.children.last) else {
            Issue.record("Expected the post-interval A and B work.")
            return
        }
        #expect(alternatingWork.children.map(\.exercises).map(\.count) == [1, 2])
        #expect(amrap.notes.contains { $0.contains("alternate A & B") })

        let performanceGroups = parsed.blocks[1].nodes.compactMap { node -> ParsedWorkoutGroup? in
            guard case .group(let group) = node else { return nil }
            return group
        }
        #expect(performanceGroups.map(\.durationSeconds) == [2_100, 2_100])
        #expect(performanceGroups.map { $0.children.flatMap(\.exercises).map(\.name) } == [
            ["StairMaster", "Box Step Over", "Hand Release Push-Up"],
            ["StairMaster", "Dumbbell Push Press", "Wall Ball"],
        ])
        #expect(performanceGroups[0].notes.contains { $0.contains("weight vest") })
        #expect(performanceGroups[1].notes.contains { $0.contains("without the weight vest") })
        guard case .group(let skiCore) = try #require(parsed.blocks[2].nodes.first) else {
            Issue.record("Expected one reconstructed ski and core parent group.")
            return
        }
        #expect(parsed.blocks[2].nodes.count == 1)
        #expect(skiCore.notes.contains { $0.contains("Fixture page 5 coaching context") })
        let normalized = WorkoutImportSemanticNormalizer.normalize(
            parsed,
            observations: request.sections.flatMap(\.observations)
        )
        let built = WorkoutImportDraftBuilder.build(normalized, catalog: ExerciseCatalog.definitions)
        let materialized = WorkoutImportMaterializer.materialize(built.draft)
        func guidanceNotes(_ guidance: CoachGuidance?) -> [String] {
            guard let guidance else { return [] }
            return [guidance.goal, guidance.tempo, guidance.progressionNotes].compactMap { $0 }
                + guidance.formCues
                + guidance.commonMistakes
        }
        let workoutGuidanceExpected = try [
            "p0-note-1", "p0-note-2", "p0-long-context",
            "p1-above", "p1-below", "p1-long-context",
        ].map { try #require(exactTextByID[$0]) }
        let p2LongNote = try #require(exactTextByID["p2-long-context"])
        let p3LongNote = try #require(exactTextByID["p3-long-context"])
        let p4LongNote = try #require(exactTextByID["p4-long-context"])

        // Materialization must preserve both exact note text and structural ownership. A
        // flattened assertion would still pass if a group or block note were promoted to the
        // workout, which changes how the imported workout is presented and edited.
        let workoutGuidanceNotes = guidanceNotes(materialized.guidance)
        #expect(workoutGuidanceNotes == workoutGuidanceExpected)
        #expect(!workoutGuidanceNotes.contains(p2LongNote))
        #expect(!workoutGuidanceNotes.contains(p3LongNote))
        #expect(!workoutGuidanceNotes.contains(p4LongNote))

        let materializedMED = try #require(materialized.blocks.first { $0.name == "Minimum Effective Dose (MED)" })
        let materializedPerformance = try #require(materialized.blocks.first { $0.name == "Performance Layer" })
        let materializedMDV = try #require(materialized.blocks.first { $0.name == "Maximum Daily Volume (MDV)" })
        #expect(guidanceNotes(materializedMED.guidance).isEmpty)
        #expect(guidanceNotes(materializedPerformance.guidance) == [
            p3LongNote,
            "StairMaster - 70 minutes total - ideally with a weight vest or ruck.",
        ])
        #expect(guidanceNotes(materializedMDV.guidance).isEmpty)

        let materializedPerformanceGroups = materializedPerformance.nodes.compactMap { node -> WorkoutGroup? in
            guard case .group(let group) = node else { return nil }
            return group
        }
        #expect(materializedPerformanceGroups.map(\.execution.repetition) == [
            .until(seconds: 2_100),
            .until(seconds: 2_100),
        ])
        #expect(materializedPerformanceGroups.map { $0.children.exercises.map(\.exerciseName) } == [
            ["Stair Stepper", "Box Step-Over", "Hand-Release Push-Up"],
            ["Stair Stepper", "Dual Dumbbell Push Press", "Wall Balls"],
        ])
        #expect(guidanceNotes(materializedPerformanceGroups[0].guidance) == [
            "Ideally use a weight vest during this phase.",
        ])
        #expect(guidanceNotes(materializedPerformanceGroups[1].guidance) == [
            "Complete this phase without the weight vest.",
        ])

        guard case .group(let materializedAMRAP) = try #require(materializedMED.nodes.first) else {
            Issue.record("Expected one materialized AMRAP parent group.")
            return
        }
        #expect(guidanceNotes(materializedAMRAP.guidance) == [
            p2LongNote,
            "Work through aerobic intervals then alternate A & B after the 6 sets for the duration of the AMRAP.",
        ])
        #expect(!guidanceNotes(materializedMED.guidance).contains(p2LongNote))

        guard case .group(let materializedSkiCore) = try #require(materializedMDV.nodes.first) else {
            Issue.record("Expected one materialized ski and core parent group.")
            return
        }
        #expect(guidanceNotes(materializedSkiCore.guidance) == [p4LongNote])
        #expect(!guidanceNotes(materializedMDV.guidance).contains(p4LongNote))

        let deadlift = try #require(materialized.allExercises.first { $0.definitionId == "deadlift" })
        let sled = try #require(materialized.allExercises.first { $0.definitionId == "sled_pull" })
        #expect(guidanceNotes(deadlift.guidance) == [
            "Use bodyweight as a descriptive barbell load target. The athlete must still be able to enter the actual bar weight.",
        ])
        #expect(materialized.allExercises.contains { $0.definitionId == "echo_bike" })
        #expect(materialized.allExercises.contains { $0.exerciseName.localizedCaseInsensitiveContains("push press") })
        #expect(materialized.allExercises.contains { $0.exerciseName.localizedCaseInsensitiveContains("lateral burpee") })
        #expect(deadlift.selectedMetrics.contains(.load))
        #expect(deadlift.prescription.sets.first?.load == nil)
        #expect(sled.selectedMetrics.contains(.load))
        #expect(sled.prescription.sets.first?.distance == 25)
        #expect(sled.prescription.sets.first?.load == nil)
        let builtSled = try #require(built.draft.workout.allExercises.first { $0.definitionId == "sled_pull" })
        let builtDeadlift = try #require(built.draft.workout.allExercises.first { $0.definitionId == "deadlift" })
        let sledEvidence = try #require(built.evidence.first { $0.exerciseID == builtSled.id })
        let deadliftEvidence = try #require(built.evidence.first { $0.exerciseID == builtDeadlift.id })
        #expect(sledEvidence.sourceObservationIDs == ["p2-sled"])
        #expect(deadliftEvidence.sourceObservationIDs == ["p2-deadlift"])
    }

    @Test @MainActor
    func manifestSchemaIsCheckedBeforeTypedDecodeAndSurfacedToTheUser() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportSchemaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let job = WorkoutImportJob(expectedPageCount: 1)
        try await repository.create(job)
        let manifest = root
            .appending(path: job.id.uuidString, directoryHint: .isDirectory)
            .appending(path: FileWorkoutImportJobRepository.manifestFilename)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        )
        object["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: object).write(to: manifest, options: .atomic)

        do {
            _ = try await repository.load(job.id)
            Issue.record("Expected the incompatible manifest envelope to be rejected.")
        } catch WorkoutImportJobRepositoryError.unsupportedSchema(
            let version,
            let incompatibleID,
            let expiresAt,
            _
        ) {
            #expect(version == 1)
            #expect(incompatibleID == job.id)
            #expect(abs(expiresAt.timeIntervalSince(job.expiresAt)) < 0.001)
        } catch {
            Issue.record("Unexpected manifest error: \(error)")
        }

        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            jobParser: CompletingWorkoutImportJobParser(serverJobID: "unused"),
            repository: repository
        )
        await model.restore(catalog: ExerciseCatalog.definitions).value
        #expect(model.session.status == .failed(
            message: "This saved import was created by an older Baseline version and cannot be resumed. Start a new import with the original photos."
        ))

        await model.cancel().value
        #expect(try await repository.load(job.id) == nil)
    }

    @Test
    func incompatibleManifestDoesNotHideANewerValidCheckpointAndExpiresWithItsSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportManifestIsolationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let now = Date(timeIntervalSince1970: 2_000_000)

        let incompatible = WorkoutImportJob(
            startedAt: now.addingTimeInterval(-100),
            lastUpdated: now.addingTimeInterval(-50),
            expiresAt: now.addingTimeInterval(-1)
        )
        try await repository.create(incompatible)
        _ = try await repository.writeSource(Data([1, 2, 3]), jobID: incompatible.id, pageIndex: 0)
        let incompatibleManifest = root
            .appending(path: incompatible.id.uuidString, directoryHint: .isDirectory)
            .appending(path: FileWorkoutImportJobRepository.manifestFilename)
        var incompatibleObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: incompatibleManifest)) as? [String: Any]
        )
        incompatibleObject["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: incompatibleObject).write(to: incompatibleManifest, options: .atomic)

        let valid = WorkoutImportJob(
            stage: .recognizingText,
            startedAt: now.addingTimeInterval(-10),
            lastUpdated: now,
            expiresAt: now.addingTimeInterval(WorkoutImportJob.retentionInterval)
        )
        try await repository.create(valid)

        let restored = try #require(try await repository.mostRecentActiveJob(now: now))
        #expect(restored.id == valid.id)

        await repository.removeExpired(now: now)
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: incompatible.id.uuidString, directoryHint: .isDirectory).path
        ) == false)
        #expect(try await repository.load(valid.id)?.id == valid.id)
    }

    @Test @MainActor
    func closeAndOnDisappearDuringNormalizationPreserveTheCheckpointForRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportCloseCheckpointTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let normalizer = SupersedingWorkoutImageNormalizer()
        let firstModel = WorkoutImportViewModel(
            normalizer: normalizer,
            recognizer: IndexedWorkoutTextRecognizer(),
            jobParser: CompletingWorkoutImportJobParser(serverJobID: "close-checkpoint-job"),
            repository: repository,
            coordinatorConfiguration: .init(pollingDelay: {})
        )

        let work = firstModel.importImage(Data([1]), catalog: ExerciseCatalog.definitions)
        let jobID = firstModel.session.id
        await normalizer.waitUntilFirstImportStarts()
        firstModel.pause()
        await normalizer.releaseFirstImport()
        await work.value

        let checkpoint = try #require(try await repository.load(jobID))
        #expect(checkpoint.pages.count == 1)
        #expect(checkpoint.pages.first?.stage == .sourceStored)
        #expect(try await repository.imageData(
            jobID: jobID,
            relativeFilename: try #require(checkpoint.pages.first?.sourceRelativeFilename)
        ) == Data([1]))

        let relaunched = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            jobParser: CompletingWorkoutImportJobParser(serverJobID: "close-checkpoint-job"),
            repository: repository,
            coordinatorConfiguration: .init(pollingDelay: {})
        )
        await relaunched.restore(catalog: ExerciseCatalog.definitions).value
        #expect(relaunched.session.status == .reviewing)
        await relaunched.cancel().value
    }

    @Test @MainActor
    func retryImmediatelyPreservesProgressAndRejectsDuplicateInitiation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportRetryStateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let progress = WorkoutImportServerProgress(
            serverJobID: "gated-retry-job",
            status: "failed",
            completedSections: 2,
            totalSections: 4,
            failureCode: "provider_unavailable"
        )
        let job = WorkoutImportJob(
            stage: .failed,
            expectedPageCount: 5,
            serverProgress: progress,
            failure: .init(stage: "server", reasonCode: "provider_unavailable", isRetryable: true)
        )
        try await repository.create(job)
        let parser = GatedFailingRetryWorkoutImportParser()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            jobParser: parser,
            repository: repository,
            initialSession: ImportSession(id: job.id, status: .failed(message: "Retry")),
            initialJob: job
        )

        let retry = try #require(model.retry(catalog: ExerciseCatalog.definitions))

        #expect(model.session.status == .retryingSections(completed: 2, total: 4))
        #expect(model.currentJob?.stage == .failed)
        #expect(!model.canRetry)
        #expect(model.retry(catalog: ExerciseCatalog.definitions) == nil)
        await parser.waitUntilRetryStarts()
        #expect(await parser.retryCallCount() == 1)

        await parser.releaseRetry()
        await retry.value

        guard case .failed = model.session.status else {
            Issue.record("Expected the failed retry to restore the failure state")
            return
        }
        #expect(model.canRetry)
        #expect(model.currentJob?.serverProgress?.completedSections == 2)
        #expect(model.currentJob?.serverProgress?.totalSections == 4)
        await model.cancel().value
    }

    @Test @MainActor
    func lifecycleCancellationDuringRemoteRetryNeverBecomesRemoteUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportRetryCancellationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let job = WorkoutImportJob(
            stage: .failed,
            expectedPageCount: 1,
            serverProgress: .init(
                serverJobID: "cancelled-retry-job",
                status: "failed",
                completedSections: 0,
                totalSections: 1,
                failureCode: "provider_unavailable"
            ),
            failure: .init(stage: "server", reasonCode: "provider_unavailable", isRetryable: true)
        )
        try await repository.create(job)
        let parser = CancellingRetryWorkoutImportParser()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            jobParser: parser,
            repository: repository,
            initialSession: ImportSession(id: job.id, status: .failed(message: "Retry")),
            initialJob: job
        )

        await model.retry(catalog: ExerciseCatalog.definitions)?.value

        #expect(model.currentJob?.failure == job.failure)
        #expect(try await repository.load(job.id)?.failure == job.failure)
        await model.cancel().value
    }

    @Test
    func terminalFailedRetryResponseDoesNotPollOrOverwriteTheServerFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportTerminalFailedRetryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let job = terminalRetryJob(serverJobID: "terminal-failed-retry")
        try await repository.create(job)
        let parser = TerminalRetryWorkoutImportParser(state: .failed, failureCode: "section_invalid")
        let coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser,
            configuration: .init(pollingDelay: {})
        )

        let result = await coordinator.retry(job, catalog: ExerciseCatalog.definitions, progress: { _ in })

        #expect(result.stage == .failed)
        #expect(result.failure?.reasonCode == "section_invalid")
        #expect(result.failure?.isRetryable == false)
        #expect(await parser.statusCallCount() == 0)
        #expect(try await repository.load(job.id)?.failure == result.failure)
    }

    @Test
    func terminalCancelledRetryResponseDoesNotPollAndBecomesNonRetryable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportTerminalCancelledRetryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let job = terminalRetryJob(serverJobID: "terminal-cancelled-retry")
        try await repository.create(job)
        let parser = TerminalRetryWorkoutImportParser(state: .cancelled)
        let coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser,
            configuration: .init(pollingDelay: {})
        )

        let result = await coordinator.retry(job, catalog: ExerciseCatalog.definitions, progress: { _ in })

        #expect(result.stage == .failed)
        #expect(result.failure?.reasonCode == "server_cancelled")
        #expect(result.failure?.isRetryable == false)
        #expect(await parser.statusCallCount() == 0)
        #expect(try await repository.load(job.id)?.failure == result.failure)
    }

    private func terminalRetryJob(serverJobID: String) -> WorkoutImportJob {
        WorkoutImportJob(
            stage: .failed,
            expectedPageCount: 1,
            serverProgress: .init(
                serverJobID: serverJobID,
                status: "failed",
                completedSections: 0,
                totalSections: 1,
                failureCode: "provider_unavailable"
            ),
            failure: .init(stage: "server", reasonCode: "provider_unavailable", isRetryable: true)
        )
    }

    @Test @MainActor
    func cancelBeforeTheFirstProgressCallbackStillCreatesAProtectedCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportEarlyCancelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GatedCreateWorkoutImportRepository(root: root)
        let parser = RecoveringCancellationWorkoutImportParser()
        await parser.makeCancellationAvailable()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            jobParser: parser,
            repository: repository
        )

        let work = model.importImage(Data([1]), catalog: ExerciseCatalog.definitions)
        let jobID = model.session.id
        await repository.waitUntilCreateStarts()
        #expect(model.currentJob == nil)
        let cleanup = model.cancel()
        await cleanup.value
        await repository.releaseCreate()
        await work.value

        #expect(await parser.cancelCallCount() == 1)
        #expect(try await repository.load(jobID) == nil)
        #expect(model.session.status == .selecting)
    }

    @Test @MainActor
    func missingOriginalsAreReselectedWithoutDiscardingStoredPages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportReselectionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let jobID = UUID()
        var job = WorkoutImportJob(
            id: jobID,
            stage: .failed,
            expectedPageCount: 3,
            failure: .init(stage: "local_restore", reasonCode: "source_intake_incomplete", isRetryable: false)
        )
        try await repository.create(job)
        let firstFilename = try await repository.writeSource(Data([1]), jobID: jobID, pageIndex: 0)
        job.pages = [WorkoutImportSourcePage(
            index: 0,
            sourceRelativeFilename: firstFilename,
            relativeFilename: "",
            digest: WorkoutImportStableIdentity.page(data: Data([1])),
            pixelWidth: 0,
            pixelHeight: 0,
            stage: .sourceStored
        )]
        try await repository.save(job)
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            jobParser: CompletingWorkoutImportJobParser(serverJobID: jobID.uuidString),
            repository: repository,
            initialSession: ImportSession(id: jobID, status: .failed(message: "Choose remaining photos")),
            initialJob: job
        )

        #expect(model.missingSourceCount == 2)
        #expect(model.requiresSourceReselection)
        await model.reconcileMissingSources(
            count: 2,
            catalog: ExerciseCatalog.definitions,
            loadImage: { Data([UInt8($0 + 2)]) }
        )?.value

        #expect(model.session.status == .reviewing)
        #expect(model.session.sourcePages.map(\.index) == [0, 1, 2])
        #expect(await model.sourceImageData(at: 0) == Data([1]))
        #expect(await model.sourceImageData(at: 1) == Data([2]))
        #expect(await model.sourceImageData(at: 2) == Data([3]))
        await model.cancel().value
    }

    @Test(arguments: ["image_too_large", "image_unreadable"])
    @MainActor
    func failedFourthPhotoPreservesThreePagesAndReplacesTheRemainingOrderedRemainder(
        reasonCode: String
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportFailedRemainderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let jobID = UUID()
        var job = WorkoutImportJob(
            id: jobID,
            stage: .failed,
            expectedPageCount: 5,
            failure: .init(stage: "local", reasonCode: reasonCode, isRetryable: false)
        )
        try await repository.create(job)
        for index in 0..<3 {
            let data = Data([UInt8(index + 1)])
            let filename = try await repository.writeSource(data, jobID: jobID, pageIndex: index)
            job.pages.append(WorkoutImportSourcePage(
                index: index,
                sourceRelativeFilename: filename,
                relativeFilename: "",
                digest: WorkoutImportStableIdentity.page(data: data),
                pixelWidth: 0,
                pixelHeight: 0,
                stage: .sourceStored
            ))
        }
        try await repository.save(job)
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            jobParser: CompletingWorkoutImportJobParser(serverJobID: jobID.uuidString),
            repository: repository,
            initialSession: ImportSession(id: jobID, status: .failed(message: "Replace remaining photos")),
            initialJob: job
        )

        #expect(model.missingSourceCount == 2)
        #expect(model.firstMissingSourcePosition == 4)
        #expect(model.requiresSourceReselection)
        #expect(model.sourceReselectionPrompt.contains("photo 4"))
        if reasonCode == "image_too_large" {
            #expect(model.sourceReselectionPrompt.contains("20 MB"))
        }

        await model.reconcileMissingSources(
            count: 2,
            catalog: ExerciseCatalog.definitions,
            loadImage: { Data([UInt8($0 + 4)]) }
        )?.value

        #expect(model.session.status == .reviewing)
        #expect(model.session.sourcePages.map(\.index) == [0, 1, 2, 3, 4])
        #expect(await model.sourceImageData(at: 0) == Data([1]))
        #expect(await model.sourceImageData(at: 3) == Data([4]))
        #expect(await model.sourceImageData(at: 4) == Data([5]))
        await model.cancel().value
    }

    @Test(arguments: ["image_too_large", "image_unreadable"], [1, 2, 4])
    @MainActor
    func sourceReselectionCopyUsesCorrectGrammarForEveryRemainingSuffix(
        reasonCode: String,
        missingCount: Int
    ) {
        let expectedPageCount = 5
        let retainedCount = expectedPageCount - missingCount
        let pages = (0..<retainedCount).map { index in
            WorkoutImportSourcePage(
                index: index,
                sourceRelativeFilename: "sources/\(index).source",
                relativeFilename: "",
                digest: "page-\(index)",
                pixelWidth: 0,
                pixelHeight: 0,
                stage: .sourceStored
            )
        }
        let job = WorkoutImportJob(
            stage: .failed,
            expectedPageCount: expectedPageCount,
            pages: pages,
            failure: .init(stage: "local", reasonCode: reasonCode, isRetryable: false)
        )
        let model = WorkoutImportViewModel(initialJob: job)
        let position = retainedCount + 1
        let prefix = reasonCode == "image_too_large"
            ? "Photo \(position) is over the 20 MB limit. "
            : "Baseline could not read photo \(position). "
        let suffix: String
        switch missingCount - 1 {
        case 0:
            suffix = "Choose a replacement for photo \(position) to continue."
        case 1:
            suffix = "Choose photo \(position) and the photo after it to continue."
        default:
            suffix = "Choose photo \(position) and the \(missingCount - 1) photos after it to continue."
        }

        #expect(model.sourceReselectionPrompt == prefix + suffix)
        #expect(!model.sourceReselectionPrompt.contains("1 photos"))
    }

    @Test func remoteRequestEncodingAndDiagnosticsCountTheExactPayloadBytes() async throws {
        let request = WorkoutImportRemoteStartRequest(
            clientJobID: "job",
            requestID: "request",
            jobHash: "hash",
            sections: [],
            catalogHints: ["Run"]
        )
        #expect(String(decoding: try request.encodedPayload(), as: UTF8.self) ==
            #"{"catalogHints":["Run"],"clientJobID":"job","jobHash":"hash","requestID":"request","schemaVersion":1,"sections":[]}"#)

        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportPayloadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = CompletingWorkoutImportJobParser(serverJobID: "payload-job")
        let coordinator = WorkoutImportCoordinator(
            repository: FileWorkoutImportJobRepository(root: root),
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser,
            configuration: .init(pollingDelay: {})
        )
        let result = await coordinator.start(
            imageCount: 1,
            catalog: ExerciseCatalog.definitions,
            loadImage: { _ in Data([1]) },
            progress: { _ in }
        )
        let sent = try #require(await parser.receivedRequest())
        let observability = try #require(sent.observability)
        #expect(observability.appVersion.isEmpty == false)
        #expect(observability.appBuild.isEmpty == false)
        #expect(observability.iosVersion.isEmpty == false)
        #expect(observability.deviceClass == "ios")
        #expect(observability.catalogVersion.isEmpty == false)
        let expectedPayloadBytes = try sent.encodedPayload().count
        #expect(result.diagnostics.parserPayloadBytes == expectedPayloadBytes)
        await coordinator.cancel(result)
    }

    @Test func protectedRepositoryRoundTripsAndExpiresACompleteCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportRepositoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let id = UUID()
        var job = WorkoutImportJob(id: id, expectedPageCount: 1)
        try await repository.create(job)
        let image = ImportedWorkoutImage(data: Data([1, 2, 3]), pixelWidth: 20, pixelHeight: 30)
        let sourceFilename = try await repository.writeSource(Data([9, 8, 7]), jobID: id, pageIndex: 0)
        let filename = try await repository.writeImage(image, jobID: id, pageIndex: 0)
        job.pages = [WorkoutImportSourcePage(
            index: 0,
            sourceRelativeFilename: sourceFilename,
            relativeFilename: filename,
            digest: WorkoutImportStableIdentity.page(data: image.data),
            pixelWidth: 20,
            pixelHeight: 30,
            stage: .recognized,
            observations: [observation("line", "Run 400 m", page: 0)]
        )]
        job.stage = .waitingForHandoff
        try await repository.save(job)

        let restored = try #require(try await repository.load(id))
        #expect(restored.id == job.id)
        #expect(restored.requestID == job.requestID)
        #expect(restored.stage == job.stage)
        #expect(restored.pages == job.pages)
        #expect(abs(restored.startedAt.timeIntervalSince(job.startedAt)) < 0.001)
        #expect(try await repository.imageData(jobID: id, relativeFilename: sourceFilename) == Data([9, 8, 7]))
        #expect(try await repository.imageData(jobID: id, relativeFilename: filename) == image.data)
        #expect(FileWorkoutImportJobRepository.protectedWriteOptions.contains(.atomic))
        #expect(FileWorkoutImportJobRepository.protectedWriteOptions.contains(.completeFileProtection))
        let rootValues = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(rootValues.isExcludedFromBackup == true)

        job.expiresAt = Date(timeIntervalSince1970: 0)
        try await repository.save(job)
        await repository.removeExpired(now: Date())
        #expect(try await repository.load(id) == nil)
    }

    @Test func semanticParagraphsAreNeverSplitAcrossSections() throws {
        let heading = observation("heading", "Coach Notes", page: 0, y: 0.95)
        let paragraph = (0..<120).map { index in
            observation(
                "note-\(index)",
                "keep this coaching sentence together line \(index)",
                page: 0,
                y: 0.88 - (Double(index) * 0.005)
            )
        }
        let exercises = (0..<100).map { index in
            observation("exercise-\(index)", "Movement \(index)", page: 0, y: 0.20 - (Double(index) * 0.001))
        }

        let document = try WorkoutImportSourceDocumentBuilder.build(
            pages: [sourcePage(index: 0, observations: [heading] + paragraph + exercises)]
        )
        let paragraphIDs = Set(paragraph.map(\.id))
        let containingSections = document.sections.filter { section in
            !paragraphIDs.isDisjoint(with: section.observations.map(\.id))
        }

        #expect(containingSections.count == 1)
        #expect(Set(try #require(containingSections.first).observations.map(\.id)).isSuperset(of: paragraphIDs))
        #expect(document.sections.allSatisfy { $0.observations.count <= 180 })
        #expect(document.sections.allSatisfy { $0.characterCount <= 6_000 })
    }

    @Test func longAMRAPFragmentsKeepOneParentScopeAndAtomicOptions() throws {
        let pages = (0..<5).map { pageIndex in
            var observations = [WorkoutTextObservation]()
            if pageIndex == 0 {
                observations.append(observation(
                    "med-heading",
                    "Minimum Effective Dose (MED)",
                    page: pageIndex,
                    y: 0.92
                ))
                observations.append(observation(
                    "amrap-heading",
                    "70 minute AMRAP +/- 10 minutes based on desired volume.",
                    page: pageIndex,
                    y: 0.82
                ))
            }
            observations.append(observation(
                "long-note-\(pageIndex)",
                "Page \(pageIndex + 1). " + String(
                    repeating: "Preserve this coaching detail for the complete AMRAP. ",
                    count: 32
                ),
                page: pageIndex,
                y: 0.60
            ))
            if pageIndex == 4 {
                observations.append(observation("option-a", "A. 25 m Sled Pull", page: pageIndex, y: 0.30))
                observations.append(observation("option-b", "B. 12 Deadlifts at bodyweight", page: pageIndex, y: 0.20))
                observations.append(observation(
                    "required",
                    "Required after either option: 12 lateral burpees over barbell",
                    page: pageIndex,
                    y: 0.10
                ))
            }
            return sourcePage(index: pageIndex, observations: observations)
        }

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)

        #expect(document.sections.count > 1)
        let parentScope = try #require(document.sections.first?.startScopeID)
        #expect(document.sections.allSatisfy { $0.startScopeID == parentScope && $0.endScopeID == parentScope })
        for index in 1..<document.sections.count {
            #expect(document.sections[index].continuationFromSectionID == document.sections[index - 1].id)
        }
        let optionSectionIndexes = document.sections.indices.filter { index in
            document.sections[index].observations.contains { ["option-a", "option-b", "required"].contains($0.id) }
        }
        #expect(optionSectionIndexes.count == 1)
        let optionIDs = Set(document.sections[try #require(optionSectionIndexes.first)].observations.map(\.id))
        #expect(optionIDs.isSuperset(of: ["option-a", "option-b", "required"]))
    }

    @Test func anOversizedSemanticParagraphFailsInsteadOfBeingSilentlySplit() {
        let line = observation("long-note", String(repeating: "coaching detail ", count: 500), page: 0)

        #expect(throws: WorkoutImportSourceDocumentError.semanticUnitTooLarge) {
            try WorkoutImportSourceDocumentBuilder.build(
                pages: [sourcePage(index: 0, observations: [line])]
            )
        }
    }

    @Test func sourceByteLimitAcceptsTheBoundaryAndRejectsBeforePersistence() throws {
        #expect(throws: Never.self) {
            try WorkoutImageSourceValidator.validate(byteCount: WorkoutImageImportLimits.maximumSourceBytes)
        }
        #expect(throws: WorkoutImagePipelineError.self) {
            try WorkoutImageSourceValidator.validate(byteCount: WorkoutImageImportLimits.maximumSourceBytes + 1)
        }
        #expect(throws: WorkoutImagePipelineError.self) {
            try WorkoutImageSourceValidator.validate(byteCount: 0)
        }
    }

    @Test func stableIdentitiesAndSectionBoundariesAreDeterministic() throws {
        let pageDigest = WorkoutImportStableIdentity.page(data: Data("page".utf8))
        let bounds = WorkoutTextObservation.Rect(x: 0.12, y: 0.34, width: 0.5, height: 0.06)
        let first = WorkoutImportStableIdentity.observation(pageDigest: pageDigest, text: "Run 400 m", boundingBox: bounds)
        let second = WorkoutImportStableIdentity.observation(pageDigest: pageDigest, text: "  run 400 M ", boundingBox: bounds)
        #expect(first == second)
        #expect(first.count == 64)
        let firstPageIdentity = WorkoutImportStableIdentity.digest([pageDigest, "0"])
        let secondPageIdentity = WorkoutImportStableIdentity.digest([pageDigest, "1"])
        #expect(WorkoutImportStableIdentity.observation(
            pageDigest: firstPageIdentity,
            text: "Run 400 m",
            boundingBox: bounds
        ) != WorkoutImportStableIdentity.observation(
            pageDigest: secondPageIdentity,
            text: "Run 400 m",
            boundingBox: bounds
        ))

        let observations = (0..<181).map { index in
            observation("line-\(index)", "Movement \(index)", page: 0, y: Double(181 - index) / 200)
        }
        let page = sourcePage(index: 0, observations: observations)
        let firstDocument = try WorkoutImportSourceDocumentBuilder.build(pages: [page])
        let secondDocument = try WorkoutImportSourceDocumentBuilder.build(pages: [page])
        #expect(firstDocument == secondDocument)
        #expect(firstDocument.sections.count == 2)
        #expect(firstDocument.sections.allSatisfy {
            $0.observations.count <= WorkoutImportSourceDocumentBuilder.preferredSectionObservations
        })
        #expect(firstDocument.sections.allSatisfy { $0.observations.count <= 180 })
        #expect(firstDocument.sections.allSatisfy { $0.characterCount <= 6_000 })
        #expect(firstDocument.sections[1].contextBefore.count == 3)
    }

    @Test(.bug(id: 2))
    func fivePage109ObservationImportUsesTwoDeterministicSemanticSections() throws {
        var globalIndex = 0
        let pages = (0..<5).map { pageIndex in
            let count = pageIndex < 4 ? 22 : 21
            let observations = (0..<count).map { lineIndex in
                let targetLength = globalIndex < 66 ? 30 : 29
                let prefix = "coaching detail \(globalIndex) "
                let text = prefix + String(repeating: "x", count: targetLength - prefix.count)
                defer { globalIndex += 1 }
                return observation(
                    WorkoutImportStableIdentity.digest(["live-timeout", String(globalIndex)]),
                    text,
                    page: pageIndex,
                    y: 0.90 - (Double(lineIndex) * 0.03)
                )
            }
            return sourcePage(index: pageIndex, observations: observations)
        }

        let first = try WorkoutImportSourceDocumentBuilder.build(pages: pages)
        let second = try WorkoutImportSourceDocumentBuilder.build(pages: pages)

        #expect(first == second)
        #expect(first.lines.count == 109)
        #expect(first.lines.reduce(0) { $0 + $1.text.count } == 3_227)
        #expect(first.sections.count == 2)
        #expect(first.sections.map(\.observations.count) == [88, 21])
        #expect(first.sections.allSatisfy {
            $0.observations.count <= WorkoutImportSourceDocumentBuilder.preferredSectionObservations
        })
        for pageIndex in 0..<5 {
            let containingSections = first.sections.filter { section in
                section.observations.contains { $0.sourceImageIndex == pageIndex }
            }
            #expect(containingSections.count == 1)
        }
    }

    @Test(.bug(id: 2))
    func maximumSupportedObservationCountFitsTheTwentySectionServerLimit() throws {
        let pages = (0..<10).map { pageIndex in
            sourcePage(
                index: pageIndex,
                observations: (0..<200).map { lineIndex in
                    let globalIndex = (pageIndex * 200) + lineIndex
                    return observation(
                        WorkoutImportStableIdentity.digest(["maximum-import", String(globalIndex)]),
                        "Movement \(globalIndex)",
                        page: pageIndex,
                        y: 0.99 - (Double(lineIndex) * 0.004)
                    )
                }
            )
        }

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)

        #expect(document.lines.count == 2_000)
        #expect(document.sections.count == 20)
        #expect(document.sections.map(\.observations.count) == Array(repeating: 100, count: 20))
        #expect(document.sections.allSatisfy { $0.observations.count <= 180 })
        #expect(document.sections.allSatisfy { $0.characterCount <= 6_000 })
    }

    @Test(.bug(id: 2))
    func atomicParagraphsRepackToTheHardLimitInsteadOfExceedingTwentySections() throws {
        var unitIndex = 0
        let pages = (0..<10).map { pageIndex in
            let unitsOnPage = pageIndex < 9 ? 4 : 3
            var observations: [WorkoutTextObservation] = []
            for pageUnitIndex in 0..<unitsOnPage {
                let y = 0.90 - (Double(pageUnitIndex) * 0.15)
                for lineIndex in 0..<51 {
                    observations.append(observation(
                        String(format: "p%02du%02dl%02d", pageIndex, unitIndex, lineIndex),
                        String(format: "move p%02du%02dl%02d", pageIndex, unitIndex, lineIndex),
                        page: pageIndex,
                        y: y
                    ))
                }
                unitIndex += 1
            }
            return sourcePage(index: pageIndex, observations: observations)
        }

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)

        #expect(document.lines.count == 1_989)
        #expect(document.sections.count == 13)
        #expect(document.sections.allSatisfy { $0.observations.count == 153 })
        #expect(document.sections.allSatisfy {
            $0.observations.count <= WorkoutImportSourceDocumentBuilder.maximumSectionObservations
        })
        #expect(document.sections.allSatisfy { $0.characterCount <= 6_000 })
        #expect(Set(document.sections.flatMap(\.provenanceObservationIDs)).count == 1_989)
    }

    @Test func ambiguousAdjacentOverlapIsPreservedWithDistinctProvenance() throws {
        let page0 = sourcePage(index: 0, observations: [
            observation("clock-0", "5:53", page: 0, y: 0.93),
            observation("rounds-0", "4 Rounds", page: 0, y: 0.80),
            observation("a", "25 m Sled Pull", page: 0, y: 0.40),
            observation("b", "12 Deadlifts at bodyweight", page: 0, y: 0.30),
        ])
        let page1 = sourcePage(index: 1, observations: [
            observation("clock-1", "5:53", page: 1, y: 0.93),
            observation("rounds-1", "4 Rounds", page: 1, y: 0.20),
            observation("a-copy", "25 m Sled Pull", page: 1, y: 0.70),
            observation("b-copy", "12 Deadlifts at bodyweight", page: 1, y: 0.60),
            observation("c", "12 Lateral Burpees Over Barbell", page: 1, y: 0.50),
        ])

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: [page0, page1])

        #expect(document.lines.count { $0.text == "5:53" } == 2)
        #expect(document.lines.count { $0.text == "4 Rounds" } == 2)
        #expect(document.lines.count { $0.text == "25 m Sled Pull" } == 2)
        let sledSources = document.lines
            .filter { $0.text == "25 m Sled Pull" }
            .map(\.sourceObservationIDs)
        #expect(sledSources == [["a"], ["a-copy"]])
        #expect(document.sections.flatMap(\.observations).count { $0.text == "25 m Sled Pull" } == 2)
        #expect(Set(document.sections.flatMap(\.provenanceObservationIDs)).isSuperset(of: ["a", "a-copy"]))
    }

    @Test(.bug(id: 2))
    func repeatedColonDurationsRemainProgrammingWithoutStrongStatusEvidence() throws {
        let pages = [
            sourcePage(index: 0, observations: [
                observation("timer-0", "10:00", page: 0, y: 0.94),
                observation("run-0", "Run", page: 0, y: 0.70),
            ]),
            sourcePage(index: 1, observations: [
                observation("timer-1", "10:00", page: 1, y: 0.94),
                observation("run-1", "Run", page: 1, y: 0.70),
            ]),
        ]

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)

        #expect(document.lines.count { $0.text == "10:00" } == 2)
        #expect(Set(document.sections.flatMap(\.provenanceObservationIDs)).isSuperset(of: ["timer-0", "timer-1"]))
    }

    @Test(.bug(id: 2))
    func repeatedProgrammingWithAConsistentScrollShiftRemainsDistinct() throws {
        let pages = [
            sourcePage(index: 0, observations: [
                observation("timer-0", "10:00", page: 0, y: 0.70),
                observation("run-0", "Run", page: 0, y: 0.60),
            ]),
            sourcePage(index: 1, observations: [
                observation("timer-1", "10:00", page: 1, y: 0.85),
                observation("run-1", "Run", page: 1, y: 0.75),
            ]),
        ]

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)

        #expect(document.lines.count { $0.text == "10:00" } == 2)
        #expect(document.lines.count { $0.text == "Run" } == 2)
        #expect(Set(document.sections.flatMap(\.provenanceObservationIDs)) == [
            "timer-0", "run-0", "timer-1", "run-1",
        ])
    }

    @Test(.bug(id: 2))
    func repeatedEdgePercentagesAndWorkoutHeadingsRemainDistinct() throws {
        let pages = [
            sourcePage(index: 0, observations: [
                observation("percent-0", "90%", page: 0, y: 0.94),
                observation("cooldown-0", "Cooldown", page: 0, y: 0.06),
            ]),
            sourcePage(index: 1, observations: [
                observation("percent-1", "90%", page: 1, y: 0.94),
                observation("cooldown-1", "Cooldown", page: 1, y: 0.06),
            ]),
        ]

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)

        #expect(document.lines.count { $0.text == "90%" } == 2)
        #expect(document.lines.count { $0.text == "Cooldown" } == 2)
        #expect(Set(document.sections.flatMap(\.provenanceObservationIDs)) == [
            "percent-0", "cooldown-0", "percent-1", "cooldown-1",
        ])
    }

    @Test(.bug(id: 2))
    func repeatedUnknownEdgeCoachingCuesRemainInTheirOriginalScopes() throws {
        let pages = [
            sourcePage(index: 0, observations: [
                observation("block-a", "Tempo Block", page: 0, y: 0.20),
                observation("breathe-a", "Breathe", page: 0, y: 0.06),
            ]),
            sourcePage(index: 1, observations: [
                observation("block-b", "Overload Block", page: 1, y: 0.20),
                observation("breathe-b", "Breathe", page: 1, y: 0.06),
            ]),
        ]

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)

        let cues = document.lines.filter { $0.text == "Breathe" }
        #expect(cues.count == 2)
        #expect(cues.map(\.sourceImageIndex) == [0, 1])
        #expect(cues.map(\.sourceObservationIDs) == [["breathe-a"], ["breathe-b"]])
        #expect(Set(document.sections.flatMap(\.provenanceObservationIDs)).isSuperset(of: [
            "block-a", "breathe-a", "block-b", "breathe-b",
        ]))
    }

    @Test(.bug(id: 2))
    func varyingStatusBarClocksAndPercentagesRemainWhileExplicitNetworkChromeIsRemoved() throws {
        func status(
            _ id: String,
            _ text: String,
            page: Int,
            x: Double,
            width: Double = 0.12
        ) -> WorkoutTextObservation {
            WorkoutTextObservation(
                id: id,
                text: text,
                confidence: 0.98,
                boundingBox: .init(x: x, y: 0.96, width: width, height: 0.03),
                sourceImageIndex: page
            )
        }
        let heading = observation("heading", "12 Burpees", page: 0, y: 0.95)
        let reps = WorkoutTextObservation(
            id: "reps",
            text: "12 Reps",
            confidence: 0.98,
            boundingBox: .init(x: 0.35, y: 0.96, width: 0.12, height: 0.03),
            sourceImageIndex: 0
        )
        let cooldown = WorkoutTextObservation(
            id: "cooldown",
            text: "Cooldown",
            confidence: 0.98,
            boundingBox: .init(x: 0.35, y: 0.96, width: 0.12, height: 0.03),
            sourceImageIndex: 1
        )
        let pages = [
            sourcePage(index: 0, observations: [
                status("clock-0", "8:13 0", page: 0, x: 0.05),
                status("battery-0", "89%", page: 0, x: 0.84),
                reps,
                heading,
            ]),
            sourcePage(index: 1, observations: [
                status("clock-1", "8:14 0", page: 1, x: 0.05),
                status("network-1", "5G UW", page: 1, x: 0.68),
                status("battery-1", "88%", page: 1, x: 0.84),
                cooldown,
                observation("run", "Run 400 m", page: 1, y: 0.80),
            ]),
        ]

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)

        #expect(document.lines.map(\.id).contains("heading"))
        #expect(document.lines.map(\.id).contains("run"))
        #expect(document.lines.map(\.id).contains("reps"))
        #expect(document.lines.map(\.id).contains("cooldown"))
        #expect(document.lines.filter { $0.id.hasPrefix("clock-") }.count == 2)
        #expect(document.lines.filter { $0.id.hasPrefix("battery-") }.count == 2)
        #expect(document.lines.contains { $0.id.hasPrefix("network-") } == false)
    }

    @Test(.bug(id: 2))
    func oneStatusLikeClusterCannotActivateLayoutBasedRemoval() throws {
        func status(_ id: String, _ text: String, x: Double) -> WorkoutTextObservation {
            WorkoutTextObservation(
                id: id,
                text: text,
                confidence: 0.98,
                boundingBox: .init(x: x, y: 0.96, width: 0.12, height: 0.03),
                sourceImageIndex: 0
            )
        }
        let pages = [
            sourcePage(index: 0, observations: [
                status("clock-0", "8:13 0", x: 0.05),
                status("battery-0", "89", x: 0.84),
                observation("heading", "Main", page: 0, y: 0.80),
            ]),
            sourcePage(index: 1, observations: [
                observation("run", "Run 400 m", page: 1, y: 0.80),
            ]),
        ]

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)

        #expect(document.lines.map(\.id).contains("clock-0"))
        #expect(document.lines.map(\.id).contains("battery-0"))
    }

    @Test(.bug(id: 2))
    func croppedTimersAndBareNumericTargetsRemainSourceContent() throws {
        func narrow(_ id: String, _ text: String, page: Int, x: Double) -> WorkoutTextObservation {
            WorkoutTextObservation(
                id: id,
                text: text,
                confidence: 0.98,
                boundingBox: .init(x: x, y: 0.96, width: 0.12, height: 0.03),
                sourceImageIndex: page
            )
        }
        let pages = [
            sourcePage(index: 0, observations: [
                narrow("timer-0", "12:30", page: 0, x: 0.05),
                narrow("target-0", "90", page: 0, x: 0.84),
                observation("heading", "Main", page: 0, y: 0.80),
            ]),
            sourcePage(index: 1, observations: [
                narrow("timer-1", "10:00", page: 1, x: 0.05),
                narrow("target-1", "80", page: 1, x: 0.84),
                observation("run", "Run 400 m", page: 1, y: 0.80),
            ]),
        ]

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)
        let ids = Set(document.lines.map(\.id))

        #expect(ids.isSuperset(of: ["timer-0", "target-0", "timer-1", "target-1"]))
    }

    @Test(.bug(id: 2))
    func croppedTimersAndPercentageTargetsRemainSourceContent() throws {
        func narrow(_ id: String, _ text: String, page: Int, x: Double) -> WorkoutTextObservation {
            WorkoutTextObservation(
                id: id,
                text: text,
                confidence: 0.98,
                boundingBox: .init(x: x, y: 0.96, width: 0.12, height: 0.03),
                sourceImageIndex: page
            )
        }
        let pages = [
            sourcePage(index: 0, observations: [
                narrow("timer-0", "12:30", page: 0, x: 0.05),
                narrow("target-0", "90%", page: 0, x: 0.84),
                observation("heading", "Main", page: 0, y: 0.80),
            ]),
            sourcePage(index: 1, observations: [
                narrow("timer-1", "10:00", page: 1, x: 0.05),
                narrow("target-1", "80%", page: 1, x: 0.84),
                observation("run", "Run 400 m", page: 1, y: 0.80),
            ]),
        ]

        let document = try WorkoutImportSourceDocumentBuilder.build(pages: pages)
        let ids = Set(document.lines.map(\.id))

        #expect(ids.isSuperset(of: ["timer-0", "target-0", "timer-1", "target-1"]))
    }

    @Test func restoreResumesRemoteStatusWithoutRepeatingOCR() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportRestoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let observation = observation("line", "Run 400 m", page: 0)
        let section = WorkoutImportSourceSection(
            id: WorkoutImportStableIdentity.section(observations: [observation]),
            order: 0,
            observations: [observation],
            provenanceObservationIDs: [observation.id],
            contextBefore: [],
            characterCount: observation.text.count
        )
        let job = WorkoutImportJob(
            stage: .processingSections,
            expectedPageCount: 1,
            pages: [sourcePage(index: 0, observations: [observation])],
            sections: [section],
            serverProgress: .init(
                serverJobID: "server-job",
                status: "processing",
                completedSections: 0,
                totalSections: 1
            )
        )
        try await repository.create(job)
        let parser = CompletingWorkoutImportJobParser(serverJobID: "server-job")
        let coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser,
            configuration: .init(pollingDelay: {})
        )

        let restored = try #require(await coordinator.restoreLatest(
            catalog: ExerciseCatalog.definitions,
            progress: { _ in }
        ))

        #expect(restored.stage == .reviewing)
        #expect(restored.draft?.workout.allExercises.first?.exerciseName == "Run")
        #expect(await parser.statusCallCount() == 1)
        #expect(await parser.startCallCount() == 0)
    }

    @Test @MainActor
    func recognizedTextReviewCanRefreshTheStillRunningServerJobWithoutRepeatingOCR() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportFallbackRefreshTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let recognized = observation("line", "Run 400 m", page: 0)
        let section = WorkoutImportSourceSection(
            id: WorkoutImportStableIdentity.section(observations: [recognized]),
            order: 0,
            observations: [recognized],
            provenanceObservationIDs: [recognized.id],
            contextBefore: [],
            characterCount: recognized.text.count
        )
        let fallbackDocument = WorkoutImportFallbackBuilder.build(sections: [section])
        let fallback = WorkoutImportDraftBuilder.build(
            fallbackDocument,
            catalog: ExerciseCatalog.definitions
        )
        let job = WorkoutImportJob(
            stage: .reviewing,
            expectedPageCount: 1,
            pages: [sourcePage(index: 0, observations: [recognized])],
            sections: [section],
            serverProgress: .init(
                serverJobID: "fallback-refresh-job",
                status: WorkoutImportRemoteJobState.processing.rawValue,
                completedSections: 0,
                totalSections: 1
            ),
            parsedDocument: fallbackDocument,
            draft: fallback.draft,
            issues: fallback.issues,
            evidence: fallback.evidence
        )
        try await repository.create(job)
        let parser = CompletingWorkoutImportJobParser(serverJobID: "fallback-refresh-job")
        let recognizer = IndexRecordingWorkoutTextRecognizer()
        var initialSession = ImportSession(id: job.id)
        initialSession.draft = fallback.draft
        initialSession.status = .reviewing
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: recognizer,
            jobParser: parser,
            repository: repository,
            initialSession: initialSession,
            initialJob: job
        )

        #expect(model.canRefreshStructuredResult)
        #expect(model.session.draft?.workout.allExercises.map(\.exerciseName) == ["Run"])

        await model.refreshStructuredResult(catalog: ExerciseCatalog.definitions)?.value

        #expect(model.session.status == .reviewing)
        #expect(model.session.draft?.workout.allExercises.first?.exerciseName == "Run")
        #expect(model.hasCompletedServerResult)
        #expect(!model.canRefreshStructuredResult)
        #expect(await parser.statusCallCount() == 1)
        #expect(await parser.startCallCount() == 0)
        #expect(await recognizer.recognizedIndexes().isEmpty)
        await model.cancel().value
    }

    @Test(arguments: [
        WorkoutImportRemoteJobState.queued,
        WorkoutImportRemoteJobState.processing,
        WorkoutImportRemoteJobState.failed,
        WorkoutImportRemoteJobState.cancelled,
    ]) @MainActor
    func refreshKeepsFallbackEditsUntilACompletedServerResultIsReady(
        state: WorkoutImportRemoteJobState
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportFallbackRefreshStateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let recognized = observation("line", "Run 400 m", page: 0)
        let section = WorkoutImportSourceSection(
            id: WorkoutImportStableIdentity.section(observations: [recognized]),
            order: 0,
            observations: [recognized],
            provenanceObservationIDs: [recognized.id],
            contextBefore: [],
            characterCount: recognized.text.count
        )
        let fallbackDocument = WorkoutImportFallbackBuilder.build(sections: [section])
        let fallback = WorkoutImportDraftBuilder.build(
            fallbackDocument,
            catalog: ExerciseCatalog.definitions
        )
        let job = WorkoutImportJob(
            stage: .reviewing,
            expectedPageCount: 1,
            pages: [sourcePage(index: 0, observations: [recognized])],
            sections: [section],
            serverProgress: .init(
                serverJobID: "fallback-refresh-state-job",
                status: WorkoutImportRemoteJobState.processing.rawValue,
                completedSections: 0,
                totalSections: 1
            ),
            parsedDocument: fallbackDocument,
            draft: fallback.draft,
            issues: fallback.issues,
            evidence: fallback.evidence
        )
        try await repository.create(job)
        var initialSession = ImportSession(id: job.id)
        initialSession.draft = fallback.draft
        initialSession.status = .reviewing
        let parser = FixedStatusWorkoutImportJobParser(state: state)
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexRecordingWorkoutTextRecognizer(),
            jobParser: parser,
            repository: repository,
            initialSession: initialSession,
            initialJob: job
        )
        model.updateWorkout { $0.title = "Athlete's fallback edit" }

        await model.refreshStructuredResult(catalog: ExerciseCatalog.definitions)?.value

        #expect(model.session.status == .reviewing)
        #expect(model.session.draft?.workout.title == "Athlete's fallback edit")
        #expect(model.currentJob?.serverProgress?.status == state.rawValue)
        #expect(model.canRefreshStructuredResult == (state == .queued || state == .processing))
        #expect(!model.hasCompletedServerResult)
        #expect(await parser.statusCallCount() == 1)
        await model.cancel().value
    }

    @Test @MainActor
    func unreachableRefreshKeepsFallbackEditsAndRemainsRefreshable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportFallbackRefreshOfflineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let recognized = observation("line", "Run 400 m", page: 0)
        let section = WorkoutImportSourceSection(
            id: WorkoutImportStableIdentity.section(observations: [recognized]),
            order: 0,
            observations: [recognized],
            provenanceObservationIDs: [recognized.id],
            contextBefore: [],
            characterCount: recognized.text.count
        )
        let fallbackDocument = WorkoutImportFallbackBuilder.build(sections: [section])
        let fallback = WorkoutImportDraftBuilder.build(
            fallbackDocument,
            catalog: ExerciseCatalog.definitions
        )
        let job = WorkoutImportJob(
            stage: .reviewing,
            expectedPageCount: 1,
            pages: [sourcePage(index: 0, observations: [recognized])],
            sections: [section],
            serverProgress: .init(
                serverJobID: "fallback-refresh-offline-job",
                status: WorkoutImportRemoteJobState.processing.rawValue,
                completedSections: 0,
                totalSections: 1
            ),
            parsedDocument: fallbackDocument,
            draft: fallback.draft,
            issues: fallback.issues,
            evidence: fallback.evidence
        )
        try await repository.create(job)
        var initialSession = ImportSession(id: job.id)
        initialSession.draft = fallback.draft
        initialSession.status = .reviewing
        let parser = RecoveringCancellationWorkoutImportParser()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexRecordingWorkoutTextRecognizer(),
            jobParser: parser,
            repository: repository,
            initialSession: initialSession,
            initialJob: job
        )
        model.updateWorkout { $0.title = "Offline fallback edit" }

        await model.refreshStructuredResult(catalog: ExerciseCatalog.definitions)?.value

        #expect(model.session.status == .reviewing)
        #expect(model.session.draft?.workout.title == "Offline fallback edit")
        #expect(model.canRefreshStructuredResult)
        #expect(!model.hasCompletedServerResult)
        await parser.makeCancellationAvailable()
        await model.cancel().value
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        WorkoutImportRemoteJobState.queued,
        WorkoutImportRemoteJobState.processing,
        WorkoutImportRemoteJobState.completed,
        WorkoutImportRemoteJobState.failed,
        WorkoutImportRemoteJobState.cancelled,
    ]) @MainActor
    func savingWhileRefreshIsSuspendedCannotResurrectTheImport(
        state: WorkoutImportRemoteJobState
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportRefreshSaveRaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let workout = Workout(title: "Reviewed fallback", blocks: [
            WorkoutBlock(name: "Main", exercises: [
                PlannedExercise(exerciseName: "Run", definitionId: "run"),
            ]),
        ])
        let draft = WorkoutTemplateDraft(workout: workout)
        let job = WorkoutImportJob(
            stage: .reviewing,
            expectedPageCount: 1,
            serverProgress: .init(
                serverJobID: "refresh-save-race-job",
                status: WorkoutImportRemoteJobState.processing.rawValue,
                completedSections: 0,
                totalSections: 1
            ),
            draft: draft
        )
        try await repository.create(job)
        let parser = GatedStatusWorkoutImportJobParser(state: state)
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexRecordingWorkoutTextRecognizer(),
            jobParser: parser,
            repository: repository,
            initialSession: ImportSession(id: job.id, draft: draft, status: .reviewing),
            initialJob: job
        )

        let refresh = try #require(model.refreshStructuredResult(catalog: ExerciseCatalog.definitions))
        await parser.waitUntilStatusStarts()

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))
        #expect(model.saveNewTemplate(in: plan) != nil)

        await parser.releaseStatus()
        await refresh.value
        await model.waitForPendingCleanup()

        guard case .saved = model.session.status else {
            Issue.record("Expected save to remain terminal after the late status response")
            return
        }
        #expect(model.currentJob == nil)
        #expect(try await repository.load(job.id) == nil)
        #expect(await parser.cancelCallCount() == 1)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func editingWhileRefreshIsSuspendedKeepsTheNewerDraft() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportRefreshEditRaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let workout = Workout(title: "Fallback before refresh", blocks: [
            WorkoutBlock(name: "Main", exercises: [
                PlannedExercise(exerciseName: "Run", definitionId: "run"),
            ]),
        ])
        let draft = WorkoutTemplateDraft(workout: workout)
        let job = WorkoutImportJob(
            stage: .reviewing,
            expectedPageCount: 1,
            serverProgress: .init(
                serverJobID: "refresh-edit-race-job",
                status: WorkoutImportRemoteJobState.processing.rawValue,
                completedSections: 0,
                totalSections: 1
            ),
            draft: draft
        )
        try await repository.create(job)
        let parser = GatedStatusWorkoutImportJobParser()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexRecordingWorkoutTextRecognizer(),
            jobParser: parser,
            repository: repository,
            initialSession: ImportSession(id: job.id, draft: draft, status: .reviewing),
            initialJob: job
        )

        let refresh = try #require(model.refreshStructuredResult(catalog: ExerciseCatalog.definitions))
        await parser.waitUntilStatusStarts()
        model.updateWorkout { $0.title = "Newer athlete edit" }
        await parser.releaseStatus()
        await refresh.value

        #expect(model.session.status == .reviewing)
        #expect(model.session.draft?.workout.title == "Newer athlete edit")
        #expect(model.canRefreshStructuredResult)
        #expect(try await repository.load(job.id)?.draft?.workout.title == "Newer athlete edit")
        await model.cancel().value
    }

    @Test func restoreFinishesOCRFromProtectedPreparedPages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportPreparedRestoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let id = UUID()
        var job = WorkoutImportJob(id: id, stage: .recognizingText, expectedPageCount: 2)
        try await repository.create(job)
        for index in 0..<2 {
            let image = ImportedWorkoutImage(data: Data([UInt8(index + 1)]), pixelWidth: 10, pixelHeight: 20)
            let filename = try await repository.writeImage(image, jobID: id, pageIndex: index)
            job.pages.append(WorkoutImportSourcePage(
                index: index,
                relativeFilename: filename,
                digest: WorkoutImportStableIdentity.page(data: image.data),
                pixelWidth: 10,
                pixelHeight: 20,
                stage: .prepared
            ))
        }
        try await repository.save(job)
        let recognizer = CountingPreparedWorkoutTextRecognizer()
        let parser = CompletingWorkoutImportJobParser(serverJobID: id.uuidString)
        let coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: recognizer,
            parser: parser
        )

        let restored = try #require(await coordinator.restoreLatest(
            catalog: ExerciseCatalog.definitions,
            progress: { _ in }
        ))

        #expect(restored.stage == .reviewing)
        #expect(restored.pages.map(\.stage) == [.recognized, .recognized])
        #expect(await recognizer.callCount() == 2)
        #expect(await parser.startCallCount() == 1)
    }

    @Test func restoreResumesMixedSourceNormalizationAndOCRCheckpointsWithoutRepeatingWork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportMixedRestoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let id = UUID()
        var job = WorkoutImportJob(id: id, stage: .recognizingText, expectedPageCount: 3)
        try await repository.create(job)

        for index in 0..<3 {
            let data = Data([UInt8(index + 1)])
            let sourceFilename = try await repository.writeSource(data, jobID: id, pageIndex: index)
            var page = WorkoutImportSourcePage(
                index: index,
                sourceRelativeFilename: sourceFilename,
                relativeFilename: "",
                digest: WorkoutImportStableIdentity.page(data: data),
                pixelWidth: 0,
                pixelHeight: 0,
                stage: .sourceStored
            )
            if index > 0 {
                let image = ImportedWorkoutImage(data: data, pixelWidth: 10, pixelHeight: 20)
                page.relativeFilename = try await repository.writeImage(image, jobID: id, pageIndex: index)
                page.pixelWidth = 10
                page.pixelHeight = 20
                page.stage = .prepared
            }
            if index == 2 {
                page.stage = .recognized
                page.observations = [observation("already-recognized", "Run 400 m", page: index)]
            }
            job.pages.append(page)
        }
        try await repository.save(job)
        let normalizer = CountingWorkoutImageNormalizer()
        let recognizer = IndexRecordingWorkoutTextRecognizer()
        let parser = CompletingWorkoutImportJobParser(serverJobID: id.uuidString)
        let coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: normalizer,
            recognizer: recognizer,
            parser: parser,
            configuration: .init(pollingDelay: {})
        )

        let restored = try #require(await coordinator.restoreLatest(
            catalog: ExerciseCatalog.definitions,
            progress: { _ in }
        ))

        #expect(restored.stage == .reviewing)
        #expect(restored.pages.map(\.stage) == [.recognized, .recognized, .recognized])
        #expect(await normalizer.callCount() == 1)
        #expect(await recognizer.recognizedIndexes() == [0, 1])
        #expect(await parser.startCallCount() == 1)
    }

    @Test func offlineCancellationIsRetriedFromAProtectedTombstone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportCancellationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let parser = RecoveringCancellationWorkoutImportParser()
        let coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser
        )
        let job = WorkoutImportJob(
            stage: .processingSections,
            expectedPageCount: 1,
            serverProgress: .init(
                serverJobID: "durable-server-job",
                status: "processing",
                completedSections: 0,
                totalSections: 1
            )
        )
        try await repository.create(job)

        await coordinator.cancel(job)

        #expect(try await repository.load(job.id) == nil)
        #expect(try await repository.pendingCancellations().map(\.jobID) == [job.id])
        #expect(await parser.cancelCallCount() == 1)

        await parser.makeCancellationAvailable()
        await coordinator.cleanup()

        #expect(try await repository.pendingCancellations().isEmpty)
        #expect(await parser.cancelCallCount() == 2)
    }

    @Test func cancellationDeletesLocalSourcesEvenWhenTheTombstoneCannotBeSaved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportCancellationWriteFailureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FailingCancellationSaveWorkoutImportRepository(root: root)
        let parser = RecoveringCancellationWorkoutImportParser()
        await parser.makeCancellationAvailable()
        let coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser
        )
        var job = WorkoutImportJob(
            stage: .processingSections,
            expectedPageCount: 1,
            serverProgress: .init(
                serverJobID: "write-failure-cancel-job",
                status: "processing",
                completedSections: 0,
                totalSections: 1
            )
        )
        try await repository.create(job)
        let filename = try await repository.writeSource(Data([1, 2, 3]), jobID: job.id, pageIndex: 0)
        job.pages = [WorkoutImportSourcePage(
            index: 0,
            sourceRelativeFilename: filename,
            relativeFilename: "",
            digest: "source",
            pixelWidth: 0,
            pixelHeight: 0,
            stage: .sourceStored
        )]
        try await repository.save(job)
        let jobFolder = root.appending(path: job.id.uuidString, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: jobFolder.path))

        await coordinator.cancel(job)

        #expect(try await repository.load(job.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: jobFolder.path))
        #expect(await parser.cancelCallCount() == 1)
        #expect(try await repository.pendingCancellations().isEmpty)
    }

    @Test func relaunchCancellationRecoveryDeletesTheCheckpointBeforeClearingTheTombstone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportCancelRelaunchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let job = WorkoutImportJob(
            stage: .processingSections,
            expectedPageCount: 1,
            serverProgress: .init(
                serverJobID: "cancelled-before-process-death",
                status: "processing",
                completedSections: 0,
                totalSections: 1
            )
        )
        try await repository.create(job)
        try await repository.saveCancellation(.init(
            jobID: job.id,
            serverJobID: "cancelled-before-process-death",
            requestID: UUID(),
            createdAt: Date()
        ))
        let parser = RecoveringCancellationWorkoutImportParser()
        await parser.makeCancellationAvailable()
        let relaunched = WorkoutImportCoordinator(
            repository: repository,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser
        )

        let restored = await relaunched.restoreLatest(
            catalog: ExerciseCatalog.definitions,
            progress: { _ in }
        )

        #expect(restored == nil)
        #expect(try await repository.load(job.id) == nil)
        #expect(try await repository.pendingCancellations().isEmpty)
        #expect(await parser.cancelCallCount() == 1)
    }

    @Test func restorePersistsFailureWhenEveryRecognizedPageHasNoText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportEmptyRestoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        var page = sourcePage(index: 0, observations: [])
        page.stage = .noText
        page.failureCode = "no_text"
        let job = WorkoutImportJob(
            stage: .recognizingText,
            expectedPageCount: 1,
            pages: [page]
        )
        try await repository.create(job)
        let parser = CompletingWorkoutImportJobParser(serverJobID: "unused")
        let coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: EmptyWorkoutTextRecognizer(),
            parser: parser
        )

        let restored = try #require(await coordinator.restoreLatest(
            catalog: ExerciseCatalog.definitions,
            progress: { _ in }
        ))

        #expect(restored.stage == .failed)
        #expect(restored.failure?.reasonCode == "no_text")
        #expect(await parser.startCallCount() == 0)
        let persisted = try #require(try await repository.load(job.id))
        #expect(persisted.stage == .failed)
        #expect(persisted.failure?.reasonCode == "no_text")
    }

    @Test @MainActor
    func backgroundDuringLocalPreparationKeepsInProcessWorkAlive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportBackgroundTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let gate = WorkoutImportImageLoadGate()
        let model = WorkoutImportViewModel(
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            jobParser: CompletingWorkoutImportJobParser(serverJobID: "background-job"),
            repository: repository,
            coordinatorConfiguration: .init(pollingDelay: {})
        )

        let work = model.importImages(count: 1, catalog: ExerciseCatalog.definitions) { _ in
            await gate.load()
        }
        await gate.waitUntilLoadStarts()
        #expect(await gate.isWaiting)

        model.suspendForBackground()
        await gate.release()
        await work.value

        #expect(model.session.status == .reviewing)
        _ = await model.cancel().value
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func ocrConcurrencyIsBoundedAtTwoAndSourceOrderIsStable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportConcurrencyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let recognizer = ConcurrencyTrackingWorkoutTextRecognizer()
        let parser = RecordingWorkoutParser()
        let coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: recognizer,
            parser: LegacyWorkoutImportJobParser(parser: parser)
        )

        let result = await coordinator.start(
            imageCount: 4,
            catalog: ExerciseCatalog.definitions,
            loadImage: { Data([UInt8($0 + 1)]) },
            progress: { _ in }
        )

        #expect(await recognizer.highWaterMark() == 2)
        #expect(result.pages.map(\.index) == [0, 1, 2, 3])
        #expect(result.pages.flatMap(\.observations).map(\.sourceImageIndex) == [0, 1, 2, 3])
        #expect(result.stage == .reviewing)
        await coordinator.cancel(result)
    }

    @Test @MainActor
    func everyUnreadablePageFailsLocallyWithoutStartingAJob() async {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportEmptyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileWorkoutImportJobRepository(root: root)
        let parser = CompletingWorkoutImportJobParser(serverJobID: "unused")
        let coordinator = WorkoutImportCoordinator(
            repository: repository,
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: EmptyWorkoutTextRecognizer(),
            parser: parser
        )

        let result = await coordinator.start(
            imageCount: 2,
            catalog: ExerciseCatalog.definitions,
            loadImage: { Data([UInt8($0 + 1)]) },
            progress: { _ in }
        )

        #expect(result.stage == .failed)
        #expect(result.failure?.reasonCode == "no_text")
        #expect(result.pages.map(\.stage) == [.noText, .noText])
        #expect(await parser.startCallCount() == 0)
        await coordinator.cancel(result)
    }

    private func observation(
        _ id: String,
        _ text: String,
        page: Int,
        y: Double = 0.5
    ) -> WorkoutTextObservation {
        WorkoutTextObservation(
            id: id,
            text: text,
            confidence: 0.98,
            boundingBox: .init(x: 0.1, y: y, width: 0.8, height: 0.04),
            sourceImageIndex: page
        )
    }

    private func sourcePage(index: Int, observations: [WorkoutTextObservation]) -> WorkoutImportSourcePage {
        WorkoutImportSourcePage(
            index: index,
            relativeFilename: "pages/\(index).jpg",
            digest: WorkoutImportStableIdentity.digest(["page", String(index)]),
            pixelWidth: 100,
            pixelHeight: 200,
            stage: .recognized,
            observations: observations
        )
    }
}

private actor CompletingWorkoutImportJobParser: WorkoutImportJobParsing {
    private let serverJobID: String
    private var starts = 0
    private var statuses = 0
    private var request: WorkoutImportRemoteStartRequest?

    init(serverJobID: String) {
        self.serverJobID = serverJobID
    }

    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus {
        starts += 1
        self.request = request
        return completedStatus(serverJobID: request.clientJobID, sectionCount: request.sections.count)
    }

    func status(serverJobID: String) async throws -> WorkoutImportRemoteStatus {
        statuses += 1
        return completedStatus(serverJobID: serverJobID, sectionCount: 1)
    }

    func retry(serverJobID: String, requestID: UUID) async throws -> WorkoutImportRemoteStatus {
        completedStatus(serverJobID: serverJobID, sectionCount: 1)
    }

    func cancel(serverJobID: String, requestID: UUID) async throws {}

    func startCallCount() -> Int { starts }
    func statusCallCount() -> Int { statuses }
    func receivedRequest() -> WorkoutImportRemoteStartRequest? { request }

    private func completedStatus(serverJobID: String, sectionCount: Int) -> WorkoutImportRemoteStatus {
        WorkoutImportRemoteStatus(
            serverJobID: serverJobID,
            state: .completed,
            completedSections: sectionCount,
            totalSections: sectionCount,
            document: .init(
                title: "Imported",
                blocks: [.init(name: "Main", exercises: [.init(name: "Run", sets: [])])]
            ),
            model: "test"
        )
    }
}

private actor FixedStatusWorkoutImportJobParser: WorkoutImportJobParsing {
    private let state: WorkoutImportRemoteJobState
    private var statusCalls = 0

    init(state: WorkoutImportRemoteJobState) {
        self.state = state
    }

    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func status(serverJobID: String) async throws -> WorkoutImportRemoteStatus {
        statusCalls += 1
        return WorkoutImportRemoteStatus(
            serverJobID: serverJobID,
            state: state,
            completedSections: state == .queued ? 0 : 1,
            totalSections: 1,
            failureCode: state == .failed ? "section_failed" : nil
        )
    }

    func retry(serverJobID: String, requestID: UUID) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func cancel(serverJobID: String, requestID: UUID) async throws {}

    func statusCallCount() -> Int { statusCalls }
}

private actor GatedStatusWorkoutImportJobParser: WorkoutImportJobParsing {
    private let state: WorkoutImportRemoteJobState
    private var statusStarted = false
    private var statusContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellations = 0

    init(state: WorkoutImportRemoteJobState = .completed) {
        self.state = state
    }

    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func status(serverJobID: String) async throws -> WorkoutImportRemoteStatus {
        statusStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { statusContinuation = $0 }
        return WorkoutImportRemoteStatus(
            serverJobID: serverJobID,
            state: state,
            completedSections: state == .queued ? 0 : 1,
            totalSections: 1,
            document: state == .completed
                ? ParsedWorkoutDocument(
                    title: "Late server result",
                    blocks: [.init(name: "Main", exercises: [.init(name: "Deadlift", sets: [])])]
                )
                : nil,
            model: state == .completed ? "test" : nil,
            failureCode: state == .failed ? "section_failed" : nil
        )
    }

    func retry(serverJobID: String, requestID: UUID) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func cancel(serverJobID: String, requestID: UUID) async throws {
        cancellations += 1
    }

    func waitUntilStatusStarts() async {
        guard !statusStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseStatus() {
        statusContinuation?.resume()
        statusContinuation = nil
    }

    func cancelCallCount() -> Int { cancellations }
}

private actor CancellingRetryWorkoutImportParser: WorkoutImportJobParsing {
    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func status(serverJobID: String) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func retry(serverJobID: String, requestID: UUID) async throws -> WorkoutImportRemoteStatus {
        throw CancellationError()
    }

    func cancel(serverJobID: String, requestID: UUID) async throws {}
}

private actor TerminalRetryWorkoutImportParser: WorkoutImportJobParsing {
    private let state: WorkoutImportRemoteJobState
    private let failureCode: String?
    private var statusCalls = 0

    init(state: WorkoutImportRemoteJobState, failureCode: String? = nil) {
        self.state = state
        self.failureCode = failureCode
    }

    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func status(serverJobID: String) async throws -> WorkoutImportRemoteStatus {
        statusCalls += 1
        throw WorkoutParserError.remoteFailure
    }

    func retry(serverJobID: String, requestID: UUID) async throws -> WorkoutImportRemoteStatus {
        WorkoutImportRemoteStatus(
            serverJobID: serverJobID,
            state: state,
            completedSections: 0,
            totalSections: 1,
            failureCode: failureCode
        )
    }

    func cancel(serverJobID: String, requestID: UUID) async throws {}

    func statusCallCount() -> Int { statusCalls }
}

private actor GatedFailingRetryWorkoutImportParser: WorkoutImportJobParsing {
    private var calls = 0
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func status(serverJobID: String) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func retry(serverJobID: String, requestID: UUID) async throws -> WorkoutImportRemoteStatus {
        calls += 1
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        throw WorkoutParserError.remoteFailure
    }

    func cancel(serverJobID: String, requestID: UUID) async throws {}

    func waitUntilRetryStarts() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func releaseRetry() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func retryCallCount() -> Int { calls }
}

private actor ConcurrencyTrackingWorkoutTextRecognizer: WorkoutTextRecognizing {
    private var active = 0
    private var highWater = 0
    private var reachedTwo = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recognize(
        image: ImportedWorkoutImage,
        sourceImageIndex: Int,
        customWords: [String]
    ) async throws -> [WorkoutTextObservation] {
        active += 1
        highWater = max(highWater, active)
        if !reachedTwo {
            if active == 2 {
                reachedTwo = true
                let pending = waiters
                waiters.removeAll()
                pending.forEach { $0.resume() }
            } else {
                await withCheckedContinuation { waiters.append($0) }
            }
        }
        active -= 1
        return [WorkoutTextObservation(
            id: "page-\(sourceImageIndex)",
            text: "Page \(sourceImageIndex + 1)",
            confidence: 1,
            boundingBox: .init(x: 0.1, y: 0.5, width: 0.8, height: 0.05),
            sourceImageIndex: sourceImageIndex
        )]
    }

    func highWaterMark() -> Int { highWater }
}

private actor CountingPreparedWorkoutTextRecognizer: WorkoutTextRecognizing {
    private var calls = 0

    func recognize(
        image: ImportedWorkoutImage,
        sourceImageIndex: Int,
        customWords: [String]
    ) async throws -> [WorkoutTextObservation] {
        calls += 1
        return [WorkoutTextObservation(
            id: "prepared-\(sourceImageIndex)",
            text: "Page \(sourceImageIndex + 1)",
            confidence: 1,
            boundingBox: .init(x: 0.1, y: 0.5, width: 0.8, height: 0.05),
            sourceImageIndex: sourceImageIndex
        )]
    }

    func callCount() -> Int { calls }
}

private actor CountingWorkoutImageNormalizer: WorkoutImageNormalizing {
    private var calls = 0

    func normalize(_ data: Data) async throws -> ImportedWorkoutImage {
        calls += 1
        return ImportedWorkoutImage(data: data, pixelWidth: 10, pixelHeight: 20)
    }

    func callCount() -> Int { calls }
}

private actor IndexRecordingWorkoutTextRecognizer: WorkoutTextRecognizing {
    private var indexes: [Int] = []

    func recognize(
        image: ImportedWorkoutImage,
        sourceImageIndex: Int,
        customWords: [String]
    ) async throws -> [WorkoutTextObservation] {
        indexes.append(sourceImageIndex)
        return [WorkoutTextObservation(
            id: "restored-\(sourceImageIndex)",
            text: "Page \(sourceImageIndex + 1)",
            confidence: 1,
            boundingBox: .init(x: 0.1, y: 0.5, width: 0.8, height: 0.05),
            sourceImageIndex: sourceImageIndex
        )]
    }

    func recognizedIndexes() -> [Int] { indexes.sorted() }
}

private actor RecoveringCancellationWorkoutImportParser: WorkoutImportJobParsing {
    private var cancellationAvailable = false
    private var cancellations = 0

    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func status(serverJobID: String) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func retry(serverJobID: String, requestID: UUID) async throws -> WorkoutImportRemoteStatus {
        throw WorkoutParserError.remoteFailure
    }

    func cancel(serverJobID: String, requestID: UUID) async throws {
        cancellations += 1
        if !cancellationAvailable { throw WorkoutParserError.remoteFailure }
    }

    func makeCancellationAvailable() { cancellationAvailable = true }
    func cancelCallCount() -> Int { cancellations }
}

private struct EmptyWorkoutTextRecognizer: WorkoutTextRecognizing {
    func recognize(
        image: ImportedWorkoutImage,
        sourceImageIndex: Int,
        customWords: [String]
    ) async throws -> [WorkoutTextObservation] {
        throw WorkoutImagePipelineError.noText
    }
}

private actor WorkoutImportImageLoadGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async -> Data {
        isWaiting = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
        isWaiting = false
        return Data([1])
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilLoadStarts() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private actor GatedCreateWorkoutImportRepository: WorkoutImportJobStoring {
    private let base: FileWorkoutImportJobRepository
    private var createStarted = false
    private var createReleased = false
    private var createContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(root: URL) {
        base = FileWorkoutImportJobRepository(root: root)
    }

    func create(_ job: WorkoutImportJob) async throws {
        createStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !createReleased {
            await withCheckedContinuation { createContinuation = $0 }
        }
        try await base.create(job)
    }

    func waitUntilCreateStarts() async {
        guard !createStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseCreate() {
        createReleased = true
        createContinuation?.resume()
        createContinuation = nil
    }

    func load(_ id: UUID) async throws -> WorkoutImportJob? { try await base.load(id) }
    func mostRecentActiveJob(now: Date) async throws -> WorkoutImportJob? {
        try await base.mostRecentActiveJob(now: now)
    }
    func activeJobs(now: Date) async throws -> [WorkoutImportJob] {
        try await base.activeJobs(now: now)
    }
    func save(_ job: WorkoutImportJob) async throws { try await base.save(job) }
    func writeSource(_ data: Data, jobID: UUID, pageIndex: Int) async throws -> String {
        try await base.writeSource(data, jobID: jobID, pageIndex: pageIndex)
    }
    func writeImage(_ image: ImportedWorkoutImage, jobID: UUID, pageIndex: Int) async throws -> String {
        try await base.writeImage(image, jobID: jobID, pageIndex: pageIndex)
    }
    func imageData(jobID: UUID, relativeFilename: String) async throws -> Data {
        try await base.imageData(jobID: jobID, relativeFilename: relativeFilename)
    }
    func remove(_ id: UUID) async { await base.remove(id) }
    func removeExpired(now: Date) async { await base.removeExpired(now: now) }
    func saveCancellation(_ tombstone: WorkoutImportCancellationTombstone) async throws {
        try await base.saveCancellation(tombstone)
    }
    func pendingCancellations() async throws -> [WorkoutImportCancellationTombstone] {
        try await base.pendingCancellations()
    }
    func removeCancellation(_ id: UUID) async { await base.removeCancellation(id) }
}

private actor FailingCancellationSaveWorkoutImportRepository: WorkoutImportJobStoring {
    private let base: FileWorkoutImportJobRepository

    init(root: URL) {
        base = FileWorkoutImportJobRepository(root: root)
    }

    func create(_ job: WorkoutImportJob) async throws { try await base.create(job) }
    func load(_ id: UUID) async throws -> WorkoutImportJob? { try await base.load(id) }
    func mostRecentActiveJob(now: Date) async throws -> WorkoutImportJob? {
        try await base.mostRecentActiveJob(now: now)
    }
    func activeJobs(now: Date) async throws -> [WorkoutImportJob] {
        try await base.activeJobs(now: now)
    }
    func save(_ job: WorkoutImportJob) async throws { try await base.save(job) }
    func writeSource(_ data: Data, jobID: UUID, pageIndex: Int) async throws -> String {
        try await base.writeSource(data, jobID: jobID, pageIndex: pageIndex)
    }
    func writeImage(_ image: ImportedWorkoutImage, jobID: UUID, pageIndex: Int) async throws -> String {
        try await base.writeImage(image, jobID: jobID, pageIndex: pageIndex)
    }
    func imageData(jobID: UUID, relativeFilename: String) async throws -> Data {
        try await base.imageData(jobID: jobID, relativeFilename: relativeFilename)
    }
    func remove(_ id: UUID) async { await base.remove(id) }
    func removeExpired(now: Date) async { await base.removeExpired(now: now) }
    func saveCancellation(_ tombstone: WorkoutImportCancellationTombstone) async throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func pendingCancellations() async throws -> [WorkoutImportCancellationTombstone] {
        try await base.pendingCancellations()
    }
    func removeCancellation(_ id: UUID) async { await base.removeCancellation(id) }
}

private actor FailingReviewSaveWorkoutImportRepository: WorkoutImportJobStoring {
    private let base: FileWorkoutImportJobRepository
    private var savesAreAllowed = false

    init(root: URL) {
        base = FileWorkoutImportJobRepository(root: root)
    }

    func allowSaves() {
        savesAreAllowed = true
    }

    func create(_ job: WorkoutImportJob) async throws { try await base.create(job) }
    func load(_ id: UUID) async throws -> WorkoutImportJob? { try await base.load(id) }
    func mostRecentActiveJob(now: Date) async throws -> WorkoutImportJob? {
        try await base.mostRecentActiveJob(now: now)
    }
    func activeJobs(now: Date) async throws -> [WorkoutImportJob] {
        try await base.activeJobs(now: now)
    }
    func save(_ job: WorkoutImportJob) async throws {
        guard savesAreAllowed else { throw CocoaError(.fileWriteNoPermission) }
        try await base.save(job)
    }
    func writeSource(_ data: Data, jobID: UUID, pageIndex: Int) async throws -> String {
        try await base.writeSource(data, jobID: jobID, pageIndex: pageIndex)
    }
    func writeImage(_ image: ImportedWorkoutImage, jobID: UUID, pageIndex: Int) async throws -> String {
        try await base.writeImage(image, jobID: jobID, pageIndex: pageIndex)
    }
    func imageData(jobID: UUID, relativeFilename: String) async throws -> Data {
        try await base.imageData(jobID: jobID, relativeFilename: relativeFilename)
    }
    func remove(_ id: UUID) async { await base.remove(id) }
    func removeExpired(now: Date) async { await base.removeExpired(now: now) }
    func saveCancellation(_ tombstone: WorkoutImportCancellationTombstone) async throws {
        try await base.saveCancellation(tombstone)
    }
    func pendingCancellations() async throws -> [WorkoutImportCancellationTombstone] {
        try await base.pendingCancellations()
    }
    func removeCancellation(_ id: UUID) async { await base.removeCancellation(id) }
}

private struct PassthroughWorkoutImageNormalizer: WorkoutImageNormalizing {
    func normalize(_ data: Data) async throws -> ImportedWorkoutImage {
        ImportedWorkoutImage(data: data, pixelWidth: 1, pixelHeight: 1)
    }
}

private struct FailingSecondWorkoutImageNormalizer: WorkoutImageNormalizing {
    func normalize(_ data: Data) async throws -> ImportedWorkoutImage {
        if data.first == 2 { throw WorkoutImagePipelineError.unreadable }
        return ImportedWorkoutImage(data: data, pixelWidth: 1, pixelHeight: 1)
    }
}

private struct IndexedWorkoutTextRecognizer: WorkoutTextRecognizing {
    func recognize(image: ImportedWorkoutImage, sourceImageIndex: Int,
                   customWords: [String]) async throws -> [WorkoutTextObservation] {
        [WorkoutTextObservation(
            id: "page-\(sourceImageIndex)",
            text: "page-\(image.data.first ?? 0)",
            confidence: 1,
            boundingBox: .init(x: 0, y: 0, width: 1, height: 0.1),
            sourceImageIndex: sourceImageIndex
        )]
    }
}

private struct FailingSecondWorkoutTextRecognizer: WorkoutTextRecognizing {
    func recognize(image: ImportedWorkoutImage, sourceImageIndex: Int,
                   customWords: [String]) async throws -> [WorkoutTextObservation] {
        if sourceImageIndex == 1 { throw WorkoutImagePipelineError.noText }
        return try await IndexedWorkoutTextRecognizer().recognize(
            image: image,
            sourceImageIndex: sourceImageIndex,
            customWords: customWords
        )
    }
}

private actor GatedWorkoutTextRecognizer: WorkoutTextRecognizing {
    private var recognitionStarted = false
    private var recognitionReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func recognize(image: ImportedWorkoutImage, sourceImageIndex: Int,
                   customWords: [String]) async throws -> [WorkoutTextObservation] {
        recognitionStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !recognitionReleased {
            await withCheckedContinuation { continuation in releaseWaiters.append(continuation) }
        }
        return try await IndexedWorkoutTextRecognizer().recognize(
            image: image,
            sourceImageIndex: sourceImageIndex,
            customWords: customWords
        )
    }

    func waitUntilRecognitionStarts() async {
        guard !recognitionStarted else { return }
        await withCheckedContinuation { continuation in startWaiters.append(continuation) }
    }

    func releaseRecognition() {
        recognitionReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor GatedSecondImageLoader {
    private var secondLoadStarted = false
    private var secondLoadReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func load(_ index: Int) async -> Data {
        guard index == 1 else { return Data([1]) }
        secondLoadStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !secondLoadReleased {
            await withCheckedContinuation { continuation in releaseWaiter = continuation }
        }
        return Data([2])
    }

    func waitUntilSecondLoadStarts() async {
        guard !secondLoadStarted else { return }
        await withCheckedContinuation { continuation in startWaiters.append(continuation) }
    }

    func releaseSecondLoad() {
        secondLoadReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor SupersedingWorkoutImageNormalizer: WorkoutImageNormalizing {
    private var firstImportStarted = false
    private var firstImportReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func normalize(_ data: Data) async throws -> ImportedWorkoutImage {
        if data.first == 1 {
            firstImportStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }

            if !firstImportReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiter = continuation
                }
            }
        }
        return ImportedWorkoutImage(data: data, pixelWidth: 1, pixelHeight: 1)
    }

    func waitUntilFirstImportStarts() async {
        guard !firstImportStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstImport() {
        firstImportReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private final class RecordingWorkoutParser: WorkoutParsing {
    private(set) var received: [WorkoutTextObservation] = []
    private(set) var callCount = 0

    func parse(observations: [WorkoutTextObservation], catalogHints: [String]) async throws -> WorkoutParserResponse {
        callCount += 1
        received = observations
        return WorkoutParserResponse(
            document: .init(
                title: "Imported pages",
                blocks: [.init(name: "Main", exercises: [.init(name: "Run", sets: [])])]
            ),
            model: "test"
        )
    }
}

@MainActor
private struct FailingWorkoutParser: WorkoutParsing {
    func parse(observations: [WorkoutTextObservation], catalogHints: [String]) async throws -> WorkoutParserResponse {
        throw WorkoutParserError.remoteFailure
    }
}

@MainActor
private struct TimedOutWorkoutParser: WorkoutParsing {
    func parse(observations: [WorkoutTextObservation], catalogHints: [String]) async throws -> WorkoutParserResponse {
        throw WorkoutParserError.timedOut
    }
}

@MainActor
private final class LateSupersededWorkoutParser: WorkoutParsing {
    private var firstParseStarted = false
    private var firstParseReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func parse(observations: [WorkoutTextObservation], catalogHints: [String]) async throws -> WorkoutParserResponse {
        if observations.first?.text == "page-1" {
            firstParseStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !firstParseReleased {
                await withCheckedContinuation { continuation in releaseWaiter = continuation }
            }
            return response(title: "Superseded import", model: "stale-model")
        }
        return response(title: "Current import", model: "current-model")
    }

    func waitUntilFirstParseStarts() async {
        guard !firstParseStarted else { return }
        await withCheckedContinuation { continuation in startWaiters.append(continuation) }
    }

    func releaseFirstParse() {
        firstParseReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    private func response(title: String, model: String) -> WorkoutParserResponse {
        WorkoutParserResponse(
            document: .init(
                title: title,
                blocks: [.init(name: "Main", exercises: [.init(name: "Run", sets: [])])]
            ),
            model: model
        )
    }
}

private func temporaryImportFolder(_ sessionID: UUID) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: FileWorkoutImportJobRepository.folderName, directoryHint: .isDirectory)
        .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
}

@Suite("Workout import persistence")
@MainActor
struct WorkoutImportPersistenceTests {
    @Test func confirmedImportIsAnOrdinaryTemplateAndCanBeScheduled() throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(for: Schema(models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let plan = PlanStore(repo: SwiftDataPlanRepository(context: container.mainContext))
        _ = plan.addProgram(Program(name: "Baseline", createdAt: Date()))
        let workout = Workout(title: "Imported strength", blocks: [
            WorkoutBlock(name: "", exercises: [PlannedExercise(exerciseName: "Deadlift", definitionId: "deadlift")], isDefault: true),
        ])

        let template = try plan.saveImportedTemplate(name: workout.title, workout: workout)
        #expect(plan.templateWorkout(template.id)?.title == "Imported strength")
        #expect(plan.templates(matchingFingerprintOf: workout).map(\.id).contains(template.id))
        let scheduled = try #require(plan.instantiateTemplate(template.id, on: Date()))
        #expect(scheduled.templateID == template.id)
        #expect(scheduled.workout.title == "Imported strength")
    }
}
