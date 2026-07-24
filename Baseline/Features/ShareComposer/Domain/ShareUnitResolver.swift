import Foundation

/// How a share surface asks for the athlete's display unit.
///
/// Two entry points because a share card asks two different questions. A per-set line belongs to one
/// exercise and must honour that exercise's override tiers, so a 20 m sled push reads in metres for
/// everyone rather than becoming "0.02 km". A workout-level total is a single number with room for
/// one unit, so it is resolved from the whole workout's composition instead.
///
/// The closures keep this layer free of `WorkoutStore`, which owns the resolution rule itself.
struct ShareUnitResolver {
    /// The unit for a metric logged under one performed exercise, keyed by its planned exercise id.
    /// A nil id is an ad-hoc add with no planned exercise to hang an override on.
    let unitForExercise: (MetricType, UUID?) -> MetricUnit
    /// The unit for a workout-level aggregate.
    let unitForTotals: (MetricType) -> MetricUnit

    init(
        unitForExercise: @escaping (MetricType, UUID?) -> MetricUnit,
        unitForTotals: @escaping (MetricType) -> MetricUnit
    ) {
        self.unitForExercise = unitForExercise
        self.unitForTotals = unitForTotals
    }

    /// A resolver with no workout in hand, where every metric reads in the athlete's system default.
    static func withoutExerciseContext(_ unit: @escaping (MetricType) -> MetricUnit) -> ShareUnitResolver {
        ShareUnitResolver(unitForExercise: { metric, _ in unit(metric) }, unitForTotals: unit)
    }

    /// The resolver for a completed workout: each performed exercise resolves through its own planned
    /// exercise, so the override tiers and the floor/endurance distance rule both reach the share card.
    @MainActor
    init(workout: Workout, store: WorkoutStore) {
        self.init(
            unitForExercise: { metric, plannedID in
                guard let plannedID,
                      let planned = workout.allExercises.first(where: { $0.id == plannedID })
                else { return store.displayUnit(metric) }
                return store.displayUnit(metric, for: planned)
            },
            unitForTotals: { store.displayUnit($0, forTotalsIn: workout) }
        )
    }
}
