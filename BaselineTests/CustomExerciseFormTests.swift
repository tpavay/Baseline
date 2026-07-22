import Foundation
import Testing
@testable import Baseline

@MainActor
struct CustomExerciseFormTests {
    @Test func requiredFieldsControlWhetherTheDraftCanSave() {
        var draft = CustomExerciseFormDraft(name: "Single-Arm Sled Drag")
        #expect(draft.canSave == false)

        draft.equipment = [.sled]
        draft.primaryMuscles = [.lats]
        draft.metrics = [.duration]
        #expect(draft.canSave)

        draft.name = "   \n"
        #expect(draft.canSave == false)
    }

    @Test func promotingAMuscleToPrimaryRemovesItFromOtherMuscles() {
        var draft = CustomExerciseFormDraft(
            name: "Single-Arm Sled Drag",
            primaryMuscles: [.lats],
            secondaryMuscles: [.quadriceps, .biceps]
        )

        draft.primaryMuscles = [.quadriceps]

        #expect(draft.primaryMuscles == [.quadriceps])
        #expect(draft.secondaryMuscles == [.biceps])
    }

    @Test func aDraftSeededWithOverlappingMusclesKeepsOnlyThePrimaryCopy() {
        let draft = CustomExerciseFormDraft(
            name: "Single-Arm Sled Drag",
            primaryMuscles: [.lats],
            secondaryMuscles: [.lats, .biceps]
        )

        #expect(draft.secondaryMuscles == [.biceps])
    }

    @Test func pickerSelectionFeedsTheDraftAndPreservesTapOrder() {
        let options: [MovementPattern] = [.squat, .hinge, .lunge, .push, .pull, .carry, .rotation, .gait, .hold]

        var selection = CustomExercisePickerLogic.orderedSelection(
            options: options,
            selectedIDs: [.pull, .gait],
            previousSelection: [.pull]
        )
        #expect(selection == [.pull, .gait])

        selection = CustomExercisePickerLogic.orderedSelection(
            options: options,
            selectedIDs: [.gait],
            previousSelection: selection
        )
        #expect(selection == [.gait])
    }

    @Test func savingCreatesTheDefinitionWithEveryChosenTaxonomyValue() throws {
        let defaults = UserDefaults(suiteName: "custom-form-\(UUID().uuidString)")!
        let store = WorkoutStore(units: StubUnitSystem(.imperial), defaults: defaults)
        let draft = CustomExerciseFormDraft(
            name: "Single-Arm Sled Drag",
            equipment: [.sled],
            primaryMuscles: [.lats],
            secondaryMuscles: [.quadriceps, .biceps, .forearms],
            metrics: [.duration, .distance, .pace],
            patterns: [.pull, .gait],
            tags: [.hyrox],
            level: [.intermediate]
        )

        let created = draft.createDefinition(in: store)

        #expect(created.name == "Single-Arm Sled Drag")
        #expect(created.equipment == [.sled])
        #expect(created.primaryMuscles == [.lats])
        #expect(created.secondaryMuscles == [.quadriceps, .biceps, .forearms])
        #expect(created.supported == [.duration, .distance, .pace])
        #expect(created.patterns == [.pull, .gait])
        #expect(created.tags == [.hyrox])
        #expect(created.level == .intermediate)
        #expect(store.customDefinitions.map(\.id) == [created.id])
    }
}

struct CustomExerciseTaxonomyOrderTests {
    @Test func equipmentOrderCoversEveryCaseExactlyOnce() {
        #expect(Set(CustomExerciseTaxonomyOrder.equipment) == Set(Equipment.allCases))
        #expect(CustomExerciseTaxonomyOrder.equipment.count == Equipment.allCases.count)
    }

    @Test func muscleOrderCoversEveryCaseExactlyOnce() {
        #expect(Set(CustomExerciseTaxonomyOrder.muscles) == Set(Muscle.allCases))
        #expect(CustomExerciseTaxonomyOrder.muscles.count == Muscle.allCases.count)
    }

    @Test func metricOrderCoversEveryCaseExactlyOnce() {
        #expect(Set(CustomExerciseTaxonomyOrder.metrics) == Set(MetricType.allCases))
        #expect(CustomExerciseTaxonomyOrder.metrics.count == MetricType.allCases.count)
    }

    @Test func patternOrderCoversEveryCaseExactlyOnce() {
        #expect(Set(CustomExerciseTaxonomyOrder.patterns) == Set(MovementPattern.allCases))
        #expect(CustomExerciseTaxonomyOrder.patterns.count == MovementPattern.allCases.count)
    }

    @Test func tagOrderCoversEveryCaseExactlyOnce() {
        #expect(Set(CustomExerciseTaxonomyOrder.tags) == Set(ExerciseTag.allCases))
        #expect(CustomExerciseTaxonomyOrder.tags.count == ExerciseTag.allCases.count)
    }

    @Test func levelOrderCoversEveryCaseExactlyOnce() {
        #expect(Set(CustomExerciseTaxonomyOrder.levels) == Set(ExerciseLevel.allCases))
        #expect(CustomExerciseTaxonomyOrder.levels.count == ExerciseLevel.allCases.count)
    }
}
