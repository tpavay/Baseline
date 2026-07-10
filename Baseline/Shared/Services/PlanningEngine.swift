import Foundation

/// The **Planning Engine** — turns the Decision Engine's state into *today's plan*. Pure and
/// unit-testable. `(band × limiter × constraints × training state × style) → Plan {type, summary,
/// avoid, why}`. It **proposes**, honoring these rules:
/// - Constraints override the score-derived choice: an active injury re-routes the plan (preserve
///   the *stimulus*, drop the impact — a threshold run on a cranky Achilles becomes a bike, not "skip
///   it") even on a green day.
/// - Copy is hybrid/HYROX-flavored, movement *categories* not programmed sessions, and never the word
///   "chassis" (say "active recovery" / "easy aerobic"). See docs/conversation-design.md + principles.
enum PlanningEngine {

    enum Style: String, Codable, Sendable { case conservative, balanced, aggressive }

    /// Today's practical constraints, from the chat ("only 25 minutes", "traveling"). They shape the
    /// plan's framing — the specific session is the LLM's job later; here we add honest context notes.
    struct DailyFactors: Sendable {
        var timeAvailableMinutes: Int?
        var traveling: Bool?
        var limitedEquipment: Bool?
        init(timeAvailableMinutes: Int? = nil, traveling: Bool? = nil, limitedEquipment: Bool? = nil) {
            self.timeAvailableMinutes = timeAvailableMinutes
            self.traveling = traveling
            self.limitedEquipment = limitedEquipment
        }
    }

    /// Minimal training state for now (goal/phase are captured by the conversation later and only
    /// flavor the copy; the deterministic routing works without them).
    struct TrainingState: Sendable {
        var goal: String?
        var phase: String?
        init(goal: String? = nil, phase: String? = nil) { self.goal = goal; self.phase = phase }
    }

    enum PlanType: String, Sendable {
        case hardIntensity, threshold, aerobicBase, easyAerobic, lowImpact, activeRecovery
        var summary: String {
            switch self {
            case .hardIntensity: "Intensity is on — a hard session fits today."
            case .threshold:     "Threshold work — controlled hard, not all-out."
            case .aerobicBase:   "Aerobic base — Zone 2, 40–60 min. Build the engine without digging a hole."
            case .easyAerobic:   "Easy aerobic — keep it Zone 1–2 and light."
            case .lowImpact:     "Recovered, but locally limited — go upper-body or low-impact (bike, SkiErg) and skip the pounding."
            case .activeRecovery:"Active recovery — easy movement, mobility, and blood flow."
            }
        }
    }

    struct Plan: Equatable, Sendable {
        let type: PlanType
        let summary: String
        let why: [String]
        let avoid: [String]
    }

    // MARK: - Plan

    static func plan(for d: DecisionEngine.Result, daily: DailyFactors = .init(),
                     state: TrainingState = .init(), style: Style = .balanced) -> Plan {
        // Base level from the band: 4 hard · 3 threshold · 2 aerobic base · 1 easy · 0 active recovery.
        var level: Int
        switch d.band { case .green: level = 4; case .amber: level = 2; case .red: level = 0 }

        // The limiter caps how hard is wise.
        switch d.primaryLimiter {
        case .musculoskeletal: level = min(level, 1)
        case .autonomic, .subjective, .trainingLoad: level = min(level, 2)
        case .sleep: level = min(level, 3)
        case .none: break
        }

        switch style {
        case .conservative: level -= 1
        case .aggressive:   level += 1
        case .balanced:     break
        }
        level = min(max(level, 0), 4)

        // Constraint override — preserve the stimulus, drop the impact.
        let blocking = d.constraints.filter { $0.affectsTraining && $0.severity >= 2 }
        var avoid: [String] = []
        if !blocking.isEmpty {
            for c in blocking { avoid.append("Loading your \(c.location.lowercased())") }
            avoid.append("Running, jumping, and heavy lower-body")
        }

        let type: PlanType = (!blocking.isEmpty && level >= 2) ? .lowImpact : levelType(level)

        avoid += avoidFor(type: type)
        return Plan(type: type, summary: type.summary, why: why(d, state: state) + dailyNotes(daily), avoid: dedupe(avoid))
    }

    private static func dailyNotes(_ d: DailyFactors) -> [String] {
        var out: [String] = []
        if let m = d.timeAvailableMinutes, m < 40 { out.append("You've got ~\(m) min — compress it and keep the main stimulus.") }
        if d.traveling == true { out.append("Traveling — a run, bodyweight circuit, or hotel gym all work.") }
        else if d.limitedEquipment == true { out.append("Limited equipment — bodyweight, a run, or the machines you've got will do.") }
        return out
    }

    // MARK: - Mapping

    private static func levelType(_ level: Int) -> PlanType {
        switch level {
        case 4: .hardIntensity
        case 3: .threshold
        case 2: .aerobicBase
        case 1: .easyAerobic
        default: .activeRecovery
        }
    }

    private static func avoidFor(type: PlanType) -> [String] {
        switch type {
        case .hardIntensity: []
        case .threshold: ["Going fully to failure", "Stacking a second hard day tomorrow"]
        case .aerobicBase, .lowImpact: ["Running intervals", "Sled push", "Heavy lower-body"]
        case .easyAerobic, .activeRecovery: ["Any intervals", "Sled or wall balls", "Heavy or max-effort lifting"]
        }
    }

    private static func why(_ d: DecisionEngine.Result, state: TrainingState) -> [String] {
        var out: [String] = []
        if let p = d.primaryLimiter { out.append("Mainly limited by \(limiterPhrase(p)).") }
        if let s = d.secondaryLimiter { out.append("Also weighing \(limiterPhrase(s)).") }
        if let c = d.constraints.first(where: { $0.affectsTraining && $0.severity >= 2 }) {
            out.append("Working around your \(c.location.lowercased()) — keeping load off it.")
        }
        if d.certainty == .low {
            out.append("Still early — I'm being cautious until I learn how you respond.")
        }
        if out.isEmpty { out.append("Everything looks in range this morning.") }
        return out
    }

    private static func limiterPhrase(_ d: DecisionEngine.Domain) -> String {
        switch d {
        case .autonomic: "elevated systemic stress (HRV and heart rate)"
        case .sleep: "short sleep"
        case .musculoskeletal: "muscle soreness"
        case .subjective: "how you're feeling"
        case .trainingLoad: "a high recent training load"
        }
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>(); return items.filter { seen.insert($0).inserted }
    }
}
