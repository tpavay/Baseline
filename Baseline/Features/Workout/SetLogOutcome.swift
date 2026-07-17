import Foundation

enum SetLogOutcome: String, Codable, Equatable, Sendable {
    case pending
    case completed
    case skipped
}
