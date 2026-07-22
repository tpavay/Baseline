# Baseline instrument compatibility layer

`Instrument.swift` contains established primitives that remain in use across reading, sleep, onboarding, and recovery surfaces.
The current semantic tokens and new shared components are documented in `README.md`.

## Direction

Instrumentation uses monospaced numerals, restrained color, and hairlines over heavy fills.
Prose uses the native system sans-serif face.
The violet accent remains visually distinct from semantic status colors.
New training surfaces should lead with the user's action or editable training object instead of a readiness score.

## Compatibility APIs

### `Font.bMono`

`Font.bMono` preserves existing explicit-size monospaced call sites.
It is not the preferred API for new shared UI because explicit font sizes do not provide the same semantic Dynamic Type behavior.
Use `BaselineTypography` for new work.

### `InstrumentLabel`

`InstrumentLabel` renders a compact uppercase monospaced label.
It now uses the semantic `instrumentLabel` font while preserving caller-supplied tracking and color.

### `Hairline`

`Hairline` renders `BaselineSize.hairline` with `BaselineColor.line` by default.
Use it for separators and outlines that require a standalone view.

### `InstrumentStat`

`InstrumentStat` remains available for legacy large readouts.
New components should prefer the semantic metric styles when they do not need an existing explicit-size contract.

### Instrument button styles

`InstrumentButtonStyle` and `InstrumentOutlineButtonStyle` use the semantic button style and grow vertically with content.
Both preserve a minimum 44-point target.
Their pressed feedback is an opacity transition, which remains suitable when Reduce Motion is enabled.

### `BaselineMeter`

`BaselineMeter` is a legacy readiness visualization.
It may remain on existing measurement surfaces but is not the default hierarchy for new Today, workout, plan, or profile UI.

## Figma relationship

The Figma file is `CCVlatyKW7MSHRGE3PK50i`.
The older instrument frame is `BASELINE - INSTRUMENT DS`, node `69:2`.
That frame still contains local paint and text styles rather than Figma variables.
Its historical type styles use Inter and Roboto Mono, while the approved prototype uses Inter with Apple system fallback plus SF Mono.
Production currently resolves the mismatch to native SF Pro and SF Mono as documented in `README.md`.

## Maintenance rule

When a shared visual token changes, update the Swift source, the current approved Figma source, and `README.md` in the same change.
Keep this file focused on legacy compatibility rather than duplicating the full token inventory.
