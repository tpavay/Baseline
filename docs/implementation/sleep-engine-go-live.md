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

Build the repository with the athlete's sleep need threaded from `ReadinessConfig`, then wrap it in
the provider (which reads the repository's cached analysis, so display and decision always agree):

```swift
let sleepRepository = SwiftDataSleepRepository(context: modelContext,
                                               derivation: .engine(need: config.sleepNeed))
let sleepProvider = RepositorySleepEvidenceProvider(repository: sleepRepository)
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

### Seam-on cap behavior to verify at go-live

Two properties are only exercised once a provider is injected, so include them in the on-device
go-live check:

- **Need-relative `poorSleep` cap.** The cap threshold is need-relative — it fires at
  `asleep ≤ need − 3.5 h`, not at a literal `< 4.5 h`. The equivalence to the old clock threshold
  holds exactly only at the default 8 h need; a user-set need moves the cap with the goal (a 9 h need
  caps a night at ≤ 5.5 h). Verify a short night against a *non-default* need caps as expected.
- **Cold-start / low-coverage device nights still cap.** A device-sourced night whose score is not
  published (cold start with < 5 nights of history, or a low-coverage night) does **not** publish a
  score, but it still feeds `sleepHours` + `sleepDurationDeficit` to the decision so the `poorSleep`
  training-safety cap fires — matching what the pre-slice `health.lastNightSleep()` path did.
  `sleepScore`/`sleepConfidence` stay nil (no renormalized score, no certainty credit), and no
  decision snapshot is frozen. Verify a genuinely short cold-start device night is still capped.
  (A manual/`.none` night remains the sole subjective-fallback route and feeds no cap signal.)
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

> **Parity caveat — re-verify seam-on readiness at this step.** `ReadinessScore.sleepScore` is the
> shared leaf of *both* the live seam and the `MorningReadinessParityTests` reference helper. The
> parity tests only proved **seam-off** equals pre-slice; they say nothing about the engine path.
> Retiring this function moves both sides of that comparison at once, so the parity suite cannot catch
> a seam-on regression here. Re-verify seam-on readiness end-to-end on-device (published-score night,
> cold-start short device night → still capped, manual night → subjective fallback) as part of this
> commit rather than relying on the parity tests.

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
