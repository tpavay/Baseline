# Baseline Live Heart-Rate Contract

## Product Contract

- Live heart rate is an optional workout aid.
- A user can execute and log any supported workout without a connected monitor.
- The capability must support different training modalities without implying that zones are equally relevant to all of them.
- Planned guidance and actual performance are separate structured records.
- A disconnected or unsupported source remains missing data and is never inferred.

## Current Source Direction

- Prefer the standard BLE Heart Rate Service `0x180D`.
- Read Heart Rate Measurement characteristic `0x2A37`.
- Use the transmitted heart-rate value for live workout display.
- Parse optional R-R intervals when present, but do not require them for basic workout heart-rate tracking.
- Polar H10 is the currently validated device, not an exclusive requirement.
- Reuse saved-device and connection behavior where practical without coupling workout execution to the resting-reading lifecycle.

## Current Zone Direction

- Baseline computes its own zones from raw user inputs rather than importing another app's private zone configuration.
- Heart Rate Reserve, also called Karvonen, is the current default model.
- The model uses resting heart rate and maximum heart rate:

  `target HR = resting HR + intensity fraction × (maximum HR - resting HR)`

- Tanaka is the current fallback estimate when no observed or tested maximum is available:

  `estimated maximum HR = 208 - 0.7 × age`

- Precedence should favor an explicit tested maximum over an observed maximum, and an observed maximum over an age estimate, unless the user chooses another policy.
- Support an explicit LTHR-based configuration for running when the product implements that path.
- Do not invent zone percentages or Friel boundaries when the repository has not defined them.
  Confirm the product policy before hard-coding new thresholds.
- Persist the calculation method and inputs needed to explain or reproduce a historical zone boundary.

## Session And Segment History

- Bind samples to an active workout and, when meaningful, the active segment.
- Track planned target zones separately from actual zone summaries.
- Define pause, resume, backgrounding, disconnect, reconnect, and workout-end boundaries explicitly.
- Avoid double-counting samples across segment transitions or reconnects.
- Preserve enough timing information to calculate time in zone and explain gaps.
- Store summaries at a useful resolution while retaining raw data only when a concrete product, diagnostic, or research need justifies it.

## Recommendation Boundary

- A zone model expresses physiological intensity.
- It does not independently decide which workout the user should perform.
- The planning layer considers the session's intended effect, the user's goals and plan, recent work, constraints, explicit context, and optional evidence.
- Strength, bodybuilding, skill, mobility, and mixed sessions may use different adaptation levers from endurance sessions.

## Testing Contract

- Test pure zone math at exact boundaries and with missing or invalid inputs.
- Test max-HR source precedence and user overrides.
- Test segment aggregation with pauses, transitions, duplicate timestamps, late samples, disconnects, and reconnects.
- Test connection-state behavior through a fake source without hardware.
- Verify at least one real-device workflow separately when changing BLE integration.

## Current Implementation Status

The repository contains a BLE heart-signal service and workout models with target or actual zone concepts.
Do not assume complete live workout streaming, zone calculation, or per-segment persistence exists without inspecting current code.
