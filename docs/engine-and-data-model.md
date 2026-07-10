# Baseline — Engine & Data Model

> The detailed, evolving "how it works under the hood" reference. Durable rules + product summary live in `CLAUDE.md`; this doc holds the depth and **will change as we build**. Companions: `docs/v0-spec.md` (scope + build order), `docs/design.md` (screens + design system).

## Vocabulary (use consistently)
- **Reading** — a morning HRV capture + the subjective check.
- **Exercise** — a catalog entry (a movement) with a logging type + tags + aliases.
- **Routine** — a reusable, editable *template* (ordered exercises with targets). Created in-app or produced by import.
- **Planned Session** — a dated intended workout instance (usually started from a Routine; can be ad-hoc). Source of truth for what Baseline or the athlete meant to do.
- **Workout Log / Performed Session** — the actual work performed: sets, reps, load, time, distance, pace, power, HR-zone history, skips, substitutions, notes, and pain events.
- **Session** — shorthand only when the planned/performed distinction is obvious. In storage and engine code, keep the distinction explicit.
- **Plan / Week** — Routines assigned to calendar days. This is what the engine reshuffles.

## The daily loop
morning **Reading** → **readiness score** → **today's recommendation** (a planned Session, proposed + editable) → **start workout** → **log performance** (sets/reps/load/time/distance/pace/power + live HR zones) → **add notes/context** → **complete or modify session** → **recompute training state** → **adapt the remaining plan**.

## Planned vs performed work
Baseline must preserve two records:
- **Planned work:** the intended session and exercise prescriptions, versioned through the Plan Repository.
- **Performed work:** what the athlete actually did, versioned through the Workout Log.

The performed log never overwrites the plan. It links back to the plan and records deltas: completed as prescribed, load changed, skipped, substituted, stopped early, moved later, or replaced after a constraint appeared. Those deltas feed the Learning Engine and can trigger explicit plan revisions.

Examples:
- Planned `4 x 5 min threshold + 6 x 30 sec speed`; performed threshold completed, speed skipped because calf pain appeared.
- Deadlift logged as `3 x 8 @ 185/205/225 lb`, with an exercise note: grip weak.
- Max-effort SkiErg pulls logged as `15 reps`, average pace `1:33/500m`, best pace `1:29/500m`.

Conversation is an interface over this model. Natural language like "my calf hurt so I skipped the speed work; move it later this week" becomes validated tool calls such as `skipExercise`, `createConstraint`, and `moveExerciseToLaterDate`, followed by a recompute.

## The recovery engine (applies in layers)
Job: answer "what should I train today, given my recovery?" — automating the week-reordering a coach otherwise hands back. It works at three levels depending on how much structure the content carries:

- **Layer A — dose-structured import (richest).** Some sources (e.g. a coach programming the Bayens method) bake **MED / HPL / MDV** into each day. If import captures that, the morning score **picks the dose**: `<60%` → MED, `60–79%` → MED-leaning aerobic, `≥80%` → +HPL / +MDV scaled to recent volume.
- **Layer B — classified import.** Most imports carry no dose layers, but the importer assigns a **day-type** (active-recovery / aerobic-capacity / intensity / strength — the taxonomy seen in real HYROX programming). The score decides **do it / sub a lighter routine from your pool / drop to recovery**.
- **Layer C — no plan.** Nothing planned → recommend from Baseline's **built-in chassis/recovery/aerobic library** (which also makes the recommendation real on day one, before any import exists).

**Incremental, not macrocycle.** Athletes receive programming a day or week at a time, so Baseline reasons over a **rolling window of what's been imported**, not a full periodized block.

**Recovery bands:** `≥80%` intensity OK · `60–79%` aerobic / sub-threshold only (defer scheduled intensity later in the week) · `<60%` active recovery / chassis.
**Hard constraints:** never two hard days in a row; a hard day is followed by aerobic or active recovery; batch intensity.
**Subjective overrides:** high stress or soreness can outrank a good HRV (recovered HRV + heavy DOMS → chassis/low-impact, not quality).
**Auto-reorder:** when it reshuffles a *loaded* week it **just does it** (not a suggestion) and shows the why — but it's a later feature (needs a populated week). For the incremental/coach-fed case the mechanism is dose-pick (A) + subbing recovery, not rescheduling days not yet received.

