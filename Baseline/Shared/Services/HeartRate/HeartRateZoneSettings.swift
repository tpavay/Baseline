import Foundation

/// The athlete's local heart-rate-zone configuration: an optional tested/observed **max HR**
/// override, an optional **resting HR** (which switches zones to Karvonen/HRR), and an optional
/// **LTHR** anchor. Pure `Codable` value type — no SwiftUI, persistence, or CoreBluetooth — so
/// validation and model-building are fully unit-testable.
///
/// A committed config must never be able to build a degenerate `HeartRateZoneModel` (non-increasing
/// zones). `validate(ageYears:)` enforces `restingHR < maxHR` and a sane LTHR band, and
/// `validatedModel(ageYears:)` refuses to produce a model from an invalid config. Max HR is resolved
/// as **override ?? Tanaka(age)** — an explicit user value always wins and is never silently
/// replaced by the age estimate (`baseline-live-heart-rate`: never overwrite a tested max).
struct HeartRateZoneSettings: Codable, Equatable, Sendable {

    /// Explicit max HR. `nil` means "use the age-derived Tanaka estimate". Never overwritten by the
    /// estimate — clearing it is an explicit user action, not an inference.
    var maxHROverride: Int?
    /// Resting HR. When present (and valid), zones use Karvonen / Heart Rate Reserve.
    var restingHR: Int?
    /// Optional lactate-threshold HR anchor. Stored and passed through; not yet a boundary input.
    var lthr: Int?

    init(maxHROverride: Int? = nil, restingHR: Int? = nil, lthr: Int? = nil) {
        self.maxHROverride = maxHROverride
        self.restingHR = restingHR
        self.lthr = lthr
    }

    // MARK: - Sane bounds

    /// Plausible human max HR band for an override (guards fat-finger entry). Below this a resting HR
    /// couldn't sit under it; above it is non-physiological.
    static let maxHROverrideRange = 120...230
    /// Plausible resting HR band. Upper bound is deliberately below the max-HR floor so the two can't
    /// meet; the `restingHR < maxHR` check still enforces the per-config relationship.
    static let restingHRRange = 25...120
    /// LTHR must sit inside the aerobic-to-max span: at least this fraction of max, at most max.
    static let lthrLowerFraction = 0.60

    // MARK: - Resolution

    /// Effective max HR: the explicit override when set, else Tanaka(age) via `HeartRateZoneModel`
    /// (so the estimate math has one home). Never discards the override.
    func resolvedMaxHR(ageYears: Int?) -> Int {
        maxHROverride ?? HeartRateZoneModel(age: ageYears).maxHR
    }

    /// The active zone method, honest about inputs: Karvonen/HRR **iff** a valid resting HR is set,
    /// otherwise %max. Mirrors `HeartRateZoneModel`'s own method selection.
    func method(ageYears: Int?) -> HeartRateZoneModel.Method {
        validatedRestingHR(ageYears: ageYears) != nil ? .heartRateReserve : .percentMax
    }

    /// The resting HR only if it is present *and* passes validation for the resolved max; otherwise
    /// `nil`. Keeps method selection and model-building from ever using an out-of-band resting value.
    func validatedRestingHR(ageYears: Int?) -> Int? {
        guard let restingHR else { return nil }
        let maxHR = resolvedMaxHR(ageYears: ageYears)
        guard Self.restingHRRange.contains(restingHR), restingHR < maxHR else { return nil }
        return restingHR
    }

    // MARK: - Validation

    enum ValidationError: Error, Equatable {
        /// The max-HR override is outside `maxHROverrideRange`.
        case maxHROutOfRange
        /// The resting HR is outside `restingHRRange`.
        case restingHROutOfRange
        /// `restingHR >= maxHR` — would collapse the Karvonen reserve to zero/negative.
        case restingNotBelowMax
        /// The LTHR sits outside the `[lowerFraction·maxHR, maxHR]` band.
        case lthrOutOfBand
    }

    /// The sane LTHR band for the resolved max HR (`[⌈0.60·max⌉, max]`).
    func lthrBand(ageYears: Int?) -> ClosedRange<Int> {
        let maxHR = resolvedMaxHR(ageYears: ageYears)
        let lower = Int((Self.lthrLowerFraction * Double(maxHR)).rounded(.up))
        return lower...maxHR
    }

    /// Returns the first validation failure, or `nil` when the config is committable. A `nil` result
    /// guarantees `validatedModel(ageYears:)` yields a well-formed, strictly-increasing model.
    func validate(ageYears: Int?) -> ValidationError? {
        let maxHR = resolvedMaxHR(ageYears: ageYears)
        if let maxHROverride, !Self.maxHROverrideRange.contains(maxHROverride) {
            return .maxHROutOfRange
        }
        if let restingHR {
            guard Self.restingHRRange.contains(restingHR) else { return .restingHROutOfRange }
            guard restingHR < maxHR else { return .restingNotBelowMax }
        }
        if let lthr, !lthrBand(ageYears: ageYears).contains(lthr) {
            return .lthrOutOfBand
        }
        return nil
    }

    var isEmpty: Bool { maxHROverride == nil && restingHR == nil && lthr == nil }

    // MARK: - Model building

    /// Builds the zone model **only** from a valid config; returns `nil` otherwise so a degenerate
    /// model can never be produced from committed state.
    func validatedModel(ageYears: Int?) -> HeartRateZoneModel? {
        guard validate(ageYears: ageYears) == nil else { return nil }
        return HeartRateZoneModel(maxHR: resolvedMaxHR(ageYears: ageYears),
                                  restingHR: restingHR,
                                  lthr: lthr)
    }
}
