import Foundation
import SwiftData

/// SwiftData **persistence adapters** for the Plan domain (`docs/implementation/plan-tab.md` §5). These
/// are storage only — the domain value types in `PlanModel.swift` are canonical; the repository maps
/// between them. Engines/UI never touch these.
///
/// CloudKit-safe per CLAUDE.md: no `@Attribute(.unique)`, every stored property has a default or is
/// optional, and cross-entity links are plain `UUID` foreign keys (not SwiftData relationships), so there
/// are no relationship-optionality traps. Blob payloads (`*JSON`) are Codable value types encoded to
/// `Data`. All models are registered from day one so the schema is stable across slices even where a
/// model has no v1 UI (versions / proposals / templates).

@Model final class SDProgram {
    var id: UUID = UUID()
    var name: String = ""
    var isActive: Bool = true
    var isArchived: Bool = false
    var createdAt: Date = Date.distantPast
    var goalsJSON: Data?
    init(id: UUID = UUID(), name: String = "", isActive: Bool = true, isArchived: Bool = false,
         createdAt: Date = Date.distantPast, goalsJSON: Data? = nil) {
        self.id = id; self.name = name; self.isActive = isActive; self.isArchived = isArchived
        self.createdAt = createdAt; self.goalsJSON = goalsJSON
    }
}

@Model final class SDProgramSection {
    var id: UUID = UUID()
    var programID: UUID = UUID()
    var name: String = ""
    var role: String?
    var startDate: Date?
    var endDate: Date?
    init(id: UUID = UUID(), programID: UUID = UUID(), name: String = "", role: String? = nil,
         startDate: Date? = nil, endDate: Date? = nil) {
        self.id = id; self.programID = programID; self.name = name; self.role = role
        self.startDate = startDate; self.endDate = endDate
    }
}

@Model final class SDScheduledWorkout {
    var id: UUID = UUID()
    var programID: UUID = UUID()
    var sectionID: UUID?
    var originRaw: String = WorkoutOrigin.userCreated.rawValue
    var date: Date = Date.distantPast
    var timeOfDayRaw: String?
    var skipped: Bool = false
    var workoutID: UUID = UUID()
    var workoutRevisionID: UUID = UUID()
    var templateID: UUID?
    var templateRevisionID: UUID?
    var tagsJSON: Data?
    var supportsGoalIDsJSON: Data?
    var recurrenceJSON: Data?
    init(id: UUID = UUID(), programID: UUID = UUID(), sectionID: UUID? = nil,
         originRaw: String = WorkoutOrigin.userCreated.rawValue, date: Date = Date.distantPast,
         timeOfDayRaw: String? = nil, skipped: Bool = false, workoutID: UUID = UUID(),
         workoutRevisionID: UUID = UUID(), templateID: UUID? = nil, templateRevisionID: UUID? = nil,
         tagsJSON: Data? = nil, supportsGoalIDsJSON: Data? = nil, recurrenceJSON: Data? = nil) {
        self.id = id; self.programID = programID; self.sectionID = sectionID; self.originRaw = originRaw
        self.date = date; self.timeOfDayRaw = timeOfDayRaw; self.skipped = skipped
        self.workoutID = workoutID; self.workoutRevisionID = workoutRevisionID
        self.templateID = templateID; self.templateRevisionID = templateRevisionID
        self.tagsJSON = tagsJSON; self.supportsGoalIDsJSON = supportsGoalIDsJSON; self.recurrenceJSON = recurrenceJSON
    }
}

@Model final class SDWorkoutRevision {
    var id: UUID = UUID()
    var workoutID: UUID = UUID()
    var createdAt: Date = Date.distantPast
    var workoutJSON: Data = Data()
    init(id: UUID = UUID(), workoutID: UUID = UUID(), createdAt: Date = Date.distantPast, workoutJSON: Data = Data()) {
        self.id = id; self.workoutID = workoutID; self.createdAt = createdAt; self.workoutJSON = workoutJSON
    }
}

@Model final class SDWorkoutTemplate {   // fwd-compat (no v1 authoring)
    var id: UUID = UUID()
    var name: String = ""
    var currentRevisionID: UUID = UUID()
    var tagsJSON: Data?
    init(id: UUID = UUID(), name: String = "", currentRevisionID: UUID = UUID(), tagsJSON: Data? = nil) {
        self.id = id; self.name = name; self.currentRevisionID = currentRevisionID; self.tagsJSON = tagsJSON
    }
}

