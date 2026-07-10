# Baseline — Product Architecture

*The master design document. It stays at the **architecture level** — responsibilities, boundaries, and philosophy. Field-level decisions (data types, storage choices, formulas, schemas) live in the per-responsibility implementation docs, so the product can evolve without this document churning.*

## The promise
> **"Baseline tells you what to train today."**

*Baseline helps you decide how to train today by combining your physiology, recent training, goals, and personal context.* HRV, Apple Health, training load, constraints, readiness, and the conversation all exist to serve that. Baseline is **not** "an HRV app" and **not** "a readiness score." The score is an input; the **plan for today** is the product. Positioned bluntly: a **personal training operating system that happens to use HRV** — people recommend it because "it tells me exactly what to do today," not for its HRV implementation.

## Core philosophy (the invariants)
- **Structured state is the source of truth.** Conversation is an *interface, not a datastore* — it matters, but it is not where truth lives. The Context Engine extracts durable information from conversation into structured state, and the Decision Engine operates *exclusively* on that structured state.
- **The Decision Engine owns truth.** Deterministic, auditable, never guesses. Everything else feeds it or interprets it — nothing overrides its caps or invents its scores.
- **Conversation is the primary interface.** Not "forms plus a chat" — the user interacts with Baseline through conversation (input, onboarding, explanation, negotiation, coaching), and the app extracts structure from it.
- **Ask for the minimum information necessary.** Infer first, observe second, ask last — the Context Engine requests more only when it would materially improve today's plan.
- **Natural before structured.** Encourage natural communication; Baseline extracts the structure. Structured controls (pickers, toggles, sliders, quick replies) are used only when they're faster, clearer, or less ambiguous than talking.
- **Today's plan is the hero.** Readiness, certainty, limiter, and evidence support it — they don't share top billing.
- **Planned work and performed work stay separate.** The plan is the intended training; the workout log is what actually happened. Baseline can compare them, learn from the delta, and propose plan revisions, but it never overwrites intent with actuals.
- **Recommendations are always explainable.** Every recommendation is traceable to the evidence, context, and rules that produced it — "Zone 2 because your 7-day load is elevated, HRV is suppressed, and your Achilles constraint is active," never an opaque "don't run today."
- **When evidence is insufficient, Baseline communicates uncertainty rather than manufacturing confidence.** Not-knowing is a valid, first-class output that shapes prompts, rules, UI, onboarding, and error handling.
- **Certainty = evidence available today**, not "Health connected = high."
- **Injuries are constraints, not just lower scores** — a constraint can gate the plan on a high-readiness day.
- **Simple UI, complex backend. Start hybrid-specific, design generic.**

---

## Architecture — organized by responsibility, not feature
```
Evidence Engine  →  Context Engine  →  Decision Engine  →  Planning Engine  →  Workout Execution Engine  →  Learning Engine (future)
```
Every capability slots into a responsibility, so new features have an obvious home: Garmin / WHOOP → **Evidence**; voice conversations → **Context**; workout planner → **Planning**; program upload → **Context** (extraction) + **Planning**; active workout logging → **Workout Execution**; personalized adaptation → **Learning**. A thin **Presentation Layer** sits between the engines and the user so surfaces (home, workout screen, widgets, Siri, Apple Watch, voice, notifications) are interchangeable views of the same structured state — a codebase seam, not a product concern.

### Evidence Engine — automatically observed
Passive signals the user never types: HealthKit (sleep, resting HR, heart-rate samples, workouts, active energy, steps, distance), the morning HRV scan, and derived **training load**. Extensible by adding sources (CGM, weather, altitude, power meters, running dynamics) without touching anything downstream.

