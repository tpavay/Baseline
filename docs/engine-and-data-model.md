# Baseline - Engine & Data Model

> Durable product model: the core entities, lifecycle, responsibilities, and boundaries. This doc describes **what the system is** and **why the concepts exist**. Implementation details that will age, such as device APIs, formulas, model providers, dataset choices, and storage rules, live in `docs/technical-reference.md` or the per-engine implementation docs.

## Core Flow
```
Reading -> Decision -> Plan -> Workout -> Learning
```

Baseline's durable loop is:
1. Observe or collect today's evidence.
2. Make a recovery-aware decision.
3. Produce or adapt a plan.
4. Execute and log the workout.
5. Learn from the difference between intended and performed work.

The key product idea is that Baseline is not just a readiness score. It is the system that connects planning, execution, logging, adaptation, and learning.

## Core Entities

### Reading
A daily recovery input. A Reading may include physiology, sleep, subjective check-in, soreness, stress, mood, or any future evidence source. The important durable concept is not the capture method; it is that a Reading becomes structured evidence for a Decision.

### Decision
The deterministic recovery-aware output for a day. It interprets evidence, constraints, training state, and certainty, then decides what training dose or training direction is appropriate. The Decision Engine owns scores, caps, constraints, and uncertainty.

### Plan
The intended training over time. A Plan assigns planned sessions to dates and can be adapted when readiness, constraints, travel, availability, or performed work changes.

Plans are versioned. Meaningful changes create history so the athlete can understand, undo, compare, and trust adaptations.

### Program
A longer training structure, such as a multi-week HYROX block. A Program may contain blocks, weeks, days, planned sessions, and planned exercises.

Baseline does not require a full Program to work. It can reason over a single imported day, a rolling week, or a larger plan.

### Routine
A reusable template for training content. A Routine can be imported, created manually, copied from past work, or shipped as Baseline content. Starting a Routine creates a planned or ad-hoc session instance.

### Planned Session
A dated intended workout. This is what Baseline or the athlete meant to do on a given day.

A Planned Session contains planned exercises. It may come from a Routine, an imported coach plan, a generated recommendation, a previous workout, or a manual entry.

### Planned Exercise
An intended exercise inside a Planned Session. It connects an Exercise to a Prescription and Coach Guidance.

Planned Exercises are editable: the athlete or Baseline can add, remove, reorder, substitute, or reschedule them through validated plan operations.

### Exercise
A movement or modality Baseline can prescribe, recognize, and log. Examples include deadlift, threshold run, SkiErg, wall balls, calf yielding isometric, and mobility drills.

An Exercise is not the same thing as its prescription. "Deadlift" is the movement; "3 x 8 at moderate load" is a Prescription; "brace before pulling" is Coach Guidance; "left calf tightened" is an Athlete Note.

### Prescription
The structured target for a planned exercise. It describes what should be done: sets, reps, load, duration, distance, pace, intensity, zone, rest, tempo, or modality-specific targets.

Prescription is intended work. It should remain separate from actual performance.

### Coach Guidance
Authored instructional metadata attached to a planned session or planned exercise. It explains how and why to perform the work.

Coach Guidance can include:
- Goal or intent.
- Tempo.
- Form cues.
- Common mistakes.
- Why the exercise exists.
- Progression notes.
- Video, attachments, and links.

Coach Guidance is permanent authored content. It ships with a plan, comes from a coach, or is produced by Baseline as part of a recommendation. It is not an execution log.

### Context-Aware Guidance
Dynamic guidance created from Coach Guidance plus today's state. Baseline can adjust the coaching layer based on readiness, constraints, injury history, fatigue, available equipment, or prior execution.

Example:
- Coach Guidance: "Brace before pulling."
- Current context: hamstring sensitivity and low readiness.
- Context-Aware Guidance: "Be conservative off the floor today. Your hamstring has been sensitive this week."

The base guidance remains unchanged. The contextual layer is generated for the current decision or workout.

### Workout Log / Performed Session
The actual work performed. It records what happened during training: completed work, skipped work, substitutions, added exercises, modified targets, pain events, performance metrics, and athlete notes.

The Workout Log links back to the Planned Session when one exists. It never overwrites the plan.

### Athlete Notes
User-generated execution notes. Athlete Notes describe what happened or how it felt in a specific workout, exercise, set, interval, or day.

Examples:
- "Left calf tightened during rep 3."
- "Grip was weak on the last deadlift set."
- "Treadmill felt easier than track pace."

Athlete Notes are not Coach Guidance. They are evidence for future decisions and learning.

### Constraint
A condition that gates or shapes training. Constraints can come from pain, injury, equipment, travel, time, recovery, or user preference.

