# Baseline — Project Guide

## What Baseline Is
Baseline is a recovery-aware HYROX / hybrid training coach for iOS. Each morning the athlete takes a guided HRV reading from a chest strap; Baseline computes a readiness score and then **prescribes or modulates today's training** — running, HYROX stations, strength, and the "chassis" (joints, tendons, mobility) — adjusting the *dose* to the athlete's recovery.

The job it does: remove the daily "am I training the right thing today?" anxiety for self-coached hybrid athletes by automating the one judgment even elite coaches hand back to the athlete — *which dose to do today, given recovery*.

**Solo dev + AI assisted** (Tyler Pavay). Build-for-self first. Planned monetization: subscription (the recurring daily coach), via RevenueCat + SuperWall.

## What Baseline Is NOT (define the niche by exclusion)
- **Not a generic fitness or HRV tracker.** HYROX/hybrid-specific and recovery-driven. If a feature serves "any fitness user," it probably doesn't belong.
- **Not a passive readiness score (Whoop/Oura).** Every reading ends in a concrete session recommendation — the score is an input, not the product.
- **Not a measurement instrument that stops at the number (Elite HRV).** The reading → readiness → *what to train today* bridge is the whole point.
- **Not a static plan / PDF (Warrior Lab).** The program adapts daily to recovery.
- **Not a generic logger.** Logging exists to serve the recovery-aware coaching loop.
- **Not hardware-locked (Morpheus).** Works with a chest strap the athlete already owns (or a wearable via HealthKit).

## Core Product Model
**The daily loop:** morning reading → readiness score → today's session (proposed, editable) → log → the log feeds tomorrow's readiness/recommendation.

**Three pillars** (most apps do one or two; Baseline integrates all three):
- **Engine** — energy systems (Zone-2 aerobic base, threshold, VO2).
- **Chassis** — joints, tendons, mobility, durability. The differentiator. On low-recovery days this is the *productive* answer (the "red-day pivot"), and there is a dedicated **base/durability phase** for athletes building tissue capacity before running volume.
- **Recovery** — the morning reading decides which pillar/dose runs today.

**Readiness score (composite, with a baseline ramp):**
- Inputs: HRV (chest-strap RMSSD vs. rolling baseline), resting HR, 7-day trend, **sleep (Apple Health)**, **prior-day training load**, and a quick subjective check (mood / energy / stress / soreness — soreness can capture body region to target the chassis pivot). Output: a **0–100 score mapped to a recovery band** → "how recovered you are + what to do today."
- **Cold-start:** for the first ~10–14 readings there is no reliable personal baseline — be conservative, lean on absolute values + age-population norms + the subjective check, and show "calibrating" bands. Do NOT be absolute against a baseline that doesn't exist yet.
- **Established:** once the 7-day rolling baseline is solid, score precisely against it. A good HRV day can still score low (stress / poor sleep / soreness) — the score is a composite, not raw HRV.

**Engine logic (reverse-engineered from elite HYROX coaching — see `docs/design.md`):**
- **Recovery bands:** ≥80% → intensity OK; 60–79% → aerobic / sub-threshold only (defer scheduled intensity later in the week); <60% → active recovery / chassis.
- **Dose layers (cumulative):** MED (Minimum Effective Dose, always) → +HPL (High Performance Layer, recovery strong) → +MDV (Maximum Daily Volume, advanced & very strong).
- **Hard scheduling constraints:** never two hard days in a row; a hard day is followed by aerobic or active recovery; batch intensity within the week.
- **Periodization metadata** lives on each authored session (type, microcycle role, the three doses). The recovery % picks the dose; the plan's structure constrains which dose is *wise* (e.g., a consolidation day between two hard days defaults to MED even on a green reading).
- **Subjective overrides:** high stress or high soreness can outrank a good HRV (recovered HRV + heavy DOMS → chassis / low-impact, not quality).
- **Automate the week:** Baseline surfaces *today's* session by applying these rules — automating the manual week-reordering a coach otherwise hands back to the athlete.

