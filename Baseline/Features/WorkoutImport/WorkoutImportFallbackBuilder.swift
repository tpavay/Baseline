import Foundation

/// A deterministic safety net for provider failures.
///
/// This builder is deliberately conservative. It only creates native exercises when recognized
/// text contains an exact catalog name or alias. It never turns unstructured OCR into editor
/// content, invents an exercise, or creates import-only blocks.
enum WorkoutImportFallbackBuilder {
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

    static func build(
        sections: [WorkoutImportSourceSection],
        catalog: [ExerciseDefinition]
    ) -> ParsedWorkoutDocument {
        let observations = sections
            .sorted { $0.order < $1.order }
            .flatMap(\.observations)

        let exercises = observations.flatMap { observation in
            parsedExercises(in: observation, catalog: catalog)
        }

        guard !exercises.isEmpty else {
            return ParsedWorkoutDocument(title: title(from: observations, catalog: catalog), blocks: [])
        }

        return ParsedWorkoutDocument(
            title: title(from: observations, catalog: catalog),
            blocks: [
                ParsedWorkoutBlock(
                    name: "Workout",
                    exercises: exercises,
                    sourceObservationIDs: exercises.flatMap(\.sourceObservationIDs)
                ),
            ]
        )
    }

    /// Kept for call sites that do not inject a catalog yet. Production import always supplies the
    /// current catalog so remotely delivered definitions and aliases participate in recovery.
    static func build(sections: [WorkoutImportSourceSection]) -> ParsedWorkoutDocument {
        build(sections: sections, catalog: ExerciseCatalog.definitions)
    }

    private struct CatalogMatch {
        let definition: ExerciseDefinition
        let range: Range<String.Index>
        let aliasLength: Int
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

    private static func parsedExercises(
        in observation: WorkoutTextObservation,
        catalog: [ExerciseDefinition]
    ) -> [ParsedWorkoutExercise] {
        let line = searchable(observation.text.replacingOccurrences(of: "/", with: " or "))
        guard !line.isEmpty else { return [] }

        let candidates = catalog.compactMap { definition -> CatalogMatch? in
            let aliases = ([definition.name] + definition.aliases)
                .map(searchable)
                .filter { !$0.isEmpty }
                .sorted { $0.count > $1.count }

            for alias in aliases {
                guard let range = wholePhraseRange(of: alias, in: line) else { continue }
                return CatalogMatch(definition: definition, range: range, aliasLength: alias.count)
            }
            return nil
        }
        .sorted {
            if $0.aliasLength != $1.aliasLength { return $0.aliasLength > $1.aliasLength }
            return $0.range.lowerBound < $1.range.lowerBound
        }

        var accepted: [CatalogMatch] = []
        for candidate in candidates {
            guard !accepted.contains(where: { $0.range.overlaps(candidate.range) }) else { continue }
            if candidate.definition.id == "isometric_hold", !accepted.isEmpty { continue }
            accepted.append(candidate)
        }
        if accepted.count > 1 {
            accepted.removeAll { $0.definition.id == "isometric_hold" }
        }
        accepted.sort { $0.range.lowerBound < $1.range.lowerBound }
        guard looksLikeExercisePrescription(line, matches: accepted) else { return [] }

        return accepted.enumerated().map { index, match in
            let previousEnd = index == 0 ? line.startIndex : accepted[index - 1].range.upperBound
            let nextStart = index + 1 < accepted.count ? accepted[index + 1].range.lowerBound : line.endIndex
            let prefix = String(line[previousEnd..<match.range.lowerBound])
            let suffix = String(line[match.range.upperBound..<nextStart])
            let metrics = parsedMetrics(
                beforeExercise: prefix,
                afterExercise: suffix,
                definition: match.definition
            )
            let setCount = parsedSetCount(beforeExercise: prefix)
            let sets = (0..<setCount).map { _ in ParsedWorkoutSet(metrics: metrics) }

            return ParsedWorkoutExercise(
                name: match.definition.name,
                sets: sets,
                notes: [observation.text.trimmingCharacters(in: .whitespacesAndNewlines)],
                sourceObservationIDs: [observation.id]
            )
        }
    }

