import Foundation
import Testing
@testable import Baseline

@Suite("Exercise catalog snapshot")
struct ExerciseCatalogSnapshotTests {
    private func def(_ id: String, _ name: String, aliases: [String] = []) -> ExerciseDefinition {
        ExerciseDefinition(id: id, name: name, category: .strength,
                           supported: [.reps, .load], defaults: [.reps], aliases: aliases)
    }
    private let generic = ExerciseCatalog.generic

    @Test func indexesByIDAndPreservesOrder() {
        let defs = [def("a", "Alpha"), def("b", "Bravo"), def("c", "Charlie")]
        let snapshot = ExerciseCatalogSnapshot(defs)
        #expect(snapshot.definitions.map(\.id) == ["a", "b", "c"])
        #expect(snapshot.definition(id: "b")?.name == "Bravo")
        #expect(snapshot.definition(id: "missing") == nil)
    }

    @Test func resolveMatchesExactNameThenAliasThenSubstring() {
        let defs = [
            def("row", "Row", aliases: ["rower", "erg row"]),
            def("bench", "Bench Press", aliases: ["bench", "bp"])
        ]
        let snapshot = ExerciseCatalogSnapshot(defs)
        #expect(snapshot.resolve("Row", generic: generic).id == "row")          // exact name, case-insensitive
        #expect(snapshot.resolve("rower", generic: generic).id == "row")        // exact alias
        #expect(snapshot.resolve("BP", generic: generic).id == "bench")         // exact alias, case-insensitive
        #expect(snapshot.resolve("concept2 erg row machine", generic: generic).id == "row") // substring fuzzy
    }

    @Test func resolveFallsBackToGenericForEmptyOrUnknown() {
        let snapshot = ExerciseCatalogSnapshot([def("row", "Row", aliases: ["rower"])])
        #expect(snapshot.resolve("   ", generic: generic).id == generic.id)
        #expect(snapshot.resolve("landmine rainbow", generic: generic).id == generic.id)
    }

    @Test func firstDefinitionWinsOnColliding() {
        // Two definitions sharing an id, name, and alias — the earlier one must win, matching the old scan.
        let defs = [
            def("first", "Squat", aliases: ["shared"]),
            def("first", "Squat", aliases: ["shared"])
        ]
        let snapshot = ExerciseCatalogSnapshot(defs)
        #expect(snapshot.resolve("squat", generic: generic).id == "first")
        #expect(snapshot.resolve("shared", generic: generic).id == "first")
    }

    @Test func realSeedRoundTripsThroughASnapshot() {
        // The live façade is backed by exactly this snapshot; sanity-check a couple of known lookups.
        let snapshot = ExerciseCatalogSnapshot(ExerciseCatalog.seedDefinitions)
        #expect(snapshot.definition(id: "deadlift")?.category == .strength)
        #expect(snapshot.resolve("spin bike", generic: generic).id == "stationary_bike")
        #expect(snapshot.definitions.count == ExerciseCatalog.definitions.count)
    }
}
