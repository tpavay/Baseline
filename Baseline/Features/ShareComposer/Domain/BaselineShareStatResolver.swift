import Foundation

/// Resolves Baseline completed-workout aggregates into share-sticker display values.
struct BaselineShareStatResolver {
    let summary: WorkoutLogSummary
    let unitForMetric: (MetricType) -> MetricUnit

    func availableKinds() -> [ShareStatStickerKind] {
        ShareStatStickerKind.allCases.filter { resolve($0) != nil }
    }

    func resolve(_ kind: ShareStatStickerKind) -> ResolvedShareStat? {
        switch kind {
        case .workoutName:
            return stat(kind, "WORKOUT", summary.title)
        case .date:
            return stat(kind, "DATE", DateFormatter.shareComposerDate.string(from: summary.finishedAt))
        case .duration:
            return stat(kind, "DURATION", MetricFormat.durationLong(summary.elapsedSeconds))
        case .exerciseCount:
            guard summary.exerciseCount > 0 else { return nil }
            return stat(kind, "EXERCISES", "\(summary.exerciseCount)")
        case .totalSets:
            guard summary.totalSets > 0 else { return nil }
            return stat(kind, "SETS", "\(summary.totalSets)")
        case .totalReps:
            guard summary.totalReps > 0 else { return nil }
            return stat(kind, "REPS", summary.totalReps.formatted(.number.grouping(.automatic)))
        case .totalVolume:
            guard summary.totalVolumeKilograms > 0 else { return nil }
            let unit = unitForMetric(.load)
            return stat(
                kind,
                "VOLUME",
                MetricFormat.value(summary.totalVolumeKilograms, .load, unit: unit)
            )
        case .heaviestLoad:
            guard let load = summary.heaviestLoadKilograms else { return nil }
            return stat(
                kind,
                "HEAVIEST",
                MetricFormat.value(load, .load, unit: unitForMetric(.load))
            )
        case .totalDistance:
            guard summary.totalDistanceMeters > 0 else { return nil }
            return stat(
                kind,
                "DISTANCE",
                MetricFormat.value(summary.totalDistanceMeters, .distance, unit: unitForMetric(.distance))
            )
        case .totalDuration:
            guard summary.totalDurationSeconds > 0 else { return nil }
            return stat(kind, "WORK TIME", MetricFormat.durationLong(summary.totalDurationSeconds))
        case .totalCalories:
            guard summary.totalCalories > 0 else { return nil }
            return stat(kind, "CAL", MetricFormat.value(summary.totalCalories, .calories, unit: unitForMetric(.calories)))
        case .avgPace:
            guard let pace = summary.averagePaceSecondsPerMeter else { return nil }
            return stat(kind, "AVG PACE", MetricFormat.value(pace, .pace, unit: unitForMetric(.pace)))
        }
    }

    private func stat(_ kind: ShareStatStickerKind, _ label: String, _ value: String) -> ResolvedShareStat {
        ResolvedShareStat(kind: kind, label: label, value: value)
    }
}

private extension DateFormatter {
    static let shareComposerDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}
