import Foundation

/// The **typed metric system** — one abstraction for every loggable quantity, so the model never
/// grows another ad-hoc `distance`/`calories`/`cadence` field. A set stores `MetricValues` in
/// **canonical units**; display units convert at read time so switching miles↔km never corrupts
/// history. See docs/engine-and-data-model.md ("Exercise identity, metrics, and units").
enum MetricType: String, Codable, Sendable, CaseIterable {
    case reps, load, duration, distance, calories, heartRate, heartRateZoneTime, cadence, power, pace, rpe

    /// The unit values are always stored in.
    var canonicalUnit: MetricUnit {
        switch self {
        case .reps: .count
        case .load: .kilograms
        case .duration, .heartRateZoneTime: .seconds
        case .distance: .meters
        case .calories: .kcal
        case .heartRate: .bpm
        case .cadence: .rpm
        case .power: .watts
        case .pace: .secondsPerMeter
        case .rpe: .rpe
        }
    }

    /// Display units the athlete can choose between. Single-entry = not convertible.
    ///
    /// Pace deliberately does **not** offer its canonical `s/m`: nobody reads a pace that way. The
    /// two offered forms are the ones athletes speak — minutes per kilometer and per mile.
    var displayUnits: [MetricUnit] {
        switch self {
        case .distance: [.meters, .kilometers, .miles]
        case .load: [.kilograms, .pounds]
        case .duration, .heartRateZoneTime: [.seconds, .minutes]
        case .pace: [.secondsPerKilometer, .secondsPerMile]
        default: [canonicalUnit]
        }
    }

    /// Units a value may arrive **in**, from imported text or an agent tool argument. Wider than the
    /// display choices on purpose: a source is entitled to state a pace as `s/m` even though the app
    /// would never show one back. Parsing what the world writes and choosing what the athlete reads
    /// are different questions, and conflating them made an import reject its own canonical unit.
    var parsableUnits: [MetricUnit] {
        displayUnits.contains(canonicalUnit) ? displayUnits : displayUnits + [canonicalUnit]
    }

    var label: String {
        switch self {
        case .reps: "Reps"
        case .load: "Load"
        case .duration: "Duration"
        case .distance: "Distance"
        case .calories: "Calories"
        case .heartRate: "Avg HR"
        case .heartRateZoneTime: "Zone time"
        case .cadence: "Cadence"
        case .power: "Power"
        case .pace: "Pace"
        case .rpe: "RPE"
        }
    }

    /// Whole-number metrics (no decimals) for input/formatting.
    var isInteger: Bool {
        switch self { case .reps, .duration, .heartRate, .heartRateZoneTime, .cadence: true; default: false }
    }
}

/// Whether a distance in this kind of work is course-length or floor-length. It is the whole reason
/// distance cannot have one answer per unit system: a 5 km run and a 20 m sled push are the same
/// metric, and an athlete reads them in different units on the same screen.
enum DistanceContext: Sendable {
    /// Runs, rides, rows — the athlete's system decides (km ↔ mi).
    case endurance
    /// Sleds, carries, strength work — meters in **both** systems. A 20 m sled push is 20 m to
    /// everyone; "0.01 mi" is not a distance any athlete has ever programmed.
    case floor
}

extension ActivityCategory {
    /// Endurance is the closed, unambiguous set: the three cardio modalities. Everything else —
    /// including `other`, which is what an uncatalogued movement resolves to — is floor work, so an
    /// unmatched import can never render a sled push in miles. Meters on a long effort is merely
    /// verbose; miles on a sled is wrong, and wrong is what was reported.
    var distanceContext: DistanceContext {
        switch self {
        case .cycling, .running, .erg: .endurance
        case .strength, .carry, .isometric, .other: .floor
        }
    }
}

/// The athlete's coarse imperial/metric preference. A single onboarding choice that seeds sensible
/// per-dimension display-unit defaults (imperial → lb + mi, metric → kg + km); duration is unaffected
/// and every default stays overridable per exercise. Storage is always canonical (see `MetricValues`);
/// this only chooses how values are *shown*.
enum UnitSystem: String, Codable, Sendable, CaseIterable {
    case metric, imperial

    /// The initial default for an athlete who hasn't chosen yet — inferred from the device locale
    /// (US and the few other imperial locales → imperial), always user-overridable afterwards.
    static var localeDefault: UnitSystem {
        Locale.current.measurementSystem == .metric ? .metric : .imperial
    }

    /// **The one door every display path goes through**, and the only place the category rule lives —
    /// views ask this, they never re-derive it.
    ///
    /// The approved policy, in full:
    /// - load — kg (metric) / lb (imperial)
    /// - endurance distance — km (metric) / mi (imperial)
    /// - floor distance (sled, carry, strength) — **meters in both systems**
    /// - pace — min/km (metric) / min/mi (imperial)
    /// - everything else has one unit and this returns it
    ///
    /// This is the *default*. A stored per-exercise or per-instance choice overrides it, which is how
    /// the metrics picker's "Distance mi" and a specific sled's "20 m" both hold on the same screen —
    /// see `WorkoutStore.displayUnit(_:for:)` for the full resolution order.
    ///
    /// `exercise` is nil where there is genuinely no exercise in hand — weekly aggregates, group
    /// totals — which reads as endurance, the sense those surfaces sum in. Nothing in a display path
    /// may reach for `canonicalUnit` itself; see `UnitSystemReachTests`.
    func displayUnit(metric: MetricType, exercise: ExerciseDefinition?) -> MetricUnit {
        switch metric {
        case .load:
            return self == .imperial ? .pounds : .kilograms
        case .distance:
            switch exercise?.category.distanceContext ?? .endurance {
            case .floor: return .meters
            case .endurance: return self == .imperial ? .miles : .kilometers
            }
        case .pace:
            return self == .imperial ? .secondsPerMile : .secondsPerKilometer
        default:
            return metric.canonicalUnit
        }
    }
}

