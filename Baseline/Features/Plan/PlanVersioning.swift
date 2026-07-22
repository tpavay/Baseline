import Foundation

/// Plan **versioning + mutation** value types (`docs/implementation/plan-tab.md` §6–§7). Every schedule
/// change is a typed operation that produces a human-renderable `ScheduleDiff` and appends an
/// **append-only** `PlanVersion` carrying a full post-op `ScheduleSnapshot`. Undo/restore never pop —
/// they append a new version whose snapshot equals the target state. Confirmation-gated mutations
/// (destructive) return a `confirmationRequired` result bound to a stored `PendingPlanProposal` +
/// `expectedHeadVersionID`, so a stale "yes" can't apply an outdated change.

enum PlanOpKind: String, Codable, Sendable {
    case move, swap, reorder, add, duplicate, replace, editContent, skip, unskip, delete, undo, restore
}

/// A human-renderable set of changes — enough for the UI/agent to show a diff before confirming.
struct ScheduleDiff: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case add, remove, move, edit }
        var kind: Kind
        var summary: String
        var scheduledID: UUID?
    }
    var changes: [Change] = []
}

/// The stored plan-intent of one scheduled workout — the unit a snapshot serializes. Excludes performed
/// state (sessions/logs) by design, so restoring a snapshot never rewinds history.
struct ScheduledIntent: Codable, Equatable, Sendable {
    var id: UUID
    var programID: UUID
    var sectionID: UUID?
    var date: Date
    var timeOfDay: TimeOfDay?
    var origin: WorkoutOrigin
    var workoutID: UUID
    var workoutRevisionID: UUID
    var templateID: UUID?
    var templateRevisionID: UUID?
    var tags: [WorkoutTag]
    var supportsGoalIDs: [UUID]
    var skipped: Bool
}

/// A complete, immutable schedule-intent snapshot for one version. References revisions by id
/// (revisions are immutable) — never copies workout blobs.
struct ScheduleSnapshot: Codable, Equatable, Sendable {
    var scheduled: [ScheduledIntent] = []
}

struct PlanOperation: Codable, Equatable, Sendable {
    var id: UUID
    var kind: PlanOpKind
    var actor: PlanActor
    var reason: String?
    var timestamp: Date
    var diff: ScheduleDiff
}

struct PlanVersion: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var actor: PlanActor
    var operation: PlanOperation
    var snapshot: ScheduleSnapshot
    var workoutMutationReceipt: WorkoutMutationReceipt? = nil
}

// MARK: - Workout mutation contract

/// The shared scope vocabulary for every conversational workout mutation.
///
/// A target always carries its authoritative revision token. The caller repeats that token as
/// `expectedRevisionToken`; keeping both values makes a delayed request self-describing while the
/// repository still verifies it against current persisted state immediately before writing.
enum WorkoutMutationScope: String, Codable, Equatable, Sendable {
    case plan
    case sessionWorkout
    case performedLog
    case transient
}

struct WorkoutMutationTarget: Codable, Equatable, Sendable {
    var scope: WorkoutMutationScope
    var scheduledWorkoutID: UUID?
    var sessionID: UUID?
    var workoutID: UUID
    var revisionToken: UUID

    enum CodingKeys: String, CodingKey {
        case scope
        case scheduledWorkoutID = "scheduled_workout_id"
        case sessionID = "session_id"
        case workoutID = "workout_id"
        case revisionToken = "revision_token"
    }
}

/// A domain-level description of what changed. Later composite waves append multiple changes to this
/// same value, so one receipt and one undo continue to represent one user intent.
struct WorkoutMutationDiff: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
            case add, remove, move, replace, edit
        }

        var kind: Kind
        var summary: String
        var entityID: UUID?

        enum CodingKeys: String, CodingKey {
            case kind, summary
            case entityID = "entity_id"
        }
    }

    var changes: [Change]
}

