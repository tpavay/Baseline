# Competitive landscape — recovery / readiness apps

Research date: 2026-07-08. Teardowns of the popular, high-revenue apps adjacent to Baseline. Each
file has the concrete detail + sources; this index is the cross-cutting synthesis.

- [morpheus.md](morpheus.md) — closest competitor: recovery-driven HR zones + weekly zone-minute budget.
- [welltory.md](welltory.md) — camera-PPG HRV + correlations engine (our reading twin; no prescription).
- [wearables-whoop-oura.md](wearables-whoop-oura.md) — WHOOP & Oura, the passive-readiness archetypes.
- [athlete-hrv-apps.md](athlete-hrv-apps.md) — HRV4Training, Athlytic, Training Today, Elite HRV, Gentler Streak.

## The one finding that matters
Across **all eight apps**, the guidance ladder tops out at an *intensity signal or a target number* —
a recovery %, a strain/activity target, a traffic light, or a manual menu. **None turns the reading
into a concrete, sport-specific, dose-layered, loggable session.** HRV4Training and Morpheus get
closest and both stop deliberately (HRV4Training hands the session to a human coach; Morpheus only
widens/narrows HR zones). **Baseline's entire reason to exist is the step none of them take:
reading → readiness → *here is today's actual session* (or the active-recovery pivot).**

## Where they converge (validates Baseline's design)
- **HRV metric:** everyone uses **RMSSD / lnRMSSD** against a **personal rolling baseline**, not
  population norms. Baseline's plan matches.
- **Reading protocol:** consistent morning time + posture + **natural breathing** (Welltory,
  HRV4Training, Morpheus all explicitly say *don't* control the breath). Baseline decided the same.
- **3-band recovery model** is legible and universal (WHOOP green/yellow/red, Oura Optimal/Good/
  Pay-attention, Morpheus green/amber/red).
- **Recovery scales a daily target** (WHOOP strain, Oura activity goal, Morpheus zone boundaries).
- **Cold-start humility** (population/age-gender norms until a personal baseline forms).

## Where they diverge — decisions for Baseline
| Dimension | WHOOP | Oura | Morpheus | HRV4Training | **Baseline (plan)** |
|---|---|---|---|---|---|
| HRV baseline window | ~30-day | 14d vs 3-mo | 10-day | **7d vs ~60d band** | 7-day; calibrate at 4 |
| Recovery bands | 67 / 34 | 85 / 70 | 80 / 40 | normal-range band | ≥80 / 60–79 / <60 |
| HR zones | **HRR/Karvonen** | %-max | hidden dynamic | — | **HRR/Karvonen** |
| Weekly volume | strain target | activity goal | **min/zone budget** | — | dose layers (MED/HPL/MDV) |
| Live in-workout HR | yes (strap) | **no (BYO strap)** | yes (M7) | — | **yes (strap-native)** |
| Session prescription | ✗ | ✗ | ✗ (zones only) | ✗ (word) | **✓ ← the wedge** |

Notable convergence: **WHOOP independently uses HRR/Karvonen zones** — the exact model CLAUDE.md
specifies — while Oura's plain %-max and no-native-live-HR are gaps Baseline's strap-native tracking
closes.

## Pricing anchors (subscription is the market norm)
| App | Price |
|---|---|
| Training Today | ~$10–15 one-time |
| HRV4Training | $9.99 one-time (+ €45/yr Pro) |
| Athlytic | $24.99/yr |
| Oura | $69.99/yr membership + $349–499 ring |
| Welltory | $99/yr (or $599 lifetime) |
| WHOOP | $199–359/yr (hardware bundled) |

Welltory ($99/yr, no prescription) proves consumers pay recurring for a daily HRV habit alone —
Baseline layers higher-value coaching on top.

## The idea Baseline wants to adopt: a weekly zone-minute budget
Morpheus's headline mechanic — **each week, a target range of minutes in each HR zone (Blue/Green/
Red), recomputed from recovery/fitness trends; the daily recovery band steers which bucket today
fills** — is worth adapting because it:
1. **Ships before the exercise library / program-authoring work.** A zone-minute target needs no
   exercise content — just HR-zone time from the strap. It's a recovery-aware training target that
   can launch with the score + live zones, ahead of full session prescription.
2. **Composes with the dose model:** the weekly budget sets the *volume envelope*; the daily
   recovery band picks *which dose* (MED/HPL/MDV) fills today's slice; the HYROX pillars (Engine /
   Chassis / Recovery) decide *what modality*.
3. **Still differentiates:** unlike Morpheus (which only reshapes zones), Baseline can name the
   actual target ("~25 min Green today; you're amber, so hold Blue") and later attach the concrete
   session.

Suggested phased path: **(a)** score + recovery band (done) → **(b)** live strap zone tracking +
weekly zone-minute budget scaled by recovery → **(c)** full session prescription + exercise library.
Stage (b) is a shippable, defensible product on its own and closes more of the reading→action loop
than any competitor, without waiting on the heavy content work.
