# Baseline — Plan Engine (design, future)

*The future extension of the **Planning Engine**: from "what should I do **today**?" to create · edit · adapt · reorder a **structured training plan**. This is a design document, not a build — it defines the target so today's tool-calling layer (the Today Conversation slice) grows into it cleanly instead of becoming a dead end. It's **architecturally compatible** with the agent pattern already in `docs/architecture.md`, but it adds a substantial new **domain** layer (§10) — not trivial.*

*In one line: **Baseline is building Git for training plans.** A plan is an evolving, versioned document — every meaningful change is immutable, attributable, and explainable, and you can diff, undo, and restore it.*

## 1. Purpose
Solve, over a real training plan:
- **Create** a plan (from a template, a library, or an upload).
- **Edit** it (add/remove/reorder sessions and exercises; change a prescription).
- **Adapt** it to today's readiness, constraints, travel, and available time.
- **Substitute** sessions while **preserving training intent** (a threshold run → a threshold bike, not "skip it").
- **Reorder** the week/calendar around what the athlete can actually do.

The wedge this unlocks: **readiness × your program → an adaptive calendar.** *"I'd swap today's threshold run with Saturday's Zone 2 — you keep the week's intent and take the load off your Achilles."*

## 2. Where it fits
It extends the Planning Engine and rides the **same agent loop** as the rest of Baseline:
```
Conversation → Tool proposal → Validation → Database → Decision Engine → Planning Engine → Updated plan
```
The AI **never edits data directly.** It proposes *validated operations*; the app validates, applies, versions, and recomputes. Once a program exists, "today's plan" becomes *"should I modify today's scheduled session?"* — a harder question the Decision + Planning engines still own.

**Plan Repository.** Between the Planning Engine and the Presentation Layer sits a **Plan Repository** — the versioned store that owns the *current* version, all *previous* versions, the *accepted* version, undo, and diffs. Not another engine; a clean separation so the plan is an evolving, auditable document rather than a mutable blob:
```
Planning Engine → Plan Repository → Presentation
```

**Boundary with Workout Execution.** The Plan Engine owns **intended training**: planned sessions, prescriptions, Coach Guidance, order, and version history. The future Workout Execution Engine owns **performed training**: actual sets/reps/load/duration/distance/pace, completed work, skipped work, substitutions, Athlete Notes, and pain events. Workout actuals never overwrite the plan. If a workout event should change future training, it creates a validated plan operation and a new Plan Repository version.

## 3. Data model — a fully editable hierarchy
Every layer of the plan is an addressable, editable node — from the whole program down to a single set:
```
Program
  → Training Phase     (multi-week block / mesocycle — base, build, peak, taper)
  → Week
  → Day
  → Workout            (a dated session the athlete performs; the planned session)
  → Workout Block      (a semantic group inside a workout: warm-up, strength, metcon, HYROX stations, cooldown)
  → Exercise
  → Prescription       (the structured target for that exercise)
  → Set / Interval     (a single set or interval, addressable on its own)
```
Every level carries a **stable id** and an **ordering** field, so moves and reorders are unambiguous and reversible.

> **Baseline supports validated, reversible edits at every level of the training hierarchy — from the overall program down to individual sets and intervals. Workout Blocks are semantic containers, not atomic units. Exercises may be added, removed, reordered, substituted, or moved between blocks; prescriptions may be changed at exercise or set level; entire blocks may be added, removed, reordered, or modified. All future-facing changes remain versioned and explainable.**

**Two different "blocks" — don't conflate them:**
- **Training Phase** — the multi-week macro layer (mesocycle). *(Earlier drafts called this a "Training Block".)*
- **Workout Block** — an intra-workout grouping that captures *purpose* (why these exercises sit together). It helps Baseline understand intent and adaptation, but it is a **semantic container, not an atomic unit**: it never prevents editing inside it, and exercises move freely between blocks.