Constraints are structured and durable enough to affect future plans until resolved or updated. They are not just notes and not just lower readiness scores.

### Learning Signal
The structured evidence produced after execution. Learning Signals come from planned-vs-performed deltas, performance trends, constraints, athlete notes, and recovery response.

These signals help Baseline personalize future readiness interpretation, guidance, prescriptions, and plan adaptations.

## Planned vs Performed
Baseline preserves two records:
- **Planned work:** intended sessions, planned exercises, prescriptions, and coach guidance.
- **Performed work:** workout logs, actual performance, athlete notes, skips, substitutions, modifications, and pain events.

The performed log never mutates the plan in place. It links to the plan and records the delta.

Examples:
- Planned: `4 x 5 min threshold + 6 x 30 sec speed`.
- Performed: threshold completed, speed skipped because calf pain appeared.
- Plan adaptation: move or replace speed work later through an explicit plan revision.

This separation is what lets Baseline learn from reality without losing intent.

## Prescription vs Guidance vs Athlete Notes
Every planned exercise should support three different kinds of information:

```
Exercise
  -> Prescription
  -> Coach Guidance
  -> Athlete Notes (only after or during execution)
```

For a deadlift:
- **Prescription:** `3 x 8`, load target, rest, tempo.
- **Coach Guidance:** "Build posterior chain strength. Brace before pulling. Watch for hips shooting up."
- **Athlete Notes:** "Grip was weak on the third set."

For a threshold run:
- **Prescription:** `4 x 5 min threshold`, recovery duration, surface or environment target.
- **Coach Guidance:** "Raise lactate threshold. Controlled discomfort. Do not sprint the first rep."
- **Athlete Notes:** "Did threshold on treadmill; calf tightened before speed work."

Mixing these together makes the product hard to trust. Authored guidance should not be polluted by one day's execution notes, and athlete notes should not disappear into generic coaching copy.

## Lifecycle

### Morning Decision
1. Baseline receives a Reading and current context.
2. The Decision Engine computes readiness, certainty, limiters, and constraints.
3. The Planning Engine proposes today's plan or adapts the scheduled plan.
4. The athlete accepts, edits, or negotiates the plan.

### Plan Editing
1. A plan change is proposed by the athlete, Baseline, import, or conversation.
2. The app validates the change.
3. Meaningful future-facing changes create a new plan version.
4. The current accepted plan remains explainable and reversible.

### Workout Execution
1. The athlete starts a planned or ad-hoc workout.
2. Baseline shows the current prescription and relevant coach guidance.
3. The athlete logs actual performance and athlete notes.
4. The athlete can add, remove, reorder, substitute, skip, or extend work.
5. Pain or context events update constraints and can trigger remaining-work adaptation.
6. Completing the workout produces a Workout Log and Learning Signals.

### Learning
1. Baseline compares planned work to performed work.
2. It interprets what changed and why.
3. It connects performance and Athlete Notes to future readiness and planning.
4. It gradually personalizes recommendations and guidance.

## Engine Boundaries

### Evidence Engine
Owns observed inputs and daily evidence. It does not decide the plan.

### Context Engine
Turns conversation and user-provided information into structured context. It extracts and validates; it does not invent scores or silently rewrite plans.

### Decision Engine
Owns readiness, certainty, caps, limiters, and constraints. It is deterministic and auditable.

### Planning Engine / Plan Engine
Owns intended training: plan structure, planned sessions, prescriptions, substitutions, rescheduling, and version history.

### Workout Execution Engine
Owns performed training: active workout state, actual logs, athlete notes, modifications, skips, substitutions, pain events, and remaining-work recomputation.

### Learning Engine
Owns personalization from evidence over time, especially the deltas between proposed, accepted, and performed work.

## Durable Relationships
```
Program
  -> Training Block
  -> Week
  -> Day
  -> Planned Session
  -> Planned Exercise
      -> Exercise
      -> Prescription
      -> Coach Guidance

Workout Log
  -> Performed Exercise
      -> Actual Performance
      -> Athlete Notes
      -> Workout Events

Constraint
  -> affects Decision
  -> affects Plan
  -> may be created or updated during Workout Execution

Learning Signal
  -> compares Plan to Workout Log
  -> informs future Decisions, Plans, and Guidance
```

## What Belongs Elsewhere
This doc should not carry implementation-specific details that will age quickly.

Use `docs/technical-reference.md` for:
- Sensor APIs and UUIDs.
- HealthKit details.
- Scoring formulas and HR-zone equations.
- Model providers and import implementation.
- Firebase and persistence rules.
- Exercise dataset choices.
- Concrete logging enum names.
- Platform timelines and OS availability.

Use per-engine implementation docs for build plans, tool APIs, validation rules, storage schemas, and UI-specific execution details.
