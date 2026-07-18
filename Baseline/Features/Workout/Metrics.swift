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

    /// Display units the athlete can choose between (canonical first). Single-entry = not convertible.
    var displayUnits: [MetricUnit] {
        switch self {
        case .distance: [.meters, .kilometers, .miles]
        case .load: [.kilograms, .pounds]
        case .duration, .heartRateZoneTime: [.seconds, .minutes]
        default: [canonicalUnit]
        }
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

    /// The display unit this system implies for a convertible metric, or nil for metrics that have a
    /// single display unit (reps, RPE, …) or that this system doesn't reframe (duration stays as-is).
    func defaultUnit(for metric: MetricType) -> MetricUnit? {
        switch metric {
        case .load: self == .imperial ? .pounds : .kilograms
        case .distance: self == .imperial ? .miles : .kilometers
        default: nil
        }
    }
}

enum MetricUnit: String, Codable, Sendable {
    case count, kilograms, pounds, meters, kilometers, miles, seconds, minutes, kcal, bpm, rpm, watts, secondsPerMeter, rpe

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
        case .rpe: ""
        }
    }
}

/// Canonical ↔ display conversion. Only distance and load have multiple units; everything else is 1:1.
enum MetricConvert {
    static let metersPerMile = 1609.344
    static let metersPerKilometer = 1000.0
    static let kgPerPound = 0.45359237

    /// Convert a canonical value into a display unit.
    static func fromCanonical(_ value: Double, _ metric: MetricType, to unit: MetricUnit) -> Double {
        switch (metric.canonicalUnit, unit) {
        case (.meters, .kilometers): value / metersPerKilometer
        case (.meters, .miles): value / metersPerMile
        case (.kilograms, .pounds): value / kgPerPound
        case (.seconds, .minutes): value / 60
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
