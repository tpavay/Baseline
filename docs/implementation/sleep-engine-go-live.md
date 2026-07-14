# Sleep Engine — Go-Live Runbook

Slice 4 wired the Sleep Engine into the readiness decision behind an **injectable seam that is off by
default**.
With no `SleepEvidenceProvider` injected, the app's readiness behavior is byte-identical to
pre-slice (AC-5): the legacy `ReadinessScore.sleepScore(hours:efficiency:)` path runs, nothing reads
the sleep store, and no `SleepAnalysis` is persisted onto `ReadinessEntry`.

This document is the owner-performed handoff: the exact, ordered steps to turn the seam on.
Each step is independently revertible.
Do not batch them into one commit — land and verify them in order.

## Preconditions

- Slices 1–3 merged (ingestion, persistence/aggregation, scoring) — present in this branch's history.
- `BaselineApp.swift` unrelated WIP cleared (this slice deliberately left that file with a zero diff;
  see AC-9).
- A device with HealthKit sleep authorization, or a seeded store, to verify the on path.

## Ordered steps

### 1. Register the Sleep store in the app container

`SleepSchema.models` (`SDSleepNight`, `SDSleepSyncState`) is **not** registered on the app's
`ModelContainer` yet.
In `BaselineApp.swift`, extend the model list:

```swift
let models: [any PersistentModel.Type] =
    [Reading.self, ReadinessEntry.self] + PlanSchema.models + SleepSchema.models
```

All Sleep entities are CloudKit-safe (optional/defaulted properties, no `.unique`, UUID keys), so this
is an additive migration — existing stores open unchanged.
Construct a `SwiftDataSleepRepository(context: container.mainContext)` and hold it where the other
stores live (alongside `PlanStore`).

### 2. Start the backfill

Kick off `SleepBackfillOrchestrator` (progressive 90-night import, Slice 1) once, after
authorization, so the store has canonical nights and history windows for scoring.
Until nights exist, the provider returns `nil` for today and the seam falls back to the legacy/manual
path — so this step is safe to run before step 3, and the app degrades honestly if it is skipped.

### 3. Inject the provider into the decision assembly

Build the provider threading the athlete's sleep need from `ReadinessConfig`:

```swift
let sleepProvider = RepositorySleepEvidenceProvider(repository: sleepRepository, config: config)
```

Pass it at the two (and only two) construction points:

- `TodayEvidence.baseInputs(readings:todayEntry:health:sleepProvider:referenceDate:)` — the agent's
  base evidence (called from `TodayView` and `ConversationView`).
- `MorningReadinessScoreView(… sleepProvider: … referenceDate: …)` — the morning reveal
  (`DailyReadingFlowView`).

Use the recovery day for `referenceDate` (today's wake day).
No other call site needs to change; both parameters default to `nil`/`.now`, which is the dormant
seam.

Once injected:

- A scored device night feeds `sleepScore`, `sleepConfidence`, `sleepDurationDeficit`,
  `sleepInterruptionBurden`, and `sleepScheduleShift` into `DecisionEngine.Inputs`.
- The `poorSleep` cap re-expresses on the structured deficit; certainty counts sleep only when
  quality clears the bar (coverage ≥ 0.7 ∧ reliability ≥ 0.5).
- A manual/`.none` night (no published score) falls back to the existing subjective 85/35 path — the
  single manual route (AC-4).
- The exact `SleepAnalysis` used is frozen onto `ReadinessEntry.sleepDecisionSnapshot` (with its
  aggregation/score versions), and `sleepScore`/`sleepConfidence` are recorded (AC-7).
- A conversational sleep override (`PlanAssembler`, "I slept 5 h") still wins over the automatic base
  and reverts sleep to the manual path for that decision (AC-6).

### 4. Retire the legacy two-factor formula

Only after steps 1–3 are verified on-device, delete `ReadinessScore.sleepScore(hours:efficiency:)`
and the seam's `.legacy` branch, making the provider the sole sleep path.
Do this as its own commit so the legacy path stays revertible until the engine path is proven in the
field.
At that point `SleepDecisionSeam.Source.legacy` and the `health.lastNightSleep()` calls in
`TodayEvidence`/`MorningReadinessScoreView` can also be removed.

## Parity & rollback

- **Parity gate before flip:** the `MorningReadinessParityTests`/`TodayEvidenceTests` prove seam-off
  equals the legacy path on the with-Health, manual, and no-sleep fixtures.
  Keep them green through steps 1–3; they are the regression net for "we didn't change today's app."
- **Staged rollout:** steps 1–2 are invisible (store + data only).
  Step 3 is the first behavior change and is the natural place for a flag or a limited rollout if one
  is wanted later — the provider's presence *is* the flag.
- **Rollback:** remove the provider injection (step 3) to return to byte-identical pre-slice behavior
  with zero data loss — the store and snapshots simply stop being read.
  Reverting step 1 additionally detaches the store; existing `ReadinessEntry` snapshot blobs remain
  readable (optional field) but are no longer written.
- **Snapshot honesty:** `ReadinessEntry.sleepDecisionSnapshot` is immutable per entry, so a late
  Health revision or a version bump re-deriving the current reconstruction can never rewrite what a
  past morning's decision shows it used (plan §7).
