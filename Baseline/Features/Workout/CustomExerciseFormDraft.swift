import Foundation

/// Presentation state for Baseline's deliberate manual custom-exercise flow.
struct CustomExerciseFormDraft: Equatable {
    var name: String
    var equipment: [Equipment]
    var primaryMuscles: [Muscle] {
        didSet { secondaryMuscles.removeAll(where: primaryMuscles.contains) }
    }
    var secondaryMuscles: [Muscle]
    var metrics: [MetricType]
    var patterns: [MovementPattern]
    var tags: [ExerciseTag]
    var level: [ExerciseLevel]

    init(
        name: String = "",
        equipment: [Equipment] = [],
        primaryMuscles: [Muscle] = [],
        secondaryMuscles: [Muscle] = [],
        metrics: [MetricType] = [],
        patterns: [MovementPattern] = [],
        tags: [ExerciseTag] = [],
        level: [ExerciseLevel] = [.intermediate]
    ) {
        self.name = name
        self.equipment = equipment
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles.filter { primaryMuscles.contains($0) == false }
        self.metrics = metrics
        self.patterns = patterns
        self.tags = tags
        self.level = level
    }

    var canSave: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && equipment.isEmpty == false
            && primaryMuscles.isEmpty == false
            && metrics.isEmpty == false
    }

    @MainActor
    func createDefinition(in store: WorkoutStore) -> ExerciseDefinition {
        store.createCustomDefinition(
            name: name,
            supported: metrics,
            equipment: equipment,
            primaryMuscles: primaryMuscles,
            secondaryMuscles: secondaryMuscles,
            patterns: patterns,
            tags: tags,
            level: level.first ?? .intermediate
        )
    }
}