/// Internal input shared by every workout-content tool. Validation and transformation happen against
/// one authoritative value before this request crosses the persistence boundary.
struct WorkoutMutationRequest: Codable, Equatable, Sendable {
    var mutationID: UUID
    var target: WorkoutMutationTarget
    var expectedRevisionToken: UUID
    var actor: PlanActor
    var reason: String
    var diff: WorkoutMutationDiff
    var dryRun: Bool

    enum CodingKeys: String, CodingKey {
        case mutationID = "mutation_id"
        case target
        case expectedRevisionToken = "expected_revision_token"
        case actor, reason, diff
        case dryRun = "dry_run"
    }
}

/// Durable proof of one applied workout mutation. The mutation ID names exactly one persisted plan
/// version or session mutation version, and undo is allowed only while `afterRevisionToken` remains
/// authoritative for that same target.
struct WorkoutMutationReceipt: Codable, Equatable, Sendable, Identifiable {
    var mutationID: UUID
    var scope: WorkoutMutationScope
    var scheduledWorkoutID: UUID?
    var sessionID: UUID?
    var workoutID: UUID
    var beforeRevisionToken: UUID
    var afterRevisionToken: UUID
    var diff: WorkoutMutationDiff
    var actor: PlanActor
    var undoAvailable: Bool

    var id: UUID { mutationID }

    enum CodingKeys: String, CodingKey {
        case mutationID = "mutation_id"
        case scope
        case scheduledWorkoutID = "scheduled_workout_id"
        case sessionID = "session_id"
        case workoutID = "workout_id"
        case beforeRevisionToken = "before_revision_token"
        case afterRevisionToken = "after_revision_token"
        case diff, actor
        case undoAvailable = "undo_available"
    }
}

enum WorkoutMutationError: String, Error, Codable, Equatable, Sendable {
    case notFound
    case invalidTarget
    case staleRevision
    case sessionDiscarded
    case activeSessionConflict
    case undoUnavailable
    case persistenceFailure
}

enum WorkoutMutationResult: Equatable, Sendable {
    case applied(WorkoutMutationReceipt)
    case preview(WorkoutMutationReceipt)
    case rejected(WorkoutMutationError)
}

enum SessionMutationKind: String, Codable, Equatable, Sendable {
    case sessionWorkout
    case performedLog
}

enum SessionMutationSnapshot: Codable, Equatable, Sendable {
    case sessionWorkout(Workout)
    case performedLog(WorkoutLog)
    /// A content mutation that also rewrote the performed log (a logged-actual purge). Undo must
    /// restore both together or it would resurrect a planned set whose actual stayed lost.
    case sessionWorkoutAndLog(Workout, WorkoutLog)
}

/// Append-only persisted history for workout content and performed facts owned by one session.
struct SessionMutationVersion: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var mutationID: UUID
    var kind: SessionMutationKind
    var beforeSnapshot: SessionMutationSnapshot
    var afterRevisionToken: UUID
    var actor: PlanActor
    var timestamp: Date
    var diff: WorkoutMutationDiff
    var receipt: WorkoutMutationReceipt
}

/// A confirmation-gated operation, persisted until the caller resubmits with its id (a bare UUID binds
/// nothing). Applies only if the head version still matches and it hasn't expired.
enum ProposedPlanOperation: Codable, Equatable, Sendable {
    case delete(UUID)
}

struct PlanWarning: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case destructive, occupiedDay, activeSession }
    var kind: Kind
    var message: String
}

enum PlanError: String, Error, Equatable, Sendable {
    case notFound, headMismatch, proposalExpired, invalidTarget, activeSessionConflict, nothingToUndo
}

enum MutationResult: Sendable {
    case applied(diff: ScheduleDiff, version: PlanVersion)
    case confirmationRequired(warnings: [PlanWarning], proposedDiff: ScheduleDiff, proposalID: UUID)
    case rejected(PlanError)

    var appliedDiff: ScheduleDiff? { if case .applied(let d, _) = self { return d }; return nil }
    var isApplied: Bool { if case .applied = self { return true }; return false }
}
