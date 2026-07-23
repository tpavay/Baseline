# Baseline design system

This is the canonical human-readable reference for Baseline's production visual foundation.
The Swift implementation lives in `Baseline/Shared/DesignSystem/`.

## Source priority

Use these sources in order:

1. Current product principles and explicit approved direction in `AGENTS.md`.
2. The approved taxonomy prototype and current approved Figma frames.
3. This document and the shared Swift primitives.
4. Legacy screens and one-off styles.

The approved taxonomy prototype has SHA-256 `ccb6751053e0e27156d8649ebadc1d6e56ea38597467628a2260c631508e5a10`.
The Figma file is `CCVlatyKW7MSHRGE3PK50i`.
The design-system frame is `BASELINE - INSTRUMENT DS`, node `69:2`.

## Direction

Baseline is calm, precise, conversational, and low-friction.
Actions and editable training objects lead the hierarchy.
Metrics and evidence support decisions instead of becoming the product.
Prefer restrained hairlines and purposeful depth over dense filled panels.
Reserve violet primarily for interaction and brand emphasis.
Use status colors only when they communicate an actual semantic state.

## Colors

`BaselineColor.swift` is the compiled source of truth for production colors.

| Role | Swift token | Hex | Use |
|---|---|---:|---|
| Base | `BaselineColor.base` | `#0C0A10` | Primary screen background |
| Surface | `BaselineColor.surface` | `#1C1822` | Selective raised fill |
| Amethyst | `BaselineColor.amethyst` | `#33203E` | Feature depth and plan-card gradient |
| Accent | `BaselineColor.accent` | `#9B6DFF` | Interaction and brand emphasis |
| Text high | `BaselineColor.textHi` | `#F3F0F8` | Primary text and values |
| Text middle | `BaselineColor.textMid` | `#9B94A8` | Supporting text |
| Text faint | `BaselineColor.textFaint` | `#6A6478` | Labels and tertiary text |
| Hairline | `BaselineColor.line` | `#272231` | Rules, outlines, tracks, and separators |
| Zone blue | `BaselineColor.zoneBlue` | `#4C8DFF` | Zone 1 and approved blue emphasis |
| Zone green | `BaselineColor.zoneGreen` | `#34D27B` | Zone 2 and positive semantic state |
| Zone amber | `BaselineColor.zoneAmber` | `#F5A623` | Zone 4 and caution semantic state |
| Zone red | `BaselineColor.zoneRed` | `#FF5247` | Zone 5 and high-risk semantic state |

The approved five-zone donut uses blue, green, violet, amber, and red in order.
`zoneOrange` remains available only for existing live heart-rate zone-gauge compatibility and is not part of the approved taxonomy-surface palette.
Do not introduce screen-local color values when one of these semantic tokens applies.

## Typography

The approved prototype specifies Inter for prose with the Apple system sans-serif as its fallback, and SF Mono for instrumentation.
The older Figma text styles and previous documentation specify Inter plus Roboto Mono.
The app currently bundles no custom fonts and has historically rendered SF Pro plus SF Mono.

The production foundation resolves that conflict by using the prototype's native Apple fallback: SF Pro for prose and SF Mono for instrumentation.
No font resources are registered in `project.yml`.
If Baseline later chooses to bundle Inter, add the licensed font resources, register them through `project.yml`, and update both this document and `BaselineTypography.swift` in the same change.

`BaselineTypography` uses semantic system text styles so every style scales with Dynamic Type.

| Semantic style | Face | Swift text style | Intended use |
|---|---|---|---|
| `screenTitle` | SF Pro Bold | `title2` | Screen-level headings |
| `navigationTitle` | SF Pro Semibold | `headline` | Navigation and card titles |
| `prose` | SF Pro Regular | `body` | Explanation and conversational copy |
| `proseSmall` | SF Pro Regular | `subheadline` | Supporting prose |
| `exerciseName` | SF Pro Semibold | `title3` | Prominent editable exercise names |
| `rowTitle` | SF Pro Regular | `body` | Picker row titles |
| `rowValue` | SF Pro Regular | `subheadline` | Classification values and compact supporting values |
| `rowSubtitle` | SF Pro Regular | `caption` | Picker subtitles and disabled reasons |
| `instrumentMetric` | SF Mono Bold | `title2` | Primary metric values |
| `instrumentValue` | SF Mono Bold | `title3` | Compact center values and readouts |
| `instrumentLabel` | SF Mono Semibold | `caption` | Uppercase section and instrument labels |
| `instrumentMeta` | SF Mono Medium | `caption` | Supporting measurement metadata |
| `button` | SF Mono Bold | `subheadline` | Compact action labels |
| `primaryAction` | SF Pro Bold | `subheadline` | Full-width primary actions |

Use `.baselineTypography(...)` for new shared and feature UI.
`Font.bMono` remains a compatibility API for existing call sites that still require explicit sizes.

## Geometry

