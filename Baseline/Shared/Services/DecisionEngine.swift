import Foundation

/// The **Decision Engine** — Baseline's deterministic core. Structured state (evidence + context) →
/// per-domain subscores → hard caps + constraints → readiness + band + primary/secondary limiter +
/// certainty. Pure and unit-testable: no hardware, no HealthKit, no view tree, and nothing here is
/// ever invented by an LLM. Constraints can gate the outcome even when the score is high. The
/// Context Engine feeds `Inputs`; the Planning Engine reads `Result`. See docs/architecture.md.
///
/// Reuses the shared readiness math (tunables, rolling `baseline`, `sleepScore`) from `ReadinessScore`
/// while owning the domain blend, caps, limiter, and certainty.
enum DecisionEngine {

    // MARK: - Types

    enum Domain: String, CaseIterable, Sendable {
        case autonomic, sleep, musculoskeletal, subjective, trainingLoad
        var title: String {
            switch self {
            case .autonomic: "Autonomic"
            case .sleep: "Sleep"
            case .musculoskeletal: "Musculoskeletal"
            case .subjective: "How you feel"
            case .trainingLoad: "Training load"
            }
        }
    }

    enum Band: String, Sendable { case green, amber, red }
    enum Certainty: String, Sendable { case low, medium, high }

    /// A present domain's 0–100 subscore (neutral = 50) and its effective (renormalized) weight.
    struct DomainScore: Equatable, Sendable {
        let domain: Domain
        let subscore: Int
        let weight: Double
    }

    /// A hard cap that fired; the binding (lowest) one names the primary limiter.
    struct AppliedCap: Equatable, Sendable {
        let domain: Domain
        let cap: Int
        let reason: String   // stable key, not user copy
    }

