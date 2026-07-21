import Foundation
import Testing
@testable import Baseline

/// The conversion layer: text comprehension → structured, loggable Baseline training.
///
/// This is the half of import that must be deterministic, so it is the half that gets tested
/// exhaustively. The model's job is comprehension; everything asserted here is ordinary code.
@Suite("Workout import conversion")
struct WorkoutImportConversionTests {

    private var catalog: [ExerciseDefinition] { ExerciseCatalog.definitions }
    private var snapshot: ExerciseCatalogSnapshot { ExerciseCatalogSnapshot(catalog) }

    private func isExercise(_ node: ParsedWorkoutNode) -> Bool {
        if case .exercise = node { return true }
        return false
    }

    // MARK: - Quantities are canonical, never the source's units

    @Test func distancesBecomeCanonicalMetresWhateverTheSourceWroteThemIn() {
        #expect(ImportQuantityParser.quantities(in: "400m") == [.init(metric: .distance, canonicalValue: 400)])
        #expect(ImportQuantityParser.quantities(in: "2km") == [.init(metric: .distance, canonicalValue: 2_000)])
        #expect(ImportQuantityParser.quantities(in: "12.5m") == [.init(metric: .distance, canonicalValue: 12.5)])

        let mile = try! #require(ImportQuantityParser.quantities(in: "1 mile").first)
        #expect(abs(mile.canonicalValue - MetricConvert.metersPerMile) < 0.001)
        let yards = try! #require(ImportQuantityParser.quantities(in: "100 yards").first)
        #expect(abs(yards.canonicalValue - 91.44) < 0.001)
    }

    @Test func loadsBecomeCanonicalKilogramsWhateverTheSourceWroteThemIn() {
        #expect(ImportQuantityParser.quantities(in: "60kg") == [.init(metric: .load, canonicalValue: 60)])
        let pounds = try! #require(ImportQuantityParser.quantities(in: "135 lbs").first)
        #expect(pounds.metric == .load)
        #expect(abs(pounds.canonicalValue - (135 * MetricConvert.kgPerPound)) < 0.0001)
    }

    @Test func durationsBecomeCanonicalSecondsIncludingClockNotation() {
        #expect(ImportQuantityParser.quantities(in: "20 sec") == [.init(metric: .duration, canonicalValue: 20)])
        #expect(ImportQuantityParser.quantities(in: "4 min") == [.init(metric: .duration, canonicalValue: 240)])
        #expect(ImportQuantityParser.quantities(in: "40 secs rest") == [.init(metric: .duration, canonicalValue: 40)])
        #expect(ImportQuantityParser.quantities(in: "1:30") == [.init(metric: .duration, canonicalValue: 90)])
    }

    /// "400m" must not be read as "40 minutes", and "5 min" must not be read as "5 miles".
    @Test func unitTokensDoNotBleedIntoOneAnother() {
        #expect(ImportQuantityParser.quantities(in: "400m") == [.init(metric: .distance, canonicalValue: 400)])
        #expect(ImportQuantityParser.quantities(in: "5 min") == [.init(metric: .duration, canonicalValue: 300)])
        #expect(ImportQuantityParser.quantities(in: "5 mi").first?.metric == .distance)
        #expect(ImportQuantityParser.quantities(in: "20 cal") == [.init(metric: .calories, canonicalValue: 20)])
    }

    // MARK: - Ranges and effort targets stay coach text

    @Test(arguments: [
        "6-8 reps", "8-12 reps", "3-5km pace", "7RPE", "8/9 RPE", "10 to 12 reps",
        "AMRAP", "Max unbroken set of wall balls", "As Prescribed", "2 reps in reserve",
    ])
    func rangesPacesAndEffortTargetsAreNeverTurnedIntoNumbers(text: String) {
        #expect(ImportQuantityParser.isCoachText(text))
        #expect(ImportQuantityParser.quantities(in: text).isEmpty)
        #expect(ImportSetCountParser.setCount(in: text) == nil)
    }

