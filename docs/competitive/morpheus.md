# Competitive teardown — Morpheus (trainwithmorpheus.com)

Research date: 2026-07-08. Sourced from the Morpheus support KB (support.trainwithmorpheus.com),
their marketing/topic pages, and a third-party gym writeup (bspnova.com). Confidence flags noted
where numbers come from marketing/third-party rather than the official KB.

Morpheus is the closest competitor to Baseline's recovery-driven model. This teardown captures how
they determine HR zones, set weekly training volume per zone, and let the daily recovery score
drive it — plus what they collect and where Baseline can differentiate.

---

## 1. Heart-rate zones

**Three dynamic color zones** (the *training* zones — distinct from the recovery-score colors):

| Zone | Name | Intent |
|------|------|--------|
| **Blue** | Recovery | Low-intensity, parasympathetic engagement. Zone 1 = lower Blue (restoration); Zone 2 = **upper third of Blue** (aerobic base). |
| **Green** | Conditioning | Moderate-intensity stimulus. |
| **Red** | Overload | High-intensity stress for adaptation. |

- **No published formula.** Morpheus explicitly rejects fixed-percentage boundaries: zones are
  *"not fixed percentages."* No %-max-HR, no %HRR/Karvonen, no bpm edges anywhere in the docs.
  Rationale: *"the same heart rate can represent very different stress loads depending on your
  recovery state."*
- **Only quasi-numeric anchor:** Zone 1 *"should still elevate heart rate meaningfully — often at
  least above ~100 bpm."*
- **Max HR:** manual entry preferred; else estimated from **age, sex, fitness level** (examples
  cited: `220 − age` and `208 − 0.7 × age` / Tanaka). Optional field tests: a **20-min test** or a
  **4×2 test**. They stress age formulas can be off ±10–20 bpm — their justification for dynamic
  zones over max-HR precision.
- **Resting HR is NOT used in zone math** — only as a recovery-score input and fitness-trend marker.
- Philosophy worth stealing: *"Heart rate is not the input. Workload and environment are the
  inputs. Heart rate is the response."* They anchor Zone 2 to a known pace/watts and use HR +
  cardiac drift to confirm the workload still fits.

## 2. Weekly zone-budget model (the headline mechanic)

**Every Monday, Morpheus sets a weekly TIME target (a minute range) per zone** — Blue/Green/Red —
and you fill those buckets across the week. It is a **time-in-zone budget, not a points system.**

- **Target derivation:** recent training load + recovery/HRV trends + personal fitness level +
  stated goals. *"the amount of time in each zone that research and Morpheus's database show is most
  likely to improve your fitness."* Hit any part of each range (top/middle/bottom).
- **Adaptive:** metrics trending the wrong way → next week's targets drop; fitness improving →
  targets rise. Self-calibrating from passive recovery data — **no benchmark/fitness test.**
