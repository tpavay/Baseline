# Feature Contract: Provider-independent workout import IR

- Issue: #2
- Base branch: `develop`
- Change type: fix
- Owner: orchestrator

## User outcome

An athlete can import a long, multi-image workout without the import failing merely because the language model produced Baseline's recursive persisted workout shape incorrectly.
The model returns a small flat interpretation, and deterministic application code constructs and validates the existing workout document before the ordinary review flow opens.
When a valid imported power range has a missing or unsupported unit, the review flow offers narrowly scoped, issue-adjacent recovery without redesigning the ordinary workout editor.

## Non-goals

- This increment does not broadly redesign the import review flow, ordinary workout editor, source gallery, image intake, OCR, catalog UI, persistence format, or callable response consumed by the iOS app.
- This increment does not move source photos into workout content or change how the source gallery and source-evidence sheets are presented.
- This increment does not add cross-request import-job persistence, section-level resumability, or a second AI provider.
- This increment does not accept invalid model output or weaken the existing workout document validator.
- This increment does not infer numeric values from qualitative prescriptions such as bodyweight or race weight.

## Acceptance criteria

- [ ] AC-1: The provider is required to return a versioned, flat `WorkoutImportIR` rather than `ParsedWorkoutDocument`, and its strict tool schema stays within the provider's documented schema-complexity limits.
- [ ] AC-2: A deterministic assembler converts valid IR records into the existing `ParsedWorkoutDocument` response without asking the model to construct recursive domain objects.
- [ ] AC-3: The assembler preserves ordered blocks, groups, choices, rests, exercises, sets, metrics, notes, ambiguity, qualitative intensity targets, adjustments, and valid source observation provenance.
- [ ] AC-4: Duplicate record IDs, missing parents, invalid parent-child relationships, cycles, invalid attributes, unsupported units, and configured size limits fail deterministically without returning a partial workout.
- [ ] AC-5: Safe mechanical normalization handles bounded string-number and unit representations, while unknown or unresolved source meaning is retained as text rather than invented as a numeric value or catalog identity.
- [ ] AC-6: The provider request enables native strict schema enforcement, and shape failures no longer trigger whole-document probabilistic regeneration through the former repair path.
- [ ] AC-7: The callable response and iOS decoding contract remain backward-compatible because deterministic assembly still returns `ParsedWorkoutDocument`.
- [ ] AC-8: Privacy-safe diagnostics identify the IR or assembly boundary, attempt, fixed error code, schema-derived path, and bounded type/count metadata without recording OCR text, source IDs, model output, arbitrary keys, filenames, or images.
- [ ] AC-9: Regression tests cover the representative five-image workout semantics, including long notes, required `A` and `B` stations, `Deadlift + Lateral Burpee Over Barbell`, Echo Bike, Dual Dumbbell Push Press, bodyweight load target, race-weight load target, and no fabricated numeric load.
- [ ] AC-10: An unresolved but valid power range offers issue-adjacent `Use watts` and confirmed destructive `Remove target` actions that update the authoritative review store, resolve only the exact selected marker, preserve unrelated edits, and safely rebase duplicate identical markers.
- [ ] AC-11: The recovery actions use Baseline's established text-action styling, retain source access, provide at least 44-point targets, adapt at accessibility Dynamic Type sizes, expose meaningful VoiceOver labels and hints, and require confirmation before discarding the source target.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Flat records deterministically assemble into the existing review document. | IR assembler tests and callable orchestration tests. |
| Loading | Not applicable: this increment does not change client loading behavior. | Existing client behavior remains unchanged. |
| Empty | An IR with no exercises is rejected and no partial document is returned. | Empty-document assembler test. |
| Error/offline | Provider or assembly failure returns the existing actionable import failure without leaking content. | Callable failure and diagnostic tests. |
| Invalid graph | Duplicate IDs, missing parents, cycles, and invalid relationships are rejected deterministically. | Graph validation tests. |
| Qualitative load | Bodyweight and race-weight targets survive while numeric load remains absent. | Representative IR regression test. |
| Unresolved power target | A valid range with a missing or unsupported unit remains blocking until the athlete confirms watts or confirms removal of that exact target. | Authoritative-store reconciliation tests, duplicate-marker mutation test, and targeted simulator accessibility review. |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | Strict schema complexity test | Fails if recursion or optional/union growth makes the provider schema ineligible for strict decoding. |
| AC-2 | Flat IR assembly happy-path test | Proves recursive output is application-owned and deterministic. |
| AC-3 | Full node and metadata round-trip tests | Proves every accepted semantic record reaches the established document validator. |
| AC-4 | Duplicate, orphan, cycle, relationship, unit, and limit tests | Proves malformed graphs fail closed before document construction. |
| AC-5 | Attribute normalization and unresolved-text tests | Proves safe coercions are bounded and unknown meaning is not invented. |
| AC-6 | Provider request contract and call-count tests | Proves strict mode is enabled and whole-document repair is removed. |
| AC-7 | Existing callable and Swift parser tests | Proves the external document contract remains unchanged. |
| AC-8 | Diagnostic serialization privacy-canary tests | Proves diagnostics remain structurally useful and content-free. |
| AC-9 | Representative Bayens Method fixture test | Proves the previously misparsed relationships and load targets are preserved. |
| AC-10 | `duplicateUnresolvedIntensitiesResolveTheSelectedIssueAndRebaseTheRemainingIssue` and `synchronizingOneExternalDuplicateMarkerRemovalKeepsOneBlockingIssue` | Proves the UI-facing methods edit the authoritative store, preserve unrelated changes, resolve the selected issue identity, and retain exactly one blocker when one of two identical markers remains. |
| AC-11 | Final targeted simulator render and accessibility review | Proves the issue-adjacent actions retain source access, remain legible at standard and accessibility Dynamic Type sizes, meet the 44-point target requirement, expose useful VoiceOver labels and hints, and guard destructive removal with a confirmation dialog. |

## UX evidence

Required final evidence is a targeted simulator render of an unresolved power issue showing `Use watts`, `Remove target`, and retained `View source` access in the import review flow.
The render must confirm that the actions are issue-adjacent text controls rather than a broad review redesign or decorative surface.
Accessibility review must cover standard and accessibility Dynamic Type layouts, at least 44-point targets, VoiceOver labels and hints, focus return after the system confirmation dialog, semantic destructive treatment, and the confirmation copy that explains source-intent removal.
The final evidence must also confirm that source photos remain available through the established gallery and evidence sheet rather than being inserted inline with workout content.

## Risk and rollout

- Data migration: none, because neither persisted workout models nor the callable response change.
- Backward compatibility: the iOS client continues receiving `ParsedWorkoutDocument`.
- Privacy/security: strict output and deterministic assembly do not change the bounded OCR-only request or local image lifecycle.
- Provider compatibility: provider-native strict decoding is isolated at the adapter boundary, while IR validation and assembly remain provider-independent.
- Rollback: restore the previous provider adapter and orchestration without changing the client.
- Deployment order: backend tests and live staging evaluation must pass before callable deployment, and deployment remains an explicit human gate.

## Human gates

- Firebase callable deployment requires explicit user approval.
- Any dependency version change requires explicit user approval.
