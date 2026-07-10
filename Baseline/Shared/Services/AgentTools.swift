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
        case openAppleHealthSetup
        // Retrieval — the model asks; the app fetches the truth (HealthKit / the reading store)
        // rather than answering from memory. Executed via `execute` (async).
        case getSleep(nightsAgo: Int)
        case getHRVReadings(limit: Int)
        case getRestingHeartRate(days: Int)
        // Workout editing — build/edit today's structured workout (name-resolved). See WorkoutStore.
        case createWorkout(title: String, goal: String?)
        case addBlock(name: String, intent: String?)
        case addExercise(block: String, name: String, sets: Int?, reps: Int?, load: Double?, durationSeconds: Int?)
        case moveExercise(exercise: String, toBlock: String)
        case removeExercise(exercise: String)
        case updateSet(exercise: String, setNumber: Int, reps: Int?, load: Double?, durationSeconds: Int?, rpe: Double?)
        case getCurrentWorkout

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
            case .openAppleHealthSetup: return "Opened Apple Health setup"
            case .getSleep(let n): return "Retrieved sleep (\(n == 0 ? "last night" : "\(n) nights ago")) from Apple Health"
            case .getHRVReadings(let l): return "Retrieved \(l) recent HRV readings"
            case .getRestingHeartRate(let d): return "Retrieved resting HR (\(d)-day) from Apple Health"
            case .createWorkout(let t, _): return "Created workout: \(t)"
            case .addBlock(let n, _): return "Added block: \(n)"
            case .addExercise(let b, let n, _, _, _, _): return "Added \(n) to \(b)"
            case .moveExercise(let e, let b): return "Moved \(e) → \(b)"
            case .removeExercise(let e): return "Removed \(e)"
            case .updateSet(let e, let n, _, _, _, _): return "Updated set \(n) of \(e)"
            case .getCurrentWorkout: return "Read the current workout"
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

    /// Live app state the model needs to answer "how do I…" and to *do* things (not just describe
    /// them). `health` powers Apple Health capability status + the connect action; `hrvConfigured`
    /// reflects whether a reading source is set up.
    private let health: HealthService?
    private let hrvConfigured: Bool
    private let readings: [Reading]              // recent HRV readings, newest first — for retrieval
    private let workouts: WorkoutStore?         // today's structured workout the chat can edit

    init(store: TrainingContextStore, base: DecisionEngine.Inputs = .init(), style: PlanningEngine.Style = .balanced,
         health: HealthService? = nil, hrvConfigured: Bool = false, readings: [Reading] = [], workouts: WorkoutStore? = nil) {
        self.store = store
        self.base = base
        self.style = style
        self.health = health
        self.hrvConfigured = hrvConfigured
        self.readings = readings
        self.workouts = workouts
    }

    // MARK: - Async execution (retrieval tools do real I/O; state tools stay synchronous)

    /// The entry point the conversation runtime calls. Retrieval tools fetch from HealthKit / the
    /// reading store; everything else falls through to the synchronous `dispatch`.
    func execute(_ call: Call) async -> Response {
        switch call {
        case .getSleep(let nightsAgo): return await retrieveSleep(nightsAgo: nightsAgo)
        case .getHRVReadings(let limit): return retrieveReadings(limit: limit)
        case .getRestingHeartRate(let days): return await retrieveRestingHR(days: days)
        default: return dispatch(call)
        }
    }

    private func retrieveSleep(nightsAgo: Int) async -> Response {
        guard let health, health.isAvailable else {
            return Response(text: "Apple Health isn't available on this device, so I can't pull sleep.", decision: nil, plan: nil)
        }
        guard health.requested else {
            return Response(text: "Apple Health isn't set up yet, so there's nothing to read — that's different from the athlete having no sleep logged. Offer to connect it with open_apple_health_setup.", decision: nil, plan: nil)
        }
        let when = nightsAgo == 0 ? "last night" : "\(nightsAgo) night\(nightsAgo == 1 ? "" : "s") ago"
        guard let s = await health.sleepSummary(nightsAgo: nightsAgo) else {
            return Response(text: "Apple Health has no sleep recorded for \(when).", decision: nil, plan: nil)
        }
        // Raw Apple Health numbers, kept distinct from Baseline's own computed score.
        let h = Int(s.hours), m = Int((s.hours - Double(h)) * 60)
        var parts = ["\(h)h \(m)m asleep"]
        if let d = s.deepHours { parts.append("\(Int((d * 60).rounded())) min deep") }
        if let r = s.remHours { parts.append("\(Int((r * 60).rounded())) min REM") }
        if let e = s.efficiency { parts.append("\(Int((e * 100).rounded()))% efficiency") }
        var text = "Apple Health, \(when): " + parts.joined(separator: ", ") + "."
        if let score = ReadinessScore.sleepScore(hours: s.hours, efficiency: s.efficiency) {
            text += " Baseline's own sleep score (computed from this, not an Apple number): \(Int(score.rounded()))/100."
        }
        return Response(text: text, decision: nil, plan: nil)
    }

    private func retrieveReadings(limit: Int) -> Response {
        let recent = readings.prefix(max(1, min(limit, 30)))
        guard !recent.isEmpty else {
            return Response(text: "No HRV readings are on file yet — the athlete hasn't taken one in Baseline.", decision: nil, plan: nil)
        }
        let list = recent.map {
            "\($0.date.formatted(date: .abbreviated, time: .shortened)) — RMSSD \(Int($0.rmssd.rounded())) ms, HR \(Int($0.meanHR.rounded())) bpm (\($0.kind.title))"
        }.joined(separator: "; ")
        return Response(text: "Recent Baseline HRV readings, newest first: \(list).", decision: nil, plan: nil)
    }

    private func retrieveRestingHR(days: Int) async -> Response {
        guard let health, health.isAvailable else {
            return Response(text: "Apple Health isn't available on this device, so I can't pull resting heart rate.", decision: nil, plan: nil)
        }
        guard health.requested else {
            return Response(text: "Apple Health isn't set up yet, so there's no resting heart rate to read (NOT 'no data'). Offer to connect it with open_apple_health_setup.", decision: nil, plan: nil)
        }
        let d = max(1, min(days, 90))
        let samples = await health.restingHeartRate(days: d)
        guard let latest = samples.first else {
            return Response(text: "Apple Health has no resting heart-rate samples in the last \(d) days.", decision: nil, plan: nil)
        }
        let avg = samples.map(\.bpm).reduce(0, +) / Double(samples.count)
        let list = samples.prefix(7).map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \(Int($0.bpm.rounded())) bpm" }.joined(separator: "; ")
        return Response(text: "Apple Health resting HR — latest \(Int(latest.bpm.rounded())) bpm, \(d)-day average \(Int(avg.rounded())) bpm. Recent: \(list).", decision: nil, plan: nil)
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
        case .openAppleHealthSetup:
            guard let health, health.isAvailable else {
                return Response(text: "Apple Health isn't available on this device.", decision: nil, plan: nil)
            }
            Task { await health.requestReadAccess() }
            return Response(text: "Opening Apple Health — grant read access in the sheet and I'll fold your sleep and resting HR into today's plan.", decision: nil, plan: nil)
        case .createWorkout(let title, let goal):
            guard let workouts else { return workoutUnavailable() }
            workouts.create(title: title, goal: goal)
            return workoutResponse(prefix: "Created workout \"\(title)\".")
        case .addBlock(let name, let intent):
            guard let workouts else { return workoutUnavailable() }
            guard workouts.addBlock(name: name, intent: intent) else {
                return Response(text: "There's no workout yet — create one first.", decision: nil, plan: nil)
            }
            return workoutResponse(prefix: "Added block \"\(name)\".")
        case .addExercise(let block, let name, let sets, let reps, let load, let dur):
            guard let workouts else { return workoutUnavailable() }
            return outcome(workouts.addExercise(name: name, toBlockNamed: block, sets: sets, reps: reps, load: load, durationSeconds: dur),
                           success: "Added \(name) to \(block).")
        case .moveExercise(let exercise, let toBlock):
            guard let workouts else { return workoutUnavailable() }
            return outcome(workouts.moveExercise(named: exercise, toBlockNamed: toBlock),
                           success: "Moved \(exercise) to \(toBlock).")
        case .removeExercise(let exercise):
            guard let workouts else { return workoutUnavailable() }
            return outcome(workouts.removeExercise(named: exercise), success: "Removed \(exercise).")
        case .updateSet(let exercise, let n, let reps, let load, let dur, let rpe):
            guard let workouts else { return workoutUnavailable() }
            return outcome(workouts.updateSet(exerciseNamed: exercise, setNumber: n, reps: reps, load: load, durationSeconds: dur, rpe: rpe),
                           success: "Updated set \(n) of \(exercise).")
        case .getCurrentWorkout:
            guard let workouts else { return workoutUnavailable() }
            return Response(text: workouts.summary, decision: nil, plan: nil)
        case .getSleep, .getHRVReadings, .getRestingHeartRate:
            // Retrieval is async — routed through `execute`, never here.
            return Response(text: "", decision: nil, plan: nil)
        }
    }

    private func workoutUnavailable() -> Response {
        Response(text: "Workout editing isn't available in this context.", decision: nil, plan: nil)
    }

    /// Turn a name-resolved edit into a reply: on success echo the refreshed workout; on not-found
    /// or ambiguity, hand the model the message so it asks the athlete which one (never guesses).
    private func outcome(_ o: WorkoutStore.EditOutcome, success: String) -> Response {
        switch o {
        case .done: return workoutResponse(prefix: success)
        case .notFound(let m), .ambiguous(let m): return Response(text: m, decision: nil, plan: nil)
        }
    }

    /// After a workout edit, hand the model the refreshed structure so its reply reflects the truth.
    private func workoutResponse(prefix: String) -> Response {
        let text = [prefix, workouts?.summary].compactMap { $0 }.joined(separator: "\n")
        return Response(text: text, decision: nil, plan: nil)
    }

    // MARK: - Helpers

    private func today() -> (DecisionEngine.Result, PlanningEngine.Plan) {
        store.rolloverIfNeeded()   // never plan today off yesterday's context
        return PlanAssembler.assemble(base: base, dailyContext: store.daily, constraints: store.activeConstraints, style: style)
    }

    /// The model's **memory**: today's plan plus the durable structured state that persists across
    /// conversations (constraints + logged context). The raw transcript resets each session by
    /// design — this is what makes a fresh conversation still know the athlete. Sent as the system
    /// context on every request.
    func contextSummary() -> String {
        let (d, p) = today()
        var lines = [planLine(d, p)]

        let constraints = store.activeConstraintRecords
        if !constraints.isEmpty {
            let list = constraints.map {
                "\($0.location) (\($0.kind.rawValue), severity \($0.severity)/3\($0.affectsTraining ? "" : ", not limiting training")) [id \($0.id.uuidString)]"
            }.joined(separator: "; ")
            lines.append("Active constraints (persist until resolved — to change or clear one, pass its id; don't create a duplicate): \(list).")
        }

        let dc = store.daily
        var ctx: [String] = []
        if let s = dc.sleepHours { ctx.append("slept \(String(format: "%g", s))h") }
        if let e = dc.energy { ctx.append("energy \(Int(e))/5") }
        if let m = dc.mood { ctx.append("mood \(Int(m))/5") }
        if let s = dc.stress { ctx.append("stress \(Int(s))/5") }
        if let so = dc.soreness { ctx.append("soreness \(Int(so))/5") }
        if let t = dc.timeAvailableMinutes { ctx.append("\(t) min available") }
        if let eq = dc.equipment, !eq.isEmpty { ctx.append("equipment: \(eq.joined(separator: ", "))") }
        if dc.traveling == true { ctx.append("traveling") }
        if dc.illness == true { ctx.append("feeling unwell") }
        if let n = dc.note, !n.isEmpty { ctx.append("note: \(n)") }
        if !ctx.isEmpty { lines.append("Logged for today: \(ctx.joined(separator: "; ")).") }

        if constraints.isEmpty && ctx.isEmpty {
            lines.append("Nothing else has been recorded yet — no injuries, sleep, check-in, or context on file.")
        }

        lines.append(capabilityLine())
        lines.append(retrievableLine())
        return lines.joined(separator: "\n")
    }

    /// The honest menu of what the model can actually fetch on request — so it offers exactly these
    /// and never over-claims (e.g. promising resting-HR retrieval it has no tool for).
    private func retrievableLine() -> String {
        var items = ["recent HRV readings (get_hrv_readings)"]
        // Health-backed retrieval is only real once setup was requested — advertising it before then
        // would let the model claim "no sleep recorded" when the truth is "not connected".
        if let health, health.isAvailable, health.requested {
            items.insert("sleep for a recent night (get_sleep)", at: 0)
            items.append("resting heart-rate trend (get_resting_heart_rate)")
        }
        return "You can look these up when the athlete asks — nothing else: " + items.joined(separator: ", ") + "."
    }

    /// Live capability state, so the model answers "how do I…" from fact — not guesses — and knows
    /// which action tools it can invoke.
    private func capabilityLine() -> String {
        var caps: [String] = []
        if let health {
            if !health.isAvailable {
                caps.append("Apple Health not available on this device")
            } else if health.requested {
                caps.append("Apple Health access set up (Apple doesn't reveal read-grant status, so data may still be empty)")
            } else {
                caps.append("Apple Health supported but not set up — call open_apple_health_setup to connect it (imports sleep + resting HR, raises certainty)")
            }
        }
        caps.append("HRV reading supported via chest strap or phone camera\(hrvConfigured ? " (set up)" : " (not set up yet)") — a 2:30 morning reading on the Today screen adds autonomic evidence")
        return "Baseline capabilities right now: " + caps.joined(separator: "; ") + "."
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
