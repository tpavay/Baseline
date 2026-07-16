import Foundation

/// The intrinsic classification axes of an exercise — what it works, how the body does it, what gear it
/// needs. Deliberately **intent-free**: strength vs hypertrophy is programming (the prescription), never a
/// property of the movement. See docs and the taxonomy plan. Each axis is a small closed enum so the
/// compiler enforces exhaustiveness and nothing falls through a default.

// MARK: - Muscles

/// Which side of a front/back body silhouette a muscle shades in the distribution heatmap.
enum MuscleRegion: String, Codable, Sendable, CaseIterable {
    case anterior      // front of the body
    case posterior     // back of the body
    case systemic      // whole-body / no single location (e.g. Full body)
}

/// The muscle a movement trains. 22 values — the industry-standard 17 plus obliques, hip flexors, and a
/// three-way deltoid split, so a distribution view can surface front/back and push/pull imbalances the
/// coarse standard hides. Optional on an exercise: cardio movements have none.
enum Muscle: String, Codable, Sendable, CaseIterable, Hashable {
    case abdominals
    case abductors
    case adductors
    case biceps
    case calves
    case chest
    case forearms
    case frontDelts
    case fullBody
    case glutes
    case hamstrings
    case hipFlexors
    case lats
    case lowerBack
    case neck
    case obliques
    case quadriceps
    case rearDelts
    case sideDelts
    case traps
    case triceps
    case upperBack

    var displayName: String {
        switch self {
        case .abdominals: "Abdominals"
        case .abductors: "Abductors"
        case .adductors: "Adductors"
        case .biceps: "Biceps"
        case .calves: "Calves"
        case .chest: "Chest"
        case .forearms: "Forearms"
        case .frontDelts: "Front delts"
        case .fullBody: "Full body"
        case .glutes: "Glutes"
        case .hamstrings: "Hamstrings"
        case .hipFlexors: "Hip flexors"
        case .lats: "Lats"
        case .lowerBack: "Lower back"
        case .neck: "Neck"
        case .obliques: "Obliques"
        case .quadriceps: "Quadriceps"
        case .rearDelts: "Rear delts"
        case .sideDelts: "Side delts"
        case .traps: "Traps"
        case .triceps: "Triceps"
        case .upperBack: "Upper back"
        }
    }

    /// The silhouette side this muscle shades. A muscle wraps the body, but for a front/back heatmap each
    /// gets one primary side; `fullBody` washes across everything.
    var region: MuscleRegion {
        switch self {
        case .chest, .abdominals, .obliques, .hipFlexors, .quadriceps,
             .frontDelts, .sideDelts, .biceps, .forearms, .neck, .adductors:
            .anterior
        case .upperBack, .lats, .traps, .lowerBack, .rearDelts, .triceps,
             .glutes, .hamstrings, .calves, .abductors:
            .posterior
        case .fullBody:
            .systemic
        }
    }
}

// MARK: - Movement pattern

/// How the body organizes the effort — a richer replacement for the databases' push/pull/static "force."
/// An exercise carries 1–2 (a thruster is `.squat` + `.push`); pure cyclic cardio (a bike) carries none.
enum MovementPattern: String, Codable, Sendable, CaseIterable {
    case squat
    case hinge
    case lunge
    case push
    case pull
    case carry
    case rotation
    case gait      // bipedal locomotion: run / walk / treadmill (NOT cycling)
    case hold      // static / isometric

    var displayName: String {
        switch self {
        case .squat: "Squat"
        case .hinge: "Hinge"
        case .lunge: "Lunge"
        case .push: "Push"
        case .pull: "Pull"
        case .carry: "Carry"
        case .rotation: "Rotation"
        case .gait: "Gait"
        case .hold: "Hold"
        }
    }
}

// MARK: - Equipment

/// The gear a movement needs. Names the apparatus — the axis every exercise database has and Baseline
/// lacked. Cardio machines are kept specific (Bike / Rower / Treadmill…) rather than a generic "machine",
/// so "how much did I bike this week" is a one-line filter. `bike` covers stationary / outdoor / echo /
/// bike-erg — all "a bike" for time totals; finer differences live on the exercise identity + metrics.
enum Equipment: String, Codable, Sendable, CaseIterable {
    case barbell
    case dumbbell
    case kettlebell
    case cable
    case machine
    case bodyweight
    case band
    case medicineBall
    case ezBar
    case bench
    case sled
    case sandbag
    case box
    case jumpRope
    case trapBar
    case pullUpBar
    case bike
    case rower
    case skiErg
    case treadmill
    case stairStepper
    case elliptical
    case other

    var displayName: String {
        switch self {
        case .barbell: "Barbell"
        case .dumbbell: "Dumbbell"
        case .kettlebell: "Kettlebell"
        case .cable: "Cable"
        case .machine: "Machine"
        case .bodyweight: "Bodyweight"
        case .band: "Band"
        case .medicineBall: "Medicine ball"
        case .ezBar: "EZ-bar"
        case .bench: "Bench"
        case .sled: "Sled"
        case .sandbag: "Sandbag"
        case .box: "Box"
        case .jumpRope: "Jump rope"
        case .trapBar: "Trap bar"
        case .pullUpBar: "Pull-up bar"
        case .bike: "Bike"
        case .rower: "Rower"
        case .skiErg: "Ski erg"
        case .treadmill: "Treadmill"
        case .stairStepper: "Stair stepper"
        case .elliptical: "Elliptical"
        case .other: "Other"
        }
    }
}

// MARK: - Modality

/// What kind of training a movement is. An explicit field (not derived) so cardio is first-class and
/// totalable — "142 min of cardio this week" is the sum of logged duration where `modality == .cardio`.
enum Modality: String, Codable, Sendable, CaseIterable {
    case resistance
    case cardio
    case hold        // static / isometric holds (plank, wall sit)
    case mobility

    var displayName: String {
        switch self {
        case .resistance: "Resistance"
        case .cardio: "Cardio"
        case .hold: "Hold"
        case .mobility: "Mobility"
        }
    }
}

// MARK: - Mechanic

/// Single-joint isolation vs multi-joint compound. Straight from ExRx / the Free Exercise DB.
enum Mechanic: String, Codable, Sendable, CaseIterable {
    case compound
    case isolation

    var displayName: String {
        switch self {
        case .compound: "Compound"
        case .isolation: "Isolation"
        }
    }
}

// MARK: - Level

/// Difficulty. Inherited from the seed dataset on import; a sensible default from equipment/mechanic for
/// hand-authored exercises. Never a grade Baseline invents on its own.
enum ExerciseLevel: String, Codable, Sendable, CaseIterable {
    case beginner
    case intermediate
    case expert

    var displayName: String {
        switch self {
        case .beginner: "Beginner"
        case .intermediate: "Intermediate"
        case .expert: "Expert"
        }
    }
}

// MARK: - Discipline tags

/// Cross-cutting discipline labels — what a movement is "for", spanning categories. Non-exclusive and
/// never about mechanics or measurement. This is where HYROX lives (it spans running, ergs, sleds, etc.).
enum ExerciseTag: String, Codable, Sendable, CaseIterable {
    case hyrox
    case olympicWeightlifting
    case powerlifting
    case calisthenics
    case plyometric
    case mobility
    case strongman

    var displayName: String {
        switch self {
        case .hyrox: "HYROX"
        case .olympicWeightlifting: "Olympic weightlifting"
        case .powerlifting: "Powerlifting"
        case .calisthenics: "Calisthenics"
        case .plyometric: "Plyometric"
        case .mobility: "Mobility"
        case .strongman: "Strongman"
        }
    }
}