| Role | Token | Value |
|---|---|---:|
| Hairline | `BaselineSize.hairline` | 1 pt |
| Minimum tap target | `BaselineSize.minimumTapTarget` | 44 pt |
| Picker icon | `BaselineSize.icon` | 32 pt |
| Picker icon glyph | `BaselineSize.iconGlyph` | 15 pt |
| Picker selection glyph | `BaselineSize.selectionGlyph` | 17 pt |
| Primary action height | `BaselineSize.primaryActionHeight` | 50 pt |
| Picker row minimum height | `BaselineSize.pickerRowMinimumHeight` | 62 pt |
| Exercise asset placeholder | `BaselineSize.exerciseAsset` | 92 pt |
| Icon radius | `BaselineRadius.icon` | 9 pt |
| Control radius | `BaselineRadius.control` | 10 pt |
| Search radius | `BaselineRadius.search` | 11 pt |
| Action radius | `BaselineRadius.action` | 12 pt |
| Card radius | `BaselineRadius.card` | 14 pt |
| Pill radius | `BaselineRadius.pill` | 28 pt |
| Compact radius | `BaselineRadius.small` | 8 pt |
| Row radius | `BaselineRadius.row` | 12 pt |
| Floating tab bar radius | `BaselineRadius.tabBar` | 30 pt |
| Form row vertical padding | `BaselineSpacing.formRowVertical` | 14 pt |
| Sleep ring | `BaselineSize.sleepRing` | 92 pt |
| Sleep ring line width | `BaselineSize.sleepRingLineWidth` | 11 pt |
| Sleep ring segment gap | `BaselineSize.sleepRingGapDegrees` | 28 degrees |
| Heart-rate-zone ring | `BaselineSize.zoneRing` | 118 pt |
| Heart-rate-zone ring line width | `BaselineSize.zoneRingLineWidth` | 11 pt |
| Heart-rate-zone segment gap | `BaselineSize.zoneRingGapDegrees` | 1.2 degrees |
| Weekly body figure max width | `BaselineSize.weeklyFigure` | 132 pt |
| Weekly heat legend | `BaselineSize.heatLegendWidth` by `BaselineSize.heatLegendHeight` | 34 by 7 pt |
| Movement label width | `BaselineSize.movementLabelWidth` | 74 pt |
| Movement value width | `BaselineSize.movementValueWidth` | 56 pt |
| Movement bar height | `BaselineSize.movementBarHeight` | 8 pt |
| Zone legend marker | `BaselineSize.zoneMarkerWidth` by `BaselineSize.zoneMarkerHeight` | 3 by 15 pt |
| Zone legend label width | `BaselineSize.zoneLabelWidth` | 17 pt |
| Zone legend time width | `BaselineSize.zoneTimeWidth` | 32 pt |
| Two-up reading card height | `BaselineSize.readingCardFullHeight` | 154 pt |
| Solo reading card height | `BaselineSize.readingCardSoloHeight` | 118 pt |
| Floating tab bar height | `BaselineSize.floatingTabBarHeight` | 60 pt |
| Floating tab bar bottom inset | `BaselineSize.floatingTabBarBottom` | 15 pt |
| Floating tab bar horizontal inset | `BaselineSize.floatingTabBarHorizontal` | 40 pt |
| Floating tab selection height | `BaselineSize.floatingTabSelectionHeight` | 46 pt |
| Floating tab page clearance | `BaselineSize.floatingTabClearance` | bar height + bottom inset (75 pt) |
| Compact internal gap | `BaselineSpacing.compact` | 6 pt |
| Tile gap | `BaselineSpacing.tile` | 9 pt |
| Section stack gap | `BaselineSpacing.section` | 14 pt |
| Card content padding | `BaselineSpacing.cardContent` | 15 pt |
| Row padding | `BaselineSpacing.row` | 13 pt |
| Extra-large gap | `BaselineSpacing.xLarge` | 20 pt |
| Scroll-end breathing room | `BaselineSpacing.scrollBottom` | 20 pt |
| Screen margin | `BaselineSpacing.screen` | 24 pt |
| Screen bottom clearance | `BaselineSpacing.screenBottom` | 90 pt |
| Profile avatar | `BaselineSize.avatar` | 58 pt |
| Plan calendar row minimum height | `BaselineSize.tabBarHeight` | 60 pt |
| Compact muscle map | `BaselineSize.miniMuscleMapHeight` | 30 pt |
| Full muscle map | `BaselineSize.muscleMapHeight` | 180 pt |
| Heart-rate chart | `BaselineSize.chartHeight` | 108 pt |
| Workout action sheet | `BaselineSize.actionSheetHeight` | 274 pt |

The reference canvas is 393 by 852 points.
Shared views must remain flexible across device sizes and must not read `UIScreen.main.bounds`.

## Shared components

### `BaselineCard`

`BaselineCard` owns content padding, surface fill, the one-point hairline, and the approved 14-point radius.
Use `.standard` for normal supporting cards.
Use `.plan` for the named amethyst-to-surface gradient and violet-tinted plan border.
Do not recreate this chrome in feature screens.

### `SegmentedRingLayout`, `SegmentedRing`, and `RadialFillSegmentedRing`

