import Foundation

/// A performed-only change to one exercise occurrence. `iteration == nil` applies to every round
/// in the group; both scope values nil apply to a non-repeated exercise.
struct ExerciseLogAdjustment: Identifiable, Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        case original
        case skipped
        case substituted
    }

    var id = UUID()
    var plannedExerciseID: UUID
    var groupID: UUID?
    var iteration: Int?
    var outcome: Outcome
    var substitution: LoggedExerciseSubstitution?
}
