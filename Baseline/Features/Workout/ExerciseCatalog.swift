import Foundation

/// A stable **exercise definition** — identity + the metrics the modality supports + a default
/// metric selection + an activity category + casual-language aliases. Global and stable: how one
/// workout logs an exercise never edits this. See docs/engine-and-data-model.md.
struct ExerciseDefinition: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let category: ActivityCategory
    let supported: [MetricType]
    let defaults: [MetricType]        // sensible metrics to log by default
    let aliases: [String]
    let media: ExerciseMedia?

    init(
        id: String,
        name: String,
        category: ActivityCategory,
        supported: [MetricType],
        defaults: [MetricType],
        aliases: [String],
        media: ExerciseMedia? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.supported = supported
        self.defaults = defaults
        self.aliases = aliases
        self.media = media
    }
}

/// A small curated catalog — enough to prove the metric model across real workouts before designing
/// every modality. Unknown movements resolve to a generic definition rather than failing.
enum ExerciseCatalog {
    static let definitions: [ExerciseDefinition] = [
        .init(id: "stationary_bike", name: "Stationary Bike", category: .cycling,
              supported: [.duration, .distance, .calories, .heartRate, .cadence, .power],
              defaults: [.duration, .distance],
              aliases: ["stationary bike", "spin bike", "indoor bike", "exercise bike", "assault bike"],
              media: ExerciseMediaManifest.media(for: "stationary_bike")),
        .init(id: "outdoor_bike", name: "Outdoor Bike", category: .cycling,
              supported: [.duration, .distance, .heartRate, .power, .cadence],
              defaults: [.duration, .distance],
              aliases: ["outdoor bike", "road bike", "cycling", "bike ride"],
              media: ExerciseMediaManifest.media(for: "outdoor_bike")),
        .init(id: "bike_erg", name: "BikeErg", category: .erg,
              supported: [.duration, .distance, .calories, .power, .pace, .cadence, .heartRate],
              defaults: [.duration, .distance, .pace, .power],
              aliases: ["bikeerg", "bike erg", "concept2 bike", "c2 bike"]),
        .init(id: "run", name: "Run", category: .running,
              supported: [.duration, .distance, .heartRate, .pace, .cadence],
              defaults: [.duration, .distance, .pace],
              aliases: ["run", "running", "outdoor run", "road run", "track run", "jog"],
              media: ExerciseMediaManifest.media(for: "run")),
        .init(id: "treadmill_run", name: "Treadmill Run", category: .running,
              supported: [.duration, .distance, .heartRate, .pace, .cadence],
              defaults: [.duration, .distance, .pace],
              aliases: ["treadmill run", "treadmill running", "treadmill"],
              media: ExerciseMediaManifest.media(for: "treadmill_run")),
        .init(id: "ski_erg", name: "SkiErg", category: .erg,
              supported: [.duration, .distance, .calories, .power, .pace, .heartRate],
              defaults: [.duration, .distance, .pace, .power],
              aliases: ["skierg", "ski erg", "ski"],
              media: ExerciseMediaManifest.media(for: "ski_erg")),
        .init(id: "row", name: "Row", category: .erg,
              supported: [.duration, .distance, .calories, .power, .pace, .heartRate],
              defaults: [.duration, .distance, .pace, .power],
              aliases: ["row", "rower", "rowerg", "indoor row"],
              media: ExerciseMediaManifest.media(for: "row")),
        .init(id: "deadlift", name: "Deadlift", category: .strength,
              supported: [.reps, .load, .rpe],
              defaults: [.reps, .load, .rpe],
              aliases: ["deadlift", "conventional deadlift"],
              media: ExerciseMediaManifest.media(for: "deadlift")),
        .init(id: "back_squat", name: "Barbell Back Squat", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["back squat", "barbell back squat", "barbell squat"],
              media: ExerciseMediaManifest.media(for: "back_squat")),
        .init(id: "bench_press", name: "Bench Press", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["bench press", "barbell bench press", "bench"],
              media: ExerciseMediaManifest.media(for: "bench_press")),
        .init(id: "bodyweight_squat", name: "Bodyweight Squat", category: .strength,
              supported: [.reps, .duration, .rpe], defaults: [.reps, .rpe],
              aliases: ["bodyweight squat", "air squat", "unweighted squat"],
              media: ExerciseMediaManifest.media(for: "bodyweight_squat")),
        .init(id: "push_up", name: "Push-Up", category: .strength,
              supported: [.reps, .duration, .rpe], defaults: [.reps, .rpe],
              aliases: ["push-up", "push up", "pushup"],
              media: ExerciseMediaManifest.media(for: "push_up")),
        .init(id: "pull_up", name: "Pull-Up", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .rpe],
              aliases: ["pull-up", "pull up", "pullup"],
              media: ExerciseMediaManifest.media(for: "pull_up")),
        .init(id: "sled_push", name: "Sled Push", category: .strength,
              supported: [.distance, .load, .duration, .rpe], defaults: [.distance, .load, .duration],
              aliases: ["sled push", "prowler push"],
              media: ExerciseMediaManifest.media(for: "sled_push")),
        .init(id: "burpee_broad_jump", name: "Burpee Broad Jump", category: .other,
              supported: [.distance, .duration, .reps, .rpe], defaults: [.distance, .duration],
              aliases: ["burpee broad jump", "burpee broad jumps", "broad jump burpee"],
              media: ExerciseMediaManifest.media(for: "burpee_broad_jump")),
        .init(id: "sandbag_lunge", name: "Sandbag Lunge", category: .strength,
              supported: [.distance, .load, .duration, .reps, .rpe], defaults: [.distance, .load, .duration],
              aliases: ["sandbag lunge", "sandbag lunges", "weighted walking lunge"],
              media: ExerciseMediaManifest.media(for: "sandbag_lunge")),
        .init(id: "wall_balls", name: "Wall Balls", category: .strength,
              supported: [.reps, .load, .duration, .rpe], defaults: [.reps, .load],
              aliases: ["wall balls", "wall ball", "wall-ball shots"],
              media: ExerciseMediaManifest.media(for: "wall_balls")),
        .init(id: "farmers_carry", name: "Farmers Carry", category: .carry,
              supported: [.distance, .load, .duration, .rpe], defaults: [.distance, .load],
              aliases: ["farmers carry", "farmer carry", "farmer's carry", "kettlebell farmers carry"],
              media: ExerciseMediaManifest.media(for: "farmers_carry")),
        .init(id: "loaded_carry", name: "Loaded Carry", category: .carry,
              supported: [.distance, .load, .duration],
              defaults: [.distance, .load],
              aliases: ["loaded carry", "overhead carry", "suitcase carry"]),
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