    /// A compound prescription states one metric several times. Collapsing "12.5m / 12.5m / 12.5m"
    /// to a single 12.5 m set would silently discard two thirds of the work.
    @Test func aMetricStatedMoreThanOnceStaysProse() {
        let compound = "12.5m Sled Push / 12.5m sled drag / 12.5m sled push"
        #expect(ImportQuantityParser.quantities(in: compound).isEmpty)
    }

    // MARK: - Set counts

    @Test func setCountsAreExpandedOnlyWhenTheSourceSettlesThem() {
        #expect(ImportSetCountParser.setCount(in: "15 x") == 15)
        #expect(ImportSetCountParser.setCount(in: "3") == 3)
        #expect(ImportSetCountParser.setCount(in: "3 working sets") == 3)
        #expect(ImportSetCountParser.setCount(in: "4 rounds") == 4)
        // A duration window is not a set count.
        #expect(ImportSetCountParser.setCount(in: "4 min") == nil)
        // Reps are not sets.
        #expect(ImportSetCountParser.setCount(in: "8 reps") == nil)
        #expect(ImportSetCountParser.setCount(in: nil) == nil)
    }

    @Test func animplausibleSetCountIsRefusedRatherThanBuiltIntoHundredsOfRows() {
        #expect(ImportSetCountParser.setCount(in: "\(ImportSetCountParser.maximumSets) x") == ImportSetCountParser.maximumSets)
        #expect(ImportSetCountParser.setCount(in: "\(ImportSetCountParser.maximumSets + 1) x") == nil)
        #expect(ImportSetCountParser.setCount(in: "400 x") == nil)
    }

    // MARK: - Exercise matching surfaces near-misses instead of resolving them

    @Test func exactNamesAndCasualAliasesResolveConfidently() {
        let run = ImportExerciseMatcher.match("Run", in: catalog, snapshot: snapshot)
        #expect(run.confidence == .exact)
        #expect(run.definition?.id == "run")

        let strides = ImportExerciseMatcher.match("Strides", in: catalog, snapshot: snapshot)
        #expect(strides.confidence == .exact)
        #expect(strides.definition?.id == "run")

        let echo = ImportExerciseMatcher.match("Assault Bike", in: catalog, snapshot: snapshot)
        #expect(echo.confidence == .exact)
        #expect(echo.definition?.id == "echo_bike")
    }

    /// The captain's own example. A confident wrong match is worse than an honest unknown, because
    /// every set logged against it lands on another movement's history with no signal that anything
    /// was decided. The catalog has no plain "Sled Drag", and the neighbours it does have either add
    /// a qualifier the source never said or are a different movement entirely.
    @Test func sledDragIsSurfacedAsUncertainAndNeverBecomesSledPush() throws {
        let match = ImportExerciseMatcher.match("Sled Drag", in: catalog, snapshot: snapshot)

        #expect(match.confidence == .uncertain)
        #expect(match.definition == nil)

        // And it survives conversion as an honest unknown: the source's own words, reported as
        // unresolved, so the draft builder raises its blocking question rather than anything
        // downstream quietly settling on a different movement.
        let sketch = WorkoutImportSketch(blocks: [.init(items: [.init(name: "Sled Drag", prescription: "12.5m")])])
        let converted = WorkoutImportSketchConverter.convert(sketch, catalog: catalog)
        let exercise = try #require(converted.document.blocks.first?.exercises.first)

        #expect(exercise.name == "Sled Drag")
        #expect(converted.unresolvedNames == ["Sled Drag"])
        #expect(!catalog.contains { $0.id == "sled_push" && $0.name == exercise.name })
    }

    /// A qualifier the source *did* say is not thrown away to reach a shorter catalog name.
    @Test func aQualifierTheSourceStatedIsNotDiscardedToReachAMatch() {
        let match = ImportExerciseMatcher.match("Kettlebell Farmers Walk", in: catalog, snapshot: snapshot)

        #expect(match.confidence == .uncertain)
        #expect(match.definition == nil)
    }

