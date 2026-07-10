import Foundation
import Observation

/// The **Context Engine's** local structured state — today's context + active constraints. The
/// chat's tools write here; the Decision Engine reads here. Embodies "structured state is the
/// source of truth": the conversation is an interface, this is the datastore. Local-first
/// (UserDefaults, JSON). Designed so the same mutate → recompute path extends to the future Plan
/// Engine (typed, validated operations), and constraints already feed `DecisionEngine`.
@MainActor
@Observable
final class TrainingContextStore {

    /// Resets each day. Populated by the chat ("only 30 minutes", "no gym", "traveling", "sick").
    struct DailyContext: Codable, Equatable, Sendable {
        var date: Date = .now
        var timeAvailableMinutes: Int?
        var equipment: [String]?
        var traveling: Bool?
        var illness: Bool?
        var note: String?
        // Reported sleep + subjective check-in (1–5, 5 = most recovered — matches DecisionEngine).
        // These are context the athlete *reports* in conversation and they feed the score, unlike a
        // free-text `note`.
        var sleepHours: Double?
        var energy: Double?
        var mood: Double?
        var stress: Double?
        var soreness: Double?
    }

    /// A persistent injury/pain constraint — survives until resolved; gates the plan even on a
    /// green day. Maps to `DecisionEngine.Constraint` for scoring.
    struct ActiveConstraint: Codable, Equatable, Identifiable, Sendable {
        var id: UUID = UUID()
        var kind: DecisionEngine.Constraint.Kind    // injury | pain
        var location: String
        var severity: Int                            // 0…3
        var affectsTraining: Bool = true
        var resolved: Bool = false
        var createdAt: Date = .now
        var updatedAt: Date = .now
    }

    private(set) var daily: DailyContext { didSet { persist(daily, Keys.daily) } }
    private(set) var constraints: [ActiveConstraint] { didSet { persist(constraints, Keys.constraints) } }

    private let defaults: UserDefaults
    private let calendar = Calendar.current
    private enum Keys { static let daily = "context.daily"; static let constraints = "context.constraints" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = defaults.data(forKey: Keys.daily).flatMap { try? JSONDecoder().decode(DailyContext.self, from: $0) }
        // A stale daily context (not today) rolls over to empty.
        daily = loaded.map { Calendar.current.isDateInToday($0.date) ? $0 : DailyContext() } ?? DailyContext()
        constraints = defaults.data(forKey: Keys.constraints)
            .flatMap { try? JSONDecoder().decode([ActiveConstraint].self, from: $0) } ?? []
    }

    /// Roll the daily context over if a new day has started (call on view appearance).
    func rolloverIfNeeded(now: Date = .now) {
        if !calendar.isDate(daily.date, inSameDayAs: now) { daily = DailyContext(date: now) }
    }

    // MARK: - Tool-facing mutations (each maps to one chat tool)

    func setTimeAvailable(_ minutes: Int?) { rolloverIfNeeded(); daily.date = .now; daily.timeAvailableMinutes = minutes }
    func setEquipment(_ equipment: [String]?) { rolloverIfNeeded(); daily.date = .now; daily.equipment = equipment }
    func setTraveling(_ traveling: Bool?) { rolloverIfNeeded(); daily.date = .now; daily.traveling = traveling }
    func setIllness(_ illness: Bool?) { rolloverIfNeeded(); daily.date = .now; daily.illness = illness }
    func setNote(_ note: String?) { rolloverIfNeeded(); daily.date = .now; daily.note = note }
    func setSleep(hours: Double?) { rolloverIfNeeded(); daily.date = .now; daily.sleepHours = hours.map { max(0, $0) } }

    /// Partial update — only the fields the athlete actually described are set, so "I'm stressed"
    /// doesn't wipe a previously-logged energy. Each clamps to 1–5.
    func setCheckIn(energy: Double? = nil, mood: Double? = nil, stress: Double? = nil, soreness: Double? = nil) {
        rolloverIfNeeded(); daily.date = .now
        if let energy { daily.energy = clamp15(energy) }
        if let mood { daily.mood = clamp15(mood) }
        if let stress { daily.stress = clamp15(stress) }
        if let soreness { daily.soreness = clamp15(soreness) }
    }
    private func clamp15(_ v: Double) -> Double { min(max(v, 1), 5) }

    /// Create or update a constraint. Returns its id. Passing an existing `id` updates it. With no
    /// id, an existing *unresolved* constraint for the same location+kind is updated in place rather
    /// than duplicated — the model can only ever create (it isn't handed ids reliably), so without
    /// this a re-mentioned injury spawns duplicate, sometimes contradictory, entries.
    @discardableResult
    func upsertConstraint(id: UUID? = nil, kind: DecisionEngine.Constraint.Kind, location: String,
                          severity: Int, affectsTraining: Bool = true) -> UUID {
        let sev = min(max(severity, 0), 3)
        func apply(_ idx: Int) {
            constraints[idx].kind = kind
            constraints[idx].location = location
            constraints[idx].severity = sev
            constraints[idx].affectsTraining = affectsTraining
            constraints[idx].resolved = false
            constraints[idx].updatedAt = .now
        }
        if let id, let idx = constraints.firstIndex(where: { $0.id == id }) {
            apply(idx); return id
        }
        // Dedupe: fold a no-id repeat into the existing unresolved constraint for this body part.
        let key = normalized(location)
        if id == nil, let idx = constraints.firstIndex(where: {
            !$0.resolved && $0.kind == kind && normalized($0.location) == key
        }) {
            apply(idx); return constraints[idx].id
        }
        let c = ActiveConstraint(kind: kind, location: location, severity: sev, affectsTraining: affectsTraining)
        constraints.append(c)
        return c.id
    }

    private func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Returns whether a matching constraint existed (so callers can report honestly).
    @discardableResult
    func resolveConstraint(id: UUID) -> Bool {
        guard let idx = constraints.firstIndex(where: { $0.id == id }) else { return false }
        constraints[idx].resolved = true
        constraints[idx].updatedAt = .now
        return true
    }

    // MARK: - Read for the engine

    /// Unresolved constraint records (with ids) — for surfacing to the model so it can update or
    /// resolve a specific one instead of creating duplicates.
    var activeConstraintRecords: [ActiveConstraint] { constraints.filter { !$0.resolved } }

    /// Unresolved constraints mapped for `DecisionEngine.Inputs`.
    var activeConstraints: [DecisionEngine.Constraint] {
        constraints.filter { !$0.resolved }
            .map { DecisionEngine.Constraint(kind: $0.kind, location: $0.location,
                                             severity: $0.severity, affectsTraining: $0.affectsTraining) }
    }

    // MARK: - Persistence

    private func persist<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
