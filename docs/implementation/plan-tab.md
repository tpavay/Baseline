# Plan Tab — Implementation Plan

Baseline's week-level training control surface. This is the complete, approved-scope plan; nothing here
is dropped — it is **sequenced** into four ordered, reviewable slices. Grounded in the four architecture
decisions (2026-07-12):

1. **SwiftData is persistence only.** The canonical domain model stays **pure Swift value types**.
   SwiftData `@Model` classes are adapters mapped through a **repository**. The Decision / Planning /
   Workout / (future Learning) engines must never import or depend on SwiftData. Schema follows the
   domain (`Program → ScheduledWorkout(date) → WorkoutRevision → Workout → Block → Exercise → Set`, with
   `ProgramSection` an *optional* grouping — phases are folders, not a required level; Week/Day are derived
   date projections), every object carries a **stable UUID** (incl. a durable `ExerciseInstanceID`
   preserved across revisions), and we migrate the current JSON store rather than wiping it. No
   hybrid persistence.
2. **Slice order:** (1) migration + repository + Plan reading + lifecycle (start/complete are mutations);
   (2) typed
   mutation API + versioning + diffs + undo, **headless with tests**; (3) drag-and-drop + manual editing
   wired to those operations; (4) multi-program filtering + full agent tool suite. The mutation core is
   built and tested before any gesture is attached to it.
3. **Adaptive status is today-only and honest.** Only today's session gets a physiological status from
   the existing engines. Future sessions are `Planned`/`Preview` unless explicitly changed, in which case
   status is **attribution-based** (User modified / Baseline proposed / Baseline modified & accepted).
   Past sessions show actual execution state. Exact numbers ("−20% volume") appear **only** when computed
   from a stored before/after diff; otherwise qualitative, evidence-backed wording.
4. **Program ≠ Origin.** Model the full `Program` entity now (no authoring UI). Every `ScheduledWorkout`
   belongs to a `Program` **and** records an **immutable** `WorkoutOrigin` (imported / baselineGenerated /
   userCreated / coachAuthored). *Who last modified it* lives only in version history, never in origin.
   The filter runs against `Program` from day one. Manual program creation / import is deferred.

---

## 0. Revision log

**2026-07-12 round 2** — corrections applied before implementation (identity / status / history semantics /
dual-source & query problems):
- **Nav:** Slice 1 ships **Today / Plan / Profile** only. Not five tabs. History is contextual (reached
  from a workout/exercise); an active workout is globally reachable; the standalone Workout tab is
  retired because Plan opens/starts/resumes any workout. (§1, §2, §3, §9, §16, §17)
- **Origin, not source:** `WorkoutOrigin` is immutable (`imported/baselineGenerated/userCreated/
  coachAuthored`); `baselineModified` removed — modifications/actors are version-history only. (§4, §5)
- **Status is never persisted:** removed `statusRaw`; `ScheduleStatus` comes from a **pure resolver** over
  stored facts (date, skip flag, active/completed refs, accepted version records). (§4, §5, §12)
- **Version history is append-only:** undo/restore append inverse/restore versions; nothing is popped or
  deleted. (§6, §7)
- **No dual writable store:** on migration failure the old JSON is **read-only recovery** (retry/export),
  schedule writes are blocked, and old JSON is removed only after the new store is verified. (§5, §13)
- **Previous-performance in Slice 2** (not Slice 4): a repository query by stable exercise identity over
  completed logs, which exist from Slice 1. (§6, §15, §16, §18)
- **Blob tradeoff stated + normalized index:** `Workout`/`WorkoutLog` are Codable blobs on the schedule
  graph; a normalized **completed-exercise-performance index** is written now so history/PRs/previous
  don't decode every log. (§5)
- **Typed confirmation result:** mutations return `applied / confirmationRequired(warnings, diff,
  proposalID) / rejected(error)` — no Boolean `confirm:`. Caller resubmits with the proposal token. (§6,
  §7, §8, §12)
- **Snapshot defined:** each `PlanVersion` stores a complete immutable serialized **schedule snapshot**
  (v1 choice); restore appends a version whose state equals the chosen snapshot. (§4, §6, §7)
- **Week/Day are derived projections,** not stored nodes — assembled by date range. Stored metadata
  (deload-week goal, day note) is added only if/when it owns unique data. (§4, §5, §10)

**2026-07-12 round 3** — versioning must cover the *plan*, not just the calendar; performed history is
immutable; proposals are concretely stored:
- **Immutable workout revisions (point 1):** a workout edit creates a new `WorkoutRevision`; the schedule
  snapshot references `workoutRevisionID`, so undo/restore brings back the exact exercises/sets/blocks/
  guidance of that version — not whatever the workout was later edited into. Blobs aren't copied per
  snapshot. (§4, §5, §6)
- **Restore never rewinds performed history (point 2):** `ScheduledWorkout` stores **no** active/completed
  refs; logs are queried by `scheduledWorkoutID` and are append-only. Restoring old plan intent can't
  delete/detach/uncomplete a finished workout; a restore conflicting with an active session returns
  `confirmationRequired`. (§4, §5, §6, §12)
- **Stored `PendingPlanProposal` (point 3):** confirmation binds to a persisted proposal carrying the
  operation, diff, warnings, and `expectedHeadVersionID`; a "yes" applies only if the head still matches
  and inputs still resolve, else it regenerates. (§4, §5, §6)
