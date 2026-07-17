# Feature Contract: Resumable section-based workout import

- Issue: #2
- Base branch: `develop`
- Change type: fix
- Owner: orchestrator

## User outcome

An athlete can import a long workout from multiple ordered photos without losing completed work when the app backgrounds, the phone sleeps, a provider request times out, or one section needs repair.
Baseline recognizes and checkpoints source text locally, processes bounded workout sections through a durable server job, resumes automatically, and opens the existing workout editor with the assembled result.

## Non-goals

- This increment does not upload source image bytes, replace Vision OCR with cloud OCR, or make source images permanent workout content.
- This increment does not redesign the ordinary workout editor or insert source-image crops throughout the workout.
- This increment does not infer missing numeric loads, invent exercise identities, or weaken deterministic document validation.
- This increment does not remove the existing `parseWorkoutImport` callable while released clients may still use it.
- This increment does not guarantee successful recognition of handwriting or unreadable source material.
- This increment does not add a third-party dependency.

## Acceptance criteria

- [ ] AC-1: Each import has a stable client job identifier and a protected, non-backed-up local checkpoint containing only normalized source metadata, OCR observations, server job identity, progress, and any completed result needed to resume.
- [ ] AC-2: The app checkpoints after each normalized image and each OCR page, restores an unfinished import after relaunch or foregrounding, and removes the checkpoint plus temporary source images only after explicit cancellation, successful save, or expiry.
- [ ] AC-3: OCR runs with bounded concurrency, preserves the user's source order, assigns deterministic observation identifiers, and can continue when one page has no readable text as long as another selected page is readable.
- [ ] AC-4: A deterministic source-document processor removes only explicit repeated interface chrome and strongly proven status-bar artifacts using conservative layout-aware rules.
  Cross-photo repeated text remains distinct because geometry cannot prove whether it is screenshot overlap or intentionally repeated programming.
  The provider may consolidate true overlap only by citing every contributing observation identifier on the same structured record.
  Variable status-bar layout recognition requires left-clock and right-battery candidates in expected geometry on at least two source images.
  Clocks, battery-shaped numbers, and percentages remain reviewable even in status-like geometry because they can be workout timers or intensity targets.
  Only explicit interface and network tokens may be removed automatically.
  Programming, headings, catalog movements, and unknown narrow edge fragments remain reviewable content.
- [ ] AC-5: The source document is split into stable, bounded sections before provider interpretation, and each section carries only its observations, minimal document context, and bounded catalog hints.
- [ ] AC-6: Starting an import creates an authenticated, idempotent server job and returns promptly after durable handoff so server processing can continue when the phone sleeps or the app is suspended.
- [ ] AC-7: The server processes sections with bounded concurrency, stores each validated section result independently, never repeats a completed section, and exposes privacy-safe progress through an authenticated status callable.
- [ ] AC-8: A failed section is retried independently with exponential server retry policy, and a structured-output validation failure receives at most three targeted repairs containing only that section, the latest invalid flat IR, and a fixed validator diagnostic.
  An incomplete-provenance diagnostic includes the exact missing request-local observation aliases without logging aliases, durable identifiers, or workout content.
  Exhausted repair preserves that section's recognized text for explicit review rather than returning no workout.
- [ ] AC-9: Provider input, output, record counts, section counts, deadlines, and token limits are bounded.
The output-token allowance is computed per section and clamped between 2,048 and 8,192 tokens instead of using the previous 32,768-token allowance.
- [ ] AC-10: When all sections validate, deterministic application code assembles them in source order into the existing `ParsedWorkoutDocument`, validates the full document, and preserves workout notes, block notes, groups, choices, rests, exercises, sets, metrics, intensity targets, and source observation provenance.
- [ ] AC-11: If deterministic final assembly discovers a cross-section relationship problem, the server preserves validated structured sections beside OCR-only review sections, adds a fixed boundary warning, and never asks the model to regenerate the entire workout.
- [ ] AC-12: The iOS parser adapter supports start, status, resume, and cancel operations while retaining the existing `WorkoutParsing` result boundary and keeping the legacy synchronous callable available for older app builds.
- [ ] AC-13: The import screen shows contextual page and section progress, remains cancellable, explains that processing can continue after the app closes once handoff completes, and uses the established review editor when complete.
- [ ] AC-14: Recoverable connectivity or provider failure preserves completed local and server work, offers retry, automatic resume, or an explicit status refresh from recognized-text review, and never deletes the user's source state merely because one attempt failed.
  A refresh keeps the current editable draft while the server is pending or unreachable and replaces it only when the completed server result is ready.
