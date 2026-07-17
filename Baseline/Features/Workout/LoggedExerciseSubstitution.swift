import Foundation

/// A snapshot of the movement actually performed when it differs from the template exercise.
/// Keeping this on the log preserves the original plan while allowing different metrics and media.
struct LoggedExerciseSubstitution: Codable, Equatable, Sendable {
    var exerciseName: String
    var definitionId: String?
    var selectedMetrics: [MetricType]
    var displayUnits: [MetricType: MetricUnit]
    var prescription: Prescription

    func applying(to planned: PlannedExercise) -> PlannedExercise {
        var actual = planned
        actual.exerciseName = exerciseName
        actual.definitionId = definitionId
        actual.selectedMetrics = selectedMetrics
        actual.displayUnits = displayUnits
        actual.prescription = prescription
        return actual
    }
}
