# Feature Contract: Workout metadata and label tools

- Issue: #42
- Base branch: `develop`
- Change type: feature
- Owner: orchestrator

## User outcome

An athlete can conversationally rename a workout, block, or exercise instance and can set or clear workout, block, and exercise metadata without changing omitted fields.
Every edit targets the revision and stable instance IDs returned by `get_current_workout`, returns a mutation receipt, and remains eligible for the existing targeted undo flow.

## Non-goals

- Do not add per-field metadata tools.
- Do not add a second mutation apply path outside `WorkoutMutationRequest`.
- Do not change the structure of `CoachGuidance` or the manual workout editor.
- Do not add Wave 4 set, metric, or unit mutations.
- Do not retain name-based fallback targeting for these new block and exercise tools.

## Acceptance criteria

- [ ] AC-1: `update_workout_metadata` independently patches title, goal, and guidance through the versioned mutation envelope.
  *(Superseded by issue #79: the workout level now has one note and no `CoachGuidance`, so the tool patches `title` and `note` only. See the workout-note invariant in `CLAUDE.md`.)*
- [ ] AC-2: `update_block_metadata` targets one block by stable block ID and independently patches name, intent, and guidance through the versioned mutation envelope.
- [ ] AC-3: `update_exercise_metadata` targets one exercise by stable exercise instance ID and independently patches display label and guidance through the versioned mutation envelope.
- [ ] AC-4: Every nullable metadata field preserves three states from JSON through the domain write: omitted leaves the field unchanged, a value sets it, and JSON `null` clears it.
- [ ] AC-5: Every successful metadata edit returns a Wave 2 mutation receipt whose targeted undo restores the exact prior workout state.
- [ ] AC-6: Stable ID targeting changes only the requested block or exercise when duplicate names exist.
- [ ] AC-7: Malformed IDs, stale revisions, empty patches, and invalid patch value types reject without writing.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | The requested metadata fields change once, one receipt is returned, and targeted undo restores the prior state. | Mapper, agent tool, and mutation-envelope tests. |
| Loading | Not applicable: metadata mutations execute synchronously against local authoritative state. | Compile-time and architecture inspection. |
| Empty | An empty patch or missing target is rejected without creating a revision. | Mapper and store tests. |
| Error/offline | Malformed input and stale revisions reject without a write; network availability is not required. | Mapper and mutation-envelope failure tests. |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `WorkoutMetadataToolTests/updateWorkoutMetadataReturnsReceiptAndUndoRestoresPriorState` | Exercises workout title, goal, and guidance through the public call and undo path. |
| AC-2 | `WorkoutMetadataToolTests/updateBlockMetadataTargetsDuplicateNameByIDAndUndoRestoresPriorState` | Proves stable block targeting, receipt creation, and restoration. |
| AC-3 | `WorkoutMetadataToolTests/updateExerciseMetadataTargetsDuplicateNameByIDAndUndoRestoresPriorState` | Proves stable exercise-instance targeting, receipt creation, and restoration. |
| AC-4 | `ToolCallMapperTests/mapsMetadataPatchesWithoutCollapsingOmittedAndNull` and `WorkoutMetadataToolTests/nullableMetadataSupportsSetClearAndOmitted` | Proves all three JSON states survive mapping and produce distinct domain outcomes. |
| AC-5 | The three plan receipt tests, `activeSessionMetadataReceiptUndoRestoresOnlySessionWorkout`, and `transientImportMetadataSupportsTargetedUndoAndRejectsStaleUndo` | Proves each supported workout scope returns a receipt and restores only its own prior snapshot. |
| AC-6 | Duplicate-name block and exercise tests | Proves same-name siblings remain unchanged unless their stable ID is targeted. |
| AC-7 | `ToolCallMapperTests/rejectsInvalidMetadataPatches`, `invalidMetadataTargetsAndStaleTokensNeverWrite`, and `discardedSessionRejectsMetadataUndoWithoutWriting` | Proves invalid calls, stale requests, missing targets, and discarded sessions cannot write. |

## UX evidence

Not applicable: this wave exposes conversational domain tools and does not change a visual screen or interaction component.

## Risk and rollout

No persistence schema migration, backend deployment, analytics change, privacy change, feature flag, or third-party dependency is required.
The tools reuse stable IDs, revision tokens, persisted mutation receipts, and targeted undo from Waves 1 and 2, with an in-memory snapshot for the isolated import-review draft.
The primary compatibility risk is collapsing omitted and explicit `null`; typed patch values and end-to-end tests cover that boundary.
Rollback can remove the three tool schemas and call cases without affecting stored workout data or existing mutation history.

## Human gates

- None.
