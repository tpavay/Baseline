import Foundation
import Testing
@testable import Baseline

/// Retrieval behaviour of the catalog search - the pure half, run against the real bundled catalog so
/// the assertions reflect what the assistant actually gets back rather than a hand-made fixture.
struct ExerciseSearchTests {

    private var snapshot: ExerciseCatalogSnapshot { ExerciseCatalogSnapshot(ExerciseCatalog.seedDefinitions) }

    private func search(
        text: String? = nil, muscle: String? = nil, equipment: String? = nil, modality: String? = nil,
        pattern: String? = nil, tag: String? = nil, level: String? = nil
    ) throws -> ExerciseSearch.Results {
        let parsed = ExerciseSearch.parse(text: text, muscle: muscle, equipment: equipment,
                                          modality: modality, pattern: pattern, tag: tag, level: level)
        let query = try parsed.get()
        return ExerciseSearch.run(query, in: snapshot)
    }

    // MARK: - The bundled catalog is really there

    @Test func seedCatalogIsTheFullImportedLibrary() {
        // Guards the whole feature: a search tool over a catalog that failed to bundle is worthless.
        #expect(ExerciseCatalog.seedDefinitions.count > 800)
        #expect(ExerciseCatalog.seedDefinitions.allSatisfy { !$0.name.isEmpty })
    }

    // MARK: - Text query

    @Test func queryFindsTheBenchPressFamilyAndLeadsWithThePlainestName() throws {
        let r = try search(text: "bench")
        #expect(r.total > 1)
        let names = r.matches.map(\.name)
        #expect(names.contains("Bench Press"))
        // The canonical movement outranks "Barbell Guillotine Bench Press" et al.
        #expect(names.first == "Bench Press")
        #expect(names.allSatisfy { $0.localizedCaseInsensitiveContains("bench") })
    }

    @Test func queryMatchesAliasesAndPunctuationInsensitively() throws {
        // "hrpu" is an alias only - it appears in no exercise name.
        #expect(try search(text: "hrpu").matches.first?.id == "hand_release_push_up")
        #expect(try search(text: "air squat").matches.first?.id == "bodyweight_squat")
        // "push up" must reach "Push-Up" across the hyphen.
        #expect(try search(text: "push up").matches.contains { $0.id == "push_up" })
        #expect(try search(text: "PUSHUP").matches.contains { $0.id == "push_up" })
    }

    /// Only the ~50 curated built-ins carry aliases; the 873 imported entries have none, so casual
    /// names resolve for curated movements and imported ones must be found by their real name.
    @Test func importedExercisesAreFoundByNameSinceTheyCarryNoAliases() throws {
        let imported = try #require(ExerciseCatalog.seedDefinitions.first { $0.name == "Romanian Deadlift" })
        #expect(imported.aliases.isEmpty)
        #expect(try search(text: "romanian deadlift").matches.first?.id == imported.id)
        #expect(try search(text: "romanian").matches.contains { $0.id == imported.id })
    }

    @Test func exactNameOutranksMerelyContainingIt() throws {
        let r = try search(text: "deadlift")
        #expect(r.matches.first?.id == "deadlift")
        #expect(r.total > 1)   // the family (Romanian, sumo, …) still comes back
    }

    @Test func wordBoundaryMatchesOutrankIncidentalMidWordOnes() throws {
        // "Prowler", "Narrow", and "Throw" all contain r-o-w, so they do match "row" - mid-word hits are
        // deliberate, and the total counts them. But an exercise carrying "row" as an actual word ranks
        // above them, and there are enough of those to fill the page, so none of them reach it.
        let incidental = ["Prowler Sprint", "Narrow Stance Squats", "Backward Medicine Ball Throw"]
        // Without this the test would pass vacuously if the catalog ever stopped carrying them.
        #expect(incidental.allSatisfy { name in ExerciseCatalog.seedDefinitions.contains { $0.name == name } })

        let r = try search(text: "row")
        #expect(r.matches.first?.id == "row")                        // the exact name still wins outright
        #expect(r.matches.count == ExerciseSearch.resultLimit)
        #expect(r.matches.allSatisfy { !incidental.contains($0.name) })
        #expect(r.total > r.matches.count)                           // and the mid-word hits are in the total
    }

