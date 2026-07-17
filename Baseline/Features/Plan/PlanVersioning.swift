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
