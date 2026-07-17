# Feature Contract: Live Heart Rate Slice 1 — zone model + live monitor (headless)

- Issue: #10
- Base branch: `feature/issue-2-workout-image-import`
- Change type: feature
- Owner: orchestrator

Base note: branched from integration tip `a3fdcb4`. `main` remains stale (recorded in #4).

## User outcome

No visible change yet. The app gains the tested headless core for live heart-rate zones: a pure
Z1–Z5 zone model (Karvonen/HRR or %max-HR, max HR from Tanaka or a user value), a live BPM +
sensor-contact stream from the already-paired strap via a new `BluetoothManager` live mode, and a
`HeartRateMonitor` facade exposing current BPM, current zone, freshness, and accumulated zone-time —
the foundation for the settings (Slice 2) and the in-workout UI (Slice 3).

## Non-goals

- No UI (settings = Slice 2; live-HR view = Slice 3).
- No workout-execution-view changes (`StructuredWorkoutView`/`WorkoutView`/`WorkoutModel` are owner
  WIP; wiring is the go-live step).
- No change to the existing HRV **reading** path or R-R/HRV logic; the `reading` intent and its tests
  are untouched.
- No new BLE permissions (`NSBluetoothAlwaysUsageDescription` already present); no second
  `CBCentralManager`.
- No persistence yet (zone-time lives in memory on the facade; a per-session record is Slice 2).
- Existing tests are not modified, weakened, or deleted.

## Acceptance criteria

- [ ] AC-1: `HeartRateZone` has cases z1…z5 (CaseIterable, ordered), each with a `displayName` and a
      design-system color token name; ordering z1<…<z5 holds.
- [ ] AC-2: `HeartRateZoneModel.zone(forBPM:)` returns the correct zone against **hand-computed**
      boundaries: Karvonen/HRR (`target = restingHR + fraction·(maxHR − restingHR)`) when `restingHR`
      is present, else %max-HR fractions; boundaries come from one centralized tunable table.
- [ ] AC-3: `position(forBPM:)` returns a monotonic 0→1 value across the full Z1→Z5 span (for the UI
      marker), clamped at the ends, consistent with `zone(forBPM:)` (the position's zone bucket equals
      the returned zone).
- [ ] AC-4: Max-HR derivation: with no user max, `HeartRateZoneModel(age:)` uses Tanaka
      (`208 − 0.7·age`, rounded), age bounded to [13,120], fallback age 35 when nil; a user-supplied
      max overrides Tanaka.
- [ ] AC-5: `BluetoothManager` gains a `.live` intent and publishes a live BPM + sensor-contact value
      parsed from the standard 0x2A37 notifications; entering `.live` and returning to `.idle` does
      not disturb the `reading` path. Existing `BluetoothManager`/reading tests pass unmodified.
- [ ] AC-6: `HeartRateMonitor` exposes `currentBPM`, `currentZone` (via an injected
      `HeartRateZoneModel`), `sensorContact`, and `freshSample` — where a sample older than the
      freshness window (~5 s, tunable) is treated as absent (BLE gives no signal-lost push). Proven
      with an injected clock.
- [ ] AC-7: Zone-time accumulation: feeding a timed sequence of BPM samples yields correct
      seconds-in-zone per zone (injected clock; boundary crossings attributed correctly); no wall-clock
      or real sleeps in tests.
- [ ] AC-8: No behavior change in the running app: full existing suite passes unmodified; the new
      types are referenced only within the new HeartRate module and tests; no workout/profile/app
      construction site starts the monitor.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Strap streaming → currentBPM + currentZone update, zone-time accrues | AC-5/AC-6/AC-7 |
| Loading | Between samples within freshness window → last sample retained | AC-6 |
| Empty | No sample / sample older than freshness window → `freshSample == nil`, currentZone nil | AC-6 |
| Error/offline | Sensor contact not detected → surfaced on the sample; monitor stays honest | AC-6 |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `HeartRateZoneTests` ordering/displayName cases | Enum shape asserted |
| AC-2 | `HeartRateZoneModelTests` Karvonen + %max boundary cases | Zone pinned to hand-computed thresholds |
| AC-3 | `HeartRateZoneModelTests` position monotonicity + zone-consistency | 0→1 marker vs zone bucket |
| AC-4 | `HeartRateZoneModelTests` Tanaka + user-override + bounds cases | Max-HR derivation exact |
| AC-5 | `BluetoothManagerLiveTests` (fixture 0x2A37 data) + existing reading suite green | Live parse without disturbing reading |
| AC-6 | `HeartRateMonitorTests` freshness with injected clock | Stale → absent, fresh → present |
| AC-7 | `HeartRateMonitorTests` zone-time sequence cases | Seconds-in-zone hand-computed |
| AC-8 | Full suite green; reference grep; no monitor start site | Isolation |

## UX evidence

Not applicable: headless slice, no user-facing behavior.

## Risk and rollout

- **Data migration:** none.
- **Backward compatibility:** `BluetoothManager` gains an additive `.live` intent; the `reading`
  path and `HeartSignalSource` reading API are unchanged.
- **Privacy/security:** on-device; no new permission; no health values logged.
- **Analytics/flags:** none.
- **Rollback:** revert branch; nothing starts the monitor.
- **Deployment order:** behind Slices 2–3 and the go-live wiring.

## Human gates

- None.
