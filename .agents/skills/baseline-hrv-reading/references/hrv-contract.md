# Baseline HRV Contract

## Product Contract

- HRV is optional evidence.
- The user may use a chest strap, the phone camera, neither source, or a future supported source.
- Declining HRV must remove it from the primary experience until the user enables it again.
- The output of a reading is evidence for a plan-aware recommendation, not a required user-facing readiness score.
- A recommendation must communicate material uncertainty when the available evidence is limited.

## Current Capture Sources

### BLE chest strap

- Use the standard BLE Heart Rate Service `0x180D`.
- Read Heart Rate Measurement characteristic `0x2A37`.
- Parse the R-R-present flag rather than assuming every heart-rate packet includes R-R intervals.
- Convert R-R units from `1/1024 s` to milliseconds.
- Polar H10 is the currently validated device, not a hardware lock.

### Camera PPG

- Use fingertip PPG through the camera and flash as the no-hardware capture path.
- Keep camera capture behind `HeartSignalSource` and reuse the R-R-to-HRV pipeline.
- Treat camera-derived and ECG-strap-derived readings as different modalities with different noise characteristics.

### Unsupported substitutions

- Do not treat stored Apple Watch SDNN as an on-demand RMSSD reading.
- Do not claim generic optical sensors support resting HRV unless the available stream provides usable beat-to-beat intervals.

## Reading Experience

- The current resting read is a quiet 2 minute 30 second timed session.
- Instruct the user to breathe naturally.
  Do not add paced-breathing cues because controlled resonance breathing changes the measurement and adds compliance noise.
- Keep the interface calm and low-distraction.
- Show the live heart signal only when it helps the user complete the reading.
- Provide clear completion feedback with the established sound and haptic behavior.
- Persist the source and raw R-R intervals needed for provenance or diagnostics.
- Keep internal artifact or reliability handling separate from unsupported user-facing certainty claims.

## Signal Pipeline

1. Acquire heart rate and beat-to-beat intervals from the selected source.
2. Preserve the raw R-R series.
3. Reject physiologically implausible intervals and artifact-correct the usable series according to the current pure implementation.
4. Compute RMSSD from successive differences.
5. Compute lnRMSSD only from a positive RMSSD value.
6. Persist raw values, derived values, source, timing, and reliability metadata required by the current model.
7. Expose the result as structured evidence without mapping it to a mandatory global score.

## Baselines And Source Changes

- Compare like with like.
- Keep any personal trend or baseline source-specific.
- When the capture modality changes, start a new calibration context rather than silently joining unlike measurements.
- Historical data from another source may remain visible with provenance but must not be represented as one homogeneous baseline.

## Testing Contract

- Test BLE parsing with 8-bit and 16-bit heart rate payloads, optional fields, multiple R-R intervals, malformed packets, and missing R-R flags.
- Test artifact correction and RMSSD or lnRMSSD as pure functions.
- Test countdown, acquisition, reading, cancellation, failure, and completion without hardware through a mock `HeartSignalSource`.
- Test source-specific persistence and baseline selection.
- Keep hardware validation as an additional integration check, never the only evidence of correctness.

## Known Legacy Material

`docs/readiness-score.md`, parts of `docs/design.md`, existing readiness services, and some screens still describe a composite score and fixed recovery bands.
Those artifacts document the current legacy implementation but do not override the AI-first, decision-first product rules in `AGENTS.md`.