**The hierarchy provides structure; no layer is immutable.** A block explains purpose; it does not lock its contents.

Exercise-level **prescription** is structured, never free text:
- sets · reps **or** duration · load · distance · rest · target HR zone · RPE · tempo · pace · equipment · **movement category** · **intent**.

Individual **sets / intervals** are addressable, so one set can change (load/reps) without rewriting the exercise, and **actual performance is logged separately from the planned prescription** — Workout Execution owns the actuals; the plan keeps the intent.

Each planned exercise also carries **Coach Guidance** (goal · intent · tempo · form cues · common mistakes · why it exists · progression notes · media) separately from the prescription and from Athlete Notes. The Plan Engine owns authored guidance; Workout Execution owns Athlete Notes; Context-Aware Guidance is generated from the two without mutating either.

Without this model the AI can only rewrite text. With it, the AI becomes a real plan editor.

### 3a. Valid operations by level
No layer is a dead end — each supports both structural and fine-grained edits:
- **Workout:** rename · change overall goal · add/remove/reorder blocks · move blocks · duplicate · split or merge workouts.
- **Workout Block:** rename · change goal/intent · add/remove/reorder exercises · move an exercise into another block · duplicate · delete · change dose or priority.
- **Exercise:** add · delete · substitute · reorder · move between blocks · update sets/reps/load/duration/rest/pace/zone/tempo · edit Coach Guidance · add notes.
- **Set / Interval:** change one set without touching the rest · add/remove a set · change load or reps for a single set · log actual performance separately from the planned prescription.

## 4. Preserve adaptation (the defining philosophy)
Most coaching apps, when life interferes, **cancel or delay** ("skip today's run"). Baseline should instead **preserve the adaptation** — keep the intended physiological stimulus while respecting the constraint. That's a fundamentally different philosophy, and it may be Baseline's defining feature.

> **The Planning Engine optimizes for preserving the intended physiological adaptation whenever possible, rather than cancelling or delaying training.**

It works because every session carries an **intent + purpose**, not just a name:
```
Session: "Threshold run"   intent: threshold   purpose: raise lactate threshold
```
So a constraint becomes a **substitution that keeps the stimulus**:
- Threshold run → **threshold bike**
- Heavy squat → **belt squat**
- Running → **SkiErg**
- Outdoor run → **treadmill**

Preserve the stimulus; respect the constraint. Adapting the *stimulus* rather than the *label* is one of Baseline's biggest long-term moats.

## 5. Tool API (validated operations)
The AI composes these; each is validated and applied by the app. There is a valid operation at **every level** of the hierarchy (§3) — structural *and* fine-grained. These are **plan-editing** tools, not workout-logging tools; logging tools live with Workout Execution and may request plan edits after validation.
- **Program / phase / calendar:** `createProgram` · `createPhase` · `createWeek` · `addWorkout` · `updateWorkout` · `deleteWorkout` · `moveWorkout` · `reorderDays` · `reorderWeek` · `duplicateWorkout` · `splitWorkout` · `mergeWorkouts` · `updateWorkoutGoal`
- **Workout Block:** `addBlock` · `deleteBlock` · `moveBlock` · `reorderBlocks` · `duplicateBlock` · `updateBlockGoal`
- **Exercise:** `addExercise` · `deleteExercise` · `reorderExercises` · `moveExercise` *(including into another block)* · `substituteExercise` · `updateExercisePrescription`
- **Prescription / set:** `updateSets` · `updateReps` · `updateLoad` · `updateDuration` · `updateRest` · `updateIntensityTarget` · `updateSet` · `addSet` · `deleteSet`
- **Coach Guidance:** `updateCoachGuidance` *(goal · tempo · form cues · common mistakes · progression notes)* · `attachMedia`
- **Triggered by workout actuals:** `moveExerciseToLaterDate` · `replanWeek` · `updateConstraint` · `substituteRemainingWork`