/// The **single owner** of the athlete's imperial/metric choice, read through rather than copied.
/// `AppSettings` is the only conformer that stores it; every display surface holds a reference to a
/// source instead of its own `UnitSystem`, so no surface can drift out of step with the setting.
/// Injected (never a singleton), and required at construction so a new surface cannot forget it.
@MainActor
protocol UnitSystemSource: AnyObject {
    var unitSystem: UnitSystem { get }
}

enum MetricUnit: String, Codable, Sendable {
    case count, kilograms, pounds, meters, kilometers, miles, seconds, minutes, kcal, bpm, rpm, watts
    case secondsPerMeter, secondsPerKilometer, secondsPerMile, rpe

    var short: String {
        switch self {
        case .count: ""
        case .kilograms: "kg"
        case .pounds: "lb"
        case .meters: "m"
        case .kilometers: "km"
        case .miles: "mi"
        case .seconds: "s"
        case .minutes: "min"
        case .kcal: "cal"
        case .bpm: "bpm"
        case .rpm: "rpm"
        case .watts: "W"
        case .secondsPerMeter: "s/m"
        case .secondsPerKilometer: "/km"
        case .secondsPerMile: "/mi"
        case .rpe: ""
        }
    }
}

/// Canonical ↔ display conversion. Only distance and load have multiple units; everything else is 1:1.
enum MetricConvert {
    static let metersPerMile = 1609.344
    static let metersPerKilometer = 1000.0
    static let kgPerPound = 0.45359237
    /// Body height is not a `MetricType`, but its conversion belongs here with the others so the
    /// onboarding ruler cannot drift from the rest of the app.
    static let cmPerInch = 2.54

    /// Convert a canonical value into a display unit.
    static func fromCanonical(_ value: Double, _ metric: MetricType, to unit: MetricUnit) -> Double {
        switch (metric.canonicalUnit, unit) {
        case (.meters, .kilometers): value / metersPerKilometer
        case (.meters, .miles): value / metersPerMile
        case (.kilograms, .pounds): value / kgPerPound
        case (.seconds, .minutes): value / 60
        // Pace inverts: seconds *per meter* becomes seconds per a longer distance, so it multiplies.
        case (.secondsPerMeter, .secondsPerKilometer): value * metersPerKilometer
        case (.secondsPerMeter, .secondsPerMile): value * metersPerMile
        default: value   // same unit or non-convertible
        }
    }

    /// Convert a display value back into the canonical unit (for storage).
    static func toCanonical(_ value: Double, _ metric: MetricType, from unit: MetricUnit) -> Double {
        switch (unit, metric.canonicalUnit) {
        case (.kilometers, .meters): value * metersPerKilometer
        case (.miles, .meters): value * metersPerMile
        case (.pounds, .kilograms): value * kgPerPound
        case (.minutes, .seconds): value * 60
        case (.secondsPerKilometer, .secondsPerMeter): value / metersPerKilometer
        case (.secondsPerMile, .secondsPerMeter): value / metersPerMile
        default: value
        }
    }
}

/// A set's values, keyed by metric, stored canonically. Encodes as a `{ "distance": 1000 }` object.
struct MetricValues: Codable, Equatable, Sendable {
    private var storage: [MetricType: Double]

    init(_ storage: [MetricType: Double] = [:]) { self.storage = storage }

    subscript(_ metric: MetricType) -> Double? {
        get { storage[metric] }
        set { storage[metric] = newValue }
    }

    func int(_ metric: MetricType) -> Int? { storage[metric].map { Int($0.rounded()) } }
    mutating func setInt(_ metric: MetricType, _ value: Int?) { storage[metric] = value.map(Double.init) }

    /// Metrics that actually have a value (in canonical order).
    var present: [MetricType] { MetricType.allCases.filter { storage[$0] != nil } }
    var isEmpty: Bool { storage.isEmpty }

    /// A copy keeping only values whose metric is in `allowed`. Used when a movement is replaced with
    /// one whose schema differs: a value is just a number under a key with no schema tag, so a lift's
    /// `reps`/`load` would otherwise linger on a cardio exercise and resurface wherever columns are
    /// derived from which values are present. Sanitizing at the swap keeps the data honest to the
    /// movement that owns it.
    func retainingOnly(_ allowed: Set<MetricType>) -> MetricValues {
        MetricValues(storage.filter { allowed.contains($0.key) })
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Double].self)
        storage = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            MetricType(rawValue: key).map { ($0, value) }
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: storage.map { ($0.key.rawValue, $0.value) }))
    }
}

enum ActivityCategory: String, Codable, Sendable, CaseIterable {
    case cycling, running, erg, strength, carry, isometric, other

    /// SF Symbol standing in for an exercise thumbnail until real media exists.
    var glyph: String {
        switch self {
        case .cycling: "bicycle"
        case .running: "figure.run"
        case .erg: "figure.rower"
        case .strength: "dumbbell.fill"
        case .carry: "figure.walk"
        case .isometric: "figure.core.training"
        case .other: "figure.strengthtraining.functional"
        }
    }
}
