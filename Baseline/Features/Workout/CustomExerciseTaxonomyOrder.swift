import Foundation

/// Deliberate display order for every custom-exercise taxonomy picker.
/// Each list must cover its enum exactly once; `CustomExerciseTaxonomyOrderTests` enforces that
/// so a new taxonomy case can never be silently unpickable in the custom-exercise flow.
enum CustomExerciseTaxonomyOrder {
    static let equipment: [Equipment] = [
        .bodyweight, .barbell, .ezBar, .trapBar, .dumbbell, .kettlebell, .medicineBall, .machine,
        .cable, .sled, .sandbag, .box, .bench, .band, .jumpRope, .pullUpBar, .bike, .rower,
        .skiErg, .treadmill, .stairStepper, .elliptical, .other
    ]

    static let muscles: [Muscle] = [
        .chest, .lats, .upperBack, .traps, .lowerBack, .frontDelts, .sideDelts, .rearDelts,
        .biceps, .triceps, .forearms, .abdominals, .obliques, .glutes, .quadriceps,
        .hamstrings, .adductors, .abductors, .calves, .hipFlexors, .neck, .fullBody
    ]

    static let metrics: [MetricType] = [
        .reps, .load, .duration, .distance, .pace, .power, .calories, .cadence, .heartRate,
        .heartRateZoneTime, .rpe
    ]

    static let patterns: [MovementPattern] = MovementPattern.allCases

    static let tags: [ExerciseTag] = [
        .hyrox, .powerlifting, .olympicWeightlifting, .strongman, .calisthenics, .plyometric, .mobility
    ]

    static let levels: [ExerciseLevel] = ExerciseLevel.allCases
}
