# Baseline — UX Flow

*How the product feels end to end, at the flow level (not pixels). It maps the first-run journey and the daily loop onto the engines in `docs/architecture.md`, and honors `docs/product-principles.md` — conversation-first, plan-as-hero, explainable, honest about uncertainty. Screen-level specs live in the UI/UX implementation doc.*

Legend: **[E]** Evidence · **[C]** Context · **[D]** Decision · **[P]** Planning engine touchpoints.

---

## Part 1 — First launch → first plan

The goal of first run: **reach a first, honest plan with the least effort** — and be upfront when evidence is still thin.

### 1. Welcome
One line on the promise: *"Baseline tells you what to train today — from your body, your training, and your goals."* Single CTA: **Set up Baseline**. No feature tour.

### 2. Meet your coach (conversational onboarding) **[C]**
Not a form — the Context Engine's first session. Opens like a coach:
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
