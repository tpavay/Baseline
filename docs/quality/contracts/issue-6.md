# Feature Contract: Sleep Engine Slice 3 — pure scoring & comparison (headless)

- Issue: #6
- Base branch: `feature/issue-2-workout-image-import`
- Change type: feature
- Owner: orchestrator

Base note: branched from the Slice 2 merge point (`363a279`). `main` remains stale (recorded in #4).

## User outcome

No visible change yet. Every canonical sleep night gains a derived, versioned `SleepAnalysis`: an
internal 0–100 score using **Apple-aligned component weighting** (duration 50 / bedtime consistency
30 / interruptions 20) with its breakdown, stage evidence outside the score, evidence quality,
acute-vs-chronic comparison with sleep debt, consistency statistics, notable-night flags, descriptive
insights, and the structured decision evidence Slice 4 will feed into `DecisionEngine`. Analyses
persist on the Slice 2 store and lazily re-derive when the algorithm version bumps.

**Product-language precision (binding):** the score borrows Apple's published *component weights*
(50/30/20), not Apple's formula. It is "Apple-aligned," never "Apple-equivalent." The
duration-taper curve (zeroing at 50 % of need) and the interruption split (WASO 12 / awakenings 8
with grace bands) are **Baseline internal heuristics** — Apple has not published those curves. All
are v1 tunables carried under `scoreAlgorithmVersion` so history can be recomputed if retuned.

## Non-goals

- No `DecisionEngine`/`TodayEvidence`/`PlanAssembler`/morning-flow changes; readiness behavior is
  byte-identical (Slice 4).
- No UI, no agent tools (Slice 5).
- No app-container registration (`BaselineApp.swift` untouched; store still unreachable by the app).
- No stage-proportion input to the score — deep/REM are evidence display data only (plan round-2
  correction; prevents divergence from Apple's documented structure).
- No stage→performance insight claims ("less REM → higher perceived effort" is Learning Engine
  material); insights are descriptive/calculable only.
- No personal sleep-need inference; need is a passed parameter (default 8 h), `ReadinessConfig`
  wiring lands in Slice 4.
- Existing tests untouched (Slices 1–2 tests are pre-existing; additive-only changes).

## Acceptance criteria

- [ ] AC-1: For a fully observed HealthKit night with ≥ 5 nights of history, `SleepEngine.analyze`
      produces components duration 0–50 (full points at ≥ need, tapering below), bedtime consistency
      0–30 (penalty grows with |bedtime − 14-day rolling mean|), interruptions 0–20 (WASO +
      awakening penalties), and `score == duration + consistency + interruptions` on a 0–100 scale.
- [ ] AC-2: No renormalization: when any required component is unobservable the analysis reports
      `observedPoints/possiblePoints` and `score == nil` — never a scaled-up 0–100. Consistency is
      unavailable below 5 recorded nights; stage-dependent interruption evidence missing →
      interruptions component unavailable rather than imputed. Cold-start consistency **lowers
      `possiblePoints`** (does not zero the whole score) and leaves `score == nil`.
- [ ] AC-2b (manual = never a measured score): a **manual-source** night never publishes a score
      and never enters a duration-scoring path. Its analysis is `score == nil`, `observedPoints == 0`,
      `possiblePoints == 0`, `quality.reliability` low. The manual duration is still persisted as
      evidence (visible in `additionalEvidence`/night facts), but there is exactly **one** manual
      path — the existing subjective thumbs → 85/35 fallback that `DecisionEngine` already owns
      (Slice 4). No duration points, no second manual-scoring route; this preserves the Slice 4
      readiness-parity guarantee.
- [ ] AC-3: Stage data never moves the score: two nights identical except for deep/REM distribution
      score identically, while `additionalEvidence` reflects the distribution difference.
- [ ] AC-4: `SleepEvidenceQuality` separates coverage (fraction of required evidence present),
      reliability (source class: staged wearable > generic > manual), and lifecycle status
      (provisional/complete/revised), each with reasons; a complete manual entry yields high
      coverage with low reliability.
- [ ] AC-5: `vsBaseline` reports acute (7 d) vs chronic (30 d) asleep-hour means over available
      history and a 14-day sleep debt (Σ max(0, need − slept)); gap nights are excluded from means
      but count toward debt via their absence only when a night exists with lower hours — missing
      nights contribute no fabricated deficit (never impute).
- [ ] AC-6: Flags are history-honest: bestIn/worstIn(days:) computed against available history,
      capped at its length, and all comparative flags suppressed below 14 recorded nights;
      scheduleShift fires on bedtime deviation beyond the tunable threshold; shortNight on duration
      below the tunable floor.
- [ ] AC-7: `SleepInsights.rules(for:)` emits only descriptive, recomputable copy (the five
      contract-exemplar shapes: vs-average duration delta, bedtime delta, awake time, tracking gap,
      shortest-in-N); every emitted line's quantities match the analysis fields; no stage→effect
      claims exist in the rule set.
- [ ] AC-8: Every analysis carries `aggregationVersion` + `scoreAlgorithmVersion`; the repository
      persists the analysis on the Slice 2 reserved fields; reading a night whose stored versions
      trail the current engine re-derives lazily, persists the new analysis, and leaves
      newer-or-equal versions untouched (zero-write).
- [ ] AC-9: `decisionEvidence` (durationDeficit hours, interruptionBurden, scheduleShift minutes) is
      populated for observed nights and nil-safe for partial ones — Slice 4 consumes it without
      recomputation.
- [ ] AC-10: No behavior change in the running app: full existing suite passes unmodified; new
      types referenced only within the sleep module, `SleepRepository`, and tests; `BaselineApp.swift`,
      engines, views untouched.

## Reviewer acceptance criteria (binding — the review must confirm each with a mapped test)

1. A **manual source can never publish `score`** (AC-2b): `score == nil`, `observedPoints == 0`,
   `possiblePoints == 0`, `reliability` low — even with ample history. No duration-points path.
2. **Stage intervals cannot alter any scored component** (AC-3): proven by a stage-invariance pair
   *and* an injection that makes a component read a stage proportion, which the AC-3 test must kill.
3. **Circular bedtime math** treats 11:50 PM and 12:10 AM as **20 minutes** apart, not ~24 hours
   (AC-1): explicit midnight-straddling fixture, hand-computed.
4. **Cold-start consistency lowers `possiblePoints` and leaves `score == nil`** (AC-2) — asserted at
   the 4-night (unavailable) vs 5-night (available) boundary.
5. **Persisted derivations regenerate when `scoreAlgorithmVersion` changes** (AC-8), observed by
   write counts; newer-or-equal versions are zero-write.
6. **Every score curve has hand-calculated boundary tests**, including exact threshold values
   (duration taper knots, consistency penalty knots, WASO/awakening grace-band edges) — not
   round-tripped against whatever the code emits.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Full staged night + history → complete analysis, score present | AC-1/AC-3/AC-5 tests |
| Loading | Provisional night → analysis computed, quality status `provisional` | AC-4 tests |
| Empty | No history → consistency unavailable, flags suppressed, score nil until observable | AC-2/AC-6 tests |
| Error/offline | Partial nights → observed-points path; manual nights → no score (subjective fallback), decision evidence nil-safe | AC-2/AC-2b/AC-9 tests |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `SleepEngineTests` component cases (need taper, consistency penalty curve, WASO/awakening penalties, sum) | Each component pinned against hand-computed fixture values |
| AC-2 | `SleepEngineTests` observed-points cases (cold-start 4-vs-5 nights, missing stages) | Asserts `score == nil` + exact observed/possible points, no scaling |
| AC-2b | `SleepEngineTests` manual-source case | Asserts `score == nil`, `observedPoints == 0`, `possiblePoints == 0`, low reliability — no duration path |
| AC-3 | `SleepEngineTests` stage-invariance pair | Identical scores, differing `additionalEvidence`, asserted directly |
| AC-4 | `SleepEngineTests` quality separation cases | Coverage/reliability/status asserted independently with reasons |
| AC-5 | `SleepEngineTests` window cases incl. DST-spanning and gap-night fixtures | Means/debt pinned to hand-computed values; no imputation asserted |
| AC-6 | `SleepEngineTests` flag cases (13 vs 14 nights, caps, thresholds) | Suppression boundary and cap observed directly |
| AC-7 | `SleepInsightsTests` rule-by-rule + quantity-match + negative claim-scan | Each line recomputed from analysis; no stage-effect strings in rules |
| AC-8 | `SleepAnalysisPersistenceTests` version-bump re-derivation + zero-write on current | Write counts + stored version/blob observed through the repository |
| AC-9 | `SleepEngineTests` decision-evidence cases (observed + partial) | Field-level assertions, nil-safety on partial nights |
| AC-10 | Full suite green; `git diff --stat` scope audit; reference grep | Proves isolation |

## UX evidence

Not applicable: headless scoring slice; the running app cannot reach the engine output (AC-10).

## Risk and rollout

- **Data migration:** none — populates Slice 2's reserved optional fields (optional-backing rule
  already satisfied); old rows without analyses re-derive lazily on read.
- **Backward compatibility:** pure additions; `SleepRepository` gains analysis read/write +
  re-derivation; no Slice 1/2 public API broken.
- **Privacy/security:** derived scores stay on-device beside the facts; no values logged.
- **Analytics/flags:** none.
- **Rollback:** revert branch; stored analysis blobs are ignored by older code (optional fields).
- **Deployment order:** behind Slice 4 (which wires need from `ReadinessConfig` and feeds
  `DecisionEngine`).

## Human gates

- None.
