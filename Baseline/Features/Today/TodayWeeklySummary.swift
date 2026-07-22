import Foundation

struct TodayCompletedExerciseSample: Equatable {
    let completedLogID: UUID
    let date: Date
    let definitionID: String?
    let metrics: [MetricValues]
}

struct TodayCompletedSessionSample: Equatable {
    let completedLogID: UUID
    let finishedAt: Date
    let startedAt: Date?
}

struct TodayMovementSummary: Equatable, Identifiable {
    let name: String
    let sets: Int
    let tint: TodayMovementTint

    var id: String { name }
}

enum TodayMovementTint: Equatable {
    case accent
    case caution
}

struct TodayHeartRateZoneSummary: Equatable, Identifiable {
    let zone: HeartRateZone
    let seconds: Double

    var id: Int { zone.rawValue }
}

struct TodayMuscleMapLayer: Equatable, Identifiable {
    let assetName: String
    let intensity: Double

    var id: String { assetName }
}

struct TodayWeeklySummary: Equatable {
    let sessionCount: Int
    let trainingSeconds: Double
    let cardioSeconds: Double
    let movements: [TodayMovementSummary]
    let frontMuscles: [TodayMuscleMapLayer]
    let backMuscles: [TodayMuscleMapLayer]
    let heartRateZones: [TodayHeartRateZoneSummary]
    let averageHeartRate: Int?

    static func build(
        sessions: [TodayCompletedSessionSample],
        exercises: [TodayCompletedExerciseSample],
        zoneModel: HeartRateZoneModel,
        referenceDate: Date = .now,
        calendar: Calendar = .planWeek
    ) -> TodayWeeklySummary {
        let weekStart = calendar.weekStart(for: referenceDate)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? referenceDate
        let weekSessions = sessions.filter { $0.finishedAt >= weekStart && $0.finishedAt < weekEnd }
        let weekLogIDs = Set(weekSessions.map(\.completedLogID))
        let weekExercises = exercises.filter {
            $0.date >= weekStart && $0.date < weekEnd && weekLogIDs.contains($0.completedLogID)
        }

        let fallbackDurations = exerciseDurationByLog(weekExercises)
        let trainingSeconds = weekSessions.reduce(0.0) { total, session in
            guard let startedAt = session.startedAt, session.finishedAt > startedAt else {
                return total + fallbackDurations[session.completedLogID, default: 0]
            }
            return total + session.finishedAt.timeIntervalSince(startedAt)
        }

        var cardioSeconds = 0.0
        var movementSets: [MovementPattern: Double] = [:]
        var muscleScores: [Muscle: Double] = [:]
        var zoneSeconds: [HeartRateZone: Double] = [:]
        var weightedHeartRate = 0.0
        var heartRateWeight = 0.0

        for sample in weekExercises {
            let definition = sample.definitionID.flatMap(ExerciseCatalog.definition(id:)) ?? ExerciseCatalog.generic
            let completedSets = Double(sample.metrics.count)
            if definition.modality == .cardio {
                cardioSeconds += sample.metrics.compactMap { $0[.duration] }.reduce(0, +)
            }
            for pattern in definition.patterns {
                movementSets[pattern, default: 0] += completedSets
            }
            for muscle in definition.primaryMuscles {
                muscleScores[muscle, default: 0] += completedSets
            }
            for muscle in definition.secondaryMuscles {
                muscleScores[muscle, default: 0] += completedSets * 0.5
            }

            for values in sample.metrics {
                guard let bpmValue = values[.heartRate], bpmValue > 0 else { continue }
                let duration = max(values[.duration] ?? 0, 1)
                let bpm = Int(bpmValue.rounded())
                let zone = zoneModel.zone(forBPM: bpm)
                zoneSeconds[zone, default: 0] += duration
                weightedHeartRate += bpmValue * duration
                heartRateWeight += duration
            }
        }

        let muscles = muscleLayers(scores: muscleScores)
        return TodayWeeklySummary(
            sessionCount: weekSessions.count,
            trainingSeconds: trainingSeconds,
            cardioSeconds: cardioSeconds,
            movements: movementSummary(movementSets),
            frontMuscles: muscles.front,
            backMuscles: muscles.back,
            heartRateZones: HeartRateZone.allCases.map {
                TodayHeartRateZoneSummary(zone: $0, seconds: zoneSeconds[$0, default: 0])
            },
            averageHeartRate: heartRateWeight > 0 ? Int((weightedHeartRate / heartRateWeight).rounded()) : nil
        )
    }

