import SwiftUI

/// Prototype-approved labels, subtitles, and glyphs for the real taxonomy values.
enum CustomExerciseTaxonomyPresentation {
    static func title(_ equipment: Equipment) -> String {
        equipment == .bodyweight ? "None / bodyweight" : equipment.displayName
    }

    static func icon(_ equipment: Equipment) -> Image {
        let symbol = switch equipment {
        case .barbell, .barbellPlates, .ezBar, .trapBar: "dumbbell"
        case .dumbbell, .kettlebell, .medicineBall: "figure.strengthtraining.traditional"
        case .cable: "cable.connector"
        case .machine: "gearshape"
        case .bodyweight: "figure.stand"
        case .band, .rope: "scribble.variable"
        case .bench, .box: "shippingbox"
        case .sled: "square.stack.3d.down.right"
        case .sandbag: "backpack"
        case .jumpRope: "circle.dashed"
        case .pullUpBar, .hangboard: "rectangle.topthird.inset.filled"
        case .exerciseBall, .bosuBall: "circle"
        case .bike: "bicycle"
        case .rower: "figure.rower"
        case .skiErg: "figure.skiing.crosscountry"
        case .treadmill: "figure.run"
        case .stairStepper: "figure.stairs"
        case .elliptical: "figure.elliptical"
        case .other: "asterisk"
        }
        return Image(systemName: symbol)
    }

    static func title(_ muscle: Muscle) -> String {
        muscle == .abdominals ? "Abs" : muscle.displayName
    }

    static func subtitle(_ muscle: Muscle) -> String {
        switch muscle {
        case .chest: "chest"
        case .lats, .upperBack, .traps, .lowerBack: "back"
        case .frontDelts, .sideDelts, .rearDelts: "shoulders"
        case .biceps, .triceps, .forearms: "arms"
        case .abdominals, .obliques: "core"
        case .glutes, .quadriceps, .hamstrings, .adductors, .abductors, .calves, .hipFlexors: "legs"
        case .neck: "neck"
        case .fullBody: "full body"
        }
    }

    static func icon(_ muscle: Muscle) -> Image {
        switch muscle.region {
        case .anterior: Image(systemName: "circle.lefthalf.filled")
        case .posterior: Image(systemName: "circle.righthalf.filled")
        case .systemic: Image(systemName: "circle.fill")
        }
    }

    static func title(_ metric: MetricType) -> String {
        switch metric {
        case .heartRate: "Heart rate"
        case .heartRateZoneTime: "Heart-rate zone time"
        default: metric.label
        }
    }

    static func subtitle(_ metric: MetricType, unitSystem: UnitSystem) -> String? {
        if metric == .reps || metric == .calories || metric == .rpe {
            return nil
        }
        if metric == .duration { return "time" }
        if metric == .heartRateZoneTime { return "zone time" }
        let unit = unitSystem.displayUnit(metric: metric, exercise: nil).short
        return unit.isEmpty ? nil : unit
    }

    static func icon(_ metric: MetricType) -> Image {
        let symbol = switch metric {
        case .reps: "number"
        case .load: "scalemass"
        case .duration: "stopwatch"
        case .distance: "ruler"
        case .calories: "flame"
        case .heartRate: "heart"
        case .heartRateZoneTime: "heart.circle"
        case .cadence: "arrow.triangle.2.circlepath"
        case .power: "bolt"
        case .pace: "figure.run"
        case .rpe: "dial.medium"
        }
        return Image(systemName: symbol)
    }

    static func title(_ pattern: MovementPattern) -> String {
        pattern == .hold ? "Hold / isometric" : pattern.displayName
    }

    static func icon(_ pattern: MovementPattern) -> Image {
        let symbol = switch pattern {
        case .squat: "arrow.down"
        case .hinge: "arrow.turn.down.right"
        case .lunge: "arrow.down.right"
        case .push: "arrow.up"
        case .pull: "arrow.down"
        case .carry: "arrow.right"
        case .rotation: "arrow.clockwise"
        case .gait: "figure.walk"
        case .hold: "pause"
        }
        return Image(systemName: symbol)
    }

    static func icon(_ tag: ExerciseTag) -> Image {
        Image(systemName: "number")
    }

    static func title(_ level: ExerciseLevel) -> String {
        level == .expert ? "Advanced" : level.displayName
    }

    static func subtitle(_ level: ExerciseLevel) -> String? {
        level == .intermediate ? "default" : nil
    }

    static func icon(_ level: ExerciseLevel) -> Image {
        let symbol = switch level {
        case .beginner: "chart.bar.fill"
        case .intermediate: "chart.bar.xaxis"
        case .expert: "chart.bar.xaxis.ascending"
        }
        return Image(systemName: symbol)
    }
}
