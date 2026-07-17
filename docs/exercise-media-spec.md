# Exercise Media Specification

Exercise media is optional catalog content. Missing, unpublished, or failed media must never block
exercise search, creation, planning, or logging. The exercise name and category glyph remain the
functional fallback.

## Canonical Assets

Every published exercise may have two still-image variants. Both are transparent PNGs with no card,
panel, text, watermark, or third-party logo baked into the artwork.

Source artwork may arrive as a transparent PNG or as a 1024 x 1024 JPEG with a rendered
checkerboard. JPEG sources are import material only; the normalizer uses Apple Vision foreground
instance masking before creating the canonical transparent PNG exports.

### Detail

- Canvas: 1024 x 1024 pixels.
- Transparent background with transparent corners.
- Full athlete and all exercise-defining equipment visible.
- Subject fits within an 880 x 880 pixel area, centered by visual mass.
- Consistent mannequin, outline weight, violet accents, lighting, and motion marks.
- No glow or shadow may touch the canvas edge.

### Thumbnail

- Canvas: 512 x 512 pixels.
- Transparent background with transparent corners.
- Tighter crop derived from the same approved source as the detail asset.
- Subject fits within a 430 x 430 pixel area (approximately 84% of the canvas).
- Must remain identifiable when rendered at 48 points.
- No soft background glow may extend to the canvas edge.

The app supplies its own surface color. Assets must not bake in `BaselineColor.surface`, so the same
art can be used in picker rows, details, widgets, and future themes.

## Storage Layout

Paths are versioned and stored in the exercise-media manifest. The app stores paths, not permanent
Firebase download URLs.

The app downloads published images through the authenticated Firebase Storage SDK with a 5 MB
limit, then caches the versioned bytes in memory and the system Caches directory. It does not create
public download-token URLs.

```text
exercise-media/<exercise-definition-id>/v<version>/thumbnail.png
exercise-media/<exercise-definition-id>/v<version>/detail.png
exercise-media/<exercise-definition-id>/v<version>/preview.mp4
exercise-media/<exercise-definition-id>/v<version>/instruction.mp4
```

Video fields are reserved in the schema but are not loaded or rendered in this implementation.

## Publication Lifecycle

- `draft`: source exists but has not passed normalization and visual QA.
- `ready`: normalized assets passed local QA and are ready to upload.
- `published`: files exist at their manifest paths and may be requested by the app.
- `blocked`: must not ship, for example because of visible branding or incorrect biomechanics.
- `retired`: previously published media that should no longer be requested.

Only `published` entries are eligible for network loading. Changing a status to `published` is the
last step after upload verification, not a promise that an upload will happen later.

## Current Pipeline

Run the normalizer from the repository root:

```bash
scripts/normalize-exercise-media.sh ~/Downloads
scripts/normalize-exercise-media.sh ~/Downloads "$PWD/.generated" elliptical plank
```

The first form rebuilds the full manifest. The second processes only the requested exercise IDs and
is the preferred path for incremental single or batch additions.

The normalizer requires `jq`, ImageMagick, and the Xcode command-line tools. For a source without an
alpha channel, it compiles `scripts/extract-exercise-media-foreground.swift` and preserves every
foreground instance Vision identifies. This avoids color-keying the off-white mannequin or graphite
equipment. Foreground extraction is not publication approval: always inspect thin bars, cables,
motion marks, and enclosed equipment areas because an automated mask can omit them.

Outputs are written to `.generated/exercise-media/` using the exact Firebase Storage paths in the
manifest. The directory is intentionally ignored by Git and is not part of the app binary.

Generate dark, light, and 48-point QA sheets for one or more normalized entries:

```bash
scripts/create-exercise-media-contact-sheets.sh elliptical plank
```

After the Firebase Storage bucket has been provisioned, deploy the locked-down client rules and
upload only entries whose status is `ready`:

```bash
npx -y firebase-tools@latest deploy --only storage --project baseline-app-dev
scripts/upload-exercise-media.sh baseline-app-dev.firebasestorage.app elliptical plank
scripts/verify-exercise-media.sh baseline-app-dev.firebasestorage.app elliptical plank

scripts/upload-exercise-media.sh baseline-app-prod.firebasestorage.app elliptical plank
scripts/verify-exercise-media.sh baseline-app-prod.firebasestorage.app elliptical plank

scripts/promote-exercise-media.sh elliptical plank
```

The verifier compares object path, content type, immutable cache control, size, and exact MD5 with
the generated local file. Promote only after every requested environment passes. The upload script
does not promote statuses automatically, so a partial upload can never make the app request files
that are not present.

Before publication, inspect every thumbnail in the actual exercise picker at 48 points and every
detail image on the app's dark surface. Reject branding, illegible silhouettes, clipped equipment,
inconsistent anatomy, and movement phases that could be mistaken for a different exercise.
