import Foundation

/// The configurable morning readiness score — a pure, unit-testable function (no hardware, no
/// HealthKit calls, no view tree). Callers fetch the raw inputs (HRV reading, HealthKit sleep,
/// check-in answers) and pass them in; this maps them to a 0–100 score + band + per-contributor
/// breakdown, re-normalizing over whatever inputs are present and enabled.
///
/// Design grounded in the readiness-score research (WHOOP/Oura weighted personal-baseline blend,
/// Altini's lnRMSSD normalization + smallest-worthwhile-change, Saw et al. on weighting subjective
/// self-report heavily and letting extreme soreness/stress floor the band). See
/// docs/readiness-score.md.
enum ReadinessScore {

    // MARK: - Tunables (single source of truth)

    /// A neutral / at-baseline day sits in the **middle of the amber band** (not at 50/red) —
    /// amber is the "within normal variation" band around your baseline. `spread` then earns
    /// green at roughly +0.5 SD above baseline (Altini's smallest-worthwhile-change) and red at
    /// ~0.5 SD below. Recentered 2026-07-08 so an average day reads amber, never red.
    static let neutralScore = 70.0
    static let spread = 20.0
    /// Converts a 0–100 subscore (whose neutral is 50) into a z before the composite blend.
    static let subscoreScale = 22.0
    /// Readings needed before the personal rolling baseline is trusted. Kept deliberately short
    /// (HRV4Training-style): a handful of morning readings is enough for a usable personal frame —
    /// no need to wait two weeks before scoring against the athlete's own data.
    static let calibrationThreshold = 4

    enum Band: String, Sendable { case green, amber, red }

    struct Contributor: Equatable, Sendable {
        let input: String
        let z: Double
        let weight: Double
    }

    struct Result: Equatable, Sendable {
        let score: Int
        let band: Band
        let calibrating: Bool
        let contributors: [Contributor]
    }

    /// One input's value today plus its rolling baseline (mean/SD in the input's transformed
    /// units — lnRMSSD for HRV, bpm for RHR, a 0–100 sleep score, etc.). SD nil/tiny → treated
    /// as no usable baseline (cold-start path for that input).
    struct Baseline: Equatable, Sendable {
        var mean: Double
        var sd: Double
        var count: Int
    }

    // MARK: - Inputs

    /// Everything the score can consume this morning. Any field left nil simply drops out and the
    /// remaining weights re-normalize.
    struct Inputs: Sendable {
        var lnRMSSD: Double?
        var hrvBaseline: Baseline?
        var restingHR: Double?
        var rhrBaseline: Baseline?
        /// 0–100 sleep score (see `sleepScore(hours:efficiency:)`), already computed.
        var sleepScore: Double?
        /// Oriented 1–5 check-in items (5 = most recovered), only the enabled ones.
        var checkIn: [Double]
        var soreness: Double?
        var stress: Double?

        init(lnRMSSD: Double? = nil, hrvBaseline: Baseline? = nil,
             restingHR: Double? = nil, rhrBaseline: Baseline? = nil,
             sleepScore: Double? = nil, checkIn: [Double] = [],
             soreness: Double? = nil, stress: Double? = nil) {
            self.lnRMSSD = lnRMSSD
            self.hrvBaseline = hrvBaseline
            self.restingHR = restingHR
            self.rhrBaseline = rhrBaseline
            self.sleepScore = sleepScore
            self.checkIn = checkIn
            self.soreness = soreness
            self.stress = stress
        }
    }

    private static let weights: [String: Double] = [
        "HRV": 0.50, "Check-in": 0.25, "Resting HR": 0.15, "Sleep": 0.10,
    ]
    /// Cold-start leans on the subjective input, which needs no baseline and is the most
    /// training-responsive signal (Saw et al.).
    private static let coldWeights: [String: Double] = [
        "HRV": 0.30, "Check-in": 0.45, "Resting HR": 0.15, "Sleep": 0.10,
    ]

    // MARK: - The score

