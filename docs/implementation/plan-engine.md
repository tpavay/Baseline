# Baseline — Plan Engine (design, future)

*The future extension of the **Planning Engine**: from "what should I do **today**?" to create · edit · adapt · reorder a **structured training plan**. This is a design document, not a build — it defines the target so today's tool-calling layer (the Today Conversation slice) grows into it cleanly instead of becoming a dead end. It's **architecturally compatible** with the agent pattern already in `docs/architecture.md`, but it adds a substantial new **domain** layer (§10) — not trivial.*

*This is the **last** high-level design doc. After it: implementation, and everything else emerges from building and using the product.*

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

## 3. Data model
```
Program → TrainingBlock → Week → Day → Session → Exercise
```
Every level carries a **stable id** and an **ordering** field (so moves/reorders are unambiguous and reversible). Exercise-level **prescription** is structured, never free text:
- sets · reps **or** duration · load · distance · rest · target HR zone · RPE · notes · equipment · **movement category** · **intent**.

Without this model the AI can only rewrite text. With it, the AI becomes a real plan editor.

## 4. Training intent (the differentiator)
Every session has an **intent + purpose**, not just a name:
```
Session: "Threshold run"   intent: threshold   purpose: raise lactate threshold
```
Substitution preserves the intent: *replace threshold run → threshold bike* keeps the adaptation while dropping the impact. Adapting the **stimulus** rather than the label is one of Baseline's biggest long-term differentiators.

## 5. Tool API (validated operations)
The AI composes these; each is validated and applied by the app.
- **Structure:** `createProgram` · `createBlock` · `createWeek` · `addSession` · `updateSession` · `deleteSession` · `moveSession` · `reorderDays` · `reorderWeek` · `duplicateSession`
- **Exercise:** `addExercise` · `updateExercise` · `deleteExercise` · `reorderExercises` · `substituteExercise`
- **Prescription:** `updateSets` · `updateReps` · `updateLoad` · `updateDuration` · `updateRest` · `updateIntensityTarget`

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

Everything is **versioned regardless**, so even auto-applied edits are reversible. Start conservative (confirm more), relax as trust is earned. This directly answers "don't let it silently rewrite my program."

## 8. Validation
The AI cannot write the database. Every proposal passes **server- and client-side validation** — schema, ordering, dependency, conflict, and the Decision Engine's safety caps — before it's applied. Rejected proposals come back with a reason the AI can explain to the athlete rather than silently failing.

## 9. Version history (currently missing everywhere — required)
Every change is a **versioned, reversible transition**:
```
Plan v18 → moveSession(Thu→Sat) → Plan v19
```
Supports **undo · compare · restore**, and eventually *"show me why Baseline changed this"* — because each version records the **proposal + the evidence, context, and rules** that drove it. This is not yet in the architecture; treat it as a hard requirement of the Plan Engine.

## 10. New domain architecture this adds (compatible, not trivial)
The agent pattern is reused, but this introduces: program **schema** · **calendar semantics** · **training-intent taxonomy** · **progression rules** · **dependency validation** · **conflict handling** · **undo/version history** · **proposed-vs-accepted acceptance workflow**. Architecturally compatible with what exists; a real, sizable build.

## 11. Keeping today's build extension-ready
So the Today Conversation slice doesn't become a dead end, design its tool layer now to generalize later:
- Tool calls are **typed, validated, and versioned** from day one — even the small Today tools (update context, update constraint).
- The **proposed → validate → apply → recompute** path and the **proposed-vs-accepted** distinction exist from the first slice.
- The `ConversationService` + tool-dispatch abstraction is schema-agnostic, so pointing it at Program-editing tools later is additive.

## Status
**Design only.** Sequenced after: Today Conversation → Context Engine → program upload → **Plan Engine**. Companion to `docs/architecture.md` (extends the Planning Engine) and `docs/conversation-design.md` (how edits are proposed and confirmed in conversation).
