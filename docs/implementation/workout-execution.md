# Baseline - Workout Execution Engine (design, future)

*The engine that turns an accepted plan into a performed workout log. This began as a design document; parts are now built (see Status). It exists to keep the workout model, conversation tools, and future replanning work pointed at the same target.*

## 1. Requirement
> Baseline must distinguish planned training from actual performed training and support starting a workout, logging sets/reps/load/duration/distance/pace, athlete notes at exercise and workout level, skipped or modified work, pain events, and mid-workout replanning. The conversational agent should expose validated tools over this model so natural-language logging updates structured workout data. Planned vs actual must remain separate, versioned, and feed the Learning and Plan Engines.

## 2. Product loop
```
Plan -> start workout -> log performance -> add athlete notes/context -> complete or modify session -> recompute training state -> adapt remaining plan
```

This makes Baseline a training system, not a readiness score with a recommendation. The athlete should be able to read, write, adjust, discuss, perform, and log the plan from one place.

## 3. Product bar from coach-delivered apps
The Fitter-style pattern to avoid: a coach delivers a useful plan, but the app behaves like a static vertical document with fixed logging cells. Coach guidance takes over the screen, performance logging only fits certain exercises, run context is not structured, and anything outside the prescribed plan requires another app.

Baseline should be different in these ways:
- Coach Guidance is available, but execution stays clean: the current prescription, logging controls, remaining work, and conversation entry point are primary.
- Every planned exercise can be completed, skipped, reordered, substituted, removed, or extended when the athlete actually trains.
- The athlete can add unplanned work inside the same workout, including durability/chassis work and custom exercises.
- Structured metrics never have to hide in notes. SkiErg average/best pace, run surface, treadmill vs track, intervals, isometric duration/load, and extra sets are first-class fields.
- "Performance layer" is not a separate rigid bucket. Any session item can have planned targets, Coach Guidance, actual logs, Athlete Notes, and deltas.

## 4. Responsibility
The Workout Execution Engine owns active-session state and performed-work records:
- Start a planned or ad-hoc workout.
- Track completed, skipped, substituted, and modified work.
- Log actual performance: sets, reps, load, duration, distance, pace, power, calories, HR zones, rest, run environment, interval summaries, and isometric details.
- Record exercise-level Athlete Notes and whole-workout Athlete Notes.
- Capture pain events and convert them into constraints when appropriate.
- Preserve planned vs actual as separate records.
- Recompute the remaining workout after a mid-session change.
- Request versioned plan revisions from the Plan Engine when work should move later.

The engine does not own readiness scoring or plan generation. It produces structured evidence those engines can use.

## 5. Boundary with Plan Engine
The Plan Engine owns intended work:
```
Program -> Block -> Week -> Day -> PlannedSession -> PlannedExercise
```

Workout Execution owns performed work:
```
WorkoutLog -> PerformedExercise -> SetLog / IntervalLog / Event / AthleteNote
```

The performed log links back to the planned prescription, but never overwrites it. If the athlete skips speed work because of calf pain, the plan remains the plan; the workout log records the skip and the reason. Moving that speed work later is a new plan operation with a versioned diff.

During execution, Baseline consumes both the Prescription and Coach Guidance from the planned exercise. It may also show Context-Aware Guidance for today's readiness and constraints. None of those should be stored as Athlete Notes unless the athlete explicitly records an execution observation.

## 6. Data model sketch
- **Completion timing:** `WorkoutSession.startedAt` records the start, while immutable `CompletedWorkoutLog` stores the actual `finishedAt` and optional athlete-confirmed `durationSeconds`.
  Older completed records fall back to the start/finish interval; `docs/implementation/plan-tab.md` owns the domain and persistence schema.
- **PerformedExercise:** plannedExerciseId?, exerciseId, order, status, substitutionFor?, reason, athleteNotes, modality, intent, environment.
- **SetLog:** setNumber, reps, load, RPE, rest, completedAt.
- **IntervalLog:** intervalNumber, duration, distance, pace, power, calories, targetZone, actualZoneSummary.
- **IsometricLog:** contractionType (yielding/overcoming), duration, load/resistance, position/joint angle, side, effort/RPE.
- **MetricSummary:** reps/attempts, average pace, best pace, average power, best power, total distance, total calories.
- **WorkoutEvent:** timestamp, type, payload. Types include pain, constraintCreated, skipped, substituted, movedLater, athleteNote, pause, resume, completed.
- **WorkoutDelta:** derived comparison between planned and performed work for Learning and plan review.

The schema should support heterogeneous logging from day one: strength, holds, isometrics, intervals, distance, distance+load, calories, pace, power, run environment, and HR-zone time.

