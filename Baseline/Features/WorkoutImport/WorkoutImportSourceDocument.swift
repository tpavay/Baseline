import CryptoKit
import Foundation

enum WorkoutImportStableIdentity {
    static func digest(_ parts: some Sequence<String>) -> String {
        let data = Data(parts.joined(separator: "\u{1f}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func page(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func observation(
        pageDigest: String,
        text: String,
        boundingBox: WorkoutTextObservation.Rect
    ) -> String {
        digest([
            pageDigest,
            normalized(text),
            quantized(boundingBox.x),
            quantized(boundingBox.y),
            quantized(boundingBox.width),
            quantized(boundingBox.height),
        ])
    }

    static func section(observations: [WorkoutTextObservation]) -> String {
        digest(observations.flatMap { [$0.id, normalized($0.text)] })
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func quantized(_ value: Double) -> String {
        String(Int((value * 10_000).rounded()))
    }
}

struct WorkoutImportSourceDocument: Codable, Equatable, Sendable {
    var lines: [WorkoutImportSourceLine]
    var sections: [WorkoutImportSourceSection]
}

enum WorkoutImportSourceDocumentError: Error, Equatable {
    case semanticUnitTooLarge
}

enum WorkoutImportSourceDocumentBuilder {
    static let maximumSectionCharacters = 6_000
    static let maximumSectionObservations = 180
    static let preferredSectionObservations = 100
    static let maximumSectionCount = 20
    static let contextLineCount = 3

    static func build(pages: [WorkoutImportSourcePage]) throws -> WorkoutImportSourceDocument {
        let orderedPages = pages
            .filter { $0.stage == .recognized }
            .sorted { $0.index < $1.index }
            .map { page in
                page.observations.sorted(by: readingOrder).map { observation in
                    WorkoutImportSourceLine(
                        id: observation.id,
                        text: observation.text,
                        sourceObservationIDs: [observation.id],
                        sourceImageIndex: observation.sourceImageIndex,
                        boundingBox: observation.boundingBox,
                        confidence: observation.confidence
                    )
                }
        }

        let withoutChrome = removeRepeatedChrome(orderedPages)
        // Identical programming on adjacent screenshots may be either scrolled overlap or an
        // intentionally repeated interval. Preserve both source observations and let the semantic
        // parser consolidate true overlap while accounting for every source identifier.
        let lines = withoutChrome.flatMap { $0 }
        return WorkoutImportSourceDocument(lines: lines, sections: try sections(from: lines))
    }

    private static func removeRepeatedChrome(_ pages: [[WorkoutImportSourceLine]]) -> [[WorkoutImportSourceLine]] {
        guard pages.count > 1 else { return pages }
        let statusClusterPages = Set(pages.indices.filter { pageIndex in
            pages[pageIndex].contains(where: isStatusBarClockAnchor)
                && pages[pageIndex].contains(where: isStatusBarBatteryAnchor)
        })
        let hasRepeatedStatusBarLayout = statusClusterPages.count >= 2
        var pageIndexesByToken: [String: Set<Int>] = [:]
        for (pageIndex, page) in pages.enumerated() {
            for line in page where isChromeRegion(line) && isKnownInterfaceChrome(normalized(line.text)) {
                pageIndexesByToken[normalized(line.text), default: []].insert(pageIndex)
            }
        }
        let repeated = Set(pageIndexesByToken.compactMap { token, indexes in indexes.count > 1 ? token : nil })
        var result = Array(repeating: [WorkoutImportSourceLine](), count: pages.count)
        for (pageIndex, page) in pages.enumerated() {
            for line in page {
                if hasRepeatedStatusBarLayout,
                   statusClusterPages.contains(pageIndex),
                   isStatusBarArtifact(line) {
                    continue
                }
                let token = normalized(line.text)
                if isChromeRegion(line), repeated.contains(token), isKnownInterfaceChrome(token) {
                    continue
                }
                result[pageIndex].append(line)
            }
        }
        return result
    }

    private struct SemanticUnit {
        var lines: [WorkoutImportSourceLine]
        var scopeID: String
        var fragmentPath: [String]

        var characterCount: Int { lines.reduce(0) { $0 + $1.text.count } }
    }

    private static func sections(from lines: [WorkoutImportSourceLine]) throws -> [WorkoutImportSourceSection] {
        guard !lines.isEmpty else { return [] }
        let semanticUnits = atomicChoiceUnits(from: semanticUnits(from: lines))
        let preferredSections = try sections(
            from: semanticUnits,
            observationLimit: preferredSectionObservations
        )
        guard preferredSections.count > maximumSectionCount else { return preferredSections }

        // Preserve the smaller latency-oriented sections for normal imports. If atomic semantic
        // units make that packing exceed the server limit, deterministically repack up to the
        // validated hard limit before rejecting a document that can still be processed safely.
        return try sections(
            from: semanticUnits,
            observationLimit: maximumSectionObservations
        )
    }

    private static func sections(
        from semanticUnits: [SemanticUnit],
        observationLimit: Int
    ) throws -> [WorkoutImportSourceSection] {
        var result: [WorkoutImportSourceSection] = []
        var observations: [WorkoutTextObservation] = []
        var provenanceObservationIDs: [String] = []
        var provenance: [WorkoutImportProvenance] = []
        var characters = 0
        var startScopeID = ""
        var endScopeID = ""
        var startFragmentPath: [String] = []
        var endFragmentPath: [String] = []

        func appendSection() {
            guard !observations.isEmpty else { return }
            let context = result.last?.observations.suffix(contextLineCount).map(\.text) ?? []
            let previous = result.last
            result.append(WorkoutImportSourceSection(
                id: WorkoutImportStableIdentity.section(observations: observations),
                order: result.count,
                observations: observations,
                provenanceObservationIDs: provenanceObservationIDs,
                provenance: provenance,
                contextBefore: context,
                characterCount: characters,
                startScopeID: startScopeID,
                endScopeID: endScopeID,
                startFragmentPath: startFragmentPath,
                endFragmentPath: endFragmentPath,
                continuationFromSectionID: previous?.endScopeID == startScopeID ? previous?.id : nil
            ))
            observations = []
            provenanceObservationIDs = []
            provenance = []
            characters = 0
            startScopeID = ""
            endScopeID = ""
            startFragmentPath = []
            endFragmentPath = []
        }

        for unit in semanticUnits {
            guard unit.characterCount <= maximumSectionCharacters,
                  unit.lines.count <= maximumSectionObservations else {
                throw WorkoutImportSourceDocumentError.semanticUnitTooLarge
            }
            if !observations.isEmpty && (
                characters + unit.characterCount > maximumSectionCharacters ||
                observations.count + unit.lines.count > observationLimit
            ) {
                appendSection()
            }
            if startScopeID.isEmpty { startScopeID = unit.scopeID }
            endScopeID = unit.scopeID
            if startFragmentPath.isEmpty { startFragmentPath = unit.fragmentPath }
            endFragmentPath = unit.fragmentPath
            for line in unit.lines {
                observations.append(WorkoutTextObservation(
                    id: line.id,
                    text: line.text,
                    confidence: line.confidence,
                    boundingBox: line.boundingBox,
                    sourceImageIndex: line.sourceImageIndex
                ))
                provenanceObservationIDs.append(contentsOf: line.sourceObservationIDs)
                provenance.append(WorkoutImportProvenance(
                    primaryID: line.id,
                    sourceObservationIDs: Array(Set(line.sourceObservationIDs)).sorted()
                ))
                characters += line.text.count
            }
        }
        appendSection()
        return result
    }

    /// A/B and Option A/Option B sequences describe one choice or required sequence. Keep the
    /// entire tail of that parent scope atomic so a model never sees one option without the others.
    private static func atomicChoiceUnits(from units: [SemanticUnit]) -> [SemanticUnit] {
        var result: [SemanticUnit] = []
        var index = 0
        while index < units.count {
            var unit = units[index]
            guard unit.lines.first.map({ startsAtomicChoice($0.text) }) == true else {
                result.append(unit)
                index += 1
                continue
            }
            index += 1
            while index < units.count, units[index].scopeID == unit.scopeID {
                unit.lines.append(contentsOf: units[index].lines)
                index += 1
            }
            result.append(unit)
        }
        return result
    }

    private static func semanticUnits(from lines: [WorkoutImportSourceLine]) -> [SemanticUnit] {
        var result: [SemanticUnit] = []
        var paragraph: [WorkoutImportSourceLine] = []
        var scopeID = WorkoutImportStableIdentity.digest(["workout-import-root", lines[0].id])
        var fragmentPath = [scopeID]

        func finishParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(SemanticUnit(
                lines: paragraph,
                scopeID: scopeID,
                fragmentPath: fragmentPath
            ))
            paragraph = []
        }

        for line in lines {
            if looksLikeHeading(line.text) || looksLikeContainerHeading(line.text) {
                finishParagraph()
                if looksLikeTopLevelHeading(line.text) {
                    scopeID = WorkoutImportStableIdentity.digest(["workout-import-scope", line.id])
                    fragmentPath = [scopeID]
                } else if looksLikeContainerHeading(line.text) {
                    let fragmentID = WorkoutImportStableIdentity.digest([
                        "workout-import-container-fragment",
                        scopeID,
                        line.id,
                    ])
                    fragmentPath = [scopeID, fragmentID]
                }
                result.append(SemanticUnit(
                    lines: [line],
                    scopeID: scopeID,
                    fragmentPath: fragmentPath
                ))
                continue
            }
            if let previous = paragraph.last,
               previous.sourceImageIndex != line.sourceImageIndex || paragraphGap(after: previous, before: line) {
                finishParagraph()
            }
            paragraph.append(line)
        }
        finishParagraph()
        return result
    }

    private static func paragraphGap(
        after previous: WorkoutImportSourceLine,
        before current: WorkoutImportSourceLine
    ) -> Bool {
        let verticalGap = previous.boundingBox.y - (current.boundingBox.y + current.boundingBox.height)
        return verticalGap > 0.035
    }

    private static func looksLikeHeading(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return false }
        if trimmed.hasSuffix(":") { return true }
        if trimmed.range(of: #"^(?:[A-Z]|Option\s+[A-Z]|Part\s+\d+)[.):]\s+"#, options: .regularExpression) != nil {
            return true
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count <= 10,
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) == nil else { return false }
        let titleWords = words.filter { word in
            guard let first = word.first else { return false }
            return first.isUppercase || word.allSatisfy(\.isNumber)
        }
        return titleWords.count >= max(1, words.count - 1)
    }

    private static func looksLikeTopLevelHeading(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeHeading(trimmed), !startsAtomicChoice(trimmed) else { return false }
        return trimmed.range(
            of: #"\b(?:block|summary|guidelines?|layer|dose|volume|warm[ -]?up|cool[ -]?down|strength|conditioning|accessor(?:y|ies)|mobility|coach(?:'s)? notes?)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func looksLikeContainerHeading(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160, !startsAtomicChoice(trimmed) else { return false }
        guard trimmed.range(
            of: #"\b(?:rest|recover(?:y)?)\s+(?:between|after)\s+(?:rounds?|sets?|intervals?)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) == nil else { return false }
        return trimmed.range(
            of: #"\b(?:amrap|emom|every\s+minute|for\s+time)\b|^\s*\d+\s+(?:rounds?|sets?|intervals?)\b|\b(?:circuit|intervals?)\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func startsAtomicChoice(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^(?:(?:Option\s+)?[A-Z]|Required)(?:[.):]|\s+-|\s)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func readingOrder(_ lhs: WorkoutTextObservation, _ rhs: WorkoutTextObservation) -> Bool {
        let lhsTop = lhs.boundingBox.y + lhs.boundingBox.height
        let rhsTop = rhs.boundingBox.y + rhs.boundingBox.height
        if abs(lhsTop - rhsTop) > 0.02 { return lhsTop > rhsTop }
        if abs(lhs.boundingBox.x - rhs.boundingBox.x) > 0.001 {
            return lhs.boundingBox.x < rhs.boundingBox.x
        }
        return lhs.id < rhs.id
    }

    private static func isChromeRegion(_ line: WorkoutImportSourceLine) -> Bool {
        let top = line.boundingBox.y + line.boundingBox.height
        return top >= 0.88 || line.boundingBox.y <= 0.08
    }

    private static func hasStatusBarGeometry(_ line: WorkoutImportSourceLine) -> Bool {
        let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let top = line.boundingBox.y + line.boundingBox.height
        return top >= 0.94
            && line.boundingBox.height <= 0.06
            && line.boundingBox.width <= 0.25
            && !trimmed.isEmpty
            && trimmed.count <= 8
            && trimmed.split(whereSeparator: \.isWhitespace).count <= 2
    }

    private static func isStatusBarClockAnchor(_ line: WorkoutImportSourceLine) -> Bool {
        hasStatusBarGeometry(line)
            && line.boundingBox.x <= 0.25
            && line.text.trimmingCharacters(in: .whitespacesAndNewlines).range(
                of: #"^\d{1,2}:\d{2}(?:\s+[[:alnum:]]{1,2})?$"#,
                options: .regularExpression
            ) != nil
    }

    private static func isStatusBarBatteryAnchor(_ line: WorkoutImportSourceLine) -> Bool {
        hasStatusBarGeometry(line)
            && line.boundingBox.x >= 0.75
            && line.text.trimmingCharacters(in: .whitespacesAndNewlines).range(
                of: #"^(?:100|[2-9]\d)%?$"#,
                options: .regularExpression
            ) != nil
    }

    private static func isStatusBarArtifact(_ line: WorkoutImportSourceLine) -> Bool {
        guard hasStatusBarGeometry(line) else { return false }
        let token = normalized(line.text)
        guard !looksLikeProgramming(line.text),
              !looksLikeTopLevelHeading(line.text),
              !looksLikeContainerHeading(line.text) else { return false }
        if token.range(
            of: #"^(?:5g(?:\s*uw)?|4g|3g|lte|wi[ -]?fi)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        return false
    }

    private static func looksLikeProgramming(_ value: String) -> Bool {
        let rawToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawToken.range(of: #"^\d+(?:\.\d+)?%$"#, options: .regularExpression) != nil {
            return true
        }
        let token = normalized(value)
        if token.range(of: #"^\d{1,2}:\d{2}(?:\s|$)"#, options: .regularExpression) != nil {
            return true
        }
        return [" rep", " reps", " sec", " min", " kg", " lb", " km", " meter", " round", " set"]
            .contains { token.contains($0) }
    }

    private static func isKnownInterfaceChrome(_ token: String) -> Bool {
        return ["history", "show less", "show more", "5g", "5g uw"].contains(token)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }
}
