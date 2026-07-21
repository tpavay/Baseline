# Baseline — Design System & Decisions

**Figma (source of truth):** https://www.figma.com/design/CCVlatyKW7MSHRGE3PK50i

## Direction
Dark, **"calm precision"** — a trustworthy instrument that bridges the calm morning read and serious training. Chosen over "athletic-aggressive" (too loud) and "premium-minimal" (too soft) after a 5-palette exploration.

## Tokens
| Role | Hex |
|---|---|
| Base (near-black) | `#0C0A10` |
| Surface | `#1C1822` |
| Amethyst (feature surface) | `#33203E` |
| **Accent (violet)** | `#9B6DFF` |
| Text hi / mid / faint | `#F3F0F8` / `#9B94A8` / `#6A6478` |
| Line | `#272231` |

**Recovery zones (semantic — never reused as brand accent):** Blue `#4C8DFF` · Green `#34D27B` · Amber `#F5A623` · Red `#FF5247`.

**Why violet:** zone-safe (not in the blue/green/amber/red families, so a control never reads as a recovery state) and premium on near-black. Electric blue was rejected — it collides with the blue recovery zone.

**Type:** See [`design-system/README.md`](design-system/README.md#typography) for the production type system (SF Pro for prose, SF Mono for instrumentation; no custom fonts bundled).

## Screen inventory (in Figma)
- **Daily Home** — readiness gauge in the zone color, supporting stats, today's session card (amethyst), violet CTA, bottom nav. 4 states: Pre-reading · High/green · Moderate/amber · Low/red (chassis).
- **Morning Reading flow** — live preview → 6 breathing-orb states (one 5s/5s cycle) → averages (HRV + HR) → quick check → recommended.
- **Day recommendations** — the "Your Day" card across input combinations, demonstrating the engine logic and the subjective overrides.

## Reading screen — locked details
- Fixed **2:30**, **5s in / 5s out** resonance (≈6 bpm), no holds. Dark. No "signal quality" copy.
- Breathe **cue + orb top-middle** (phase shown by the text + orb flipping at each extreme — no seconds shown).
- **One graph** below: smooth **R-R curve** (not an ECG/PQRS trace) building left-to-right; **bpm Y-axis on the left** (70/55/40 + gridlines); **time-in-seconds X-axis** (5s dashes, 10s labels); glowing leading point.
- **HR & HRV** as big numbers above the graph, small labels bottom-aligned; values move with the breath (RSA).
- Optional: a single subtle haptic at each phase turn (eyes-closed); the orb may shift hue slightly on exhale.

## Competitive teardown — conclusions
- **Elite HRV** — best reading ritual + deep data + context tags; stops at the number. *Steal the ritual; add the prescription.*
- **Morpheus** — recovery → training zones (the bridge), but hardware-locked, weekly (not daily session), sport-agnostic, no chassis.
- **Warrior Lab** — strong HYROX content + domain taxonomy, but it's a self-service diagnostic + **static PDF** plan; the diagnostic and the plan never talk, no daily recovery loop.
- **The Bayens Method (via FITR + Morpheus)** — the elite human-coaching gold standard Baseline automates: recovery-aware, zone-targeted, weakness-tracked, deeply explained. Source of the engine logic (bands, MED/HPL/MDV, never-two-hard-days, batch intensity, automate-the-week).

**The wedge:** assemble what no one combines — Morpheus's recovery→prescription engine + Elite HRV's reading ritual + HYROX-native content — minus the hardware, made *daily*, plus the **chassis pillar** and the **why-layer**, at app price/scale.
