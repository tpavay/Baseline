# Workout Image Import — Why it doesn't work properly (diagnosis, 2026-07-15)

## TL;DR

The client pipeline and server transport are sound. The provider (Claude Sonnet 4.5)
is called and returns real structured workout IR. But the server's **strict assembly
validator** re-derives what the provider "should" have produced from the raw OCR text
using regex heuristics, and **hard-rejects** the provider's output when the two disagree.
On real, narrative-heavy workouts the provider cannot satisfy those heuristics across the
initial parse plus all 3 repairs, so **every section exhausts its repair budget and falls
to the deterministic fallback**, which dumps the raw OCR into a single
"Recognized text — needs review" note. The athlete gets a placeholder, not their workout.

This validates the standing intuition: the *transport/pipeline* architecture is decent;
the *assembly-validation philosophy* is the problem. It is also exactly the thing the v1
contract (`docs/implementation/workout-image-import.md`) already says to change.

## Evidence (production, `baseline-app-dev`, 2026-07-15)

Two real import jobs: `C9AFE279-2333-…` and `2A5E3B07-FBA8-…`.

- The provider was called and returned real IR (5–10 KB responses) — this is logged as
  `workout_import_job.provider_attempt_completed`.
- **Every** section then logged `workout_import_job.validation_failed` with:
  - `reasonCode: assembly.relationship`
  - `relationshipRule: source_standalone_movement`
  - `expectedExerciseCount: 1`, `observedCount: 0`, `validationPath: ir.records`
  - across `attempt: initial` and `repairAttempt: 1, 2, 3`.
- Then `section_fallback_completed` (`section_invalid` / `worker_budget_exhausted`), then
  `assembly_fallback_completed` (`cross_section_assembly`).
- The stored section result (Firestore `workoutImportJobSections`) is:
  - `title: "Imported workout"`, one block `"Imported section 1"`, one group
    `"Recognized text - needs review"` whose single note is the **raw OCR text**, with the
    ambiguity string *"Baseline preserved the recognized text because this section could not
    be structured automatically."*
  - This also violates v1 contract **invariant #8** ("the editor never renders OCR / provider
    output as workout content") — the current fallback ships raw OCR to the editor as a note.

## The kind of input that breaks it

The failing job was **"THE BAYENS METHOD"**, a HYROX tempo-running session. The actual workout
is small and simple —

- 10-minute easy-jog warm-up,
- one tempo block: **3 × 13:00 @ tempo pace, 1:30 standing rest between intervals**,

— but it is embedded in *paragraphs of coaching prose*: recovery-percentage guidance, pacing
philosophy, execution notes, "I would recommend…" narration. Roughly 90% of the OCR is prose,
10% is the prescription.

The assembly heuristics are tuned for **structured strength lists** (named custom movements →
one exercise each). On **endurance / coaching-note** content they misfire: they flag prose lines
as "required standalone movements," then demand an exercise the provider correctly did not create,
and fail the whole section.

A synthetic analog of this shape (safe to commit; no third-party program text) lives at
`docs/quality/evidence/fixtures/narrative-endurance-session.txt`.

## Root cause (files + lines)

- `functions/src/workoutImport.ts` — `assembleWorkoutImportIR` / `reconcileParsedWorkoutCatalogIdentities`.
  The `invalidStandalone` / `invalidAlternatives` / `invalidStructure` / `invalidTimedWork` checks
  (~lines 3415–3517) re-derive expected structure from OCR regex (`standaloneRequiredMovementTokens`
  at ~2971, `standaloneAlternativeMovementTokens`, `sourceTimedWorkPrescription`, …) and emit **fatal**
  `assembly.relationship` failures.
  - The specific false positive: `invalidStandalone` fires when a line is heuristically classified as a
    required movement, the observation is cited by *some* record, but **no exercise cites it**
    (`observedCount: 0`) — i.e. the provider used it as a note/group/heading, which for narrative content
    is usually correct. The rule cannot be satisfied by repair because the "movement" isn't really one.
- `functions/src/workoutImportJobRuntime.ts` (~lines 556–595) retries up to
  `MAX_SECTION_REPAIR_ATTEMPTS = 3` (`workoutImportJobs.ts:26`) then discards the parse for the fallback.

This is **deliberate and fully tested** — `cd functions && npm test` → **187 pass, 0 fail**, including
`"raw reconciliation rejects laundering a standalone custom movement through another exercise"`. So this
is not a bug to patch; it is an over-strict validation *philosophy* to revise.

## This is what the v1 contract already prescribes

`docs/implementation/workout-image-import.md`:
- "Structural uncertainty becomes a targeted `ReviewIssue` instead of malformed workout content."
- "The deterministic grounding layer repairs only source-proven shapes that have one valid interpretation."
- "Preserve the source as a note or ambiguity instead of inventing a relationship."
- Non-negotiable invariant #5: "`ReviewIssue` values are targeted sidecar metadata," not a reason to
  discard the whole parse.

The current server does the opposite: it discards a good parse when a re-derived relationship rule
isn't met.

## Recommended fix (order = impact ÷ risk)

1. **Make `assembly.relationship` mismatches non-fatal at repair-budget exhaustion.**
   When repairs are exhausted and the remaining failures are relationship-shape (`assembly.relationship`),
   **keep the provider's structured parse** and attach each mismatch as a targeted review flag, instead of
   dropping to the OCR-dump fallback. This one change turns "placeholder + raw OCR" into "the real workout +
   a couple of review flags," and aligns the fallback with contract invariant #8. Reserve the OCR-dump
   fallback for genuine parse failure (empty/garbage provider output), not for relationship disagreements.

2. **Raise the heuristics' precision** so they stop firing on coaching prose / endurance sessions
   (`standaloneRequiredMovementTokens` et al.): only enforce `source_standalone_movement` when the provider
   *did* produce at least one exercise from the observation (`sourcedExercises.length >= 1`) — respect the
   provider's decision to treat a line as a note when it produced none. Narrow, unit-testable.

3. **Section token budget:** one section also logged `provider_output_truncated` at 4096 tokens. Confirm the
   dense-section allowance (6144) is actually being selected for prose-heavy sections; truncation guarantees a
   failed parse.

4. **Longer term:** the full v1-contract reconciliation (CandidateGraph + semantic transactions +
   `WorkoutDraftBuilder`, structural-only validation) the implementation doc describes.

## How to build the fix safely

- Reproduce with `docs/quality/evidence/fixtures/narrative-endurance-session.txt` (synthetic; commit-safe).
  For an exact repro, the real OCR + provider IR are still retrievable from Firestore
  (`workoutImportJobSections`, job `2A5E3B07-FBA8-…`, sections order 0/1) until the 24 h TTL expires.
- Add a server test: this section must produce a **structured** tempo-run workout
  (warm-up + `3 × 13:00` tempo block + rest) with at most a couple of review issues — **not** the fallback.
- Apply fix #1/#2 until that test passes and the existing 187 stay green.

## What is NOT the problem (verified)

- Functions are deployed (all 8 import callables live on `baseline-app-dev`).
- The client is wired in (`BaselineApp`, `PlanView`) and calls `parseWorkoutImport` / the job callables.
- The image pipeline (normalize → Vision OCR → protected temp) is solid; OCR returns 128 observations / 3,511
  chars for this workout — the text is captured fine.
- App Check is **not enforced** (logs: *"Allowing request with invalid AppCheck token because enforcement is
  disabled"*), so it is not blocking calls today — but it must be enabled before prod (release checklist).
