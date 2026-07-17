import Foundation

struct ExerciseMediaClient: Sendable {
    var imageData: @Sendable (_ storagePath: String) async throws -> Data

    static let live: ExerciseMediaClient = {
        let repository = FirebaseExerciseMediaRepository()
        return ExerciseMediaClient { storagePath in
            try await repository.imageData(for: storagePath)
        }
    }()
}
