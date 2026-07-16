---
name: baseline-add-exercises
description: Create, review, correct, add, import, replace, or publish one or many Baseline exercise illustrations and catalog exercises, including full extraction-safe artwork prompts, biomechanics and visual QA, catalog identity, aliases, logging metrics, manifest records, transparent thumbnail/detail normalization, Firebase Storage upload to dev/prod, remote verification, publication, and focused tests.
---

# Baseline Add Exercises

Treat one exercise as a batch of one.
Process a supplied batch together so setup, validation, builds, and deployments are not repeated per exercise.

## Select The Workflow

- For prompt generation, art direction, or image correction, read [artwork-prompt-spec.md](references/artwork-prompt-spec.md) and complete only the artwork stage unless the user also supplied final source files.
- For catalog or media ingestion, complete the repository, normalization, validation, upload, and publication stages below.
- For a request spanning both stages, generate or approve the artwork first and ingest only files that pass visual QA.

## Generate Or Review Artwork

Read [artwork-prompt-spec.md](references/artwork-prompt-spec.md) before writing or reviewing exercise artwork prompts.

- Return one complete standalone prompt per exercise inside its own fenced text block.
- Repeat the full visual, background, edge, composition, and negative requirements in every prompt.
- Never rely on phrases such as "same style," "as above," or "like the previous image."
- Describe the defining movement phase, joint positions, grip, palm direction, foot direction, equipment geometry, camera angle, and motion cues explicitly.
- Require the canonical flat chroma-cyan source background and fully opaque black containment outlines around every meaningful foreground component.
- Prefer a fresh generation when a failed reference anchors the model to incorrect anatomy or equipment geometry.
- When an image is supplied, inspect biomechanics, anatomy, equipment, framing, brand consistency, and extraction risk before approving it.
- Do not begin catalog work when the request is only for prompts or artwork feedback.

## Locate And Protect The Worktree

1. Use the current repository when it contains `Baseline/` and `AGENTS.md`; otherwise use `/Users/tylerpavay/Documents/Development/iOS/Baseline`.
2. Read `AGENTS.md`, then inspect `git status --short`.
3. Preserve unrelated and concurrent changes.
4. Load the Firebase and relevant Swift skills before changing those domains.
5. Read only these known surfaces first:
   - `Baseline/Features/Workout/ExerciseCatalog.swift`
   - `Baseline/Resources/ExerciseMedia/exercise-media-manifest.json`
   - `BaselineTests/ExerciseMediaTests.swift`
   - `BaselineTests/WorkoutMetricsTests.swift`
   - `docs/exercise-media-spec.md`
   - `scripts/*exercise-media*`

## Build The Batch

For every supplied image, determine `id`, display name, source filename, category, supported metrics, default metrics, and aliases.
Read [exercise-spec.md](references/exercise-spec.md) for the schema and selection rules.

- Reuse an existing definition when the movement already resolves to one.
- Add media to that stable identity instead of creating duplicate history.
- Use stable snake-case IDs.
- Search names, IDs, and aliases for collisions before editing.
- Infer unambiguous metadata from the exercise name and established neighboring definitions.
- Ask only when exercise identity or logging behavior is genuinely ambiguous.
- Add all catalog definitions in one patch and all alias tests in one patch.
- Add manifest entries with `publicationStatus: "ready"`.
- Use `v1` for new media.
- When replacing published media, increment the version and paths.
- Never overwrite an immutable published path.
- Keep `previewVideoPath` and `instructionalVideoPath` null.
- Keep raw source images outside the repository.
- Write generated outputs only under ignored `.generated/` paths.

Maintain exact parity between manifest keys and catalog definitions whose `media` is non-nil.
Do not promote a manifest entry until its remote objects are verified.

## Normalize Once

Run one command for the batch:

```bash
scripts/normalize-exercise-media.sh <source-directory> "$PWD/.generated" <id> [<id> ...]
```

The normalizer preserves valid alpha PNGs and uses Apple Vision to extract foregrounds from JPEGs or other 1024 x 1024 sources without alpha.
Stop on missing files, wrong dimensions, absent alpha, or nontransparent corners.

Generate all QA sheets in one command:

```bash
scripts/create-exercise-media-contact-sheets.sh <id> [<id> ...]
```

Inspect the original source, extracted detail asset, dark sheet, light sheet, and 48-point sheet.
Compare source and cutout side by side to detect removed outlines, cables, ropes, bars, fingers, feet, equipment edges, and motion cues.
Check biomechanics, complete equipment, hands and feet, no checkerboard remnants, no logos or text, consistent crop, and recognition at picker size.
Do not deploy artwork that fails visual QA.

## Validate Locally

Before network writes:

1. Run `jq empty` on the manifest and `git diff --check`.
2. Assert every requested ID is `ready`, has both generated files, and resolves in the catalog.
3. Run `xcodegen generate`.
4. Run only the focused suites while reusing their isolated build cache:

   ```bash
   xcodebuild test \
     -project Baseline.xcodeproj \
     -scheme Baseline \
     -destination 'platform=iOS Simulator,name=iPhone 16' \
     -derivedDataPath /tmp/BaselineExerciseMediaDerivedData \
     -only-testing:BaselineTests/ExerciseMediaTests \
     -only-testing:BaselineTests/ExerciseCatalogTests
   ```

Do not start the full iOS suite unless the change crosses those boundaries.

## Upload And Publish

Use these buckets:

- Dev: `baseline-app-dev.firebasestorage.app`
- Prod: `baseline-app-prod.firebasestorage.app`

Verify CLI authentication and project context once.
Existing Storage rules already support versioned PNG thumbnail and detail paths, so do not deploy rules unless they changed.

Upload dev once, then verify every object:

```bash
scripts/upload-exercise-media.sh baseline-app-dev.firebasestorage.app <id> [<id> ...]
scripts/verify-exercise-media.sh baseline-app-dev.firebasestorage.app <id> [<id> ...]
```

Upload prod only when the request includes production publication and local and dev checks pass:

```bash
scripts/upload-exercise-media.sh baseline-app-prod.firebasestorage.app <id> [<id> ...]
scripts/verify-exercise-media.sh baseline-app-prod.firebasestorage.app <id> [<id> ...]
```

The verifier must confirm path, PNG content type, immutable cache control, size below 5 MB, and exact local and remote MD5.
After both requested environments verify, publish once:

```bash
scripts/promote-exercise-media.sh <id> [<id> ...]
```

Re-run the focused tests after promotion.
If prod was not requested, leave entries `ready` and state that clearly.
Do not imply that unpublished media will render in the app.

## Finish

Report the exercise IDs, environments uploaded, object count, publication state, focused test result, and any supplied movement omitted due to missing or ambiguous artwork.
State that authenticated picker rows display published thumbnails and retain icon fallbacks.
Do not commit unless requested.
