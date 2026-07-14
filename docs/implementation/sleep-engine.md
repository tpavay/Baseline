# Sleep Engine — Implementation Plan

Sleep graduates from "one scalar into the readiness blend" to a first-class **evidence engine**:
score + breakdown, trends/baseline, debt, consistency, confidence, and notable-night flags — all in
service of the training decision, never as a standalone tracker. The full vision (2026-07-14
discussion, 15 points + Personal Recovery Model) is **sequenced, not dropped**: points that need
months of outcome data land in the Learning Engine section (§11) with their data capture designed in
now. Grounded in these architecture decisions:

1. **The Sleep Engine is an evidence source, not a second decision-maker.** It computes *sleep truth*
   (what happened, how it compares to this athlete's norm, how sure we are) and hands it to the
   existing `DecisionEngine` sleep domain — as **structured evidence** (score + deficit + interruption
   burden + schedule shift), so the decision engine sees the actual limiter instead of reverse-inferring
   it from one number. It never prescribes training directly — the recovery recommendation pipeline
   (`DecisionEngine` caps/limiters → `PlanningEngine` effort ceiling) already exists and stays the
   single decision path.
2. **Apple-aligned score; stages are evidence, not score.** The 0–100 score uses Apple's documented
   structure — **duration 50 / bedtime consistency 30 / interruptions 20** — so users comparing
   against Apple's number see no unexplained divergence. Deep/REM/core intervals are collected,
   persisted, and displayed as *additional sleep evidence*, but do **not** move the v1 score.
3. **Pure engine, house persistence pattern.** `SleepEngine` is a pure enum like `DecisionEngine`
   (unit-testable, no SwiftData/SwiftUI imports). Nightly facts are pure value types persisted
   through a `SleepRepository` protocol with a SwiftData adapter, CloudKit-safe (optionals/defaults,
   no `.unique`, UUID FKs).
4. **Facts are immutable per source revision; the canonical night is replaceable.** HealthKit writes
   and revises samples after first import, so every night carries a
   `provisional → complete → revised` lifecycle, a source fingerprint, and sync metadata. Derived
   metrics are recomputable and carry **three independent versions** (facts schema / aggregation /
   score algorithm). The morning *decision snapshot* is frozen separately from the *current
   reconstruction* so late Health updates can never make history imply a decision the app didn't make.
5. **Honest evidence quality, propagated.** Coverage (how much required data exists) is separated
   from reliability (how trustworthy the source is) and from lifecycle status; the combined quality
   flows into `DecisionEngine.Certainty`. Missing components are **never renormalized into a
   confident-looking 0–100** — extending the existing "communicate uncertainty rather than
   manufacture confidence" invariant.
6. **No third-party chart dependency.** The timeline chart is built in SwiftUI in-house
   (SleepChartKit is inspiration only, per the no-third-party rule); `HealthService` is extended to
   return the stage *intervals* it currently discards.

---

## 0. Revision log

**2026-07-14 round 2** — scoring model corrected and ingestion semantics hardened before
implementation (review corrections, all applied):
- **Score components corrected:** Apple's documented structure is **duration 50 / bedtime
  consistency 30 / interruptions 20** — *not* duration/architecture/continuity. Stage proportions
  (deep/REM) do not enter the v1 score; they are displayed as "additional sleep evidence." Prevents
  unexplained divergence from Apple's number. (§3, §4, §9)
- **No renormalization of missing components:** partial nights report *observed points / possible
  points* + coverage; a 0–100 score is published to the decision only when required evidence exists.
  Manual nights keep the existing subjective fallback rather than masquerading as measured scores.
  (§3, §4, §8)
- **`SleepEvidenceQuality` replaces scalar confidence:** coverage ≠ reliability ≠ lifecycle status —
  a complete manual entry is high-coverage but low-reliability. (§3, §8)
- **Provisional-night lifecycle added** (`provisional / complete / revised`): "facts immutable once
  recorded" was wrong — HealthKit revises samples after import. Facts are immutable *per source
  revision*; the canonical night is replaceable, and readiness recomputes when it changes. (§3, §5, §7)
- **Sync model split:** one persisted **HealthKit anchored-query cursor** per sample-type query (the
  delta stream) + a deterministic **per-night source fingerprint** (did this canonical night change?).
  The prior per-night stringified anchor was wrong. (§5)
- **Multi-source precedence designed** (new §6): deterministic source resolution (preferred source →
  Watch staged → other complete staged → generic asleep → manual); never merge stage intervals across
  unrelated devices; provenance persisted per interval.
- **`SleepEpisode` / `SleepNight` split:** episodes are contiguous sleep sessions; a night is one or
  more episodes assigned to a recovery day. Noon-to-noon stays the v1 default *assignment boundary*,
  but naps/split sleep are retained without silently inflating primary sleep. (§3)
- **Structured evidence to the decision engine:** `sleepDurationDeficit`, `sleepInterruptionBurden`,
  `sleepScheduleShift` added alongside score/hours/quality — a 75 from short-but-consistent sleep and
  a 75 from adequate-but-erratic sleep must not read identically. (§8)
- **"Contributed +N points" dropped:** weighted terms aren't causal contributions once caps interact.
  Replaced with *weighted influence* ("12 of 15 possible points") + separate cap attribution ("today's
  readiness was capped by short sleep"). (§8, §9)
- **Versioning split three ways:** `factsSchemaVersion` / `aggregationVersion` /
  `scoreAlgorithmVersion` — a scoring change ≠ a change in how samples are deduplicated/grouped. (§7)
- **Decision snapshot vs current reconstruction:** `ReadinessEntry` freezes the exact sleep analysis
  used at decision time; the repository separately holds the latest reconstruction. (§7, §8)
- **Q-A resolved — separate:** HRV baseline-window fix decoupled; dedicated issue filed now (the
  all-prior-mornings baseline grows increasingly inert). **Q-B resolved — push from the Today sleep
  row**, whole row tappable, no new tab / mega-card. **Q-C resolved — no REM→training-effect claims
  in v1:** descriptive/calculable insights only; training interpretation stays with the decision
  engine. Stage-specific performance claims wait for the Learning Engine. **Q-D resolved — 90-night
  progressive backfill** (14 nights → today's result → continue to 90 → recompute comparisons). (§2,
  §4, §5, §10)
- **Slices reordered to five:** ingestion → persistence/aggregation → scoring → decision integration
  → UI/agent. (§13)

**2026-07-14 — initial plan.** Drafted from the sleep-vision discussion and a code audit
(`DecisionEngine`, `ReadinessScore`, `HealthService`, `TodayEvidence`, `DailyReadingFlowView`,
`ReadinessEntry`, Plan repository pattern). Key audit findings baked in: sleep is already a
`DecisionEngine` domain (0.15 warm weight + a <4.5 h hard cap + a `PlanningEngine` effort ceiling);
`HealthService.SleepSummary` already parses deep/REM/core hours but downstream drops them; nothing
about sleep is persisted except the subjective check-in answer on `ReadinessEntry`; no derived metric
anywhere carries an algorithm version.

---

## 1. Existing repository assessment

| Area | Today | Gap |
| --- | --- | --- |
| Sleep → score | `ReadinessScore.sleepScore(hours:efficiency:)` (`ReadinessScore.swift:197`): 0.7·duration + 0.3·efficiency, plateau 7–9 h | No goal-relative duration, no bedtime-consistency component, no interruptions component, fixed 7–9 h band for everyone |
| Sleep in the decision | `DecisionEngine.Domain.sleep` warm weight .15 / cold .10; hard cap 55 if `sleepHours < 4.5` (`DecisionEngine.swift:246`); `PlanningEngine` caps effort at 3 when sleep is the limiter (`PlanningEngine.swift:70`) | Recommendation pipe exists — it's fed one crude number. Needs structured evidence (deficit / interruption burden / schedule shift) |
| Breakdown / "why" | `DecisionEngine.Result.domains: [DomainScore]` + `primaryLimiter`; `TodayView` renders domains | Domain-level only. No sleep-internal breakdown, no influence-vs-cap attribution copy |
| HealthKit sleep | `HealthService.sleepSummary(nightsAgo:)` (`HealthService.swift:78`): asleep hours, deep/REM/core hours, efficiency, noon-to-noon window | Discards sample timestamps → no bedtime/wake, no awakenings, no gaps, no timeline data, no per-interval source attribution, no anchored delta sync, no multi-source resolution |
| Persistence | `ReadinessEntry` stores only `sleepQuality` (subjective). Sleep recomputed fresh each morning | No canonical night record → no trends, debt, baselines, flags, revision lifecycle, or reproducibility |
| History / baselines | HRV baseline = all prior same-source mornings, threshold 4 (code) vs "7-day rolling" (`docs/readiness-score.md:97`) | Out of scope here (dedicated issue filed — §2 Q-A). Sleep defines its own explicit windows |
| Manual fallback | `SleepCheckInCard` thumbs/stepper → `CheckInAnswers`; mapped to 85/35 in `MorningReadinessScoreView.compute()` (`DailyReadingFlowView.swift:425`) | Preserved as-is: manual nights are recorded but never presented as measured scores |
| Versioning precedent | Plan versioning only (`SDPlanVersion`); content versions on exercise media | No algorithm/schema version stamping anywhere — §7 introduces the three-way pattern |

## 2. Product decisions (all resolved 2026-07-14)

- **Score structure:** Apple-aligned **duration 50 / consistency 30 / interruptions 20**. Stage data
  is evidence, never score input, in v1.
- **Sleep need/goal:** user-set (default 8:00) in `ReadinessConfig`, editable in Profile. Inferred
  personal need is Learning Engine (§11).
- **Sleep debt:** narration + trend surface only; does not move the readiness number in v1.
- **Q-A (HRV baseline window):** separate — never change two evidence domains in one validation
  surface. Dedicated issue filed at plan time; sleep ships its own explicit 7 d/14 d/30 d windows.
- **Q-B (detail placement):** push `SleepDetailView` from the Today sleep domain row; the **whole row
  is tappable**, not a chevron target. No new tab, no expandable mega-card — Today stays the decision
  surface; the detail screen explains the evidence behind it.
- **Q-C (insight copy):** **descriptive/calculable only** in v1 — e.g. "You slept 54 minutes less
  than your 30-day average," "Bedtime was 1 h 12 m later than usual," "Awake 38 minutes during the
  night," "Data contains a 46-minute tracking gap," "Shortest night in 21 days." No stage→performance
  claims (consumer stage estimates are noisy; single-night proportions doubly so). Training
  interpretation comes only from the decision engine ("Shorter and more interrupted sleep reduced
  today's readiness").
- **Q-D (backfill):** **90 nights, progressive**: import last 14 → compute today's result → continue
  to 90 in the background → recompute historical comparisons/flags on completion. The user never
  waits on the full import to see readiness.
- **Naps:** retained as episodes, excluded from the primary-night score, visible as evidence.

## 3. Data model (pure value types, `Baseline/Features/Sleep/`)

```
SleepEpisode                          // one contiguous sleep session
├── id: UUID
├── start / end: Date
├── intervals: [SleepStageInterval]   // {stage: core|deep|rem|awake|unspecified, start, end, source}
│                                     //   ↑ provenance per interval, not per night
├── isPrimary: Bool                   // primary overnight sleep vs nap/split segment
└── gaps: [DateInterval]              // untracked spans inside the episode window

SleepNight                            // canonical facts for one recovery day (replaceable, see §5)
├── id: UUID, date: Date              // assignment: noon-to-noon default boundary (v1)
├── episodes: [SleepEpisode]          // primary + naps; score uses primary sleep only
├── bedtime / wakeTime: Date?         // from the primary episode
├── asleepHours, inBedHours: Double?
├── awakenings: Int?, wasoMinutes: Double?
├── resolvedSource: SleepSource       // winner of §6 precedence: healthKit(bundleID) | manual | none
├── analysisStatus: provisional | complete | revised
├── sourceFingerprint: String         // deterministic hash of normalized samples (§5)
├── lastHealthKitSyncAt: Date?, lastSampleEndDate: Date?
├── revision: Int                     // bumps each canonical replacement
└── factsSchemaVersion: Int

SleepAnalysis (derived — recomputable, versioned)
├── observedPoints / possiblePoints: Int          // e.g. 45/50 when only duration is observable
├── score: Int?                                   // 0–100 ONLY when all required components observed
├── components: [SleepComponent]                  // duration 0–50 · bedtimeConsistency 0–30 · interruptions 0–20
├── additionalEvidence: SleepStageEvidence        // REM/deep/core durations + distribution, timing,
│                                                 //   tracking gaps — displayed, never scored (v1)
├── quality: SleepEvidenceQuality                 // coverage 0–1, reliability 0–1, status, [Reason]
├── vsBaseline: SleepComparison                   // acute 7 d vs chronic 30 d means; sleep debt (Σ deficit vs need, 14 d)
├── consistency: SleepConsistency                 // bedtime/wake mean + variance over 14 d
├── flags: [SleepFlag]                            // bestIn(days:) / worstIn(days:) / scheduleShift / shortNight
├── aggregationVersion: Int, scoreAlgorithmVersion: Int
└── decisionEvidence: SleepDecisionEvidence       // durationDeficit, interruptionBurden, scheduleShift (→ §8)
```

Component rules (tunables in one place, like `ReadinessScore`'s):
- **Duration (0–50):** primary asleep hours vs sleep need; full points at ≥ need, tapering below.
- **Bedtime consistency (0–30):** |bedtime − 14-day rolling bedtime mean|; **unavailable during cold
  start** (< 5 recorded nights) — reported as reduced `possiblePoints` + coverage, never renormalized.
- **Interruptions (0–20):** WASO minutes + awakening count penalties.
- A HealthKit night with sufficient history normally observes all three; manual nights observe
  duration only and keep the subjective fallback path (§8) instead of a pseudo-measured score.

## 4. Engine design

`SleepEngine` — pure `enum`, `Baseline/Shared/Services/SleepEngine.swift`:

- `analyze(night: SleepNight, history: [SleepNight], need: Duration) -> SleepAnalysis` — single pure
  entry point; history supplies consistency baseline, comparisons, debt, flags.
- `static let aggregationVersion / scoreAlgorithmVersion: Int` — stamped on every `SleepAnalysis`
  (facts schema version lives on `SleepNight`; see §7 for why they're independent).
- Flags are relative comparisons from history ("worst sleep in 46 days"), capped at available history
  and suppressed below ~14 nights (cold-start honesty, mirroring `calibrating`).
- `SleepInsights.rules(for:)` — pure function returning **descriptive-only** bounded copy (§2 Q-C
  list is the v1 rule set); every line is directly recomputable from the analysis. No effect claims.

## 5. Ingestion, sync & the provisional-night lifecycle

- **Anchored delta sync:** one persisted `HKQueryAnchor` **cursor per sample-type/source query** —
  the synchronization stream. It is *not* stored per night.
- **Night fingerprint:** after §6 source resolution, the canonical night's normalized samples
  (source, start, end, value) hash into `sourceFingerprint`. Delta arrives → re-resolve affected
  nights → fingerprint changed ⇒ replace the canonical night (`revision += 1`,
  `analysisStatus = .revised`), re-derive `SleepAnalysis`, and **recompute readiness** (§8 snapshot
  semantics keep history honest).
- **Lifecycle:** a night ingested while data may still arrive (e.g., early morning, watch not yet
  synced) is `provisional`; it becomes `complete` when the source's samples stabilize past wake +
  sync; any later change marks it `revised`. Facts are immutable *per source revision* — replacement,
  not mutation.
- **Progressive 90-night backfill (Q-D):** import trailing 14 nights → compute today's analysis and
  let the morning flow proceed → continue batches to 90 in the background → on completion recompute
  comparisons/flags that depend on the full window. Idempotent via fingerprints.

## 6. Multi-source precedence

HealthKit can hold overlapping sleep from Apple Watch, iPhone, Oura, Eight Sleep, AutoSleep, and
manual entry. Overlapping samples are **resolved, never blended**:

1. User-selected preferred source (Profile setting; default none).
2. Apple Watch staged data.
3. Another single source with complete staged data.
4. Generic `asleepUnspecified` samples (best contiguous source).
5. Manual fallback (`SleepCheckInCard`).

Rules: resolution is deterministic (same inputs → same canonical night); **stage intervals from
unrelated devices are never merged**; the losing sources are dropped from the canonical night but
remain reachable in raw storage for debugging; provenance is persisted **per interval** (§3), and the
night records the `resolvedSource`. Reliability in `SleepEvidenceQuality` derives from the resolved
source class (staged wearable > generic phone inference > manual).

## 7. Persistence, versioning & snapshots

- **`SDSleepNight`** `@Model` (`Baseline/Shared/Persistence/SleepEntities.swift`): canonical facts
  (episodes/intervals as a Codable blob — same blob tradeoff as `Workout` logs) + latest derived
  analysis + lifecycle/sync fields (`analysisStatus`, `revision`, `sourceFingerprint`,
  `lastHealthKitSyncAt`, `lastSampleEndDate`) — all optional-with-defaults (the SwiftData new-field
  crash rule). A small `SDSleepSyncState` row holds the per-query anchors.
- **`protocol SleepRepository`** (`@MainActor`) + `SwiftDataSleepRepository`: `replaceCanonical(night:)`
  (fingerprint-gated), `nights(in:)`, `latest(limit:)`. Single write path; engines never see SwiftData.
- **Three independent versions:** `factsSchemaVersion` (how samples normalize into episodes/nights),
  `aggregationVersion` (how nights aggregate into comparisons/windows), `scoreAlgorithmVersion` (the
  scoring math). Any bump re-derives lazily as nights are read — history gets the new algorithm and
  score changes are explainable, but see next point.
- **Decision snapshot vs current reconstruction:** `ReadinessEntry` gains an immutable
  `sleepDecisionSnapshot` (Codable blob: the exact `SleepAnalysis` + versions used when the morning
  readiness was shown). The repository's night rows always hold the *current* reconstruction (latest
  facts, latest algorithms). History UIs read the snapshot; trend/comparison UIs read the current
  reconstruction; a same-day revision recomputes and updates Today **with attribution** ("updated
  after Health sync") while the original snapshot stays frozen. A late Health edit or version bump
  can therefore never imply the app decided differently that morning than it did.

## 8. Decision-engine integration (the whole point)

- `TodayEvidence.baseInputs` and `MorningReadinessScoreView.compute()` switch from
  `ReadinessScore.sleepScore(hours:efficiency:)` to the repository's current `SleepAnalysis`. The old
  two-factor formula is deleted.
- **Structured evidence, not just a scalar.** `DecisionEngine.Inputs` gains:
  `sleepConfidence: Double?` (from `SleepEvidenceQuality`), `sleepDurationDeficit: Double?` (hours
  short of need), `sleepInterruptionBurden: Double?` (normalized WASO), `sleepScheduleShift: Double?`
  (minutes vs rolling bedtime). All optional/defaulted — existing call sites and tests untouched.
  The `poorSleep` hard cap re-expresses on `sleepDurationDeficit`; limiter narration can now say
  *which* aspect of sleep limited today. `sleepScore`/`sleepHours` keep their contract.
- **Score publication rule (no renormalization):** the engine feeds `Inputs.sleepScore` only when
  `SleepAnalysis.score` is non-nil (all required components observed). Otherwise `sleepScore = nil` —
  never imputed — and the existing manual/subjective fallback (thumbs → 85/35) applies exactly as
  today. Certainty counts sleep only when quality clears the bar (coverage ≥ 0.7 ∧ reliability ≥ 0.5).
- **Influence, not "contribution":** weighted terms aren't causal once caps interact. Copy is
  *"Sleep domain: 82 — weighted influence 12 of 15 possible points"*, and separately, when a sleep
  cap bound the result: *"Today's readiness was capped by short sleep."* Display-layer only, computed
  from `DomainScore` and `appliedCaps` which already exist.
- **Revision recompute:** when §5 replaces a canonical night for *today*, `PlanAssembler` re-runs and
  Today refreshes with attribution; `ReadinessEntry`'s decision snapshot stays frozen (§7).
- Docs: update `docs/readiness-score.md` sleep section + `docs/architecture.md` Evidence Engine list
  in the same PR as Slice 4.

## 9. UI & screens

- **`SleepDetailView`** (pushed from Today's sleep domain row; whole row tappable): score (or
  observed-points + coverage when partial) + quality/status badge → stage timeline chart → duration /
  awake / gap stats → **Apple-aligned component breakdown** (Duration 42/50 · Consistency 26/30 ·
  Interruptions 14/20) → **additional sleep evidence** section (REM/deep/core durations,
  distribution, timing — visually distinct from the score) → vs-you comparisons (acute/chronic, debt,
  flags) → descriptive insight lines → provenance & sync state (resolved source, last sync,
  provisional/revised marker) → influence/cap attribution footer tying it to today's decision.
- **`SleepTimelineChart`** — in-house SwiftUI: horizontal time axis, stage bands, gap hatching, nap
  episodes rendered separately. Pure view over `[SleepStageInterval]`; interval → bar math in a
  testable layout helper, nothing in `body` beyond layout.
- **`SleepCheckInCard`** upgrade: with Health data, show score + duration + quality hint (and a
  provisional marker when the watch hasn't synced); manual path unchanged.
- Trends (7/30-day strips, consistency, debt sparkline) live inside `SleepDetailView` — no new tab,
  honoring the not-a-generic-tracker exclusion.

## 10. Agent surface

One new read-only tool: `get_sleep_evidence` (current `SleepAnalysis` + comparison summary + quality)
in `AgentTools`/`ToolCallMapper`, so the conversational coach narrates sleep with the same numbers
the engine used. No sleep *mutation* tools — facts come from Health or the existing check-in.
(Firestore untouched — sleep stays on-device in v1, so no `firestore.rules` change.)

## 11. Learning Engine deferrals (data captured now, intelligence later)

Deliberately **not** built now — each needs months of paired sleep-plus-outcome data, and all become
possible because canonical facts persist from Slice 1 and workouts/RPE already persist via the Plan
repository:

- **Personal sleep need** (point 5) — estimate true need from chronic data; replaces the user-set goal.
- **Outcome learning** (point 12) — sleep → session RPE/performance regressions.
- **Cross-signal correlations** (point 13) — sleep↔HRV, sleep↔pace, consistency-vs-duration findings.
- **Schedule-disruption classification** (point 6, beyond the v1 `scheduleShift` flag) — jet lag /
  shift-work / travel detection.
- **Stage-specific effect claims** (point 10's original form) — REM/deep → perceived-effort or
  performance statements require user-specific outcome evidence; until then they stay out of the app.
- **Personal Recovery Model** (the flagship) — "your best interval sessions follow ≥ 7 h 35 m, bedtime
  before 10:45, HRV above baseline." Composes the learners above.

## 12. Testing strategy

All engine logic reachable without a view tree (house rule):

- `SleepEngineTests` — per-component scoring (duration/consistency/interruptions); goal taper;
  consistency unavailable in cold start → observed-points path, `score == nil`, no renormalization;
  manual night duration-only; debt/acute-chronic windows incl. DST and gap nights; flag suppression
  under 14 nights; quality coverage-vs-reliability separation; version stamping.
- `SleepIngestionTests` — episode segmentation (incl. split sleep + naps, `isPrimary`), noon-to-noon
  assignment, awakening/WASO extraction, gap detection, **source-precedence resolution** (overlapping
  Watch/phone/third-party fixtures; never-merge rule), fingerprint determinism, provisional →
  complete → revised transitions, anchored-cursor delta handling, progressive-backfill idempotence.
- `SleepRepositoryTests` — fingerprint-gated canonical replacement, revision bump, version-bump
  lazy re-derivation, migration defaults, sync-state persistence.
- `DecisionEngineTests` additions — structured fields (deficit/burden/shift) default-neutral;
  `poorSleep` cap on deficit basis (regression vs existing cases); quality gating of certainty;
  `sleepScore == nil` → fallback parity with today's behavior.
- `TodayEvidenceTests` — Health-vs-manual precedence, conversation override still wins, same-day
  revision triggers recompute while the decision snapshot stays frozen.
- Chart layout helper tests — interval → bar geometry, gaps, midnight crossing, nap rendering.

## 13. Ordered build slices

Issue-first: file a GitHub issue per slice (or one epic + slice checklist), branches
`feature/issue-<n>-sleep-engine-<slice>` off `develop`.

1. **Canonical sleep ingestion (headless).** `SleepEpisode`/`SleepNight` value types,
   `HealthService` interval extraction, episode segmentation, §6 source precedence, anchored-cursor
   sync, provisional/complete/revised lifecycle, fingerprints, 90-night progressive backfill.
2. **Persistence & aggregation (headless).** `SleepRepository` + `SDSleepNight` + `SDSleepSyncState`,
   canonical replacement, three-way versioning, window aggregation (7/14/30 d), lazy re-derivation.
3. **Pure scoring & comparison (headless).** `SleepEngine.analyze`: duration 50 / consistency 30 /
   interruptions 20, additional stage evidence outside the score, `SleepEvidenceQuality`,
   observed-points rule, debt, flags, descriptive insights.
4. **Decision integration.** Structured inputs (deficit/burden/shift/quality), certainty gating,
   score-publication rule, deficit-based `poorSleep` cap, morning decision snapshot on
   `ReadinessEntry`, same-day revision recompute, old formula deleted, docs updated. Behavior changes
   only here — reviewable as one focused diff against parity tests.
5. **UI & agent surface.** `SleepDetailView` + timeline chart + provenance/sync state + upgraded
   `SleepCheckInCard` + influence/cap copy + `get_sleep_evidence`.

## 14. Vision-point → plan traceability

| Vision point | Where |
| --- | --- |
| 1 Sleep Engine, not a score | §3–§7 (episodes/nights, engine, lifecycle, versions) |
| 2 Show why / contribution | §3 components, §8 influence + cap attribution, §9 detail view |
| 3 Acute vs chronic trends | §3 `vsBaseline`, §9 |
| 4 Sleep debt | §3 (14-day debt), narration-only per §2 |
| 5 Personal sleep need | §11 (deferred; user-set goal in v1) |
| 6 Schedule disruptions | v1 `scheduleShift` flag (§3); classification deferred (§11) |
| 7 Consistency | §3 — and a scored component (30 pts), per Apple's structure |
| 8 Confidence | §3 `SleepEvidenceQuality` (coverage ≠ reliability ≠ status), §8 certainty gating |
| 9 Unusual nights | §3 `flags` (best/worst-in-N) |
| 10 Effect explanations | §4 descriptive-only insights (Q-C); stage-effect claims → §11 |
| 11 Recovery recommendations | Already built (caps + effort ceiling); fed structured evidence via §8 |
| 12 Learn from outcomes | §11 |
| 13 Correlations | §11 |
| 14 Timeline UI | §9 (in-house SwiftUI) |
| 15 Version everything | §7 (three-way versioning + snapshot-vs-reconstruction) |
| Personal Recovery Model | §11 (enabled by Slice 1–2 durable facts) |

## Status

Planned 2026-07-14, revised same day (round 2: Apple-aligned components, ingestion lifecycle,
multi-source precedence, snapshot semantics). Ready for implementation; HRV-baseline issue filed
separately per Q-A.
