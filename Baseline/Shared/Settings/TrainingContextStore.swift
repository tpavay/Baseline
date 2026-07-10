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

    /// Create or update a constraint. Returns its id. Passing an existing `id` updates it.
    @discardableResult
    func upsertConstraint(id: UUID? = nil, kind: DecisionEngine.Constraint.Kind, location: String,
                          severity: Int, affectsTraining: Bool = true) -> UUID {
        let sev = min(max(severity, 0), 3)
        if let id, let idx = constraints.firstIndex(where: { $0.id == id }) {
            constraints[idx].kind = kind
            constraints[idx].location = location
            constraints[idx].severity = sev
            constraints[idx].affectsTraining = affectsTraining
            constraints[idx].resolved = false
            constraints[idx].updatedAt = .now
            return id
        }
        let c = ActiveConstraint(kind: kind, location: location, severity: sev, affectsTraining: affectsTraining)
        constraints.append(c)
        return c.id
    }

    func resolveConstraint(id: UUID) {
        guard let idx = constraints.firstIndex(where: { $0.id == id }) else { return }
        constraints[idx].resolved = true
        constraints[idx].updatedAt = .now
    }

    // MARK: - Read for the engine

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
