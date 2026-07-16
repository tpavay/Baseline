---
name: baseline-live-heart-rate
description: Design, implement, review, or debug Baseline's optional live workout heart-rate capability, including BLE Heart Rate Service streaming, device connection lifecycle, target-zone calculation, HRR or Karvonen inputs, tested-max and LTHR overrides, workout-segment association, zone history, persistence, and tests. Use whenever work touches workout-time heart rate, heart-rate zones, connected straps during sessions, targetZone or actualZone data, per-segment zone summaries, or heart-rate-guided execution. Do not use for a resting HRV reading unless the task also changes shared capture infrastructure.
---

# Baseline Live Heart Rate

Build workout-time heart-rate tracking as an optional execution capability that works across training modalities.
Keep live measurement, zone policy, session guidance, and historical interpretation as separate testable layers.

## Establish Current Scope

1. Read `AGENTS.md`, especially Optional Evidence, Training Logic Is Domain-Specific, and System Surfaces.
2. Read [references/live-heart-rate-contract.md](references/live-heart-rate-contract.md).
3. Search the repository before assuming the feature exists.
   The BLE reading pipeline is implemented, while complete workout-time zone tracking may still be planned.
4. Inspect the relevant models and services, including:
   - `Baseline/Shared/Services/BluetoothManager.swift`
   - `Baseline/Shared/Services/HeartSignalSource.swift`
   - workout execution and logging models under `Baseline/Features/Workout/`
   - `docs/implementation/workout-execution.md`
   - `docs/technical-reference.md`
5. Load the relevant shared Swift, concurrency, testing, HealthKit, security, and accessibility skills for the task.

## Protect Product Behavior

- Keep live heart-rate tracking opt-in and useful without making it mandatory for workout execution or logging.
- Support standard heart-rate sources rather than locking the product to one device model.
- Distinguish simple heart-rate streaming from resting HRV.
  Workout heart rate does not require every source to produce trustworthy R-R intervals.
- Treat zones as user-specific execution guidance, not universal training logic.
- Preserve the intended training effect of the planned session.
  Do not use one fixed zone policy to rewrite every strength, bodybuilding, interval, mobility, or mixed session.
- Do not gate training through a legacy readiness score.
  The recommendation layer may adjust targets using plan-aware evidence and explicit constraints.
- Keep user overrides explicit and durable.
  Never silently replace a tested max HR or configured threshold model with an age estimate.

## Preserve Technical Boundaries

- Keep BLE discovery, connection, reconnection, streaming, and permissions behind a service boundary.
- Keep zone calculation pure and independent of CoreBluetooth, HealthKit, SwiftUI, and persistence.
- Keep planned targets separate from performed heart-rate history.
- Associate actual heart-rate or zone summaries with the correct workout segment and time window.
- Preserve source, calculation method, configuration version, and missing-data semantics.
- Avoid retaining an unbounded raw stream in UI state.
  Store the resolution needed for execution, summaries, diagnostics, and future learning.
- Isolate callback queues and document any unsafe sendability or thread-confinement invariant.

## Implement And Verify

1. Define the user outcome and the supported source or zone method before changing data structures.
2. Confirm the current domain model can represent the planned target and the performed result independently.
3. Implement pure zone calculations and deterministic segment aggregation first.
4. Connect the live source through an adapter rather than embedding CoreBluetooth in a workout view.
5. Add tests for calculation boundaries, override precedence, reconnects, missing inputs, segment transitions, pause and resume, and duplicate or late samples as applicable.
6. Verify the real workout UI with connected, connecting, disconnected, stale-signal, override, and no-device states.
7. Update the technical reference and this skill when zone policy or persistence contracts change.

## Coordinate With Adjacent Skills

- Use `baseline-hrv-reading` for resting R-R capture, RMSSD, camera PPG, or source-specific HRV baselines.
- Use both skills when changing a shared BLE manager, saved-device model, permissions flow, or reconnection policy.
- Use `baseline-design-system` for live-zone presentation or workout interaction changes.
