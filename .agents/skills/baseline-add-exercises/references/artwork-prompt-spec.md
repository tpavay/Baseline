# Exercise Artwork Prompt Specification

Use this specification for every new Baseline exercise illustration prompt and every visual review of generated exercise artwork.

## Output Contract

- Write a complete standalone prompt for each exercise.
- Put each prompt in its own fenced `text` block with the exercise name immediately above it.
- Repeat every required style and extraction rule in every prompt, including batch requests.
- Do not refer to prior prompts, prior images, or an implied shared style.
- Ask only when the exercise identity, equipment variant, or defining movement phase is materially ambiguous.
- Use an edit prompt only when the reference has correct overall geometry and needs a narrow correction.
- Start from a blank generation when a reference repeatedly anchors incorrect anatomy, grip, direction, or equipment layout.

## Movement Fidelity

Describe the exercise before describing the style.

Every prompt must state:

- The exact exercise and equipment variant.
- The defining movement phase shown in the still image.
- The camera angle needed to reveal the defining mechanics.
- The torso, hip, knee, ankle, shoulder, elbow, wrist, and head positions that disambiguate the movement.
- The grip type, palm direction, hand spacing, and thumb position when grip matters.
- The athlete's facing direction and the direction of the feet, knees, machine, cable stack, bench, pads, or target when orientation matters.
- The geometry and placement of all exercise-defining equipment.
- The bar, cable, rope, handle, sled, machine, or implement path when motion matters.
- The specific features that distinguish the exercise from its closest visual alternatives.

Prefer an active and recognizable movement phase over a generic setup or static end position.
For multi-phase exercises, choose the single phase that best communicates the exercise and add restrained motion cues only where they improve recognition.
Do not invent impossible anatomy to show multiple phases at once.

## Canonical Visual Language

- Use one faceless, hairless, gender-neutral mannequin unless the request explicitly calls for another body type.
- Use realistic athletic proportions and credible biomechanics without exaggerated musculature.
- Use matte off-white body panels with restrained flat gray anatomical shading.
- Use graphite equipment with restrained Baseline violet accents.
- Use pure black containment outlines and consistent internal line weights.
- Keep the athlete visually primary while showing every piece of exercise-defining equipment completely.
- Use a square 1024 x 1024 composition.
- Keep the complete subject inside a centered safe area with approximately 8 to 10 percent padding on every side.
- Center by visual mass rather than by the mannequin alone when equipment materially changes the composition.
- Use no clothing, facial features, hair, text, labels, logos, trademarks, scenery, decorative card, floor texture, or unrelated objects.

## Extraction-Safe Background And Edges

Every prompt must include all of these requirements.

- Render the source on one completely flat chroma-cyan `#00E5FF` background.
- Do not use chroma-cyan anywhere inside the athlete, equipment, accents, or motion cues.
- Use no background gradient, texture, grid, scenery, shadow, glow, lighting variation, or vignette.
- At 1024 x 1024, use a continuous 10 to 12 pixel pure black outer contour around every meaningful foreground component.
- At 1024 x 1024, use 5 to 6 pixel pure black internal contours with rounded line joins and rounded line caps.
- Make every contour fully opaque, solid, smooth, and uninterrupted.
- Contain the athlete, equipment, plates, benches, boxes, handles, ropes, cables, bars, machines, and other essential components with clear black edges.
- Render essential thin cables, ropes, bars, and handles thick enough to survive extraction, with at least a 3 pixel black keyline on both sides.
- Use motion cues only when they clarify the exercise.
- Keep motion cues close to the moving body or equipment, render them at least 10 pixels thick, and surround them with a 3 to 4 pixel black keyline.
- Do not use detached faint marks, translucent strokes, outer glow, rim light, drop shadow, feathering, antialiased gray fringe, semitransparent outlines, sketch marks, or background-colored gaps.
- Do not place a white highlight directly against an outer edge.

The chroma background is source-generation material, not part of the published asset.
The app's normalizer still produces the canonical transparent thumbnail and detail PNGs.

## Prompt Structure

Use this order so movement requirements are not diluted by style language:

1. `CREATE` names the exercise and requests a completely new square illustration.
2. `DEFINING ACTION` specifies the exact phase and biomechanics.
3. `CAMERA AND ORIENTATION` specifies viewpoint and spatial relationships.
4. `EQUIPMENT AND CONTACT` specifies equipment geometry, grip, pads, contact points, and load placement.
5. `MOTION` specifies only necessary motion trails or arrows.
6. `COMPOSITION` specifies scale, padding, centering, and complete visibility.
7. `VISUAL STYLE` states the canonical Baseline mannequin and equipment language.
8. `BACKGROUND AND EDGE PROTECTION` repeats the full extraction-safe requirements.
9. `DO NOT GENERATE` lists the closest incorrect movements plus known anatomy, equipment, branding, and extraction failures.

Never shorten the background and edge section because a previous prompt already contained it.

## Correction Strategy

When reviewing a generated image, separate failures into movement fidelity, anatomy, equipment, composition, style, and extraction risk.
Write a narrow edit prompt only when preserving the existing image is beneficial.
State the intended geometry positively before listing exclusions.
For grip corrections, state both where the palms face and where the knuckles face.
For machine corrections, describe the ordered spatial relationship between the camera, athlete, pads, feet, attachment, and machine stack.
For multi-step movement corrections, choose one recognizable phase rather than combining incompatible poses.
After two failed edits caused by the same anchored error, stop editing the reference and issue a new complete prompt from scratch.

## Visual QA Before Ingestion

Compare the generated source and background-removed result side by side at full resolution.

Reject or repair the cutout when any of these changed or disappeared:

- The black silhouette around any body part or equipment.
- A cable, rope, bar, handle, plate, machine rail, bench leg, box edge, or sled component.
- A finger, hand, foot, limb segment, or contact point.
- A motion cue required to understand the movement.
- An enclosed negative space inside equipment.
- The intended crop, padding, or visual center.

Inspect the cutout again on both dark and light surfaces and at 48-point thumbnail size.
Do not approve an image merely because the full-size source looks correct.
