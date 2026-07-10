# Baseline - Technical Reference

> Living implementation notes. This document is allowed to change as Apple APIs, model providers, sensors, data sources, and storage choices change. Durable product concepts belong in `docs/engine-and-data-model.md`.

## Recovery Capture
- Current preferred HRV source: chest strap.
- BLE Heart Rate Service: `0x180D`.
- Heart Rate Measurement characteristic: `0x2A37`.
- R-R interval units from the characteristic are converted from `1/1024 s` to milliseconds.
- Current HRV metric: RMSSD / lnRMSSD after artifact correction.
- Current validated device: Polar H10.
- Phone camera PPG remains the secondary no-hardware capture path.
- Do not mix capture sources inside one personal baseline; switching source should recalibrate.

## Readiness Scoring
Canonical scoring spec: `docs/readiness-score.md`.

Current implementation notes:
- MVP inputs: lnRMSSD vs personal rolling baseline, resting HR, sleep, and subjective wellness.
- Subjective wellness uses soreness, mood, energy, sleep, and stress.
- Prior-day training load is deferred until workout logging and live HR-zone history exist.
- Cold-start should be conservative until enough personal readings exist.
- The score is a composite input into training decisions, not the product itself.

## HR Zones
Current zone implementation notes:
- Baseline computes zones from raw inputs instead of reading another app's zone settings.
- Current default method: Heart Rate Reserve / Karvonen.
- Fallback max-HR estimate: Tanaka.
- Supported overrides should include tested max HR and LTHR-based zones for run training.
- Zone history should be stored per relevant workout segment for later trends and learning.

## Exercise Catalog
Current catalog direction:
- Base dataset: `free-exercise-db`.
- Curated Baseline extension: HYROX stations, common functional movements, cardio modalities, mobility, warm-up, and chassis work.
- The alias map is critical for import quality, especially for variants like RDL vs deadlift.
- Content should remain hosted/versioned so adding exercises or guidance does not require an app release.

Current logging categories:
- Reps/load.
- Reps only.
- Holds.
- Isometrics.
- Distance.
- Distance/load.
- Calories.
- Time/zone.
- Pace/power summaries.

Current cardio metadata:
- Intent examples: easy/Z2, tempo/threshold, intervals/VO2, speed, long, race.
- Environment examples: treadmill, track, road/outdoor, trail.

## HYROX Stations
Current fixed station set:
- SkiErg.
- Sled Push.
- Sled Pull.
- Burpee Broad Jumps.
- Row.
- Farmers Carry.
- Sandbag Lunges.
- Wall Balls.
- Interleaved running.

Station and interval summaries should support rep count, distance, time, calories, average pace, best pace, power, and splits where relevant.

## Import Pipeline
Current implementation direction:
- Text to structured workout: Apple Foundation Models when available.
- Photo to structured workout: Vision OCR, then structured parsing.
- Cloud fallback: Claude API through a controlled backend path for messy or unsupported imports.
- Import should extract more than exercise names: day type, intensity, targets, duration, dose layers when present, and confidence.
- Low-confidence imports should be confirmed before becoming planned work.

## Conversation Context Assembly
- **Current (prototype):** the app sends the full durable structured state — today's plan plus all active constraints and today's logged context — to the model on every message. Acceptable for now: simplest correct behavior, and the state is still small.
- **Target:** assemble a *relevant* snapshot by intent instead of shipping the whole state every turn:
  `user message → detect intent → select relevant structured state → send context to model`.
  As state grows (goals, training history, multiple constraints, an imported program), sending everything wastes tokens and exposes irrelevant context. This selection belongs in the Context Engine, transparent to Decision/Planning.
- **User-facing framing:** describe this as Baseline using the athlete's *saved training profile, constraints, and daily context* across conversations — **not** as "memory," and not as replaying past chats. Baseline may speak naturally as though it knows saved facts, but privacy copy and internal language keep the distinction clear: it relies on saved structured state, not stored conversation logs.

## Persistence And Backend
Current direction:
- SwiftData is the local editing and in-flight UX source of truth.
- Firebase Auth and Firestore support sync, content delivery, and backend-assisted features.
- Firestore schema changes must be reflected in rules and deployed in sync with app changes.
- Raw health data and raw chat logs should not become backend source of truth; derived summaries and structured state are the durable records.

## Platform Notes
- iOS baseline and availability decisions belong here or in ADRs, not in durable product docs.
- Specific Apple API timelines should be treated as replaceable implementation assumptions.
- Any future provider choice for LLMs, OCR, storage, analytics, or subscriptions should be documented here or as an ADR when the decision becomes meaningful.
