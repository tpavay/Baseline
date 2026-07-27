import Foundation

/// The **Plan domain model** — pure value types for the week-level schedule (see
/// `docs/implementation/plan-tab.md`). SwiftData never appears here; `@Model` adapters map to/from these
/// in the repository, and the engines/UI use only these. The leaf `Workout → Block → Exercise → Set`
/// model is reused unchanged; a `ScheduledWorkout` wraps a *revision* of it.
///
/// Invariants encoded here:
/// - **Immutable origin.** Where a workout came from never changes; who edited it lives in version history.
/// - **Immutable revisions.** A plan edit makes a new `WorkoutRevision`; ids of exercises/sets are
///   *preserved* across revisions (the durable `ExerciseInstanceID`), so per-exercise history works.
/// - **Phases are optional folders.** A workout belongs to a `Program` and a `date`; `ProgramSection`
///   groups only when a program actually has phases.
/// - **Performed ≠ intent.** Sessions/logs are separate records, keyed by `scheduledWorkoutID`, never
///   embedded on the schedule — so plan restore can't rewind performed history.

// MARK: - Identity & classification

/// Immutable: WHERE a workout originated. `legacyMigrated` = pre-existing app state moved into the new store.
enum WorkoutOrigin: String, Codable, Sendable, CaseIterable {
    case imported, baselineGenerated, userCreated, coachAuthored, legacyMigrated
}

/// AM/PM/other — lets a hybrid athlete carry two sessions on one day. `nil` = unspecified single session.
enum TimeOfDay: String, Codable, Sendable, CaseIterable { case morning, midday, evening }

/// Cross-cutting labels on a scheduled workout — power filtering, replace-all, and intensity distribution.
enum WorkoutTag: String, Codable, Sendable, CaseIterable {
    case threshold, strength, recovery, mobility, capacity, durability, raceSpecific, aerobic, speed
}

/// Modeled now, unused in v1 — the schema anticipates "every Tuesday" / "every 3 weeks" without a later
/// `@Model` migration. Generation of recurring instances ships with programs/import.
enum RecurrenceRule: Codable, Sendable, Equatable {
    case none
    case weekly(weekdays: [Int])          // 1 = Sunday … 7 = Saturday
    case everyNDays(Int)
    case everyNWeeks(Int, weekday: Int)
}

// MARK: - Program & grouping

/// A goal a program advances (e.g. "Sub-60 HYROX", "Improve threshold"). Owned by the program so
/// workouts *reference* goals instead of inventing them.
struct ProgramGoal: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var programID: UUID
    var text: String
    var kind: String?                     // free-form for now (endurance/strength/health/skill…)
}

struct Program: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var isActive = true
    var isArchived = false
    var createdAt: Date
    var goals: [ProgramGoal] = []         // may be empty — not every program has explicit goals
}

/// The renamed "Phase" — an **optional** grouping (Base / Build / Peak). Created only when a program has
/// real phases; general and ad-hoc plans have none.
struct ProgramSection: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var programID: UUID
    var name: String
    var role: String?                     // e.g. "deload", "race-prep"
    var startDate: Date?
    var endDate: Date?
}

// MARK: - Content revisions & templates

/// The leaf workout content at a point in time. A plan edit creates a NEW revision; the old one is never
/// mutated, so `restore` brings back exact content. Exercise/set ids are preserved across revisions.
struct WorkoutRevision: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var workoutID: UUID                   // stable identity of the workout across all its revisions
    var createdAt: Date
    var workout: Workout
}

/// A reusable workout source that can be scheduled many times and copied between programs. Modeled so
/// `templateID` exists from day one; image/text import becomes its primary authoring path.
struct WorkoutTemplate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var currentRevisionID: UUID
    var tags: [WorkoutTag] = []
}

// MARK: - Scheduled workout (plan intent)

/// One workout placed on a day inside a program. Carries plan *intent* only — no performed state. The
/// resolved `workout`/`workoutRevisionID` is the current revision's content (the repo hydrates it); the
/// snapshot/versioning references the revision by id.
struct ScheduledWorkout: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var programID: UUID
    var date: Date
    var timeOfDay: TimeOfDay?
    var origin: WorkoutOrigin
    var workoutID: UUID
    var workoutRevisionID: UUID
    var workout: Workout                  // resolved current revision content (for UI/resolvers)
    var sectionID: UUID?                  // optional phase-as-folder
    var templateID: UUID?                 // the template this was instantiated from (attribution)
    var templateRevisionID: UUID?         // which template *revision* — so template edits never touch this
    var tags: [WorkoutTag] = []
    var supportsGoalIDs: [UUID] = []
    var recurrence: RecurrenceRule?       // fwd-compat, unused in v1
    var skipped = false
    /// Stable display order among sessions sharing a calendar day.
    ///
    /// This is deliberately separate from `timeOfDay`: morning/midday/evening describes intent,
    /// while drag order is an arbitrary user-owned sequence that can contain more than three sessions.
    /// Nil is the backward-compatible value for schedules written before drag ordering shipped.
    var dayOrder: Int? = nil
}

