# Baseline Visual Foundations

## Direction

- Calm, precise, conversational, and low-friction.
- Dark and focused without feeling clinical, aggressive, or ornamental.
- Actions and editable training objects lead.
- Metrics support decisions instead of becoming the product.
- Use outlines and hairlines more often than heavy filled containers.
- Use depth and glow sparingly to establish focus.

## Current Core Colors

| Role | Token | Value | Current use |
|---|---|---:|---|
| Background | `BaselineColor.base` | `#0C0A10` | Primary screen background |
| Surface | `BaselineColor.surface` | `#1C1822` | Raised surfaces used selectively |
| Amethyst | `BaselineColor.amethyst` | `#33203E` | Feature surface and ambient depth |
| Accent | `BaselineColor.accent` | `#9B6DFF` | Primary interaction and brand emphasis |
| Text high | `BaselineColor.textHi` | `#F3F0F8` | Primary text and values |
| Text middle | `BaselineColor.textMid` | `#9B94A8` | Supporting text |
| Text faint | `BaselineColor.textFaint` | `#6A6478` | Labels and tertiary information |
| Hairline | `BaselineColor.line` | `#272231` | Rules, outlines, and separators |

Existing blue, green, amber, and red tokens may remain available as semantic status colors.
Do not automatically map them to fixed readiness bands or use them as the default product navigation language.
Keep the violet accent distinct from status colors so controls do not read as warnings or outcomes.

## Typography

- Use a clear prose face for explanation and conversational content.
- Use monospaced numerals or labels selectively when they improve measurement readability or the instrument character.
- Avoid oversized metric numerals unless the metric is genuinely the user's primary task on that screen.
- Keep type responsive to Dynamic Type and do not reproduce fixed Figma sizes blindly in SwiftUI.

Current source disagreement is unresolved:

- Figma and `docs/design-system/` specify Inter for prose and Roboto Mono for data.
- `Baseline/Shared/DesignSystem/Instrument.swift` currently uses system prose and system monospaced fonts.

Inspect the target and preserve implementation consistency unless the task explicitly resolves the font strategy.
Do not claim Figma and Swift typography are in parity while this disagreement remains.

## Current Geometry And Effects

- Reference canvas: 393 by 852 points.
- Common side margin: 24 points.
- Common card and button radius: 10 points.
- Common pill radius: 28 points.
- Hairline: 1 point.
- Accent glow: violet with restrained opacity and blur.
- Ambient blur: use sparingly as background mood, not as a substitute for hierarchy.

Treat these as current tokens, not permission to hard-code them throughout feature views.
Use or extend shared primitives.

## Information Hierarchy

Prefer this order when the screen is helping the user decide or train:

1. The next action, planned session, or editable object.
2. The most important constraint or change.
3. A concise explanation of why.
4. Meaningful uncertainty or missing optional evidence.
5. Supporting metrics and history on demand.

Avoid making a readiness score, HRV number, recovery band, or sensor connection the hero unless the user explicitly opened a measurement or history surface.

## Source Locations

- Figma: `https://www.figma.com/design/CCVlatyKW7MSHRGE3PK50i`
- Human-readable tokens and legacy component inventory: `docs/design-system/README.md`
- Figma generation notes: `docs/design-system/instrument.md`
- Swift tokens and components: `Baseline/Shared/DesignSystem/`
- Product and architecture authority: `AGENTS.md`

## Known Legacy Visuals

The following existing elements may be useful implementation references but are not default patterns for new product work:

- Readiness gauges as the home-screen hero.
- Fixed green, amber, and red recovery bands.
- The baseline meter as the universal signature element.
- MED, HPL, and MDV dose scales.
- Recovery-instrument framing that makes HRV the product identity.

When working on an existing legacy screen, preserve behavior unless the task includes redesigning it.
When creating new work, follow the AI-first decision hierarchy instead.
