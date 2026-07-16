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

