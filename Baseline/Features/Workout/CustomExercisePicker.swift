import SwiftUI

struct CustomExercisePicker: View {
    let kind: CustomExercisePickerKind
    @Binding var draft: CustomExerciseFormDraft

    @Environment(WorkoutStore.self) private var store

    @ViewBuilder
    var body: some View {
        switch kind {
        case .equipment:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: equipmentOptions,
                allowsMultiple: false,
                isSearchEnabled: kind.isSearchEnabled,
                searchPrompt: "Search equipment",
                selected: $draft.equipment
            )
        case .primaryMuscle:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: muscleOptions,
                allowsMultiple: false,
                isSearchEnabled: kind.isSearchEnabled,
                searchPrompt: "Search muscles",
                selected: $draft.primaryMuscles
            )
        case .otherMuscles:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: otherMuscleOptions,
                allowsMultiple: true,
                isSearchEnabled: kind.isSearchEnabled,
                searchPrompt: "Search muscles",
                selected: $draft.secondaryMuscles,
                unavailableReason: { muscle in
                    draft.primaryMuscles.contains(muscle) ? "primary" : nil
                }
            )
        case .metrics:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: metricOptions,
                allowsMultiple: true,
                isSearchEnabled: kind.isSearchEnabled,
                selected: $draft.metrics
            )
        case .movementPattern:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: patternOptions,
                allowsMultiple: true,
                isSearchEnabled: kind.isSearchEnabled,
                selectionLimit: 2,
                selected: $draft.patterns
            )
        case .tags:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: tagOptions,
                allowsMultiple: true,
                isSearchEnabled: kind.isSearchEnabled,
                selected: $draft.tags
            )
        case .level:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: levelOptions,
                allowsMultiple: false,
                isSearchEnabled: kind.isSearchEnabled,
                selected: $draft.level
            )
        }
    }

    private var equipmentOptions: [CustomExerciseTaxonomyOption<Equipment>] {
        equipmentOrder.map { equipment in
            CustomExerciseTaxonomyOption(
                id: equipment,
                title: CustomExerciseTaxonomyPresentation.title(equipment),
                subtitle: nil,
                icon: CustomExerciseTaxonomyPresentation.icon(equipment)
            )
        }
    }

    private var muscleOptions: [CustomExerciseTaxonomyOption<Muscle>] {
        muscleOrder.map { muscle in
            CustomExerciseTaxonomyOption(
                id: muscle,
                title: CustomExerciseTaxonomyPresentation.title(muscle),
                subtitle: CustomExerciseTaxonomyPresentation.subtitle(muscle),
                icon: CustomExerciseTaxonomyPresentation.icon(muscle)
            )
        }
    }

    private var otherMuscleOptions: [CustomExerciseTaxonomyOption<Muscle>] {
        muscleOrder.map { muscle in
            CustomExerciseTaxonomyOption(
                id: muscle,
                title: CustomExerciseTaxonomyPresentation.title(muscle),
                subtitle: draft.primaryMuscles.contains(muscle)
                    ? "primary"
                    : CustomExerciseTaxonomyPresentation.subtitle(muscle),
                icon: CustomExerciseTaxonomyPresentation.icon(muscle)
            )
        }
    }

    private var metricOptions: [CustomExerciseTaxonomyOption<MetricType>] {
        metricOrder.map { metric in
            CustomExerciseTaxonomyOption(
                id: metric,
                title: CustomExerciseTaxonomyPresentation.title(metric),
                subtitle: CustomExerciseTaxonomyPresentation.subtitle(metric, unitSystem: store.unitSystem),
                icon: CustomExerciseTaxonomyPresentation.icon(metric)
            )
        }
    }

    private var patternOptions: [CustomExerciseTaxonomyOption<MovementPattern>] {
        MovementPattern.allCases.map { pattern in
            CustomExerciseTaxonomyOption(
                id: pattern,
                title: CustomExerciseTaxonomyPresentation.title(pattern),
                subtitle: nil,
                icon: CustomExerciseTaxonomyPresentation.icon(pattern)
            )
        }
    }

    private var tagOptions: [CustomExerciseTaxonomyOption<ExerciseTag>] {
        tagOrder.map { tag in
            CustomExerciseTaxonomyOption(
                id: tag,
                title: tag.displayName,
                subtitle: nil,
                icon: CustomExerciseTaxonomyPresentation.icon(tag)
            )
        }
    }

    private var levelOptions: [CustomExerciseTaxonomyOption<ExerciseLevel>] {
        ExerciseLevel.allCases.map { level in
            CustomExerciseTaxonomyOption(
                id: level,
                title: CustomExerciseTaxonomyPresentation.title(level),
                subtitle: CustomExerciseTaxonomyPresentation.subtitle(level),
                icon: CustomExerciseTaxonomyPresentation.icon(level)
            )
        }
    }

    private var equipmentOrder: [Equipment] {
        [.bodyweight, .barbell, .ezBar, .trapBar, .dumbbell, .kettlebell, .medicineBall, .machine,
         .cable, .sled, .sandbag, .box, .bench, .band, .jumpRope, .pullUpBar, .bike, .rower,
         .skiErg, .treadmill, .stairStepper, .elliptical, .other]
    }

    private var muscleOrder: [Muscle] {
        [.chest, .lats, .upperBack, .traps, .lowerBack, .frontDelts, .sideDelts, .rearDelts,
         .biceps, .triceps, .forearms, .abdominals, .obliques, .glutes, .quadriceps,
         .hamstrings, .adductors, .abductors, .calves, .hipFlexors, .neck, .fullBody]
    }

    private var metricOrder: [MetricType] {
        [.reps, .load, .duration, .distance, .pace, .power, .calories, .cadence, .heartRate,
         .heartRateZoneTime, .rpe]
    }

    private var tagOrder: [ExerciseTag] {
        [.hyrox, .powerlifting, .olympicWeightlifting, .strongman, .calisthenics, .plyometric, .mobility]
    }
}
