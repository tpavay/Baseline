# Baseline — UX Flow

*How the product feels end to end, at the flow level (not pixels). It maps the first-run journey and the daily loop onto the engines in `docs/architecture.md`, and honors `docs/product-principles.md` — conversation-first, plan-as-hero, explainable, honest about uncertainty. Screen-level specs live in the UI/UX implementation doc.*

Legend: **[E]** Evidence · **[C]** Context · **[D]** Decision · **[P]** Planning engine touchpoints.

---

## Navigation model - three modes, four tabs
The app is **three modes** the athlete is never in two of at once — *Decide, Plan, Train* — plus setup. "Workout" is an overloaded word for three different objects, so the execution surface is **Train**; it is entered by starting a session from **Plan** or from the Train tab itself.

```
Today            Plan                  Train            Profile
= Decide         = the calendar        = execute        = setup
"what should     "what am I scheduled  "log what I'm
 I do?"           for?" → start it      doing"
```

*Follow-up: consolidating the navigation model into its owner (`docs/implementation/plan-tab.md`) is tracked in issue #57.*

**Three objects, never conflated:**
- **Program** — long-term training (HYROX Dallas, Marathon Base, Shoulder Rehab). An athlete can have several at once; Today reasons across all of them.
- **Workout** — a *planned* session inside a program/day (has a date, lives on the calendar).
- **Training Session** — the thing you actually *execute and log* (no dates — you're training). A Workout becomes a Training Session when you Start it.

`Program → Calendar → Workout → (Decision Engine) → Training Session`. This is the wedge: Hevy starts at the Training Session; FITR starts at the Program; Baseline needs both, joined by readiness.

**Why this matters:** "Today's Workout — NOT TODAY" feels wrong because it forces one screen to be planning *and* execution. In this model, tapping today's workout enters a **Training Session** (no dates, no "not today"); dates only matter while browsing the **Plan** calendar. The date-scoping banner is a stopgap that this modes split removes.

- **Plan** — Programs (open the only one automatically; show cards if several) → week → **workout cards** (FITR-style, cleaner than a grid) → **Workout Detail** (the workout's one note · today's adaptation · blocks · Talk to Baseline · **Start Session** / Edit).
- **Train** — Hevy-style execution: exercise → log → complete → next → reflection → Decision Engine → history. Includes **Start Empty Session** (walk in, no plan needed).
- **AI is everywhere**, scoped to the surface: Plan ("build next week"), Workout Detail ("swap sled pushes"), Train ("I skipped these"), History ("why has my deadlift stalled?").

*Status: Today, Train (execution editor), the Plan calendar, and Workout Detail exist, and the Program object is modeled. The remaining Plan Engine slices are sequenced in `docs/implementation/plan-tab.md`.*
- **Today** — the day's recommendation (readiness → plan). Opened every day.
- **Plan** — one bounded week at a time: every day is a row, and a day's sessions are cells in it; tap a session → **Workout Detail**. The primary action is **Talk to Baseline / Edit with Baseline** (not a generic "Adjust Plan"). *(The weekly grid and Workout Detail shipped; the day-state rules and the remaining behavior are owned by `docs/implementation/plan-tab.md`.)*
- **Train** — the **current** session being executed (not a library). Collapsible blocks; per-exercise `•••` menu; set logging. Opened every workout.
- **Profile** — setup, devices, integrations. Occasional.

**History is a capability, not a destination.** It's reached *through* the surfaces that need it (reading history from Today; exercise history from Exercise Detail; workout history from Plan), never the tab bar. The shell is **Today / Plan / Train / Profile** - `MainTabView`'s floating tab bar, per the approved taxonomy prototype. Plan also opens/starts/resumes any workout (`docs/implementation/plan-tab.md`), so Train is the live execution surface, not a workout library.

**The chat never navigates away.** "Talk to Baseline" is always a **bottom sheet / floating panel** over the current screen — drag-to-peek, dismiss back to where you were — so you can ask "should I add weight?" on Set 3 without leaving the workout.

**Four screens, four flows:**
- **Today → Workout Detail** — *understanding*: opens **Note → Today's Context → Blocks** (why am I doing this today comes first). The workout level carries one athlete-owned note, not a stacked goal plus coach block; coach guidance stays plan metadata and surfaces per exercise.
- **Workout (execution)** — blocks **collapsed by default** (long sessions don't become enormous), one expanded at a time; each exercise `•••` → Talk about this exercise · Skip · Substitute · Move · Coach Notes · History · Delete · Duplicate. So the chat doesn't have to do everything.
- **Exercise Detail** (the missing screen) — tap an exercise → History · Best · Recent · Coach Guidance · Current Prescription · Video · Notes · Progression · Talk to Baseline. The home for "how much did I deadlift last month? compare today. should I increase?" — cleaner than burying it in a History tab.

**Naming:** the execution tab is named **Train** - "Workout" sounds static and is overloaded; "Train" reads as intent. Landed with the taxonomy shell.

*Status: the Today, Plan, Train (execution), and Profile tabs and the Workout Detail screen exist, and the workout note is one field there. Today's Context ordering above and Exercise Detail remain designed-only and build on the Plan Engine + workout-history persistence.*

### Interaction density — steal Hevy's muscle memory
Copy Hevy's *interaction density*, not its product. **Exercises are collapsible document rows, not cards** — a name row separated by whitespace/thin rules; collapsed by default, expanding inline into a **logging table** (`# · TIME · DIST · ⋯` — columns generated from the exercise's selected metrics). A 40-exercise workout is 40 rows, not 40 giant cards. **Blocks are lightweight section headers** (Apple-Notes style: a label + hairline rule), *not* cards — organization, not decoration; they let the exercises breathe, and the implicit default block shows nothing at all. Baseline layers its value *on expand*: today's goal · context · coach guidance appear only when an exercise is open (not always). *(Built: light rows, section-header blocks, collapse-by-default, dynamic metric columns, drag reorder via the workout ⋯ → **Reorder Workout** sheet. Follow-ons: coach-guidance-on-expand — needs the guidance model; per-row thumbnails.)*

### The routine is the plan; the logging table is the execution
Planned-vs-actual is separated by **mode, not by column** — no "Planned"/"Actual" headers. The *same* set table reads two ways:
- **Planning** (not started): cells edit the **prescription** — the target. This is the plan the coach/AI authored.
- **Training** (started): each cell pre-fills with the plan value *as its placeholder*; typing records the **actual** (stored on the log, never overwriting the plan). "If you only managed 170×12, that's what gets stored." A **✓ per set row** is the completion gesture — check it and the row grays, the next becomes active; when every set is checked the **exercise auto-completes**. There is no exercise-level "Complete" button and no separate log sheet.

The exercise **⋯ menu** is: *History* · *Metrics* (which columns) · *Units* (how each shows) · *Replace* (substitute) · and, when planning, *Edit Workout Label* · *Move to Block* · *Duplicate* · *Remove Exercise*. Deferred until its data exists: *Coach Guidance*, never faked with placeholder data.

**Training-mode edits are this workout's, not the plan's.** While logging, the same menu also offers *Edit Sets & Targets* and a destructive *Remove from This Workout*: a **true removal**, not a reversible skip, so it also discards that exercise's logged sets (confirmed first when there are any). Grouped exercises keep the round-level *Remove This Round / All Rounds* and *Restore* as skips, because those are logging facts about a round rather than structural edits. Every block also carries an **Add Exercise** button while logging, because deciding to do extra work is far more common than sitting down to redraft the plan. The workout ⋯ adds **Reorder Workout**, a two-level sheet: reorder blocks, then exercises within one block. Moving an exercise *between* blocks stays with *Move to Block*, so a drag can never do it. Everything edited here shapes this session only; the saved plan changes only if the athlete accepts the completion prompt (see the mid-workout-edit rule in `CLAUDE.md`).

### Direct manipulation, not forms
The workout is a **living document** — edit objects directly, like Notion / Things, not "tap → modal → form → Save → return." Tapping **+ Block** inserts *Block N* immediately (rename inline); **+ Exercise** opens a search sheet and the pick is inserted at once, auto-expanded, ready to edit; set values are **inline-editable fields** (tap and type); **+ Set** duplicates the last set (copy structure + values, change only what differs — like duplicating a spreadsheet row). **Autosave everywhere** — the model is versioned/undoable, so there is no Save button. Chat and the UI edit the *same object*: every conversation edit is possible manually, every manual edit possible through conversation. *(Built for the execution screen: inline block rename, direct-insert exercise, inline set values, duplicate set, add-metric inline.)*

### Adding an exercise — Hevy-model multi-select
Steal the interaction model that already works: **search → multi-select → Add N exercises** (like Photos). Recents first, then **all exercises A–Z** (never random); **category chips** (All / Cycling / Strength / …) filter; each row has a **glyph/thumbnail + name + category tag + selection state**; the keyboard follows iOS convention (scroll dismisses; a sticky **Add N** bar sits above it). Selecting a stable **Exercise Definition** comes before typing, so identity/aliases/history never break. Custom definitions are created **explicitly** ("Create custom exercise"), never from a typo. Inserted exercises carry their **remembered metrics + units** (no setup) and drop straight into the editor for inline editing. *(Built. Follow-ons that need catalog media/metadata: real thumbnails; searching muscles / equipment / movement patterns; a Favorites chip.)*

### Blocks are optional — via an implicit default block (NOT a mixed hierarchy)
Don't force blocks, but **don't** corrupt the model with `Content = Exercise | Block` either — a mixed hierarchy adds needless complexity everywhere (ordering two entity types, root↔block moves, tool ambiguity, render/persistence/version branches). Keep the invariant **`Workout → Block → Exercise`** and use an **implicit default block**: every workout has one internally, but its header is **never** rendered — while it's the only block the workout reads flat (Hevy-style), and if it holds loose exercises alongside named blocks those render headerless at the top. The auto "Main" label never appears as a section. Rules: new workout gets one default block; workout-level Add Exercise lands there; **adding a user block drops the empty default** (`addUserBlock` — so you name your own block instead of getting a phantom "Main" beside it) but keeps a default that holds loose exercises; deleting all explicit blocks falls back to a fresh default (always ≥1 block); the agent's add lands in the single implicit block regardless of block name; chat creates named blocks only for distinct purposes. *(Built.)*

**Removing a set:** swipe a set row left to reveal a trash affordance, then tap — the only way to delete a set (planning keeps a Duplicate button in-row; training has just the checkbox). *(Built.)*

### Where Baseline differentiates
Steal the boring, well-optimized parts (the Add-Exercise sheet, set logging) from apps like Hevy. **Differentiate on everything *after* the exercise is added:** AI builds the workout, rich structure + readiness-driven adaptation, coach guidance, conversation, learning. The Exercise Detail screen adds what Hevy lacks — **today's goal + context + coach note** alongside history.

### Two creation modes — conversation to create, controls to correct
**Use conversation to create and reshape; use controls to inspect, correct, and execute.** Same agent, three presentations by task complexity:
1. **Inline bar** — quick scoped questions/edits during a workout ("add one set", "why this exercise?", "log 3×8 at 225").
2. **Bottom sheet** — scoped edits to the current object (drag-to-peek; already the Ask Baseline presentation).
3. **Full-screen "Build with Baseline"** — creating or restructuring a whole workout/week. A **split interaction**: conversation + a **live structured preview** using the *same* Block/Exercise cards as the real Plan. On iPhone, stacked: conversation ─ draft workout cards ─ **Apply changes**. Nothing commits until applied ("Build Thursday: 45 min Z2 bike, then 3 rounds of carries + Copenhagen planks" → a structured draft with **Add to Thursday / Edit / Ask a question**). This is the right place for complex creation — not the tiny composer.

The **Plan** tab exposes both: `[ Build with Baseline ]` + `[ + Add manually ]` at the top; each day card has `Open / Ask Baseline / •••`; Workout Detail has `Edit with Baseline` which opens chat **already scoped to that workout**. *(The full-screen builder + Plan surfaces build on the Plan Engine.)*

---

## Part 1 — First launch → first plan

The goal of first run: **reach a first, honest plan with the least effort** — and be upfront when evidence is still thin.

> **The user should never feel like they are "feeding the app."** Every question, permission request, and interaction has an immediately understandable benefit to *today's plan*.

### 1. Welcome
One line on the promise: *"Baseline tells you what to train today — from your body, your training, and your goals."* Single CTA: **Set up Baseline**. No feature tour.

### 2. Meet Baseline for the first time (conversational onboarding) **[C]**
Not a form — the Context Engine's first session. Opens as Baseline itself (the brand, not "your AI coach"):
> "Hi, I'm Baseline. Before I start making recommendations, tell me what you're trying to accomplish."

With tappable example prompts ("I'm training for HYROX", "I want to get stronger", "I've never really worked out"), and **type or dictate**. The engine **adapts**:
- **Power user** ("HYROX Dallas sub-60, six days/week, full gym, hamstring flares if I run too much") → extracts goal, event, frequency, equipment, constraint at once; **does not re-ask** them; moves to the next useful question ("structured program or day-by-day?").
- **Beginner** ("honestly I just want to get healthier") → continues naturally ("what kind of movement do you enjoy?" → "gym access?").

Stops on **confidence, not question count** — when another question wouldn't change the first plan, it stops. Everything said becomes **structured state** (training state, equipment, constraints, style).

*Recommendation style* (conservative / balanced / aggressive) is captured here — by asking, or inferred and confirmed.

### 3. Connect Apple Health **[E]** — value before permission
Explain first, then prompt: *"Connect Apple Health so Baseline can read your sleep, heart rate, workouts, and training history automatically — so you type less."* Then the system permission sheet.
- **Granted** → Evidence Engine begins reading (sleep, RHR, workouts, HR samples, steps).
- **Denied / skipped** → fine. Baseline continues on conversation + optional HRV scan, and **says** certainty will be lower until more evidence exists (Principle 7). Re-offer later, never block.

### 4. HRV scan (optional) **[E]**
*"For higher-certainty recommendations, add a 60-second morning HRV scan."* Choose **Use HRV scan** or **Skip for now**. If chosen: the guided quiet read (strap or camera). Skipping is a valid path — certainty simply reflects the missing signal.

### 5. Setup summary
Reflect back the structured state so the user sees what Baseline understood: goal, phase, access/equipment, constraints, data connected, scan preference. CTA: **Generate today's plan.**

### 6. First plan (the payoff) **[D] → [P]**
Decision Engine computes domains → caps/constraints → readiness + limiter + **certainty**; Planning Engine turns it into today's plan. The screen leads with the **plan**, then its support:
```
Today
40–60 min Zone 2 + upper-body strength         ← the hero (plan)
Certainty: Medium                                ← honest about evidence so far
Why: HRV suppressed · yesterday's load high · sleep good · quads sore
Avoid: running intervals · sled push · heavy lunges
```
**Low-evidence first day** → the plan is more conservative and the copy is explicit: *"I don't have much history yet, so this is a cautious starting point — it'll sharpen as I learn your patterns."* (Principle 7.)

---

## Part 2 — The daily loop

```
Open app → sync Health [E] → optional HRV scan [E] → engine computes [D] →
Context Engine asks only what would change the answer [C] → today's plan [P]
```
- Morning open **syncs evidence** and recomputes. If everything needed is already known, **zero questions** — the plan is just there.
- The Context Engine asks a question **only if it would move the plan** ("Any pain or niggles today?" when a constraint is active; "rough night — how many hours did you sleep?" when Health has no sleep).

### Home
Leads with **today's plan**, then: readiness, certainty, primary limiter/constraint, why, avoid. The conversation is available to add context or ask questions (placement is UI, not architecture).

### Detail / breakdown
Tapping through shows the **domain breakdown** (autonomic, sleep, musculoskeletal, subjective, training load) and the constraints — the full evidence behind the plan.

### From plan to execution
The plan is not the end — it leads into training. Even before real workout tracking exists, the UX must acknowledge the arc, or the product feels like it stops before the user actually trains:
```
Today's Plan → Start Workout → Workout Complete → Reflection ("how did it feel?") → Learning
```
The **Reflection** is what feeds the Learning Engine (and closes the Proposed → Accepted → workout → feedback loop). We don't build tracking now, but the plan screen points forward to it rather than dead-ending on a card.

### Continuity — you're not starting over
Baseline doesn't reset each morning; it **continues the conversation.** It references recent context so mornings feel alive, not blank:
> "Good morning. Yesterday you only had time for a short workout — back to your normal schedule today?"

The user picks up where they left off instead of re-establishing everything daily. Opening should feel less like *"receive today's plan"* and more like *"continue the conversation."*

### Returning after time away
When the user has been gone, Baseline re-orients gently rather than pretending nothing happened — and never guilt-trips:
> "Welcome back — I haven't seen a morning reading in four days. Want today's plan based on what I know, or update me first?"

> "Looks like you've been away a week. Anything major change? · Injury · Travel · New goal · Nothing"

It offers a plan from known state (honest about the lower certainty) plus an easy way to refresh context. Never a hard reset.

---

## Part 3 — Context update → updated plan (negotiation)

Context arrives any time, in natural language, and the plan **recomputes**. The plan is **proposed, then negotiated, then accepted** (Principle: the Planning Engine proposes, it doesn't dictate).

```
User: "I only have 30 minutes and no gym."
  [C] extract → daily context { time: 30, equipment: none } → recompute
  [P] Proposed Plan updates → "30-min Zone 2 run or bodyweight circuit."

User: "I really want to run."
  [P] negotiates against constraints:
  "Given your Achilles, I'd keep it easy — 20–30 min flat, skip strides. Want that instead?"
User: "Okay."  → Accepted Plan stored (differs from the first proposal — that difference is signal).
```
Other everyday updates that recompute: *"quads feel fine today"*, *"I'm traveling"*, *"signed up for a marathon"*, *"my Achilles hurts"* (→ creates/updates a **constraint** that persists until resolved, and future days ask *"how's the Achilles today?"* rather than re-asking generically).

---

## Part 4 — Living with Baseline (Day 30)

The product changes once it has learned the athlete. Early on, recommendations lean on **general physiology**; over days and weeks they become increasingly **personalized** to how this specific athlete responds (via the Learning Engine):
- "You consistently recover well after Zone 2 days."
- "Threshold sessions suppress your HRV for roughly 48 hours."
- "Your legs recover faster than your autonomic system."
- "You tend to perform poorly after travel days."

The experience evolves from a generic coach into one that understands the individual — plans reference the athlete's own patterns, and explanations cite them ("I'm keeping today easy because threshold work tends to suppress your HRV for about two days"). This is the long-term differentiation; the UX should have room for it to surface without a redesign.

---

## Key states to design (beyond the happy path)
- **No data yet / first day** — cautious plan + explicit low certainty.
- **Low certainty** — evidence thin (scan skipped, Health denied); plan still given, uncertainty surfaced.
- **Permission denied** — graceful, re-offer later, never block the plan.
- **HRV scan failed / poor signal** — offer retry; proceed with reduced certainty rather than forcing a redo.
- **Constraint active** — plan and avoid list reflect it even on a green day; targeted daily follow-up.
- **Syncing / computing** — brief, honest progress ("syncing Health", "finding your limiter"), not fake drama.
- **Plan proposed vs accepted** — the negotiation is visible; the accepted plan is what's stored.

## Open questions (for the UI/UX implementation doc)
- Where the conversation lives (home inline, bottom sheet, dedicated tab, voice).
- How much of the domain breakdown to show by default vs on tap.
- Onboarding length ceiling and how aggressively to infer vs ask.
- How Accepted-Plan feedback ("how did it feel?") is captured for the Learning Engine.
