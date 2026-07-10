import Foundation

/// A stable **exercise definition** — identity + the metrics the modality supports + a default
/// metric selection + an activity category + casual-language aliases. Global and stable: how one
/// workout logs an exercise never edits this. See docs/engine-and-data-model.md.
struct ExerciseDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let category: ActivityCategory
    let supported: [MetricType]
    let defaults: [MetricType]        // sensible metrics to log by default
    let aliases: [String]
}

/// A small curated catalog — enough to prove the metric model across real workouts before designing
/// every modality. Unknown movements resolve to a generic definition rather than failing.
enum ExerciseCatalog {
    static let definitions: [ExerciseDefinition] = [
        .init(id: "stationary_bike", name: "Stationary Bike", category: .cycling,
              supported: [.duration, .distance, .calories, .heartRate, .cadence, .power],
              defaults: [.duration, .distance],
              aliases: ["stationary bike", "spin bike", "indoor bike", "exercise bike", "assault bike"]),
        .init(id: "outdoor_bike", name: "Outdoor Bike", category: .cycling,
              supported: [.duration, .distance, .heartRate, .power, .cadence],
              defaults: [.duration, .distance],
              aliases: ["outdoor bike", "road bike", "cycling", "bike ride"]),
        .init(id: "bike_erg", name: "BikeErg", category: .erg,
              supported: [.duration, .distance, .calories, .power, .pace, .cadence, .heartRate],
              defaults: [.duration, .distance, .pace, .power],
              aliases: ["bikeerg", "bike erg", "concept2 bike", "c2 bike"]),
        .init(id: "run", name: "Run", category: .running,
              supported: [.duration, .distance, .heartRate, .pace, .cadence],
              defaults: [.duration, .distance, .pace],
              aliases: ["run", "running", "treadmill", "jog"]),
        .init(id: "ski_erg", name: "SkiErg", category: .erg,
              supported: [.duration, .distance, .calories, .power, .pace, .heartRate],
              defaults: [.duration, .distance, .pace, .power],
              aliases: ["skierg", "ski erg", "ski"]),
        .init(id: "row", name: "Row", category: .erg,
              supported: [.duration, .distance, .calories, .power, .pace, .heartRate],
              defaults: [.duration, .distance, .pace, .power],
              aliases: ["row", "rower", "rowerg", "concept2 row"]),
        .init(id: "deadlift", name: "Deadlift", category: .strength,
              supported: [.reps, .load, .rpe],
              defaults: [.reps, .load, .rpe],
              aliases: ["deadlift", "conventional deadlift"]),
        .init(id: "loaded_carry", name: "Loaded Carry", category: .carry,
              supported: [.distance, .load, .duration],
              defaults: [.distance, .load],
              aliases: ["loaded carry", "farmers carry", "farmer carry", "overhead carry", "suitcase carry"]),
        .init(id: "isometric_hold", name: "Isometric Hold", category: .isometric,
              supported: [.duration, .load, .rpe],
              defaults: [.duration, .load, .rpe],
              aliases: ["isometric hold", "isometric", "plank", "hold", "copenhagen"]),
    ]

    /// The fallback for movements not in the catalog — supports the common fields, defaults to none
    /// (the caller keeps whatever metrics were actually entered).
    static let generic = ExerciseDefinition(
        id: "generic", name: "Exercise", category: .other,
        supported: [.reps, .load, .duration, .distance, .calories, .rpe],
        defaults: [], aliases: [])

    /// Resolve casual language → a definition: exact name, then alias, then substring. Never nil —
    /// unknown movements get the generic definition (so nothing fails; identity just isn't curated).
    static func resolve(_ name: String) -> ExerciseDefinition {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return generic }
        if let exact = definitions.first(where: { $0.name.lowercased() == key }) { return exact }
        if let alias = definitions.first(where: { $0.aliases.contains(key) }) { return alias }
        if let fuzzy = definitions.first(where: { def in
            def.aliases.contains(where: { key.contains($0) || $0.contains(key) })
        }) { return fuzzy }
        return generic
    }

    static func definition(id: String) -> ExerciseDefinition? {
        definitions.first { $0.id == id }
    }
}
