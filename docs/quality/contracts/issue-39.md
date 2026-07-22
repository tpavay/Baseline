# Feature Contract: Versioned workout mutations and targeted undo

- Issue: #39
- Base branch: `develop`
- Change type: feature
- Owner: orchestrator

## User outcome

Every conversational workout edit applies atomically against the workout revision the agent inspected, returns a durable mutation receipt, and can be undone by that exact receipt without reverting later work.
Session-scoped workout and performed-log changes gain a persisted append-only mutation history that can support the same safe undo behavior in later waves.

## Non-goals

- Do not add the Wave 3 and later workout-editing primitives.
- Do not gate ordinary edits behind preview or confirmation.
- Do not implement reverse operations for undo.
- Do not add session or performed-log undo tools before their public mutation tools exist.
- Do not change the manual editor's existing coalescing behavior.

## Acceptance criteria

- [ ] AC-1: Every existing agent plan-editing tool routes through one `WorkoutMutationRequest` apply path that resolves scope, verifies the expected revision, validates before writing, applies to one authoritative workout value, and persists once.
- [ ] AC-2: Every applied agent plan edit creates an immutable workout revision and an append-only `PlanVersion` with actor `.agent`, reason, domain diff, and a persisted mutation receipt.
- [ ] AC-3: Every mutation result returns mutation ID, scope, before and after revision tokens, exact diff, actor, and undo availability.
- [ ] AC-4: `undo_workout_mutation` restores the immediately preceding plan snapshot and appends an undo version only while the mutation's applied revision remains head.
- [ ] AC-5: Targeted undo rejects stale requests after a later edit or conflicting session state and never reverts that later work.
- [ ] AC-6: Session mutation history records session ID, mutation ID, kind, before snapshot, after revision token, actor, timestamp, and diff in append-only SwiftData storage.
- [ ] AC-7: Session mutation history survives repository and store reconstruction from the same persistent container.
- [ ] AC-8: Ordinary edits apply immediately after validation, while the internal envelope supports a non-writing dry-run result for later destructive, bulk, and composite tools.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | The edit writes one version and returns one receipt; targeted undo restores the prior snapshot. | Agent tool, store, and plan mutation tests. |
| Loading | Not applicable: mutations execute synchronously against local authoritative state. | Compile-time and architecture inspection. |
| Empty | A missing workout, scheduled target, mutation receipt, or session returns a correctable not-found result without writing. | Mapper, agent tool, and repository failure tests. |
| Error/offline | Local validation and stale conflicts reject without partial persistence; network availability is not required. | Invalid-input, stale-head, and persistence tests. |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `WorkoutMutationEnvelopeTests/everyExistingWorkoutContentToolUsesTheSharedVersionedEnvelope` | Drives every existing conversational workout-content mutation through the same receipt-producing path. |
| AC-2 | `WorkoutMutationEnvelopeTests/agentEditCreatesVersionedRevisionAndDurableReceipt` | Proves the repository appends both workout and plan revisions with agent metadata. |
| AC-3 | `AgentToolsTests/workoutToolsEditThroughTheStore` and `WorkoutMutationEnvelopeTests` | Proves public mutation responses expose the receipt and persisted versions retain the same value. |
| AC-4 | `WorkoutMutationEnvelopeTests/targetedUndoRestoresSnapshotWhenMutationIsStillHead` | Proves snapshot restoration, append-only undo versioning, and one-shot undo eligibility. |
| AC-5 | `WorkoutMutationEnvelopeTests/targetedUndoRejectsWhenALaterEditIntervened` and `targetedUndoRejectsAsStaleWhenASessionStartsAfterTheEdit` | Proves head-bound stale rejection preserves later work. |
| AC-6 | `WorkoutMutationEnvelopeTests/sessionWorkoutAndPerformedLogHistorySurviveRepositoryReload` | Proves every required history field and exact receipt are stored and reloaded. |
| AC-7 | `WorkoutMutationEnvelopeTests/sessionWorkoutAndPerformedLogHistorySurviveRepositoryReload` | Proves history survives reconstruction through a new repository and model context. |
| AC-8 | `WorkoutMutationEnvelopeTests/dryRunReturnsDiffWithoutWriting` and `staleExpectedRevisionRejectsWithoutAnyWrite` | Proves dry-run and stale validation return without persistence. |

## UX evidence

The chat renders a token-backed "Undo last edit" affordance only while the latest receipt reports that targeted undo is available.
The control uses the existing instrument outline style, has a descriptive accessibility hint, and delegates directly to deterministic receipt-bound undo instead of asking the model to infer a target.

## Risk and rollout

This adds SwiftData schema types, so every production and test `ModelContainer` must register the new model while existing records remain readable.
Receipts and session mutation records contain structured workout and log snapshots but no new categories of sensitive data; they remain local to the existing plan persistence boundary.
The agent route changes from an unversioned content write to `PlanStore.editContent`, so backward compatibility requires manual editor writes and session-only writes to keep their existing destinations.
The stale check and single-write invariant prevent partial or cross-revision mutations.
No analytics, feature flag, backend deployment, or third-party dependency is required.
Rollback can remove the tool exposure while leaving append-only revision records harmlessly unread.

## Human gates

- None.