    /// A structured constraint (injury / pain). Shapes the plan even on a high-readiness day.
    struct Constraint: Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case injury, pain }
        var kind: Kind
        var location: String
        var severity: Int        // 0 none … 3 high
        var affectsTraining: Bool
        init(kind: Kind, location: String, severity: Int, affectsTraining: Bool = true) {
            self.kind = kind; self.location = location
            self.severity = min(max(severity, 0), 3); self.affectsTraining = affectsTraining
        }
    }

    struct Result: Equatable, Sendable {
        let score: Int
        let band: Band
        let certainty: Certainty
        let calibrating: Bool
        let domains: [DomainScore]          // present domains, worst subscore first
        let primaryLimiter: Domain?
        let secondaryLimiter: Domain?
        let appliedCaps: [AppliedCap]
        let constraints: [Constraint]       // pass-through for the Planning Engine
    }

    // MARK: - Inputs (structured state)

    struct Inputs: Sendable {
        // Autonomic
        var lnRMSSD: Double?
        var hrvBaseline: ReadinessScore.Baseline?
        var restingHR: Double?
        var rhrBaseline: ReadinessScore.Baseline?
        // Sleep
        var sleepScore: Double?     // 0–100 (see ReadinessScore.sleepScore)
        var sleepHours: Double?     // raw hours, for the poor-sleep cap
        // Subjective — oriented 1–5 (5 = most recovered)
        var energy: Double?
        var mood: Double?
        var stress: Double?
        var soreness: Double?       // musculoskeletal (also 1–5, 5 = no soreness)
        // Training load — acute:chronic (7:28) ratio; nil until HealthKit lands
        var loadRatio: Double?
        // Context
        var constraints: [Constraint]

        init(lnRMSSD: Double? = nil, hrvBaseline: ReadinessScore.Baseline? = nil,
             restingHR: Double? = nil, rhrBaseline: ReadinessScore.Baseline? = nil,
             sleepScore: Double? = nil, sleepHours: Double? = nil,
             energy: Double? = nil, mood: Double? = nil, stress: Double? = nil, soreness: Double? = nil,
             loadRatio: Double? = nil, constraints: [Constraint] = []) {
            self.lnRMSSD = lnRMSSD; self.hrvBaseline = hrvBaseline
            self.restingHR = restingHR; self.rhrBaseline = rhrBaseline
            self.sleepScore = sleepScore; self.sleepHours = sleepHours
            self.energy = energy; self.mood = mood; self.stress = stress; self.soreness = soreness
            self.loadRatio = loadRatio; self.constraints = constraints
        }
    }

    // MARK: - Weights (hybrid-athlete default; renormalized over present domains)

    private static let warmWeights: [Domain: Double] = [
        .autonomic: 0.35, .trainingLoad: 0.20, .subjective: 0.20, .sleep: 0.15, .musculoskeletal: 0.10,
    ]
    /// Cold-start (no personal HRV baseline yet) leans on subjective self-report, which needs no
    /// baseline and is the most training-responsive signal (Saw et al.).
    private static let coldWeights: [Domain: Double] = [
        .subjective: 0.40, .autonomic: 0.20, .trainingLoad: 0.20, .sleep: 0.10, .musculoskeletal: 0.10,
    ]

    // MARK: - Compute

    static func compute(_ inputs: Inputs) -> Result {
        let calibrating = (inputs.hrvBaseline?.count ?? 0) < ReadinessScore.calibrationThreshold

        // --- raw autonomic signals (needed by both the domain and the suppression cap) ---
        let (hrvZ, rhrZ) = autonomicSignals(inputs, calibrating: calibrating)

        // --- per-domain subscores (0–100, neutral 50), nil when the domain has no inputs ---
        var subscores: [Domain: Int] = [:]
        if let a = autonomicSubscore(hrvZ: hrvZ, rhrZ: rhrZ) { subscores[.autonomic] = a }
        if let s = inputs.sleepScore { subscores[.sleep] = clampScore(s) }
        if let m = musculoskeletalSubscore(inputs) { subscores[.musculoskeletal] = m }
        if let sub = subjectiveSubscore(inputs) { subscores[.subjective] = sub }
        if let tl = trainingLoadSubscore(inputs.loadRatio) { subscores[.trainingLoad] = tl }

        // --- weighted blend, renormalized over PRESENT domains ---
        let weights = calibrating ? coldWeights : warmWeights
        var domainScores: [DomainScore] = []
        var wSum = 0.0, wz = 0.0
        for (domain, sub) in subscores {
            let w = weights[domain] ?? 0
            domainScores.append(DomainScore(domain: domain, subscore: sub, weight: w))
            wSum += w
            wz += w * z(fromSubscore: sub)
        }
        let blend: Int = wSum > 0
            ? Int((ReadinessScore.neutralScore + ReadinessScore.spread * (wz / wSum)).rounded()).clampedInt(1...100)
            : Int(ReadinessScore.neutralScore)

        // --- hard caps: final = min(blend, lowest cap) ---
        let caps = appliedCaps(inputs, hrvZ: hrvZ, rhrZ: rhrZ)
        let bindingCap = caps.map(\.cap).min()
        let score = min(blend, bindingCap ?? 100)

        // --- limiter: only domains that are actually holding you back (below neutral-good, or a
        // fired cap). A relatively-lowest-but-still-healthy domain on a great day is NOT a limiter. ---
        let present = domainScores.sorted { $0.subscore < $1.subscore }
        var limiters = present.filter { $0.subscore < 60 }.map(\.domain)   // worst-first
        if let capDomain = caps.min(by: { $0.cap < $1.cap })?.domain {
            limiters.removeAll { $0 == capDomain }
            limiters.insert(capDomain, at: 0)
        }
        let primary = limiters.first
        let secondary = limiters.dropFirst().first

        return Result(
            score: score,
            band: band(for: score),
            certainty: certainty(inputs, calibrating: calibrating),
            calibrating: calibrating,
            domains: present,
            primaryLimiter: primary,
            secondaryLimiter: secondary,
            appliedCaps: caps,
            constraints: inputs.constraints
        )
    }

    // MARK: - Domain subscores

    /// HRV + RHR z-scores (personal baseline once established, else population frame), with the
    /// parasympathetic-saturation guard applied to HRV (low HRV + notably low RHR = vagal
    /// saturation, not fatigue — soften the penalty).
    private static func autonomicSignals(_ i: Inputs, calibrating: Bool) -> (hrv: Double?, rhr: Double?) {
        var hrvZ: Double?
        if let ln = i.lnRMSSD {
            if let b = i.hrvBaseline, b.sd > 0.01, !calibrating { hrvZ = clampZ((ln - b.mean) / b.sd) }
            else { hrvZ = clampZ((ln - 3.8) / 0.6) }
        }
        var rhrZ: Double?
        if let rhr = i.restingHR {
            if let b = i.rhrBaseline, b.sd > 0.01, !calibrating { rhrZ = clampZ((b.mean - rhr) / b.sd) }
            else { rhrZ = clampZ((60 - rhr) / 12) }
        }
        // Saturation guard: RHR clearly low (z > +0.75) + HRV negative → floor HRV at −0.5.
        if let r = rhrZ, r > 0.75, let h = hrvZ, h < 0 { hrvZ = max(h, -0.5) }
        return (hrvZ, rhrZ)
    }

    private static func autonomicSubscore(hrvZ: Double?, rhrZ: Double?) -> Int? {
        var wSum = 0.0, wz = 0.0
        if let h = hrvZ { wSum += 0.75; wz += 0.75 * h }
        if let r = rhrZ { wSum += 0.25; wz += 0.25 * r }
        guard wSum > 0 else { return nil }
        return subscore(fromZ: wz / wSum)
    }

    private static func musculoskeletalSubscore(_ i: Inputs) -> Int? {
        let sorenessPresent = i.soreness != nil
        // Only constraints the athlete says affect training move the score (honors affectsTraining,
        // matching the Planning Engine).
        let activeConstraints = i.constraints.filter { $0.severity > 0 && $0.affectsTraining }
        guard sorenessPresent || !activeConstraints.isEmpty else { return nil }
        let base = i.soreness.map(oriented100) ?? 50           // 50 if only a constraint is known
        let penalty = Double((activeConstraints.map(\.severity).max() ?? 0)) * 12   // 0/12/24/36
        return clampScore(base - penalty)
    }

    private static func subjectiveSubscore(_ i: Inputs) -> Int? {
        let vals = [i.energy, i.mood, i.stress].compactMap { $0 }
        guard !vals.isEmpty else { return nil }
        return clampScore(oriented100(vals.reduce(0, +) / Double(vals.count)))
    }

    /// Acute:chronic (7:28) load ratio → 0–100. ~1.0 sits comfortably positive (absorbing well);
    /// higher ratios (spiking load) pull it down; very low ratios (fresh/detrained) sit high.
    private static func trainingLoadSubscore(_ ratio: Double?) -> Int? {
        guard let r = ratio else { return nil }
        let s = r <= 1.0 ? 65 + (1.0 - r) * 25 : 65 - (r - 1.0) * 70
        return clampScore(s)
    }

    // MARK: - Caps

    private static func appliedCaps(_ i: Inputs, hrvZ: Double?, rhrZ: Double?) -> [AppliedCap] {
        var caps: [AppliedCap] = []
        func add(_ d: Domain, _ cap: Int, _ reason: String) { caps.append(AppliedCap(domain: d, cap: cap, reason: reason)) }

        if let s = i.soreness, s <= 2 { add(.musculoskeletal, 60, "severeSoreness") }
        if let e = i.energy, e <= 2 { add(.subjective, 60, "veryLowEnergy") }
        if let st = i.stress, st <= 2 { add(.subjective, 70, "highStress") }
        if let h = i.sleepHours, h < 4.5 { add(.sleep, 55, "poorSleep") }
        // Genuine suppression = low HRV AND elevated resting HR (both z negative). The opposite
        // case — low HRV with a *low* RHR — is vagal saturation, softened by the guard, not capped.
        if let hz = hrvZ, hz < -0.5, let rz = rhrZ, rz < -0.75 { add(.autonomic, 50, "autonomicSuppressed") }
        if let r = i.loadRatio {
            if r >= 2.0 { add(.trainingLoad, 55, "veryHighLoad") }
            else if r >= 1.5 { add(.trainingLoad, 70, "highLoad") }
        }
        for c in i.constraints where c.severity >= 3 && c.affectsTraining {
            add(.musculoskeletal, 45, c.kind == .injury ? "injuryHigh" : "tendonHigh")
        }
        return caps
    }

    // MARK: - Certainty (evidence available today)

    private static func certainty(_ i: Inputs, calibrating: Bool) -> Certainty {
        var points = 0
        if i.lnRMSSD != nil { points += 1 }
        if i.restingHR != nil { points += 1 }
        if i.sleepScore != nil { points += 1 }
        if i.energy != nil || i.mood != nil || i.stress != nil || i.soreness != nil { points += 1 }
        if i.loadRatio != nil { points += 1 }
        if !calibrating { points += 1 }                 // an established personal baseline
        return points >= 5 ? .high : (points >= 3 ? .medium : .low)
    }

    // MARK: - Small helpers

    static func band(for score: Int) -> Band { score >= 80 ? .green : (score >= 60 ? .amber : .red) }

    private static func oriented100(_ v: Double) -> Double { (v - 1) / 4 * 100 }              // 1–5 → 0–100
    private static func z(fromSubscore s: Int) -> Double { (Double(s) - 50) / ReadinessScore.subscoreScale }
    private static func subscore(fromZ z: Double) -> Int { clampScore(50 + ReadinessScore.subscoreScale * z) }
    private static func clampScore(_ v: Double) -> Int { Int(v.rounded()).clampedInt(0...100) }
    private static func clampZ(_ z: Double) -> Double { min(max(z, -3), 3) }
}

private extension Int {
    func clampedInt(_ r: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}
