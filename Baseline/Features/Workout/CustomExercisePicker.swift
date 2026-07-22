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
                allowsMultiple: kind.allowsMultiple,
                isSearchEnabled: kind.isSearchEnabled,
                searchPrompt: "Search equipment",
                selected: $draft.equipment
            )
        case .primaryMuscle:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: muscleOptions,
                allowsMultiple: kind.allowsMultiple,
                isSearchEnabled: kind.isSearchEnabled,
                searchPrompt: "Search muscles",
                selected: $draft.primaryMuscles
            )
        case .otherMuscles:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: otherMuscleOptions,
                allowsMultiple: kind.allowsMultiple,
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
                allowsMultiple: kind.allowsMultiple,
                isSearchEnabled: kind.isSearchEnabled,
                selected: $draft.metrics
            )
        case .movementPattern:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: patternOptions,
                allowsMultiple: kind.allowsMultiple,
                isSearchEnabled: kind.isSearchEnabled,
                selectionLimit: 2,
                selected: $draft.patterns
            )
        case .tags:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: tagOptions,
                allowsMultiple: kind.allowsMultiple,
                isSearchEnabled: kind.isSearchEnabled,
                selected: $draft.tags
            )
        case .level:
            CustomExerciseTaxonomyPicker(
                title: kind.title,
                options: levelOptions,
                allowsMultiple: kind.allowsMultiple,
                isSearchEnabled: kind.isSearchEnabled,
                selected: $draft.level
            )
        }
    }

    private var equipmentOptions: [CustomExerciseTaxonomyOption<Equipment>] {
        CustomExerciseTaxonomyOrder.equipment.map { equipment in
            CustomExerciseTaxonomyOption(
                id: equipment,
                title: CustomExerciseTaxonomyPresentation.title(equipment),
                subtitle: nil,
                icon: CustomExerciseTaxonomyPresentation.icon(equipment)
            )
        }
    }

    private var muscleOptions: [CustomExerciseTaxonomyOption<Muscle>] {
        CustomExerciseTaxonomyOrder.muscles.map { muscle in
            CustomExerciseTaxonomyOption(
                id: muscle,
                title: CustomExerciseTaxonomyPresentation.title(muscle),
                subtitle: CustomExerciseTaxonomyPresentation.subtitle(muscle),
                icon: CustomExerciseTaxonomyPresentation.icon(muscle)
            )
        }
    }

    private var otherMuscleOptions: [CustomExerciseTaxonomyOption<Muscle>] {
        CustomExerciseTaxonomyOrder.muscles.map { muscle in
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
        CustomExerciseTaxonomyOrder.metrics.map { metric in
            CustomExerciseTaxonomyOption(
                id: metric,
                title: CustomExerciseTaxonomyPresentation.title(metric),
                subtitle: CustomExerciseTaxonomyPresentation.subtitle(metric, unitSystem: store.unitSystem),
                icon: CustomExerciseTaxonomyPresentation.icon(metric)
            )
        }
    }

    private var patternOptions: [CustomExerciseTaxonomyOption<MovementPattern>] {
        CustomExerciseTaxonomyOrder.patterns.map { pattern in
            CustomExerciseTaxonomyOption(
                id: pattern,
                title: CustomExerciseTaxonomyPresentation.title(pattern),
                subtitle: nil,
                icon: CustomExerciseTaxonomyPresentation.icon(pattern)
            )
        }
    }

    private var tagOptions: [CustomExerciseTaxonomyOption<ExerciseTag>] {
        CustomExerciseTaxonomyOrder.tags.map { tag in
            CustomExerciseTaxonomyOption(
                id: tag,
                title: tag.displayName,
                subtitle: nil,
                icon: CustomExerciseTaxonomyPresentation.icon(tag)
            )
        }
    }

    private var levelOptions: [CustomExerciseTaxonomyOption<ExerciseLevel>] {
        CustomExerciseTaxonomyOrder.levels.map { level in
            CustomExerciseTaxonomyOption(
                id: level,
                title: CustomExerciseTaxonomyPresentation.title(level),
                subtitle: CustomExerciseTaxonomyPresentation.subtitle(level),
                icon: CustomExerciseTaxonomyPresentation.icon(level)
            )
        }
    }
}
