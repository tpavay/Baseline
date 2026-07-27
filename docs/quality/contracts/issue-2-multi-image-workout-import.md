# Feature Contract: Ordered multi-image workout import with note-aware parsing

- Issue: #2
- Base branch: `develop`
- Change type: feature
- Owner: orchestrator

## User outcome

An athlete can select up to 10 workout photos in reading order and land in Baseline's ordinary workout editor with one editable Workout Template whose structure, metrics, qualitative targets, and notes preserve the source meaning across image boundaries. Source photos remain available on demand without interrupting workout review.

## Non-goals

- PDF, video, live camera, handwriting guarantees, and multi-day program import remain out of scope.
- The parser does not persist source photos, silently create custom exercises, or write directly into a scheduled workout.
- The feature does not remove the existing single-image paste workflow.
- Import review does not infer a numeric load from qualitative prescriptions such as bodyweight or race weight.

## Acceptance criteria

- [ ] AC-1: Photos import accepts 1 through 10 selected images, respects the user's selected order, and makes every normalized source image available in an on-demand gallery during review.
- [ ] AC-2: OCR observations retain their zero-based source image index through the callable payload so parsing and evidence crops cannot confuse coordinates from different images.
- [ ] AC-3: The parser contract distinguishes workout-level and block-level prose from exercise prescriptions and preserves long notes without converting prose-only lines into exercises.
- [ ] AC-4: Parsed workout, block, group, and exercise notes materialize into canonical `CoachGuidance`, remain editable in import review, and survive template encode/decode.
  *(Superseded by issue #79: workout, block, and group prose now folds into the one `Workout.goal` note; only exercise notes become `CoachGuidance`. See `docs/implementation/workout-image-import.md`.)*
- [ ] AC-5: Selecting zero images, more than 10 images, an unreadable image, or a batch with no readable workout text produces a clear failure and does not save a partial template; a text-free page inside an otherwise readable batch continues to review with an explicit warning.
- [ ] AC-6: Source image bytes remain local, use complete file protection while temporary, and are removed on cancel or successful save; only bounded OCR observations are sent to the callable parser.
- [ ] AC-7: Single-image Photos and paste imports keep working through the same ordered-image pipeline.
- [ ] AC-8: A valid model document inside up to two allowlisted, unambiguous envelopes is normalized without a second provider call. One structural repair is allowed only when its explicit 75-second provider budget fits inside the 180-second callable deadline, and the iOS client waits longer than that server deadline.
- [ ] AC-9: If provider output fails structural validation, each failed attempt emits only a fixed validator code, a schema-derived path containing bounded numeric indexes, and bounded type/count metadata; diagnostics never contain OCR text or IDs, workout content, model output, raw keys, filenames, or images.
- [ ] AC-10: After parsing, the athlete edits the imported workout through the same flat workout editor, exercise ellipsis menu, metric sheet, unit sheet, replacement flow, and add/remove controls used by manually created workouts; ordinary matched exercises show no correctness badge or inline source crop.
- [ ] AC-11: An import issue can open the exact supporting source crop on demand, while the default review hierarchy shows the workout rather than repeated image snippets.
- [ ] AC-12: Qualitative load prescriptions such as `bodyweight` and `race weight` preserve a structured load target, enable an empty editable load metric, and never fabricate a numeric load.
- [ ] AC-13: Lettered programming preserves structure losslessly: `A & B` means alternating required stations, while `B. Deadlifts + lateral burpees` keeps both ordered exercises and does not become an `or` choice or an invented exercise name.
- [ ] AC-14: Echo Bike and Dual Dumbbell Push Press resolve to their own catalog identities rather than Stationary Bike or Dumbbell Bench Press.
- [ ] AC-15: Exercise identity remains canonical while an optional workout-specific display label can be edited independently and survives encode/decode.
- [ ] AC-16: `Fix with Baseline` opens the existing validated workout-edit assistant against the transient imported draft, and its edits remain visible, editable, and undoable through the normal workout editor before save.
- [ ] AC-17: After readable OCR exists, provider unavailability, invalid model output, exhausted repair, or cross-section assembly failure still reaches import review with every recognized line preserved in clearly marked editable `Needs review` sections; successful sections remain structured and no fallback text is silently treated as a prescribed exercise.
  If a durable server job is still running after a status transport failure, fallback review remains explicitly refreshable without repeating OCR or replacing user edits unless the completed server result is ready.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Ordered images become one reviewable template with notes at the correct semantic level. | Swift builder/view-model tests, callable validation tests, simulator review evidence. |
| Loading | UI reports local text recognition followed by template construction and remains cancellable. | Existing state transition tests plus simulator inspection. |
| Empty | Zero selected images is rejected before OCR and no draft is created. | View-model boundary test. |
| Source failure | Missing or unreadable source images show an actionable failure. A batch with no readable workout text fails, while one text-free page inside an otherwise readable batch continues with an explicit warning. | View-model source failure and mixed-batch tests. |
| Model error/offline | Once readable OCR exists, unavailable or invalid model output produces a reviewable OCR-backed draft with explicit warnings instead of an empty terminal error. A still-running server job can be checked again from review. | Runtime fallback tests and coordinator offline fallback and refresh tests. |
| Maximum selection | Exactly 10 ordered images are accepted; an 11-image programmatic request is rejected. | Pipeline boundary test. |
| Long notes | Multi-paragraph workout and block notes remain prose and are not counted as exercises. | Swift builder test and callable validator/prompt-contract test. |
| Cancellation | Active work stops and all temporary images for the session are removed. | File-store test and cancellation inspection. |
| Review | The parsed draft appears as a normal flat workout editor with sources and issue crops available on demand. | Shared editor inspection and simulator evidence. |
| Qualitative load | Bodyweight/race-weight targets show a blank load field plus a structured target. | Builder and presentation formatter tests. |
| Ambiguous structure | Real alternatives remain choices; required A/B and `+` sequences remain groups/exercises. | Parser prompt/validator tests and Swift builder fixture. |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `WorkoutImportViewModelTests.importsImagesInSourceOrder`; simulator source preview | Captures ordered recognizer input and verifies all sources reach review. |
| AC-2 | `WorkoutTextObservationTests.roundTripsSourceImageIndex`; callable payload test | Proves page identity survives Codable and server validation. |
| AC-3 | Callable validator test for document/block notes and prompt-contract assertions | Proves the response schema accepts bounded long notes and tells the model how to classify prose. |
| AC-4 | `WorkoutImportTests.materializesAndRoundTripsNotesAtEveryLevel` | Verifies canonical guidance and backward-compatible Codable behavior. |
| AC-5 | View-model empty/limit/failure tests | Verifies invalid batches fail atomically before save. |
| AC-6 | Temporary-file batch removal test and payload shape inspection | Verifies protected local lifecycle and the absence of image bytes from the remote contract. |
| AC-7 | Existing builder tests plus `importImage` convenience-path test | Proves the single-image entry point delegates without changing behavior. |
| AC-8 | Provider call-count, envelope-boundary, repair-budget, endpoint-metadata, and iOS timeout propagation tests | Prevents a valid wrapped model result from triggering an unnecessary repair call or moving the observed gateway timeout to another layer. |
| AC-9 | Typed diagnostic path tests, initial/repair attempt-sequence test, and privacy-canary log serialization test | Distinguishes the failing schema boundary while proving sensitive workout/model content cannot enter diagnostic metadata. |
| AC-10 | Shared editor component usage plus `WorkoutStore` edit tests and simulator evidence | Proves import and manual editing invoke the same controls and mutation model. |
| AC-11 | Evidence resolver tests and simulator issue-to-crop evidence | Proves provenance is available without eagerly rendering every crop. |
| AC-12 | Swift builder qualitative-load tests and callable qualitative-metric normalization test | Proves the target is structured, load is enabled, and no numeric value is invented. |
| AC-13 | Callable prompt-contract test plus `WorkoutImportTests.preservesLetteredRequiredStations` | Protects the exact A/B and plus-sign semantics that failed in the representative import. |
| AC-14 | Catalog resolution tests for Echo Bike and Dual Dumbbell Push Press | Prevents unrelated canonical matches. |
| AC-15 | Workout model round-trip and presentation tests | Proves a workout label cannot overwrite exercise identity. |
| AC-16 | Import review-store integration evidence and existing AgentTools mutation tests | Proves chat mutations use validated operations against the draft rather than direct model writes. |
| AC-17 | Runtime tests for provider outage, invalid repair, output truncation, mixed-result assembly fallback, and assembly failure plus Swift coordinator tests for unreachable Firebase and fallback-to-server refresh | Proves every post-OCR AI failure preserves recognized text and transitions to review without inventing an exercise, while completed structured server work remains recoverable. |

## UX evidence

- Inspect on the smallest supported iPhone simulator and a current large iPhone at default and accessibility Dynamic Type.
- Verify ordered Photos selection copy, multiple-source disclosure, long multiline note editors, loading, failure, and VoiceOver labels.
- Capture a review screenshot with the source gallery collapsed, a long workout, qualitative load targets, and at least one actionable issue; separately capture the gallery and exact issue crop.
- Verify the import editor matches the manual workout editor hierarchy and exercise ellipsis menu.
- No custom motion evidence is required because this change adds no animation or gesture behavior.

## Risk and rollout

- Data compatibility: `guidance` is optional on `Workout` and decoded with a default on `WorkoutBlock`, so existing templates remain readable.
- Data compatibility: the workout-specific exercise display label is optional, so existing templates decode without migration.
- Backend compatibility: deploy the callable schema/prompt before or with the app; old single-image clients remain valid because `sourceImageIndex` defaults to zero server-side.
- Privacy/security: normalized images remain in protected temporary files and never enter Firebase, logs, diagnostics, or parser payloads.
- Abuse/cost: callable validation caps images, observations, OCR characters, catalog hints, output nodes, and note lengths; existing authentication, App Check, and rate limiting remain unchanged.
- Analytics: diagnostics remain counts/timings only and do not add note text or image content.
- Rollback: the client can revert to single-image selection while the additive callable fields remain compatible.
- Feature flag: none; this extends the existing issue #2 importer and keeps its review-before-save gate.

## Human gates

- Firebase callable deployment and production App Check registration remain explicit release actions.
- Final visual acceptance uses representative real workout screenshots because automated OCR fixtures cannot prove real-world photo legibility.
