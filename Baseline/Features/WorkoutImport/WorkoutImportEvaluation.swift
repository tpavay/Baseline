import Foundation

struct WorkoutImportEvaluationSample: Sendable {
    var name: String
    var observations: [WorkoutTextObservation]
    var expectedFingerprint: String?
}

struct WorkoutImportEvaluationResult: Sendable {
    var sampleName: String
    var parserName: String
    var elapsedMilliseconds: Int
    var fingerprintMatched: Bool? = nil
    var issueCount: Int
    var error: String? = nil
}

/// A deliberately UI-free evaluation seam for comparing parsers against a fixed, sanitized OCR corpus.
/// It is not used in production routing; model changes should earn their way in through these reports.
@MainActor
enum WorkoutImportEvaluationRunner {
    static func evaluate(
        samples: [WorkoutImportEvaluationSample],
        parsers: [(name: String, parser: any WorkoutParsing)],
        catalog: [ExerciseDefinition]
    ) async -> [WorkoutImportEvaluationResult] {
        var results: [WorkoutImportEvaluationResult] = []
        let hints = catalog.flatMap { [$0.name] + $0.aliases }
        for sample in samples {
            for candidate in parsers {
                let start = ContinuousClock.now
                do {
                    let response = try await candidate.parser.parse(observations: sample.observations, catalogHints: hints)
                    let built = WorkoutImportDraftBuilder.build(response.document, catalog: catalog)
                    let fingerprint = WorkoutFingerprint.value(for: built.draft.workout)
                    results.append(.init(sampleName: sample.name, parserName: candidate.name,
                                         elapsedMilliseconds: milliseconds(since: start),
                                         fingerprintMatched: sample.expectedFingerprint.map { $0 == fingerprint },
                                         issueCount: built.issues.count))
                } catch {
                    results.append(.init(sampleName: sample.name, parserName: candidate.name,
                                         elapsedMilliseconds: milliseconds(since: start), issueCount: 0,
                                         error: error.localizedDescription))
                }
            }
        }
        return results
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        return Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
