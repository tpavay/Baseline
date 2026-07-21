import Foundation

/// Strips import-only scaffolding out of a **parsed** document before it becomes editor content.
///
/// This operates on structure the parser actually produced. It never invents exercises, and there is
/// deliberately no path here that turns recognized text into a workout: an import that could not be
/// structured fails visibly instead of presenting a confidently wrong draft. See
/// `WorkoutImportCoordinator.fail(_:stage:reason:retryable:progress:)`.
enum WorkoutImportArtifactSanitizer {
    static func removingImportArtifacts(from document: ParsedWorkoutDocument) -> ParsedWorkoutDocument {
        var sanitized = document
        sanitized.title = sanitized.title.caseInsensitiveCompare("Imported workout") == .orderedSame
            ? "Workout"
            : sanitized.title
        sanitized.blocks = sanitized.blocks.compactMap { block in
            var block = block
            block.nodes = block.nodes.compactMap(sanitizedNode)
            let isFallbackBlock = block.name.lowercased().hasPrefix("imported section")
            return isFallbackBlock && block.nodes.isEmpty ? nil : block
        }
        return sanitized
    }

    private static func sanitizedNode(_ node: ParsedWorkoutNode) -> ParsedWorkoutNode? {
        switch node {
        case .exercise, .rest:
            return node
        case .group(var group):
            if group.label.caseInsensitiveCompare("Recognized text - needs review") == .orderedSame {
                return nil
            }
            group.children = group.children.compactMap(sanitizedNode)
            return .group(group)
        case .choice(var choice):
            choice.options = choice.options.compactMap(sanitizedNode)
            return choice.options.isEmpty ? nil : .choice(choice)
        }
    }
}
