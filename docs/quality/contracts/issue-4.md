# Feature Contract: Sleep Engine Slice 1 — canonical sleep ingestion (headless)

- Issue: #4
- Base branch: `feature/issue-2-workout-image-import`
- Change type: feature
- Owner: orchestrator

Base-branch note: `feature/issue-2-workout-image-import` is the de-facto integration branch; `main`
is stale (recorded as infrastructure debt in #4).

## User outcome

No visible change. The app gains a tested, headless ingestion layer that turns raw HealthKit sleep
samples into canonical `SleepNight` facts (episodes, stage intervals with provenance, awakenings,
WASO, gaps, lifecycle, fingerprint) with deterministic multi-source resolution and a progressive
90-night backfill — the foundation for `docs/implementation/sleep-engine.md` Slices 2–5.

## Non-goals

- No SwiftData persistence of nights or sync cursors (Slice 2); storage sits behind protocols with
  in-memory implementations.
- No scoring, no `SleepAnalysis`, no comparisons/flags (Slice 3).
- No `DecisionEngine`/`TodayEvidence`/morning-flow changes; readiness behavior is byte-identical (Slice 4).
- No UI, no agent tools (Slice 5).
- No new HealthKit read types (`.sleepAnalysis` is already authorized) and no Firestore/rules changes.
- Existing tests are not modified, weakened, or deleted.

## Acceptance criteria

- [ ] AC-1: Fixture samples for one staged night resolve to a canonical `SleepNight` with stage
      intervals carrying per-interval source provenance, bedtime/wake, asleep hours, awakening
      count, WASO minutes, and detected tracking gaps.
- [ ] AC-2: Episode segmentation marks primary overnight sleep vs naps (`isPrimary`); naps never
      inflate primary asleep hours; noon-to-noon assignment places a midnight-spanning episode on
      the wake day.
- [ ] AC-3: Source precedence is deterministic — user-preferred → Apple Watch staged → other single
      complete staged source → generic asleep samples → manual — and overlapping samples from
      unrelated devices are resolved to one source, never merged into one interval set.
- [ ] AC-4: The night source fingerprint is deterministic (same normalized samples → same hash) and
      changes when any composing sample changes.
- [ ] AC-5: Lifecycle transitions hold: a night ingested inside the stabilization window is
      `provisional`; it becomes `complete` after stabilization; a delta that changes the canonical
      night yields `revised` with `revision` incremented; an unchanged fingerprint leaves the stored
      night untouched.
- [ ] AC-6: Progressive backfill imports the most recent 14 nights first (today's night available
      after batch 1), continues to 90 nights, and re-running the full backfill is idempotent (no
      duplicate nights, unchanged nights not rewritten).
- [ ] AC-7: Boundary/invalid inputs are safe: empty sample set → no night (never imputed);
      zero-duration and overlapping same-source samples are normalized without crashing; HealthKit
      denied/unavailable → ingestion reports empty results without throwing into callers.
- [ ] AC-8: No behavior change anywhere in the app: the full existing test suite passes unmodified,
      and no new type is referenced from views, engines, or stores outside the new sleep ingestion
      module.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Full staged Watch night → canonical `SleepNight`, status `complete` | AC-1/AC-5 unit tests |
| Loading | Ingestion before source stabilization → `provisional` night, later replaced | AC-5 lifecycle tests |
| Empty | No samples in window → no `SleepNight` (nil, never imputed) | AC-7 tests |
| Error/offline | HealthKit unavailable/denied → empty result, no throw to caller, no partial night | AC-7 tests |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `SleepIngestionTests` night-assembly cases (fixture-driven) | Asserts every canonical field from known raw samples |
| AC-2 | `SleepIngestionTests` segmentation cases (nap, split sleep, midnight span) | Observes `isPrimary`, primary hours, and date assignment directly |
| AC-3 | `SleepIngestionTests` precedence cases (Watch+iPhone, Watch+Oura, preferred override, manual-only) | Same fixtures always resolve to the same single source; merged-interval assertion is negative |
| AC-4 | `SleepIngestionTests` fingerprint determinism + mutation cases | Hash equality/inequality asserted on controlled sample edits |
| AC-5 | `SleepIngestionTests` lifecycle transition cases with injected clock | Status/revision observed across simulated sync points |
| AC-6 | `SleepBackfillTests` progressive + idempotence cases with in-memory stores | Batch order, availability-after-batch-1, and store write counts asserted |
| AC-7 | `SleepIngestionTests` boundary cases + `SleepBackfillTests/emptyProviderProducesNoNightsAndDoesNotThrow` (primary denied/unavailable evidence, fixture-driven); `HealthServiceSleepSmokeTests` is smoke-only (environment-coupled: live simulator HK store, denial indistinguishable from absence) | Nil/empty outcomes asserted, no crash |
| AC-8 | Full existing suite green with zero modified test files (`git diff --stat` on `BaselineTests/`) | Proves isolation of the slice |

## UX evidence

Not applicable: headless slice with no user-facing behavior; AC-8 proves the app surface is unchanged.

## Risk and rollout

- **Data migration:** none — no persistence in this slice; stores are in-memory protocol impls.
- **Backward compatibility:** additive new files plus an extension of `HealthService`; existing
  `sleepSummary`/`lastNightSleep` callers untouched (removal happens in Slice 4 per plan §6).
- **Privacy/security:** read-only HealthKit, no new read types, no data leaves device, no logging of
  health values.
- **Analytics/flags:** none.
- **Rollback:** revert the branch; nothing depends on the new module (AC-8).
- **Deployment order:** merges behind Slices 2–4 before anything user-visible exists.

## Human gates

- None. (PR base-branch choice — stale `main` vs `feature/issue-2-workout-image-import` — is
  surfaced to the user at PR time, not blocking implementation.)