- **Concrete anchors** (from the KB):
  - Monthly zone distribution ≈ **Blue 75–85% / Green 15–25% / Red ≤8–10%.**
  - **80/20 polarized** (weekly totals, not per session). They warn against living in Green ("junk
    fatigue" — HRV drifts down, RHR creeps up).
  - Minimum effective dose ≈ 2–3×/wk × 20–40 min (~40–120 min/wk); optimal ≈ 3–5×/wk × 30–60 min
    (~90–300 min/wk).
  - 12-week phased ramp; **no fixed deload week** — extend the current phase if recovery trends down.
- The concrete per-user minute numbers live in the app UI, not the KB.

## 3. Recovery score → training

**The daily recovery score reshapes the zone boundaries** (it does NOT pick a session):
- **Low recovery:** Blue *broadens*, Green/Red *lower* → less HR needed to "overload," steering you
  into Blue.
- **High recovery:** Green/Red *expand* → headroom to bank hard minutes.

**Recovery-score "cost" per workout** (a stress budget in recovery %):
- Red day (RPE 8–10): **−12 to −18%** (sometimes more)
- Green day (RPE 7–8): **−8 to −12%**
- Blue day: **+3 to +5%** (raises recovery)

**Weekly plan templates & rules:**
- *1/2/3* (beginner: 1 Red / 2 Green / 3 Blue days), *2/2/2* (advanced, ~2× the stress).
- **Never >2 Red days in a row** (needs ≥2 recovery days).
- Self-governing gate: keep rolling **average recovery >80%**; aim to wake Monday **>85%**. If the
  average dips, you've earned too many Red days — cut back.

## 4. The recovery score itself

- **Reading:** 2:30 morning HRV test, **10–30 min after waking**, lying/seated, **natural breathing**
  (no pacing), **RMSSD**, via the M7 chest strap. Electrodes must be moistened.
- **Score: 1–100%.** Bands: **>80 green / 40–80 amber / <40 red** ⚠️ *(from marketing + third-party,
  not the KB — the KB keeps the score deliberately non-prescriptive)*.
- **Computation:** HRV vs a **rolling 10-day personal baseline** sets the *range* of possible score;
  then **resting HR + subjective sleep-quality + prior-day training load** position the final score
  within that range. Personal baseline, not population. Blended; **no published weights.**

## 5. Data collected

HRV (RMSSD), resting HR, a **daily subjective questionnaire** (sleep hours, sleep-quality rating,
muscle soreness, overall well-being, notes), prior-day training load, and **sleep + steps from Apple
Health / Garmin / Fitbit / Health Connect** (reads the synced database, not the device).

---

## Implications for Baseline

Much of CLAUDE.md is **validated** by Morpheus: recovery-driven zones, no-two-hard-days, 80/20,
subjective inputs blended with HRV against a personal baseline, natural-breathing RMSSD reading.

Deltas to decide on:

| Dimension | Morpheus | Baseline (current plan) |
|---|---|---|
| HRV baseline window | **10-day** rolling | 7-day; calibration usable at 4 readings |
| Recovery bands | >80 / 40–80 / <40 (huge amber middle) | ≥80 / 60–79 / <60 |
| Zones | Hidden, qualitative daily shift | Explicit HRR/Karvonen (transparency edge) |
| Weekly plan | **Minute budget per zone**, recomputed Monday | MED/HPL/MDV dose layers |
| Recovery→training bridge | Reshapes zone boundaries only | **Picks the actual session** ← whitespace |
| Calibration | Self-calibrating from passive data (no test) | open question |

**Biggest differentiator confirmed:** Morpheus never tells you *which* session to do — it only
widens/narrows zones for whatever you'd do anyway. Baseline's explicit "recovery band → dose →
here's today's session" bridge is more prescriptive than anything Morpheus documents.

**Idea to adopt:** the **weekly minute-per-zone budget** (Blue/Green/Red) is a strong, concrete
scaffold. It could sit alongside (or feed) the MED/HPL/MDV dose model — e.g. the weekly budget sets
the *volume envelope*, the daily recovery band picks *which dose* fills today's slice, and the
HYROX pillars (Engine/Chassis/Recovery) decide *what modality*. It also degrades gracefully before
the authored-program/exercise-library work is done: a zone-minute target needs no exercise content,
just HR-zone time — so it's shippable earlier than full session prescription.

## Key source URLs

- [Why Morpheus Uses 3 Dynamic HR Zones Adjusted Daily by Recovery Score](https://support.trainwithmorpheus.com/support/solutions/articles/4000226200-why-morpheus-uses-3-dynamic-hr-zones-adjusted-daily-by-recovery-score)
- [How Much Volume and Intensity You Actually Need — Weekly Zone Targets](https://support.trainwithmorpheus.com/support/solutions/articles/4000226201)
- [Building a Weekly Training Plan](https://support.trainwithmorpheus.com/support/solutions/articles/4000180422) (1/2/3 & 2/2/2, no-2-red-in-a-row, recovery-cost model)
- [The 80/20 Approach to Training](https://support.trainwithmorpheus.com/support/solutions/articles/4000226063)
- [What Zone 2 Actually Means](https://support.trainwithmorpheus.com/support/solutions/articles/4000226156-what-zone-2-actually-means-it-s-not-just-a-heart-rate-number-)
- [Zone 2 Isn't One Thing — It Changes With Your Recovery](https://support.trainwithmorpheus.com/support/solutions/articles/4000226231-zone-2-isn-t-one-thing-it-changes-with-your-recovery)
- [Maximum Heart Rate: Estimating It vs Measuring It](https://support.trainwithmorpheus.com/support/solutions/articles/4000148448-maximum-heart-rate-estimating-it-vs-measuring-it)
- [Checking Your Recovery](https://support.trainwithmorpheus.com/support/solutions/articles/4000148284-checking-your-recovery)
- [The Morpheus Recovery Test (update)](https://trainwithmorpheus.com/topic/the-morpheus-recovery-test-update/) — most concrete score-computation source
- [Recovery Is Multiplicative, Not Additive](https://support.trainwithmorpheus.com/support/solutions/articles/4000226274)
