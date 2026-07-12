import Foundation

enum ExerciseMediaPublicationStatus: String, Codable, Equatable, Sendable {
    case draft
    case ready
    case published
    case blocked
    case retired
}
