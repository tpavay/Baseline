import Foundation

enum CustomExercisePickerKind: String, Identifiable, Hashable {
    case equipment
    case primaryMuscle
    case otherMuscles
    case metrics
    case movementPattern
    case tags
    case level

    var id: String { rawValue }

    var title: String {
        switch self {
        case .equipment: "Select equipment"
        case .primaryMuscle: "Primary muscle"
        case .otherMuscles: "Other muscles"
        case .metrics: "Metrics"
        case .movementPattern: "Movement pattern"
        case .tags: "Tags"
        case .level: "Level"
        }
    }

    var allowsMultiple: Bool {
        switch self {
        case .otherMuscles, .metrics, .movementPattern, .tags: true
        case .equipment, .primaryMuscle, .level: false
        }
    }

    var isSearchEnabled: Bool {
        switch self {
        case .equipment, .primaryMuscle, .otherMuscles: true
        case .metrics, .movementPattern, .tags, .level: false
        }
    }
}
