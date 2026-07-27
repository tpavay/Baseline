import Foundation

/// Resolves a live heart rate into a `HeartRateZone` for one athlete. Pure value type — no
/// CoreBluetooth, HealthKit, SwiftUI, or persistence — so every boundary is unit-testable against
/// hand-computed thresholds.
///
/// Zone boundaries use **Heart Rate Reserve (Karvonen)** when a resting HR is known
/// (`target = restingHR + fraction · (maxHR − restingHR)`), and fall back to **percent of max HR**
/// (`target = fraction · maxHR`) otherwise. Both methods read the *same* centralized table of
/// per-zone lower-bound fractions, so there is one place to tune the policy.
///
/// Max HR comes from an explicit user value when supplied, else **Tanaka** (`208 − 0.7·age`). Zones
/// are a coaching aid: they communicate intensity, never fabricated precision, and never silently
/// overwrite an athlete's tested max (see `baseline-live-heart-rate`).
struct HeartRateZoneModel: Hashable, Sendable {

    /// How the boundaries were derived, preserved so a historical zone can be explained/reproduced.
    /// String-backed so `HeartRateZoneModelSnapshot` can persist it as a stable, readable token.
    enum Method: String, Hashable, Sendable, Codable {
        /// Karvonen / Heart Rate Reserve — used whenever `restingHR` is present.
        case heartRateReserve
        /// Percent of max HR — the fallback when no resting HR is known.
        case percentMax
    }

    let maxHR: Int
    let restingHR: Int?
    let lthr: Int?
    let method: Method

    // MARK: - Tunables (single source of truth)

    /// Lower-bound fraction of each zone, applied to Heart Rate Reserve (Karvonen) or to max HR.
    /// The conventional five-zone split — 50/60/70/80/90 — used by Garmin and most HRR/%max
    /// schemes. Evenly spaced by 0.10 over the [0.50, 1.00] span, which is what makes
    /// `position(forBPM:)` map cleanly onto zone buckets (quintiles). Index 0 (0.50) is the bottom
    /// of Z1 and the start of the spectrum; indices 1…4 are the Z1→Z2 … Z4→Z5 dividers.
    static let zoneLowerBounds: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90]

    /// Used when age is unknown pre-onboarding (matches the resting-reading fallback).
    static let fallbackAge = 35

    // MARK: - Init

    /// Explicit max HR (a tested/observed maximum), optionally with resting HR and LTHR.
    /// Presence of `restingHR` selects Karvonen; otherwise %max.
    init(maxHR: Int, restingHR: Int? = nil, lthr: Int? = nil) {
        self.maxHR = maxHR
        self.restingHR = restingHR
        self.lthr = lthr
        self.method = restingHR != nil ? .heartRateReserve : .percentMax
    }

    /// Age-estimated max HR via Tanaka (`208 − 0.7·age`, rounded), age bounded to [13, 120] and
    /// defaulting to 35 when nil. An explicit max should prefer the `init(maxHR:…)` overload; this
    /// is the honest fallback when the athlete has never tested or entered one.
    init(age: Int?, restingHR: Int? = nil, lthr: Int? = nil) {
        let boundedAge = min(max(age ?? Self.fallbackAge, 13), 120)
        let estimatedMax = Int((208.0 - 0.7 * Double(boundedAge)).rounded())
        self.init(maxHR: estimatedMax, restingHR: restingHR, lthr: lthr)
    }

    // MARK: - Zone resolution

    /// The zone for a live BPM. Below the Z1 lower bound still reads as Z1 (clamped low);
    /// at or above the Z5 lower bound reads as Z5.
    func zone(forBPM bpm: Int) -> HeartRateZone {
        let bpm = Double(bpm)
        if bpm < threshold(at: 1) { return .z1 }
        if bpm < threshold(at: 2) { return .z2 }
        if bpm < threshold(at: 3) { return .z3 }
        if bpm < threshold(at: 4) { return .z4 }
        return .z5
    }

    /// A monotonic 0→1 position across the whole Z1→Z5 span (for the moving spectrum marker),
    /// clamped at both ends. Because the zone dividers are evenly spaced over the span, the position
    /// bucket `floor(position · 5)` equals `zone(forBPM:)` for any BPM strictly inside a zone.
    func position(forBPM bpm: Int) -> Double {
        let low = threshold(at: 0)          // bottom of Z1 == start of spectrum
        let high = Double(maxHR)            // top of Z5 (fraction 1.0) == max HR, both methods
        guard high > low else { return 0 }
        let raw = (Double(bpm) - low) / (high - low)
        return min(max(raw, 0), 1)
    }

    // MARK: - Zone boundaries (shared)

    /// The inclusive lower BPM of `zone` — the lowest integer heart rate the model assigns to it.
    /// This is the single source of the boundary math: it reads the *same* `zoneLowerBounds`,
    /// `maxHR`, and `restingHR` as `zone(forBPM:)`, and `⌈threshold⌉` is exactly the smallest integer
    /// that is not `< threshold`, so `zone(forBPM: lowerBPM(for: z)) == z` for z2…z5 (and the Z1
    /// nominal floor for z1). The settings preview and the live spectrum consume this rather than
    /// re-deriving Karvonen/%max, so displayed bands can never drift from the resolver.
    func lowerBPM(for zone: HeartRateZone) -> Int {
        Int(threshold(at: zone.rawValue - 1).rounded(.up))
    }

    // MARK: - Internals

    /// The BPM threshold for the zone lower-bound at `index` in `zoneLowerBounds`.
    private func threshold(at index: Int) -> Double {
        let fraction = Self.zoneLowerBounds[index]
        if let restingHR {                                   // Karvonen / HRR
            return Double(restingHR) + fraction * Double(maxHR - restingHR)
        }
        return fraction * Double(maxHR)                      // %max
    }
}
