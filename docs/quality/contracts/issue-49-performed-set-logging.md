# Feature Contract: Wave 6 performed-set logging

- Issue: #49
- Base branch: `develop`
- Change type: feature
- Owner: orchestrator

## User outcome

An athlete can use Baseline conversation to inspect an active session and record, revise, classify, and undo the work they actually performed while the saved workout plan remains unchanged.

## Non-goals

- Do not use planned-workout mutation tools or change `PlannedSet.values` to represent actual work.
- Do not add Wave 9 exercise substitution, choice selection, group progress, note edit or delete, session discard, or retroactive session selection.
- Do not infer a canonical unit from an unqualified dimensional number.
- Do not expose Wave 6 tools to clients that do not advertise the Wave 6 tool schema.

## Acceptance criteria

- [ ] AC-1: `get_active_session` returns the active session, workout log, exercise instance, planned set, group, iteration, performed set, outcome, and revision identifiers needed for precise ID-based targeting.
- [ ] AC-2: `upsert_performed_set` records actual metric values for one planned set, group, and iteration from athlete-provided `value_text`, converts explicit units to canonical storage with `ImportQuantityParser`, and rejects missing, ambiguous, mismatched, unsupported, or unqualified dimensional quantities without writing.
- [ ] AC-3: `set_performed_set_outcome` transitions a targeted planned-set actual among `pending`, `completed`, and `skipped`, including restoration from a handled state to pending.
- [ ] AC-4: extra performed sets can be added, updated, and deleted by stable performed-set ID without affecting planned sets.
- [ ] AC-5: an exercise session note can be appended to the targeted performed exercise.
- [ ] AC-6: every successful performed-log mutation writes once through `WorkoutStore.editLog` and `PlanRepository.updateSessionLog`, appends a persisted `SessionMutationVersion`, and returns a Wave 2 mutation receipt with undo available.
- [ ] AC-7: `undo_session_mutation` restores the stored before-log snapshot only when the current performed-log revision token matches the mutation receipt, and truthfully rejects stale, discarded, missing, or already-undone mutations.
- [ ] AC-8: performed-set logging and undo never mutate the scheduled or session workout plan, including `PlannedSet.values` and workout revision identifiers.
- [ ] AC-9: the Wave 6 server schemas, iOS mapper, model prompt guidance, capability gate, client schema version, and observability prompt and tool schema versions remain synchronized.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Active-session reads and all performed-log mutations return precise payloads and mutation receipts. | `PerformedSetLoggingTests`, `WorkoutMutationEnvelopeTests`, and server schema tests. |
| Loading | Not applicable: the subsystem executes synchronously against local authoritative state. | Code inspection and strict-concurrency build. |
| Empty | No active session returns a correctable no-session result and performs no write. | `PerformedSetLoggingTests`. |
| Error/offline | Invalid quantities, stale revisions, missing IDs, discarded sessions, and persistence rejection return truthful errors without partial writes. Network availability is not required for local mutation execution. | Mapper, store, repository, and facade tests. |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | Active-session snapshot tests | Decode the returned JSON and assert every required identity and state field. |
| AC-2 | Quantity parser, mapper, and performed-set facade tests | Prove `185 lb` and `1:19 per 400 m` convert correctly while bare `185`, mismatched metrics, and ambiguous text do not write. |
| AC-3 | Outcome transition tests | Exercise completed, skipped, and restored pending states on the same planned target. |
| AC-4 | Extra-set CRUD tests | Add, target, revise, and delete a row whose `plannedSetID` is nil. |
| AC-5 | Exercise note test | Assert one exact note is appended to the targeted performed exercise. |
| AC-6 | Repository history and receipt tests | Assert one log revision and one append-only performed-log history row per successful operation. |
| AC-7 | Session undo tests | Assert exact before-snapshot restoration and stale rejection after a later log write. |
| AC-8 | Plan-separation tests | Snapshot scheduled and session workout values and revision identifiers before logging and compare after mutation and undo. |
| AC-9 | TypeScript schema, prompt, gate, observability, and Swift mapper tests | Pin the served Wave 6 contract and its client capability boundary. |

## UX evidence

Not applicable: this wave adds a headless conversational tool subsystem and does not change a screen or visual interaction.

## Risk and rollout

Wave 2 already registered the optional performed-log revision field and session mutation history SwiftData model, so this wave does not require a new data migration.
The client advertises a new monotonic tool schema version so older installed clients continue receiving their prior compatible schema and prompt.
All values remain local performed-log data and no new analytics, health authorization, credential, or privacy collection is introduced.
Rollback is safe because the server capability gate can withhold Wave 6 tools from older clients and the persisted history format is already backward-compatible.
The server schema and prompt must deploy with the client that advertises the new version.

## Follow-ups

- The direct-control `PlanRepository.updateSessionLog(forScheduled:transform:)` path replaces the whole performed log from a bound `WorkoutStore`'s in-memory copy without a revision-token check.
  This is safe today because only one live surface binds a store to the active session: the Plan-tab execution store is recreated on open and the Today UI shares the agent's store, so a stale UI push cannot clobber agent-logged sets.
  If a second concurrently bound store ever becomes reachable, thread the performed-log revision token through `WorkoutStore.PlanSink.pushLog` and reject stale direct writes the same way the receipt-backed `updateSessionLog(forScheduled:request:log:)` overload does.

## Human gates

- None.
