# Live Heart Rate & Zones — Implementation Plan

Bring live heart rate from a connected BLE strap into training: while a session runs, show the
current **BPM** and a full **Z1–Z5 colored zone spectrum** (not a single dot), personalized to the
athlete, and record zone-time so it can feed logs and future adaptation. Grounded in the AscendApp
`develop` pattern (PR #196: `BluetoothHeartRateClient` → `HeartRateMonitorService` facade →
`LiveClimbSessionView` chip) but deliberately going further where Baseline is better positioned.

## Grounding decisions (improvements over the Ascend reference)

1. **Reuse Baseline's existing BLE connection; do not build a second CoreBluetooth stack.** Ascend
   built a fresh `BluetoothHeartRateClient` because it had none. Baseline already has
   `BluetoothManager` (single peripheral, standard HR service `0x180D` / measurement `0x2A37`,
   already parsing that characteristic for the HRV reading). We add a **live streaming mode** to that
   manager and layer a `HeartRateMonitor` facade on top — one connection, one pairing, no
   dual-central conflict over the single-slot strap.
2. **Five zones with the conventional blue→red spectrum, not Ascend's three display bands.** Baseline
   already models `targetZone: Int? // 1–5` and `IntensityTarget.heartRateZone(Int)`, and the
   pattern-alignment principle says HR zones use the conventional Z1-blue→Z5-red spectrum. Five zones
   let the live **actual** zone be shown against the **planned target** zone — an integration neither
   app has.
3. **Karvonen / HRR model with honest fallback.** The Profile "Heart Rate Zones — Karvonen / LTHR"
   row is a `.soon` stub; we make it real. Zone boundaries use heart-rate reserve (Karvonen) when
   resting HR is known, fall back to %max-HR bands otherwise, and derive max HR from a user value or
   **Tanaka (208 − 0.7·age)** using the profile's `ageYears`. Optional LTHR anchor is a later refinement.
   Zones are a display/coaching aid — communicate uncertainty, never fabricate precision.
4. **Adopt Ascend's facade robustness.** Keep the parts of `HeartRateMonitorService` that are simply
   correct: a **freshness window** (BLE has no "signal lost" push — silence is the only signal),
   auto-reconnect to the remembered device at session start, a connect timeout, and sensor-contact
   state. Baseline already remembers one strap in `BluetoothManager`, so the facade reuses it.
5. **Headless + previewable now; wire into the live workout at go-live.** The in-workout drop-in
   touches the workout-execution views (`StructuredWorkoutView`, `WorkoutView`, `WorkoutModel`),
   which are in uncommitted owner WIP. So — exactly like the Sleep Engine — we build the engine,
   monitor, settings, and a **standalone live-HR view component** (rendered via previews for review),
   and defer the one-line placement into the active-workout surface to a documented go-live step.

## Existing repository assessment

| Area | Today | This work |
| --- | --- | --- |
| BLE stack | `BluetoothManager` (0x180D/0x2A37), single peripheral, `Intent { idle, scan, reading }`, remembers one strap | Add a `.live` intent + published live BPM / sensor-contact stream; existing reading path untouched |
| Zones | `targetZone: Int?`, `IntensityTarget.heartRateZone(Int)` — static planned text only; no boundaries, no live actual | New `HeartRateZone` (Z1–Z5) + boundary model; live actual zone from BPM |
| Zone settings | Profile row "Heart Rate Zones — Karvonen/LTHR" = `.soon` stub | Real settings screen: max HR (Tanaka default, editable), resting HR, optional LTHR, live preview |
| Profile fields | `ageYears: Int = 28`; no max/resting/LTHR | Add optional maxHR / restingHR / LTHR (optional-backed) |
| Colors | `BaselineColor.zoneBlue/Green/Amber/Red` (4) | Add a 5th token for the Z1–Z5 spectrum |
| In-workout UI | `StructuredWorkoutView`/`WorkoutView` (DIRTY — owner WIP) | Build standalone `LiveHeartRateView`; defer drop-in to go-live |

## Data model (pure value types)

