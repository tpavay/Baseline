# Baseline — v0 Build Spec

**One-liner:** *One reading. One decision. The recovery-aware HYROX coach that tells you what to train today — and why.*

> Scope + build order. Engine / data-model / catalog detail: `docs/engine-and-data-model.md`. Design: `docs/design.md`. **Evolving** — the current plan, not a contract.

## The reshape (how v0 actually works)
- **Import-first, not authored-program-first.** Writing a full program is too much work, and most athletes already get programming elsewhere. So the primary content path is **type or photograph a workout → native, loggable Routine** (on-device Apple Foundation Models; free). Baseline's own authored program is deferred.
- **Firebase Auth + Firestore backend from day one** (same setup as Ascend).
- **Build-for-self first** (Tyler), then open up.
- **The engine modulates by recovery in layers** (A: dose-pick coach content · B: classify → do/sub/recover · C: built-in library) — see the engine doc.
- **Live in-session HR zones** is a flagship, not a nice-to-have — one app, no more Polar Flow.
- **Monetization deferred** to the end; **not** forced by AI cost (import runs on-device for free).

## Priority stack (build order)
1. **The spine (= the launch MVP)** — Reading → readiness score → band guidance + HR zones. HRV (✅ validated on H10) + the configurable readiness composite + band-level guidance copy ("intensity is on" / "keep it easy — active recovery") + zones for anyone with an HR source (capped on low days: "stay in Z1–Z2"). **No session prescription at launch** (decided 2026-07-07) — the score, the guidance, and the zones are the product; concrete sessions arrive with priority 5. User-facing copy never says "chassis" — say "active recovery" / "mobility" (chassis stays internal/engine vocabulary).
2. **Usable daily** — exercise catalog + heterogeneous logging + **live HR zones** + complete → **calendar / streak**. (Off Polar Flow immediately.)
3. **Import: text → Routine** (on-device FM) + auto day-type classification.
4. **Import: photo → Routine** (Vision OCR now / native image input on iOS 27).
5. **Recovery modulation & session recommendation** — dose-pick (A) + do/sub/recover (B) + recommend from the built-in active-recovery/aerobic library (C). This is where "what to do today" becomes a concrete session — post-launch.
6. **Auto-reorder** the loaded week.
7. **Trends** depth + the age/gender **bell-curve** positioning.

## What v0 ships
The spine (1) + a daily-usable logger with live zones (2) + text/photo import (3–4) + recovery modulation (5), for **one athlete (you) first**, with the **chassis/recovery library** as the built-in differentiator.

**Launch cut (2026-07-07):** ship (1) alone first — the configurable score + zones is a complete, honest product (see the mocked screen set). 2–5 layer on after launch.

## What v0 defers (YAGNI)
Baseline's own authored periodized program · auto-reorder polish · multi-block periodization · 2nd/3rd tracks · video movement analysis · nutrition · social/community · leaderboards · wearable capture (Apple Watch stays context/seed-only) · the paywall. (Camera PPG moved INTO launch, 2026-07-07.)

## Reading flow (locked — see design.md; scoring in `readiness-score.md`)
live preview → quiet **2:30 timed read, breathing naturally** (no paced cues — pacing shifts HRV via respiration; decided 2026-07-07; dark screen, still ambient orb, single R-R curve building across with bpm Y-axis + seconds X-axis, live HR/HRV, bell + haptic at the end) → **averages** → **wellness check** (McLean 5: soreness / mood / energy / sleep / stress, 1–5; Save & continue / Skip) → **readiness score + band + today's guidance** (a recommended session replaces plain guidance when priority 5 ships). Standardization comes from consistent time + posture + natural breath, not breath control.
- **Reading sources at launch (2026-07-07):** chest strap **and camera PPG** both ship at launch; subjective-only remains valid (HRV/RHR drop out, weights re-normalize). Onboarding is **config-first**: the Readiness Formula screen (defaults pre-checked) drives which setup steps follow — keeping the heart reading on leads to a source choice (strap = ECG-grade, recommended · camera = optical, no hardware), each a 2:30 guided reading. Formula rows name **metrics, not sources** ("Morning Heart Reading — HRV + resting HR"); the source is its own configuration. Apple Watch seeds baseline/context only — it can't do a live paced read.

## Information architecture (decided 2026-07, designed in the mock set)
Tabs: **Today / History / Profile**. Today = score (semicircle gauge) + band guidance + zones card; History = readiness trend chart + day list → day detail (composed of per-input sections from that day's snapshot); Profile = settings incl. Readiness Setup, Heart Rate Zones, Devices. **Train** joins as a 4th tab when logging/programs ship (priority 2+).

## Monetization & legal
- Subscription later (RevenueCat + SuperWall); on-device import means no cost pressure to gate early.
- **No PAR-Q, no standalone disclaimer screen** (decided 2026-07 — cut for onboarding friction; see CLAUDE.md): assumption-of-risk lives in the ToS, accepted via a one-line footnote at the onboarding commitment step, plus a contextual "training guidance, not medical advice" line on guidance surfaces. Keep the **HYROX® trademark disclaimer**; lawyer-reviewed ToS. (Baseline prescribes intensity → cardiac-risk surface.)

## Open decisions (smaller now)
- True max HR / LTHR known, or seed-from-Health + refine? (no blocker — defaults to seed.)
- v0 launch device/OS floor (on-device AI needs a recent iPhone; image input needs iOS 27).
- Eventually: who authors Baseline's own program (you + HYROX L1 vs. partner a coach), and HYROX-naming caution in copy/ASO.