    /// The widening that *is* allowed: the same movement spelled differently. Singular versus
    /// plural is spelling, not a different exercise.
    @Test func aPluralSpellingOfTheSameMovementStillResolves() {
        let plural = ImportExerciseMatcher.match("Box Jumps", in: catalog, snapshot: snapshot)
        #expect(plural.definition?.id == "box_jump")
    }

    @Test func anUnknownMovementResolvesToNothingAndOffersCandidates() {
        let match = ImportExerciseMatcher.match("Zercher Sandbag Yoke Carry Thing", in: catalog, snapshot: snapshot)
        #expect(match.confidence == .uncertain)
        #expect(match.definition == nil)
    }

    @Test func anEmptyNameIsUncertainRatherThanMatchingTheFirstDefinition() {
        let match = ImportExerciseMatcher.match("   ", in: catalog, snapshot: snapshot)
        #expect(match.confidence == .uncertain)
        #expect(match.definition == nil)
    }

    // MARK: - Conversion end to end

    /// The main set the shipped pipeline lost entirely: "A) 400s — 15 x — 400m effort — 40 secs rest".
    @Test func theVOTwoMainSetBecomesFifteenLoggableFourHundredMetreSets() throws {
        let sketch = WorkoutImportSketch(
            title: "AM: VO2 THRESHOLDS",
            blocks: [.init(name: "A) 400s", items: [
                .init(name: "Run", sets: "15", prescription: "400m", rest: "40 secs",
                      intensity: "3-5km pace, 8/9 RPE"),
            ])]
        )

        let converted = WorkoutImportSketchConverter.convert(sketch, catalog: catalog)
        let exercise = try #require(converted.document.blocks.first?.exercises.first)

        #expect(converted.document.title == "AM: VO2 THRESHOLDS")
        #expect(exercise.name == "Run")
        #expect(exercise.sets.count == 15)
        #expect(exercise.sets.allSatisfy {
            $0.metrics == [.init(type: "distance", value: 400, unit: "meters")]
        })
        #expect(exercise.restSeconds == 40)
        // Pace and RPE are coach text, kept verbatim rather than invented into a typed target.
        #expect(exercise.notes.contains("3-5km pace, 8/9 RPE"))
        #expect(exercise.intensityTargets.isEmpty)
        #expect(converted.unresolvedNames.isEmpty)
    }

    @Test func theWholeConvertedDocumentBuildsANativeDraftWithoutBlockingIssues() throws {
        let sketch = WorkoutImportSketch(
            title: "AM: VO2 THRESHOLDS",
            notes: ["Level 3: As Prescribed", "Level 2: 12 sets", "Level 1: 10 sets"],
            blocks: [
                .init(name: "Warmup", items: [
                    .init(name: "Run", prescription: "2km", note: "easy"),
                ]),
                .init(name: "A) 400s", items: [
                    .init(name: "Run", sets: "15", prescription: "400m", rest: "40 secs"),
                ]),
            ]
        )

        let converted = WorkoutImportSketchConverter.convert(sketch, catalog: catalog)
        let built = WorkoutImportDraftBuilder.build(converted.document, catalog: catalog)

        #expect(built.draft.workout.allExercises.count == 2)
        #expect(built.draft.workout.blocks.map(\.name) == ["Warmup", "A) 400s"])
        #expect(!built.issues.contains { $0.severity == .blocking })
        #expect(built.draft.workout.allExercises.allSatisfy { $0.definitionId == "run" })
    }

    /// Storage is canonical and display is a preference, so an imported workout must never carry a
    /// per-instance unit override taken from whatever the source happened to be written in.
    @Test func aKilometreSourceLeavesNoImperialOrMetricOverrideOnTheExercise() throws {
        let sketch = WorkoutImportSketch(blocks: [.init(items: [
            .init(name: "Run", prescription: "5km"),
        ])])

        let converted = WorkoutImportSketchConverter.convert(sketch, catalog: catalog)
        let built = WorkoutImportDraftBuilder.build(converted.document, catalog: catalog)
        let exercise = try #require(built.draft.workout.allExercises.first)

        #expect(exercise.prescription.sets.first?.values[.distance] == 5_000)
        #expect(exercise.displayUnits.isEmpty)
    }

    /// The rule end to end: a workout written in kilometres, imported by an athlete who has chosen
    /// Imperial, displays in miles — while the stored value stays the same canonical 5000 metres.
    @Test @MainActor func aMetricSourceDisplaysImperialToAnImperialAthlete() throws {
        let sketch = WorkoutImportSketch(blocks: [.init(items: [.init(name: "Run", prescription: "5km")])])
        let converted = WorkoutImportSketchConverter.convert(sketch, catalog: catalog)
        let built = WorkoutImportDraftBuilder.build(converted.document, catalog: catalog)
        let exercise = try #require(built.draft.workout.allExercises.first)

        let store = WorkoutStore(defaults: UserDefaults(suiteName: "import-units-\(UUID().uuidString)")!)
        store.unitSystem = .imperial
        #expect(store.displayUnit(.distance, for: exercise) == .miles)

        store.unitSystem = .metric
        #expect(store.displayUnit(.distance, for: exercise) == .kilometers)

        // The stored value never moved; only the lens over it did.
        #expect(exercise.prescription.sets.first?.values[.distance] == 5_000)
    }

    @Test func anUnresolvedNameBlocksSavingInsteadOfBecomingSomeOtherMovement() throws {
        let sketch = WorkoutImportSketch(blocks: [.init(items: [
            .init(name: "Zercher Sandbag Yoke Carry Thing", sets: "3", prescription: "50m"),
        ])])

        let converted = WorkoutImportSketchConverter.convert(sketch, catalog: catalog)
        let built = WorkoutImportDraftBuilder.build(converted.document, catalog: catalog)

        #expect(converted.unresolvedNames == ["Zercher Sandbag Yoke Carry Thing"])
        #expect(built.draft.workout.allExercises.first?.definitionId == nil)
        #expect(built.issues.contains { $0.code == .unknownExercise && $0.severity == .blocking })
    }

    // MARK: - Grouping is one level

    @Test func consecutiveItemsSharingAnOrdinalBecomeOneGroupAndStandalonesStayFlat() throws {
        let sketch = WorkoutImportSketch(blocks: [.init(name: "Main", items: [
            .init(group: "1", name: "Back Squat", sets: "3", prescription: "5 reps"),
            .init(group: "1", name: "Box Jump", sets: "3", prescription: "5 reps"),
            .init(name: "Sled Push", prescription: "50m"),
            .init(group: "2", name: "Bench Press", sets: "3", prescription: "8 reps"),
            .init(group: "2", name: "Pull Up", sets: "3", prescription: "8 reps"),
            .init(group: "2", name: "Plank", sets: "3", prescription: "60 sec"),
        ])])

        let nodes = try #require(WorkoutImportSketchConverter.convert(sketch, catalog: catalog).document.blocks.first?.nodes)

        #expect(nodes.count == 3)
        guard case .group(let first) = nodes[0] else { Issue.record("expected a group"); return }
        #expect(first.label == "1")
        #expect(first.children.count == 2)
        guard case .exercise = nodes[1] else { Issue.record("expected a standalone exercise"); return }
        guard case .group(let third) = nodes[2] else { Issue.record("expected a group"); return }
        #expect(third.label == "2")
        #expect(third.children.count == 3)
        // One level only: no group contains another group.
        #expect(nodes.flatMap(\.exercises).count == 6)
        #expect(first.children.allSatisfy(isExercise))
    }

    /// A lone ordinal has nothing to superset against, so it stays a plain exercise rather than a
    /// one-child group the editor would render as pointless nesting.
    @Test func aGroupOfOneStaysAStandaloneExercise() throws {
        let sketch = WorkoutImportSketch(blocks: [.init(items: [
            .init(group: "1", name: "Back Squat", sets: "3", prescription: "5 reps"),
            .init(group: "2", name: "Bench Press", sets: "3", prescription: "5 reps"),
        ])])

        let nodes = try #require(WorkoutImportSketchConverter.convert(sketch, catalog: catalog).document.blocks.first?.nodes)

        #expect(nodes.count == 2)
        #expect(nodes.allSatisfy(isExercise))
    }

    /// The run is two items but only one of them names a movement, so the surviving structure is one
    /// exercise. A superset container holding a single row — or none at all — is a shape the athlete
    /// never wrote and the editor should never render.
    @Test func aGroupWhoseSiblingHasNoNameCollapsesRatherThanRenderingAnEmptyContainer() throws {
        let sketch = WorkoutImportSketch(blocks: [.init(items: [
            .init(group: "1", name: "Back Squat", sets: "3", prescription: "5 reps"),
            .init(group: "1", name: "   ", sets: "3", prescription: "5 reps"),
            .init(group: "2", name: " ", prescription: "5 reps"),
            .init(group: "2", name: "", prescription: "5 reps"),
        ])])

        let nodes = try #require(WorkoutImportSketchConverter.convert(sketch, catalog: catalog).document.blocks.first?.nodes)

        #expect(nodes.count == 1)
        #expect(nodes.allSatisfy(isExercise))
    }

    // MARK: - Notes

    @Test func aQuantityThatBecameASetIsNotAlsoRepeatedAsANote() throws {
        let sketch = WorkoutImportSketch(blocks: [.init(items: [
            .init(name: "Run", sets: "15", prescription: "400m", rest: "40 secs"),
        ])])
        let exercise = try #require(
            WorkoutImportSketchConverter.convert(sketch, catalog: catalog).document.blocks.first?.exercises.first
        )
        #expect(!exercise.notes.contains("400m"))
        #expect(!exercise.notes.contains("40 secs"))
        #expect(!exercise.notes.contains("15"))
    }

    @Test func aPrescriptionCarryingWordsBeyondTheQuantityKeepsThoseWords() throws {
        let sketch = WorkoutImportSketch(blocks: [.init(items: [
            .init(name: "Run", prescription: "150m @ heavier than race weight"),
        ])])
        let exercise = try #require(
            WorkoutImportSketchConverter.convert(sketch, catalog: catalog).document.blocks.first?.exercises.first
        )
        #expect(exercise.notes.contains("150m @ heavier than race weight"))
    }

    @Test func aRangeSurvivesAsCoachTextAndLeavesItsSetsUnfilled() throws {
        let sketch = WorkoutImportSketch(blocks: [.init(items: [
            .init(name: "Bench Press", sets: "3", prescription: "6-8 reps",
                  note: "immediately into echo effort"),
        ])])
        let exercise = try #require(
            WorkoutImportSketchConverter.convert(sketch, catalog: catalog).document.blocks.first?.exercises.first
        )
        #expect(exercise.sets.count == 3)
        #expect(exercise.sets.allSatisfy { $0.metrics.isEmpty })
        #expect(exercise.notes.contains("6-8 reps"))
        #expect(exercise.notes.contains("immediately into echo effort"))
    }

    /// The metric set is decided per exercise, not applied uniformly: a distance read onto a bench
    /// press is a misread, and must not become a distance field the athlete has to delete.
    @Test func aMetricTheMovementDoesNotLogStaysProse() throws {
        let sketch = WorkoutImportSketch(blocks: [.init(items: [
            .init(name: "Bench Press", sets: "3", prescription: "400m"),
        ])])
        let exercise = try #require(
            WorkoutImportSketchConverter.convert(sketch, catalog: catalog).document.blocks.first?.exercises.first
        )
        #expect(exercise.sets.allSatisfy { $0.metrics.isEmpty })
        #expect(exercise.notes.contains("400m"))
    }

    @Test func anEmptySketchProducesAnEmptyDocumentRatherThanAPlaceholderWorkout() {
        let converted = WorkoutImportSketchConverter.convert(WorkoutImportSketch(), catalog: catalog)
        #expect(converted.document.blocks.isEmpty)
    }
}
