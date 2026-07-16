import Foundation
import os

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

    // Intent-free classification axes (see ExerciseTaxonomy.swift). Optional/empty by default; the built-in
    // catalog is backfilled below and custom exercises set them at creation. `category` is retained for now
    // and retired in a later pass once these axes are proven.
    let primaryMuscles: [Muscle]
    let secondaryMuscles: [Muscle]
    let patterns: [MovementPattern]     // 1–2 for compounds; empty for pure cyclic cardio
    let equipment: [Equipment]
    let mechanic: Mechanic?
    let modality: Modality?
    let level: ExerciseLevel?
    let tags: [ExerciseTag]

    init(
        id: String,
        name: String,
        category: ActivityCategory,
        supported: [MetricType],
        defaults: [MetricType],
        aliases: [String],
        media: ExerciseMedia? = nil,
        primaryMuscles: [Muscle] = [],
        secondaryMuscles: [Muscle] = [],
        patterns: [MovementPattern] = [],
        equipment: [Equipment] = [],
        mechanic: Mechanic? = nil,
        modality: Modality? = nil,
        level: ExerciseLevel? = nil,
        tags: [ExerciseTag] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.supported = supported
        self.defaults = defaults
        self.aliases = aliases
        self.media = media
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.patterns = patterns
        self.equipment = equipment
        self.mechanic = mechanic
        self.modality = modality
        self.level = level
        self.tags = tags
    }

    // Decode tolerantly: the new axes default when absent so older catalogs/fixtures still decode. (Stored
    // custom definitions predating these fields are allowed to reset — the app is pre-release.)
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(ActivityCategory.self, forKey: .category)
        supported = try c.decode([MetricType].self, forKey: .supported)
        defaults = try c.decode([MetricType].self, forKey: .defaults)
        aliases = try c.decode([String].self, forKey: .aliases)
        media = try c.decodeIfPresent(ExerciseMedia.self, forKey: .media)
        primaryMuscles = try c.decodeIfPresent([Muscle].self, forKey: .primaryMuscles) ?? []
        secondaryMuscles = try c.decodeIfPresent([Muscle].self, forKey: .secondaryMuscles) ?? []
        patterns = try c.decodeIfPresent([MovementPattern].self, forKey: .patterns) ?? []
        equipment = try c.decodeIfPresent([Equipment].self, forKey: .equipment) ?? []
        mechanic = try c.decodeIfPresent(Mechanic.self, forKey: .mechanic)
        modality = try c.decodeIfPresent(Modality.self, forKey: .modality)
        level = try c.decodeIfPresent(ExerciseLevel.self, forKey: .level)
        tags = try c.decodeIfPresent([ExerciseTag].self, forKey: .tags) ?? []
    }
}

/// A small curated catalog — enough to prove the metric model across real workouts before designing
/// every modality. Unknown movements resolve to a generic definition rather than failing.
/// The classification of a built-in exercise, kept as a separate id-keyed table so the definition list
/// stays focused on identity + logging and the taxonomy (the reviewed backfill) reads as one block.
struct ExerciseClassification {
    var primary: [Muscle] = []
    var secondary: [Muscle] = []
    var patterns: [MovementPattern] = []
    var equipment: [Equipment] = []
    var mechanic: Mechanic?
    var modality: Modality?
    var level: ExerciseLevel?
    var tags: [ExerciseTag] = []
}

extension ExerciseDefinition {
    func applying(_ c: ExerciseClassification) -> ExerciseDefinition {
        ExerciseDefinition(
            id: id, name: name, category: category, supported: supported, defaults: defaults,
            aliases: aliases, media: media,
            primaryMuscles: c.primary, secondaryMuscles: c.secondary, patterns: c.patterns,
            equipment: c.equipment, mechanic: c.mechanic, modality: c.modality, level: c.level, tags: c.tags
        )
    }
}

/// An immutable, indexed view of a set of exercise definitions. Precomputes an id index and lowercased
/// exact name/alias indices so `definition(id:)` and `resolve` stay O(1) rather than scanning the whole
/// list on every call — both are hit per row render, and the catalog is heading from ~50 to ~800 entries.
/// A value type so it can be swapped atomically under a lock (see `ExerciseCatalog`).
struct ExerciseCatalogSnapshot: Sendable {
    let definitions: [ExerciseDefinition]
    private let byID: [String: ExerciseDefinition]
    private let byName: [String: ExerciseDefinition]   // lowercased exact name → first definition in order
    private let byAlias: [String: ExerciseDefinition]  // lowercased exact alias → first definition in order

