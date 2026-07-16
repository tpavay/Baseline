# Feature Contract: Photo Import Draft Handoff

- Issue: #2
- Base branch: `develop`
- Change type: fix
- Owner: orchestrator

## User outcome

The athlete selects up to ten ordered workout photos, sees concise progress, and receives a normal editable workout draft containing real blocks and exercises.
The editor never displays raw OCR, parser output, imported-section placeholders, or an empty workout presented as success.

## Non-goals

- Progressive section streaming into an open editor is deferred.
- Import does not automatically create permanent exercise-library entries.
- Import does not change scheduling, workout execution, or logging behavior after Save.
- Source photos are not uploaded to Cloud Storage or retained with the saved workout.

## Acceptance criteria

- [ ] AC-1: A structurally valid complete import opens the ordinary workout editor with blocks, exercises, metrics, notes, and ordering preserved.
- [ ] AC-2: A usable partial import containing at least one valid exercise can be reviewed in the ordinary editor with targeted issues attached to affected workout elements.
- [ ] AC-3: OCR-only, text-only, candidate-only, empty, or structurally invalid results never open the editor and never render raw OCR as workout content.
- [ ] AC-4: Import progress reads `Creating your workout` with the phases `Reading workout`, `Organizing exercises`, and `Preparing editor`.
- [ ] AC-5: Cancel becomes Close only after the import job is durably accepted, and closing does not cancel supported background processing.
- [ ] AC-6: Once the editor opens, late, retried, or replayed import results cannot mutate the user-owned draft.
- [ ] AC-7: Closing the editor before Save preserves the draft so it can be resumed without another import.
- [ ] AC-8: Save commits through the ordinary workout/template path and deletes temporary photos, OCR, candidates, and checkpoints.
- [ ] AC-9: Discard deletes the draft and its temporary import evidence.
- [ ] AC-10: Source photos appear only through a temporary overflow action and never inline with workout content.
- [ ] AC-11: The five supplied Bayens Method fixture images produce at least one valid exercise without a live provider call in deterministic tests and produce a provider response through the deployed-compatible job path in an opt-in smoke test.
- [ ] AC-12: The app builds with Swift 6 strict concurrency for an iPhone simulator and all targeted import tests pass without retries or timing sleeps.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Progress hands one valid draft to the ordinary editor. | Unit, integration, and rendered UI evidence. |
| Loading | Three plain-language phases are visible and VoiceOver-readable. | View-model tests and rendered UI evidence. |
| Empty | No editor opens when no valid exercise exists. | Deterministic builder and handoff tests. |
| Usable partial | Normal editor opens with targeted review issues. | Builder, ownership, and editor integration tests. |
| Error/offline | Evidence and checkpoints remain retryable when safe; no OCR dump is shown. | Coordinator and view-model tests. |
| Editor closed | User-owned draft remains resumable. | Draft repository integration test. |
| Late provider completion | User-owned draft is unchanged. | Ownership race test. |
| Save | Ordinary template is committed and import evidence is deleted. | Repository integration test. |
| Discard | Draft and import evidence are deleted. | Repository integration test. |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | Complete builder and handoff tests | A complete valid graph becomes ordinary draft content. |
| AC-2 | Usable-partial builder and handoff tests | A valid exercise plus localized issues is allowed to hand off. |
| AC-3 | Empty and invalid handoff tests | OCR text and candidates cannot satisfy the handoff gate. |
| AC-4 | Import phase presentation tests | Loading copy derives from the three approved phases. |
| AC-5 | Import close-action state tests | Cancel changes to Close only after durable acceptance. |
| AC-6 | Ownership handoff stale-result test | A result arriving after handoff cannot alter draft revision or content. |
| AC-7 | Draft resume repository integration test | Leaving and reopening returns the same active draft. |
| AC-8 | Draft commit and evidence cleanup integration test | Save persists ordinary content and removes temporary import data. |
| AC-9 | Draft discard and evidence cleanup integration test | Discard removes both active draft and temporary import data. |
| AC-10 | Rendered editor and source viewer evidence | Photos remain subordinate and outside workout content. |
| AC-11 | Five-photo fixture regression plus opt-in backend smoke | The original failing input yields exercises and the production-compatible job returns. |
| AC-12 | Targeted tests, build gate, and flake gate | The final source compiles and tests deterministically. |

## UX evidence

- Render progress, failure, usable-partial, and complete-editor states on a 393-point-wide iPhone.
- Render the editor at the smallest supported iPhone width and at an accessibility Dynamic Type size.
- Verify VoiceOver labels for Close, progress status, targeted issues, Save, Discard, exercise menus, and View Source Photos.
- Verify source photos are absent from the workout scroll content.
- Capture final screenshots or a short simulator recording.

## Risk and rollout

The current import branch contains resumable local manifests and Firebase job documents.
Manifest decoding must remain backward-compatible or explicitly invalidate old jobs without crashing.
No source images may enter logs, Firestore workout records, Cloud Storage, or analytics.
Provider output remains untrusted and passes deterministic validation before draft handoff.
The Firebase functions and rules must be deployed before a phone build relies on new job fields or response shapes.
Rollback must leave ordinary workout drafts and saved templates readable.

## Human gates

- Final physical-device smoke test after the simulator build and automated gates pass.
- Firebase deployment requires explicit approval if server changes are needed for the phone test.