## Readiness score
> **Full spec: `docs/readiness-score.md`** — configurable inputs, capture sources, questionnaire, and the scoring math. Summary below.
- **Inputs (MVP):** lnRMSSD vs. personal rolling baseline (primary) · resting HR · **sleep (Apple Health, else the subjective sleep item)** · the **wellness questionnaire** (McLean 5: soreness / mood / energy / sleep / stress, oriented so 5 = best, + notes). **Prior-day training load is deferred from MVP** (needs logging + live zones first; then normalized sRPE / Edwards-TRIMP). Configurable = the athlete toggles *which inputs count*, not the weights.
- **Composite:** each present input → signed z-score vs baseline → weighted blend (HRV 0.50 / subjective 0.25 / RHR 0.15 / sleep 0.10), re-normalized over whatever's enabled → `50 + 22·z` clamped 0–100. High soreness/stress **hard-floors** the band at amber.
- **Cold-start ramp:** first ~14 readings have no reliable baseline → be conservative, lean on absolute values + age-population norms + the subjective check, show "calibrating." Never be absolute against a baseline that doesn't exist yet.
- **Output:** a **0–100 score mapped to a recovery band** (green ≥80 / amber 60–79 / red <60), surfaced as "how recovered you are + what to do today," which gates the dose (and later modulates target HR zones, Morpheus-style).

## Recovery capture (HRV)
- **Chest-strap-first.** BLE Heart Rate Service `0x180D`, Heart Rate Measurement characteristic `0x2A37`; R-R intervals (units 1/1024 s → ms = raw×1000/1024) → artifact-correct → **RMSSD / lnRMSSD**. **Validated on a Polar H10.**
- HRV math is a **pure function** (unit-tested without hardware). Sensor callbacks off-main; marshal to main for UI.
- **Don't mix sources in a baseline** — one source per baseline; switching sources re-enters cold-start.

## HR zones
Needed for the live in-session zone display (the "no more Polar Flow" feature) and for tagging cardio intent.
- **Derivation — computed by Baseline from raw Health data** (mirrors how Apple/Strava/Garmin do it): Heart-Rate-Reserve / **Karvonen** — `target = (maxHR − restingHR) × intensity% + restingHR`.
  - **Health connected:** age + resting HR + **observed max from workout HR history** → 5 zones. Personalized from day one; no "enter your max HR" wall.
  - **No Health:** Tanaka estimate (`208 − 0.7×age`) + entered/default resting HR → conservative zones.
  - **Refine** max/resting over time as strap + Health data accumulate.
  - **Override:** tested max HR, or **LTHR-based zones (Friel)** — gold standard for the threshold run work.
- There's no clean public API to read Apple's computed zone boundaries, so we read the raw inputs and compute — which also lets us offer LTHR zones Apple doesn't.
- **Live + history:** live zone shown per segment during a Session; per-segment HR + time-in-zone stored for trends.

