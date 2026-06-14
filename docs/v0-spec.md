# Baseline — v0 Build Spec

**One-liner:** *One reading. One decision. The recovery-aware HYROX coach that tells you exactly what to train today — and why.*

## What v0 ships
Morning reading → readiness score → today's session at the right **dose**, in zone language, with the **why** — for **one track**, with the **chassis red-day pivot** as the signature differentiator, and full in-app logging.

## What v0 defers (YAGNI)
Video movement analysis · nutrition · social/community · the MDV leaderboard · multi-block periodization · the 2nd/3rd tracks · camera/wearable capture (strap-first for v0).

## The engine (the answer to "how does it know what to advise?")
```
1. Onboard → pick TRACK by limiting factor (Running / Strength-endurance / Open)
2. Each day in the track = ONE session authored at 3 cumulative doses (MED / +HPL / +MDV)
3. Morning RECOVERY reading picks the dose:
     ≥80%  → intensity OK (programmed/full), scaled to recent weekly volume
     60–79% → aerobic / sub-threshold (MED-leaning); defer scheduled intensity later in week
     <40–60% → active recovery / CHASSIS pivot
   Hard constraints: never two hard days in a row; batch intensity.
   Subjective overrides: high stress / high soreness can outrank a good HRV.
4. Present the chosen dose as a session card + the "why" + zone targets + substitutions.
```
Each authored day carries metadata: `{ type, microcycleRole, doses:{MED,HPL,MDV} }`. Recovery % picks the dose; the plan's structure constrains which is wise.

## Recovery capture
- **Chest-strap-first** (BLE HRS `0x180D`, R-R intervals → artifact-correct → RMSSD). Wearable-via-HealthKit fallback; no-device → recommend a strap.
- Reading flow: **live preview** (clean-signal check) → guided breathing **2:30 @ 5s/5s** resonance (dark; orb cue top-middle; single R-R curve building across with bpm Y-axis + seconds X-axis; live HR/HRV) → **averages** (HRV + HR) → **quick check** (mood/energy/stress/soreness; interactive; Save & continue / Skip) → **recommended session**.
- Cold-start: first ~10–14 readings show "calibrating," run the plan unmodulated / conservative. Don't fake a baseline.
- Don't mix sources in a baseline.

## Screens (built in Figma)
- **Daily Home** — readiness gauge (zone color), today's session card, violet CTA, bottom nav. States: Pre-reading / High (green) / Moderate (amber) / Low (red → chassis).
- **Morning Reading flow** — preview → 6 breathing states → averages → quick check → recommended.
- **Day recommendations** — same screen across input combinations (prime / sore-legs / moderate / high-stress override / low chassis / recovered-but-sore), showing how the check reshapes the call.
- **Session detail** (next) — Goal / Warm-up / Work (zones) / Why / substitutions; proposed-but-editable (add from bank or custom, reorder, log reps/load/time/holds).

## Logging & exercise bank
- Session = ordered, editable exercise list. Engine proposes pre-filled; athlete owns it.
- Tagged exercise bank + create-custom. Log reps / load / time / isometric holds. Add + reorder within the session.
- Lean on HealthKit / existing loggers for detailed strength history where sensible; Baseline owns the reading, session selection, completion, runs/stations/chassis.

## Programs
- Source-agnostic. Flagship = Baseline's authored HYROX program (full modulation). Coach-administered / own-notes / imported = log + recovery-guidance overlay + chassis recommendations.

## Monetization & legal
- Subscription (RevenueCat); free trial that lets the daily loop be felt before the wall (SuperWall).
- Medical disclaimer + PAR-Q at onboarding + HYROX® trademark disclaimer. Lawyer-reviewed ToS.

## Build sequence
- **v0.1** strap capture + reading (with cold-start) → one Open-track program (dose-structured days) → daily home → session card → completion + logging.
- **v0.2** chassis red-day pivot + the subjective check overrides.
- **v0.3** Running / Strength-endurance tracks + weakness diagnosis + LLM "why" narration.
- **v0.4** paywall + polish + the why-education curriculum.

## Open decisions
- Who authors the program (Tyler + HYROX L1 cert vs. partner a coach).
- Launch track (recommend **Open / once-a-day** — the serious-amateur audience, not 2-a-day pros).
