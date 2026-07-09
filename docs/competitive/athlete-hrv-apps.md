# Competitive teardown — athlete morning-HRV → training-guidance apps

Research date: 2026-07-08. Covers HRV4Training, Athlytic, Training Today, Elite HRV, Gentler Streak
— the apps closest to Baseline's core loop. **Through-line: all stop at an intensity signal (a
word, a %, a traffic light, a number, or a manual menu). None prescribes a full recovery-aware
session.** That gap is Baseline's thesis.

---

## 1. HRV4Training — the technical benchmark (Marco Altini)

The one to study hardest. Altini is an HRV researcher; the methodology is the most transparent and
defensible in the category, and **Baseline's readiness math is modeled on it**.

**Reading:** pioneered **camera PPG** (fingertip over rear camera + flash, ~**60 s**, morning, same
posture, **natural breathing** — no pacing). Validated ≈ Polar H7 strap ≈ ECG. Optional BLE strap +
Apple Health. Rationale = standardize by consistent time + posture + natural breath to capture
*chronic* baseline stress before acute stressors hit — exactly Baseline's 2:30 protocol rationale.

**Score & method (model on this):**
- **RMSSD → lnRMSSD**, scaled to friendly "Recovery Points" (~6–10 range) so users don't stare at ms.
- **Baseline = 7-day moving average; "normal range" = a band from the past ~60 days.** Two
  timescales: 7-day baseline scored against a ~60-day normal band.
- **Coefficient of variation (CV)** is a first-class fatigue signal — a *rising* CV flags poor
  adaptation even when the mean looks fine.
- **Smallest-worthwhile-change** is operationalized by the band: deviations *inside* the band are
  noise; only excursions *outside* it count. No single hard ms threshold.
- Daily advice weighs day-over-day change, deviation from 7-day baseline, position vs 60-day band,
  subjective tags, and recent trend — not raw HRV alone. Pro classifies stable / coping /
  maladaptation / accumulated-fatigue.

**Guidance (consecutive-days-below-normal logic — a de-facto recovery engine):**
- In/above normal → train as planned.
- Below 1 day → proceed, maybe trim volume ("one low day means very little").
- Below 2–3 consecutive → swap intensity for moderate/easy.
- Below 4+ with rising CV → genuine recovery day(s).
- **Ceiling:** outputs an *intensity word* (hard/easy/rest), never a session, zones, or volume. The
  athlete translates "go easy" into an actual workout. Coach tier can hide the advice so the human
  coach owns the call.

**Data:** HRV/lnRMSSD/CV, HR; **tags** — sleep quality, mental energy, muscle soreness, stress,
alcohol, travel, menstruation, illness, training type/intensity + custom; Strava load; sleep.

**Monetization:** ~**$9.99 one-time** app; Pro web ≈ **€45/yr**; Coach tier for remote athlete config.

**Baseline takeaway:** match the math (lnRMSSD, 7-day-vs-60-day band, CV as fatigue signal,
excursion-only significance) and the tag set. **Exceed** it by turning the intensity word into a
dose-layered, loggable session — the layer HRV4Training deliberately hands to a coach.

---

## 2. Athlytic — Apple Watch recovery, deliberately no prescription
- **Reading:** none active — overnight **Apple Watch HRV (RMSSD) + RHR**. Passive, no ritual.
- **Method:** Recovery % vs a **60-day rolling personal baseline**, **HRV weighted slightly above
  RHR**. Second metric = cumulative 7-day **Effort Score** (strain).
- **Prescription:** **none by design** — "a recovery and readiness tool, not a training planner."
  (Reviews pair it with a separate coach app, Cora, for actual prescriptions.)
- **Monetization:** free + **Pro ≈ $2.99/mo or $24.99/yr**.
- **Takeaway:** validates the passive-overnight path (a Baseline fallback via Health). Its explicit
  refusal to prescribe is the exact seam Baseline occupies; 60-day baseline / HRV>RHR mirrors
  Baseline's established-phase math.

## 3. Training Today — the minimalist traffic light
- **Reading:** passive, continuous Apple Health/Watch.
- **Method:** **Readiness To Train (RTT)** = HRV 60-day avg vs a rolling ~24-hour window, blended
  with RHR, respiratory rate, sleep. HRV-first, updates all day.
- **Prescription:** a **traffic light** — high/medium/low intensity. Explicitly "doesn't prescribe
  specific workouts." Overtraining guardrail.
- **Monetization:** free + one-time **~$10–15** Pro.
- **Takeaway:** purest score-only competitor; validates a **free-tier MVP = score + traffic-light
  band**. Its 24h-vs-60d window is a lighter variant of the 7d-vs-60d model.

## 4. Elite HRV — measurement instrument, freemium
- **Reading:** **chest strap primary**, camera secondary. **"Morning Readiness"**, natural breathing,
  same position.
- **Method:** Morning Readiness score + ANS-balance gauge; both time- and frequency-domain metrics
  (research-instrument depth). Also guided-breathing biofeedback.
- **Prescription:** effectively **none** — the number, trends, ANS interpretation. Coaching lives in
  a separate Team platform.
- **Monetization:** freemium + small IAPs + paid coaching platform.
- **Takeaway:** the "measurement instrument that stops at the number" CLAUDE.md names. Widest
  score→training gap of the five. Strap R-R + natural-breath read directly comparable to Baseline's
  strap path.

## 5. Gentler Streak — the anti-overtraining tracker (brief)
- **Reading:** passive Apple Watch/Health (HR, workouts, sleep); HRV is one input, not a headline read.
- **Method:** models a "Path of Effort" and "Path of Rest" + morning vitals/sleep summary → energy /
  readiness, wellbeing-framed rather than a precise HRV score.
- **Prescription:** **most session-like of the group** — "Go Gentler" lets you pick rest / active
  recovery / strength / cooldown and suggests workouts responsive to readiness. But it's a **manual
  menu**, not a recovery-computed dose. Closest to Baseline's red-day pivot in spirit.
- **Pedigree:** 2022 Apple Watch App of the Year; 2024 Apple Design Award (Social Impact) — a UX bar.
- **Takeaway:** proves "active recovery / rest as a productive choice" sells (aligns with the MVP
  note to say "active recovery," never "chassis"). Its polish is the design benchmark; but "Go
  Gentler" chooses, it doesn't compute the dose.

---

## The market seam (one line)
Every competitor lands on an **intensity signal** — a word (HRV4Training), % + effort (Athlytic), a
traffic light (Training Today), a number (Elite HRV), or a manual menu (Gentler Streak). **None
computes a recovery-aware, dose-layered, loggable session.** HRV4Training's consecutive-day logic is
the closest to Baseline's engine — and it deliberately hands the session back to a human coach.

Sources: [HRV4Training Pro guide](https://marcoaltini.substack.com/p/hrv4training-pro-user-guide) ·
[Altini — HRV-guided training](https://medium.com/@altini_marco/heart-rate-variability-hrv-guided-training-to-improve-performance-24b0ec24e6f8) ·
[Altini — variability in variability (CV)](https://marcoaltini.substack.com/p/variability-in-variability) ·
[Athlytic recovery](https://athlyticapp.helpscoutdocs.com/article/20-understanding-recovery) ·
[Training Today method](https://trainingtodayapp.helpscoutdocs.com/article/84-how-training-today-works) ·
[Elite HRV FAQ](https://elitehrv.com/faq) · [Gentler Streak](https://gentler.app/)
