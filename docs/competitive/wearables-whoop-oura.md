# Competitive teardown — WHOOP & Oura (the readiness wearables)

Research date: 2026-07-08. Sourced from developer.whoop.com, support/blog pages, ouraring.com +
support, peer-reviewed validation studies, and reputable third-party press. Neither publishes exact
input weights (proprietary, personalized). These two are the archetypes CLAUDE.md defines Baseline
*against*: "Not a passive readiness score (Whoop/Oura) — every reading ends in a concrete session."

---

## WHOOP

**Recovery score (0–100%).** Overnight composite of **HRV (heaviest single input), resting HR,
respiratory rate, sleep, skin temp, SpO₂**, each vs a **rolling ~30-day personal baseline**. HRV =
**RMSSD**, measured **during sleep**, weighted toward the **last slow-wave (deep) sleep period**.
- **Bands:** **Green 67–100 / Yellow 34–66 / Red 0–33.**

**Strain (0–21) + Strain Coach — the recovery→target bridge.** Strain is a **logarithmic** load
scale modeled on Borg RPE (Light 0–9, Moderate 10–13, High 14–17, All-Out 18–21). Computed from
time in HR zones weighted by personal max HR, aggregated across the whole day, and **recovery-
adjusted** (same workout scores higher strain when you started under-recovered). Each morning WHOOP
issues a **Strain Target range** from today's recovery: exceed it = "overreaching," stay under =
"restoring." Third-party typical targets ≈ **10–14 on red/recovery days, 14–18 on green days** (WHOOP
doesn't publish a clean band→target table). **It stops at a strain *number*, never a session.**

**HR zones:** five, defined by **Heart-Rate Reserve (Karvonen)** using max HR *and* current resting
HR — so zones auto-shift as fitness improves. **This is the same HRR/Karvonen approach Baseline's
CLAUDE.md specifies — direct convergence.** Weekly guidance ~75% in Z1–3, ~25% in Z4–5.

**Data collected:** HRV, RHR, respiratory rate, SpO₂, skin temp (the 5 "Health Monitor" vitals);
continuous HR (52 Hz), sleep stages/performance/debt, strain + muscular load, HR-zone time,
calories, Stress Monitor, Menstrual Cycle Insights, Healthspan ("WHOOP Age"), and on WHOOP 5.0/MG:
on-demand ECG, irregular-rhythm alerts, daily blood-pressure insights. **WHOOP Coach** = generative-
AI narration.

**Monetization:** subscription with hardware bundled — **One $199/yr, Peak $239/yr, Life $359/yr**.
~2.5M+ members, ~$260M revenue (2025); later reporting cites a ~$10.1B valuation (verify).

**Relevance to Baseline:** the recovery→strain-target logic and HRR/Karvonen zones are the parts
worth pattern-matching. WHOOP stops precisely at the boundary Baseline crosses — score → strain
*number*, never "here's today's actual session, editable and loggable."

---

## Oura

**Readiness score (0–100).** Seven contributors in three pillars, **no published weights**:
- *Sleep:* Previous Night, Sleep Balance (14-day).
- *Activity:* Previous Day Activity, Activity Balance (14-day vs 2-month).
- *Body Stress:* Resting HR, **HRV Balance (14-day avg vs 3-month avg)**, **Body Temperature
  deviation** (heavily weighted — an illness-signal off-baseline temp tanks the score), + a separate
  **Recovery Index** (recovery sleep after nightly HR nadir).
- HRV = **nocturnal RMSSD** from finger PPG, computed in 5-min segments across the night (daily value
  historically = highest-RMSSD 5-min window).
- **Bands:** **85–100 Optimal / 70–84 Good / <70 Pay attention.**

**Activity score + recovery→goal bridge.** Oura sets a daily activity goal, then **auto-scales it by
that morning's readiness**: readiness >85 → goal raised; <70 → goal lowered. **You cannot manually
override** ("your body knows best"). This is the only place recovery mechanically changes a target —
and it's a movement/calorie goal, not "do intervals vs mobility." **Daytime Stress** (HR + HRV +
motion + temp vs a daily-recalibrated baseline) → Stressed/Engaged/Relaxed/Restored, every 15 min.

**HR zones:** six (Z0–5) from a **plain age-based %-of-max-HR** (override with known max). *Not*
Karvonen/HRR or LTHR — a differentiation opening for Baseline. **The ring does NOT stream live HR to
screen**; live-workout HR requires pairing a **third-party BLE chest strap** (Polar H10 etc.) — i.e.
"bring your own strap," the same live-zone gap Baseline's strap-native tracking closes.

**Data collected:** 50+ biometrics — sleep stages/efficiency/regularity, RHR, nocturnal HRV,
**Cardiovascular Age**, **VO₂ Max (guided walk test)**, temp deviation, SpO₂ + Breathing Disturbance
Index, respiratory rate, steps/calories/40+ activity types, Readiness/Stress/Resilience, Symptom
Radar, Cycle Insights (+ Natural Cycles), chronotype.

**Monetization:** **ring $349–$499 + membership $5.99/mo or $69.99/yr** (scores free; everything else
gated). ~$11B valuation (Oct 2025), on pace for 5M+ paid members and ~$2B 2026 sales; filed for IPO.

**Relevance to Baseline:** the passive "readiness + generic movement goal" competitor. No session
prescription, no HYROX programming, no dose model, plain %-max zones, no native live HR. The
prescription layer and strap-native live-zone tracking are clean differentiation lanes.

Sources: [WHOOP 101 (dev)](https://developer.whoop.com/docs/whoop-101/) ·
[WHOOP HRR zones](https://www.whoop.com/us/en/thelocker/why-whoop-uses-heart-rate-reserve-not-max-heart-rate/) ·
[Oura Readiness Contributors](https://support.ouraring.com/hc/en-us/articles/360057791533-Readiness-Contributors) ·
[Oura Activity Score](https://support.ouraring.com/hc/en-us/articles/360025577993-Activity-Score) ·
[Oura Live Activity Tracking](https://support.ouraring.com/hc/en-us/articles/50433376859283-Live-Activity-Tracking) ·
[Oura nocturnal RMSSD validation (MDPI 2024)](https://www.mdpi.com/1424-8220/24/23/7475)
