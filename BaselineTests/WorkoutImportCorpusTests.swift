import Foundation
import Testing
@testable import Baseline

/// The import corpus: real workouts, each pinned to the structure conversion must produce from it.
///
/// The point of this file is that it never needs editing. Every case is a JSON document in
/// `fixtures/workout-import/corpus/`, discovered at run time, so adding a workout is: write the
/// file, run `xcodegen generate`, done. See that directory's README for the schema.
///
/// Cases are judged on **structure** — right exercises, right order, right grouping, and an honest
/// refusal to name what it could not place. A missing number is seconds of typing for the athlete;
/// a wrong skeleton wastes everything under it.
@Suite("Workout import corpus")
struct WorkoutImportCorpusTests {

    // MARK: - Case format

    private struct Case: Decodable {
        var name: String
        var source: String?
        var sketch: WorkoutImportSketch
        var expect: Expectation

        struct Expectation: Decodable {
            var title: String?
            var blocks: [String]?
            var exercises: [String]
            var groups: [Group]?
            var unresolved: [String]?
            /// Exercise index → number of sets.
            var setCounts: [String: Int]?
            /// Exercise index → canonical metric values every set must carry.
            var metrics: [String: [String: Double]]?
            /// Exercise index → coach text that must survive verbatim.
            var notesContain: [String: [String]]?

            struct Group: Decodable {
                var label: String
                var size: Int
            }
        }
    }

    private final class BundleToken {}

    private static func isNotAGroup(_ node: ParsedWorkoutNode) -> Bool {
        if case .group = node { return false }
        return true
    }

    private struct Discovery {
        var cases: [Case] = []
        /// Files that declare themselves corpus cases but would not decode. Reported, never skipped:
        /// a malformed case that quietly vanishes turns a shrinking corpus into a green suite.
        var malformed: [String] = []
    }

    private static let discovery: Discovery = {
        // Resources land flat in the bundle alongside other fixtures, so a case identifies itself by
        // carrying a "sketch" key rather than by where it sits.
        let urls = Bundle(for: BundleToken.self).urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        var discovery = Discovery()
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url),
                  let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  probe["sketch"] != nil else { continue }
            if let decoded = try? JSONDecoder().decode(Case.self, from: data) {
                discovery.cases.append(decoded)
            } else {
                discovery.malformed.append(url.lastPathComponent)
            }
        }
        return discovery
    }()

    private static var cases: [Case] { discovery.cases }

    // MARK: - The harness

    /// A passing suite that ran nothing is the most expensive kind of green, so the corpus proves it
    /// loaded before anything else asserts against it.
    @Test func everyCorpusFileIsDiscoveredAndWellFormed() {
        #expect(
            Self.discovery.malformed.isEmpty,
            "corpus files declare a sketch but do not match the case schema: \(Self.discovery.malformed)"
        )
        #expect(!Self.cases.isEmpty, "no corpus cases were found in the test bundle; run xcodegen generate")
    }

    @Test func everyCorpusWorkoutConvertsToTheExpectedStructure() throws {
        for testCase in Self.cases {
            let catalog = ExerciseCatalog.definitions
            let converted = WorkoutImportSketchConverter.convert(testCase.sketch, catalog: catalog)
            let document = converted.document
            let exercises = document.blocks.flatMap(\.exercises)
            let expect = testCase.expect
            let label = "[\(testCase.name)]"

            if let title = expect.title {
                #expect(document.title == title, "\(label) title")
            }
            if let blocks = expect.blocks {
                #expect(document.blocks.map(\.name) == blocks, "\(label) block names")
            }
            #expect(exercises.map(\.name) == expect.exercises, "\(label) exercises in document order")

            let groups = document.blocks.flatMap { $0.nodes }.compactMap { node -> ParsedWorkoutGroup? in
                if case .group(let group) = node { return group }
                return nil
            }
            if let expected = expect.groups {
                #expect(groups.map(\.label) == expected.map(\.label), "\(label) group labels")
                #expect(groups.map(\.children.count) == expected.map(\.size), "\(label) group sizes")
            }
            // Grouping is one level. Nothing inside a group may itself be a group.
            #expect(
                groups.allSatisfy { $0.children.allSatisfy(Self.isNotAGroup) },
                "\(label) grouping must stay one level deep"
            )

            if let unresolved = expect.unresolved {
                #expect(converted.unresolvedNames == unresolved, "\(label) names Baseline must not guess")
            }

            for (rawIndex, count) in expect.setCounts ?? [:] {
                let index = try #require(Int(rawIndex), "\(label) setCounts key \(rawIndex)")
                let exercise = try #require(exercises[safe: index], "\(label) no exercise at \(index)")
                #expect(exercise.sets.count == count, "\(label) \(exercise.name) set count")
            }

            for (rawIndex, expected) in expect.metrics ?? [:] {
                let index = try #require(Int(rawIndex), "\(label) metrics key \(rawIndex)")
                let exercise = try #require(exercises[safe: index], "\(label) no exercise at \(index)")
                for (metric, value) in expected {
                    #expect(
                        exercise.sets.allSatisfy { set in
                            set.metrics.contains { $0.type == metric && $0.value == value }
                        },
                        "\(label) \(exercise.name) every set carries \(metric) = \(value) (canonical)"
                    )
                }
                // Canonical storage: the source's own units never travel into the document.
                #expect(
                    exercise.sets.allSatisfy { set in
                        set.metrics.allSatisfy { metric in
                            MetricType(rawValue: metric.type).map { $0.canonicalUnit.rawValue == metric.unit } ?? false
                        }
                    },
                    "\(label) \(exercise.name) metrics must be stored in canonical units"
                )
            }

            for (rawIndex, expected) in expect.notesContain ?? [:] {
                let index = try #require(Int(rawIndex), "\(label) notesContain key \(rawIndex)")
                let exercise = try #require(exercises[safe: index], "\(label) no exercise at \(index)")
                for note in expected {
                    #expect(
                        exercise.notes.contains { $0.contains(note) },
                        "\(label) \(exercise.name) must keep coach text “\(note)”; kept \(exercise.notes)"
                    )
                }
            }
        }
    }

    /// Whatever a case pins, the document it produces has to survive the one bridge into native
    /// training data — otherwise the structure above is a shape nothing can be logged against.
    @Test func everyCorpusWorkoutBuildsANativeDraftPreservingItsExercisesAndOrder() throws {
        for testCase in Self.cases {
            let catalog = ExerciseCatalog.definitions
            let converted = WorkoutImportSketchConverter.convert(testCase.sketch, catalog: catalog)
            let built = WorkoutImportDraftBuilder.build(converted.document, catalog: catalog)
            let label = "[\(testCase.name)]"

            #expect(
                built.draft.workout.allExercises.map(\.exerciseName) == testCase.expect.exercises,
                "\(label) native draft must keep every exercise in order"
            )
            // The source's units never become a per-instance display override; the athlete's
            // AppSettings.unitSystem decides display, through WorkoutStore.displayUnit(_:for:).
            #expect(
                built.draft.workout.allExercises.allSatisfy { $0.displayUnits.isEmpty },
                "\(label) an imported exercise must not carry a display-unit override from its source"
            )
            // Only names Baseline honestly refused to place may block saving.
            let blockedNames = Set(
                built.issues
                    .filter { $0.code == .unknownExercise }
                    .compactMap { issue in
                        built.draft.workout.allExercises.first { $0.id == issue.exerciseID }?.exerciseName
                    }
            )
            #expect(
                blockedNames == Set(converted.unresolvedNames),
                "\(label) blocking unknown-exercise issues must match the unresolved names exactly"
            )
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
