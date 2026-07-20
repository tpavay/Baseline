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

    /// Where an edit made on this surface belongs. A surface showing performed data is showing the
    /// session's own shape, so its edits stay on the session copy; the plan surfaces edit the plan.
    var editScope: WorkoutEditScope { usesPerformedData ? .session : .plan }
}
