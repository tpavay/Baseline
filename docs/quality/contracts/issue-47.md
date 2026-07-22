# Feature Contract: Wave 5 conversational workout structure editing

- Issue: #47
- Base branch: `develop`
- Change type: feature
- Owner: orchestrator

## User outcome

An athlete can ask Baseline to add, remove, move, reorder, duplicate, or replace workout blocks and exercises, with every operation targeting stable instance IDs and returning a versioned mutation receipt that can be safely undone when no logged work is lost.

## Non-goals

- Nested parent-container targeting remains a later wave.
- Performed-set logging tools remain Wave 6 work.
- Advanced group, choice, rest, and arbitrary nested-node editing remain Wave 8 work.
- Existing direct-control workout editing behavior remains unchanged.

## Acceptance criteria

- [ ] AC-1: A block can be added at a validated insertion position with optional guidance, removed by block ID, moved by block ID, and duplicated with fresh block, node, exercise, set, and alternative IDs.
- [ ] AC-2: An exercise can be added to a block at a validated insertion position, moved to a destination block and position, removed, reordered within its containing list, duplicated with fresh node, exercise, set, and alternative IDs, and replaced by exercise instance ID.
- [ ] AC-3: Stable instance targeting edits exactly the requested exercise when two exercises have the same display name.
- [ ] AC-4: Every successful operation routes through the Wave 2 mutation envelope, returns a versioned receipt, and supports targeted undo when the mutation is eligible.
- [ ] AC-5: Live-session block and exercise removal uses the purge-aware store path so performed rows for removed exercises cannot remain orphaned.
- [ ] AC-6: A live-session removal that drops logged work either restores that work on undo or returns `undoAvailable: false` without recording a misleading undo entry.
- [ ] AC-7: Invalid UUIDs, missing targets, invalid insertion positions, stale revision tokens, and conflicting identifiers fail without persistence.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | The requested structure mutation persists once and returns an accurate receipt. | Agent tool integration tests and mutation-envelope tests. |
| Loading | Not applicable: these synchronous domain tool handlers have no presentation loading state. | Not applicable. |
| Empty | Missing blocks or exercises produce a correctable validation error without writing. | Mapper and agent tool invalid-target tests. |
| Error/offline | Invalid or stale requests fail before persistence, and persistence errors do not return success receipts. | Mapper, stale-token, and store failure tests. |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | Wave 5 block mutation tests | Exercises every block operation, insertion boundary, fresh duplicate identity, receipt, and undo. |
| AC-2 | Wave 5 exercise mutation tests | Exercises every exercise operation, destination and position validation, fresh duplicate identity, receipt, and undo. |
| AC-3 | Same-named exercise integration test | Proves selection is by exercise instance ID rather than name. |
| AC-4 | Receipt and targeted-undo assertions for every Wave 5 call | Proves all public operations use the shared envelope and restore the exact prior snapshot. |
| AC-5 | Live-session block and exercise removal tests with performed rows | Proves removed instances cannot leave performed rows behind. |
| AC-6 | Live-session logged-work removal receipt tests | Proves the receipt does not promise an undo that cannot restore purged work. |
| AC-7 | Mapper and dispatcher validation tests | Proves malformed, stale, missing-target, and out-of-range requests fail before writing. |

## UX evidence

Not applicable: this wave adds conversation tool contracts and domain behavior without changing visual presentation.

## Risk and rollout

The primary risk is silent live-session data loss or orphaned performed rows, mitigated by mandatory purge-aware store routing and honest undo eligibility tests.
No core workout-data migration, analytics change, privacy change, or security boundary change is required.
The Cloud Function must deploy first because clients explicitly advertise Wave 5 schema support, while clients without that capability continue receiving the Wave 4 schema and tool set.
Wave 5 adds an additive persisted mutation-history payload for complete live-log undo.
A rollback preserves primary workout and performed-log data, but an older app may be unable to decode Wave 5 targeted-undo history created after launch.

## Human gates

- None.
