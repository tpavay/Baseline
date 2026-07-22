# Feature Contract: Wave 4 Conversational Workout Editing

- Issue: #45
- Base branch: `develop`
- Change type: feature
- Owner: orchestrator

## User outcome

Baseline can add, update, remove, move, and duplicate planned sets by stable ID, edit set metrics and logging units by stable exercise and set IDs, and undo every successful mutation through the existing versioned mutation envelope.

## Non-goals

- Do not add Wave 5 block or exercise structure tools.
- Do not add Wave 6 performed-set logging tools.
- Do not change canonical stored metric values when changing display or entry units.
- Do not bypass the existing Wave 1 targeting, Wave 2 receipt and undo, or Wave 3 three-state patch infrastructure.

## Acceptance criteria

- [x] AC-1: `add_set` inserts a validated planned set for an exercise instance, optionally after a set ID, and returns an undoable Wave 2 receipt.
- [x] AC-2: `update_set` targets a set ID and supports omitted, set, and explicit clear semantics for supported values, roles, and targets.
- [x] AC-3: `remove_set` targets a set ID and preserves the live-session logged-actual purge safeguard.
- [x] AC-4: `move_set` reorders a set by `before_set_id` or `to_index` with complete target and range validation.
- [x] AC-5: `duplicate_set` creates a deep copy with fresh set and alternative IDs.
- [x] AC-6: Metric and logging-configuration tools accept exercise instance and set IDs, expose pace units, and describe `heartRateZoneTime`.
- [x] AC-7: Changing a metric display unit modifies `displayUnits` only and leaves canonical stored metric values unchanged.
- [x] AC-8: Every successful Wave 4 mutation returns a Wave 2 receipt and can be undone without affecting later unrelated mutations.
- [x] AC-9: Invalid roles, ranges, targets, IDs, insertion positions, and explicit clears are rejected before persistence.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | A valid ID-targeted mutation persists once and returns a receipt with a new revision token. | Focused mapper, domain, and tool-envelope tests. |
| Loading | Not applicable: these domain tools have no independent loading UI. | Not applicable. |
| Empty | Missing exercises, sets, values, or invalid clear operations return a correctable validation failure without persistence. | Invalid-input tests. |
| Error/offline | A failed or stale mutation returns the existing envelope error and leaves the authoritative workout unchanged. | Existing Wave 2 envelope tests plus Wave 4 invalid-input tests. |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | Wave 4 agent tool add-set test. | Verifies ID targeting, insertion placement, receipt creation, and undo. |
| AC-2 | Wave 4 update-set patch tests. | Verifies omitted, set, clear, and validation semantics by set ID. |
| AC-3 | Live-session removal safeguard test. | Verifies matching performed rows are purged through the protected store path. |
| AC-4 | Workout set move domain and tool tests. | Verifies both placement forms and boundary rejection. |
| AC-5 | Workout set deep-copy domain and tool tests. | Verifies semantic equality and regenerated nested identities. |
| AC-6 | Tool schema and mapper tests. | Verifies ID fields, pace-unit support, and `heartRateZoneTime` schema coverage. |
| AC-7 | Display-unit immutability test. | Verifies only `displayUnits` changes while canonical values remain byte-for-byte equal. |
| AC-8 | Receipt-backed undo tests for all Wave 4 operations. | Verifies every successful operation uses the shared mutation envelope. |
| AC-9 | Parameterized invalid-input tests. | Verifies validation occurs before persistence for every new input family. |

## UX evidence

Not applicable: this wave changes conversational tool contracts and domain behavior without adding or materially changing a visual interface.

## Risk and rollout

The change is backward compatible at the persisted-model layer and requires no data migration, analytics change, privacy update, feature flag, or external deployment ordering.
The main risks are stale or ambiguous targets, accidental performed-log loss, invalid prescription state, and unit conversion corrupting canonical values.
Stable IDs, pre-persistence validation, the existing live-session purge safeguard, immutable canonical values, receipt-backed undo, and focused regression tests mitigate those risks.
Rollback is a code rollback because no persistent schema is added.

## Human gates

- None.
