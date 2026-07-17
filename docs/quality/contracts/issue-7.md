# Feature Contract: Sleep Engine Slice 4 — decision integration (headless until go-live)

- Issue: #7
- Base branch: `feature/issue-2-workout-image-import`
- Change type: feature
- Owner: orchestrator

Base note: branched from the Slice 3 merge point (`a31a41c`). `main` remains stale (recorded in #4).

## User outcome

No visible change **until a deliberate go-live**. The Sleep Engine is wired into `DecisionEngine`
through an injectable seam that is **off by default**: with the seam absent (the store is not
registered in `BaselineApp.swift`, which this slice does not touch), readiness is byte-identical to
today. With the seam present — the documented go-live the owner performs — the engine-derived sleep
score, confidence, and structured decision evidence feed the readiness decision, and the morning
snapshot records exactly what sleep contributed.

## Non-goals

- **`BaselineApp.swift` is not touched** — no `SleepSchema` container registration, no runtime
  `SleepBackfillOrchestrator` kickoff. Those, plus retiring the old two-factor formula, are the
  documented go-live steps the owner applies after clearing that file's unrelated WIP.
- No UI and no agent tool (Slice 5).
- No Firestore/rules changes.
- The existing `ReadinessScore.sleepScore(hours:efficiency:)` live path is **preserved unchanged** as
  the seam-off behavior; it is retired only at go-live, not here.
- Existing tests untouched (Slices 1–3 tests are pre-existing; additive-only).

## Acceptance criteria

- [ ] AC-1: `DecisionEngine.Inputs` gains `sleepConfidence`, `sleepDurationDeficit`,
      `sleepInterruptionBurden`, `sleepScheduleShift` — all optional with defaults such that
      omitting them yields **identical** `DecisionEngine.compute` output to the pre-slice engine
      (proven by the existing DecisionEngine suite passing unmodified + an explicit default-neutral
      test).
- [ ] AC-2: The `poorSleep` cap re-expresses on `sleepDurationDeficit` (deficit ≥ the tunable
      threshold applies the same cap the old `sleepHours < 4.5` rule did); with the new field nil,
      the legacy `sleepHours` cap path still applies — no double cap, no regression in the existing
      sleep-cap cases.
- [ ] AC-3: Certainty counts sleep only when quality clears the bar (coverage ≥ 0.7 ∧ reliability ≥
      0.5); below that, sleep does not increment certainty even if a score is present.
- [ ] AC-4: `SleepEvidenceProvider` (protocol) maps a `SleepRepository`'s current `SleepAnalysis` for
      today → the `DecisionEngine` sleep inputs, threading `need` from `ReadinessConfig` (default
      8 h). A manual/`.none` night (`score == nil`) maps to **no engine sleep score** →
      `DecisionEngine` uses the existing subjective 85/35 fallback (the single manual path;
      readiness-parity guarantee from AC-2b upheld).
- [ ] AC-5: **Seam-off parity (the headline guarantee):** when no `SleepEvidenceProvider` is injected,
      `TodayEvidence.baseInputs` and `MorningReadinessScoreView.compute()` produce **byte-identical**
      inputs and readiness results to the pre-slice code — proven by a parity test comparing against
      the legacy path on representative fixtures (with-Health, manual, no-sleep).
- [ ] AC-6: **Seam-on wiring:** when a provider is injected, `TodayEvidence`/`MorningReadinessScoreView`
      use engine-sourced sleep inputs; a conversation-reported sleep override (`PlanAssembler` path)
      still wins over the automatic base, exactly as today.
- [ ] AC-7: `ReadinessEntry` gains optional `sleepScore`, `sleepConfidence`, and an immutable
      `sleepDecisionSnapshot` (the exact `SleepAnalysis`/versions used), all optional-backing per the
      SwiftData new-field crash rule; written only when the seam is active, nil otherwise, and a row
      lacking them decodes with working defaults.
- [ ] AC-8: A go-live document (`docs/implementation/sleep-engine-go-live.md`) specifies the exact,
      ordered steps to activate: register `SleepSchema.models` in the container, inject the provider
      into `TodayEvidence`/the morning flow, start the backfill, retire
      `ReadinessScore.sleepScore(hours:efficiency:)`, and the parity/rollback notes.
- [ ] AC-9: No behavior change in the running app: full existing suite passes unmodified;
      `BaselineApp.swift` diff empty; the seam defaults to off everywhere the app constructs
      `TodayEvidence`/the morning flow (grep-verified); new types referenced only within the sleep
      module, the wired call sites, and tests.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path (seam off) | Readiness identical to today | AC-5 parity test |
| Happy path (seam on) | Engine sleep feeds decision; snapshot saved | AC-6/AC-7 tests |
| Manual night | No engine score → subjective 85/35 fallback | AC-4 test |
| Low quality | Sleep present but certainty not incremented | AC-3 test |
| Empty (no sleep) | Legacy no-sleep path unchanged | AC-5 parity test |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `DecisionEngineTests` additions (default-neutral) + existing suite green | Identical output with new fields nil |
| AC-2 | `DecisionEngineTests` deficit-cap + legacy-cap cases | Same cap from either path, no double cap |
| AC-3 | `DecisionEngineTests` certainty-gating cases | Sleep counted only above coverage/reliability bar |
| AC-4 | `SleepEvidenceProviderTests` mapping (staged/generic/manual) | Analysis→inputs incl. manual→nil→fallback, need from config |
| AC-5 | `TodayEvidenceTests`/`MorningReadinessParityTests` legacy-vs-seam-off | Byte-identical inputs/results without a provider |
| AC-6 | `TodayEvidenceTests` seam-on + conversation-override case | Engine path used; override still wins |
| AC-7 | `ReadinessEntryTests` snapshot round-trip + missing-field decode | Optional-backing defaults; snapshot persisted when active |
| AC-8 | Presence + review of `docs/implementation/sleep-engine-go-live.md` | Ordered activation steps documented |
| AC-9 | Full suite green; `BaselineApp.swift` diff empty; seam-default grep | Proves dormancy and isolation |

## UX evidence

Not applicable: no user-facing change in this slice (seam off); go-live (owner-performed) is where UI
parity/verification will apply, covered in the go-live doc and Slice 5.

## Risk and rollout

- **Data migration:** `ReadinessEntry` gains optional fields (optional-backing; AC-7) — old rows
  decode unchanged.
- **Backward compatibility:** `DecisionEngine.Inputs` additive/defaulted; legacy sleep path intact;
  the seam is off by default.
- **Privacy/security:** on-device only; no values logged.
- **Analytics/flags:** the seam itself is the flag (provider present/absent); no separate flag system.
- **Rollback:** revert branch; with the seam never injected, there is nothing live to roll back.
- **Deployment order:** go-live (owner) follows this merge — register store, inject provider, backfill,
  retire old formula, per AC-8.

## Human gates

- **Go-live is owner-performed** (registering the store in `BaselineApp.swift` + enabling the seam) —
  out of scope for this slice by owner decision; the doc (AC-8) hands off the exact steps.
