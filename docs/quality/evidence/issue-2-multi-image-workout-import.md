# Verification Evidence: Durable resumable multi-image workout import

- Issue: #2
- Base revision: `933c3288a1635658266c38c4a54386a8dfa36846`
- Verified: 2026-07-15
- Contract: `docs/quality/contracts/issue-2-resumable-section-workout-import.md`
- Workspace state: Verification includes the current dirty worktree, so the base revision identifies only the last commit and is not an exact reproducible SHA for the verified changes.

## Automated evidence

| Check | Result | Evidence |
|---|---|---|
| Feature-contract validation | Pass | All three issue #2 contracts passed `validate_feature_contract.py --require-issue`. |
| XcodeGen project generation | Pass | `xcodegen generate` completed from canonical `project.yml`. |
| Focused recognized-text fallback Swift tests | Pass: 22 tests | `WorkoutImportSourcePipelineTests` passed on iPhone 15 Pro (iOS 17.0.1) in `/tmp/BaselineFallbackSourcePipeline2.xcresult`. |
| Focused five-photo semantic fixture | Pass | `realisticFivePageFixtureBuildsSerializesAndMaterializesWithoutLosingTrainingSemantics` passed in `/tmp/BaselineFivePhotoFixture.xcresult`. |
| Focused resumable lifecycle tests | Pass: 46 tests | `ResumableWorkoutImportJobTests` passed, including the completed, queued, processing, failed, cancelled, unreachable, edit-versus-refresh, and save-versus-refresh matrices plus cancellation cleanup after tombstone-write failure. |
| Import race repetition | Pass: 500 static tests across 20 isolated iterations | Cycle 5 ran 25 static `ResumableWorkoutImportJobTests` in each isolated process; logs: `/tmp/issue-2-cycle5-swift-isolated-{1..20}.log`. |
| Callable and durable runtime tests | Pass: 187 tests | `npm test` in `functions/`, including exact relationship-repair diagnostics, both supported timed-work RPE representations, the nested-boundary regression, exact mixed-result assembly fallback, and the shared five-photo assembly fixture. |
| Runtime race repetition | Pass: 320 tests across 20 isolated runs | Cycle 5 ran 16 `workoutImportRuntime.test.js` tests in each isolated Node process; logs: `/tmp/issue-2-cycle5-node-isolated-{1..20}.log`. |
| Firestore emulator integration | Pass: 12 tests | `npm run test:firestore-emulator` against an actual Firestore emulator. |
| Signed-in development smoke | Pass: five photos, three sections, no terminal failure | A fresh authenticated import completed on final revision `processworkoutimportjob-00030-tuj` in 101.0 seconds with 8 editable blocks and all 35 evidence identifiers cited. One section exhausted its bounded repairs, so the deterministic recognized-text fallback returned the workout instead of an error. |
| Complete Swift test suite | Pass: 588 tests | `/tmp/BaselineIssue2ReleaseGate.xcresult` passed on iPhone 15 Pro (iOS 17.0.1) with zero failed or skipped tests. |
| Whitespace/error-marker inspection | Pass | `git diff --check` |
| Final independent gatekeeper | Pass | Independent correctness, test-quality, and final gatekeeper reviews found no blocking or high-severity issue. The test-quality reviewer also proved the mixed-result regression fails under a controlled structure-discarding mutation. |

The focused Swift matrix covers ordered batches; the 1/10/11-image boundaries; incremental loading; source-page identity; single-image delegation; stale-task isolation; atomic failure at normalization/OCR/parser stages; cancellation before the first progress callback; missing-original reselection without discarding saved pages; manifest schema preflight and incompatible-checkpoint deletion; exact remote payload byte accounting; successful-save cleanup; protected temporary storage; backward-compatible decoding; canonical note materialization at workout/block/group/exercise scope; structured qualitative load targets; lossless required-group versus choice semantics; canonical identity plus workout-specific display labels; exact primary-set and stable alternative issue reconciliation; transient editor isolation; authoritative draft synchronization and persistence at save; recursive AI context; and validated AI mutations.

The callable suite covers ordered and legacy source indexes, out-of-range or reordered pages, the 2,000-observation and 40,000-character boundaries, non-finite confidence and invalid bounds, catalog truncation, all four note scopes, the note-classification prompt contract, allowlisted result envelopes, ambiguous or excessively nested envelope rejection, one-call success, bounded one-repair failure, end-to-end deadline budgeting from handler entry, production provider timeout/retry construction, privacy-safe validator diagnostics for every runtime event, initial/repair attempt labeling, mixed tagged-node rejection, exact numeric-string normalization, bodyweight and race-weight prescription recovery, loss-aware repetition conflict handling, and the `require_all_options` workout-edit operation.