`SegmentedRingLayout` is pure geometry.
It accepts positive segment weights, independently clamped progress values, a gap in degrees, and a start angle.
It drops non-positive weights, defaults missing progress to zero, and prevents gaps from producing negative arcs.

`SegmentedRing` renders that geometry as arc-length progress with caller-provided colors, diameter, stroke width, track color, center content, and one accessibility summary.
`RadialFillSegmentedRing` renders the same geometry with radial-fill progress: every fill arc keeps its segment's full sweep and thickens outward from the track's inner edge as progress grows, over a dim same-hue track.
Neither component has internal animation, so Reduce Motion requires no alternate path.
Their diameter and stroke scale with Dynamic Type.

The sleep score ring and heart-rate donut must use these shared renderers.

| Caller | Renderer | Diameter | Stroke | Gap | Weights | Progress |
|---|---|---:|---:|---:|---|---|
| Sleep score ring | `RadialFillSegmentedRing` | 92 pt | 11 pt | 28 degrees | Score component maxima 50/30/20 | Radial fill per component |
| Zone donut | `SegmentedRing` | 118 pt | 11 pt | 1.2 degrees | Five proportional zone totals | Fully completed |

The approved zone order is blue, green, violet, amber, and red.
Domain calculations remain outside the component.

### `BaselineFloatingTabBar`

`BaselineFloatingTabBar` (in `MainTabView.swift`) is the shell's floating capsule tab bar: three tabs (Weekly, Plan, Profile), icon plus caption label, and an accent-tinted capsule behind the active tab with the `isSelected` accessibility trait.
Its geometry comes from the floating-tab tokens in the table above.
A `safeAreaInset` applied outside a `NavigationStack` never crosses its UIKit hosting boundary, so every screen hosted in the shell reserves bottom space itself with `.floatingTabBarClearance()` inside its own stack, or with `BaselineSpacing.screenBottom` content padding when its content should scroll behind the bar.

### `MuscleMapView`

`MuscleMapView` summarizes the primary and secondary muscles from one or more structured workouts.
Use its compact mode for workout rows and its full mode for workout detail rather than recreating muscle emphasis in feature code.
Its native paths come from the MIT-licensed `react-native-body-highlighter` geometry stored in `.lavish/muscle-assets/` and bundled through `project.yml`.

### `TaxonomyPickerRow`

`TaxonomyPickerRow` supports an image, title, optional subtitle, selected checkmark, and a visible disabled reason.
Decorative icon glyphs stay within their fixed icon containers instead of scaling like text.
The whole row is one button with at least a 44-point target.
VoiceOver receives one concise element with title, subtitle, selection state, and disabled state.
Selection never relies on color alone.

### `TaxonomyPickerShell`

`TaxonomyPickerShell` owns navigation title, Back, optional Done, optional search, lazy rows, and empty search results.
Single selection replaces the previous ID.
Multiple selection toggles an unbounded set.
Disabled rows cannot mutate selection.
Callers may override the default search placeholder and receive an optional post-selection callback after each enabled row tap, which single-select feature pickers use to dismiss on selection.
Feature screens provide data, labels, icons, and disabled reasons without rebuilding interaction behavior.

## App icon
See [`app-icon/README.md`](app-icon/README.md) - how large the mark can go, why the white field is structural, and how to review an icon change at real home-screen size.

## Components (`DS/*` in Figma → `Instrument.swift` in code)
- **Recovery Display** — big mono `82 /100` + state tag + "▲ 6% vs your baseline".
- **Baseline Meter** *(signature)* — horizontal 0–100 scale; red/amber/green zone bars; ticks; shaded **7-day baseline band**; glowing **TODAY** needle.
- **Stat Readout** — caps label + mono value + unit + micro baseline-band bar with dot.
- **Dose Scale** — MED / HPL / MDV stepped bar, filled to the cleared level.
- **Prescription Card** — outlined spec sheet: header + session + dose + footer ("WHY →").
- **Button / Primary** — accent fill, mono label, accent glow.
- **Tab Bar** - legacy hairline-top treatment; production ships `BaselineFloatingTabBar` (see Shared components).
- **Tag** — small state-colored pill, mono caps.
- **Hairline** — 1px rule.

## Accessibility and visual verification

Use semantic type styles and flexible vertical sizing.
Every interactive element must retain at least a 44 by 44 point target.
Cards and rings need meaningful accessibility summaries at their feature call sites.
Disabled picker rows must expose the reason visually and to VoiceOver.
Disabled styling increases contrast when the system Increase Contrast setting is enabled.
Do not convey selection or state by color alone.
Shared components do not add motion that requires a Reduce Motion branch.

Render tests live under `BaselineTests/DesignSystem*`.
They host SwiftUI in a scene-attached `UIWindow`, render with `drawHierarchy`, exercise large Dynamic Type, inspect accessibility output, and emit PNG evidence to the temporary test directory.

## Legacy instrument primitives

`Instrument.swift` still contains compatibility views used by existing reading and recovery surfaces.
`instrument.md` documents those compatibility primitives and how they relate to the current shared foundation.
Do not copy legacy readiness-first hierarchy into new training surfaces.
