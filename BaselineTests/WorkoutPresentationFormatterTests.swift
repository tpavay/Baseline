import Foundation
import Testing
@testable import Baseline

struct WorkoutPresentationFormatterTests {
    @Test func elapsedDurationUsesFixedHoursMinutesAndSeconds() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        #expect(
            WorkoutPresentationFormatter.elapsedDuration(
                from: start,
                to: start.addingTimeInterval(3_723.9)
            ) == "01:02:03"
        )
        #expect(
            WorkoutPresentationFormatter.elapsedDuration(
                from: start,
                to: start.addingTimeInterval(-1)
            ) == "00:00:00"
        )
    }

    @Test func repeatedBlockIntentIsSuppressed() {
        #expect(WorkoutPresentationFormatter.blockIntent(name: "Warm-up", intent: "warm-up") == nil)
        #expect(WorkoutPresentationFormatter.blockIntent(name: "Main Run", intent: "main") == nil)
        #expect(WorkoutPresentationFormatter.blockIntent(name: "Main Run", intent: "aerobic") == "aerobic")
    }

    @Test func fixedRoundsMoveIntoTheGroupTitle() {
        let group = WorkoutGroup(
            label: "Strides",
            execution: GroupExecution(repetition: .count(6))
        )
        #expect(WorkoutPresentationFormatter.groupTitle(group) == "6 × Strides")
        #expect(WorkoutPresentationFormatter.groupExecutionSummary(group.execution) == nil)
    }

    @Test func numericImportArtifactsAreNotShownAsInstructions() {
        var exercise = PlannedExercise(exerciseName: "Treadmill Run")
        exercise.prescription.intensityTargets = [
            .descriptive("1"),
            .descriptive("Very easy pace"),
        ]
        exercise.guidance = CoachGuidance(formCues: ["Very easy pace"])

        #expect(WorkoutPresentationFormatter.exerciseInstructions(exercise) == ["Very easy pace"])
    }

    @Test func editReviewSeparatesStructuredIntensityFromQualitativeLoadTargets() {
        var exercise = PlannedExercise(exerciseName: "Sled Pull")
        exercise.prescription.intensityTargets = [
            .rpe(lower: 6, upper: 8),
            .namedZone(system: "Morpheus", range: "Blue"),
            .descriptive("Load target: Race weight"),
        ]

        #expect(WorkoutPresentationFormatter.structuredIntensityTargets(exercise) == [
            "RPE 6–8",
            "Morpheus: Blue",
        ])
        #expect(WorkoutPresentationFormatter.qualitativeLoadTargets(exercise) == ["Race weight"])
    }
}
