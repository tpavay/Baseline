# Muscle-map reference figure prompts

Four standing-figure prompts for generating the front/back muscle-map reference assets.
Each already has the OUTLINE AND BACKGROUND REQUIREMENTS block appended.
Generate at 1:1, 1024×1024. These are **references for tracing** to layered SVG — not the final interactive assets.

Muscle groups per view (from the 22-muscle taxonomy):
- **FRONT (11):** neck, chest, front delts, side delts, biceps, forearms, abdominals, obliques, hip flexors, quadriceps, adductors  *(+ calves/shins visible)*
- **BACK (10):** neck, traps, upper back, rear delts, lats, triceps, forearms, lower back, glutes, hamstrings, calves  *(+ abductors / outer hip)*
- **Full body** = systemic wash across both.

Each logical muscle becomes a `<g id="quadriceps"><path/><path/></g>` in the traced SVG (bilateral/wrapping muscles need multiple shapes). Track at the group level (one "Quadriceps"); the art can show sub-shapes.

---

## OUTLINE + BACKGROUND BLOCK (appended to every prompt below)

```
OUTLINE AND BACKGROUND REQUIREMENTS:

Render the illustration as crisp, flat vector-style artwork intended for automatic background removal and later SVG tracing.

At 1024 x 1024 resolution:
- Draw one continuous 10 to 12 pixel PURE BLACK outer silhouette around the entire body.
- Draw internal anatomical and body-section boundaries with 5 to 6 pixel PURE BLACK strokes.
- Make every stroke fully opaque, solid, smooth, and uninterrupted.
- Use rounded line joins and rounded line caps.
- Keep every outer edge sharply defined against the background.
- Fill the body with a uniform matte off-white color.
- Do not place white highlights directly against the outer edge.

Use a completely flat, uniform chroma-cyan background that does not appear anywhere inside the figure. The background must contain no texture, gradient, grid, shadow, or lighting variation.

Do not generate an outer glow, rim light, drop shadow, blurred edge, semitransparent outline, gray fringe, feathering, soft halo, sketch marks, or background-colored gaps through the outline. The black silhouette must remain clearly visible after the surrounding background is removed.
```

---

## 1 — ANTERIOR (front), detailed muscular reference

Flat vector-style anatomical fitness illustration of a single adult human figure standing upright in anatomical position, viewed from the FRONT (anterior view), facing the viewer, arms straight and held slightly away from the body with palms facing forward, legs together, perfectly symmetrical left and right. Lean athletic muscular build, gender-neutral, no face details, no hair detail, no clothing.

The body surface is divided into clearly delineated MUSCLE-GROUP SECTIONS — each muscle group is a distinct closed region separated by clean internal boundary lines — covering exactly these front-of-body muscle groups: neck, chest (pectorals), front deltoids, side deltoids, biceps, forearms, abdominals, obliques, hip flexors, quadriceps (front thighs), adductors (inner thighs), and calves/shins. Draw bilateral muscles (deltoids, biceps, forearms, quadriceps, calves) as clearly separate left and right regions. Absolutely no text, no labels, no numbers, no arrows.

*(+ OUTLINE + BACKGROUND BLOCK)*

## 2 — POSTERIOR (back), detailed muscular reference

Flat vector-style anatomical fitness illustration of a single adult human figure standing upright in anatomical position, viewed from the BACK (posterior view), the back of the head and heels toward the viewer, arms straight and held slightly away from the body, legs together, perfectly symmetrical left and right. Lean athletic muscular build, gender-neutral, no hair detail, no clothing.

The body surface is divided into clearly delineated MUSCLE-GROUP SECTIONS — each muscle group is a distinct closed region separated by clean internal boundary lines — covering exactly these back-of-body muscle groups: neck, trapezius (traps), upper back, rear deltoids, lats, triceps, forearms, lower back (erectors), glutes, hamstrings, calves (gastrocnemius), and abductors (outer hips / glute medius). Draw bilateral muscles (deltoids, triceps, forearms, lats, glutes, hamstrings, calves) as clearly separate left and right regions. Absolutely no text, no labels, no numbers, no arrows.

*(+ OUTLINE + BACKGROUND BLOCK)*

## 3 — ANTERIOR (front), simplified / cleaner boundaries

Same as #1, but SIMPLIFIED: fewer internal sub-shapes, smoother larger muscle-group regions, minimal surface detail — one clean closed region per muscle group, easiest to trace. Same front muscle groups, same symmetry, same no-text rule.

*(+ OUTLINE + BACKGROUND BLOCK)*

## 4 — POSTERIOR (back), simplified / cleaner boundaries

Same as #2, but SIMPLIFIED: fewer internal sub-shapes, smoother larger muscle-group regions, minimal surface detail — one clean closed region per muscle group, easiest to trace. Same back muscle groups, same symmetry, same no-text rule.

*(+ OUTLINE + BACKGROUND BLOCK)*
