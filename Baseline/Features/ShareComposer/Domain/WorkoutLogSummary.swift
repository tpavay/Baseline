import Foundation

/// Pure aggregate of a completed performed log.
///
/// Baseline persists per-set facts rather than session-level totals, so share surfaces compute the
/// small set of required aggregates at the edge.
struct WorkoutLogSummary: Equatable, Sendable {
    struct ExerciseLine: Equatable, Sendable {
        var name: String
        var completedSetCount: Int
        var setSummaries: [String]
    }

    var title: String
    var startedAt: Date
    var finishedAt: Date
    var confirmedDurationSeconds: TimeInterval?
    var exerciseCount: Int
    var totalSets: Int
    var totalReps: Int
    var totalVolumeKilograms: Double
    var heaviestLoadKilograms: Double?
    var totalDistanceMeters: Double
    var totalDurationSeconds: Double
    var totalCalories: Double
    var averagePaceSecondsPerMeter: Double?
    var averageHeartRate: Int?
    var maxHeartRate: Int?
    var exerciseLines: [ExerciseLine]

    var elapsedSeconds: TimeInterval {
        if let confirmedDurationSeconds, confirmedDurationSeconds.isFinite {
            return min(max(0, confirmedDurationSeconds), MetricFormat.maxDurationSeconds)
        }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }

    init(
        title: String,
        log: WorkoutLog,
        startedAt: Date,
        finishedAt: Date,
        confirmedDurationSeconds: TimeInterval? = nil,
        averageHeartRate: Int? = nil,
        maxHeartRate: Int? = nil,
        units: ShareUnitResolver
    ) {
        self.title = title
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.confirmedDurationSeconds = confirmedDurationSeconds
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate

        var setCount = 0
        var reps = 0
        var volume = 0.0
        var heaviestLoad: Double?
        var distance = 0.0
        var duration = 0.0
        var calories = 0.0
        var lines: [ExerciseLine] = []

        for exercise in log.exercises {
            var completedSets = 0
            var setSummaries: [String] = []

            for set in exercise.setLogs where set.outcome == .completed {
                completedSets += 1
                setCount += 1

                if let setReps = set.reps {
                    reps += setReps
                }
                if let load = set.load {
                    heaviestLoad = max(heaviestLoad ?? load, load)
                    if let setReps = set.reps {
                        volume += Double(setReps) * load
                    }
                }
                if let setDistance = set.distance {
                    distance += setDistance
                }
                if let setDuration = set.duration {
                    duration += Double(setDuration)
                }
                if let setCalories = set.calories {
                    calories += setCalories
                }
                setSummaries.append(
                    Self.setSummary(
                        set,
                        plannedExerciseID: exercise.plannedExerciseID,
                        units: units
                    )
                )
            }

            lines.append(
                ExerciseLine(
                    name: exercise.exerciseName,
                    completedSetCount: completedSets,
                    setSummaries: setSummaries
                )
            )
        }

        exerciseCount = log.exercises.count
        totalSets = setCount
        totalReps = reps
        totalVolumeKilograms = volume
        heaviestLoadKilograms = heaviestLoad
        totalDistanceMeters = distance
        totalDurationSeconds = duration
        totalCalories = calories
        averagePaceSecondsPerMeter = distance > 0 && duration > 0 ? duration / distance : nil
        exerciseLines = lines
    }

    private static func setSummary(
        _ set: SetLog,
        plannedExerciseID: UUID?,
        units: ShareUnitResolver
    ) -> String {
        func unit(_ metric: MetricType) -> MetricUnit {
            units.unitForExercise(metric, plannedExerciseID)
        }
        var parts: [String] = []
        if let reps = set.reps {
            parts.append("\(reps) reps")
        }
        if let load = set.load {
            parts.append(MetricFormat.value(load, .load, unit: unit(.load)))
        }
        if let duration = set.duration {
            parts.append(MetricFormat.duration(Double(duration)))
        }
        if let distance = set.distance {
            parts.append(MetricFormat.value(distance, .distance, unit: unit(.distance)))
        }
        if let pace = Self.setPace(set) {
            parts.append(MetricFormat.value(pace, .pace, unit: unit(.pace)))
        } else if let pace = set.values[.pace] {
            parts.append(MetricFormat.value(pace, .pace, unit: unit(.pace)))
        }
        if let calories = set.calories {
            parts.append(MetricFormat.value(calories, .calories, unit: unit(.calories)))
        }
        return parts.isEmpty ? "Completed" : parts.joined(separator: " · ")
    }

    private static func setPace(_ set: SetLog) -> Double? {
        guard let seconds = set.duration,
              let meters = set.distance,
              seconds > 0,
              meters > 0
        else { return nil }
        return Double(seconds) / meters
    }
}
