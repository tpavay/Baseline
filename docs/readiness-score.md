# Baseline — Readiness Score (configurable composite)

> The full spec for the morning readiness score: the flow, the configurable inputs, the
> capture sources, the questionnaire, and the scoring math. Companion to
> `docs/engine-and-data-model.md` (which consumes the score to pick today's dose) and
> `docs/design.md` (screens). **Evolving** — the current plan, grounded in the research below.

## The general flow

```
Configure what feeds the score  →  Produce the score  →  Gate today's training (HR zones / dose)
```

1. **Configure** (once, in onboarding + editable in Settings) — the athlete chooses *which inputs* count toward their score. We do **not** expose weight sliders (see "Configurability" below).
2. **Produce the score** each morning — a composite **0–100** from whatever inputs are enabled and have data, mapped to a **recovery band** (green ≥80 · amber 60–79 · red <60).
3. **Gate today's training** — the band decides which dose / intensity is wise, and (later) modulates the day's target HR zones (Morpheus-style). This is the bridge that makes Baseline a coach, not a tracker.

## Onboarding branch (one question)

> **"Do you have a chest strap or HR sensor?"**

- **Yes → strap path.** Scan for the BLE Heart Rate Service (`0x180D`); if the device flags R-R intervals, use it (Polar H10 etc.). Best experience; also unlocks live in-session HR zones.
- **No → camera or subjective-only.** **Camera PPG** (finger-over-lens) ships **at launch** (decided 2026-07-07), so non-strap users get a real HRV read from day one via the same 2:30 guided reading. Declining both leaves the subjective-only path (the questionnaire still produces a real score) with optional Apple Health context. Keep a persistent, honest nudge: *"a chest strap is more accurate and unlocks live workout zones."*

This matches build-for-self (Tyler has an H10) and keeps the MVP tight while never blocking a non-strap user from getting a score.

## Capture sources (HRV) — honest feasibility

The morning read needs **beat-to-beat R-R intervals** to compute RMSSD/lnRMSSD. Not every "HR source" can provide them.

| Source | HRV accuracy vs ECG | Live R-R? | Status | Notes |
|---|---|---|---|---|
| **Chest strap** (Polar H10) | Gold standard (~2% RMSSD MAPE) | **Yes** (`0x2A37` R-R flag) | **MVP** | Already built + validated. Only clean per-beat stream. |
| **Camera PPG** (finger + flash) | ~1.0 corr at rest; RMSSD MAPE ~17% | **Yes** (app derives R-R) | **Launch** (2026-07-07) | Our 2:30 seated guided read is its best case. Reuses the R-R→RMSSD function; only the AVFoundation capture front-end is new. What HRV4Training/Welltory do. |
| **Optical arm band** (generic) | Good HR; HRV usable at rest only | **Only if it broadcasts R-R** | **Deferred** | Most don't expose clean `0x180D` R-R. Polar Verity Sense needs Polar's SDK, not vanilla CoreBluetooth. |
| **Coros HR armband** | HR only | **No** | **Not supported for HRV** | DC Rainmaker teardown: "Valid HRV/RR data: No." Plain HR transmitter. Don't build against it. |
| **Apple Watch** (HealthKit) | Good for *stored* SDNN | **No** | **Context / baseline-seed only** | HealthKit exposes `heartRateVariabilitySDNN` (SDNN, not our RMSSD), written opportunistically. No third-party on-demand read, no live beat-to-beat to a companion app. Use its history to seed the baseline + give context — never as the morning read. |

**Config UI shows all of these** as selectable, but each carries its real behavior (a generic arm strap is only offered if a scan finds R-R; Apple Watch appears under "context/baseline," not "reading source"). Honest config beats a path that silently fails.

**The non-negotiable constraint:** a personal baseline is built from **one source**. Chest-ECG R-R and camera-PPG R-R have different noise characteristics; mixing them corrupts the rolling baseline. Every `Reading` stores its `source`; the baseline query filters to one modality, and **switching source = recalibration → re-enter cold-start**.

*Sources: [BLE HR Service](https://www.bluetooth.com/specifications/specs/heart-rate-service-1-0/) · [DC Rainmaker Coros](https://www.dcrainmaker.com/2023/07/monitor-optical-review.html) · [Altini camera-PPG validation](https://marcoaltini.substack.com/p/another-independent-validation-of) · [Apple Forums: no 3rd-party HRV trigger / live R-R](https://developer.apple.com/forums/thread/658101) · [Altini on Apple Watch HRV](https://medium.com/@altini_marco/on-heart-rate-variability-and-the-apple-watch-24f50e8e7bc0).*

## The configurable inputs

Each enabled input contributes a 0–100 subscore. **Prior-day training load is deferred from MVP** (unclear ingestion + categorization — revisit once logging + live zones exist).

| Input | MVP | Source | Subscore |
|---|---|---|---|
| **HRV** | ✅ | strap or camera (both at launch) | lnRMSSD vs personal baseline (z-score) |
| **Resting HR** | ✅ | comes free with the HRV read | vs baseline (inverted) |
| **Wellness questionnaire** | ✅ | the 1–5 self-report below | oriented composite |
| **Sleep** | ✅ | Apple Health **if available, else** the questionnaire's sleep-quality item (never both) | duration/efficiency or the 1–5 item |
| **Prior-day training load** | ⏳ deferred | logged session (sRPE / Edwards-TRIMP) | normalized load penalty |

### Configurability = toggles, not weights
The athlete chooses **which inputs count** and **which questionnaire items appear** — not the weights. Hand-tuning weights is fiddly and unvalidated; a fixed, defensible model that re-normalizes over the enabled set is better MVP. The score stays a valid 0–100 no matter the config (missing inputs drop out of both numerator and weight-sum). The **"Readiness Setup"** screen is where this lives (Instrument DS: `Stat Readout` rows with toggles).

## The morning flow

**Strap path:** live preview → quiet **2:30 timed read, breathing naturally** (no paced cues — resonance-frequency pacing inflates RSA and adds compliance noise to the baseline; decided 2026-07-07. Dark screen, still orb, single R-R curve building, live HR/HRV, bell + haptic at the end) → **averages** → **wellness questionnaire** → **readiness score + band + today's guidance**.

**Camera path (launch):** same guided 2:30 reading with fingertip over lens + flash, then the questionnaire — identical flow to the strap, different capture front-end.

**Subjective-only path (launch):** **wellness questionnaire** → **readiness score + band + guidance** (HRV/RHR simply drop out and weights re-normalize onto subjective + sleep).

## The wellness questionnaire

The validated basis is the **McLean 5-item wellness questionnaire** (soreness, mood, fatigue/energy, sleep, stress) — which is exactly the athlete's proposed set. Rated **1–5 in 0.5 increments** with an anchor label at each integer (a slider that snaps to 0.5; the half-steps are UX smoothing between anchors, not a claim of 9 discriminable levels — a deliberate call over the strict labeled-1–5 the literature prefers). **Notes** is free text, unscored (context + fuels the later "why" narration).

Each item is **oriented so 5 = best / most-recovered** for scoring (the UI copy can still read intuitively):

| Item | UI anchors (1 → 5) | Orientation for scoring |
|---|---|---|
| **Soreness** | extremely sore · very sore · sore · somewhat · barely · none | **invert** (none = 5 = best) |
| **Mood** | angry · sad · worried · calm · happy | direct (happy = 5) |
| **Energy** | exhausted · tired · normal · energized · full of energy | direct (full = 5) |
| **Sleep quality** | terrible · poor · ok · good · excellent | direct — **only shown if no Apple Health sleep** for the night |
| **Stress** | severe · high · moderate · low · none | **invert** (none = 5 = best) |
| **Notes** | free text | unscored |

**Why the questionnaire carries real weight:** the Saw/Main/Gastin systematic review found subjective self-report is often *more responsive* to fatigue and load than HRV or resting HR, and is statistically *complementary* (near-zero correlation) — so it's not decorative, and high soreness/stress can legitimately **override** a green HRV into the chassis/low-impact pivot. *([Saw et al., 2016](https://pmc.ncbi.nlm.nih.gov/articles/PMC4789708/); [McLean et al., 2010 wellness set](https://www.globalperformanceinsights.com/post/wellness-questionnaires-for-athlete-monitoring).)*

**Stressor breakdown** (social/life/psychological/cognitive/physical) — **deferred.** One stress item + notes for MVP; later, when stress drops, offer an optional one-tap stressor tag, and use physical/soreness tags to steer the chassis-region pivot.

## The scoring math (pure function)

Implement as a pure, unit-testable function (no hardware, no view tree), mirroring `HRV.swift`.

### Per-input subscore → signed z-score
For each enabled input with data, compute a signed **z-score** relative to the athlete's personal rolling baseline, where **positive = more recovered**:

```
z_i = clamp( (today_i − baselineMean_i) / baselineSD_i , −3, +3 )
```
- **HRV:** `today = ln(RMSSD)`. Baseline = **7-day rolling** mean/SD of lnRMSSD.
- **Resting HR:** **invert** (higher RHR = worse recovery).
- **Sleep:** Health duration/efficiency → oriented; or the subjective sleep item.
- **Subjective composite:** mean of the oriented 1–5 items → its own rolling z (see below).

### Composite → 0–100
```
composite_z = Σ (w_i · z_i)  /  Σ w_i        // over PRESENT inputs only (auto re-normalize)
score       = clamp( round( 50 + 22 · composite_z ), 1, 100 )
```
`22` maps ≈ ±2.3 SD to the full 0–100 range. **Default weights** (prior-day load deferred, re-normalized):

| Input | Weight |
|---|---|
| HRV | 0.50 |
| Subjective | 0.25 |
| Resting HR | 0.15 |
| Sleep | 0.10 |

### Recovery bands (align with the engine)
`≥80` green — intensity OK · `60–79` amber — aerobic / sub-threshold · `<60` red — active recovery / chassis.

### Subjective override (hard floor, not just a weight)
If **soreness ≤ 2** (very/extremely sore) **or stress ≤ 2** (high/severe) on the 5-best scale, **floor the band at amber** (heavy DOMS → chassis, even on a green HRV) — matching the research that these items are the most training-responsive.

### Cold-start ramp (first ~14 readings)
No trustworthy personal baseline yet, so:
- HRV subscore uses **absolute values + age/population norms** (wide bands), not a baseline that doesn't exist.
- **Shift weight onto the subjective** input; show the **provisional score with a "calibrating" treatment** (violet/neutral gauge fill — never a band color, never a blank). The user gets a real number from day one (2026-07-07 ruling); copy stresses it's an estimate that sharpens with consistent readings. Band colors appear only once the baseline is trustworthy.
- Subjective cold-start score (before its own baseline) = raw sum: for `k` answered items, `score = (sum − k) / (4k) · 100`.
- ~14 readings is the consensus threshold for a trustworthy baseline (Elite HRV / Oura / Garmin all calibrate over ~2–3 weeks).

### Secondary signals (surface, don't bury in the score)
- **Normal range / SWC:** display today's HRV against `mean ± 0.5·SD` (smallest worthwhile change) — "normal / above / below your baseline."
- **Coefficient of variation** `CV = SD(7-day lnRMSSD) / mean · 100` — a *rising* CV flags maladaptation before the mean drops; show it as its own trend, not folded silently into the score.
- **Parasympathetic saturation guard:** if HRV is low **and** RHR is low, a low reading may mean fatigue *or* vagal saturation — don't blindly score it red.

*Sources: [Altini — Ultimate Guide to HRV](https://medium.com/@altini_marco/the-ultimate-guide-to-heart-rate-variability-hrv-part-2-323a38213fbc) · [lnRMSSD & SWC](https://www.ryun.app/news/lnrmssd-and-the-smallest-worthwhile-change) · [Elite HRV baseline](https://help.elitehrv.com/article/74-how-the-hrv-baseline-works) · [Whoop recovery weighting](https://support.whoop.com/s/article/WHOOP-Recovery) · [Oura readiness contributors](https://support.ouraring.com/hc/en-us/articles/360057791533-Readiness-Contributors) · [Altini — parasympathetic saturation](https://marcoaltini.substack.com/p/parasympathetic-saturation).*

## Output → today's training

- **MVP:** the recovery **band gates the dose** (green = intensity OK · amber = aerobic/sub-threshold · red = recovery/chassis) — per `docs/engine-and-data-model.md`.
- **Later (Morpheus-style dynamic zones):** the score modulates the day's **target HR zones** — a lower band compresses the intensity ceiling (green = full zones · amber = cap at threshold/Z3 · red = Z2/recovery only). This is the "Training HR zones based on score" step; the deeper re-zoning (shifting boundaries) is post-MVP.

## Deferred (YAGNI for the score)
- **Prior-day training load** as a score input (needs logging + live zones first; then normalized sRPE / Edwards-TRIMP). *Spacing / glycogen / "never two hard days" belong to the scheduling **engine**, not the score.*
- **Stressor-type breakdown**, **ACWR/EWMA trend** (contested evidence — advisory only, later), **optical arm bands**, **dynamic HR re-zoning**.

## Data model deltas (from today's `Reading`)
Add to `Reading` (all CloudKit-safe: defaults, optional, no `.unique`):
- `source: ReadingSource` (`chestStrap` / `camera` / `subjectiveOnly` / …) — for one-source baselines.
- `subjective: SubjectiveCheck?` — the oriented 1–5 items + notes.
- `restingHR`, `sleep` snapshot, computed `readinessScore` + `band`, and a `calibrating` flag.

New pure type **`ReadinessScore`** (Foundation only): takes the enabled inputs + rolling baselines → `(score, band, contributors[], calibrating)`. Unit-tested without hardware. **Implemented 2026-07-08** in `Baseline/Shared/Services/ReadinessScore.swift` — `compute(Inputs)` re-normalizes weights over present inputs (HRV 0.50 / check-in 0.25 / RHR 0.15 / sleep 0.10; cold-start shifts to check-in 0.45 / HRV 0.30), applies the parasympathetic-saturation guard and the soreness/stress amber floor. Sleep flows in from HealthKit via `HealthService.lastNightSleep()`. Camera HRV via `CameraPPGManager` + pure `PPGProcessor` (fingertip PPG → R-R → same `HRV` pipeline), behind the `HeartSignalSource` protocol shared with `BluetoothManager`.

**Band centering (decided 2026-07-08):** the composite maps as `score = 70 + 20·z` (not `50 + 22·z`), so a **neutral / at-baseline day sits mid-amber (70), never red**. This encodes the Altini normal-range model directly: **amber = the "within normal variation" band around your baseline; green ≈ ≥0.5 SD above baseline** (the smallest-worthwhile-change — a genuinely better day); **red ≈ ≥0.5 SD below**. So all-3/5 subjective → 70 (amber), all-4/5 → green, all-2/5 → red. An "average" day reads as *ready-ish*, not as a bad day. `neutralScore`/`spread`/`subscoreScale` are the tunables; once the 7-day baseline is established the same z is measured against the personal rolling mean/SD instead of the absolute cold-start frame.