    static func compute(_ inputs: Inputs) -> Result {
        let calibrating = (inputs.hrvBaseline?.count ?? 0) < calibrationThreshold
        let w = calibrating ? coldWeights : weights

        var contributors: [Contributor] = []

        // HRV: z vs personal baseline once established; absolute age-agnostic norms during cold
        // start (wide SD so early readings don't swing). Positive = higher HRV = more recovered.
        if let ln = inputs.lnRMSSD {
            let z: Double
            if let b = inputs.hrvBaseline, b.sd > 0.01, !calibrating {
                z = clamp((ln - b.mean) / b.sd)
            } else {
                // Absolute frame: lnRMSSD ~3.0 (RMSSD 20ms) low → ~4.6 (100ms) high, centered ~3.8.
                z = clamp((ln - 3.8) / 0.6)
            }
            contributors.append(Contributor(input: "HRV", z: z, weight: w["HRV"]!))
        }

        // Resting HR: inverted (lower = more recovered).
        if let rhr = inputs.restingHR {
            let z: Double
            if let b = inputs.rhrBaseline, b.sd > 0.01, !calibrating {
                z = clamp((b.mean - rhr) / b.sd)
            } else {
                z = clamp((60 - rhr) / 12)   // population frame ~48–72 bpm
            }
            contributors.append(Contributor(input: "Resting HR", z: z, weight: w["Resting HR"]!))
        }

        // Sleep: a 0–100 target-band score, centered to a z through the same curve.
        if let sleep = inputs.sleepScore {
            contributors.append(Contributor(input: "Sleep", z: clamp((sleep - 50) / subscoreScale), weight: w["Sleep"]!))
        }

        // Subjective check-in: raw-sum → 0–100 → centered z. Needs no baseline, valid at all times.
        if let subjective = subjectiveScore(inputs.checkIn) {
            contributors.append(Contributor(input: "Check-in", z: clamp((subjective - 50) / subscoreScale), weight: w["Check-in"]!))
        }

        // Parasympathetic-saturation guard: low HRV alongside a notably low RHR is vagal
        // saturation, not fatigue — soften the HRV penalty.
        contributors = applySaturationGuard(contributors)

        guard !contributors.isEmpty else {
            return Result(score: Int(neutralScore), band: band(for: Int(neutralScore)), calibrating: calibrating, contributors: [])
        }

        let wSum = contributors.map(\.weight).reduce(0, +)
        let compositeZ = contributors.map { $0.weight * $0.z }.reduce(0, +) / wSum
        var score = Int((neutralScore + spread * compositeZ).rounded()).clamped(to: 1...100)

        // Subjective floor: extreme soreness or stress caps the day at amber regardless of HRV.
        if (inputs.soreness ?? 5) <= 2 || (inputs.stress ?? 5) <= 2 {
            score = min(score, 79)
        }

        return Result(score: score, band: band(for: score), calibrating: calibrating, contributors: contributors)
    }

    // MARK: - Rolling baseline

    /// Rolling personal baseline (mean + SD) from a series of transformed values — lnRMSSD for HRV,
    /// bpm for resting HR. Pure and SwiftData-free: the caller maps saved morning `Reading`s to the
    /// value array. `count` gates cold-start in `compute`/`hrvReadingScore` (the personal frame is
    /// only trusted once `count >= calibrationThreshold`). Sample SD (n−1) so a few readings don't
    /// understate variability. nil when empty.
    static func baseline(from values: [Double]) -> Baseline? {
        guard !values.isEmpty else { return nil }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let sd: Double = values.count > 1
            ? (values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)).squareRoot()
            : 0
        return Baseline(mean: mean, sd: sd, count: values.count)
    }

    // MARK: - Helpers

    /// A single reading's HRV mapped to 0–100 on the *same* scale the composite score uses — for
    /// the reading-complete readout, so the athlete sees an interpretable result (higher = more
    /// recovered) instead of a raw millisecond figure. Uses the personal baseline once established,
    /// otherwise the population frame (cold start). Neutral (at-baseline) lands at `neutralScore`.
    static func hrvReadingScore(lnRMSSD: Double, baseline: Baseline? = nil) -> Int {
        let z: Double
        if let b = baseline, b.sd > 0.01, b.count >= calibrationThreshold {
            z = clamp((lnRMSSD - b.mean) / b.sd)
        } else {
            z = clamp((lnRMSSD - 3.8) / 0.6)
        }
        return Int((neutralScore + spread * z).rounded()).clamped(to: 1...100)
    }

    /// Subjective composite for k oriented 1–5 items: `(sum − k)/(4k)·100`. nil if none.
    static func subjectiveScore(_ oriented: [Double]) -> Double? {
        guard !oriented.isEmpty else { return nil }
        let k = Double(oriented.count)
        return ((oriented.reduce(0, +) - k) / (4 * k) * 100).clamped(to: 0...100)
    }

    /// HealthKit sleep → 0–100. Duration plateaus over the healthy 7–9h band; efficiency (if
    /// present) targets ≥85%. No data → nil (the input drops out; never imputed to 50).
    static func sleepScore(hours: Double?, efficiency: Double? = nil) -> Double? {
        guard let h = hours, h > 0 else { return nil }
        let dur: Double
        switch h {
        case 7...9:   dur = 100
        case 9...10:  dur = 100 - (h - 9) * 20
        case 5..<7:   dur = 100 - (7 - h) * 33.3
        case ..<5:    dur = max(0, 33 - (5 - h) * 20)
        default:      dur = max(0, 80 - (h - 10) * 20)   // h > 10
        }
        guard let eff = efficiency else { return dur }
        let effScore = clamp01((eff - 0.70) / 0.25) * 100
        return 0.7 * dur + 0.3 * effScore
    }

    static func band(for score: Int) -> Band {
        score >= 80 ? .green : (score >= 60 ? .amber : .red)
    }

    private static func applySaturationGuard(_ contributors: [Contributor]) -> [Contributor] {
        guard let rhr = contributors.first(where: { $0.input == "Resting HR" }), rhr.z > 0.75 else {
            return contributors
        }
        return contributors.map { c in
            (c.input == "HRV" && c.z < 0) ? Contributor(input: c.input, z: max(c.z, -0.5), weight: c.weight) : c
        }
    }

    private static func clamp(_ z: Double) -> Double { z.clamped(to: -3...3) }
    private static func clamp01(_ x: Double) -> Double { x.clamped(to: 0...1) }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