- [ ] AC-15: Import logs contain a generated job identifier, fixed stage and reason codes, counts, bounded timings, attempt numbers, and model metadata, but never contain OCR text, source observation identifiers, workout content, provider output, filenames, images, or user-entered notes.
- [ ] AC-16: Server job creation and status access are scoped to the authenticated user, reject foreign job identifiers, enforce App Check according to the existing environment policy, apply request and daily limits idempotently, and expire job data automatically.
- [ ] AC-17: Cancellation is cooperative on-device and idempotent on the server, prevents new provider work from starting, retains no source images remotely, and eventually deletes server job artifacts.
- [ ] AC-18: The representative five-image Bayens Method workout imports successfully and preserves long notes, Minimum Effective Dose, Performance Layer, Maximum Daily Volume, Echo Bike, Dual Dumbbell Push Press, Sled Pull, Deadlift plus Lateral Burpee Over Barbell, bodyweight and race-weight qualitative targets, and editable blank load fields where numeric loads are unknown.
- [ ] AC-19: The implementation records stage timings and payload sizes so performance regressions are measurable, while automated tests use deterministic operation-count and bounded-concurrency assertions rather than flaky wall-clock thresholds.
- [ ] AC-20: The smallest supported iPhone and a current large iPhone remain responsive during image normalization and OCR, and the import UI supports accessibility Dynamic Type, VoiceOver progress announcements, Reduce Motion, and 44-point interactive targets.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Ordered pages checkpoint locally, hand off to a server job, assemble deterministically, and open the ordinary editor. | Swift integration tests, Node orchestration tests, and representative five-image E2E evidence. |
| Loading images | Page-level progress advances while protected normalized files and a manifest are committed atomically. | File-store tests and interrupted-normalization restart test. |
| Recognizing text | At most the configured OCR operations run concurrently and completed pages survive cancellation, suspension, or relaunch. | Bounded-concurrency recognizer test and checkpoint restoration test. |
| Waiting for handoff | The app keeps the durable local checkpoint and retries authenticated job creation without rerunning OCR. | Offline handoff and idempotency tests. |
| Processing sections | The app polls resumable server progress and explains that processing can continue after the app closes. | Parser adapter tests and simulator evidence. |
| App backgrounded or phone asleep | The server job continues after durable handoff, and the app fetches current progress when active again. | Backend job test plus lifecycle resume test. |
| One empty OCR page | The page is marked unreadable and review receives a warning, while readable pages continue. | Partial-page OCR test. |
| Every page unreadable | The import fails locally with a clear source-quality message and no server request. | Empty-document boundary test. |
| Recoverable section failure | Only the failed section retries, completed section attempts remain unchanged, and progress resumes. | Fault-injection orchestration test. |
| Invalid structured output | Up to three targeted repairs are attempted for that section within the four-call ceiling, then its recognized text remains available in an explicit review section if validation still fails. | Repair isolation, persisted repair-resume, OCR fallback, and provider call-count tests. |
| Offline after handoff | Server work continues. Recognized text remains reviewable immediately, and the user can check the durable server job again without repeating OCR or losing current edits. | Polling recovery, fallback refresh, and lifecycle tests. |
| Cancelled | No new work starts, local protected files are removed, and server cancellation is idempotent. | Cancellation race tests. |
| Expired | Old local and server artifacts are removed without affecting saved templates. | TTL cleanup tests. |
| Legacy client | The existing synchronous callable still returns `ParsedWorkoutDocument`. | Backward-compatibility endpoint test. |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | Protected checkpoint round-trip and atomic replacement tests | Proves the local record is stable, versioned, protected, and never partially written. |
| AC-2 | Relaunch restore, foreground resume, save cleanup, cancel cleanup, and expiry tests | Proves completed local work survives lifecycle changes and is removed only at defined boundaries. |
| AC-3 | Deterministic observation ID, ordered bounded-concurrency OCR, partial empty page, and all-empty tests | Proves predictable OCR behavior without batch-wide failure. |
| AC-4 | Repeated-chrome, shifted repeated-programming, repeated coaching-cue, and provider-consolidation fixtures | Proves deterministic cleanup removes only explicit interface artifacts, preserves ambiguous repeated content, and allows semantic consolidation without losing provenance. |
| AC-5 | Stable section ID, section size, minimal-context, repeated status-bar layout, edge-fragment preservation, and provenance fixtures | Proves deterministic bounded provider inputs without discarding real top-edge programming or unknown clipped content. |
| AC-6 | Idempotent start and asynchronous handoff integration tests | Proves server processing no longer depends on a foreground client request. |
| AC-7 | Owner-only status, bounded section concurrency, and completed-section cache tests | Proves section work is durable, isolated, and not repeated. |
| AC-8 | Provider timeout, transient failure, invalid IR, exact missing-alias provenance repair, privacy-safe diagnostics, three-stage targeted repair, persisted repair resume, and repair-ceiling fault injection | Proves only the affected section retries and repairs, that provenance repairs receive actionable opaque identifiers, and that a repair-created validation error can be corrected without unbounded regeneration. |
| AC-9 | Dynamic token budget and payload limit tests | Proves each provider request has a proportional hard ceiling. |
| AC-10 | Multi-section deterministic assembly and full document validation tests | Proves the established response contract and all supported semantics survive section boundaries. |
| AC-11 | Mixed-result cross-section assembly fault injection with exact structured/fallback nodes, provenance, boundary warning, and section-only provider call-count assertions | Proves assembly errors preserve successful structure and cannot trigger whole-document regeneration. |
| AC-12 | Parser start, status, resume, cancel, legacy fallback, and response-compatibility tests | Proves the client adapter changes transport without changing the editor-facing result. |
| AC-13 | Simulator screenshots of page progress, handoff, section progress, cancellation, and review | Proves contextual progress uses the established import experience. |
| AC-14 | View-model relaunch, offline handoff, polling recovery, recognized-text review refresh, and completed-work retention tests | Proves recoverable failures do not erase progress and a completed server result can replace fallback only through an explicit refresh. |
| AC-15 | Privacy-canary serialization tests across every structured log event | Proves sensitive content cannot enter operational telemetry. |
| AC-16 | Authentication, ownership, App Check metadata, daily-limit idempotency, and TTL tests | Proves access control, abuse limits, and expiration. |
| AC-17 | Cooperative cancellation race, idempotent server cancellation, cleanup tests, and local deletion fault injection when tombstone persistence fails | Proves cancellation prevents new work, removes protected local sources even when remote bookkeeping fails, and eventually removes server artifacts when a tombstone is available. |
| AC-18 | Representative Bayens Method section IR fixture and full deterministic assembly regression | Proves the previously failing workout semantics and qualitative targets survive section boundaries. |
| AC-19 | Operation-count, concurrency-high-water, payload-size, and stage-timing instrumentation tests | Proves performance is measurable without timing-sensitive unit tests. |
| AC-20 | Accessibility inspection, VoiceOver labels, Dynamic Type, Reduce Motion, and main-thread responsiveness evidence | Proves inclusive interaction quality on supported devices. |

