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
    enum Call: Sendable {
        case getToday
        case explain
        case setTimeAvailable(Int?)
        case setEquipment([String]?)
        case setTraveling(Bool?)
        case setIllness(Bool?)
        case setNote(String?)
        case upsertConstraint(id: UUID?, kind: DecisionEngine.Constraint.Kind, location: String, severity: Int, affectsTraining: Bool)
        case resolveConstraint(id: UUID)
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
            store.setTimeAvailable(minutes.map { max(0, $0) })
            return respond(prefix: minutes.map { "\($0) min today." } ?? "Time cleared.")
        case .setEquipment(let equipment):
            store.setEquipment(equipment)
            return respond(prefix: "Equipment updated.")
        case .setTraveling(let traveling):
            store.setTraveling(traveling)
            return respond(prefix: traveling == true ? "Traveling — noted." : "Not traveling.")
        case .setIllness(let ill):
            store.setIllness(ill)
            return respond(prefix: ill == true ? "Sorry you're under the weather — noted." : "Glad you're well.")
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
            store.resolveConstraint(id: id)
            return respond(prefix: "Marked resolved.")
        }
    }

    // MARK: - Helpers

    private func today() -> (DecisionEngine.Result, PlanningEngine.Plan) {
        PlanAssembler.assemble(base: base, dailyContext: store.daily, constraints: store.activeConstraints, style: style)
    }

    private func respond(prefix: String?) -> Response {
        let (d, p) = today()
        let text = [prefix, planLine(d, p)].compactMap { $0 }.joined(separator: " ")
        return Response(text: text, decision: d, plan: p)
    }

    private func planLine(_ d: DecisionEngine.Result, _ p: PlanningEngine.Plan) -> String {
        "Plan: \(p.summary) (readiness \(d.score), \(d.band.rawValue); certainty \(d.certainty.rawValue))."
    }

    private func explanation(_ d: DecisionEngine.Result, _ p: PlanningEngine.Plan) -> String {
        var s = planLine(d, p)
        if let lim = d.primaryLimiter { s += " Main limiter: \(lim.title.lowercased())." }
        if !p.why.isEmpty { s += " Why: " + p.why.joined(separator: " ") }
        if !p.avoid.isEmpty { s += " Avoid: " + p.avoid.joined(separator: ", ") + "." }
        return s
    }
}