The durable runtime tests additionally cover exact same-task replay after transient provider failures, initial outbox dispatch recovery without a client poll, hard-crash lease takeover, stale-dispatch recovery after queue exhaustion, renewable worker and section leases, compare-and-set ownership, cancel-before-create tombstones, cancellation versus late completion, owner-only access, incompatible stored schema terminalization, exact root, section input, section result, section document, and final assembled result byte boundaries, idempotent manual retry, lifetime provider accounting, persisted repair continuation, and proportional token budgets for 16, 17, and 20 dense sections.

The shared `realistic-five-page-request.json` fixture is encoded by Swift and parsed through the production TypeScript request decoder.
Three independently inferred section IR fixtures then assemble into the pinned `realistic-five-page-response.json` document.
Both runtimes verify the same long MED and MDV continuation hierarchy, source provenance, one-of BikeErg or Echo Bike interval choice, required A/B clusters, catalog matching, and blank editable loads.
The Performance Layer is represented as two ordered 35-minute groups rather than one flattened 70-minute stair prescription.
The first group repeats a 6-minute StairMaster segment with box step overs and hand-release push-ups.
The second group repeats a 6-minute StairMaster segment with dual-dumbbell push presses and wall balls.

After Vision produces readable OCR, provider outage, invalid model output, exhausted repair, worker-budget exhaustion, oversized model output, and cross-section assembly failure now complete with an editable recognized-text review instead of a terminal no-workout error.
The fallback retains successful structured sections when possible and preserves each failed section's recognized lines as bounded notes with source identifiers.
It deliberately creates no exercise nodes, so unsupported workout structure remains visible and editable without being invented.
The iPhone client applies the same provider-independent fallback when remote start or status transport fails and when an eligible persisted failed job is restored.
When a status transport failure exposes that fallback while the durable server job is still queued or processing, review now offers `Check Import Again`.
That explicit action performs one status lookup without repeating OCR, preserves the athlete's current editable draft while the server remains pending or unreachable, and replaces it only after a completed server document is available.

The mixed-result assembly regression now asserts the exact user-visible document rather than only a privacy-safe log event.
It requires a successful Run section to remain structured with expanded provenance, a failed Deadlift section to remain exact OCR in an empty-child review group, a section-boundary warning, no invented fallback exercise, and four bounded section-only provider calls.

Cancellation now treats local privacy cleanup as unconditional.
Even if the protected remote-cancellation tombstone cannot be written, Baseline removes the job directory and its source files before attempting the idempotent remote cancellation.
The focused fault-injection repository throws during tombstone persistence and verifies that no local checkpoint or source file remains.

A controlled-fault marker left in the pinned cross-runtime request initially masked an off-by-one continuation boundary.
After removing it, the shared test exposed two adjacent `Aerobic Intervals` groups instead of one complete group.
Assembly now uses unique source-observation anchors to merge the repeated compatible child fragment after merging its outer AMRAP wrapper.
The focused nested-boundary regression and the complete shared five-photo fixture both pass with the unmodified Swift-generated request.

The signed-in development smoke used the same complete five-page fixture through the deployed callable, Cloud Tasks worker, Anthropic provider, Firestore persistence, status polling, and final deterministic assembly.
It required Aerobic Capacity, MED, Performance Layer, MDV, Echo Bike, Sled Pull, Deadlift, Lateral Burpee Over Barbell, Dumbbell Push Press, Recovery Guidelines, and Coach's Note semantics.
It also required bodyweight and race-weight qualitative loads, a structured 25 m sled distance, and at least three structured 12-repetition metrics while rejecting banana units, Dumbbell Bench, and Stationary Bike.
Every returned evidence identifier belonged to the source request, and every source observation was either cited or preserved verbatim.
The live repair contract identified exact fixed relationship rules and request-local observation aliases without logging OCR text or durable observation identifiers.
An earlier final-candidate run corrected the representative explicit-alternative line in one bounded repair and completed without a section fallback or cross-section assembly fallback.
The final-revision run encountered additional provider variation, exhausted the bounded repairs for one section, and still completed with an editable recognized-text workout rather than a terminal error.
Timed-work validation now accepts the two representations already supported by the IR and domain model: duration and RPE metrics on the same work set, or duration on a work set plus an RPE intensity target on the exercise.
It rejects duration and RPE metrics split across different sets and rejects duplicate metric-plus-intensity representations.