**Content is import-first; the session is the atomic unit** (full detail: `docs/engine-and-data-model.md`):
- **Vocabulary:** a **Routine** = a reusable, editable *template*; a **Session** = a dated *instance* the athlete actually does and logs; a **Plan/Week** = Routines assigned to days (what the engine reshuffles).
- **Primary path = import.** Most athletes get programming elsewhere (a coach, their own notes), so the main way workouts enter Baseline is **type or photograph a workout → translate to a native, loggable Routine** (workout- and exercise-level notes, title, tags), persisted and fully editable. Baseline's own authored program is deferred — not the v0 flagship.
- **The recovery engine applies in layers:** (A) imports that already carry dose structure (a coach's MED/HPL/MDV) → the morning score *picks the dose*; (B) classified imports (day-type: active-recovery / aerobic / intensity / strength) → do / sub-lighter / recover; (C) no plan → recommend from Baseline's built-in chassis/recovery/aerobic library. Import is **incremental** (day/week at a time), so the engine reasons over a rolling window, not a macrocycle.
- **Proposed but owned:** the engine *proposes* a session pre-filled; the athlete *owns* it — add / swap / reorder exercises and log actuals — during planning *and* mid-session.

**Exercise catalog:** base = **free-exercise-db** (public domain) + a **curated Baseline extension** (the 8 HYROX stations, common CrossFit movements, cardio modalities, and the mobility/chassis/warm-up library); content-driven (grows without app releases), create-custom supported. Unified schema with a per-exercise **logging type** — `repsLoad · reps · timeHold · distance · distanceLoad · calories · timeZone` (HYROX needs distance/load/calories, not just reps/load/time). **Cardio is one modality + a structured *intent*** (easy / threshold / intervals / long / race) so trends slice by intent without separate entries. A rich **alias map** is the key to import matching (RDL ≠ generic deadlift). Detail: `docs/engine-and-data-model.md`.

## Reading & Sensors
- **Chest-strap-first.** Connect a BLE Heart Rate Service (`0x180D`) strap (Polar H10 etc.), read **R-R intervals** (HR Measurement char `0x2A37`), artifact-correct, compute **RMSSD / lnRMSSD**. Wearable-via-HealthKit is the fallback; no-device → strongly recommend a strap. (Wrist optical is not sufficient for HRV — chest ECG is the standard.)
- **Morning reading:** a guided **2:30** read at **5s inhale / 5s exhale** resonance breathing (≈6 breaths/min) on a dark screen, with a live **R-R curve building across the screen** (bpm Y-axis, time-in-seconds X-axis), current HR + HRV shown live, and **averages at the end**. No "signal quality" copy. The read both standardizes the measurement and is itself a parasympathetic intervention.
- **One strap, two modes:** the morning HRV read *and* live in-session **HR-zone tracking** (kills the "stare at Polar Flow mid-workout" problem) — live zone per segment, per-segment zone history stored. Zones are computed by Baseline via **Heart-Rate-Reserve / Karvonen** from Health inputs (age + resting HR + observed max from workout history), with a Tanaka age-estimate fallback, refined over time, and **overridable** with a tested max HR or **LTHR zones (Friel)** for run training. (We compute from raw Health data, not by reading Apple's zone config.) See `docs/engine-and-data-model.md`.
- **Don't mix sources in a baseline** — build the rolling baseline from one source; switching sources recalibrates (re-enter cold-start).
- **Architecture:** sensor capture behind a service layer; the HRV computation is a **pure function (unit-testable without hardware)**; sensor callbacks run off-main and marshal UI updates back to main explicitly.

## Design System
- Dark, **"calm precision."** Tokens: base `#0C0A10`, surface `#1C1822`, amethyst (feature surface) `#33203E`, **accent violet `#9B6DFF`**, text `#F3F0F8` / `#9B94A8` / `#6A6478`, lines `#272231`.
- **Recovery zone colors (semantic):** blue `#4C8DFF`, green `#34D27B`, amber `#F5A623`, red `#FF5247`. The brand accent must stay *out* of these hue families so a control is never confused for a recovery state.
- Type: **Inter** (Regular / Medium / Semi Bold / Bold). Big display numbers for readiness / HR / HRV.
- Figma source of truth: https://www.figma.com/design/CCVlatyKW7MSHRGE3PK50i
- See `docs/design.md` for screens + rationale, `docs/engine-and-data-model.md` for engine / data-model / catalog detail, and `docs/v0-spec.md` for v0 scope + the build-order priority stack.

## Tech Stack
- **iOS 17+**, **Swift 6** strict concurrency, **SwiftUI**, `@Observable` (mark shared `@Observable` state `@MainActor`).
- **SwiftData** on-device (editing surface / source of truth for in-flight UX).
- **Firebase** (Auth, Firestore, Cloud Functions, Storage) for sync, content delivery, and the bounded LLM "why" narration.
- **RevenueCat** (subscriptions) + **SuperWall** (onboarding / paywall).
- **HealthKit** (recovery/workout reads, wearable fallback, baseline + HR-zone seeding). **CoreBluetooth** (chest strap; R-R pipeline validated on a Polar H10). **Apple Foundation Models** (on-device, `@Generable`) + **Vision** OCR for **text/photo → workout import** — free, on-device, private (native image input lands iOS 27); cloud **Claude API** is the fallback for hard parses and the bounded per-session "why" narration (structured, not open chat).
- **Content-driven:** programs, sessions, the exercise bank, and the chassis library are hosted/versioned content — *adding content must not require an app release.*

## Surfaces & Integrations
- **Apple Health (read-only) for history + context.** Import past workouts, sleep, resting HR, HRV history, and body metrics through a single read-only Health import facade — to (a) give recommendations real context on training load + recovery, and (b) **seed the baseline** from existing Health history so cold-start is short. Also the wearable fallback for the morning reading. Never write back to Health.
- **App Intents / Siri / Apple Intelligence for natural-language control.** Expose actions (start reading, start today's workout, create/add/log an exercise) and entities (Exercise, Session, Reading, Workout) via App Intents — so Siri, Spotlight, Shortcuts, the Action button, Apple Intelligence, and dictation tools can drive the app conversationally ("do I already have this exercise?", "what's my running history?"). **Design `Exercise` / `Session` / `Reading` to be App-Entity-friendly from day one;** implement the intents layer post-v0. Verify the latest WWDC 2026 App Intents / Siri APIs when building it.
- **Widgets / Live Activity (later):** a morning-readiness home-screen widget; a live in-session HR-zone Live Activity.

## Project tooling
- The Xcode project is **generated by XcodeGen** from `project.yml` (not committed — see `.gitignore`). After pulling or adding files: `xcodegen generate`. Source lives under `Baseline/` (feature-folder structure), tests under `BaselineTests/`.

---

# Engineering Principles
(ported from prior iOS work — apply to every change)

## Code structure
- **SRP** — each type does one thing. **DRY** — extract non-trivial patterns repeated 3+ times. **YAGNI** — build for what's needed now, not hypothetical flexibility.
- **Layering** — views render; view models hold UI state and orchestrate; services own side effects (network, persistence, sensors, system APIs); models persist data. A view calling the network directly is a smell.
- **DI over singletons** for testable business logic. Convenience singletons OK for global state (theme/settings), not for logic.
- **Content-driven over rebuild** — shell code accepts any instance of its content type; adding content (a program, an exercise, a chassis drill) should never mean shipping code.

## Testability
- **No business logic in SwiftUI view bodies** — decision-driving code must be reachable from a unit test without a view tree.
- **ViewModels do NOT import SwiftUI** (Foundation / Combine / Observation only).
- **Pure functions where possible** (the HRV / readiness math especially).

## Performance & rendering
- Render path stays cheap — no filter/reduce/sort over large arrays or SwiftData queries inside `body`. Cache derived state.
- Don't fight SwiftUI's diff — stable identities; avoid passing fresh closures / recreated objects into deep children.

## Code hygiene
- Clarity over cleverness. Delete before you defend (no dead code / commented experiments / "just in case"). Comments explain WHY, not WHAT. No leftover scaffolding from refactors.

# iOS Conventions
- iOS 17+, Swift 6, strict concurrency. If a newer iOS API meaningfully helps, mention it and gate with `@available` rather than silently raising the baseline.
- State: `@Observable` for shared state (`@MainActor`). `@Environment(Foo.self)` / `.environment(foo)`. `@State` for owned `@Observable`. plain `var foo: Foo` for passed-in observables; `@Bindable var foo` when `$foo.x` bindings are needed.
- Concurrency: `Task` / `Task.sleep(for:)` — no `DispatchQueue`. `deinit` can't touch `@MainActor` state → `nonisolated(unsafe)` if needed for cancellation. Blocking APIs off-main via `Task.detached` with a `Sendable` wrapper.
- No third-party frameworks without asking first. Avoid UIKit unless requested.
- Modern Swift idioms: `replacing("a", with:"b")`, `URL.documentsDirectory`, `url.appending(path:)`, `.formatted()` / `Text(_, format:)`, `localizedStandardContains()` for user-facing filtering.
- **Never commit API keys or secrets.**
- **SwiftData + CloudKit:** never `@Attribute(.unique)`; properties have defaults or are optional; all relationships optional.

# Specialized Skills (load before working in the domain)
`swiftui-pro`, `swift-concurrency-pro`, `swiftdata-pro`, `swift-testing-pro`, `vibe-security`, `firebase-basics`, `firebase-auth-basics`, `firebase-firestore-standard`, `healthkit`, `widgetkit`, `app-intents`, `ios-accessibility`, `ios-security`, `ios-networking`, `storekit`, `app-store-review`, `debugging-instruments`, `asc-xcode-build`, `asc-release-flow`, `asc-metadata-sync`, `asc-submission-health`, `asc-testflight-orchestration`, `product-design-playbook`. Also CoreBluetooth / sensor capture for the strap reading. If a task spans domains, use every matching skill.

# Firestore Schema-Change Rule
- Strict `hasOnly` + `hasAll` field validation on every collection. Adding/removing/renaming a field in the app **requires a matching `firestore.rules` update**. Deploy the same rules to all environments. Order: (1) update rules, (2) update Swift model + write logic, (3) deploy rules before/with the app.

# CI/CD & Deployment
- **Branches:** `main` (production-ready), `develop` (integration / default base), `feature/*` · `fix/*` · `chore/*` off `develop`.
- **Issue-first:** resolve work to a GitHub issue before coding; branch names include the issue number (`feature/issue-<n>-<slug>`); PRs target `develop` and include `Closes #<n>`.
- **CI:** GitHub Actions on PRs to `develop` — build + run the test suite on an iPhone simulator.
- **Distribution:** Fastlane lanes (build staging/prod, upload TestFlight); `match` for signing (CI in readonly); **OIDC + GCP Workload Identity Federation** for Firebase deploys — no long-lived JSON key secrets.

# Privacy & Compliance
- Keep `PrivacyInfo.xcprivacy`, the privacy policy, the App Store privacy questionnaire, and `NS*UsageDescription` strings in sync.
- Because Baseline prescribes training **intensity** (HR-zone work = cardiac risk): ship a **medical disclaimer** (not medical advice / assumption of risk / consult a physician / stop if symptoms), a **PAR-Q** screen at onboarding, and the **HYROX® trademark disclaimer** ("registered trademark of its owner; not affiliated with / endorsed by HYROX"). Get a lawyer to review the ToS.

---

This is the canonical project context for all AI providers (Claude, Codex, Cursor, etc.). `AGENTS.md` is a symlink to this file — edit one, edit both.
