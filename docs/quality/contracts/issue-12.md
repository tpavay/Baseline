# Feature Contract: Live Heart Rate Slice 3 — live BPM + zone spectrum HUD (standalone)

- Issue: #12
- Base branch: `feature/issue-2-workout-image-import`
- Change type: feature
- Owner: orchestrator

Base note: branched from live-HR Slice 2 tip `933c328`. `main` remains stale (recorded in #4).

## User outcome

The visual payoff: a `LiveHeartRateView` that shows the current heart rate as a large BPM number, its
zone name (e.g. "Z3 · Threshold"), and a full colored Z1–Z5 spectrum with a marker at the athlete's
current position and an optional outline of the session's planned target zone — plus honest states
when the signal is stale, the sensor loses contact, or the strap is reconnecting. It is a standalone,
fully-previewed component this slice; it appears in the app only after the owner go-live wires it into
the active-workout surface.

## Non-goals

- No workout-execution-view changes (`StructuredWorkoutView`/`WorkoutView`/`WorkoutModel` are owner
  WIP; the drop-in is the go-live step, documented in `live-heart-rate-go-live.md`).
- No `BaselineApp.swift` change; the live monitor is still only ever started by the (future) workout
  wiring, never by this slice.
- No changes to `HeartRateZoneModel` math, the monitor, or the settings store beyond consuming them.
- No zone-time persistence UI (that lands with the workout wiring at go-live).
- Existing tests untouched.

## Acceptance criteria

- [ ] AC-1: `HeartRateZoneSpectrum` renders five proportional Z1–Z5 segments in the conventional
      colors (via the exhaustive `HeartRateZone` → color map), with the **current zone** visually
      emphasized and a **marker** placed at `HeartRateZoneModel.position(forBPM:)`; all segment/marker
      geometry is in a pure, unit-tested layout helper (`body` only draws). Marker position is
      monotonic in BPM and clamps at the ends.
- [ ] AC-2: Optional **planned target-zone** band: when a target zone (1–5) is supplied, the spectrum
      outlines that zone's segment distinctly from the current-zone emphasis; when nil, no target
      outline is shown. Current-zone emphasis and target outline are visually distinguishable.
- [ ] AC-3: `LiveHeartRateView` shows the live BPM number + zone name ("Z{n} · {Name}") from the
      monitor's `currentBPM`/`currentZone`; presentation mapping (BPM/zone → display strings) is in a
      pure helper, not in `body`.
- [ ] AC-4: **Honest states** (no fabricated data): when the monitor's `freshSample` is nil (stale
      beyond the freshness window) the view shows a no-signal state (no stale BPM presented as live);
      `sensorContact == .notDetected` surfaces a contact warning; `connectionState`
      connecting/reconnecting and disconnected each have a distinct state. A pure state-resolver maps
      monitor state → a `LiveHeartRateDisplayState`, unit-tested.
- [ ] AC-5: The view binds to an **injected monitor abstraction** (protocol or the `HeartRateMonitor`
      facade) so it is previewable/testable with a fake; it never constructs a `BluetoothManager` or
      starts monitoring itself.
- [ ] AC-6: Accessibility: the BPM value, zone name, and state are exposed to VoiceOver as a coherent
      label/value; the spectrum has an accessible summary (current zone + BPM). Light + dark.
- [ ] AC-7: No behavior change in the running app: full existing suite passes unmodified;
      `BaselineApp.swift` and `Baseline/Features/Workout/` are 0-diff; `LiveHeartRateView` has no live
      call site (only previews construct it); the monitor is still never started outside a test/preview.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Streaming | BPM + zone name + marker at position; spectrum highlights current zone | AC-1/AC-3 |
| With target | Planned target-zone band outlined alongside current-zone emphasis | AC-2 |
| Stale/no-signal | No BPM number presented as live; "no signal" state | AC-4 |
| Sensor off | Contact-not-detected warning | AC-4 |
| Reconnecting/disconnected | Distinct connecting/disconnected states | AC-4 |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `HeartRateZoneSpectrumLayoutTests` (segments/marker geometry, monotonic + clamp) + preview | Geometry pinned without a view tree |
| AC-2 | `HeartRateZoneSpectrumLayoutTests` target-band cases + preview | Target outline present iff target set, distinct from current |
| AC-3 | `LiveHeartRatePresentationTests` (BPM/zone → strings) | Mapping asserted |
| AC-4 | `LiveHeartRateStateTests` (stale→no-signal, sensor-off, reconnecting, disconnected) | State resolver pinned; no stale BPM as live |
| AC-5 | `LiveHeartRateView` takes a monitor protocol; preview/test fakes it | Injected; no BluetoothManager construction |
| AC-6 | Accessibility inspection of previews + rendered light/dark | Labels/values present |
| AC-7 | Full suite green; BaselineApp/Workout 0-diff; no live call site grep | Isolation + dormancy |

## UX evidence

SwiftUI `#Preview`s of `LiveHeartRateView` (each zone Z1–Z5, no-signal/stale, reconnecting,
sensor-off, with/without a planned target band) and `HeartRateZoneSpectrum`, light + dark, rendered
via `RenderPreview` for the UX review. Design-system tokens/components, not fallback styling.

## Risk and rollout

- **Data migration:** none.
- **Backward compatibility:** additive new views; nothing else changes.
- **Privacy/security:** on-device; no values logged.
- **Analytics/flags:** none.
- **Rollback:** revert branch; no live call site exists.
- **Deployment order:** the owner go-live wires `LiveHeartRateView` into the active-workout surface,
  binds a `HeartRateMonitor` (built from the zone settings), `autoConnectIfRemembered()` at session
  start, passes the planned target zone, and persists zone-time — per `live-heart-rate-go-live.md`.

## Human gates

- Owner review of the rendered HUD is welcome (pixel-perfection standard) but not required to
  converge; go-live workout wiring is owner-performed.
