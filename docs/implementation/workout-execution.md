# Baseline - Workout Execution Engine (design, future)

*The future engine that turns an accepted plan into a performed workout log. This is a design document, not a build. It exists to keep the workout model, conversation tools, and future replanning work pointed at the same target.*

## 1. Requirement
> Baseline must distinguish planned training from actual performed training and support starting a workout, logging sets/reps/load/duration/distance/pace, notes at exercise and workout level, skipped or modified work, pain events, and mid-workout replanning. The conversational agent should expose validated tools over this model so natural-language logging updates structured workout data. Planned vs actual must remain separate, versioned, and feed the Learning and Plan Engines.

## 2. Product loop
```
Plan -> start workout -> log performance -> add notes/context -> complete or modify session -> recompute training state -> adapt remaining plan
```

This makes Baseline a training system, not a readiness score with a recommendation. The athlete should be able to read, write, adjust, discuss, perform, and log the plan from one place.

## 3. Responsibility
The Workout Execution Engine owns active-session state and performed-work records:
- Start a planned or ad-hoc workout.
- Track completed, skipped, substituted, and modified work.
- Log actual performance: sets, reps, load, duration, distance, pace, power, calories, HR zones, and rest.
- Record exercise-level notes and whole-workout notes.
- Capture pain events and convert them into constraints when appropriate.
- Preserve planned vs actual as separate records.
- Recompute the remaining workout after a mid-session change.
- Request versioned plan revisions from the Plan Engine when work should move later.

The engine does not own readiness scoring or plan generation. It produces structured evidence those engines can use.

## 4. Boundary with Plan Engine
The Plan Engine owns intended work:
```
Program -> Block -> Week -> Day -> PlannedSession -> PlannedExercise
```

Workout Execution owns performed work:
```
WorkoutLog -> PerformedExercise -> SetLog / IntervalLog / Event / Note
```

The performed log links back to the planned prescription, but never overwrites it. If the athlete skips speed work because of calf pain, the plan remains the plan; the workout log records the skip and the reason. Moving that speed work later is a new plan operation with a versioned diff.

## 5. Data model sketch
- **WorkoutLog:** id, plannedSessionId?, status, startedAt, endedAt, source, summary, overallNotes, HR-zone summary.
- **PerformedExercise:** plannedExerciseId?, exerciseId, order, status, substitutionFor?, reason, notes.
- **SetLog:** setNumber, reps, load, RPE, rest, completedAt.
- **IntervalLog:** intervalNumber, duration, distance, pace, power, calories, targetZone, actualZoneSummary.
- **WorkoutEvent:** timestamp, type, payload. Types include pain, constraintCreated, skipped, substituted, movedLater, note, pause, resume, completed.
- **WorkoutDelta:** derived comparison between planned and performed work for Learning and plan review.

The schema should support heterogeneous logging from day one: strength, holds, intervals, distance, distance+load, calories, pace, power, and HR-zone time.

## 6. Agent tools
The conversational layer should call validated tools over the workout model. Initial tool surface:
- **Workout:** `startWorkout`, `completeWorkout`, `recomputeRemainingWorkout`
- **Exercise:** `addExercise`, `removeExercise`, `substituteExercise`, `completeExercise`, `skipExercise`, `moveExerciseToLaterDate`
- **Sets:** `logSet`, `updateSet`, `deleteSet`
- **Intervals/cardio:** `logInterval`, `logDuration`, `logDistance`, `logPace`, `logPower`
- **Notes:** `addExerciseNote`, `addWorkoutNote`
- **Constraints/replanning:** `createConstraint`, `updateConstraint`, `replanWeek`

The AI proposes tool calls; the app validates exercise identity, units, ranges, workout state, plan links, and blast radius before applying them.

## 7. Example flows
**Skipped work due to pain**
1. Planned: `4 x 5 min threshold run + 6 x 30 sec speed`.
2. Athlete says: "My calf hurt after the threshold blocks, so I skipped the speed work. Move it later this week."
3. Tools: `skipExercise`, `createConstraint`, `moveExerciseToLaterDate`, `replanWeek`.
4. Stored result: threshold completed; speed skipped with calf-pain reason; constraint active; future plan revision proposed.

**Strength logging**
1. Athlete says: "Deadlifts were 3 sets of 8 at 185, 205, 225. Grip was weak."
2. Tools: three `logSet` calls and `addExerciseNote`.
3. Stored result: actual loads and exercise-level note linked to the planned deadlift.

**HYROX station logging**
1. Athlete says: "Max-effort SkiErg pulls were 15 reps, average 1:33 per 500, best 1:29."
2. Tools: `logInterval` or station-specific summary once available.
3. Stored result: repeated effort summary with average and best pace.

## 8. Mid-workout adaptation
When something changes mid-session, Baseline should not just log the change. It should update state and decide what to do with the remaining work:
```
pain/context event -> constraint update -> remaining-work evaluation -> proposed substitutions/skips/reschedule -> accepted update -> workout continues
```

Example: calf pain during speed work can remove remaining running, replace chassis work with calf-safe mobility, and propose moving speed later in the week if the constraint allows it.

## 9. Workout screen target
The eventual workout screen should support:
- Current exercise and planned prescription.
- Manual set/reps/load/time/distance/pace entry.
- Complete, skip, substitute, and note actions.
- Exercise-level and workout-level notes.
- Live HR zone where relevant.
- Remaining work.
- A talk-to-Baseline entry point that maps natural language to the same validated tools.

This should feel like the athlete's primary training surface, not an afterthought attached to readiness.

## 10. Learning inputs
Workout Execution feeds the Learning Engine:
- Planned vs performed volume, intensity, and modality.
- Completion, skipped work, and modifications.
- Reasons: pain, time, fatigue, equipment, preference.
- Performance: loads, reps, pace, power, HR-zone response, RPE.
- Notes and constraints.

The Learning Engine uses these deltas to tune future planning and readiness interpretation.

## 11. Build sequence
1. Trustworthy readiness and today's plan.
2. Today conversation.
3. Structured workout model.
4. Manual workout logging.
5. Voice/chat-assisted logging.
6. Mid-workout adaptation.
7. Week replanning.
8. Learning from planned vs performed.

## Status
**Design only.** Sequenced after the readiness spine and Today Conversation. Companion to `docs/architecture.md`, `docs/engine-and-data-model.md`, and `docs/implementation/plan-engine.md`.