```
HeartRateZone: Int, CaseIterable        // z1…z5, displayName, conventional color token
HeartRateZoneModel                       // boundaries from a profile; zone(forBPM:) + fraction within zone
├── maxHR: Int                           // user-set or Tanaka(age)
├── restingHR: Int?                      // enables Karvonen/HRR
├── lthr: Int?                           // optional threshold anchor (later)
└── method: .heartRateReserve | .percentMax   // chosen by available inputs
HeartRateSample { bpm, sensorContact, receivedAt }   // parsed 0x2A37 (reuse existing HRV parse where possible)
ZoneTimeAccumulator                      // seconds-in-zone over a session, from a sample stream + clock
```

## Engine / service design

- `HeartRateZoneModel` — pure: `zone(forBPM:) -> HeartRateZone`, `position(forBPM:) -> Double` (0–1
  across the whole spectrum, for the marker), Karvonen when `restingHR != nil` else %max. Tunables
  (zone boundary fractions) centralized. Fully unit-tested against hand-computed values.
- `HeartRateMonitor` (`@MainActor @Observable`) — facade over `BluetoothManager`'s live stream:
  `currentBPM`, `freshSample` (freshness window), `currentZone` (via injected `HeartRateZoneModel`),
  `sensorContact`, connection state, `startMonitoring()/stop()`. Zone-time accumulation via an
  injected clock. No CoreBluetooth here.
- `BluetoothManager` gains `.live` intent + a published `liveBPM`/`sensorContact` derived from the
  0x2A37 notifications it already receives; the `reading` path and R-R/HRV are untouched.

## UI

- `HeartRateZoneGauge` — the hero component. Shipped first as a linear `HeartRateZoneSpectrum` and
  then redesigned (issue #65) into a **semicircular Z1→Z5 gauge wrapping the BPM number**: segments
  proportional to each zone's BPM span, the current zone lit, a pulsing current-position marker. Pure
  view with layout math in a testable helper. See `live-heart-rate-go-live.md` for the current HUD
  design of record.
- `LiveHeartRateView` — big BPM number (tinted the current zone color) + zone name (e.g. "Z3 ·
  AEROBIC") + the gauge + AVG · TIME · MAX stats + a TIME IN ZONE breakdown + honest
  sensor-contact/"reconnecting"/stale states. Standalone, DS-compliant, rich previews (each zone,
  no-signal, stale, reconnecting, sensor-off). Rendered via `RenderPreview` for the UX review.
- `HeartRateZoneSettingsView` — replaces the `.soon` Profile row: max HR (Tanaka default, editable),
  resting HR, optional LTHR, method indicator, and a live zone-boundary preview table.

## Ordered slices

1. **Zone model + live monitor (headless).** `HeartRateZone`, `HeartRateZoneModel` (Karvonen/%max +
   Tanaka), `BluetoothManager` `.live` mode + live BPM stream, `HeartRateMonitor` facade (freshness,
   current zone, zone-time). Pure/injectable + tests. Existing HRV reading path unchanged.
2. **Zone settings + profile fields + persistence.** Real `HeartRateZoneSettingsView` (retire the
   `.soon` stub), optional maxHR/restingHR/LTHR profile fields (optional-backed), per-session
   zone-time record. Previewable.
3. **Live-HR UI (standalone).** `HeartRateZoneGauge` + `LiveHeartRateView` + the 5th color token;
   rich previews. **Defer** the drop into the active-workout surface (dirty `StructuredWorkoutView`/
   `WorkoutView`) to a documented go-live step (`docs/implementation/live-heart-rate-go-live.md`):
   place `LiveHeartRateView`, bind it to `HeartRateMonitor`, pass the session's planned target zone,
   and `autoConnectIfRemembered()` at session start.

## Dormancy / no-behavior-change guarantee

Nothing changes in the running app until the owner go-live: the live monitor is only started from the
active-workout surface (not built here), the settings screen is reachable but purely configures
values, and the standalone `LiveHeartRateView` has no live call site. The HRV reading path and
existing workout behavior are byte-identical.

## Status

Planned 2026-07-14. Reference: AscendApp `develop` (PR #196). Built via ios-feature-factory.
The dormancy guarantee above described slices 1-3 only: the go-live wiring has since been performed
and the capability is live in the workout surface - see `live-heart-rate-go-live.md`, and
`docs/technical-reference.md` § HR Zones for what a completed session now persists.
