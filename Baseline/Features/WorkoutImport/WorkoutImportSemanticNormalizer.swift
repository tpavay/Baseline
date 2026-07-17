import Foundation

/// Repairs only source-provable structural contradictions. It never guesses missing content: a
/// model-produced choice becomes required work only when its own OCR evidence explicitly joins the
/// movements with `+`, or says to alternate A & B, without any choice wording.
enum WorkoutImportSemanticNormalizer {
    static func normalize(
        _ document: ParsedWorkoutDocument,
        observations: [WorkoutTextObservation]
    ) -> ParsedWorkoutDocument {
        let textByID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0.text) })
        var result = document
        result.blocks = result.blocks.map { block in
            var block = block
            block.nodes = block.nodes.map { normalize($0, textByID: textByID) }
            return block
        }
        return result
    }

    private static func normalize(
        _ node: ParsedWorkoutNode,
        textByID: [String: String]
    ) -> ParsedWorkoutNode {
        switch node {
        case .exercise, .rest:
            return node
        case .group(var group):
            group.children = group.children.map { normalize($0, textByID: textByID) }
            return .group(group)
        case .choice(var choice):
            choice.options = choice.options.map { normalize($0, textByID: textByID) }
            let ids = Set(choice.sourceObservationIDs + choice.options.flatMap(sourceObservationIDs))
            let source = ids.compactMap { textByID[$0] }.joined(separator: " ")
            guard sourceProvesRequiredSequence(source) else { return .choice(choice) }
            return .group(ParsedWorkoutGroup(
                label: requiredGroupLabel(from: choice.label),
                children: choice.options,
                sourceObservationIDs: Array(ids).sorted()
            ))
        }
    }

    private static func sourceObservationIDs(_ node: ParsedWorkoutNode) -> [String] {
        switch node {
        case .exercise(let exercise): exercise.sourceObservationIDs
        case .rest(let rest): rest.sourceObservationIDs
        case .group(let group):
            group.sourceObservationIDs + group.children.flatMap(sourceObservationIDs)
        case .choice(let choice):
            choice.sourceObservationIDs + choice.options.flatMap(sourceObservationIDs)
        }
    }

    private static func sourceProvesRequiredSequence(_ source: String) -> Bool {
        let normalized = " " + source.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ") + " "
        let explicitlyOptional = normalized.contains(" or ")
            || normalized.contains(" either ")
            || normalized.contains(" choose ")
        guard !explicitlyOptional else { return false }
        return normalized.contains("+")
            || normalized.contains("&")
    }

    private static func requiredGroupLabel(from label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = trimmed.firstIndex(of: ":") {
            let prefix = trimmed[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { return prefix }
        }
        return trimmed.isEmpty ? "Required sequence" : trimmed
    }
}