// MARK: - Derived calendar projections (NOT stored)

struct TrainingDay: Identifiable, Sendable {
    var id: Date { date }
    var date: Date
    var sessions: [ScheduledWorkout]      // 0..n
    /// The athlete explicitly marked this day a rest day. Distinguishes a *decided* rest day from a
    /// day that merely has nothing planned yet. Display-only when `sessions` is non-empty.
    var isRestDay = false
}

struct TrainingWeek: Sendable {
    var startDate: Date
    var days: [TrainingDay]               // always 7, in order
}

// MARK: - Performed lifecycle (separate from intent; append-only)

enum SessionStatus: String, Codable, Sendable { case active, paused, completed, discarded }

/// The mutable in-progress container. On completion it freezes a `CompletedWorkoutLog`.
///
/// `workout` is the session's own copy of the planned training, present only once the athlete edits it
/// mid-workout (add / true-remove / reorder / metric change). Nil ⇒ the session follows the scheduled
/// workout's current revision. It is what the athlete performed against, kept separate from the saved
/// plan until completion reconciliation promotes the changes.
struct WorkoutSession: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var scheduledWorkoutID: UUID
    var startedAt: Date
    var status: SessionStatus = .active
    var log: WorkoutLog
    var workout: Workout? = nil
    /// Revision tokens are changed on every persisted session-workout or performed-log write.
    /// They make delayed agent calls and future targeted session undo stale-safe across relaunches.
    var sessionWorkoutRevisionID: UUID? = nil
    var performedLogRevisionID: UUID? = nil
    /// Whether the "update your plan?" decision for this session is still unanswered — the one shared
    /// fact every store bound to this workout consults to route an agent edit.
    var reconciliationPending: Bool = false
}

/// The frozen, immutable performed fact. Plan restore never touches it; found by `scheduledWorkoutID`.
struct CompletedWorkoutLog: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var scheduledWorkoutID: UUID
    var finishedAt: Date
    var log: WorkoutLog
}

// MARK: - Read models

/// Filter for the Plan tab. `allTraining` merges every active program.
enum ProgramFilter: Equatable, Sendable {
    case allTraining
    case program(UUID)
    case collection(Collection)
    enum Collection: String, Sendable { case adHoc, completed, archived }
}

/// Why a calendar day refuses to take a session.
///
/// A day that has been and gone is history, and a day already holding performed training is a record
/// of what happened rather than a slot to shuffle - so neither accepts scheduling, and neither lets a
/// session leave it either. That single rule has to be resolved in exactly one place: the Plan grid's
/// reorder handles, its drag geometry, its "Move to" destinations and the repository's own
/// `reposition` guard all go through `resolve`, so the UI can never offer a move the repository will
/// refuse and the repository can never refuse one the UI presented as legal.
enum PlanDayLock: Equatable, Sendable {
    case past
    case completed

    static func resolve(isPast: Bool, hasPerformedTraining: Bool) -> PlanDayLock? {
        if isPast { return .past }
        if hasPerformedTraining { return .completed }
        return nil
    }
}

/// One exercise's actuals from a past completed session — the normalized history row behind the Hevy
/// "previous" column, per-exercise history, and PRs. Matched by stable identity.
struct ExercisePerformance: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var completedLogID: UUID
    var date: Date
    var programID: UUID
    var workoutTitle: String
    var exerciseInstanceID: UUID          // survives across revisions
    var exerciseDefinitionID: String?     // stable catalog identity
    var exerciseName: String
    var sets: [MetricValues]              // per-set actuals

    /// Whether the athlete logged any set here at all. A performed record can exist purely to hold a
    /// session note or a status, and such a row has no sets — showing it as history says only that
    /// they typed something. A set ticked complete with no numbers in it (an imported workout whose
    /// prescription is coach text such as "6-8 reps") is training that happened, so it stays.
    var hasLoggedSets: Bool { !sets.isEmpty }
}