## 6. Trust levels (staged capability)
Each level needs more intelligence, more domain data, and more confirmation:
- **L1 — Explicit edits.** *"Move Thursday to Friday."* High confidence, a direct tool call.
- **L2 — Substitutions.** *"Replace the run with the bike."* Needs exercise metadata + intent mapping.
- **L3 — Week restructuring.** *"My Achilles hurts — rebuild this week around it."* Needs constraints, recovery state, session dependencies, and weekly load rules.
- **L4 — Full generation.** *"Build me a 12-week sub-60 HYROX block."* Uses **templates + deterministic progression rules + validation + confirmation** — *not* unrestricted LLM generation.

Build the ladder bottom-up; earn each rung before the next.

## 7. Confirmation & acceptance (the "confirmation engine")
The AI **proposes**; the athlete **accepts**. Confirmation scales with **blast radius + trust level**:
- **Low-risk, single-field, easily reversible** (one rep count, one exercise) → apply optimistically; always undoable.
- **Structural / multi-session / destructive** (reorder days, restructure a week, swap or delete sessions, any program-level change, generation) → **propose → show the diff (what changes and why) → confirm → apply.**

Everything is **versioned regardless**, so even auto-applied edits are reversible. Start conservative (confirm more), relax as trust is earned.

> **Hard rule: the AI must never silently change future training.** Any change to a future session creates a new *proposed* version the athlete sees — coming back to find half your week rearranged with no trace is unacceptable. Every change is explainable and attributable.

## 8. Validation
The AI cannot write the database. Every proposal passes **server- and client-side validation** — schema, ordering, dependency, conflict, and the Decision Engine's safety caps — before it's applied. Rejected proposals come back with a reason the AI can explain to the athlete rather than silently failing.

## 9. Plan History — Git for training plans
A training plan is an **evolving document, not a static object.** Every meaningful modification creates a **new immutable version** — this versioning is a **first-class concept**, and it's effectively *Git for training plans*.

Each version records:
- **timestamp**
- **actor** — user · Baseline · imported
- **reason**
- **supporting evidence** — the readiness, context, and rules that drove it
- **diff**

```
Plan v18 → moveWorkout(Thu→Sat)  [actor: Baseline · reason: Achilles constraint] → Plan v19
```
This enables **undo · compare · restore · explain · audit · experiment** — and eventually *"show me why Baseline changed this."* It's owned by the **Plan Repository** (§2) and is a hard requirement of the Plan Engine, not an afterthought.

## 10. New domain architecture this adds (compatible, not trivial)
The agent pattern is reused, but this introduces: program **schema** · **calendar semantics** · **training-intent taxonomy** · **progression rules** · **dependency validation** · **conflict handling** · **undo/version history** · **proposed-vs-accepted acceptance workflow**. Architecturally compatible with what exists; a real, sizable build.

## 11. Keeping today's build extension-ready
So the Today Conversation slice doesn't become a dead end, design its tool layer to generalize — without over-building the small stuff:
- Tool calls are **typed and validated** from day one — even the small Today tools (update context, update constraint).
- **Versioning and proposed-vs-accepted scale with blast radius (§7).** Low-risk, today-scoped, single-item mutations (daily context, one constraint) **apply directly** and are trivially reversible — no version wrapper needed. The **version history + proposed-vs-accepted** machinery is required for **Plan edits** (structural / multi-session / future-affecting) and is owned by the **Plan Repository** (§2), not bolted onto every micro-mutation.
- The `ConversationService` + tool-dispatch abstraction is schema-agnostic, so pointing it at Program-editing tools later is additive.
- Preserve the planned-vs-performed boundary from the first workout model. Even a simple manual logger should link actuals back to a planned prescription rather than mutating the prescription in place.

## Status
**Design only.** Sequenced after: Today Conversation → Context Engine → program upload → **Plan Engine**. Companion to `docs/architecture.md` (extends the Planning Engine) and `docs/conversation-design.md` (how edits are proposed and confirmed in conversation).
