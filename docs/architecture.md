# Baseline — Product Architecture

*The master design document. It stays at the **architecture level** — responsibilities, boundaries, and philosophy. Field-level decisions (data types, storage choices, formulas, schemas) live in the per-responsibility implementation docs, so the product can evolve without this document churning.*

## The promise
> **"Baseline tells you what to train today."**

*Baseline helps you decide how to train today by combining your physiology, recent training, goals, and personal context.* HRV, Apple Health, training load, constraints, readiness, and the conversation all exist to serve that. Baseline is **not** "an HRV app" and **not** "a readiness score." The score is an input; the **plan for today** is the product. Positioned bluntly: a **personal training operating system that happens to use HRV** — people recommend it because "it tells me exactly what to do today," not for its HRV implementation.

## Core philosophy (the invariants)
- **Structured state is the source of truth.** Conversation is an *interface, not a datastore* — it matters, but it is not where truth lives. The Context Engine extracts durable information from conversation into structured state, and the Decision Engine operates *exclusively* on that structured state.
- **The Decision Engine owns truth.** Deterministic, auditable, never guesses. Everything else feeds it or interprets it — nothing overrides its caps or invents its scores.
- **Conversation is the primary input mechanism.** Not "forms plus a chat" — a conversation the app extracts structure from.
- **Natural before structured.** Encourage natural communication; Baseline extracts the structure. Structured controls (pickers, toggles, sliders, quick replies) are used only when they're faster, clearer, or less ambiguous than talking.
- **Today's plan is the hero.** Readiness, certainty, limiter, and evidence support it — they don't share top billing.
- **Recommendations are always explainable.** Every recommendation is traceable to the evidence, context, and rules that produced it — "Zone 2 because your 7-day load is elevated, HRV is suppressed, and your Achilles constraint is active," never an opaque "don't run today."
- **When evidence is insufficient, Baseline communicates uncertainty rather than manufacturing confidence.** Not-knowing is a valid, first-class output that shapes prompts, rules, UI, onboarding, and error handling.
- **Certainty = evidence available today**, not "Health connected = high."
- **Injuries are constraints, not just lower scores** — a constraint can gate the plan on a high-readiness day.
- **Simple UI, complex backend. Start hybrid-specific, design generic.**

---

## Architecture — organized by responsibility, not feature
```
Evidence Engine  →  Context Engine  →  Decision Engine  →  Planning Engine  →  Learning Engine (future)
```
Every capability slots into a responsibility, so new features have an obvious home: Garmin / WHOOP → **Evidence**; voice conversations → **Context**; workout planner → **Planning**; program upload → **Context** (extraction) + **Planning**; personalized adaptation → **Learning**. A thin **Presentation Layer** sits between Planning and the user so surfaces (home, widgets, Siri, Apple Watch, voice, notifications) are interchangeable views of the same plan — a codebase seam, not a product concern.

### Evidence Engine — automatically observed
Passive signals the user never types: HealthKit (sleep, resting HR, heart-rate samples, workouts, active energy, steps, distance), the morning HRV scan, and derived **training load**. Extensible by adding sources (CGM, weather, altitude, power meters, running dynamics) without touching anything downstream.