    init(_ definitions: [ExerciseDefinition]) {
        self.definitions = definitions
        var byID: [String: ExerciseDefinition] = [:]
        var byName: [String: ExerciseDefinition] = [:]
        var byAlias: [String: ExerciseDefinition] = [:]
        // First-in-list wins on any collision, matching the previous `first(where:)` scan semantics.
        for def in definitions {
            if byID[def.id] == nil { byID[def.id] = def }
            let name = def.name.lowercased()
            if byName[name] == nil { byName[name] = def }
            for alias in def.aliases where byAlias[alias] == nil { byAlias[alias] = def }
        }
        self.byID = byID
        self.byName = byName
        self.byAlias = byAlias
    }

    func definition(id: String) -> ExerciseDefinition? { byID[id] }

    /// Resolve casual language → a definition: exact name, then exact alias, then substring, else `generic`.
    func resolve(_ name: String, generic: ExerciseDefinition) -> ExerciseDefinition {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return generic }
        if let exact = byName[key] { return exact }
        if let alias = byAlias[key] { return alias }
        if let fuzzy = definitions.first(where: { def in
            def.aliases.contains(where: { key.contains($0) || $0.contains(key) })
        }) { return fuzzy }
        return generic
    }
}

enum ExerciseCatalog {
    /// The catalog blob schema this build understands. A fetched catalog whose `schemaVersion` differs is
    /// rejected (the app keeps its current catalog) rather than decoded into a shape the code can't trust.
    static let supportedSchemaVersion = 1

    /// The live catalog, swappable behind a lock. Defaults to the bundled seed; a fetched catalog is
    /// installed at startup/refresh via `install(_:)` (Slice 2). An unfair lock is right here: reads are
    /// frequent and cheap, writes are rare (app launch and occasional refresh). Readers see a new snapshot
    /// atomically on their next call. Value-type domain models reach this façade directly, so the swap
    /// point stays here rather than being threaded through every call site.
    private static let live = OSAllocatedUnfairLock(initialState: ExerciseCatalogSnapshot(seedDefinitions))

    /// The public catalog — the current live snapshot's definitions.
    static var definitions: [ExerciseDefinition] { live.withLock { $0.definitions } }

    static func definition(id: String) -> ExerciseDefinition? { live.withLock { $0.definition(id: id) } }

    /// Resolve casual language → a definition. Never nil — unknown movements get `generic`.
    static func resolve(_ name: String) -> ExerciseDefinition {
        live.withLock { $0.resolve(name, generic: generic) }
    }

    /// Replace the live catalog with a fetched set. Thread-safe; the seed remains the compiled fallback.
    static func install(_ definitions: [ExerciseDefinition]) {
        live.withLock { $0 = ExerciseCatalogSnapshot(definitions) }
    }

    /// The bundled seed — each base definition overlaid with its classification (see `classifications`).
    /// Shipped in the binary so search, planning, logging, and import matching work offline before any fetch.
    static let seedDefinitions: [ExerciseDefinition] = baseDefinitions.map { def in
        classifications[def.id].map { def.applying($0) } ?? def
    }

