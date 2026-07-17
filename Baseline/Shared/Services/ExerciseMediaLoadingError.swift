import Foundation

enum ExerciseMediaLoadingError: Error, Equatable, Sendable {
    case invalidStoragePath
    case invalidImageData
}