    private static func parsedMetrics(
        beforeExercise prefix: String,
        afterExercise suffix: String,
        definition: ExerciseDefinition
    ) -> [ParsedWorkoutMetric] {
        let supported = Set(definition.supported)
        var metrics: [ParsedWorkoutMetric] = []
        let dimensionalContext = "\(prefix) \(suffix)"

        if supported.contains(.distance),
           let match = firstMatch(#"(\d+(?:\.\d+)?)\s*(km|kilometers?|m|meters?|mi|miles?)\b"#, in: dimensionalContext),
           let value = Double(match[1]) {
            metrics.append(.init(type: "distance", value: value, unit: match[2]))
        }

        if supported.contains(.duration) {
            if let match = firstMatch(#"(\d+):(\d{2})"#, in: dimensionalContext),
               let minutes = Double(match[1]),
               let seconds = Double(match[2]) {
                metrics.append(.init(type: "duration", value: (minutes * 60) + seconds, unit: "seconds"))
            } else if let match = firstMatch(#"(\d+(?:\.\d+)?)\s*(minutes?|mins?|seconds?|secs?)\b"#, in: dimensionalContext),
                      let value = Double(match[1]) {
                let unit = match[2].hasPrefix("min") ? "minutes" : "seconds"
                metrics.append(.init(type: "duration", value: value, unit: unit))
            }
        }

        if supported.contains(.reps), metrics.isEmpty, !containsSetCount(prefix) {
            let directCount = lastMatch(#"(?:^|\s)(\d+(?:\.\d+)?)\s*$"#, in: prefix)
            let alternativeCount = firstMatch(
                #"^\s*(\d+(?:\.\d+)?)\s+.+\s+or\s*$"#,
                in: prefix
            )
            if let match = directCount ?? alternativeCount,
               let value = Double(match[1]) {
                metrics.append(.init(type: "reps", value: value, unit: "reps"))
            }
        }

        if supported.contains(.load),
           let match = firstMatch(#"(\d+(?:\.\d+)?)\s*(kg|kilograms?|lb|lbs|pounds?)\b"#, in: "\(prefix) \(suffix)"),
           let value = Double(match[1]) {
            metrics.append(.init(type: "load", value: value, unit: match[2]))
        }

        return metrics
    }

    private static func parsedSetCount(beforeExercise prefix: String) -> Int {
        guard let match = lastMatch(#"(\d+)\s*(?:sets?|rounds?)\b"#, in: prefix),
              let count = Int(match[1]) else { return 1 }
        return min(max(count, 1), 20)
    }

    private static func containsSetCount(_ prefix: String) -> Bool {
        firstMatch(#"\b(?:sets?|rounds?)\b"#, in: prefix) != nil
    }

    private static func looksLikeExercisePrescription(
        _ line: String,
        matches: [CatalogMatch]
    ) -> Bool {
        guard !matches.isEmpty else { return false }
        if firstMatch(#"\b(?:avoid|skip|do not|don t|should not|instead of)\b"#, in: line) != nil {
            return false
        }
        if firstMatch(
            #"\b\d+(?:\.\d+)?\s*(?:km|kilometers?|m|meters?|mi|miles?|minutes?|mins?|seconds?|secs?|kg|kilograms?|lb|lbs|pounds?)\s+(?:is|are|was|were|should|could|would|may|might|can|must|needs?)\b"#,
            in: line
        ) != nil {
            return false
        }

        let sortedMatches = matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let beginsLikePrescription = sortedMatches.first?.range.lowerBound == line.startIndex
            || firstMatch(#"^(?:[a-d]\s+)?(?:\d+(?:\.\d+)?|max|maximum|amrap|emom)\b"#, in: line) != nil
        let hasStructuredPrescription = sortedMatches.enumerated().contains { index, match in
            let previousEnd = index == 0 ? line.startIndex : sortedMatches[index - 1].range.upperBound
            let nextStart = index + 1 < sortedMatches.count
                ? sortedMatches[index + 1].range.lowerBound
                : line.endIndex
            let prefix = String(line[previousEnd..<match.range.lowerBound])
            let suffix = String(line[match.range.upperBound..<nextStart])
            return !parsedMetrics(
                beforeExercise: prefix,
                afterExercise: suffix,
                definition: match.definition
            ).isEmpty || parsedSetCount(beforeExercise: prefix) > 1
        }
        if beginsLikePrescription && hasStructuredPrescription { return true }

        var remainderParts: [Substring] = []
        var cursor = line.startIndex
        for match in sortedMatches {
            remainderParts.append(line[cursor..<match.range.lowerBound])
            cursor = match.range.upperBound
        }
        remainderParts.append(line[cursor..<line.endIndex])
        let remainder = remainderParts.joined(separator: " ")
        let allowedConnectors: Set<String> = [
            "a", "b", "c", "d", "and", "or", "plus", "with", "then", "alternate",
            "alternating", "option", "max", "maximum", "hold", "each", "side", "per",
        ]
        let remainingWords = remainder.split(whereSeparator: \.isWhitespace).map(String.init)
        return remainingWords.allSatisfy(allowedConnectors.contains)
    }

    private static func title(
        from observations: [WorkoutTextObservation],
        catalog: [ExerciseDefinition]
    ) -> String {
        let exercisePhrases = catalog.flatMap { [$0.name] + $0.aliases }.map(searchable)
        let candidates = observations.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        for candidate in candidates {
            let normalized = searchable(candidate)
            guard candidate.count >= 4, candidate.count <= 100,
                  !looksLikeInterfaceNoise(normalized),
                  !exercisePhrases.contains(where: { wholePhraseRange(of: $0, in: normalized) != nil }) else {
                continue
            }
            let words = Set(normalized.split(separator: " ").map(String.init))
            if !words.isDisjoint(with: ["workout", "session", "day", "week", "training"]) {
                return candidate
            }
        }
        return "Workout"
    }

    private static func looksLikeInterfaceNoise(_ value: String) -> Bool {
        if value.isEmpty || value.allSatisfy({ $0.isNumber || $0 == " " || $0 == ":" || $0 == "." }) {
            return true
        }
        let ignored = [
            "history", "show less", "show more", "the bayens method", "daily summary",
            "recovery guidelines", "execution notes", "morpheus target", "coach s note",
        ]
        return ignored.contains(value)
    }

    private static func searchable(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let mapped = folded.map { character -> Character in
            if character.isLetter || character.isNumber || character == "." || character == ":" {
                return character
            }
            return " "
        }
        let punctuationSafe = String(mapped).replacingOccurrences(
            of: #"(?<!\d)[\.:]|[\.:](?!\d)"#,
            with: " ",
            options: .regularExpression
        )
        return punctuationSafe.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func wholePhraseRange(of phrase: String, in line: String) -> Range<String.Index>? {
        guard !phrase.isEmpty else { return nil }
        let padded = " \(line) "
        guard let range = padded.range(of: " \(phrase) ") else { return nil }
        let lowerOffset = padded.distance(from: padded.startIndex, to: range.lowerBound)
        guard lowerOffset >= 0,
              let lower = line.index(line.startIndex, offsetBy: lowerOffset, limitedBy: line.endIndex),
              let upper = line.index(lower, offsetBy: phrase.count, limitedBy: line.endIndex) else { return nil }
        return lower..<upper
    }

    private static func firstMatch(_ pattern: String, in value: String) -> [String]? {
        matches(pattern, in: value).first
    }

    private static func lastMatch(_ pattern: String, in value: String) -> [String]? {
        matches(pattern, in: value).last
    }

    private static func matches(_ pattern: String, in value: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).map { result in
            (0..<result.numberOfRanges).map { index in
                let matchRange = result.range(at: index)
                guard matchRange.location != NSNotFound,
                      let range = Range(matchRange, in: value) else { return "" }
                return String(value[range])
            }
        }
    }
}