    private static let baseDefinitions: [ExerciseDefinition] = [
        .init(id: "stationary_bike", name: "Stationary Bike", category: .cycling,
              supported: [.duration, .distance, .calories, .heartRate, .cadence, .power],
              defaults: [.duration, .distance],
              aliases: ["stationary bike", "spin bike", "indoor bike", "exercise bike"],
              media: ExerciseMediaManifest.media(for: "stationary_bike")),
        .init(id: "outdoor_bike", name: "Outdoor Bike", category: .cycling,
              supported: [.duration, .distance, .heartRate, .power, .cadence],
              defaults: [.duration, .distance],
              aliases: ["outdoor bike", "road bike", "cycling", "bike ride"],
              media: ExerciseMediaManifest.media(for: "outdoor_bike")),
        .init(id: "bike_erg", name: "BikeErg", category: .erg,
              supported: [.duration, .distance, .calories, .power, .pace, .cadence, .heartRate],
              defaults: [.duration, .distance, .pace, .power],
              aliases: ["bikeerg", "bike erg", "concept2 bike", "c2 bike"],
              media: ExerciseMediaManifest.media(for: "bike_erg")),
        .init(id: "echo_bike", name: "Echo Bike", category: .cycling,
              supported: [.duration, .calories, .power, .cadence, .heartRate, .rpe],
              defaults: [.duration, .calories, .heartRate],
              aliases: ["echo bike", "rogue echo bike", "assault bike", "air bike"],
              media: ExerciseMediaManifest.media(for: "echo_bike")),
        .init(id: "elliptical", name: "Elliptical", category: .other,
              supported: [.duration, .distance, .calories, .heartRate, .cadence, .rpe],
              defaults: [.duration, .distance, .heartRate],
              aliases: ["elliptical", "elliptical trainer", "cross trainer"],
              media: ExerciseMediaManifest.media(for: "elliptical")),
        .init(id: "run", name: "Run", category: .running,
              supported: [.duration, .distance, .heartRate, .pace, .cadence],
              defaults: [.duration, .distance, .pace],
              aliases: ["run", "running", "outdoor run", "road run", "track run", "jog",
                        "stride", "strides", "running stride", "running strides"],
              media: ExerciseMediaManifest.media(for: "run")),
        .init(id: "treadmill_run", name: "Treadmill Run", category: .running,
              supported: [.duration, .distance, .heartRate, .pace, .cadence],
              defaults: [.duration, .distance, .pace],
              aliases: ["treadmill run", "treadmill running", "treadmill"],
              media: ExerciseMediaManifest.media(for: "treadmill_run")),
        .init(id: "swim", name: "Swim", category: .other,
              supported: [.duration, .distance, .heartRate, .pace, .rpe],
              defaults: [.duration, .distance, .pace],
              aliases: ["swim", "swimming", "pool swim", "open water swim"]),
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
              aliases: ["deadlift", "deadlifts", "conventional deadlift"],
              media: ExerciseMediaManifest.media(for: "deadlift")),
        .init(id: "back_squat", name: "Barbell Back Squat", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["back squat", "barbell back squat", "barbell squat"],
              media: ExerciseMediaManifest.media(for: "back_squat")),
        .init(id: "front_squat", name: "Barbell Front Squat", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["front squat", "front squats", "barbell front squat"],
              media: ExerciseMediaManifest.media(for: "front_squat")),
        .init(id: "barbell_box_squat", name: "Barbell Box Squat", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["barbell box squat", "box squat", "box squats"],
              media: ExerciseMediaManifest.media(for: "barbell_box_squat")),
        .init(id: "bench_press", name: "Bench Press", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["bench press", "barbell bench press", "bench"],
              media: ExerciseMediaManifest.media(for: "bench_press")),
        .init(id: "dumbbell_bench_press", name: "Dumbbell Bench Press", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["dumbbell bench press", "db bench press", "dumbbell bench"],
              media: ExerciseMediaManifest.media(for: "dumbbell_bench_press")),
        .init(id: "dual_dumbbell_push_press", name: "Dual Dumbbell Push Press", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["dual dumbbell push press", "dual db push press", "double dumbbell push press",
                        "double db push press", "dumbbell push press", "db push press"]),
        .init(id: "barbell_overhead_press", name: "Barbell Overhead Press", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["barbell overhead press", "overhead press", "strict press",
                        "barbell strict press", "military press"],
              media: ExerciseMediaManifest.media(for: "barbell_overhead_press")),
        .init(id: "bodyweight_squat", name: "Bodyweight Squat", category: .strength,
              supported: [.reps, .duration, .rpe], defaults: [.reps, .rpe],
              aliases: ["bodyweight squat", "bodyweight squats", "air squat", "air squats", "unweighted squat"],
              media: ExerciseMediaManifest.media(for: "bodyweight_squat")),
        .init(id: "jump_squat", name: "Jump Squat", category: .strength,
              supported: [.reps, .load, .duration, .rpe], defaults: [.reps],
              aliases: ["jump squat", "jump squats", "squat jump", "squat jumps"]),
        .init(id: "push_up", name: "Push-Up", category: .strength,
              supported: [.reps, .duration, .rpe], defaults: [.reps, .rpe],
              aliases: ["push-up", "push up", "pushup"],
              media: ExerciseMediaManifest.media(for: "push_up")),
        .init(id: "dual_db_thruster", name: "Dual Dumbbell Thruster", category: .strength,
              supported: [.reps, .load, .duration, .rpe], defaults: [.reps, .load],
              aliases: ["dual db thruster", "dual db thrusters", "double dumbbell thruster", "dumbbell thrusters"],
              media: ExerciseMediaManifest.media(for: "dual_db_thruster")),
        .init(id: "box_jump", name: "Box Jump", category: .other,
              supported: [.reps, .duration, .rpe], defaults: [.reps],
              aliases: ["box jump", "box jumps"],
              media: ExerciseMediaManifest.media(for: "box_jump")),
        .init(id: "box_step_over", name: "Box Step-Over", category: .other,
              supported: [.reps, .load, .duration, .rpe], defaults: [.reps],
              aliases: ["box step-over", "box step over", "box step overs", "box stepovers"],
              media: ExerciseMediaManifest.media(for: "box_step_over")),
        .init(id: "burpee_to_plate", name: "Burpee to Plate", category: .other,
              supported: [.reps, .duration, .rpe], defaults: [.reps, .duration],
              aliases: ["burpee to plate", "burpees to plate", "plate burpee", "burpee plate jump"],
              media: ExerciseMediaManifest.media(for: "burpee_to_plate")),
        .init(id: "hand_release_push_up", name: "Hand-Release Push-Up", category: .strength,
              supported: [.reps, .duration, .rpe], defaults: [.reps, .rpe],
              aliases: ["hand-release push-up", "hand release push up", "hand release push ups",
                        "hand release pushups", "hrpu"],
              media: ExerciseMediaManifest.media(for: "hand_release_push_up")),
        .init(id: "pull_up", name: "Pull-Up", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .rpe],
              aliases: ["pull-up", "pull up", "pullup"],
              media: ExerciseMediaManifest.media(for: "pull_up")),
        .init(id: "single_arm_dumbbell_row", name: "Single-Arm Dumbbell Row", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["single-arm dumbbell row", "single arm dumbbell row",
                        "one-arm dumbbell row", "one arm dumbbell row", "single arm db row"],
              media: ExerciseMediaManifest.media(for: "single_arm_dumbbell_row")),
        .init(id: "sled_push", name: "Sled Push", category: .strength,
              supported: [.distance, .load, .duration, .rpe], defaults: [.distance, .load, .duration],
              aliases: ["sled push", "prowler push"],
              media: ExerciseMediaManifest.media(for: "sled_push")),
        .init(id: "sled_pull", name: "Sled Pull", category: .strength,
              supported: [.distance, .load, .duration, .rpe], defaults: [.distance, .load, .duration],
              aliases: ["sled pull", "rope sled pull", "hyrox sled pull"],
              media: ExerciseMediaManifest.media(for: "sled_pull")),
        .init(id: "burpee_broad_jump", name: "Burpee Broad Jump", category: .other,
              supported: [.distance, .duration, .reps, .rpe], defaults: [.distance, .duration],
              aliases: ["burpee broad jump", "burpee broad jumps", "broad jump burpee"],
              media: ExerciseMediaManifest.media(for: "burpee_broad_jump")),
        .init(id: "lateral_burpee_over_barbell", name: "Lateral Burpee Over Barbell", category: .other,
              supported: [.reps, .duration, .rpe], defaults: [.reps, .duration],
              aliases: ["lateral burpee over barbell", "lateral burpees over barbell",
                        "lateral burpee over bar", "lateral burpees over bar", "lateral barbell burpee",
                        "burpees over barbell lateral"],
              media: ExerciseMediaManifest.media(for: "lateral_burpee_over_barbell")),
        .init(id: "sandbag_lunge", name: "Sandbag Lunge", category: .strength,
              supported: [.distance, .load, .duration, .reps, .rpe], defaults: [.distance, .load, .duration],
              aliases: ["sandbag lunge", "sandbag lunges", "weighted walking lunge"],
              media: ExerciseMediaManifest.media(for: "sandbag_lunge")),
        .init(id: "bodyweight_walking_lunge", name: "Bodyweight Walking Lunge", category: .strength,
              supported: [.reps, .distance, .duration, .rpe], defaults: [.reps, .rpe],
              aliases: ["bodyweight walking lunge", "bodyweight walking lunges",
                        "unweighted walking lunge", "walking lunge", "walking lunges"],
              media: ExerciseMediaManifest.media(for: "bodyweight_walking_lunge")),
        .init(id: "dumbbell_walking_lunge", name: "Dumbbell Walking Lunge", category: .strength,
              supported: [.reps, .distance, .load, .duration, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["dumbbell walking lunge", "dumbbell walking lunges", "db walking lunge",
                        "db walking lunges", "dumbbell lunge", "dumbbell lunges"],
              media: ExerciseMediaManifest.media(for: "dumbbell_walking_lunge")),
        .init(id: "barbell_walking_lunge", name: "Barbell Walking Lunge", category: .strength,
              supported: [.reps, .distance, .load, .duration, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["barbell walking lunge", "barbell walking lunges",
                        "barbell lunge", "barbell lunges"],
              media: ExerciseMediaManifest.media(for: "barbell_walking_lunge")),
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
        .init(id: "leg_press", name: "Leg Press", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["leg press", "45 degree leg press", "sled leg press"],
              media: ExerciseMediaManifest.media(for: "leg_press")),
        .init(id: "calf_raise", name: "Standing Calf Raise", category: .strength,
              supported: [.reps, .load, .duration, .rpe], defaults: [.reps, .load],
              aliases: ["standing calf raise", "calf raise", "calf raises", "heel raise"],
              media: ExerciseMediaManifest.media(for: "calf_raise")),
        .init(id: "goblet_squat", name: "Goblet Squat", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["goblet squat", "goblet squats", "kettlebell goblet squat"],
              media: ExerciseMediaManifest.media(for: "goblet_squat")),
        .init(id: "kettlebell_swing", name: "Kettlebell Swing", category: .strength,
              supported: [.reps, .load, .duration, .rpe], defaults: [.reps, .load],
              aliases: ["kettlebell swing", "kettlebell swings", "kb swing", "kb swings"],
              media: ExerciseMediaManifest.media(for: "kettlebell_swing")),
        .init(id: "medicine_ball_slam", name: "Medicine Ball Slam", category: .strength,
              supported: [.reps, .load, .duration, .rpe], defaults: [.reps, .load],
              aliases: ["medicine ball slam", "medicine ball slams", "med ball slam",
                        "med ball slams", "ball slam", "ball slams"],
              media: ExerciseMediaManifest.media(for: "medicine_ball_slam")),
        .init(id: "barbell_hip_thrust", name: "Barbell Hip Thrust", category: .strength,
              supported: [.reps, .load, .rpe], defaults: [.reps, .load, .rpe],
              aliases: ["barbell hip thrust", "barbell hip thrusts", "weighted hip thrust",
                        "hip thrust", "hip thrusts"],
              media: ExerciseMediaManifest.media(for: "barbell_hip_thrust")),
        .init(id: "bodyweight_hip_thrust", name: "Bodyweight Hip Thrust", category: .strength,
              supported: [.reps, .duration, .rpe], defaults: [.reps, .rpe],
              aliases: ["bodyweight hip thrust", "bodyweight hip thrusts", "unweighted hip thrust"],
              media: ExerciseMediaManifest.media(for: "bodyweight_hip_thrust")),
        .init(id: "single_leg_hip_thrust", name: "Single-Leg Hip Thrust", category: .strength,
              supported: [.reps, .duration, .rpe], defaults: [.reps, .rpe],
              aliases: ["single-leg hip thrust", "single leg hip thrust",
                        "single-leg hip thrusts", "single leg hip thrusts"],
              media: ExerciseMediaManifest.media(for: "single_leg_hip_thrust")),
        .init(id: "hanging_leg_raise", name: "Hanging Leg Raise", category: .strength,
              supported: [.reps, .duration, .rpe], defaults: [.reps, .rpe],
              aliases: ["hanging leg raise", "hanging leg raises", "straight leg raise hanging"],
              media: ExerciseMediaManifest.media(for: "hanging_leg_raise")),
        .init(id: "plank", name: "Forearm Plank", category: .isometric,
              supported: [.duration, .load, .rpe], defaults: [.duration, .rpe],
              aliases: ["forearm plank", "plank", "front plank", "elbow plank"],
              media: ExerciseMediaManifest.media(for: "plank")),
        .init(id: "stair_stepper", name: "Stair Stepper", category: .other,
              supported: [.duration, .calories, .heartRate, .rpe],
              defaults: [.duration, .heartRate],
              aliases: ["stair stepper", "stair climber", "stairmaster", "stepmill", "stairmill"],
              media: ExerciseMediaManifest.media(for: "stair_stepper")),
        .init(id: "isometric_hold", name: "Isometric Hold", category: .isometric,
              supported: [.duration, .load, .rpe],
              defaults: [.duration, .load, .rpe],
              aliases: ["isometric hold", "isometric", "hold", "copenhagen"]),
    ]

    /// Reviewed classification for every built-in (the taxonomy backfill). Cardio movements carry no
    /// muscles and usually no strength pattern; carries are resistance; genuinely systemic movements use
    /// `.fullBody`. Levels are sensible defaults (a later Free-DB import inherits the DB's grade instead).
    private static let classifications: [String: ExerciseClassification] = [
        // Cardio
        "stationary_bike": .init(equipment: [.bike], modality: .cardio, level: .beginner),
        "outdoor_bike": .init(equipment: [.bike], modality: .cardio, level: .beginner),
        "bike_erg": .init(equipment: [.bike], modality: .cardio, level: .beginner),
        "echo_bike": .init(equipment: [.bike], modality: .cardio, level: .beginner),
        "elliptical": .init(patterns: [.gait], equipment: [.elliptical], modality: .cardio, level: .beginner),
        "run": .init(patterns: [.gait], modality: .cardio, level: .beginner),
        "treadmill_run": .init(patterns: [.gait], equipment: [.treadmill], modality: .cardio, level: .beginner),
        "swim": .init(modality: .cardio, level: .beginner),
        "ski_erg": .init(primary: [.lats, .upperBack], patterns: [.pull, .hinge], equipment: [.skiErg],
                         modality: .cardio, level: .beginner, tags: [.hyrox]),
        "row": .init(primary: [.lats, .upperBack, .hamstrings], patterns: [.hinge, .pull], equipment: [.rower],
                     modality: .cardio, level: .beginner, tags: [.hyrox]),
        "stair_stepper": .init(primary: [.quadriceps, .glutes], patterns: [.gait], equipment: [.stairStepper],
                               modality: .cardio, level: .beginner),
        // Resistance
        "deadlift": .init(primary: [.glutes, .hamstrings, .lowerBack], secondary: [.quadriceps, .traps, .forearms],
                          patterns: [.hinge], equipment: [.barbell], mechanic: .compound, modality: .resistance,
                          level: .intermediate, tags: [.powerlifting]),
        "back_squat": .init(primary: [.quadriceps, .glutes], secondary: [.hamstrings, .lowerBack, .abdominals],
                            patterns: [.squat], equipment: [.barbell], mechanic: .compound, modality: .resistance,
                            level: .intermediate, tags: [.powerlifting]),
        "front_squat": .init(primary: [.quadriceps, .glutes], secondary: [.upperBack, .abdominals],
                             patterns: [.squat], equipment: [.barbell], mechanic: .compound, modality: .resistance,
                             level: .intermediate),
        "barbell_box_squat": .init(primary: [.quadriceps, .glutes], secondary: [.hamstrings, .lowerBack],
                                   patterns: [.squat], equipment: [.barbell], mechanic: .compound, modality: .resistance,
                                   level: .intermediate, tags: [.powerlifting]),
        "bench_press": .init(primary: [.chest, .triceps, .frontDelts], secondary: [.sideDelts],
                             patterns: [.push], equipment: [.barbell, .bench], mechanic: .compound, modality: .resistance,
                             level: .intermediate, tags: [.powerlifting]),
        "dumbbell_bench_press": .init(primary: [.chest, .triceps, .frontDelts], patterns: [.push],
                                      equipment: [.dumbbell, .bench], mechanic: .compound, modality: .resistance,
                                      level: .beginner),
        "dual_dumbbell_push_press": .init(primary: [.frontDelts, .triceps], secondary: [.quadriceps, .glutes],
                                          patterns: [.push], equipment: [.dumbbell], mechanic: .compound,
                                          modality: .resistance, level: .intermediate),
        "barbell_overhead_press": .init(primary: [.frontDelts, .triceps], secondary: [.sideDelts, .traps, .abdominals],
                                        patterns: [.push], equipment: [.barbell], mechanic: .compound,
                                        modality: .resistance, level: .intermediate),
        "bodyweight_squat": .init(primary: [.quadriceps, .glutes], secondary: [.hamstrings], patterns: [.squat],
                                  equipment: [.bodyweight], mechanic: .compound, modality: .resistance,
                                  level: .beginner, tags: [.calisthenics]),
        "jump_squat": .init(primary: [.quadriceps, .glutes, .calves], secondary: [.hamstrings], patterns: [.squat],
                            equipment: [.bodyweight], mechanic: .compound, modality: .resistance,
                            level: .intermediate, tags: [.plyometric]),
        "push_up": .init(primary: [.chest, .triceps, .frontDelts], secondary: [.abdominals], patterns: [.push],
                         equipment: [.bodyweight], mechanic: .compound, modality: .resistance,
                         level: .beginner, tags: [.calisthenics]),
        "dual_db_thruster": .init(primary: [.quadriceps, .glutes, .frontDelts], secondary: [.triceps, .upperBack],
                                  patterns: [.squat, .push], equipment: [.dumbbell], mechanic: .compound,
                                  modality: .resistance, level: .intermediate),
        "box_jump": .init(primary: [.quadriceps, .glutes, .calves], secondary: [.hamstrings], patterns: [.squat],
                          equipment: [.box], mechanic: .compound, modality: .resistance,
                          level: .intermediate, tags: [.plyometric]),
        "box_step_over": .init(primary: [.quadriceps, .glutes], secondary: [.hamstrings, .calves], patterns: [.lunge],
                               equipment: [.box], mechanic: .compound, modality: .resistance, level: .intermediate),
        "burpee_to_plate": .init(primary: [.fullBody], patterns: [.squat, .push], equipment: [.bodyweight],
                                 mechanic: .compound, modality: .resistance, level: .intermediate, tags: [.calisthenics]),
        "hand_release_push_up": .init(primary: [.chest, .triceps, .frontDelts], secondary: [.abdominals],
                                      patterns: [.push], equipment: [.bodyweight], mechanic: .compound,
                                      modality: .resistance, level: .beginner, tags: [.calisthenics]),
        "pull_up": .init(primary: [.lats, .upperBack, .biceps], secondary: [.forearms], patterns: [.pull],
                         equipment: [.pullUpBar], mechanic: .compound, modality: .resistance,
                         level: .intermediate, tags: [.calisthenics]),
        "single_arm_dumbbell_row": .init(primary: [.lats, .upperBack, .biceps], secondary: [.forearms, .rearDelts],
                                         patterns: [.pull], equipment: [.dumbbell], mechanic: .compound,
                                         modality: .resistance, level: .beginner),
        "sled_push": .init(primary: [.quadriceps, .glutes], secondary: [.calves, .hamstrings, .chest],
                           patterns: [.push, .gait], equipment: [.sled], mechanic: .compound, modality: .resistance,
                           level: .intermediate, tags: [.hyrox]),
        "sled_pull": .init(primary: [.lats, .upperBack, .hamstrings], secondary: [.biceps, .glutes],
                           patterns: [.pull], equipment: [.sled], mechanic: .compound, modality: .resistance,
                           level: .intermediate, tags: [.hyrox]),
        "burpee_broad_jump": .init(primary: [.fullBody], patterns: [.squat, .gait], equipment: [.bodyweight],
                                   mechanic: .compound, modality: .resistance, level: .intermediate,
                                   tags: [.hyrox, .plyometric]),
        "lateral_burpee_over_barbell": .init(primary: [.fullBody], patterns: [.squat, .push], equipment: [.bodyweight],
                                             mechanic: .compound, modality: .resistance, level: .intermediate,
                                             tags: [.plyometric]),
        "sandbag_lunge": .init(primary: [.quadriceps, .glutes], secondary: [.hamstrings, .abdominals],
                               patterns: [.lunge], equipment: [.sandbag], mechanic: .compound, modality: .resistance,
                               level: .intermediate, tags: [.hyrox]),
        "bodyweight_walking_lunge": .init(primary: [.quadriceps, .glutes], secondary: [.hamstrings], patterns: [.lunge],
                                          equipment: [.bodyweight], mechanic: .compound, modality: .resistance,
                                          level: .beginner),
        "dumbbell_walking_lunge": .init(primary: [.quadriceps, .glutes], secondary: [.hamstrings], patterns: [.lunge],
                                        equipment: [.dumbbell], mechanic: .compound, modality: .resistance,
                                        level: .intermediate),
        "barbell_walking_lunge": .init(primary: [.quadriceps, .glutes], secondary: [.hamstrings], patterns: [.lunge],
                                       equipment: [.barbell], mechanic: .compound, modality: .resistance,
                                       level: .intermediate),
        "wall_balls": .init(primary: [.quadriceps, .glutes, .frontDelts], secondary: [.obliques, .triceps],
                            patterns: [.squat, .push], equipment: [.medicineBall], mechanic: .compound,
                            modality: .resistance, level: .intermediate, tags: [.hyrox]),
        "farmers_carry": .init(primary: [.forearms, .traps], secondary: [.glutes, .abdominals, .obliques],
                               patterns: [.carry], equipment: [.dumbbell], mechanic: .compound, modality: .resistance,
                               level: .beginner, tags: [.hyrox]),
        "loaded_carry": .init(primary: [.forearms, .traps], secondary: [.abdominals, .glutes], patterns: [.carry],
                              equipment: [.dumbbell], mechanic: .compound, modality: .resistance, level: .beginner),
        "leg_press": .init(primary: [.quadriceps, .glutes], secondary: [.hamstrings], patterns: [.squat],
                           equipment: [.machine], mechanic: .compound, modality: .resistance, level: .beginner),
        "calf_raise": .init(primary: [.calves], equipment: [.machine], mechanic: .isolation, modality: .resistance,
                            level: .beginner),
        "goblet_squat": .init(primary: [.quadriceps, .glutes], secondary: [.abdominals], patterns: [.squat],
                              equipment: [.kettlebell], mechanic: .compound, modality: .resistance, level: .beginner),
        "kettlebell_swing": .init(primary: [.glutes, .hamstrings], secondary: [.lowerBack, .forearms],
                                  patterns: [.hinge], equipment: [.kettlebell], mechanic: .compound,
                                  modality: .resistance, level: .intermediate),
        "medicine_ball_slam": .init(primary: [.lats, .abdominals], secondary: [.obliques, .frontDelts],
                                    patterns: [.rotation, .hinge], equipment: [.medicineBall], mechanic: .compound,
                                    modality: .resistance, level: .beginner, tags: [.plyometric]),
        "barbell_hip_thrust": .init(primary: [.glutes, .hamstrings], secondary: [.quadriceps], patterns: [.hinge],
                                    equipment: [.barbell], mechanic: .compound, modality: .resistance,
                                    level: .intermediate),
        "bodyweight_hip_thrust": .init(primary: [.glutes], secondary: [.hamstrings], patterns: [.hinge],
                                       equipment: [.bodyweight], mechanic: .compound, modality: .resistance,
                                       level: .beginner),
        "single_leg_hip_thrust": .init(primary: [.glutes], secondary: [.hamstrings], patterns: [.hinge],
                                       equipment: [.bodyweight], mechanic: .compound, modality: .resistance,
                                       level: .intermediate),
        "hanging_leg_raise": .init(primary: [.abdominals, .hipFlexors], secondary: [.forearms],
                                   equipment: [.pullUpBar], mechanic: .isolation, modality: .resistance,
                                   level: .intermediate, tags: [.calisthenics]),
        // Hold
        "plank": .init(primary: [.abdominals], secondary: [.obliques], patterns: [.hold], equipment: [.bodyweight],
                       mechanic: .isolation, modality: .hold, level: .beginner),
        "isometric_hold": .init(patterns: [.hold], equipment: [.bodyweight], modality: .hold, level: .beginner),
    ]

    /// The fallback for movements not in the catalog — supports the common fields, defaults to none
    /// (the caller keeps whatever metrics were actually entered).
    static let generic = ExerciseDefinition(
        id: "generic", name: "Exercise", category: .other,
        supported: [.reps, .load, .duration, .distance, .calories, .rpe],
        defaults: [], aliases: [])
}
