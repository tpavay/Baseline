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
1. **The spine** — Reading → readiness score → "what to do today." HRV (✅ validated on H10) + readiness composite + recommendation. Real on day one by recommending from the **built-in chassis/recovery/aerobic library**.
2. **Usable daily** — exercise catalog + heterogeneous logging + **live HR zones** + complete → **calendar / streak**. (Off Polar Flow immediately.)
3. **Import: text → Routine** (on-device FM) + auto day-type classification.
4. **Import: photo → Routine** (Vision OCR now / native image input on iOS 27).
5. **Recovery modulation** — dose-pick (A) + do/sub/recover (B/C).
6. **Auto-reorder** the loaded week.
7. **Trends** depth + the age/gender **bell-curve** positioning.

## What v0 ships
The spine (1) + a daily-usable logger with live zones (2) + text/photo import (3–4) + recovery modulation (5), for **one athlete (you) first**, with the **chassis/recovery library** as the built-in differentiator.

## What v0 defers (YAGNI)
Baseline's own authored periodized program · auto-reorder polish · multi-block periodization · 2nd/3rd tracks · video movement analysis · nutrition · social/community · leaderboards · camera/wearable capture (strap-first) · the paywall.

## Reading flow (locked — see design.md)
live preview → guided breathing **2:30 @ 5s/5s** (dark; orb cue; single R-R curve building across with bpm Y-axis + seconds X-axis; live HR/HRV) → **averages** → **quick check** (mood / energy / stress / soreness; Save & continue / Skip) → **recommended session**.

## Information architecture (proposed)
Tabs: **Today / Train / Trends**, with **Profile + Settings** behind a gear. (Confirm as we design.)

## Monetization & legal
- Subscription later (RevenueCat + SuperWall); on-device import means no cost pressure to gate early.
- Ship the **medical disclaimer** + **PAR-Q** at onboarding + **HYROX® trademark disclaimer**; lawyer-reviewed ToS. (Baseline prescribes intensity → cardiac-risk surface.)

## Open decisions (smaller now)
- True max HR / LTHR known, or seed-from-Health + refine? (no blocker — defaults to seed.)
- v0 launch device/OS floor (on-device AI needs a recent iPhone; image input needs iOS 27).
- Eventually: who authors Baseline's own program (you + HYROX L1 vs. partner a coach), and HYROX-naming caution in copy/ASO.