- **Smaller:** §11 `source`→`origin`; dropped `Program.phaseIDs` (phases reconstructed by the repo, single
  source of relationship truth); migration origin is `.legacyMigrated` (Baseline didn't author it); Slice 1
  renamed "Plan reading + lifecycle" (start/complete are mutations).

**2026-07-12 — integration seams closed.** The two post-Slice-4 seams are resolved by one mechanism: a
`WorkoutStore.PlanSink` write-through binding. The shared `WorkoutStore` (the agent's editing surface) is
bound to **today's scheduled workout** at startup, so the coach's create / edit / log / lifecycle flow
into the Plan repository as revisions + session updates (immediate write-through; the chat refreshes the
bound workout on open). The Plan-execution buffer uses the *same* binding with content coalesced (flushed
as one revision on dismiss; logging live). One mutation path for manual and agent; no divergent
`WorkoutStore.current`. 206 tests.

**2026-07-12 round 4** — final model refinements before building (mostly forward-compat fields added now to
avoid painful `@Model` migrations later; only Phase-optional and the WorkoutSession rename touch v1 code):
- **Phase is optional (point 1):** `Program → ScheduledWorkout(date)`; `ProgramSection` (renamed from
  `Phase`) is an optional folder created only when a program has real phases. `sectionID` nil otherwise.
- **Stable `ExerciseInstanceID` (point 3):** `PlannedExercise.id` is durable; revisions **preserve**
  exercise/set ids so "all edits to this exercise", compare, and per-exercise history work.
- **Programs own goals (point 4):** `Program.goals: [ProgramGoal]`; `ScheduledWorkout.supportsGoalIDs`
  links a session to the goals it advances.
- **Tags on ScheduledWorkout (point 5):** `tags: [WorkoutTag]` for filter / replace-all / intensity
  distribution.
- **`AggregateProvider` (point 6):** workouts contribute typed metric amounts; the aggregates row renders
  whatever exists — no hardcoded three cards. (§9)
- **`WorkoutSession` (point 7):** renamed from `ActiveWorkoutSession`, with `status` (active/paused/
  completed/discarded). Completion still freezes the immutable `CompletedWorkoutLog`.
- **`RecurrenceRule?` (point 8):** optional field on `ScheduledWorkout`, modeled/unused in v1.
- **`WorkoutTemplate` (point 10):** first-class fwd-compat entity (`Template → Revision → Scheduled`), =
  CLAUDE.md "Routine". `templateID?` on `ScheduledWorkout`. No v1 authoring (deferred with import).
- Points 2 (revisions) and 9 (`PendingPlanProposal`) already landed in round 3 — approved, unchanged.
- **Verdict from review: ~9.8/10, implementation-ready. Stop refining, start building.**

---

## 1. Existing repository assessment

| Area | Today | Gap for the Plan tab |
|---|---|---|
| **Nav** | `MainTabView` — 3 tabs (Today / Workout / Profile). `Features/History` exists but isn't a tab. | Slice 1 ships **Today / Plan / Profile**. Workout tab retired (Plan opens/starts/resumes any workout); an active workout stays globally reachable; History is contextual, not a tab. |
| **"Plan"** | `PlanningEngine.Plan` = one **day's recommendation** (`type/summary/why/avoid`) from `DecisionEngine` via `PlanAssembler`. | No week/schedule concept. Keep the engine; it feeds *today's* status only. |
| **Workout model** | Pure value types: `Workout → WorkoutBlock → PlannedExercise → PlannedSet` (+ `Prescription`, `CoachGuidance`); performed side `WorkoutLog → PerformedExercise → SetLog` (+ `PerformedStatus`). Typed `MetricType`/`MetricValues`. Stable UUIDs already. | Reuse **as-is** as the leaf of the schedule graph. No changes to these types except additive. |
| **Storage** | `WorkoutStore` (`@Observable @MainActor`) holds **one** `current: Workout?` + one `currentLog: WorkoutLog?`, persisted as **UserDefaults JSON**. Also `preferences`, `customDefinitions`, `recentExerciseIds`. | No multi-workout, no per-day scheduling, no programs, no versions/undo, no drag-drop. Superseded by the repository; migrated. |
| **Agent** | `AgentTools.Call` + `dispatch`/`execute`, `ToolCallMapper`, `ConversationService` (checkpoint/rollback), `functions/src/{tools,prompt}.ts`. Workout edit + start/complete tools already route through `WorkoutStore`. | Add plan-level tools on the **same repository**; no second mutation path. |
| **Engines** | `DecisionEngine`, `PlanningEngine`, `PlanAssembler`, `TrainingContextStore` — all pure/testable, no SwiftData. | Preserve. Repository sits beside them; engines stay persistence-free. |
| **Design system** | `BaselineColor` tokens, dark "Instrument" system; `WorkoutView` already Hevy-density with adaptive metric columns, set-level logging, swipe-delete. | Plan cards + timeline reuse tokens; detail/execution **is** `WorkoutView` (unify, don't fork). |
| **Persistence infra** | No `ModelContainer` yet; app is UserDefaults + Firestore(sync, later). CLAUDE.md mandates SwiftData on-device + CloudKit-safe rules (no `.unique`, defaults/optionals, optional relationships). | Introduce `ModelContainer`; follow the CloudKit-safe rules from the start. |

**Conclusion:** the schedule/program/version graph is greenfield; the *leaf* workout + performed model
and the agent/engine architecture are solid and reused unchanged.

---

## 2. Product questions requiring your decision

**Resolved (this session):** persistence (SwiftData-as-adapter), slice order, adaptive-status scope,
programs-model-now, **and the round-2 corrections in §0** (nav = Today/Plan/Profile; origin not source;
derived status; append-only history; single writable store; previous-in-Slice-2; typed confirmation;
snapshot defined; Week/Day derived). Remaining smaller decisions — defaulted as noted, flag if you
disagree (none block Slice 1):

- **Q-A Nav (decided):** Today / Plan / Profile. Workout tab retired; History contextual; active workout
  globally reachable (a slim "resume" affordance surfaced app-wide, e.g. on Today + a Plan banner).
- **Q-C Week start:** Monday (mockup shows M–S). Default Monday, locale-aware later.
- **Q-D Migration of the existing single workout:** default = seed it as **today's** ScheduledWorkout in a
  `Baseline` ad-hoc program, preserving its `currentLog`. (Alternative: discard the in-flight demo
  workout. Default preserves.)
- **Q-E "Missed" definition:** a scheduled, non-rest, past workout with no completed log. Default yes.

---

## 3. Final information architecture

```
Plan tab
├─ Program filter        All Training ▾  (Programs… / Collections: Ad Hoc, Completed, Archived)
├─ Week nav              ‹  JUL 06 – 12  ›   + calendar picker      (swipe between weeks)
├─ 7-day status strip    M T W T F S S      explicit state glyphs (not recovery-color dots)
├─ Weekly aggregates     objective totals, modality-adaptive, horizontally scrollable
├─ Timeline              every day, chronological; 0/1/many session cards per day
│   └─ Day
│       └─ ScheduledWorkout card (adaptive by modality)
│           ├─ status chip (today-only physiological / else attribution / else execution)
│           ├─ overflow ⋯  (Move/Swap/Duplicate/Edit/Replace/Skip/Delete/Talk to Baseline)
│           ├─ inline expand (▶/▼) — summary without leaving the page
│           └─ primary action: Start / Resume / View Log / Preview / Start-late
└─ Persistent Baseline entry (floating, Maps-style; prompt becomes context-sensitive on expand)

Workout detail / execution = existing WorkoutView (planning ↔ active logging are two states of it)
```

Page hierarchy (your point 9): `Week → card → (inline expand) → detail → Start → logging → complete → back to Week`.
Logging is a **state of the workout**, not a separate page.

---

## 4. Data-model changes (pure value types — the domain)

New value types in `Baseline/Features/Plan/PlanModel.swift` (engines/UI use only these). Stored entities vs.
derived projections are marked.

```
// Immutable origin — WHERE the workout came from, never who last changed it.
enum WorkoutOrigin { case imported, baselineGenerated, userCreated, coachAuthored, legacyMigrated }

// STORED entities
struct Program            { id; name; isActive; isArchived; createdAt;
                            goals: [ProgramGoal] }             // point 4 — programs own goals (may be empty)
struct ProgramGoal        { id; programID; text; kind? }       // e.g. "Sub-60 HYROX", "Improve threshold"
struct ScheduledWorkout   { id; programID; date: Date; timeOfDay: TimeOfDay?
                            origin: WorkoutOrigin;             // immutable — where it came from
                            workoutID: UUID;                   // stable identity of the workout across edits
                            workoutRevisionID: UUID;           // CURRENT immutable revision (→ WorkoutRevision)
                            sectionID: UUID?;                  // point 1 — OPTIONAL grouping (phase-as-folder)
                            templateID: UUID?;                 // point 10 — fwd-compat reusable source
                            tags: [WorkoutTag];                // point 5 — threshold/strength/recovery/…
                            supportsGoalIDs: [UUID];           // point 4 — which program goals this advances
                            recurrence: RecurrenceRule?;       // point 8 — fwd-compat, unused in v1
                            skipped: Bool }
                            // NOTE: no stored `status` (§12 resolver) and no lifecycle refs (§12/point 2) —
                            // performed logs are queried by scheduledWorkoutID, so restore can't rewind them.

// Immutable plan content — a workout edit creates a NEW revision; the old one is never mutated.
struct WorkoutRevision    { id; workoutID; createdAt; workout: Workout }   // the leaf model at a point in time

// OPTIONAL grouping — phases are folders, not a required level (point 1). Absent for general/ad-hoc plans.
struct ProgramSection     { id; programID; name; role?; dateRange? }       // was "Phase"; created only when needed

// Cross-cutting tags on a scheduled workout — power filtering/replace-all/intensity distribution (point 5).
enum WorkoutTag           { threshold, strength, recovery, mobility, capacity, durability, raceSpecific, … }

// FORWARD-COMPAT (modeled now so the schema anticipates them; authoring/generation deferred with import):
struct WorkoutTemplate    { id; name; currentRevisionID; tags }   // point 10 = CLAUDE.md "Routine" (reusable)
enum   RecurrenceRule     { … }                                   // point 8 — "every Tuesday", "every 3 weeks"

// DERIVED projections (assembled by the repository from ScheduledWorkout.date — NOT stored)
struct TrainingWeek       { startDate; days: [TrainingDay] }   // query result for a date range
struct TrainingDay        { date; sessions: [ScheduledWorkout] }
```

Distinct lifecycle records (kept separate — your requirement):

```
struct WorkoutSession         { id; scheduledWorkoutID; startedAt; status; log: WorkoutLog }  // point 7 — mutable, in-flight
enum   SessionStatus          { active, paused, completed, discarded }
struct CompletedWorkoutLog    { id; scheduledWorkoutID; finishedAt; log: WorkoutLog }  // frozen, immutable, append-only
```

`WorkoutSession` (renamed from `WorkoutSession`, point 7) is the mutable in-progress container with a
status; on completion it **freezes** an immutable `CompletedWorkoutLog` (and the session becomes
`.completed`). The frozen log is the append-only performed fact that plan restore never touches (§6/point 2).

Append-only versioning (§6):

```
enum PlanActor            { case user, baseline, imported }
enum PlanOpKind           { move, swap, reorder, add, duplicate, replace, skip, delete, lifecycle, undo, restore }
struct PlanOperation      { id; kind: PlanOpKind; actor: PlanActor; reason?; timestamp; diff: ScheduleDiff }
struct ScheduleDiff       { changes: [DayChange] }             // human-renderable + carries the inverse
struct ScheduleSnapshot   { serialized PLAN INTENT — see §6/§7: programs (+goals), optional sections, and
                            every ScheduledWorkout's {id, programID, sectionID?, date, timeOfDay, origin,
                            skipped, workoutID, workoutRevisionID, templateID?, tags, supportsGoalIDs}.
                            References revisions by id (immutable, §5) — never copies workout blobs.
                            DELIBERATELY EXCLUDES performed state (sessions/completed logs): those are
                            immutable facts, not versioned intent (point 2). }
struct PlanVersion        { id; timestamp; actor; operation: PlanOperation; snapshot: ScheduleSnapshot }

// A confirmation-gated mutation, stored until the caller resubmits (point 3). A UUID alone binds nothing.
struct PendingPlanProposal { id; operation: ProposedPlanOperation; expectedHeadVersionID: UUID;
                             diff: ScheduleDiff; warnings: [PlanWarning]; createdAt; expiresAt }
```

Additive only to existing types: none required. `Workout` already has stable ids; a `WorkoutRevision`
wraps a `Workout` at a point in time, and `ScheduledWorkout` points at the *current* revision.
`origin`/`programID`/`date`/`timeOfDay` live on `ScheduledWorkout`, not on `Workout`.

**Why immutable revisions (point 2).** "Git for training plans" must undo *plan edits*, not just calendar
moves. Editing a workout (change sets/reps/load, add/remove a block, substitute, reorder, edit guidance)
creates a **new `WorkoutRevision`** and repoints `ScheduledWorkout.workoutRevisionID`; the prior revision
is never mutated. A `ScheduleSnapshot` records revision IDs, so `restore` brings back the exact plan
content of that version — not whatever the workout was later edited into. Revisions are deduped/garbage-
collected later if storage warrants; correctness first.

**Stable exercise instance ids (point 3).** `PlannedExercise.id` **is** the durable `ExerciseInstanceID`
— a new `WorkoutRevision` **preserves** each exercise's `id` (and each set's `id`); only content changes.
So "this Deadlift" keeps its identity across `3×8 → 4×8 → 5×5`, enabling "show all edits to this
exercise", compare-revisions, and per-exercise history. Revision creation is a content copy that keeps
ids, never a fresh-id duplicate. (The existing `duplicateExercise` — a deliberate *copy* — still mints new
ids; that's a different operation.)

**Phases are optional folders (point 1).** A workout belongs to a `Program` and a `date`; `ProgramSection`
(the renamed "Phase") is an **optional** grouping created only when a program has real phases (HYROX
Base/Threshold/RacePrep; marathon Base/Build/Peak). General and ad-hoc/user-built plans have none —
`sectionID` is nil. Not every filesystem needs folders; the hierarchy is `Program → ScheduledWorkout(date)`
with sections as optional metadata.

**Why Week/Day are projections (point 10):** they own no unique data in v1 — a "week" is just
ScheduledWorkouts whose date falls in a range, a "day" is those on one date. Storing them would create
empty nodes and complicate calendar mutations. When deload-week goals or day-level notes become real,
add a *separate* stored `PhaseWeekMeta`/`DayNote` keyed by (programID, weekStart)/(date) that owns exactly
that data — the schedule graph stays date-driven.

---

## 5. Persistence & migration plan (SwiftData adapters)

`Baseline/Shared/Persistence/` — `@Model` classes, CloudKit-safe (no `.unique`; every stored prop has a
default or is optional; all relationships optional). **No `SDTrainingWeek`/`SDTrainingDay`** (derived,
§4/§10) and **no persisted status** (§12):

```
@Model SDProgram { id; name; isActive; isArchived; createdAt; goalsJSON: Data? }   // goals embedded
@Model SDProgramSection   { id; programID; name; roleRaw?; startDate?; endDate? }   // OPTIONAL (point 1)
@Model SDScheduledWorkout { id; programID; sectionID?; originRaw; date; timeOfDayRaw?; skipped;
                            workoutID; workoutRevisionID;         // → current SDWorkoutRevision; NO lifecycle refs
                            templateID?; tagsJSON: Data?; supportsGoalIDsJSON: Data?; recurrenceJSON: Data? }
@Model SDWorkoutRevision  { id; workoutID; createdAt; workoutJSON: Data }   // immutable Workout blob per edit
@Model SDWorkoutTemplate  { id; name; currentRevisionID; tagsJSON: Data? }  // fwd-compat (point 10); no v1 UI
@Model SDWorkoutSession   { id; scheduledWorkoutID; startedAt; statusRaw; logJSON: Data }   // point 7 (active/paused/…)
@Model SDCompletedLog     { id; scheduledWorkoutID; finishedAt; logJSON: Data }   // append-only, never rewound
@Model SDPlanVersion      { id; timestamp; actorRaw; operationJSON: Data; snapshotJSON: Data }  // append-only
@Model SDPendingProposal  { id; operationJSON: Data; expectedHeadVersionID; diffJSON: Data;
                            warningsJSON: Data; createdAt; expiresAt }   // confirmation binding (point 3)
// Normalized read index for history/PRs/previous (point 7) — written on each session completion:
@Model SDCompletedExercise { id; completedLogID; date; programID; exerciseInstanceID;
                             exerciseDefinitionID; exerciseName;   // stable catalog + instance identity
                             metricsJSON: Data }                   // per-set actuals for that exercise
```

All optional/`?` and defaulted per the CloudKit-safe rule — and adding `tags`/`goals`/`section`/`template`/
`recurrence` **now** (even where v1 has no UI) is deliberate: it avoids the exact painful `@Model`
migration the `swiftdata-new-enum-field-crash` note warns about. `WorkoutTemplate` and `RecurrenceRule`
are modeled but carry no v1 authoring/generation (deferred with import), same as programs.

**Blob tradeoff, stated honestly (point 7).** The graph is relational at the **schedule** level; leaf
`Workout` content lives in `SDWorkoutRevision.workoutJSON` and performed `WorkoutLog`s in the log models,
all as encoded `Data`. Upsides: fast migration, the fast-churning leaf model stays free of `@Model` churn,
immutable revisions come naturally. Downsides: exercise-level querying/partial updates require decoding the
blob. Mitigation — **normalize what we actually query**: `SDCompletedExercise` is written for every
exercise when a session completes, so previous-performance / history / totals / PRs run as SwiftData
fetches by `exerciseDefinitionID`, never by decoding every log. (Planned-side exercise queries later → an
analogous index; not needed for v1.)

**Performed logs are append-only and NOT versioned (point 2).** A `ScheduledWorkout` stores **no**
active/completed refs; the current session/log is found by querying `SDWorkoutSession`/`SDCompletedLog` by
`scheduledWorkoutID`. So restoring an older `ScheduleSnapshot` rewrites *plan intent only* (dates, order,
skip, workout revisions) and can never delete, detach, or uncomplete a finished workout. Completed logs
are immutable facts.

- **Mapping** lives in the repository only (`SD* ⇄` domain). Engines/UI never touch `SD*`.
- `ModelContainer` created at app root; injected via environment. **SwiftData is the only writable
  store.**

**Migration (`PlanMigrator`, versioned, idempotent, tested):**
1. First launch with the new container: if `WorkoutStore` UserDefaults holds a `current` workout → create
   an ad-hoc `Program`, an `SDWorkoutRevision` from `current`, and a `ScheduledWorkout(origin:
   .legacyMigrated, date: today, workoutRevisionID: <that revision>)`. (Origin is
   **`.legacyMigrated`** — Baseline didn't generate it; it's pre-existing app state. Add `.legacyMigrated`
   to `WorkoutOrigin` for exactly this, or use `.userCreated` if we'd rather not carry a migration origin.)
2. If `currentLog` exists → create an `SDWorkoutSession` (or `SDCompletedLog` + its `SDCompletedExercise`
   rows if `isComplete`), keyed by `scheduledWorkoutID`. No refs are written back onto the
   `ScheduledWorkout` — lifecycle is queried, not stored (point 2).
3. Preserve `preferences`, `customDefinitions`, `recentExerciseIds` (app-level, stay in
   `WorkoutStore`/UserDefaults — not schedule data).
4. Mark migration done (stored schema-version flag); re-runnable, no-ops if done.
5. **Single writable store on failure (point 5).** If migration can't complete: keep the original JSON as
   **read-only recovery** (never a second writable path), **block schedule mutations**, surface a recovery
   diagnostic with retry/export, and only delete the old JSON once the new store is written **and
   verified**. Two writable stores are never permitted.

---

## 6. Plan repository / versioning design

`protocol PlanRepository` (domain-typed; the single gateway for reads + mutations):

```
// Reads
func week(containing: Date, program: ProgramFilter) -> TrainingWeek     // derived projection
func day(_ date: Date, program: ProgramFilter) -> TrainingDay
func scheduledWorkout(_ id: UUID) -> ScheduledWorkout?
func status(of: ScheduledWorkout, evidence: TodayEvidence?) -> ScheduleStatus   // pure resolver, §12
func programs() -> [Program]
func versions(limit: Int) -> [PlanVersion]
// History (point 6) — normalized fetch, no blob decoding
func mostRecentPerformance(exerciseDefinitionID: String, before: Date) -> ExercisePerformance?
func history(exerciseDefinitionID: String, limit: Int) -> [ExercisePerformance]

// Mutations (Slice 2) — TYPED result (point 8), never a Boolean confirm:
enum MutationResult {
    case applied(diff: ScheduleDiff, version: PlanVersion)
    case confirmationRequired(warnings: [PlanWarning], proposedDiff: ScheduleDiff, proposalID: UUID)
    case rejected(PlanError)
}
func move(_ id: UUID, toDate: Date, timeOfDay: TimeOfDay?, actor: PlanActor, reason: String?, proposalID: UUID?) -> MutationResult
func swap / reorder / add / duplicate / replace / skip / delete …(…, proposalID: UUID?) -> MutationResult
// Lifecycle (same typed result; completion warns on unlogged work → confirmationRequired)
func startSession(_ id: UUID) -> Result<WorkoutSession, PlanError>
func resumeSession(_ id: UUID) -> Result<WorkoutSession, PlanError>
func completeSession(_ id: UUID, proposalID: UUID?) -> MutationResult
// Append-only history
func undo() -> MutationResult          // appends an inverse-op version
func restore(version: UUID) -> MutationResult   // appends a restore version == chosen snapshot
```

- `SwiftDataPlanRepository` implements it; `@Observable @MainActor` `PlanStore` wraps it for SwiftUI and
  publishes the current week + version list.
- **Plan edits create revisions.** Editing a scheduled workout's content (via the detail editor or an
  agent tool) writes a **new `WorkoutRevision`**, repoints `ScheduledWorkout.workoutRevisionID`, and
  appends a `PlanVersion`. This is what makes undo cover *plan edits*, not just calendar moves (point 1).
- **Typed confirmation with a stored proposal (point 3 + 8).** A mutation whose blast radius warrants
  confirmation returns `confirmationRequired(warnings, proposedDiff, proposalID)` and applies **nothing**,
  **persisting an `SDPendingProposal`** that holds the full proposed operation, the `proposedDiff`, the
  warnings, and the **`expectedHeadVersionID`** (the version the schedule was at when proposed) with an
  `expiresAt`. On resubmit with the `proposalID` the repo requires: the proposal still exists and is
  unexpired; the **current head version == `expectedHeadVersionID`**; and the inputs still resolve to the
  same objects. If any check fails it **regenerates a fresh proposal** (new `confirmationRequired`) or
  `rejected` — a stale "yes" never applies an outdated move after the schedule changed underneath it.
- **Append-only versioning (point 4).** Every applied mutation writes a new `PlanVersion` carrying the
  full post-op `ScheduleSnapshot`. **Undo does not pop** — it computes the inverse operation and appends a
  new version (`v19 move → v20 undo(move)`). `restore(v)` appends a version whose snapshot equals `v`'s.
  History is immutable and fully auditable ("why did Thursday change?").
- **Restore is plan-intent only; performed history is untouched (point 2).** A `ScheduleSnapshot` holds
  no active/completed refs, so `restore` rewrites dates/order/skip/`workoutRevisionID` and can never
  delete, detach, or uncomplete a logged workout — completed logs stay append-only and are re-associated
  by `scheduledWorkoutID`. If a restore would conflict with an **active session** (e.g. it changes or
  removes the workout being logged right now), the repo returns `confirmationRequired` describing the
  conflict; the caller decides (finish/discard the session, or restore around it) before it applies.
- **Snapshot & restore semantics (point 9).** v1 stores a **complete immutable plan-intent snapshot** per
  version (programs/phases + each ScheduledWorkout's date/order/membership/skip/**workoutRevisionID**;
  revisions and workout blobs referenced by id, never duplicated, so snapshots stay small). If snapshots
  ever prove costly, switch to forward+inverse ops + periodic snapshots — `PlanVersion` already carries
  both an operation and a snapshot, so it's a storage swap, not an API change.
- Drop-on-occupied resolution (`swap` / `add second session` / `move only`) is passed explicitly by the
  caller — the repo never guesses.

---

## 7. Manual mutation API (Slice 2, headless + tested first)

The typed operations above are the **only** way the schedule changes — for both the UI and the agent.
Each: validates (exists, dates in range, no illegal cross-program move), computes a `ScheduleDiff`, and
either applies atomically + appends a `PlanVersion` (`applied`), or — when the blast radius warrants —
returns `confirmationRequired(warnings, proposedDiff, proposalID)` and applies **nothing** (point 8). No
Boolean `confirm:` argument anywhere. Built and unit-tested with **no UI** in Slice 2.

*Reconciliation:* the already-shipped `complete_workout(confirm:)` on `WorkoutStore` predates the
repository. When lifecycle moves onto the repository in Slice 1, it is superseded by
`completeSession(_:proposalID:)` returning `confirmationRequired` for unlogged work; the Boolean path is
removed at that point (the agent tool switches to the proposalID pattern in §8).

---

## 8. Agent tool contracts (Slice 4 — same repository)

One tool per manual operation, mapped `AgentTools.Call → PlanRepository` (no separate write path):
`get_week_plan`, `get_workout_details`, `move_workout`, `swap_workouts`, `reorder_workouts`,
`add_workout`, `duplicate_workout`, `replace_workout`, `skip_workout`, `delete_workout`, `start_workout`
(exists), `resume_workout`, `complete_workout` (migrated), `explain_modification`. Behavior:
retrieve-before-act; ambiguity detection (reuse the name-resolution/`.ambiguous` pattern); **carry an
optional `proposal_id`** instead of a Boolean confirm — the first call returns the `confirmationRequired`
diff + `proposalID`, the model relays it, and on the athlete's yes it re-calls with that `proposal_id`
(point 8); recompute where required; never write arbitrary plan data; never invent
readiness/load/constraints/rationale (those come from the engines + stored diffs). Wire through
`ToolCallMapper` + `functions/src/{tools,prompt}.ts` exactly like the existing workout tools.

---

## 9. Screen & component breakdown (Slices 1 & 3)

`Baseline/Features/Plan/`: `PlanView` (root), `ProgramFilterMenu`, `WeekNavBar`, `SevenDayStrip`,
`WeeklyAggregatesRow` (+ `AggregateCard`), `Timeline` (+ `DayHeader`, `ScheduledWorkoutCard`), status
`StatusChip`, `WorkoutOverflowMenu`, and the persistent `ContextualChatBar` (context-sensitive prompt).
Workout **detail/execution reuses `WorkoutView`** opened from a card. Cards are one component with
modality-specific summary subviews (strength / running / cardio-erg / hybrid / recovery) chosen off
`ScheduledWorkout.workout` categories.

**`AggregateProvider` (point 6).** Each workout *contributes* typed metric amounts
(`[MetricContribution]`: duration, distance, strength sets, vertical gain, calories, zone time, …) derived
from its content/tags. `AggregateProvider.aggregates(for: [ScheduledWorkout]) -> [Aggregate]` sums the
contributions present in the current week/filter; `WeeklyAggregatesRow` renders **whatever aggregates
exist** (horizontally scrollable), never a hardcoded three. This scales to any modality without touching
the view — a running week surfaces distance/quality, a strength week surfaces sets/volume, HYROX surfaces
run distance + station volume + carries.

---

## 10. Drag-and-drop behavior (Slice 3)

Long-press → lift → drag → everything shifts → drop, on the timeline (Things/Reminders-style), driven
**only** by the Slice-2 mutation API. Drop targets: another day (move), within a day (reorder), onto an
occupied day → action sheet (**Swap / Add as second session / Move only**). Before applying a structural
change, show the `ScheduleDiff` ("You moved Threshold → Thursday; Recovery Ride → Tuesday. Accept?").
Undo available after every mutation. Implemented with a custom drag layer over the timeline (SwiftUI
`.draggable`/drop or a hand-rolled offset drag if reorder fidelity needs it — decided at Slice 3 spike).

---

## 11. Multiple-program behavior

Model supports many active programs, many sessions/day (AM/PM via `timeOfDay`), standalone ad-hoc
workouts, and per-workout immutable `origin` + `programID`. Filter (`ProgramFilter`: `.allTraining`,
`.program(id)`, `.collection(adHoc/completed/archived)`) runs against `Program` from day one; the strip,
aggregates, and timeline all respect it. All Training merges every active program chronologically.

---

## 12. Workout lifecycle & status derivation

States: **PlannedWorkout → WorkoutSession → CompletedWorkoutLog**, kept distinct.

**Status is never persisted (point 3).** A pure `ScheduleStatusResolver.status(for: ScheduledWorkout,
today: Date, evidence: TodayEvidence?, activeSession: WorkoutSession?, completedLog:
CompletedWorkoutLog?, versions: [PlanVersion]) -> ScheduleStatus` computes it on read from stored facts
only — the scheduled `date`, the `skipped` flag, the active/completed logs **queried by
`scheduledWorkoutID`** (not stored on the schedule), and accepted version records. No `statusRaw` column
exists to go stale. Resolution:
- **Today, not started:** physiological status from `DecisionEngine`/`PlanningEngine`
  (`As planned` / `Modified today` / `Constraint active` / `Swap suggested` / `Reduced volume`). Numbers
  only from a stored plan diff.
- **Active:** `In progress` → primary action `Resume`.
- **Completed:** `Completed` / `Modified during workout` / `Skipped` → action `View Log`.
- **Future:** `Planned`/`Preview` (action `Preview`), unless explicitly changed → attribution status
  (`User modified` / `Baseline proposed` / `Baseline modified & accepted`) from version history.
- **Past, not completed:** `Missed` (actions: `Start late` / `Move` / `Skip`).
`start`→creates `WorkoutSession` (keyed by `scheduledWorkoutID`); `complete`→freezes
`CompletedWorkoutLog` + `SDCompletedExercise` rows, planned workout (and its revision) intact. Neither
writes a ref back onto the `ScheduledWorkout`, so plan restore can't disturb them.

---

## 13. Error & empty states

Empty week ("No sessions this week — ask Baseline or add one"); rest day (no marker); **migration-failure
recovery mode** (read-only: old JSON preserved, schedule mutations blocked, diagnostic + retry/export — one
writable store, never two, point 5); mutation validation errors (surfaced as `rejected(PlanError)`, no
silent no-op); `confirmationRequired` diff shown before any structural change; agent ambiguity ("which
Tuesday session?"); occupied-drop conflict (action sheet); offline (local-first, fine).

---

## 14. Accessibility requirements

44pt+ tap targets on every control; VoiceOver labels describe **state + action** ("Threshold run,
Tuesday, modified today, double-tap to start"); Dynamic Type must not break the timeline (cards reflow,
aggregates scroll); status conveyed by glyph + text, never color alone (your day-strip point); drag-drop
has a non-gesture fallback via the ⋯ menu (Move/Reorder) so it isn't gesture-only; reduced-motion honored.

---

## 15. Testing strategy

- **Migration:** JSON-store → SwiftData produces the expected today ScheduledWorkout + linked
  session/log (+ `SDCompletedExercise` rows if completed); idempotent; no data loss; **failure enters
  read-only recovery** (no second writable store).
- **Repository/mutations (Slice 2, headless):** move/swap/reorder/add/duplicate/replace/skip/delete each
  produce correct diff + version; **undo/restore append inverse/restore versions (history never shrinks)**;
  occupied-drop resolutions; cross-program guards; a stored proposal applies only when
  `expectedHeadVersionID` still matches (a mutation in between → the "yes" regenerates, never applies
  stale).
- **Immutable revisions (point 1):** editing a workout creates a new `WorkoutRevision`; restoring an
  earlier version brings back that version's exercises/sets/blocks/guidance (not the later edit).
- **Restore never rewinds performed history (point 2):** complete Tuesday → restore an earlier version →
  the `CompletedWorkoutLog` still exists and Tuesday still reads completed; restore that conflicts with an
  active session returns `confirmationRequired`, never silently detaches it.
- **Status resolver (pure):** today vs. future vs. past vs. modified-attribution; never persisted;
  "no invented percentage" (numbers only from a stored diff).
- **History index (point 6):** `mostRecentPerformance(exerciseDefinitionID:before:)` returns the last
  completed actuals by stable identity via `SDCompletedExercise` (no blob decoding).
- **Aggregates:** modality-adaptive selection; objective totals correct.
- **Lifecycle:** start→active→complete keeps planned/performed distinct (extends existing tests).
- **Agent:** each tool maps to the same repo op; ambiguous command mutates nothing; structural change
  returns a diff; confirmation required.
- Target: keep the suite green at every commit (currently 172); each slice adds its own tests.

---

## 16. Ordered commit sequence

**Slice 1 — migration + repository + Plan reading + lifecycle** (start/complete are mutations) — ✅ DONE (commits 8918592, 2b69116, bf2395b, 1bd3079; 190 tests). WorkoutView execution reuse via a write-through bridge (scratch WorkoutStore → repository); nav = Today/Plan/Profile.
1. Domain value types (§4) + `ProgramFilter`/status enums (+ tests).
2. SwiftData `@Model` adapters + `ModelContainer` at root (CloudKit-safe).
3. `PlanRepository` reads + `SwiftDataPlanRepository` + `PlanStore` (+ tests).
4. `PlanMigrator` from the UserDefaults workout (+ migration tests).
5. `PlanView` shell: program filter, week nav (+ swipe/calendar), 7-day strip.
6. Weekly aggregates (modality-adaptive, objective).
7. Timeline + adaptive `ScheduledWorkoutCard` (multi-session/day, inline expand, quiet-completed).
8. Wire card → `WorkoutView` detail; Start/Resume/Complete via repository lifecycle (typed result;
   `complete` warns on unlogged work via `confirmationRequired`, replacing the shipped Boolean path).
9. Persistent contextual chat bar (context-sensitive prompt); safe-area/keyboard correct. **Nav →
   Today / Plan / Profile** (retire Workout tab; active-workout resume surfaced globally; History
   contextual).
   *Verification checkpoint (Slice 1).*

**Slice 2 — mutation core + versioning + history query (headless)** — ✅ DONE (commits df0f01e, 6200ed2; 198 tests). Typed versioned mutations, append-only undo/restore, stored-proposal confirmation gate, active-session guard, previous-performance query + Hevy previous column.
10. `WorkoutRevision` store + revision-on-edit; `ScheduleDiff` (+ inverse) + `PlanOperation`/`PlanVersion`
    (+ `ScheduleSnapshot` referencing revision IDs) + append-only version store.
11. Typed mutations (move/swap/reorder/add/duplicate/replace/skip/delete + workout-content edit) with the
    **stored `SDPendingProposal`** + `expectedHeadVersionID` confirmation gate (+ tests).
12. Append-only undo/restore — plan-intent only; **performed logs untouched**; active-session-conflict
    guard (+ tests).
12b. `SDCompletedExercise` index + `mostRecentPerformance`/`history` queries; surface the **Previous**
    column in `WorkoutView`'s active logging table (point 6) (+ tests).

**Slice 3 — drag-drop + manual editing** — ✅ DONE (commit 3c234e6; 198 tests). Action-based ⋯ menu → mutations, draggable cards + day drop targets, occupied-drop Move/Swap dialog, delete confirmation gate, undo snackbar.
13. Overflow ⋯ actions wired to mutations (with diffs/confirm/undo).
14. Long-press drag-reorder + cross-day move + occupied-drop action sheet + diff preview.

**Slice 4 — multi-program + agent tools** — ✅ DONE (commits 1d4f811, ee753b9; 203 tests; functions deployed to dev). Collections filter + week-plan agent tools (move/swap/skip/duplicate/delete/explain) on the same versioned repository, ambiguity-aware, delete confirmation-gated.
15. Program filter against real multiple programs; collections (Ad Hoc/Completed/Archived).
16. Plan agent tools (§8) through the same repository; `tools.ts`/`prompt.ts`; ambiguity + diff + confirm.
17. `explain_modification` tool tied to deterministic state + stored diffs.
    *Verification checkpoint (final).*

---

## 17. Verification checklist (run at each slice's checkpoint)

`xcodegen generate` → build → full test suite → install on sim. Then manually: week navigation; multiple
workouts/day; **(S3)** drag move / swap / reorder / undo; program filtering; start→resume→complete
lifecycle; completed log stays separate from the plan; **(S4)** agent mutations use the same ops;
ambiguous agent command mutates nothing; structural changes show a diff + confirmation; no workout content
hidden behind the chat/tab bars (the mockup's cut-off card bug — fixed by safe-area insets + reserved
space).

---

## 18. Requirement → location traceability

| Spec requirement | Where |
|---|---|
| Program filter (All Training / programs / collections) | §3, §11; Slice 1 (shell) + Slice 4 (real programs) |
| Week nav (prev/next, swipe, calendar, current-week) | §3; Slice 1 (5) |
| 7-day strip with explicit states (not recovery dots) | §3, §12, §14; Slice 1 (5) |
| Dynamic weekly aggregates (modality-adaptive, objective) | §3, §11; Slice 1 (6) |
| Chronological timeline, all days, quiet-completed, today-emphasized | §3, §9; Slice 1 (7) |
| Multiple sessions/day (AM/PM) | §4, §11; Slice 1 (7) |
| Adaptive cards by modality | §9; Slice 1 (7) |
| Status chip via pure resolver (today physiological / attribution / execution; never stored) | §12; Slice 1 (7) + Slice 2 (attribution) |
| Modification "why" from deterministic state + stored diff, never invented | §12, §8; Slice 1/2/4 |
| Overflow actions (Move/Swap/Duplicate/Edit/Replace/Skip/Delete/Talk) | §9, §10; Slice 3 (13) |
| Drag-drop (move/reorder/occupied-drop → swap/add/move) + diff preview | §10; Slice 3 (14) |
| Undo + versioning — **append-only** (actor/reason/timestamp/snapshot/restore) | §4, §6; Slice 2 (10–12) |
| **Immutable workout revisions** — undo covers plan edits, not just calendar | §4, §5, §6; Slice 2 (10) |
| **Restore never rewinds performed history** — logs immutable, queried by scheduledWorkoutID | §4, §5, §6, §12; Slice 2 (12) |
| **Stored `PendingPlanProposal`** bound to `expectedHeadVersionID` | §4, §5, §6; Slice 2 (11) |
| Previous-performance column (by stable exercise identity, normalized index) | §5, §6; Slice 2 (12b) |
| Immutable `WorkoutOrigin` (origin ≠ modifier; modifier in versions) | §4, §5 |
| Status derived by pure resolver, never persisted | §4, §5, §12 |
| Single writable store; read-only recovery on migration failure | §5, §13 |
| Typed `confirmationRequired`(warnings, diff, proposalID); no Boolean confirm | §6, §7, §8 |
| `ScheduleSnapshot`/restore fully defined | §4, §6 |
| Week/Day derived projections (not stored nodes) | §4, §10 |
| Nav = Today/Plan/Profile; Workout tab retired; History contextual | §1, §2, §16 |
| Workout detail = existing editor; logging is a workout state | §9, §12; Slice 1 (8) |
| Active logging (prev column later, dynamic columns, set-complete, edits, notes, skip, complete, chat) | reuses `WorkoutView` (built); Slice 1 (8) |
| Planned vs performed kept distinct | §4, §12; Slice 1 (2,8) |
| Multiple programs, ad-hoc, immutable origin identity | §4, §11; Slice 4 (15) |
| Agent tools = same validated ops, retrieve/ambiguity/diff/confirm/recompute | §8; Slice 4 (16–17) |
| Persistence: SwiftData adapters, domain value types, migration | §5; Slice 1 (2–4) |
| Program→ScheduledWorkout(date)→WorkoutRevision→Workout→Block→Exercise→Set; ProgramSection optional | §4, §5 |
| Stable ExerciseInstanceID preserved across revisions | §4; Slice 2 (10) |
| Programs own goals; workouts link supported goals | §4 (fwd-compat fields; authoring deferred) |
| WorkoutTag on ScheduledWorkout (filter / replace-all / distribution) | §4 |
| AggregateProvider — workouts contribute metrics; row renders what exists | §9; Slice 1 (6) |
| WorkoutSession (active/paused/completed/discarded); frozen CompletedWorkoutLog | §4, §12 |
| RecurrenceRule? + WorkoutTemplate modeled (fwd-compat, no v1 authoring) | §4, §5 |
| Migrations, no data wipe | §5; Slice 1 (4) |
| UI fixes: action not hidden behind chat/tab; safe-area; multi-session; strip states; adaptive aggregates; quiet-completed; prominent-active; tap targets; VoiceOver; Dynamic Type | §9, §13, §14, §17 |
| "Prev-performance" column | **Slice 2 (12b)** — `SDCompletedExercise` index + `mostRecentPerformance` query by stable identity; not tied to program collections |

**No arbitrary deferrals remain.** The Previous column moved into Slice 2 (it's a repository query, not a
collections feature). Manual program **authoring/import** is the only out-of-scope item — explicitly out
per decision 4, not a hidden deferral. UI fixes, nav change, history query, versioning, drag-drop, and the
full agent tool surface all have concrete homes above.
