import Foundation

enum WorkoutPresentationFormatter {
    static func elapsedDuration(from startedAt: Date, to currentDate: Date) -> String {
        elapsedDuration(seconds: currentDate.timeIntervalSince(startedAt))
    }

    static func elapsedDuration(seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    static func blockIntent(name: String, intent: String?) -> String? {
        guard let intent = intent?.trimmingCharacters(in: .whitespacesAndNewlines), !intent.isEmpty else {
            return nil
        }
        let normalizedName = normalized(name)
        let normalizedIntent = normalized(intent)
        guard normalizedName != normalizedIntent else { return nil }

        let phaseOnly = ["warmup", "main", "cooldown", "transition"]
        if phaseOnly.contains(normalizedIntent), normalizedName.contains(normalizedIntent) {
            return nil
        }
        return intent
    }

    static func groupTitle(_ group: WorkoutGroup) -> String {
        if case .count(let count) = group.execution.repetition, count > 1 {
            return "\(count) × \(group.label)"
        }
        return group.label
    }

    static func groupExecutionSummary(_ execution: GroupExecution) -> String? {
        var parts: [String] = []
        if case .until(let seconds) = execution.repetition {
            parts.append("AMRAP · \(durationLabel(seconds))")
        }
        if let cadence = execution.cadence {
            parts.append(cadence.intervalSeconds == 60 ? "EMOM" : "Every \(durationLabel(cadence.intervalSeconds))")
        }
        if let scoring = execution.scoring {
            switch scoring {
            case .completion:
                break
            case .elapsedTime:
                parts.append("For time")
            case .roundsAndReps:
                if execution.repetition.durationSeconds == nil { parts.append("Rounds + reps") }
            case .total(let metric):
                parts.append("Total \(metric.label.lowercased())")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func qualitativeLoadTargets(_ exercise: PlannedExercise) -> [String] {
        deduplicated(
            exercise.prescription.intensityTargets
                .map(intensityLabel)
                .compactMap(qualitativeLoadTarget)
        )
    }

    /// The intensity targets worth showing as their own row. Import can leave a bare number behind as a
    /// descriptive target; those carry no meaning on their own, so they stay out of every surface that
    /// renders targets rather than only the ones that once filtered them.
    static func structuredIntensityTargets(_ exercise: PlannedExercise) -> [String] {
        deduplicated(
            exercise.prescription.intensityTargets.compactMap { target in
                let label = intensityLabel(target)
                guard qualitativeLoadTarget(from: label) == nil, isMeaningfulInstruction(label) else {
                    return nil
                }
                return label
            }
        )
    }

    static func intensityLabel(_ target: IntensityTarget) -> String {
        switch target {
        case .heartRateZone(let zone): "Heart-rate zone \(zone)"
        case .namedZone(let system, let range): "\(system): \(range)"
        case .rpe(let lower, let upper): "RPE \(lower.formatted())–\(upper.formatted())"
        case .pace(let pace): pace
        case .power(let lower, let upper, let unit):
            "\(lower.formatted())–\(upper.formatted()) \(unit.short)"
        case .thresholdPercentage(let lower, let upper):
            "\(lower.formatted())–\(upper.formatted())% threshold"
        case .descriptive(let value): value
        }
    }

    static func isMeaningfulInstruction(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let numericCandidate = trimmed.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        let hasLetters = trimmed.contains(where: \Character.isLetter)
        return hasLetters || numericCandidate != trimmed
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private static func normalized(_ value: String) -> String {
        String(
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        )
    }

    private static func qualitativeLoadTarget(from value: String) -> String? {
        let prefix = "load target:"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let target = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    private static func durationLabel(_ seconds: Int) -> String {
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
