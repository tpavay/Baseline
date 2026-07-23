# Live Heart Rate — Go-Live Wiring

Slice 3 shipped the live HUD (`LiveHeartRateView` + `HeartRateZoneGauge`) as a standalone,
fully-previewed component with **no live call site**: nothing in the running app constructs a
`HeartRateMonitor`, starts monitoring, or opens a BLE connection.
This document is the ordered, owner-performed checklist to drop the HUD into the active-workout
surface and turn it on.

It is deliberately separate from the feature slices because the workout-execution views
(`StructuredWorkoutView`, `WorkoutView`, `WorkoutModel`) are uncommitted owner WIP; wiring here would
have collided with that work.
Do these steps once that surface is stable.

## What already exists (built, tested, dormant)

- `HeartRateZoneModel` — pure zone boundaries (Karvonen / %max, Tanaka default). Slice 1.
- `BluetoothManager` `.live` intent + `LiveHeartRateSource` conformance — the single-strap BLE
  streaming path, mutually exclusive with the resting-HRV `reading` path (enforced in Slice 1). Slice 1.
- `HeartRateMonitor` — `@MainActor @Observable` facade: `currentBPM`, `currentZone`, `freshSample`,
  `sensorContact`, `connectionStatus`, `startMonitoring()` / `stopMonitoring()`, per-run `zoneTime`
  accumulation, and per-run session aggregates `averageBPM` / `maxBPM` / `sessionElapsed` (feeding the
  HUD's AVG · TIME · MAX row) — all via an injected clock. Slice 1 + Slice 3.
- `HeartRateZoneSettingsStore` — persists the athlete's max/resting/LTHR and vends a
  `HeartRateZoneModel`. Slice 2.
- `LiveHeartRateView` / `HeartRateZoneGauge` / `LiveHeartRateStateResolver` — the HUD, its
  semicircular Z1→Z5 zone gauge wrapping the BPM number, and the honest state mapping. Slice 3, then
  redesigned (issue #65: proportional gauge segments, a pulsing current-position marker, a zone-name
  line, and a TIME IN ZONE breakdown fed by the monitor's `zoneTime`). `LiveHeartRateView` binds to
  any `LiveHeartRateProviding`; `HeartRateMonitor` is the production conformer.

## Ordered steps

1. **Build the monitor from settings.**
   At the point the workout-execution surface is constructed (e.g. in `WorkoutModel` or the owning
   coordinator), read the athlete's zone model from the injected `HeartRateZoneSettingsStore`
   (`store.zoneModel`) and construct one `HeartRateMonitor(source: bluetoothManager, zoneModel:)`
   using the app's existing shared `BluetoothManager`.
   Do **not** create a second `BluetoothManager` — the live and reading paths share the one paired
   strap, and Slice 1's intent guard assumes a single central.

2. **Place the HUD in the execution surface.**
   Add `LiveHeartRateView(provider: monitor, targetZones: session.plannedTargetZones)` to the
   active-workout layout (`StructuredWorkoutView` / `WorkoutView`), above the fold where the athlete
   glances during work intervals.
   `targetZones` is a `ClosedRange<Int>?` so a session can target a **single zone** (map the existing
   `targetZone: Int?` to `n...n`) or a **range** ("live in Z1–Z2"); pass `nil` when the segment has no
   HR target. Target display is currently **held** (issue #65): the parameter is accepted but **not
   rendered** — every caller passes `nil` today, and the value only reaches the gauge's accessible
   summary. Re-enabling a target cue is a separate feature.
   The view only reads the monitor — it never starts it.

   HUD design decisions (from the design review, as shipped after the issue-#65 redesign):
   - The hero is a **semicircular Z1→Z5 zone gauge wrapping the big BPM number**; each segment's arc
     length is **proportional to that zone's BPM span** in the athlete's configured `HeartRateZoneModel`
     (not equal fifths), with a **pulsing current-position marker** at the live BPM angle.
   - The big BPM number is **tinted with the current zone's color**, and the **zone name** ("Z3 ·
     AEROBIC") sits on the context line below the gauge while streaming normally.
   - Under that is an **AVG · TIME · MAX** row of session aggregates, which **persist through a
     dropout** (they summarize recorded samples; only the live number blanks when stale).
   - At the bottom, a **TIME IN ZONE** breakdown (a stacked bar plus per-zone percents, fed by the
     monitor's `zoneTime`) appears only once real zone time has been credited — never a fabricated
     all-zero split.
   - The connection status line shows **only** on a real sensor/signal issue (`sensorOff`, `noSignal`,
     `reconnecting`, `disconnected`, `connecting`); a healthy stream shows the zone name instead.
   - `sensorOff` **shows the (flagged) number** with an amber "sensor not detecting contact" warning
     rather than hiding it; `noSignal` / `reconnecting` / `connecting` / `disconnected` show no number.

3. **Start monitoring at session start; stop at session end.**
   When the session begins, call `monitor.startMonitoring()`. It calls the live source's
   `startLiveMonitoring()`, which enters the `.live` intent and, in `BluetoothManager.execute()`,
   reconnects to the remembered strap (`savedDeviceID`) automatically — or scans for the first strap
   when none is saved — so a previously-paired strap reconnects without a picker.
   When the session ends or is cancelled, call `monitor.stopMonitoring()`.
   **This is the first place the CoreBluetooth connect/subscribe lifecycle runs on a device** — verify
   permissions, background modes, and the connect timeout here, on real hardware.

4. **Persist zone-time with the session log.**
   On session completion, read `monitor.zoneTime` (seconds-in-zone) and write it into the session's
   completed record alongside the rest of the log, so it can feed history and future adaptation.
   Follow the Firestore schema-change rule if this adds a persisted field: update `firestore.rules`
   (strict `hasOnly` + `hasAll`) before/with the app.

5. **Respect the live/reading mutual exclusion.**
   The resting-HRV reading path and the live path both drive the one strap and are mutually exclusive
   (Slice 1). Do not start live monitoring while a reading capture is active (and vice versa); gate on
   the shared `BluetoothManager` intent.

## Verification at go-live

- On device: pair a strap, start a session, confirm the BPM number and marker track the strap; walk
  out of range and confirm the HUD degrades to `noSignal` / `reconnecting` (never a frozen stale
  number); remove the strap and confirm `sensorOff`.
- Confirm zone-time is persisted and matches the session duration within the freshness tolerance.
- Re-run the full suite; add a workout-surface integration test if the placement introduces new
  presentation logic (the HUD's own logic is already covered by the Slice-3 tests).
