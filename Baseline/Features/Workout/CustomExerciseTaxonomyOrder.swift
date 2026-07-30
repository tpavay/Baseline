import Foundation

/// Deliberate display order for every custom-exercise taxonomy picker.
/// Each list must cover its enum exactly once; `CustomExerciseTaxonomyOrderTests` enforces that
/// so a new taxonomy case can never be silently unpickable in the custom-exercise flow.
enum CustomExerciseTaxonomyOrder {
    static let equipment = Equipment.customCreationOptions
    static let muscles = Muscle.customCreationOptions
    static let metrics = MetricType.customCreationOptions
    static let patterns = MovementPattern.customCreationOptions
    static let tags = ExerciseTag.customCreationOptions
    static let levels = ExerciseLevel.customCreationOptions
}