### Context Engine — user-provided, via conversation
Its responsibility is **not merely conversation**: it continuously **converts unstructured conversation into structured context the Decision Engine can trust.** Owns **training state** (goal, current phase, current plan, today's intent), equipment, available time, current pain/constraints, travel, mood, stress, preferences, and notes.
- **Objective:** acquire enough context to make the best recommendation with the *least user effort*.
- **Stopping condition = confidence, not question count** — it asks itself *"would another question meaningfully improve today's recommendation?"*; if no, it stops. Zero questions or fifteen, whatever it takes.
- **Always-on, not onboarding-bound.** "Slept four hours" (morning), "hamstring feels great today" (mid-workout), "signed up for a marathon" (evening) all update context and trigger recompute. Onboarding is simply its first session — *meeting your coach*: an interview, not a questionnaire, that extracts a power user's whole paragraph at once and guides a beginner naturally.
- It is the **primary interface between the user and the Decision Engine.**
- **Guardrails:** extract, explain, modify workouts, generate alternatives, parse plans — never invent scores or override caps. It talks to the Decision Engine through validated tools.

### Decision Engine — the deterministic core
Structured state → **domain scores** (autonomic, sleep, musculoskeletal, subjective, training load) → **caps + constraints** → **readiness + band + primary/secondary limiter + certainty**. Deterministic and unit-testable end to end. Constraints can gate the outcome even when the score is high.

### Planning Engine — today's plan
Turns the Decision Engine's state into a training **plan**: `(band × limiter × constraints × training state × style)` → today's action (type, summary, avoid list) — and, over time, substitutions, progression, volume adjustments, taper, and recovery strategy. **Training State** is richer than a goal — `Goal → Current Phase → Current Plan (optional) → Today's Intent (optional)`: the same "HYROX sub-60" produces very different plans in a base block vs. taper vs. race week. Constraints override the score-derived choice; style (conservative/balanced/aggressive) tunes strictness.

The engine **proposes; it doesn't dictate** — the plan is negotiable: **Proposed Plan → conversation → Accepted Plan.** ("Zone 2 today." — "I really want to run." — "Given your Achilles I'd bike; if you run, keep it 20–30 min flat and skip strides.") The **Accepted Plan** is what gets stored — users won't always follow the proposal, and that difference is signal. Hybrid-flavored copy; movement categories, not programmed sessions, until later phases.

### Learning Engine (future) — the feedback loop
Plans generate more evidence: **Proposed Plan → Accepted Plan → workout → feedback ("how did it feel?") → Evidence.** Tracking proposed-vs-accepted matters — users won't always follow the plan. Over time this learns **athlete-specific model parameters**: responds well to back-to-back threshold; HRV suppressed ~48h after sled work; soreness recovers faster than peers; low sleep has minimal impact; prefers morning training; performs poorly after travel; adapts well to heat. Those per-athlete calibrations are the moat.

---

## What's surfaced to the user
Home surfaces **today's plan first**, followed by the evidence supporting it: readiness, certainty, primary limiter/constraint, explanation, and avoid list. (How and where the conversation appears — home, bottom sheet, voice — is UI, not architecture; see the UX flow doc.)

## What gets stored
**Local-first.** Health data and app state stay on device; only **derived daily summaries** sync (later). The **structured state is the source of truth** — training profile (long-lived), daily context (resets), constraints (persist until resolved), daily readiness/plan entries, and chat *summaries*. Never the raw chat log.

## Roadmap
- **P1 — Decision + Planning Engines + training-load MVP.** Domain scores, caps, constraints, certainty, plan; HealthKit training load + HR zones; home; local persistence.
- **P2 — Context Engine.** Conversational onboarding and always-on context capture → structured state → recompute; explain / modify / alternatives; backend proxy; derived summaries sync.
- **P3 — Adaptive Decision Engine (Learning Engine).** Feedback loop from completed workouts; per-athlete personalization.
- **P4 — History & trends.** Weekly readiness / load / HRV / sleep / constraints + summaries.
- **P5 — Program upload.** Text/image/PDF → structured workouts (Context extraction) → planned-workout × readiness swap (Planning).

## Companion docs
- **Product Principles** (`docs/product-principles.md`) — the invariants above, expanded.
- **UX Flow** (`docs/ux-flow.md`) — first launch → onboarding → Health sync → HRV scan → first plan → context update → updated plan.
- Per-responsibility implementation docs (field-level): Decision Engine · Planning Engine · Evidence & HealthKit · Training Load · Context Engine · Backend · Prompt Engineering · Data Model · UI/UX. These supersede/reconcile the earlier `readiness-score.md`, `engine-and-data-model.md`, and `v0-spec.md`.
