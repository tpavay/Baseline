import SwiftUI

private struct ExerciseMediaClientKey: EnvironmentKey {
    static let defaultValue = ExerciseMediaClient.live
}

extension EnvironmentValues {
    var exerciseMediaClient: ExerciseMediaClient {
        get { self[ExerciseMediaClientKey.self] }
        set { self[ExerciseMediaClientKey.self] = newValue }
    }
}
