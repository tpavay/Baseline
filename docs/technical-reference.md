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
- A completed session persists its measured heart rate in two pieces: a small summary (average, max, sample count, seconds per zone, and a snapshot of the zone boundaries in force at completion) on `WorkoutLog`, and the full-resolution sample trace in its own local entity, `SDWorkoutHeartRateSeries`, keyed by `scheduledWorkoutID`.
  The trace never rides on the log blob - `WorkoutLog` is re-encoded on every logged set.
  The snapshot is why editing max HR later cannot silently re-band a past workout's chart.
- Time in zone on a completed workout is measured only.
  A planned prescription is intent and is never rendered as time in zone.
- Capture happens at completion, not mid-session; re-entering a live workout restarts the trace alongside zone time and session stats.
- Series stay on device.
  A Firebase Storage sidecar (gzipped, versioned) is built behind `WorkoutHeartRateStorageRepositoryProtocol` but has no call site until durable workout sync exists to hang it off; `storage.rules` denies those writes today.
- Per-segment zone history is still unbuilt - the stored record is per session.

## Exercise Catalog
Current catalog direction:
- Base dataset: `free-exercise-db`.
- Curated Baseline extension: HYROX stations, common functional movements, cardio modalities, mobility, warm-up, and chassis work.
- The alias map is critical for import quality, especially for variants like RDL vs deadlift - and it is exactly where the catalog is thinnest.
  Coverage is curated-only: only the hand-written built-ins carry aliases, and all 873 `free-exercise-db` imports carry none, so "RDL" resolves to nothing and an imported movement is reachable by name alone.
  Backfilling import aliases is a known gap; `importedExercisesAreFoundByNameSinceTheyCarryNoAliases` in `BaselineTests/ExerciseSearchTests.swift` pins the current state, so closing the gap is a deliberate change rather than an accident.
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
- Import output is the ordinary reviewed `WorkoutDraft`; models never write canonical workout or plan state directly.
- Text to structured workout: Apple Foundation Models when available, with a bounded cloud compatibility path.
- Photo to structured workout: Vision OCR evidence, then structured parsing; complex layouts may later route the normalized image plus OCR evidence to a multimodal parser.
- Provider output becomes validated semantic transactions applied to a transient `CandidateGraph` inside `ImportSession`.
- Deterministic normalization, catalog resolution, unit conversion, and structural audit construct the ordinary `WorkoutDraft` before atomic ownership handoff.
- The editor never renders OCR, candidates, provider output, or structurally invalid workout content.
- Cloud parsing uses a controlled backend path with task-specific models, authentication, App Check, quotas, and strict request/response schemas.
- Import should extract more than exercise names: day type, intensity, targets, duration, dose layers when present, and confidence.
- Low-confidence imports should be confirmed before becoming planned work.
- Full implementation plan: `docs/implementation/workout-image-import.md`.

