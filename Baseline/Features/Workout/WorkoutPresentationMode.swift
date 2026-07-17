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
}