## 7. Agent tools
The conversational layer calls validated tools over the workout model.
The core of this surface is built; `functions/src/tools.ts` owns the served schemas.
That includes workout structure editing, start/complete, per-set outcomes (completed/skipped/pending), and the Wave 6 performed-logging tools: `get_active_session`, `upsert_performed_set`, `set_performed_set_outcome`, extra performed-set add/update/delete, `add_exercise_session_note`, and stale-safe `undo_session_mutation` (acceptance criteria in `docs/quality/contracts/issue-49-performed-set-logging.md`).
Still design-only sketch:
- **Workout:** `recomputeRemainingWorkout`
- **Exercise:** `moveExerciseToLaterDate`
- **Context/metadata:** `setWorkoutEnvironment`, `setExerciseIntent`, `logIsometric`
- **Athlete Notes:** `addAthleteWorkoutNote` (whole-workout notes)
- **Constraints/replanning:** `createConstraint`, `updateConstraint`, `replanWeek`

The AI proposes tool calls; the app validates exercise identity, units, ranges, workout state, plan links, and blast radius before applying them.

## 8. Example flows
**Skipped work due to pain**
1. Planned: `4 x 5 min threshold run + 6 x 30 sec speed`.
2. Athlete says: "My calf hurt after the threshold blocks, so I skipped the speed work. Move it later this week."
3. Tools: `skipExercise`, `createConstraint`, `moveExerciseToLaterDate`, `replanWeek`.
4. Stored result: threshold completed; speed skipped with calf-pain reason; constraint active; future plan revision proposed.

**Strength logging**
1. Athlete says: "Deadlifts were 3 sets of 8 at 185, 205, 225. Grip was weak."
2. Tools: three `logSet` calls and `addAthleteExerciseNote`.
3. Stored result: actual loads and exercise-level note linked to the planned deadlift.

**HYROX station logging**
1. Athlete says: "Max-effort SkiErg pulls were 15 reps, average 1:33 per 500, best 1:29."
2. Tools: `logInterval` or station-specific `MetricSummary` once available.
3. Stored result: repeated effort summary with average and best pace.

**Run context logging**
1. Athlete says: "The threshold blocks were on the treadmill, speed work was on the track, and I skipped the last two 400s."
2. Tools: `setWorkoutEnvironment`, `logInterval`, `skipExercise` or `updateInterval`.
3. Stored result: run intent, environment, completed intervals, skipped intervals, and reason remain queryable.

**Durability / isometric add-on**
1. Athlete says: "Add the calf yielding isometrics I did: 3 x 45 seconds each side with 40 pounds."
2. Tools: `addExercise`, `logIsometric`.
3. Stored result: custom chassis work lives in the same workout log and informs future calf constraints.

## 9. Mid-workout adaptation
When something changes mid-session, Baseline should not just log the change. It should update state and decide what to do with the remaining work:
```
pain/context event -> constraint update -> remaining-work evaluation -> proposed substitutions/skips/reschedule -> accepted update -> workout continues
```

Example: calf pain during speed work can remove remaining running, replace chassis work with calf-safe mobility, and propose moving speed later in the week if the constraint allows it.

## 10. Workout screen target
The eventual workout screen should support:
- Current exercise and planned prescription.
- Manual set/reps/load/time/distance/pace entry.
- Complete, skip, substitute, and note actions.
- Add, remove, reorder, and extend exercise actions.
- Modality-specific controls for runs, erg work, loaded carries, holds, and isometrics.
- Coach Guidance and Context-Aware Guidance without mixing them into Athlete Notes.
- Exercise-level and workout-level Athlete Notes.
- Live HR zone where relevant.
- Remaining work.
- A talk-to-Baseline entry point that maps natural language to the same validated tools.

This should feel like the athlete's primary training surface, not an afterthought attached to readiness.

## 11. Learning inputs
Workout Execution feeds the Learning Engine:
- Planned vs performed volume, intensity, and modality.
- Completion, skipped work, and modifications.
- Reasons: pain, time, fatigue, equipment, preference.
- Performance: loads, reps, pace, power, HR-zone response, RPE.
- Athlete Notes and constraints.

The Learning Engine uses these deltas to tune future planning and readiness interpretation.

## 12. Build sequence
1. Trustworthy readiness and today's plan.
2. Today conversation.
3. Structured workout model.
4. Manual workout logging.
5. Voice/chat-assisted logging.
6. Mid-workout adaptation.
7. Week replanning.
8. Learning from planned vs performed.

## Status
**Partially built.**
The structured workout model, manual logging, session lifecycle, and conversational logging (build-sequence steps 3-5) exist: `WorkoutStore` owns the active session, `PlanRepository` persists sessions and append-only completed logs, and the Wave 6 performed-log tools in `functions/src/tools.ts` expose ID-targeted, unit-safe, undoable set logging through conversation.
Mid-workout adaptation, week replanning, and Learning-Engine consumption (steps 6-8) remain design.
Companion to `docs/architecture.md`, `docs/engine-and-data-model.md`, and `docs/implementation/plan-engine.md`.
