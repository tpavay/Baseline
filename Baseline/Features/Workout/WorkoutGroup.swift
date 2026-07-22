import Foundation

enum RepetitionRule: Codable, Equatable, Sendable {
    case once
    case count(Int)
    case until(seconds: Int)

    var fixedCount: Int? {
        if case .count(let count) = self { return max(count, 1) }
        return nil
    }

    var durationSeconds: Int? {
        if case .until(let seconds) = self { return max(seconds, 0) }
        return nil
    }
}

enum CadenceScope: String, Codable, Equatable, Sendable {
    case child
    case cycle
}

struct StartCadence: Codable, Equatable, Sendable {
    var intervalSeconds: Int
    var scope: CadenceScope

    init(intervalSeconds: Int, scope: CadenceScope) {
        self.intervalSeconds = max(intervalSeconds, 1)
        self.scope = scope
    }
}

enum ScoringMethod: Codable, Equatable, Sendable {
    case completion
    case elapsedTime(capSeconds: Int?)
    case roundsAndReps
    case total(metric: MetricType)
}

struct GroupExecution: Codable, Equatable, Sendable {
    var repetition: RepetitionRule = .once
    var cadence: StartCadence?
    var scoring: ScoringMethod?
    var totalTargets = MetricValues()
    var adjustments: [MetricAdjustment] = []
}

enum RestPlacement: String, Codable, Equatable, Sendable {
    case inline
    case betweenRepetitions
    case afterEveryRepetition
    case afterFinalRepetition
}

struct PlannedRest: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var durationSeconds: Int?
    var placement: RestPlacement = .inline
    var label: String = "Rest"
    var guidance: String?
}

struct WorkoutGroup: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var label: String
    var phase: WorkoutPhase?
    var execution = GroupExecution()
    var children: [WorkoutNode] = []
    var guidance: CoachGuidance?
    var doseLayer: DoseLayer?
    var isOptional = false
}

struct WorkoutChoice: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var label: String
    var options: [WorkoutNode]
    var selectionCount = 1
}

extension GroupExecution {
    /// A group whose work repeats logs per round; a `.once` or `.count(1)` wrapper renders flat.
    var isRepeated: Bool {
        switch repetition {
        case .once: false
        case .count(let count): count > 1
        case .until: true
        }
    }
}

/// One shared expansion of a repeated group into rounds and their exercises. The round selector,
/// the agent's active-session snapshot, and any other surface must agree on which (group, iteration)
/// pairs exist, or work logged through one surface becomes invisible on another.
extension WorkoutGroup {
    /// No surface renders or targets more rounds than this.
    static let maxLoggedIterations = 500

    /// The group's round count exactly as the athlete's round selector shows it.
    /// While logging, an `.until` group exposes every completed round plus the one in progress;
    /// a completed session settles on the rounds that actually hold work.
    func iterationCount(log: WorkoutLog?, isLogging: Bool) -> Int {
        switch execution.repetition {
        case .count(let count):
            return min(max(count, 1), Self.maxLoggedIterations)
        case .until:
            let completed = log?.groups.first { $0.plannedGroupID == id }?.completedIterations ?? 0
            let maxLogged = log?.exercises.flatMap(\.setLogs)
                .filter { $0.groupID == id }
                .compactMap(\.iteration)
                .max() ?? 0
            let visible = isLogging ? completed + 1 : max(completed, maxLogged)
            return min(max(visible, 1), Self.maxLoggedIterations)
        case .once:
            return 1
        }
    }

    /// The exercises performed during one round, honoring a per-child cadence (an EMOM cycles one
    /// child per round) and resolving choices from the session's selections. Rest nodes hold no
    /// logged sets and are excluded.
    func exercises(forIteration iteration: Int, choiceSelections: [UUID: Set<UUID>]) -> [PlannedExercise] {
        let workload = children.filter { node in
            if case .rest = node { return false }
            return true
        }
        let nodes: [WorkoutNode]
        if execution.cadence?.scope == .child, !workload.isEmpty {
            nodes = [workload[(iteration - 1) % workload.count]]
        } else {
            nodes = workload
        }
        return nodes.flatMap { $0.resolvedExercises(choiceSelections: choiceSelections) }
    }
}

