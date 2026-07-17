---
name: baseline-hrv-reading
description: Implement, review, debug, or design Baseline's optional resting HRV reading and evidence pipeline, including BLE chest-strap R-R capture, camera PPG, ReadingSession, artifact correction, RMSSD and lnRMSSD, source provenance, recalibration, permissions, persistence, and tests. Use whenever work touches Baseline HRV readings, heart-signal capture outside workouts, BluetoothManager reading mode, CameraPPGManager, PPGProcessor, HeartSignalSource, R-R intervals, reading UI or history, or HRV-derived training evidence. Do not use for live in-workout heart-rate-zone tracking unless the task also changes the resting reading pipeline.
---

# Baseline HRV Reading

Build HRV as an optional evidence source inside Baseline's broader training system.
Preserve the distinction between acquiring trustworthy physiological evidence and deciding what the user should train.

## Establish Current Scope

1. Read `AGENTS.md`, especially Optional Evidence, Plan-Aware Recommendations, and Evidence Supports Decisions.
2. Read [references/hrv-contract.md](references/hrv-contract.md).
3. Inspect the current implementation before proposing architecture changes:
   - `Baseline/Shared/Services/HeartSignalSource.swift`
   - `Baseline/Shared/Services/BluetoothManager.swift`
   - `Baseline/Shared/Services/CameraPPGManager.swift`
   - `Baseline/Shared/Services/HRV.swift`
   - `Baseline/Features/Reading/ReadingSession.swift`
   - `Baseline/Features/Reading/Reading.swift`
   - `BaselineTests/HRVTests.swift`
   - `BaselineTests/ReadingSessionTests.swift`
4. Read `docs/technical-reference.md` for current sensor notes.
   Treat readiness-score formulas, recovery bands, and a user-facing score in older documents as legacy unless the user explicitly asks about that legacy implementation.
5. Load the relevant shared Swift, concurrency, testing, HealthKit, security, or accessibility skills when the task enters those domains.

## Protect Product Behavior

- Keep HRV opt-in.
  Do not make a reading, device connection, or camera measurement a prerequisite for planning, training, or logging.
- Recommend a chest strap only within an HRV flow or when accuracy materially matters.
  Do not present hardware ownership as a Baseline requirement.
- Store the reading as structured evidence with source provenance and meaningful uncertainty.
  Do not turn it into a required global readiness score.
- Let the planning and recommendation layer combine HRV with the user's plan, history, constraints, explicit context, and other optional evidence.
  HRV alone does not prescribe a workout.
- Never invent a missing reading, baseline, signal quality, or level of certainty.
- Keep source changes explicit.
  A baseline built from one capture modality must not silently mix with another modality.

## Preserve Technical Boundaries

- Keep capture behind `HeartSignalSource` so strap and camera use the same reading session.
- Keep parsing, artifact correction, RMSSD, lnRMSSD, and other calculations pure and testable without hardware or UI.
- Keep raw measurements distinguishable from corrected or derived values.
- Isolate CoreBluetooth and AVFoundation callbacks behind narrow concurrency boundaries.
  Document any queue confinement or unsafe sendability invariant.
- Request Bluetooth or camera access only when the user initiates the corresponding capability.
- Keep display and narration separate from sensor truth.
  Internal reliability data may inform handling without becoming unsupported or distracting user-facing claims.

## Implement And Verify

1. Reproduce the requested behavior using the closest available source or deterministic fixture.
2. Change the smallest appropriate layer.
   Avoid embedding signal processing or recommendation logic in SwiftUI views.
3. Add or update focused tests for BLE payload parsing, artifact handling, HRV math, reading state transitions, source provenance, persistence, and failure behavior as applicable.
4. Run the focused tests, then the broader suite required by the change.
5. For UI changes, verify the real screen with representative no-signal, acquiring, reading, completion, cancellation, and permission-denied states.
6. Update `docs/technical-reference.md` and the skill reference when a durable sensor contract changes.
   Do not revive legacy score language while documenting capture behavior.

## Coordinate With Adjacent Skills

- Use `baseline-live-heart-rate` when the task concerns workout-time streaming, target zones, or per-segment heart-rate history.
- Use both skills when changing a shared BLE connection or heart-signal abstraction that serves resting readings and workouts.
- Use `baseline-design-system` for visual or interaction changes to the reading flow.
