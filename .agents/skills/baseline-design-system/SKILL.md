---
name: baseline-design-system
description: Design, prototype, implement, or review Baseline user experiences using the current product principles, Figma source, design tokens, SwiftUI components, interaction patterns, copy standards, accessibility, and visual QA. Use for any Baseline screen, flow, component, navigation, visual styling, UX behavior, onboarding, empty state, microcopy, prototype, Figma work, or material UI change. Load this skill even when the user asks only to make a Baseline interface look better. Do not use for purely non-visual backend or domain work.
---

# Baseline Design System

Create a calm, precise, conversational, low-friction training experience.
Use the visual system consistently while allowing the newer AI-first product model to override legacy readiness-first screens.

## Gather The Current Sources

1. Read `AGENTS.md`, especially Product Experience and the decision-first product model.
2. Read [references/visual-foundations.md](references/visual-foundations.md).
3. Inspect the relevant Figma frame in file `CCVlatyKW7MSHRGE3PK50i` before designing or implementing UI.
4. Inspect `docs/design-system/`, the relevant existing screen, and `Baseline/Shared/DesignSystem/`.
5. Resolve conflicts using this priority:
   1. Current product principles and explicit user direction.
   2. Current Figma design and design-system documentation.
   3. Existing reusable SwiftUI components and tokens.
   4. Legacy screens and one-off styling.
6. Load `product-design-playbook` for consumer UX, behavioral design, onboarding, copy, activation, retention, permissions, paywalls, empty states, and other matching patterns.
7. Load the shared SwiftUI and accessibility skills for production UI work.
8. Load the applicable Figma skill before any Figma write action.

## Lead With The Product Decision

- Lead with what the user should do next.
- Make the recommendation, action, or editable training object visually primary.
- Place the material reasons, constraints, and uncertainty close enough to build trust without turning the screen into a telemetry dashboard.
- Keep conversation and direct controls complementary.
  A user should be able to understand and change structured state without depending on chat history.
- Do not use a global readiness score, recovery gauge, or four-band dashboard as the default information hierarchy.
- Keep optional evidence visually subordinate unless the user is explicitly inspecting that evidence.

## Prototype Before Committing

- Use the `lavish` skill and Lavish AXI for a new screen, flow, or material redesign when the direction is not already established.
- Match Baseline's design system in the prototype rather than using Lavish fallback styling.
- Build enough interaction to evaluate hierarchy, editing, navigation, error states, and uncertainty.
- Open the prototype for review, respond to annotated feedback, and resolve layout warnings before treating the direction as approved.
- Carry an approved prototype into Figma or SwiftUI without changing the underlying product decisions silently.

## Implement With Parity

- Use centralized color, typography, spacing, haptic, and component primitives.
- Do not hard-code a token when an established semantic token or component exists.
- Keep the violet accent reserved primarily for interaction and brand emphasis.
  Use status colors only when they represent an actual semantic state.
- Prefer restrained outlines, hairlines, clear hierarchy, and purposeful depth over dense cards or decorative effects.
- Preserve Dynamic Type, VoiceOver, Reduce Motion, sufficient contrast, and comfortable touch targets.
- When changing a shared visual token, update the Swift source, Figma styles or components, and human-readable design-system reference together.

## Verify The Real Experience

1. Exercise the screen with realistic populated, empty, loading, error, disabled, long-content, and permission-denied states as applicable.
2. Render or run the actual interface rather than reasoning only from source.
3. Compare it with the approved Figma frame or prototype.
4. Check small and large device sizes, Dynamic Type, keyboard presentation, safe areas, scrolling, truncation, and accessibility behavior.
5. Treat visible spacing, hierarchy, alignment, clipping, animation, or state inconsistencies as defects.
6. Update the design-system references when a durable pattern changes.

## Handle Legacy Artifacts

Older Figma frames, design documents, and SwiftUI components still center the product on readiness scores, recovery bands, HRV, MED or HPL or MDV, and HYROX-specific concepts.
Reuse their validated tokens and useful interaction patterns, but do not propagate their legacy product hierarchy into new work.