@Model final class SDWorkoutSession {
    var id: UUID = UUID()
    var scheduledWorkoutID: UUID = UUID()
    var startedAt: Date = Date.distantPast
    var statusRaw: String = SessionStatus.active.rawValue
    var logJSON: Data = Data()
    /// The session's own copy of the planned `Workout`, encoded to JSON — present only once the athlete
    /// makes a mid-workout structural/metric edit. Nil ⇒ the session inherits the scheduled workout's
    /// current revision unchanged. This decouples in-workout edits from the saved plan until completion
    /// reconciliation opts in. Optional with a nil default, so it is a lightweight SwiftData migration
    /// and CloudKit-safe (matches the entity conventions in this file).
    var sessionWorkoutJSON: Data?
    var sessionWorkoutRevisionID: UUID?
    var performedLogRevisionID: UUID?
    /// Whether this session's "update your plan?" decision is still unanswered. It describes the
    /// *session*, so it lives here rather than on whichever `WorkoutStore` happened to start it — two
    /// stores are bound to the same scheduled workout at once (the Plan tab's execution store and the
    /// app-level agent store) and they must not disagree. Written only at lifecycle moments: true when
    /// the session is created, false when the athlete accepts, declines, discards, or finishes a session
    /// that did not diverge. Nil (a row from before this field existed) means *not* pending.
    var reconciliationPending: Bool?
    init(id: UUID = UUID(), scheduledWorkoutID: UUID = UUID(), startedAt: Date = Date.distantPast,
         statusRaw: String = SessionStatus.active.rawValue, logJSON: Data = Data(),
         sessionWorkoutJSON: Data? = nil, sessionWorkoutRevisionID: UUID? = nil,
         performedLogRevisionID: UUID? = nil, reconciliationPending: Bool? = nil) {
        self.id = id; self.scheduledWorkoutID = scheduledWorkoutID; self.startedAt = startedAt
        self.statusRaw = statusRaw; self.logJSON = logJSON; self.sessionWorkoutJSON = sessionWorkoutJSON
        self.sessionWorkoutRevisionID = sessionWorkoutRevisionID
        self.performedLogRevisionID = performedLogRevisionID
        self.reconciliationPending = reconciliationPending
    }
}

/// Append-only mutation history for one session. The before snapshot is a tagged domain value, and
/// `afterRevisionToken` binds a future targeted undo to the exact state this mutation produced.
@Model final class SDSessionMutationVersion {
    var id: UUID = UUID()
    var sessionID: UUID = UUID()
    var mutationID: UUID = UUID()
    var kindRaw: String = SessionMutationKind.sessionWorkout.rawValue
    var beforeSnapshotJSON: Data = Data()
    var afterRevisionToken: UUID = UUID()
    var actorRaw: String = PlanActor.agent.rawValue
    var timestamp: Date = Date.distantPast
    var diffJSON: Data = Data()
    var workoutMutationReceiptJSON: Data = Data()

    init(
        id: UUID = UUID(),
        sessionID: UUID = UUID(),
        mutationID: UUID = UUID(),
        kindRaw: String = SessionMutationKind.sessionWorkout.rawValue,
        beforeSnapshotJSON: Data = Data(),
        afterRevisionToken: UUID = UUID(),
        actorRaw: String = PlanActor.agent.rawValue,
        timestamp: Date = Date.distantPast,
        diffJSON: Data = Data(),
        workoutMutationReceiptJSON: Data = Data()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.mutationID = mutationID
        self.kindRaw = kindRaw
        self.beforeSnapshotJSON = beforeSnapshotJSON
        self.afterRevisionToken = afterRevisionToken
        self.actorRaw = actorRaw
        self.timestamp = timestamp
        self.diffJSON = diffJSON
        self.workoutMutationReceiptJSON = workoutMutationReceiptJSON
    }
}

