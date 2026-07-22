# Workout import corpus

One JSON file per real workout. Each file pairs a `sketch` — what the model is expected to
comprehend from the source — with the **structure** the conversion layer must produce from it.

Adding a case is meant to be trivial:

1. Drop a new `<name>.json` in this directory following the schema below.
2. Run `xcodegen generate` so the new file joins the test bundle's resources.
3. `WorkoutImportCorpusTests` picks it up automatically. No test code changes.

## Schema

```jsonc
{
  "name": "vo2-thresholds",
  "source": "where this workout came from, for whoever reads a failure",
  "sketch": { /* a WorkoutImportSketch: title, notes, blocks[].items[] */ },
  "expect": {
    "title": "AM: VO2 THRESHOLDS",
    "blocks": ["Warmup", "A) 400s"],            // block names in order
    "exercises": ["Run", "Run"],                 // exercise names in document order
    "groups": [{ "label": "1", "size": 2 }],     // one-level groups in order; omit if none
    "unresolved": [],                            // source names Baseline must refuse to guess
    "setCounts": { "1": 15 },                    // exercise index → number of sets
    "metrics": { "1": { "distance": 400 } },     // exercise index → canonical values on every set
    "notesContain": { "0": ["easy"] },           // exercise index → coach text that must survive
    "workoutNotesContain": ["Intent:"],            // workout-level coach text that must survive
    "blockNotesContain": { "0": ["4 rounds"] }      // block index → shared scheme text that must survive
  }
}
```

Every `expect` key is optional except `exercises`. Values in `metrics` are **canonical** —
metres, kilograms, seconds, reps, kcal — never the units the source was written in.

## Judging a case

Structure first: right exercises, right order, right grouping. A missing number is seconds of
typing for the athlete and the case should still pass on structure; a wrong skeleton wastes
everything under it, so `exercises`, `blocks`, and `groups` are the assertions that matter most.
Pin `metrics` and `setCounts` only where the source genuinely settles them.
