import Foundation

/// The Context Engine's **validated tool layer** — the deterministic operations the LLM *proposes*
/// and this *executes*. The model understands language; this owns what actually happens: every call
/// is typed and validated, mutates the structured state, and returns the **recomputed** plan so the
/// conversation always reflects truth. The LLM never edits data or invents a score.
///
/// Per `docs/implementation/plan-engine.md` §7/§11, these are low-risk, today-scoped, single-item
/// mutations, so they apply directly (no version wrapper) — the versioned Plan Repository is for
/// plan edits, later. `base` is today's evidence snapshot (HRV/RHR/sleep/check-in) the app supplies.
@MainActor
final class AgentTools {

    /// A validated operation the assistant can request. The backend maps the LLM's JSON tool-calls
    /// into these; nothing else can mutate state through the conversation.
    enum Call: Sendable, Equatable {
        case getToday
        case explain
        case setTimeAvailable(Int?)
        case setEquipment([String]?)
        case setTraveling(Bool?)
        case setIllness(Bool?)
        case setSleep(hours: Double?)
        case setCheckIn(energy: Double?, mood: Double?, stress: Double?, soreness: Double?)
        case setNote(String?)
        case upsertConstraint(id: UUID?, kind: DecisionEngine.Constraint.Kind, location: String, severity: Int, affectsTraining: Bool)
        case resolveConstraint(id: UUID)

        /// A short human-readable summary of what this call did — for the "what Baseline knows"
        /// inspector's activity feed, so the behind-the-scenes mutations are visible.
        var activityLabel: String {
            switch self {
            case .getToday: return "Read today's state"
            case .explain: return "Explained the plan"
            case .setTimeAvailable(let m): return m.map { "Time available → \($0) min" } ?? "Cleared time available"
            case .setEquipment(let e): return "Equipment → \(e?.joined(separator: ", ") ?? "cleared")"
            case .setTraveling(let t): return t == true ? "Traveling → yes" : "Traveling → no"
            case .setIllness(let i): return i == true ? "Marked unwell" : "Marked well"
            case .setSleep(let h): return h.map { "Sleep → \(String(format: "%g", $0)) h" } ?? "Cleared sleep"
            case .setCheckIn(let e, let m, let s, let so):
                let parts = [("energy", e), ("mood", m), ("stress", s), ("soreness", so)]
                    .compactMap { label, v in v.map { "\(label) \(Int($0))" } }
                return "Check-in → " + (parts.isEmpty ? "—" : parts.joined(separator: ", "))
            case .upsertConstraint(_, let kind, let location, let severity, let affects):
                return "Constraint → \(location) (\(kind.rawValue), sev \(severity))\(affects ? "" : ", not limiting")"
            case .setNote: return "Saved a note"
            case .resolveConstraint: return "Resolved a constraint"
            }
        }
    }

    struct Response: Sendable {
        let text: String                       // what the model (and UI) see back
        let decision: DecisionEngine.Result?
        let plan: PlanningEngine.Plan?
    }

    private let store: TrainingContextStore
    var base: DecisionEngine.Inputs             // today's evidence; refreshed by the app after a reading
    var style: PlanningEngine.Style

    init(store: TrainingContextStore, base: DecisionEngine.Inputs = .init(), style: PlanningEngine.Style = .balanced) {
        self.store = store
        self.base = base
        self.style = style
    }

    // MARK: - Dispatch

    func dispatch(_ call: Call) -> Response {
        switch call {
        case .getToday:
            return respond(prefix: nil)
        case .explain:
            let (d, p) = today()
            return Response(text: explanation(d, p), decision: d, plan: p)
        case .setTimeAvailable(let minutes):
            let clamped = minutes.map { max(0, $0) }
            store.setTimeAvailable(clamped)
            return respond(prefix: clamped.map { "\($0) min today." } ?? "Time cleared.")
        case .setEquipment(let equipment):
            store.setEquipment(equipment)
            return respond(prefix: "Equipment updated.")
        case .setTraveling(let traveling):
            store.setTraveling(traveling)
            return respond(prefix: traveling == true ? "Traveling — noted." : "Not traveling.")
        case .setIllness(let ill):
            store.setIllness(ill)
            return respond(prefix: ill == true ? "Sorry you're under the weather — noted." : "Glad you're well.")
        case .setSleep(let hours):
            store.setSleep(hours: hours)
            return respond(prefix: hours.map { "Logged \(String(format: "%g", max(0, $0))) h sleep." } ?? "Sleep cleared.")
        case .setCheckIn(let energy, let mood, let stress, let soreness):
            guard energy != nil || mood != nil || stress != nil || soreness != nil else {
                return Response(text: "Tell me what you felt (energy, mood, stress, or soreness) and I'll log it.", decision: nil, plan: nil)
            }
            store.setCheckIn(energy: energy, mood: mood, stress: stress, soreness: soreness)
            return respond(prefix: "Check-in logged.")
        case .setNote(let note):
            store.setNote(note)
            return respond(prefix: "Noted.")
        case .upsertConstraint(let id, let kind, let location, let severity, let affects):
            let loc = location.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !loc.isEmpty else {
                return Response(text: "I need a body location to log that.", decision: nil, plan: nil)
            }
            store.upsertConstraint(id: id, kind: kind, location: loc, severity: severity, affectsTraining: affects)
            return respond(prefix: "Logged \(loc) — \(kind.rawValue), severity \(min(max(severity, 0), 3))\(affects ? "" : " (not affecting training)").")
        case .resolveConstraint(let id):
            guard store.resolveConstraint(id: id) else {
                return Response(text: "I couldn't find that one to resolve.", decision: nil, plan: nil)
            }
            return respond(prefix: "Marked resolved.")
        }
    }

    // MARK: - Helpers

    private func today() -> (DecisionEngine.Result, PlanningEngine.Plan) {
        store.rolloverIfNeeded()   // never plan today off yesterday's context
        return PlanAssembler.assemble(base: base, dailyContext: store.daily, constraints: store.activeConstraints, style: style)
    }

    private func respond(prefix: String?) -> Response {
        let (d, p) = today()
        let text = [prefix, planLine(d, p)].compactMap { $0 }.joined(separator: " ")
        return Response(text: text, decision: d, plan: p)
    }

    /// Tier-aware so the model never receives a score it hasn't earned — the same honesty the Today
    /// screen enforces. No evidence → say so and gather; partial → plan without a number; established
    /// → the full readiness number.
    private func planLine(_ d: DecisionEngine.Result, _ p: PlanningEngine.Plan) -> String {
        switch d.evidenceTier {
        case .none:
            return "Not enough evidence yet for a real readiness. Gather something about today — sleep, how they feel, an HRV reading, or any injury/constraint — before stating a plan or a score."
        case .partial:
            return "Plan: \(p.summary) (certainty \(d.certainty.rawValue); no readiness number yet — evidence is still thin, don't invent one)."
        case .established:
            return "Plan: \(p.summary) (readiness \(d.score), \(d.band.rawValue); certainty \(d.certainty.rawValue))."
        }
    }

    private func explanation(_ d: DecisionEngine.Result, _ p: PlanningEngine.Plan) -> String {
        guard d.evidenceTier != .none else { return planLine(d, p) }
        var s = planLine(d, p)
        if let lim = d.primaryLimiter { s += " Main limiter: \(lim.title.lowercased())." }
        if !p.why.isEmpty { s += " Why: " + p.why.joined(separator: " ") }
        if !p.avoid.isEmpty { s += " Avoid: " + p.avoid.joined(separator: ", ") + "." }
        return s
    }
}