@Model final class SDCompletedLog {   // append-only, never rewound
    var id: UUID = UUID()
    var scheduledWorkoutID: UUID = UUID()
    var finishedAt: Date = Date.distantPast
    var logJSON: Data = Data()
    init(id: UUID = UUID(), scheduledWorkoutID: UUID = UUID(), finishedAt: Date = Date.distantPast, logJSON: Data = Data()) {
        self.id = id; self.scheduledWorkoutID = scheduledWorkoutID; self.finishedAt = finishedAt; self.logJSON = logJSON
    }
}

@Model final class SDCompletedExercise {   // normalized index for history/PRs/previous
    var id: UUID = UUID()
    var completedLogID: UUID = UUID()
    var date: Date = Date.distantPast
    var programID: UUID = UUID()
    var workoutTitle: String = ""              // snapshot of the workout's title at completion (historical fact)
    var exerciseInstanceID: UUID = UUID()
    var exerciseDefinitionID: String?
    var exerciseName: String = ""
    var metricsJSON: Data = Data()
    init(id: UUID = UUID(), completedLogID: UUID = UUID(), date: Date = Date.distantPast, programID: UUID = UUID(),
         workoutTitle: String = "", exerciseInstanceID: UUID = UUID(), exerciseDefinitionID: String? = nil,
         exerciseName: String = "", metricsJSON: Data = Data()) {
        self.id = id; self.completedLogID = completedLogID; self.date = date; self.programID = programID
        self.workoutTitle = workoutTitle; self.exerciseInstanceID = exerciseInstanceID
        self.exerciseDefinitionID = exerciseDefinitionID; self.exerciseName = exerciseName; self.metricsJSON = metricsJSON
    }
}

@Model final class SDPlanVersion {   // append-only history (Slice 2)
    var id: UUID = UUID()
    var timestamp: Date = Date.distantPast
    var actorRaw: String = PlanActor.user.rawValue
    var operationJSON: Data = Data()
    var snapshotJSON: Data = Data()
    var workoutMutationReceiptJSON: Data?
    init(id: UUID = UUID(), timestamp: Date = Date.distantPast, actorRaw: String = PlanActor.user.rawValue,
         operationJSON: Data = Data(), snapshotJSON: Data = Data(), workoutMutationReceiptJSON: Data? = nil) {
        self.id = id; self.timestamp = timestamp; self.actorRaw = actorRaw
        self.operationJSON = operationJSON; self.snapshotJSON = snapshotJSON
        self.workoutMutationReceiptJSON = workoutMutationReceiptJSON
    }
}

@Model final class SDPendingProposal {   // confirmation binding (Slice 2)
    var id: UUID = UUID()
    var operationJSON: Data = Data()
    var expectedHeadVersionID: UUID?
    var diffJSON: Data = Data()
    var warningsJSON: Data = Data()
    var createdAt: Date = Date.distantPast
    var expiresAt: Date = Date.distantPast
    init(id: UUID = UUID(), operationJSON: Data = Data(), expectedHeadVersionID: UUID? = nil,
         diffJSON: Data = Data(), warningsJSON: Data = Data(), createdAt: Date = Date.distantPast, expiresAt: Date = Date.distantPast) {
        self.id = id; self.operationJSON = operationJSON; self.expectedHeadVersionID = expectedHeadVersionID
        self.diffJSON = diffJSON; self.warningsJSON = warningsJSON; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

/// An explicit "this is a rest day" marker for one calendar day — set from the per-day add sheet or
/// the Plan row's one-tap affordance. A plain per-day toggle, deliberately outside the versioned
/// mutation history: it schedules nothing and references nothing, so un-marking is its own undo.
@Model final class SDRestDay {
    var id: UUID = UUID()
    var date: Date = Date.distantPast   // startOfDay in the plan calendar
    init(id: UUID = UUID(), date: Date = Date.distantPast) {
        self.id = id; self.date = date
    }
}

/// The full Plan schema — registered on the app's `ModelContainer` so it's stable across all slices.
enum PlanSchema {
    static let models: [any PersistentModel.Type] = [
        SDProgram.self, SDProgramSection.self, SDScheduledWorkout.self, SDWorkoutRevision.self,
        SDWorkoutTemplate.self, SDWorkoutSession.self, SDCompletedLog.self, SDCompletedExercise.self,
        SDPlanVersion.self, SDPendingProposal.self, SDSessionMutationVersion.self, SDRestDay.self,
    ]
}
