# Feature Contract: Sleep Engine Slice 3 — pure scoring & comparison (headless)

- Issue: #6
- Base branch: `feature/issue-2-workout-image-import`
- Change type: feature
- Owner: orchestrator

Base note: branched from the Slice 2 merge point (`363a279`). `main` remains stale (recorded in #4).

## User outcome

No visible change yet. Every canonical sleep night gains a derived, versioned `SleepAnalysis`: the
Apple-aligned 0–100 score with its duration/consistency/interruptions breakdown, stage evidence
outside the score, evidence quality, acute-vs-chronic comparison with sleep debt, consistency
statistics, notable-night flags, descriptive insights, and the structured decision evidence Slice 4
will feed into `DecisionEngine`. Analyses persist on the Slice 2 store and lazily re-derive when the
algorithm version bumps.

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
      `observedPoints/possiblePoints` and `score == nil` — never a scaled-up 0–100. Manual nights
      are duration-only (`possiblePoints == 50`); consistency is unavailable below 5 recorded
      nights; stage-dependent interruption evidence missing → interruptions component unavailable
      rather than imputed.
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

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Full staged night + history → complete analysis, score present | AC-1/AC-3/AC-5 tests |
| Loading | Provisional night → analysis computed, quality status `provisional` | AC-4 tests |
| Empty | No history → consistency unavailable, flags suppressed, score nil until observable | AC-2/AC-6 tests |
| Error/offline | Partial/manual nights → observed-points path, decision evidence nil-safe | AC-2/AC-9 tests |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `SleepEngineTests` component cases (need taper, consistency penalty curve, WASO/awakening penalties, sum) | Each component pinned against hand-computed fixture values |
| AC-2 | `SleepEngineTests` observed-points cases (manual, cold-start, missing stages) | Asserts `score == nil` + exact observed/possible points, no scaling |
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
