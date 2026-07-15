# Feature Contract: Live Heart Rate Slice 2 — zone settings + local config

- Issue: #11
- Base branch: `feature/issue-2-workout-image-import`
- Change type: feature
- Owner: orchestrator

Base note: branched from live-HR Slice 1 tip `28fee91`. `main` remains stale (recorded in #4).

## User outcome

The Profile "Heart Rate Zones — Karvonen / LTHR" row stops being a greyed-out "coming soon" stub
and opens a real settings screen: the athlete sees their max HR (defaulted from age via Tanaka,
editable), can set resting HR (which switches zones to the more personal Karvonen/HRR method) and an
optional LTHR, and sees a live Z1–Z5 boundary preview (BPM ranges + zone colors) that updates as they
edit. Settings persist locally across launches.

## Non-goals

- No live-HR spectrum view and no workout wiring (Slice 3 / go-live).
- **No Firestore profile fields for zones and no `firestore.rules` change** — the strict
  `users/{uid}` `hasOnly` schema makes new profile fields a deploy-coupled change that would reject
  profile writes until rules deploy; zone config is stored **locally** (UserDefaults-JSON), reading
  the existing profile `ageYears` for the Tanaka default. Firestore sync is a documented future
  enhancement, not this slice.
- No change to `HeartRateZoneModel` math (Slice 1) beyond consuming it; no monitor/BLE changes.
- Existing tests untouched.

## Acceptance criteria

- [ ] AC-1: The Profile "Heart Rate Zones" row is no longer `.soon`; tapping it opens
      `HeartRateZoneSettingsView`. No other Profile row changes.
- [ ] AC-2: `HeartRateZoneSettingsStore` (UserDefaults-JSON) round-trips the config (maxHR override,
      restingHR, LTHR) across store re-init; an absent/empty store yields sensible defaults (no
      override; max from Tanaka(ageYears)); writes persist.
- [ ] AC-3: Max-HR default is Tanaka(`ageYears`) when the user has not overridden it; an explicit
      user max overrides it and is never silently replaced (per the domain skill's "never overwrite a
      tested max" rule).
- [ ] AC-4: **restingHR < maxHR validation** — the settings screen prevents committing
      `restingHR ≥ maxHR` (and `LTHR` outside a sane band), so the persisted config can never produce
      a degenerate `HeartRateZoneModel`; the model built from any committed config is well-formed
      (zones strictly increasing).
- [ ] AC-5: The zone preview shows five rows (Z1…Z5) with BPM ranges computed from the current
      `HeartRateZoneModel` (Karvonen when resting HR set, else %max) and the conventional zone colors;
      it recomputes when inputs change. Ranges match the model (no separate/ drifting math).
- [ ] AC-6: The settings screen presents the active method (HRR vs %max) honestly based on whether
      resting HR is set.
- [ ] AC-7: No behavior change elsewhere: full existing suite passes unmodified; new types referenced
      only within the HeartRate feature + Profile row + tests; `BaselineApp.swift` untouched; no
      Firestore/rules change; the live monitor is still never started.

## State matrix

| State | Expected behavior | Verification |
|---|---|---|
| Happy path | Edit max/resting/LTHR → preview + persistence update | AC-2/AC-5 |
| Empty | Fresh install: max = Tanaka(age), no resting, %max method | AC-3/AC-6 |
| Invalid | resting ≥ max → blocked, not committed | AC-4 |
| Loading | Not applicable: local synchronous store |

## Test mapping

| Acceptance criterion | Automated test or evidence | Why it proves the behavior |
|---|---|---|
| AC-1 | `ProfileRowTests`/inspection + preview | Row destination is the settings view, others unchanged |
| AC-2 | `HeartRateZoneSettingsStoreTests` round-trip + defaults | Persist/reload asserted |
| AC-3 | `HeartRateZoneSettingsTests` Tanaka-default vs override | Default derived, override wins |
| AC-4 | `HeartRateZoneSettingsTests` validation cases | resting ≥ max rejected; model well-formed |
| AC-5 | `HeartRateZoneSettingsTests` preview-ranges-match-model | Preview rows equal model boundaries |
| AC-6 | `HeartRateZoneSettingsTests` method-selection | HRR iff resting set |
| AC-7 | Full suite green; scope grep; BaselineApp/rules 0-diff | Isolation |

## UX evidence

SwiftUI `#Preview`s of `HeartRateZoneSettingsView` (default/Tanaka, with resting HR → Karvonen, with
LTHR, invalid-input state) in light + dark, rendered via `RenderPreview` for the UX review.
Design-system tokens/components, not fallback styling.

## Risk and rollout

- **Data migration:** none — new local store; absent store → defaults.
- **Backward compatibility:** additive; the Profile row swaps a `.soon` placeholder for a real screen.
- **Privacy/security:** local only; no new Firestore data; no values logged.
- **Analytics/flags:** none.
- **Rollback:** revert branch; the row returns to `.soon`.
- **Deployment order:** independent; feeds Slice 3's preview and the go-live workout wiring.

## Human gates

- None. (Firestore sync of zone config is deferred; if later desired it carries the rules-update +
  lockstep-deploy requirement.)
