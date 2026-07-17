import Foundation

/// Accumulates seconds-in-zone across a live session. Pure value type driven by explicit intervals
/// so it is fully deterministic in tests (no wall clock). The `HeartRateMonitor` credits the
/// interval between two consecutive samples to the zone that was active during it.
struct ZoneTimeAccumulator: Equatable, Sendable {

    private var secondsByZone: [HeartRateZone: TimeInterval] = [:]

    /// Add `seconds` to `zone`. Non-positive durations are ignored (a duplicate or out-of-order
    /// sample contributes nothing rather than corrupting the total).
    mutating func credit(_ zone: HeartRateZone, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        secondsByZone[zone, default: 0] += seconds
    }

    /// Accumulated seconds in a single zone (0 if none credited yet).
    func seconds(in zone: HeartRateZone) -> TimeInterval {
        secondsByZone[zone] ?? 0
    }

    /// Seconds for every zone in `z1…z5` order, for a summary readout.
    var secondsByZoneOrdered: [(zone: HeartRateZone, seconds: TimeInterval)] {
        HeartRateZone.allCases.map { ($0, seconds(in: $0)) }
    }

    /// Total accumulated seconds across all zones.
    var total: TimeInterval {
        secondsByZone.values.reduce(0, +)
    }
}