    @Test func singularAndPluralQueriesReachTheSameFamily() throws {
        // The catalog names one movement both ways, so neither spelling may strand the other half of the
        // family. Each direction fails differently without the trailing-"s" rule: "row" drops the plural
        // names to the substring tier, where 35 singular rows take every page slot ahead of them; "rows"
        // misses the singular names at every tier, so it answered with the plural-named handful and read
        // as the catalog holding nine rows.
        let singular = "Bent Over Barbell Row", plural = "Seated Cable Rows"
        #expect([singular, plural].allSatisfy { n in ExerciseCatalog.seedDefinitions.contains { $0.name == n } })

        for query in ["row", "rows"] {
            let names = try search(text: query).matches.map(\.name)
            #expect(try search(text: query).matches.first?.id == "row")   // the canonical row leads either way
            #expect(names.contains(singular))
            #expect(names.contains(plural))
        }
    }

    @Test func nonsenseQueryReturnsNothingRatherThanTheWholeCatalog() throws {
        let r = try search(text: "zzzznotamovement")
        #expect(r.matches.isEmpty)
        #expect(r.total == 0)
    }

    // MARK: - Filters

    @Test func muscleFilterReturnsOnlyExercisesTrainingThatMuscle() throws {
        let r = try search(muscle: "quadriceps")
        #expect(r.total > 10)
        #expect(r.matches.allSatisfy {
            $0.primaryMuscles.contains(.quadriceps) || $0.secondaryMuscles.contains(.quadriceps)
        })
        // Primary-quad movements lead, so the capped page shows the most relevant ones first.
        #expect(r.matches.first?.primaryMuscles.contains(.quadriceps) == true)
    }

    @Test func filtersCombineWithAnd() throws {
        let r = try search(muscle: "chest", equipment: "barbell")
        #expect(!r.matches.isEmpty)
        #expect(r.matches.allSatisfy {
            ($0.primaryMuscles.contains(.chest) || $0.secondaryMuscles.contains(.chest))
                && $0.equipment.contains(.barbell)
        })
    }

    @Test func textAndFilterCombine() throws {
        let r = try search(text: "squat", equipment: "barbell")
        #expect(!r.matches.isEmpty)
        #expect(r.matches.allSatisfy { $0.equipment.contains(.barbell) })
        #expect(r.matches.allSatisfy { $0.name.localizedCaseInsensitiveContains("squat") })
    }

    @Test func modalityPatternTagAndLevelFilter() throws {
        #expect(try search(modality: "cardio").matches.allSatisfy { $0.modality == .cardio })
        #expect(try search(pattern: "hinge").matches.allSatisfy { $0.patterns.contains(.hinge) })
        let hyrox = try search(tag: "hyrox")
        #expect(hyrox.total >= 5)
        #expect(hyrox.matches.allSatisfy { $0.tags.contains(.hyrox) })
        #expect(try search(level: "beginner").matches.allSatisfy { $0.level == .beginner })
    }

    // MARK: - Parsing tolerance

    @Test func filterValuesAcceptRawDisplaySlangAndCasing() throws {
        let expected = ExerciseSearch.Query(muscle: .frontDelts)
        for spelling in ["frontDelts", "front delts", "front_delts", "FRONTDELTS", "Front Delts"] {
            #expect(try ExerciseSearch.parse(muscle: spelling).get() == expected)
        }
        #expect(try ExerciseSearch.parse(muscle: "quads").get() == ExerciseSearch.Query(muscle: .quadriceps))
        #expect(try ExerciseSearch.parse(muscle: "abs").get() == ExerciseSearch.Query(muscle: .abdominals))
        #expect(try ExerciseSearch.parse(equipment: "db").get() == ExerciseSearch.Query(equipment: .dumbbell))
        #expect(try ExerciseSearch.parse(equipment: "pull-up bar").get() == ExerciseSearch.Query(equipment: .pullUpBar))
    }

    @Test func unknownFilterValueIsReportedNotIgnored() throws {
        // Silently dropping a bad filter would answer with the whole catalog and look like agreement.
        let result = ExerciseSearch.parse(muscle: "banana")
        switch result {
        case .success: Issue.record("expected an unknown-filter failure")
        case .failure(let bad):
            #expect(bad.field == "muscle")
            #expect(bad.value == "banana")
            #expect(bad.valid.contains("quadriceps"))
        }
    }

    @Test func blankAndMissingValuesAreTreatedAsAbsent() throws {
        #expect(try ExerciseSearch.parse(text: "  ", muscle: "").get() == ExerciseSearch.Query())
        #expect(try ExerciseSearch.parse().get().isEmpty)
    }

    // MARK: - Browse sample

    @Test func emptyQueryReturnsARepresentativeSampleSpanningTheLibrary() throws {
        let r = try search()
        #expect(r.isBrowseSample)
        #expect(r.matches.count == ExerciseSearch.resultLimit)
        #expect(r.total == ExerciseCatalog.seedDefinitions.count)
        #expect(r.truncated)
        // Representative means more than one kind of training - not the first 25 rows of the list.
        #expect(Set(r.matches.compactMap(\.modality)).count > 1)
        #expect(Set(r.matches.map(\.id)).count == r.matches.count)   // no duplicates
    }

    @Test func resultsAreCappedButTheTotalStaysHonest() throws {
        let r = try search(modality: "resistance")
        #expect(r.matches.count == ExerciseSearch.resultLimit)
        #expect(r.total > ExerciseSearch.resultLimit)
        #expect(r.truncated)
        #expect(!r.isBrowseSample)   // a filtered query is an answer, not a sample
    }

    @Test func searchIsDeterministic() throws {
        #expect(try search(text: "press").matches.map(\.id) == (try search(text: "press").matches.map(\.id)))
    }

    // MARK: - Single lookup

    @Test func lookUpByNameReturnsPopulatedDetail() throws {
        let d = try #require(ExerciseSearch.lookUp(name: "deadlift", id: nil, in: snapshot))
        #expect(d.id == "deadlift")
        #expect(!d.primaryMuscles.isEmpty)
        #expect(d.primaryMuscles.contains(.glutes))
        #expect(d.equipment.contains(.barbell))
        #expect(d.patterns.contains(.hinge))
        #expect(!d.supported.isEmpty)
    }

    @Test func lookUpAcceptsIDAliasAndCrossedParameters() throws {
        #expect(ExerciseSearch.lookUp(name: nil, id: "bench_press", in: snapshot)?.name == "Bench Press")
        #expect(ExerciseSearch.lookUp(name: "bench", id: nil, in: snapshot)?.id == "bench_press")   // alias
        // A model that puts a name in `id` (or an id in `name`) still gets the right answer.
        #expect(ExerciseSearch.lookUp(name: nil, id: "deadlift", in: snapshot)?.id == "deadlift")
        #expect(ExerciseSearch.lookUp(name: "bench_press", id: nil, in: snapshot)?.id == "bench_press")
    }

    @Test func lookUpMissReportsNilRatherThanTheGenericFallback() throws {
        // resolve() must still fall back for logging; find()/lookUp must not pretend a miss is a hit.
        #expect(ExerciseSearch.lookUp(name: "zzzznotamovement", id: nil, in: snapshot) == nil)
        #expect(snapshot.find("zzzznotamovement") == nil)
        #expect(snapshot.resolve("zzzznotamovement", generic: ExerciseCatalog.generic).id == "generic")
        #expect(ExerciseSearch.lookUp(name: nil, id: nil, in: snapshot) == nil)
    }
}
