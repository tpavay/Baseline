import Foundation

/// Raw athlete wording for one performed metric.
///
/// The mapper preserves `valueText` exactly and deterministic domain code converts it later.
/// Numeric JSON values are never accepted for this type.
struct PerformedMetricInput: Equatable, Sendable {
    var metric: MetricType
    var valueText: String
}

/// A set outcome can target a planned row that may not have an actual yet, or an existing extra row.
enum PerformedSetTarget: Equatable, Sendable {
    case planned(
        exerciseInstanceID: UUID,
        plannedSetID: UUID,
        groupID: UUID?,
        iteration: Int?
    )
    case extra(performedSetID: UUID)
}

/// Machine-readable active-session state returned to the model before any performed-log mutation.
struct ActiveSessionToolSnapshot: Codable, Equatable, Sendable {
    struct PlannedSetTarget: Codable, Equatable, Sendable {
        var plannedSetID: UUID
        var groupID: UUID?
        var iteration: Int?
        var plannedValues: MetricValues
        var performedSetID: UUID?
        var performedValues: MetricValues
        var outcome: SetLogOutcome

        enum CodingKeys: String, CodingKey {
            case plannedSetID = "planned_set_id"
            case groupID = "group_id"
            case iteration
            case plannedValues = "planned_values"
            case performedSetID = "performed_set_id"
            case performedValues = "performed_values"
            case outcome
        }
    }

    struct ExtraPerformedSet: Codable, Equatable, Sendable {
        var performedSetID: UUID
        var groupID: UUID?
        var iteration: Int?
        var values: MetricValues
        var outcome: SetLogOutcome

        enum CodingKeys: String, CodingKey {
            case performedSetID = "performed_set_id"
            case groupID = "group_id"
            case iteration, values, outcome
        }
    }

    struct Exercise: Codable, Equatable, Sendable {
        var exerciseInstanceID: UUID
        var catalogDefinitionID: String?
        var name: String
        var selectedMetrics: [MetricType]
        var plannedSets: [PlannedSetTarget]
        var extraPerformedSets: [ExtraPerformedSet]
        var notes: [String]

        enum CodingKeys: String, CodingKey {
            case exerciseInstanceID = "exercise_instance_id"
            case catalogDefinitionID = "catalog_definition_id"
            case name
            case selectedMetrics = "selected_metrics"
            case plannedSets = "planned_sets"
            case extraPerformedSets = "extra_performed_sets"
            case notes
        }
    }

    var scope: WorkoutMutationScope
    var scheduledWorkoutID: UUID
    var sessionID: UUID
    var workoutID: UUID
    var workoutLogID: UUID
    var sessionStatus: SessionStatus
    var startedAt: Date
    var sessionWorkoutRevisionToken: UUID
    var performedLogRevisionToken: UUID
    var exercises: [Exercise]

    enum CodingKeys: String, CodingKey {
        case scope
        case scheduledWorkoutID = "scheduled_workout_id"
        case sessionID = "session_id"
        case workoutID = "workout_id"
        case workoutLogID = "workout_log_id"
        case sessionStatus = "session_status"
        case startedAt = "started_at"
        case sessionWorkoutRevisionToken = "session_workout_revision_token"
        case performedLogRevisionToken = "performed_log_revision_token"
        case exercises
    }
}