## UX evidence

- Inspect the smallest supported iPhone and a current large iPhone at default and accessibility Dynamic Type.
- Capture local page recognition, durable server handoff, section processing, background-and-resume, recoverable failure, cancellation, and completed review states.
- Verify that progress labels describe the current user-facing outcome rather than internal AI or networking terminology.
- Verify that an unfinished import is restored without a blocking alert and offers a clear `Continue import` or `Start over` choice when automatic continuation is not possible.
- Verify that source images remain collapsed at the top of review and exact crops appear only for actionable issues.
- Run VoiceOver through progress, retry, cancel, resume, source gallery, and final review controls.
- Verify Reduce Motion and accessibility contrast behavior with the existing Baseline design tokens.

## Risk and rollout

- Data migration: no canonical workout migration is required because the final `ParsedWorkoutDocument` and materialized template formats remain unchanged.
- Local persistence: transient import checkpoints use versioned Codable records behind a repository boundary, complete file protection, atomic writes, backup exclusion, and a 24-hour expiry policy.
- Backend persistence: import jobs use private Admin SDK access and store only bounded OCR observations, section status, validated flat IR, diagnostics, and final structured output.
- Backward compatibility: the legacy synchronous callable remains deployed while the new start, status, and cancel callables are additive.
- Provider compatibility: section planning, validation, retries, repair diagnostics, and assembly remain provider-independent.
- Privacy/security: source image bytes never leave the device, and logs are limited to allowlisted operational fields.
- Abuse/cost: idempotency prevents duplicate daily-limit charges, section and attempt limits bound provider spend, and expired jobs are deleted.
- Analytics: operational stage timings and counts are emitted without workout content.
- Feature flag: the new parser adapter can fall back to the legacy callable for rollout safety until the asynchronous endpoints pass staging evaluation.
- Rollback: disable the asynchronous adapter and retain the additive backend endpoints until active jobs expire.
- Deployment order: deploy and validate backend endpoints first, then enable the client adapter, then run a real-device import and retain the legacy callable through at least one released-client compatibility window.

## Human gates

- Production Firebase deployment and production App Check enforcement remain release actions.
- No dependency changes are planned.