    static let empty = TodayWeeklySummary(
        sessionCount: 0,
        trainingSeconds: 0,
        cardioSeconds: 0,
        movements: movementSummary([:]),
        frontMuscles: [],
        backMuscles: [],
        heartRateZones: HeartRateZone.allCases.map { TodayHeartRateZoneSummary(zone: $0, seconds: 0) },
        averageHeartRate: nil
    )

    var trainingDurationText: String { Self.durationText(trainingSeconds) }
    var cardioDurationText: String { Self.durationText(cardioSeconds) }
    var heartRateDurationText: String { Self.durationText(heartRateZones.reduce(0) { $0 + $1.seconds }) }

    static func durationText(_ seconds: Double) -> String {
        let minutes = max(Int((seconds / 60).rounded()), 0)
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 { return "\(remainingMinutes)m" }
        if remainingMinutes == 0 { return "\(hours)h" }
        return "\(hours)h \(remainingMinutes)m"
    }

    private enum MuscleMapSide {
        case front
        case back

        var assetPrefix: String {
            switch self {
            case .front: "MuscleMapFront"
            case .back: "MuscleMapBack"
            }
        }
    }

    private static func exerciseDurationByLog(
        _ exercises: [TodayCompletedExerciseSample]
    ) -> [UUID: Double] {
        Dictionary(grouping: exercises, by: \.completedLogID).mapValues { samples in
            samples.flatMap(\.metrics).compactMap { $0[.duration] }.reduce(0, +)
        }
    }

    private static func movementSummary(
        _ scores: [MovementPattern: Double]
    ) -> [TodayMovementSummary] {
        let rows: [(String, Double)] = [
            ("Squat", scores[.squat, default: 0]),
            ("Push", scores[.push, default: 0]),
            ("Pull", scores[.pull, default: 0]),
            ("Hinge", scores[.hinge, default: 0]),
            ("Carry / gait", scores[.carry, default: 0] + scores[.gait, default: 0]),
        ]
        let maximum = rows.map(\.1).max() ?? 0
        return rows.map { name, value in
            let sets = Int(value.rounded())
            let tint: TodayMovementTint = maximum > 0 && value < maximum * 0.4 ? .caution : .accent
            return TodayMovementSummary(name: name, sets: sets, tint: tint)
        }
    }

    private static func muscleLayers(
        scores: [Muscle: Double]
    ) -> (front: [TodayMuscleMapLayer], back: [TodayMuscleMapLayer]) {
        let front = assetScores(side: .front, scores: scores)
        let back = assetScores(side: .back, scores: scores)
        let maximum = max(front.values.max() ?? 0, back.values.max() ?? 0)
        guard maximum > 0 else { return ([], []) }
        func layers(_ mapped: [String: Double], side: MuscleMapSide) -> [TodayMuscleMapLayer] {
            mapped.map { slug, score in
                TodayMuscleMapLayer(assetName: side.assetPrefix + slug, intensity: score / maximum)
            }
            .sorted { $0.assetName < $1.assetName }
        }
        return (layers(front, side: .front), layers(back, side: .back))
    }

    private static func assetScores(
        side: MuscleMapSide,
        scores: [Muscle: Double]
    ) -> [String: Double] {
        scores.reduce(into: [String: Double]()) { result, pair in
            guard let slug = assetSlug(for: pair.key, side: side) else { return }
            result[slug, default: 0] += pair.value
        }
    }

    private static func assetSlug(for muscle: Muscle, side: MuscleMapSide) -> String? {
        switch (side, muscle) {
        case (.front, .chest): "Chest"
        case (.front, .obliques): "Obliques"
        case (.front, .abdominals): "Abs"
        case (.front, .biceps): "Biceps"
        case (.front, .triceps): "Triceps"
        case (.front, .neck): "Neck"
        case (.front, .traps): "Trapezius"
        case (.front, .frontDelts), (.front, .sideDelts): "Deltoids"
        case (.front, .adductors): "Adductors"
        case (.front, .hipFlexors), (.front, .quadriceps): "Quadriceps"
        case (.front, .calves): "Calves"
        case (.front, .forearms): "Forearm"
        case (.back, .neck): "Neck"
        case (.back, .traps): "Trapezius"
        case (.back, .rearDelts), (.back, .sideDelts): "Deltoids"
        case (.back, .upperBack), (.back, .lats): "UpperBack"
        case (.back, .triceps): "Triceps"
        case (.back, .lowerBack): "LowerBack"
        case (.back, .forearms): "Forearm"
        case (.back, .glutes), (.back, .abductors): "Gluteal"
        case (.back, .adductors): "Adductors"
        case (.back, .hamstrings): "Hamstring"
        case (.back, .calves): "Calves"
        default: nil
        }
    }
}
