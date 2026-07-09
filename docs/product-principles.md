# Baseline — Product Principles

The invariants that govern every product and engineering decision. When a design choice is unclear, resolve it against these — in order. They are derived from `docs/architecture.md`; this doc expands each with its rationale and what it rules in and out.

---

### 1. Structured state is the source of truth
Conversation is an **interface, not a datastore**. It matters — it's how humans talk to Baseline — but truth does not live in chat logs. The Context Engine extracts durable facts from conversation into structured state, and the Decision Engine reads *only* that structured state.
- **Rules in:** typed profiles/constraints/context; storing chat *summaries*.
- **Rules out:** replaying chat history to make decisions; logic that depends on "what the user said three messages ago."

### 2. The Decision Engine owns truth
Scores, domains, caps, constraints, and load are computed by deterministic, auditable code. AI never invents a score or overrides a cap.
- **Rules in:** pure, unit-tested scoring; AI calling validated tools that recompute.
- **Rules out:** an LLM emitting a readiness number; AI relaxing a safety cap because the user pushed back.

### 3. Conversation is the primary input mechanism
We don't have "forms plus a chat." We have a conversation the app extracts structure from. Design the input as talking first.
- **Rules in:** free text / dictation as the default way to give goals, context, pain, constraints.
- **Rules out:** long rigid onboarding forms as the primary path.

### 4. Natural before structured
Encourage natural communication; Baseline is responsible for extracting the structure. Reach for a structured control (picker, toggle, slider, quick reply) only when it is genuinely **faster, clearer, or less ambiguous** than talking.
- **Rules in:** a slider for a 1–5 soreness rating; a quick "yes/no" chip when that's fastest.
- **Rules out:** forcing everything into chat *or* everything into forms — use whichever fits the moment.

### 5. Today's plan is the hero
The output is a decision, not a dashboard. The plan leads; readiness, certainty, limiter, and evidence support it.
- **Rules in:** home screen that opens with the plan, then its justification.
- **Rules out:** a big readiness number as the headline with the recommendation buried below.

### 6. Recommendations are always explainable
Every plan is traceable to the evidence, context, and rules that produced it. Transparency is part of the product.
- **Say:** "Zone 2 because your 7-day load is elevated, HRV is suppressed, and your Achilles constraint is active."
- **Never:** an opaque "don't run today."

### 7. Communicate uncertainty; never manufacture confidence
When evidence is thin (first day, no HRV, no sleep, no workouts, no context), Baseline says so. Not-knowing is a first-class output.
- **Affects:** AI prompts, recommendation rules, UI, onboarding, confidence, error handling.
- **Rules out:** a confident-looking recommendation built on almost no evidence.

### 8. Certainty = evidence available today
Confidence reflects how much *useful evidence* exists right now — not merely that a permission was granted. More signals present → higher certainty.
- **Rules out:** "Apple Health connected, therefore high confidence."

### 9. Injuries are constraints, not just lower scores
A constraint shapes the plan directly and can gate it even on a high-readiness day (readiness 88 + Achilles pain → hard upper-body/bike, avoid running/jumping). Constraints override the score-derived choice and contribute the avoid list.
- **Rules out:** treating an injury purely as a number that drags the score down and disappears into the average.

### 10. Simple UI, complex backend
The user sees a plan, its limiter, its certainty, and a way to add context. All complexity — HealthKit, load models, caps, extraction — hides behind that.

### 11. Start hybrid-specific, design generic
The first experience is tuned for HYROX / hybrid athletes; the engines are goal-agnostic underneath so other athletes slot in later without a rewrite.

---

## The one-line test
If someone asks *"what does Baseline do?"*, the answer is **"it tells me exactly what to train today"** — a personal training operating system that happens to use HRV. Any feature that doesn't serve that promise is probably out of scope.
