import Foundation
import Testing
@testable import Baseline

/// Streaming display has one promise: a row that has appeared is final. These tests hold it by
/// replaying the same JSON at every possible split point and checking that what was shown at step N
/// is always a prefix of what is shown at step N+1.
@Suite("Workout import streaming")
struct WorkoutImportStreamTests {

    private static let response = """
    {"title":"AM: VO2 THRESHOLDS","notes":["Level 3: As Prescribed"],"blocks":[\
    {"name":"Warmup","notes":[],"items":[\
    {"name":"Run","prescription":"2km","note":"easy"},\
    {"name":"Strides","sets":"6-8","prescription":"20 sec","note":"building to threshold pace"}]},\
    {"name":"A) 400s","notes":[],"items":[\
    {"name":"Run","sets":"15","prescription":"400m","rest":"40 secs","intensity":"3-5km pace, 8/9 RPE"},\
    {"name":"Burpee Broad Jump","sets":"4 min","prescription":"8 reps","note":"EMOM"}]}]}
    """

    private func exerciseNames(_ sketch: WorkoutImportSketch?) -> [String] {
        (sketch?.blocks ?? []).flatMap { $0.items.map(\.name) }
    }

    @Test func theCompletedStreamDecodesEveryExercise() {
        var stream = WorkoutImportSketchStream()
        _ = stream.append(Self.response)
        let finished = stream.finish()

        #expect(finished?.title == "AM: VO2 THRESHOLDS")
        #expect(exerciseNames(finished) == ["Run", "Strides", "Run", "Burpee Broad Jump"])
    }

    /// Character-by-character. Every partial parse must be valid, and the visible exercise list must
    /// only ever grow — never shrink, never change an entry it already showed.
    @Test func rowsOnlyEverAppendAcrossEveryPossibleSplit() {
        var stream = WorkoutImportSketchStream()
        var shown: [String] = []

        for character in Self.response {
            let sketch = stream.append(String(character))
            let names = exerciseNames(sketch)
            #expect(names.count >= shown.count, "the visible list shrank: \(shown) → \(names)")
            #expect(Array(names.prefix(shown.count)) == shown, "an already-visible row changed: \(shown) → \(names)")
            shown = names
        }

        // Everything withheld while streaming arrives at the end.
        #expect(exerciseNames(stream.finish()) == ["Run", "Strides", "Run", "Burpee Broad Jump"])
    }

    /// A row is only shown once it is closed, so a half-written item never reaches the screen with
    /// fields missing that would then fill in underneath the athlete.
    @Test func aPartiallyWrittenExerciseIsWithheldUntilItIsComplete() {
        let upToMidItem = Self.response.prefix(while: { _ in true })
            .prefix(Self.response.distance(
                from: Self.response.startIndex,
                to: Self.response.range(of: #""prescription":"2km""#)!.lowerBound
            ))
        var stream = WorkoutImportSketchStream()
        let sketch = stream.append(String(upToMidItem))

        // "Run" has a name by now but is not finished, so it is not offered.
        #expect(exerciseNames(sketch).isEmpty)
    }

    @Test func aTruncatedStreamStillYieldsTheExercisesThatDidArrive() {
        var stream = WorkoutImportSketchStream()
        let cut = Self.response.range(of: #"{"name":"Burpee"#)!.lowerBound
        _ = stream.append(String(Self.response[Self.response.startIndex..<cut]))

        #expect(exerciseNames(stream.finish()) == ["Run", "Strides", "Run"])
    }

    @Test func anEmptyOrGarbageBufferYieldsNothingRatherThanCrashing() {
        var empty = WorkoutImportSketchStream()
        #expect(empty.append("") == nil)
        #expect(empty.isEmpty)

        var garbage = WorkoutImportSketchStream()
        _ = garbage.append("not json at all")
        #expect(exerciseNames(garbage.finish()).isEmpty)
    }

    /// Escaped quotes inside a value must not be read as the end of the string, or the scanner would
    /// cut the document in the middle of a coach note.
    @Test func escapedQuotesInsideNotesDoNotConfuseTheScanner() {
        let json = #"{"title":"Coach said \"go\"","blocks":[{"name":"Main","items":[{"name":"Run"},{"name":"Row"}]}]}"#
        var stream = WorkoutImportSketchStream()
        _ = stream.append(json)
        let finished = stream.finish()

        #expect(finished?.title == #"Coach said "go""#)
        #expect(exerciseNames(finished) == ["Run", "Row"])
    }

    /// A number is not a value until a delimiter proves it finished: a trailing "40" may yet be
    /// "400", and showing a 40 m set that becomes a 400 m set is exactly the jump this design bans.
    @Test func aTrailingNumberIsNotTreatedAsFinished() {
        let partial = #"{"blocks":[{"name":"Main","items":[{"name":"Run","reps":40"#
        let closures = WorkoutImportSketchStream.closures(of: partial)

        #expect(!closures.contains { $0.contains("40") })
    }
}
