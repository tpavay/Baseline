# Baseline — Design System

The canonical, human-readable design reference. **Tokens verified against Figma** (file
`CCVlatyKW7MSHRGE3PK50i`, frame **BASELINE — INSTRUMENT DS**, node `69:2`) on 2026-07-01 and
cross-checked against the Swift source. Companions: `instrument.md` (the Figma-MCP *generation
kit* with JS helpers) · `../design.md` (screen rationale + competitive teardown).

> Note: the DS is baked as **local paint/text styles + `DS/*` components**, not Figma
> *variables* — so `get_variable_defs` returns empty and this doc + the DS frame are the source
> of truth for values.

## Direction
Dark, **"calm precision" — a recovery instrument, not a dashboard.** Chosen over
"athletic-aggressive" (too loud) and "premium-minimal" (too soft).

### Principles
- **Mono numerals for data, Inter for sentences** — numbers read like an instrument.
- **Hairlines and outlines over heavy fills** — cards are outlined, not blobs.
- **Color only where it carries meaning** — recovery zones, the green "go", violet only for the action.
- **Signature motif:** *you, measured against your 7-day baseline* — the Baseline Meter + micro-bars repeat it everywhere.
- **Depth from light** — subtle ambient glow + a glow on the active indicator/CTA. Never heavy.

## Color tokens

Verified swatches. `Swift` = symbol in `Baseline/Shared/DesignSystem/BaselineColor.swift` (all in parity).

| Token | Hex | Swift | Use |
|---|---|---|---|
| **Base** | `#0C0A10` | `BaselineColor.base` | screen background (near-black) |
| **Raised / Surface** | `#1C1822` | `.surface` | raised fills (rare — prefer outlines) |
| **Amethyst** | `#33203E` | `.amethyst` | feature surface / avatars / ambient glow |
| **Accent (violet)** | `#9B6DFF` | `.accent` | **interactive only** — CTA, links. Never a recovery state |
| **Text Primary** | `#F3F0F8` | `.textHi` | values, headlines |
| **Text Secondary** | `#9B94A8` | `.textMid` | supporting copy |
| **Text Faint** | `#6A6478` | `.textFaint` | labels, captions, ticks |
| **Hairline** | `#272231` | `.line` | rules, outlines, ticks |

### Recovery zones (semantic — never reused as the brand accent)
| Token | Hex | Swift | Band |
|---|---|---|---|
| **Green** | `#34D27B` | `.zoneGreen` | recovered / cleared / "go" (≥80) |
| **Blue** | `#4C8DFF` | `.zoneBlue` | low-intensity |
| **Amber** | `#F5A623` | `.zoneAmber` | caution (60–79) |
| **Red** | `#FF5247` | `.zoneRed` | recover / red day (<60) |

**Why violet is the accent:** it's *zone-safe* — outside the blue/green/amber/red hue families, so a
control never reads as a recovery state. (Electric blue was rejected — it collides with the blue zone.)

## Type

**Roboto Mono** for data/numerals, **Inter** for prose. Big display weights for readiness / HR / HRV.

| Style | Font | Size | Tracking |
|---|---|---|---|
| Number/Hero | Roboto Mono Bold | 104 | −3 |
| Number/Medium | Roboto Mono Bold | 52 | −1 |
| Value/Metric | Roboto Mono Bold | 22 | −0.5 |
| Label/Caps | Roboto Mono Medium | 11 | 2 |
| Meta/Mono | Roboto Mono Regular | 11 | 1 |
| Button/Mono | Roboto Mono Bold | 15 | 1 |
| Tag/Mono | Roboto Mono Medium | 10 | 1.5 |
| Body/Default | Inter Medium | 15 | (lh 22) |
| Body/Small | Inter Regular | 13 | — |
| Headline/Coach | Inter Bold | 28 | −0.5 |

## Effects
- **Glow/Accent** — drop shadow `#9B6DFF` α0.45, radius 24, spread −4 (the CTA).
- **Glow/State** — drop shadow `#34D27B` α0.6, radius 10 (active indicator / "go" dot).
- **Ambient/Blur** — layer blur 90 (background mood blob, used sparingly).

## Layout
- Screen **393 × 852**. Side margins **24**.
- Card / button radius **10**. Pill radius **28**.
- Hairlines **1px** `Hairline`. Section dividers = full-width hairlines.

## App icon
See [`app-icon/README.md`](app-icon/README.md) - how large the mark can go, why the white field is structural, and how to review an icon change at real home-screen size.

## Components (`DS/*` in Figma → `Instrument.swift` in code)
- **Recovery Display** — big mono `82 /100` + state tag + "▲ 6% vs your baseline".
- **Baseline Meter** *(signature)* — horizontal 0–100 scale; red/amber/green zone bars; ticks; shaded **7-day baseline band**; glowing **TODAY** needle.
- **Stat Readout** — caps label + mono value + unit + micro baseline-band bar with dot.
- **Dose Scale** — MED / HPL / MDV stepped bar, filled to the cleared level.
- **Prescription Card** — outlined spec sheet: header + session + dose + footer ("WHY →").
- **Button / Primary** — accent fill, mono label, accent glow.
- **Tab Bar** — hairline top, mono caps labels, accent tick on active.
- **Tag** — small state-colored pill, mono caps.
- **Hairline** — 1px rule.

## Screen inventory (Figma node IDs)

**Design system:** `69:2` BASELINE — INSTRUMENT DS · `1:34` Design tokens

| Group | Frames (node id) |
|---|---|
| **Daily Home** | Daily Home `1:2` · Today card `1:16` |
| **Home — recovery states** | Pre-reading `3:9` · High·Recovered `3:34` · Moderate `3:63` · Low·Recover `3:92` |
| **Reading flow** | Preview `10:13` · Breathe 1–6 `15:2 / 15:36 / 15:70 / 15:104 / 15:138 / 15:172` · Result `10:164` · Quick check `10:176` · Recommended `10:207` |
| **Day recommendations** | Prime `17:4` · Sore legs `17:33` · Moderate `17:62` · High stress `17:91` · Low `17:120` · Recovered·sore `17:149` |
| **Later explorations** | Today·Recovery Home `61:2` · Reading·Live `62:2` · Reading·Result `62:69` · Today·Instrument `65:2` · Today·Editorial `67:2` |

## Working with the file
- **Read** a frame: `get_screenshot` / `get_design_context` with `fileKey CCVlatyKW7MSHRGE3PK50i` + the node id above.
- **Generate** new screens: follow `instrument.md`'s JS kit via `use_figma` (build on Page 1 `0:1`; frame children use frame-relative coords — set x/y *after* `appendChild`).
- **Parity:** keep `BaselineColor.swift` and this table in sync — any token change updates Figma styles, this doc, and the Swift enum together.
