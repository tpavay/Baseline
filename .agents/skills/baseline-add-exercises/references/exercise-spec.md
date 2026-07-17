# Exercise Specification

Use this compact record while preparing a single exercise or a batch:

```json
{
  "id": "dumbbell_bench_press",
  "name": "Dumbbell Bench Press",
  "sourceFilename": "DumbbellBenchPress.png",
  "category": "strength",
  "supported": ["reps", "load", "rpe"],
  "defaults": ["reps", "load", "rpe"],
  "aliases": ["dumbbell bench press", "db bench press", "dumbbell bench"]
}
```

## Identity

- Prefer an existing canonical ID when names or aliases describe the same movement.
- Create a separate definition when equipment or execution materially changes logging or history,
  such as barbell bench press versus dumbbell bench press.
- Use lowercase snake case without branding where a generic modality is adequate. Preserve an
  existing branded stable ID rather than migrating history during an asset import.
- Include common spacing, hyphenation, abbreviation, singular/plural, and coaching-language aliases.
- Do not add an alias already owned by another definition. Test important natural-language aliases.

## Categories

Valid categories are `cycling`, `running`, `erg`, `strength`, `carry`, `isometric`, and `other`.

## Metrics

Valid metrics are `reps`, `load`, `duration`, `distance`, `calories`, `heartRate`,
`heartRateZoneTime`, `cadence`, `power`, `pace`, and `rpe`.

Use neighboring catalog definitions as the authority. Typical patterns:

| Movement | Supported | Defaults |
| --- | --- | --- |
| Strength lift | reps, load, rpe | reps, load, rpe |
| Bodyweight repetition | reps, duration, rpe | reps, rpe |
| Isometric | duration, load, rpe | duration, rpe |
| Loaded carry | distance, load, duration, rpe | distance, load |
| Conditioning machine | duration, distance/calories, heartRate, cadence/power/rpe as measurable | duration plus its primary output |
| Hybrid station | reps or distance, load when applicable, duration, rpe | competition-scored output plus duration/load |

Defaults must be a subset of supported metrics. Do not expose a metric the modality cannot reasonably
produce or the current logging UI cannot represent.

## Manifest

New media uses:

```json
{
  "sourceFilename": "DumbbellBenchPress.png",
  "thumbnailPath": "exercise-media/dumbbell_bench_press/v1/thumbnail.png",
  "detailPath": "exercise-media/dumbbell_bench_press/v1/detail.png",
  "previewVideoPath": null,
  "instructionalVideoPath": null,
  "version": 1,
  "publicationStatus": "ready"
}
```

Use `ready` until requested Firebase environments have exact verified objects. Use `published` only
after verification. Use `blocked` for artwork that cannot ship, with the reason documented in the
media spec or task summary.