The provider output allowance is 4,096 tokens for a normal section and 6,144 tokens for a dense section, with a hard per-call clamp of 2,048 through 8,192 tokens.
The durable job reserves enough tokens for every initial section call, then allows bounded repair and retry headroom up to 524,288 lifetime output tokens.
One section may use at most three targeted repairs and four total provider calls.
The earlier fully structured five-photo smoke used one repair.
The final-revision smoke exercised the full three-repair boundary and proved that a hard section falls back to recognized text instead of failing the import.

## Visual evidence

The normal review, on-demand source gallery, and exact issue crop were inspected on an iPhone 16 Pro simulator with the five representative user-provided screenshots. The default review keeps all source images out of the workout hierarchy, uses the shared normal workout editor, exposes the ordinary exercise ellipsis menu, and shows only actionable import findings. The gallery presents one full-width aspect-fit image at a time, and the issue action opened the relevant sled-pull/deadlift/lateral-burpee crop rather than a generic page. Temporary screenshot-only launch code was removed before the final build.

The final deterministic debug states were also inspected in dark appearance on an iPhone 16 and iPhone SE.
The current processing artifact visibly includes the Close control, the overflow menu, and truthful copy explaining that processing continues after the screen closes.
The recoverable failure keeps a high-contrast retry control and names the destructive start-over action, the compact layout has no overlap, and the accessibility-size review reflows primary actions vertically.

Final local visual artifacts are `/tmp/issue-2-review-final.png`, `/tmp/issue-2-gate-current-processing.png`, `/tmp/issue-2-failure-final.png`, `/tmp/issue-2-compact-failure-final.png`, and `/tmp/issue-2-compact-ax-final.png`.
Earlier source-gallery artifacts remain outside the repository because they contain user-provided workout images: `/tmp/issue-2-gallery-large.png` and `/tmp/issue-2-crop-large.png`.

## Adversarial validation

A controlled fault was applied in an isolated copy of the callable validator to permit a one-page backward source-index jump. The parser test `preserves ordered source image indexes and rejects reordered pages` failed with `Missing expected exception`, demonstrating that the test detects the ordering defect. The isolated copy was then deleted; the workspace implementation was unchanged.

Two additional controlled faults targeted the live parser regression. Disabling safe envelope unwrapping caused the wrapper regression test to fail, and forcing an unnecessary repair caused `valid raw and wrapped outputs make exactly one provider call` to fail. Both mutations were isolated and removed after proving the tests reject the original failure modes.

A later isolated fault restored the unsafe note ordering that put 20 existing model notes ahead of recovered qualitative prescriptions. The targeted test failed because `load: bodyweight` disappeared, proving the cap-boundary assertion protects the recovered target. The disposable copy was removed without transferring the mutation.

The final repair cycles added three more isolated falsifications.
Disabling set-note reparenting caused the mapped test to fail with `assembly.relationship`.
Restoring permissive ignored-heading recovery caused the prescription-heading regression to fail with `Missing expected exception`.
Disabling source-anchored section selection reproduced the deployed `cross_section_assembly` failure in the regression that includes a trailing summary block, an unwrapped child group, and a rest sibling.
Every disposable worktree was removed without transferring the controlled mutation.

The final reliability gate temporarily changed the recognized-text fallback to discard every preserved note.
The mapped Node test `OCR fallback preserves recognized lines without inventing an exercise` failed with an empty actual note collection instead of the expected two OCR lines.
Restoring the implementation made the same targeted test pass, proving that it observes the user-visible preservation rule rather than only the fallback status.

Development Cloud logs for the first failed import showed a provider response rejected as structurally invalid, followed by an unnecessary repair request and the old revision's 60-second infrastructure deadline. Revision `parseworkoutimport-00006-jos` corrected the 180-second server/client deadline mismatch; a real five-photo retry then proved that both the initial and repaired provider outputs still violated the validator contract. The follow-up local correction handles the known schema/validator contradictions without discarding the workout: duration wins a repeat/duration conflict with an explicit review ambiguity, qualitative numeric targets remain reviewable notes, exact numeric strings normalize consistently, and only a single unambiguous tagged-node representation is accepted. Any remaining validation failure emits fixed code/path/type metadata for each attempt without logging workout or OCR content.

Earlier independent correctness, test, and UX reviews identified and drove fixes for:

- parser input/output budget mismatch;
- retained photo/OCR/evidence bytes after cancellation or save;
- peak memory from loading every Photos asset before normalization;
- raw model-derived validation errors reaching logs;
- invisible iCloud photo-loading state and competing import controls;
- undersized or unlabeled blocking review actions;
- fixed-size typography and non-adaptive layouts;
- cross-page evidence being reduced to one image;
- oversized single VoiceOver elements for long instructions;
- repeated full-resolution source decoding/cropping during review rendering;
- non-navigable issue announcements and undersized recovery actions;
- alternative issues incorrectly reconciling against a valid parent set;
- invalid-value issues clearing after unrelated exercise edits;
- save-time synchronization not being exercised through persistence;
- a hidden destructive action behind static-looking `OR` text;
- blocking copy that did not name the exact set and alternative requiring review; and
- set alternatives missing stable identity, ordinary-editor value fields, and duplicate-fingerprint coverage.

Review previews now render bounded JPEGs off-main and cache them in the source/evidence child view lifecycle. Long issue lists expose a separate heading and individually navigable findings, and primary/recovery controls use adaptive minimum heights.

Repair Cycle 4 additionally fixed close-versus-cancel checkpoint semantics, manifest schema isolation and expiry, source byte validation before persistence, file-backed Photos intake, schema-incompatible remote error mapping, note-only continuation parsing, recursive continuation-group assembly, autonomous dispatch recovery, and privacy-safe model metadata.

Repair Cycle 5 replaced label-based continuation matching with source-planned fragment paths, made cancel tombstones delete local checkpoints before remote acknowledgement, bounded server provider concurrency at two, and added protected backup-excluded file-only Photos transfers with cleanup coverage.
It also made a failed or missing photo require ordered reselection from the first bad page through the remaining suffix, pinned the complete five-page note and provenance contract, added exact byte and valid-token boundary tests, and removed a two-reader OCR cancellation-gate flake.

Repair Cycle 6 added actual-runtime acceptance and terminal rejection at the exact final assembled-result byte boundary, verified exact long-note content after native materialization, and corrected singular and plural photo-reselection copy for every suffix size.
Repair Cycle 7 strengthened the shared five-page fixture with exact scope-sensitive workout, block, group, and exercise note assertions while retaining the 35-observation provenance boundary.
Repair Cycle 8 moved the provider contract to a required flat IR with explicit ignored-observation accounting, bounded Sonnet section calls, exact metadata heading recovery, narrow rest and set-note normalization, and privacy-safe provider-failure categories.
It increased the provider timeout to 120 seconds, worker and section leases to 180 seconds, and dispatch recovery to 210 seconds so a valid in-flight provider request cannot lose its claim.
Repair Cycle 9 replaced positional cross-section assembly with provenance-expanded boundary anchors and explicit compatible-wrapper, unwrapped-child, and conflicting-wrapper behavior.
It preserves distinct Circuit One/Two and Choose Modality/Load containers, merges equivalent numeric and number-word wrappers, and rejects conflicting repeat, duration, optionality, and choice-cardinality metadata.
Repair Cycle 10 added exact mixed-result assembly fallback coverage, explicit reconciliation from immediate OCR review to a still-running durable server job, and unconditional local cancellation cleanup when tombstone persistence fails.
Repair Cycle 11 made relationship diagnostics actionable, reconciled the timed-work RPE validator with the supported IR, and used the already-budgeted fourth provider call for a third targeted repair on hard sections.
The release gate then found that duration and RPE metrics from different sets could be incorrectly paired.
Both raw and final validators now require those metrics on the same set, preserve the valid exercise-intensity representation, and reject duplicate representations.
Fresh independent correctness, test-quality, and final gatekeeper reviews passed after the correction.

## Development deployment and remaining release evidence

Development worker revision `processworkoutimportjob-00030-tuj` and callable revision `parseworkoutimport-00028-kuf` serve 100 percent of development traffic.
The final-revision signed-in smoke completed all three sections in 101.0 seconds, returned eight editable blocks with all 35 source identifiers cited, and passed the exact required and forbidden semantic assertions.
Cloud logs contained only allowlisted operational fields.
They recorded actionable relationship diagnostics, bounded repairs, one recognized-text section fallback, and a final cross-section fallback instead of a failed job.
An earlier candidate smoke completed in 96.7 seconds with five fully structured blocks, 27 cited source identifiers, one repair, and no fallback.
All temporary Firestore job, section, cancellation, usage, and Auth records were deleted, including five retained diagnostic jobs from earlier repair cycles.
The temporary service-account token-creator binding was removed and verified absent.
No production deployment was performed.

Release acceptance still requires:

1. VoiceOver or Accessibility Inspector verification on a signed development build. Smallest-iPhone and accessibility Dynamic Type visual inspection are complete.
2. Physical-device verification of complete file protection and a peak-memory check with large Photos assets.
3. A real-device five-photo confirmation through the Photos picker and normal editor, followed by production App Check registration and provider spend caps before release.
