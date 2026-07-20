import Foundation

/// One workout structure, rendered for three different jobs. Keeping the mode explicit prevents
/// template edits from leaking into performed data and keeps the visual hierarchy consistent.
enum WorkoutPresentationMode: Equatable {
    case view
    case editTemplate
    case log
    case completed

    var isEditing: Bool { self == .editTemplate }
    var isLogging: Bool { self == .log }
    var usesPerformedData: Bool { self == .log || self == .completed }

    /// Where an edit made on this surface belongs. Stated for every mode rather than derived, so the
    /// mapping cannot silently change when another flag does.
    var editScope: WorkoutEditScope {
        switch self {
        // Both of these show performed data, which is the session's own shape. A note, display label,
        // or set role typed there is a fact about that performance — including after it is finished.
        // Routing them to the plan would silently edit future workouts from a screen showing the past.
        case .log, .completed: .session
        // These show the saved plan, so edits are plan edits, exactly as before sessions existed.
        case .editTemplate, .view: .plan
        }
    }
}
