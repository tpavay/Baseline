# Feature Contract: Sleep Engine Slice 5 — sleep UI (detail view, timeline chart, check-in upgrade)

- Issue: #8
- Base branch: `feature/issue-2-workout-image-import`
- Change type: feature
- Owner: orchestrator

Base note: branched from the Slice 4 merge point (`28b0956`). `main` remains stale (recorded in #4).

## User outcome

When sleep data is available (after the owner go-live), tapping the sleep row on Today opens a
`SleepDetailView` that explains the night behind the readiness decision: the Apple-aligned score with
its duration/consistency/interruptions breakdown, an in-house stage timeline chart, additional stage
evidence shown separately from the score, acute/chronic/debt comparisons, notable-night flags,
descriptive insights, source/sync provenance, and an influence/cap footer tying sleep to today's
decision. The morning check-in card shows the score + quality when Health sleep is present. **Until
that go-live these surfaces are inert** — every one is gated on a `SleepAnalysis` existing for today,
which is nil while the engine is dormant, so the app is visually byte-identical to today.

## Non-goals

- No `get_sleep_evidence` agent tool (deferred: it needs `AgentTools.swift`/`ToolCallMapper.swift`/
  `ConversationService.swift`/`functions/src/*`, all in owner WIP — recorded in the go-live doc as a
  fast follow).
- No `BaselineApp.swift` change; no store registration; no seam activation (go-live is owner-performed).
- No third-party charting dependency — the timeline chart is in-house SwiftUI.
- No change to the scoring/engine/persistence logic (Slices 1-4); this slice only reads `SleepAnalysis`.
- Existing tests untouched; existing Today/check-in behavior unchanged when dormant.

## Acceptance criteria

- [ ] AC-1: `SleepTimelineChart` renders `[SleepStageInterval]` as stage bands on a time axis with gap
      hatching and naps shown separately; all interval→geometry math lives in a pure, testable layout
      helper (unit-tested), and `body` contains only layout. Uses design-system tokens for stage
      colors (distinct from the readiness band hues).
- [ ] AC-2: `SleepDetailView` renders the full plan-§9 layout from a `SleepAnalysis`: score-or-
      observed-points + quality/status badge, timeline, duration/awake/gap stats, Apple-aligned
      component breakdown (x/50, x/30, x/20), a visually distinct additional-stage-evidence section,
      vs-you comparisons (acute/chronic + debt + flags), descriptive insight lines, provenance/sync
      state, and the influence/cap attribution footer. Business/formatting logic is in a presentation
      model or pure helpers, not in `body`.
- [ ] AC-3: Partial-night rendering: when `score == nil`, the view shows observed/possible points +
      coverage (never a fabricated 0–100); a manual night shows its evidence with the low-reliability
      quality state; component rows show availability honestly.
- [ ] AC-4: The influence/cap footer distinguishes weighted influence ("N of M possible points") from
      cap attribution ("today's readiness was capped by short sleep"), computed from the decision
      result's domain/appliedCaps — never presenting a weighted term as a causal contribution.
- [ ] AC-5: `SleepCheckInCard` upgrade: with Health sleep + an analysis present, shows score +
      duration + a quality hint (+ provisional marker when applicable); the manual thumbs/stepper
      path is unchanged.
- [ ] AC-6: The Today sleep row is fully tappable and pushes `SleepDetailView` **only when a
      `SleepAnalysis` exists for today**; when none exists (dormant, or a day with no sleep) the row
      is byte-identical to today (no tap target, no visual change).
- [ ] AC-7: **Dormancy / parity:** with the engine dormant (no analysis available), Today, the
      check-in card, and the morning flow are visually and behaviorally identical to pre-slice —
      proven by the new surfaces being gated on analysis presence and by the existing suite passing
      unmodified.
- [ ] AC-8: Accessibility & adaptivity: `SleepDetailView` and the chart support Dynamic Type, provide
      VoiceOver labels/values for the score, components, chart summary, and flags, and render in light
      and dark; the chart degrades to an accessible summary under large Dynamic Type.
- [ ] AC-9: No behavior change in the running app: full existing suite passes unmodified;
      `BaselineApp.swift` diff empty; new views referenced only within the Today/Sleep feature and
      tests; no live navigation reaches `SleepDetailView` while dormant.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path (analysis present) | Full detail view; tappable row; card shows score | AC-2/AC-5/AC-6 preview + tests |
| Loading/provisional | Provisional badge; timeline from available intervals | AC-2 preview |
| Empty/partial (score nil) | Observed/possible + coverage; no fabricated score | AC-3 preview + tests |
| Dormant (no analysis) | Byte-identical to today; row not tappable | AC-6/AC-7 tests |
| Manual night | Evidence + low reliability; no score | AC-3/AC-5 preview |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `SleepTimelineChartLayoutTests` (pure helper) + a rendered preview | Geometry math asserted without a view tree; visual via preview |
| AC-2 | `SleepDetailPresentationTests` + rendered previews (full/partial/manual) | Presentation model maps analysis→sections; layout via preview |
| AC-3 | `SleepDetailPresentationTests` partial/manual cases | Observed/possible + coverage asserted; no fabricated score |
| AC-4 | `SleepDetailPresentationTests` influence-vs-cap cases | Footer strings derived from domain/appliedCaps, not weighted term as cause |
| AC-5 | `SleepCheckInCardTests` / preview (Health-present vs manual) | Score/quality shown with data; manual path unchanged |
| AC-6 | `TodaySleepRowTests` (tappable iff analysis present) | Tap target gated on analysis presence |
| AC-7 | Existing Today/check-in suite green + dormancy gating test | Byte-identical when no analysis |
| AC-8 | Accessibility inspection of previews + Dynamic Type renders | Labels/values present; light/dark/large-type renders |
| AC-9 | Full suite green; `BaselineApp.swift` diff empty; reference grep | Isolation + no dormant navigation |

## UX evidence

Required: SwiftUI `#Preview` providers for `SleepDetailView` (full staged night, cold-start/partial,
manual, low-quality, no-data), `SleepTimelineChart`, and the upgraded `SleepCheckInCard`, each in
light + dark and at least one large Dynamic Type size — rendered to images (mcp__xcode__RenderPreview)
for the UX review. Screens must use Baseline design-system tokens/components (docs/design-system/,
`baseline-design-system` skill), not fallback styling. Final-state screenshots attached to the review.

## Risk and rollout

- **Data migration:** none (read-only over existing `SleepAnalysis`).
- **Backward compatibility:** new views additive; existing surfaces gated on analysis presence.
- **Privacy/security:** on-device rendering; no values logged; no new data leaves device.
- **Analytics/flags:** none; analysis-presence is the gate.
- **Rollback:** revert branch; nothing live changes while dormant.
- **Deployment order:** activates with the owner go-live (store registration + seam); the go-live doc
  gains the nav/card enablement note and the deferred agent-tool step.

## Human gates

- Owner review of the rendered screens is welcome (solo-dev pixel-perfection standard) but not
  required to converge the slice; go-live (store registration) remains owner-performed.