## Exercise catalog
- **Base:** [free-exercise-db](https://github.com/yuhonas/free-exercise-db) — ~800 exercises, **public domain**, JSON + images. (Chosen over ExerciseDB's 11k [commercial + variation-bloat] and wger [CC-BY-SA share-alike].)
- **Curated Baseline extension** (the differentiator — general DBs lack these):
  - the **8 HYROX stations** (table below),
  - common **CrossFit / functional** movements used in HYROX training (thrusters, box jumps, KB swings, double-unders, burpees…),
  - **cardio modalities** (Run, Row, SkiErg, BikeErg),
  - the **mobility / chassis / warm-up library**: ankle inversion/eversion w/ bands, couch stretch, pigeon + incline-bench pigeon, banded hamstring, dead hangs (+ single-arm), single-leg RDL, toe/heel walks, A/B/C skips, front-back + lateral (Frankenstein) leg swings, Cossack (Kozak) squats, lateral band walks, multi-plane core, glute activation…
  - ~100–150 items to start; **content-driven** (grows without app releases). Create-custom supported.
- **Unified schema (both sources):** `{ id, name, source, loggingType, tags[], aliases[], muscles[], equipment[], media? }`.
- **Logging types:** `repsLoad` · `reps` · `timeHold` · `distance` · `distanceLoad` · `calories` · `timeZone`. (HYROX needs distance/load/calories, not just reps/load/time/holds.)
- **Aliases are the import-matching key** — e.g. RDL → "Romanian Deadlift" (+ variants/misspellings). This, not dataset size, is what makes "RDL ≠ generic deadlift" work.
- **Cardio = one modality + a structured `intent`** (`easy/Z2` · `tempo/threshold` · `intervals/VO2` · `long` · `race`) + environment (treadmill/outdoor). Trends slice by intent — no separate "easy run"/"threshold run" entries. SkiErg/Row double as both stations and training modalities (context is intent, not a different exercise).
- **Images:** free-exercise-db ships them; curated items use a placeholder for v0 (no custom illustrations yet — mirrors Ascend's missing-art handling).

### HYROX stations (fixed set)
| Station | Logs as |
|---|---|
| SkiErg 1000m | distance / time / calories |
| Sled Push 50m | distance + load |
| Sled Pull 50m | distance + load |
| Burpee Broad Jumps 80m | distance / reps |
| Row 1000m | distance / time / calories |
| Farmers Carry 200m | distance + load |
| Sandbag Lunges 100m | distance + load |
| Wall Balls 100 | reps + load |
| (8× 1km Run between each) | Run modality + intent |

A prebuilt **"HYROX Simulation"** Routine (the full fixed sequence) ships as content — one tap to log a race sim.

## Import pipeline (text / photo → Routine)
- **Text → Routine:** on-device **Apple Foundation Models** (`@Generable` guided generation → typed `Routine`/`Exercise` structs). Free, on-device, private (iOS 26+).
- **Photo → Routine:** **Vision** OCR (on-device, free) → Foundation Models structuring today; **native multimodal image input** when iOS 27 ships (fall 2026, announced WWDC26).
- **Cloud fallback:** Claude API (via Cloud Function) only for long / messy / handwritten inputs the on-device model can't handle reliably.
- **Import extracts more than the exercise list:** day-type / intensity classification, target zones, duration, and **dose layers (MED/HPL/MDV) when present** — that's what lets the engine reason. Low-confidence guesses get a one-tap **confirm / "did you mean?"**; the athlete owns the result.
- **Gating:** on-device parsing needs an Apple-Intelligence-capable device; image input needs iOS 27. Build-for-self runs on-device today; the broad-launch floor (and how much cloud fallback to ship) is a later decision.
- **Cost:** because the core path is on-device, import is **free** — monetization is not forced by AI costs.

## Demographics & comparison
- Collect **age + gender** (minimum) on the Firebase-backed profile; weight/height optional.
- Drives **population bell-curve positioning** (e.g. "among 25–29, here's where your HRV/readiness sits"). Privacy-safe, bucketed.

## Engagement
- **Streaks** (reading streak) + **reading-count** tracking + a **calendar** (completed sessions + what was done each day).
- **Notifications:** a user-set **morning reading reminder** + a soft missed-reading nudge. No punishing streak mechanics — a recovery app shouldn't guilt rest.

## Data entities (sketch — SwiftData on device, mirrored to Firestore; will evolve)
- **Profile** — uid, age, gender, (weight/height), HR-zone config, baseline state, settings.
- **Reading** — date, lnRMSSD, RMSSD, resting HR, R-R series ref, subjective check, sleep snapshot, readiness score + band, source.
- **Exercise** — catalog entry (schema above).
- **Routine** — title, tags, source (created/import), ordered `RoutineItem`s; day-type / dose metadata when known.
- **RoutineItem** — exercise ref, targets (sets/reps/load/time/distance/zone/intent), notes.
- **PlannedSession** — date, source Routine ref, status, ordered `PlannedSessionItem`s, accepted plan version, intended prescription.
- **PlannedSessionItem** — exercise ref, targets (sets/reps/load/time/distance/zone/intent), rest, prescription notes.
- **WorkoutLog / PerformedSession** — source PlannedSession ref (optional for ad-hoc), start/end, status, ordered performed exercises, HR series + per-segment zone summary, completion.
- **PerformedExercise / SetLog / IntervalLog** — actuals per the exercise's logging type, plus completion state (completed/skipped/substituted/modified), notes, and reason.
- **WorkoutEvent** — pain event, constraint update, substitution, skipped work, moved work, pause/resume, note.
- **Plan** — date → planned Session assignments (the reshuffle surface).
- **HRZoneConfig** — method (HRR / LTHR), max HR, resting HR, zone bounds, source (estimated/observed/tested).

## Architecture notes
- Sensor capture behind a service layer; HRV + readiness + zone math are **pure functions** (unit-testable, no hardware/view tree).
- Workout execution is its own engine boundary: start planned/ad-hoc workout, log actuals, record modifications, update constraints, recompute remaining work, and request versioned plan revisions from the Plan Engine.
- Content-driven: catalog, curated extension, built-in library, and any authored programs are **hosted/versioned content** — adding content never requires an app release.
- Firebase Auth + Firestore from day one (same setup as Ascend). Firestore schema changes follow the strict-rules update order (see `CLAUDE.md`).