## App Capabilities In Conversation
- Baseline injects **live capability state** into the conversation (supported? current status? which action tool?), not static prose — the model must answer "how do I…/can I…" from runtime state, never from documentation that can go stale (e.g. claiming Health is disconnected when it's connected, or describing a moved control).
- Current: Apple Health (supported via `HKHealthStore.isHealthDataAvailable()`; connected approximated by whether access was requested — HealthKit hides read-authorization status) and HRV reading (supported; chest strap / camera; configured from the reading source). Exposed as a "Baseline capabilities right now" line.
- Action tools let Baseline *do*, not just describe: `open_apple_health_setup` presents the system Health permission sheet. Planned: `open_hrv_setup`, `open_settings_section` (need chat→screen navigation plumbing).
- Rule: speak as the product; never punt to "support" for built-in functionality; only say something is unavailable when capability state says so.

## Metrics, Units & Exercise Catalog (design → build sequence)
Durable concept in `docs/engine-and-data-model.md` (three-layer identity/metrics/units model). Implementation:
- **Canonical storage:** distance → meters, load → kilograms, time → seconds, energy → calories, pace → seconds per meter, and power → watts.
  Athlete-facing pace choices are `/500m`, `/km`, and `/mi`; exact conversion happens only at the input/display boundary, so changing the display unit cannot corrupt history.
- **Exercise Definition catalog:** stable ids, supported-metric sets, activity category (cycling, running, erg, carry, …), and an alias map (`free-exercise-db` + curated extension, hosted/versioned).
- **Per-instance logging config:** each Planned Exercise selects which supported metrics are visible + preferred display units. Unselected metrics render no field.
- **Preferences:** user-level per-exercise defaults ("use km for Stationary Bike from now on"), overridable per workout.
- **Tools:** `update_logging_config` and `update_exercise_preference` are built and target stable IDs; history retrieval (`get_exercise_history(exercise_id, metric, unit)`, `get_category_history(category, date_range)`) is still planned. `functions/src/tools.ts` owns the tool schemas. The agent resolves aliases → ids and asks when scope (this workout / future default / this exercise / whole category) is ambiguous.
- **Build order:** (1) canonical units + display conversion (built, including pace); (2) exercise-definition catalog + categories + aliases; (3) per-instance logging config + selectable fields in UI; (4) user preferences; (5) history persistence, then the history/category retrieval tools.

## Response Style By Intent
The conversation should adapt presentation to the question's intent, not just retrieve and answer literally. Three kinds:
- **Retrieval** ("what was my sleep / HRV?") → call the tool, then lead with **insight**, offer raw numbers second (don't dump telemetry like "76 ms, 140 ms"; interpret it).
- **Education** ("what is HRV?") → answer from general knowledge, no tools, no personal-data retrieval. Currently handled by the prompt; **eventually a Knowledge layer** — curated educational content (not an engine), so "explain HRV" answers like Baseline's own curriculum rather than generic AI.
- **Personal reasoning** ("what should I do today?") → reason over state + tools, recommend with a one-line why.
Later: proactive/curious prompts ("your sleep's been great three nights but HRV hasn't risen — want to see why?") turn search into coaching. And UI affordances (tap Sleep → Explain) should augment the chat, not require typing.

## Retrieval Tools (agent architecture)
Baseline is retrieval-first, not memory-first. Implementation principle: **never answer from memory (injected state) if a tool can answer more accurately.** When the athlete asks about current or historical data, the model calls a retrieval tool rather than answering from the context block or claiming it doesn't have the data.
- **Split execution (iOS constraint):** the cloud model *proposes* a tool call; the **iOS app validates and executes it locally** — HealthKit lives on-device and the Firebase function cannot query it — then returns a structured result the model answers from. This is the real agent loop, already present in `ConversationService` (`execute`).
- **Current retrieval tools:** `get_sleep(nights_ago)` (HealthKit sleep stages/durations + Baseline's own computed score, kept distinct), `get_hrv_readings(limit)` (Baseline's reading store).
- **Expanding surface** (discovered by using Baseline as a coach — each "I can't…" is a backlog item, not a brainstorm): `get_workout_history`, `get_exercise_history`, `get_workout_by_date`, `get_program`, `get_plan_history`, `get_prs`, `get_exercise_progress`, `compare_workouts` — plus `get_heart_rate_zone_minutes`, `get_readiness(date)`, `get_constraint_history`. The persistence side now exists (completed session logs are stored append-only per scheduled workout - `SDCompletedLog`/`SDCompletedExercise` in `Baseline/Shared/Persistence/PlanEntities.swift`); the retrieval tools themselves are still unbuilt.
- **Raw vs. derived:** Apple Health supplies stages/durations, not a universal "sleep score." Any score is Baseline's derivation; never present a Baseline score as an Apple metric.
- **No inference of absence:** don't conclude a signal is missing from low certainty — check the source with a retrieval tool.

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
