import Foundation

/// The five live training zones shown against a heart-rate spectrum during a workout.
///
/// Baseline uses the conventional five-zone blue→red spectrum (pattern-alignment principle) so the
/// live *actual* zone can later be shown against a planned *target* zone — richer than a single
/// effort band. The zones are ordered `z1 < … < z5`; the raw value is the familiar 1…5 label.
///
/// Each zone carries a design-system color *token name* rather than a `Color`, so this type stays
/// Foundation-only. The resolved `Color` lives in `HeartRateZone+Color.swift`, and it is the one
/// ramp every heart-rate surface reads: the live gauge, the zone-settings preview, the completed
/// workout's zone card, and the trace chart's zone bands.
enum HeartRateZone: Int, CaseIterable, Comparable, Sendable {
    case z1 = 1
    case z2
    case z3
    case z4
    case z5

    /// Short label for the spectrum ("Z1"…"Z5").
    var displayName: String { "Z\(rawValue)" }

    /// Calm, descriptive name for the zone headline (e.g. "Z3 · Aerobic").
    var title: String {
        switch self {
        case .z1: "Recovery"
        case .z2: "Easy"
        case .z3: "Aerobic"
        case .z4: "Threshold"
        case .z5: "Max"
        }
    }

    /// The `BaselineColor` token name for this zone, low (blue) → high (red). Documentation only;
    /// `HeartRateZone.color` is the compile-checked mapping views resolve.
    var colorToken: String {
        switch self {
        case .z1: "zoneBlue"
        case .z2: "zoneGreen"
        case .z3: "zoneAmber"
        case .z4: "zoneOrange"
        case .z5: "zoneRed"
        }
    }

    static func < (lhs: HeartRateZone, rhs: HeartRateZone) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