### Context Engine — user-provided, via conversation
Its responsibility is **not merely conversation**: it continuously **converts unstructured conversation into structured context the Decision Engine can trust.** Owns **training state** (goal, current phase, current plan, today's intent), equipment, available time, current pain/constraints, travel, mood, stress, preferences, and athlete-provided context.
- **Objective:** acquire enough context to make the best recommendation with the *least user effort*.
- **Stopping condition = confidence, not question count** — it asks itself *"would another question meaningfully improve today's recommendation?"*; if no, it stops. Zero questions or fifteen, whatever it takes.
- **Always-on, not onboarding-bound.** "Slept four hours" (morning), "hamstring feels great today" (mid-workout), "signed up for a marathon" (evening) all update context and trigger recompute. Onboarding is simply its first session — *meeting your coach*: an interview, not a questionnaire, that extracts a power user's whole paragraph at once and guides a beginner naturally.
- It is the **primary interface between the user and the Decision Engine.**
- **Guardrails:** extract, explain, modify workouts, generate alternatives, parse plans — never invent scores or override caps. It talks to the Decision Engine through validated tools.

**Internal pipeline** — the LLM only understands language; the app decides what happens:
```
conversation → intent detection → structured extraction → validation → Decision Engine
```
The model turns words into *candidate* structured updates; the app validates them; the deterministic engine decides.

**Conversation Runtime (provider-agnostic).** The intelligence sits behind a `ConversationService` abstraction — never a `ClaudeService`. The runtime decides *where* a request runs (on-device for lightweight extraction / intent / summaries; cloud for coaching, negotiation, explanation, complex reasoning) and *which* provider — the Context Engine and everything downstream never know or care. This keeps Baseline model-agnostic (Claude / GPT / Gemini / Apple / next) for years without touching Decision or Planning.

### Decision Engine — the deterministic core
Structured state → **domain scores** (autonomic, sleep, musculoskeletal, subjective, training load) → **caps + constraints** → **readiness + band + primary/secondary limiter + certainty**. Deterministic and unit-testable end to end. Constraints can gate the outcome even when the score is high.

### Planning Engine — today's plan
Turns the Decision Engine's state into a training **plan**: `(band × limiter × constraints × training state × style)` → today's action (type, summary, avoid list) — and, over time, substitutions, progression, volume adjustments, taper, and recovery strategy. **Training State** is richer than a goal — `Goal → Current Phase → Current Plan (optional) → Today's Intent (optional)`: the same "HYROX sub-60" produces very different plans in a base block vs. taper vs. race week. Constraints override the score-derived choice; style (conservative/balanced/aggressive) tunes strictness.

The engine **proposes; it doesn't dictate** — the plan is negotiable: **Proposed Plan → conversation → Accepted Plan.** ("Zone 2 today." — "I really want to run." — "Given your Achilles I'd bike; if you run, keep it 20–30 min flat and skip strides.") The **Accepted Plan** is what gets stored — users won't always follow the proposal, and that difference is signal. Hybrid-flavored copy; movement categories, not programmed sessions, until later phases.

*Future — the **Plan Engine** (`docs/implementation/plan-engine.md`).* The same engine grows from "today's action" into **create / edit / adapt / reorder** over a structured `Program → Block → Week → Day → Session → Exercise` model, with intent-preserving substitution, staged **trust levels**, a **confirmation/acceptance** workflow, and **version history**. Same agent loop (propose → validate → apply → recompute); a substantial new *domain* layer.

### Workout Execution Engine (future) — plan to performed work
Owns the active training session after the athlete accepts or starts a workout. It starts planned or ad-hoc workouts, tracks completed work, logs actual performance, records skips/substitutions/modifications, captures athlete notes, preserves pain events as constraints, and asks the Planning Engine to recompute remaining work when the session changes midstream.

The durable product loop is:
```
Plan → start workout → log performance → add Athlete Notes/context → complete or modify session → recompute training state → adapt remaining plan
```

This is where Baseline becomes a full training system rather than a readiness score with advice. The Planning Engine owns **intended work**; Workout Execution owns **performed work**. A threshold run planned as `4 x 5 min + 6 x 30 sec speed` can be logged as threshold completed, speed skipped because of calf pain, with the skipped speed work moved later only through an explicit, versioned plan revision.

The conversation layer talks to this engine through validated workout operations. The model proposes; the app validates, applies, and recomputes.

### Learning Engine (future) — the feedback loop
Plans generate more evidence: **Proposed Plan → Accepted Plan → performed workout → Athlete Notes / pain / modifications → Evidence.** Tracking proposed-vs-accepted and planned-vs-performed matters — users won't always follow the plan, and mid-workout changes are signal. Over time this learns **athlete-specific model parameters**: responds well to back-to-back threshold; HRV suppressed ~48h after sled work; soreness recovers faster than peers; low sleep has minimal impact; prefers morning training; performs poorly after travel; adapts well to heat; calf pain tends to follow speed work. Those per-athlete calibrations are the moat.

---

## What's surfaced to the user
Home surfaces **today's plan first**, followed by the evidence supporting it: readiness, certainty, primary limiter/constraint, explanation, and avoid list. (How and where the conversation appears — home, bottom sheet, voice — is UI, not architecture; see the UX flow doc.)

## What gets stored
**Local-first.** Health data and app state stay on device; only **derived daily summaries** sync (later). The **structured state is the source of truth** — training profile, daily context, constraints, daily readiness/plan entries, accepted plan versions, coach guidance, workout logs, athlete notes, skips, substitutions, pain events, and chat *summaries*. Never the raw chat log.

## Roadmap
**v1 is the morning decision loop — the conversation included.** The conversation *is* the interface; a person opens Baseline and talks to it. Shipping the engines without it would be a different, lesser product (just another HRV/readiness app). So v1 spans Evidence + Context + Decision + Planning, chat-forward from the first open. The complete training-system loop adds Workout Execution next: plan → perform → log → adapt.
- **v1 — the working morning loop.** Decision + Planning engines + training-load MVP (HealthKit, HR zones) **and** a conversational shell for onboarding + context. The conversation is present from day one, but v1's version is a **thin, mostly-deterministic script** that stores structured state — so it *feels* like talking to Baseline without a frontier model yet. The `ConversationService` abstraction is in place so the real LLM slots in behind it with no change to Decision/Planning. Local persistence. This is what a person opens every morning.
  - *Build order within v1:* the deterministic engine first (the truth the conversation speaks about — the engine owns truth, the conversation never invents it), then the conversational shell on top.

**AI lands in stages, behind the Conversation Runtime — conversational UX from day one, implementation gets smarter:** (1) conversation UX, deterministic, no LLM; (2) structured extraction (LLM: free text → structured state); (3) negotiation & explanation (LLM); (4) workout logging tools; (5) learning. Every stage is transparent to the Decision, Planning, and Workout Execution engines.
- **Next — Workout Execution.** Structured workout model, manual logging, actual-vs-planned deltas, Athlete Notes, skips/modifications, and live HR-zone history.
- **Then — Voice/chat-assisted logging.** Natural-language logging becomes validated tool calls over the workout model, not chat history.
- **Then — Learning / Adaptive Decision Engine.** Feedback from completed workouts; per-athlete personalization.
- **Then — History & trends.** Weekly readiness / load / HRV / sleep / constraints + summaries.
- **Later — Program upload.** Text/image/PDF → structured workouts (Context extraction) → planned-workout × readiness swap (Planning).

## Companion docs
Design docs (experience level):
- **Product Principles** (`docs/product-principles.md`) — the invariants above, expanded.
- **Engine & Data Model** (`docs/engine-and-data-model.md`) — durable entities, lifecycle, relationships, and engine boundaries.
- **UX Flow** (`docs/ux-flow.md`) — first launch → onboarding → Health sync → HRV scan → first plan → context update → updated plan → living with Baseline.
- **Conversational Experience** (`docs/conversation-design.md`) — how Baseline talks and feels to interact with: greeting, verbosity, explanation, negotiation, admitting uncertainty, when it stops asking, personality. A UX doc, not an AI/prompt doc.

Implementation docs (field level): Decision Engine · Planning Engine · **[Plan Engine](implementation/plan-engine.md)** (future) · **[Workout Execution](implementation/workout-execution.md)** (future) · Evidence & HealthKit · Training Load · Context Engine · Backend · Data Model · UI Spec · **Technical Reference** (`docs/technical-reference.md`).
