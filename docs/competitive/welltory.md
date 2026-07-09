# Competitive teardown — Welltory (welltory.com)

Research date: 2026-07-08. Sourced from welltory.com, help.welltory.com, and third-party press.

Welltory is the closest analog to Baseline's *reading* mechanic — same camera-PPG morning HRV
read — but it stops at measurement + correlation insight and never prescribes training. That gap is
Baseline's opening. Bootstrapped (no VC), ~$14M revenue (2024), 70% YoY growth, ~9–10M users.

## The reading
- **Camera / fingertip PPG** (flash-lit fingertip, ~2 min) OR **BLE ECG chest straps** (Polar,
  Garmin) OR wearable HRV via **Apple Health / Health Connect / Samsung Health**. (Note: Welltory
  ingests wearable HRV as a first-class *reading* source; Baseline treats wearable-via-HealthKit as
  history/context only.)
- **Protocol:** same position every time (sit or lie), wait 3–5 min after activity, **"don't talk,
  move, or control your breathing"** — independently confirms Baseline's natural-breath decision.
  Same finger/hand, don't press hard.
- **Live quality hints** during the read + a **post-read accuracy score** — retake below 95%,
  auto-discard below 30%. (Table-stakes UX for any camera read.)

## Metrics & scores
- **Raw HRV:** time-domain (RMSSD, SDNN, pNN50, AMo50, CV) + frequency-domain (Total Power, VLF,
  LF, HF — needs 300+ R-R). Healthy RMSSD band cited 20–89 ms. Premium exposes **21 metrics**.
- **Consumer scores (liquid-fill gauges):** **Health** (resilience, HRV-only), **Stress**
  (sympathetic dominance), **Energy** (capacity to handle load), **Focus** (from Stress+Energy).
  Premium adds **HRV Score %** (from lnRMSSD, ~100% ideal), **ANS / Nervous System Balance**
  (sympathetic vs parasympathetic %), **Coherence**.
- **Personalized against an individual baseline + age/gender population norms.** No published
  raw→score formula. No screen literally labeled "readiness" — Energy/Health play that role.

## Data collected / integrated (the "connect all your data" pitch)
- Aggregators: Apple Health, Health Connect, Samsung Health.
- Direct: Fitbit, Garmin, Oura, Withings, Strava, RescueTime, Slack, Swarm, Netatmo, AccuWeather.
- Devices: Apple/Samsung/Pixel Watch, Muse headband, Sleep Number bed, smart scales, AirPods, BLE HR.
- Data types: HRV, HR, steps, sleep, workouts, nutrition, weight/body-fat, blood pressure, SpO₂,
  breathing, menstrual cycle, temperature, air quality, weather, location, productivity, and manual
  **tags** (caffeine/alcohol/workout/mood events).

## The correlations engine (their differentiator, Premium)
- Compares any two connected data flows via **Pearson + Spearman** coefficients — surfaces links at
  **≥51%** strength that hold in **>20% of cases**. More sources connected → more correlations.
- Outputs plain-language insights ("you need less sleep when your HRV is higher") + a downloadable
  **personalized research-paper PDF**. It is **correlational/observational, not causal or
  prescriptive** — a self-experimentation flywheel.

## Guidance — deliberately non-prescriptive
Serves educational content + flags out-of-range metrics, but **never tells you to train, rest, or
relax.** "Try various options and take measurements to track their effects." Explicit not-medical
disclaimer. This is the whole opening for Baseline: Welltory ends at "here's your state + what
correlates," never "so what do I do today?"

## Monetization
**$99/yr** (~$8.25/mo, 3-day trial) or **$599 lifetime**. Free tier = basic scores + manual logging;
Premium = 21 metrics, correlations, research papers, BP reports, breathing, geotracking.

## Relevance to Baseline
- **Steal:** camera PPG as a validated no-hardware on-ramp (de-risks our camera-secondary bet);
  live quality feedback + accuracy score; plain-language scores over raw HRV; personal baseline +
  age/gender norms + cold-start humility; tags-as-context + the correlations paper as a retention
  hook.
- **Their ceiling = our wedge:** no prescription, no sport specificity, correlational not
  actionable. Don't try to out-*measure* Welltory (they win on 21 metrics + integration breadth) —
  out-*decide* them: fewer numbers, one clear prescribed dose.
- **Pricing anchor:** $99/yr proves consumers pay recurring for a daily HRV habit *without*
  prescription; Baseline layers the higher-value coaching on top.

Sources: [measurement process](https://help.welltory.com/en/articles/3395902-how-the-measurement-process-works) ·
[accuracy rules](https://welltory.com/rules-accurate-hrv-measurements/) ·
[Heartbeat Report metrics](https://help.welltory.com/en/articles/4380824-heartbeat-report-how-we-interpret-your-heart-rate-variability-metrics) ·
[correlation calc](https://help.welltory.com/en/articles/3377520-how-do-you-calculate-my-correlations) ·
[data sources](https://help.welltory.com/en/articles/11130907-data-sources-and-how-to-connect-them) ·
[plans](https://welltory.com/plans/) · [revenue/scale](https://thevertical.la/sales/bootstrappers-welltory-reached-14-mln-in-revenue/)
