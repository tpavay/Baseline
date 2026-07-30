import Foundation

/// Builds the clean clipboard and system-share text form for a completed workout.
enum WorkoutShareTextSummary {
    static func make(from summary: WorkoutLogSummary, units: ShareUnitResolver) -> String {
        var lines: [String] = [
            summary.title,
            DateFormatter.shareTextDate.string(from: summary.finishedAt),
            "Duration: \(WorkoutPresentationFormatter.elapsedDuration(seconds: summary.elapsedSeconds))"
        ]

        let resolver = BaselineShareStatResolver(summary: summary, units: units)
        if let distance = resolver.resolve(.totalDistance) {
            lines.append("Distance: \(distance.value)")
        }
        if let pace = resolver.resolve(.avgPace) {
            lines.append("Average pace: \(pace.value)")
        }

        lines.append("")

        for exercise in summary.exerciseLines where exercise.completedSetCount > 0 {
            lines.append("\(exercise.name) - \(exercise.completedSetCount) sets")
            for (index, set) in exercise.setSummaries.enumerated() {
                lines.append("  \(index + 1). \(set)")
            }
        }

        lines.append("")
        lines.append("Shared from Baseline")
        return lines.joined(separator: "\n")
    }
}

private extension DateFormatter {
    static let shareTextDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
