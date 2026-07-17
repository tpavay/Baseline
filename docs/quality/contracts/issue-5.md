# Feature Contract: Sleep Engine Slice 2 — persistence & aggregation (headless)

- Issue: #5
- Base branch: `feature/issue-2-workout-image-import`
- Change type: feature
- Owner: orchestrator

Base note: branched from the Slice 1 merge point (`c0b1892`). `main` remains stale (recorded in #4).

## User outcome

No visible change. Canonical sleep nights and the HealthKit sync cursor become durable SwiftData
storage behind a `SleepRepository`, the backfill orchestrator runs on that storage, deletions and
transient fetch failures no longer lose revisions, and window queries expose the 7/14/30-day night
sets Slice 3's scoring engine will consume.

## Non-goals

- No `SleepAnalysis`, no scoring, no comparisons (Slice 3); version fields for the analysis blob are
  reserved, not populated.
- No app-container registration: `SleepSchema.models` exists but is NOT added to
  `BaselineApp.swift` (that file carries unrelated uncommitted WIP in the primary checkout;
  registration lands with Slice 4 wiring). The running app never touches the new store.
- No DecisionEngine/TodayEvidence/UI/agent changes (Slices 4–5).
- No Firestore/rules changes; sleep data stays on-device.
- Existing tests are not modified, weakened, or deleted; Slice 1's public API is extended, not
  broken (additive protocol changes only where the deletion re-plumb requires them).

## Acceptance criteria

- [ ] AC-1: `SDSleepNight`/`SDSleepSyncState` round-trip a full `SleepNight` (episodes, intervals
      with provenance, gaps, lifecycle, fingerprint, sample UUIDs) through a ModelContainer with
      byte-stable equality, using an explicitly pinned Date encoding strategy for the Codable blob.
- [ ] AC-2: CloudKit-safety rules hold: every stored property optional or defaulted, no
      `@Attribute(.unique)`, no required relationships; decoding a row written with missing new
      fields yields working defaults (optional-backing pattern), and `SleepSource.none` decodes for
      rows that carry it.
- [ ] AC-3: `replaceCanonical(night:)` is fingerprint-gated through the repository: unchanged
      fingerprint → zero writes; changed fingerprint → single replacement with `revision` bumped and
      status `revised`; concurrent-date upsert never produces two rows for one night date.
- [ ] AC-4: `HKQueryAnchor` cursor persistence survives store reopen (secure-coding archive), and
      the cursor does NOT advance past a delta whose touched-night window refetch failed
      transiently — the failed night is retried on the next sync (Slice 1 follow-up).
- [ ] AC-5: HealthKit deletions revise nights: composing sample UUIDs are persisted per night; a
      delta carrying only deleted-object UUIDs maps them to their stored nights, re-resolves those
      nights, and produces `revised` replacements (or removal when no samples remain).
- [ ] AC-6: Window aggregation queries return correct 7/14/30-day night sets (half-open date
      windows, newest-first `latest(limit:)`), and a timezone-shifted day-key (travel) neither
      crashes nor duplicates a night — it lands as benign revision churn.
- [ ] AC-7: The backfill orchestrator running against the SwiftData-backed stores reproduces Slice
      1's contract behavior (progressive batches, idempotent re-run with zero rewrites of unchanged
      nights) across a store close/reopen mid-backfill.
- [ ] AC-8: Dropped-sample visibility: samples rejected by `@unknown default` are counted and the
      count is exposed on the ingestion result (no health values logged).
- [ ] AC-9: No behavior change in the running app: full existing suite passes unmodified;
      `SleepSchema` is referenced only from tests; `git diff` shows no edits to `BaselineApp.swift`,
      engines, views, or stores outside the sleep module + `Shared/Persistence`.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Night persisted, reopened, replaced on revision, windows queryable | AC-1/AC-3/AC-6 tests |
| Loading | Mid-backfill store reopen resumes without duplicates or rewrites | AC-7 test |
| Empty | Fresh store: no nights, nil cursor, windows return empty sets | AC-1/AC-6 boundary tests |
| Error/offline | Transient refetch failure → cursor held, night retried next sync | AC-4 test |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `SleepRepositoryTests` round-trip + Date-strategy pin (in-memory ModelContainer) | Value equality after store round-trip proves lossless persistence |
| AC-2 | `SleepRepositoryTests` migration-default + decode cases | Constructs rows missing new fields; asserts defaults and `.none` decode |
| AC-3 | `SleepRepositoryTests` replacement gating + single-row invariant | Write counts + fetched row count observed directly |
| AC-4 | `SleepBackfillPersistenceTests` cursor reopen + transient-failure retry | Failing provider injected; cursor + retry observed across syncs |
| AC-5 | `SleepBackfillPersistenceTests` deletion cases (UUID-only delta) | Deletion fixture maps to stored night; revised/removed outcome asserted |
| AC-6 | `SleepRepositoryTests` window queries + timezone-shift case | Boundary dates pinned; count/no-dupe asserted under calendar change |
| AC-7 | `SleepBackfillPersistenceTests` end-to-end on SwiftData stores | Same assertions as Slice 1 idempotence, plus close/reopen mid-run |
| AC-8 | `SleepBackfillPersistenceTests/droppedUnknownSampleCountsAccumulateAcrossFetches` (fixture-driven; includes a held-cursor retry asserting no double-count) | Count surfaces on the ingestion result and commits exactly once per successful sync. The `HealthService` subtraction site (`samples.count - mapped.count` around the `@unknown default` mapping) is inspection-only evidence — not automatable without a live HealthKit store |
| AC-9 | Full suite green; `git diff --stat` scope audit; grep for `SleepSchema` references | Proves isolation and zero app wiring |

## UX evidence

Not applicable: headless persistence slice; the running app cannot reach the new store (AC-9).

## Risk and rollout

- **Data migration:** new store entities only; no existing SwiftData entity touched. The
  optional-backing rule is enforced by AC-2 (known project crash gotcha).
- **Backward compatibility:** Slice 1 protocols extended additively (deletion plumb adds a
  deleted-UUIDs channel to the delta type; in-memory impls updated in lockstep — they are
  slice-internal, not app API).
- **Privacy/security:** health data remains on-device in the local store; no values logged; anchor
  archives contain no health payloads.
- **Analytics/flags:** none.
- **Rollback:** revert branch; store is never opened by the app (no container registration).
- **Deployment order:** behind Slices 3–4; registration + any lightweight migration land in Slice 4.

## Human gates

- None.
