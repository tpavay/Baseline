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
- Inputs: HRV (chest-strap RMSSD), resting HR, trend, sleep, and a quick subjective check (mood / energy / stress / soreness).
- **Cold-start:** for the first ~10–14 readings there is no reliable personal baseline — be conservative, lean on absolute values + age-population norms + the subjective check, and show "calibrating" bands. Do NOT be absolute against a baseline that doesn't exist yet.
- **Established:** once the 7-day rolling baseline is solid, score precisely against it. A good HRV day can still score low (stress / poor sleep / soreness) — the score is a composite, not raw HRV.

**Engine logic (reverse-engineered from elite HYROX coaching — see `docs/design.md`):**
- **Recovery bands:** ≥80% → intensity OK; 60–79% → aerobic / sub-threshold only (defer scheduled intensity later in the week); <60% → active recovery / chassis.
- **Dose layers (cumulative):** MED (Minimum Effective Dose, always) → +HPL (High Performance Layer, recovery strong) → +MDV (Maximum Daily Volume, advanced & very strong).
- **Hard scheduling constraints:** never two hard days in a row; a hard day is followed by aerobic or active recovery; batch intensity within the week.
- **Periodization metadata** lives on each authored session (type, microcycle role, the three doses). The recovery % picks the dose; the plan's structure constrains which dose is *wise* (e.g., a consolidation day between two hard days defaults to MED even on a green reading).
- **Subjective overrides:** high stress or high soreness can outrank a good HRV (recovered HRV + heavy DOMS → chassis / low-impact, not quality).
- **Automate the week:** Baseline surfaces *today's* session by applying these rules — automating the manual week-reordering a coach otherwise hands back to the athlete.

**Programs are source-agnostic; the session is the atomic unit:**
- A **session** = an ordered, *editable* list of exercises (each: target sets / reps / load / time / zone + a "why"). A **program** = an ordered set of sessions.
- Sources: (1) **Baseline's authored HYROX program** — flagship; we own the dose/zone metadata so the recovery engine fully modulates it. (2) **Coach-administered** (e.g., FITR) — can't integrate directly; support as logging + a recovery-guidance overlay + chassis recommendations. (3) **Own notes.** (4) **Imported logs.** Full modulation on our program; graceful "log + overlay" for the rest. Start with our program.
- **Proposed but owned:** the engine *proposes* the session pre-filled; the athlete *owns* it — add exercises (from the bank or custom), reorder, swap, and log actuals (reps / load / **time / holds**).

**Exercise bank:** a tagged, content-driven library (engine / chassis / strength / station / mobility), with the ability to create custom exercises. Logging supports reps, load, time, and isometric holds.

## Reading & Sensors
- **Chest-strap-first.** Connect a BLE Heart Rate Service (`0x180D`) strap (Polar H10 etc.), read **R-R intervals** (HR Measurement char `0x2A37`), artifact-correct, compute **RMSSD / lnRMSSD**. Wearable-via-HealthKit is the fallback; no-device → strongly recommend a strap. (Wrist optical is not sufficient for HRV — chest ECG is the standard.)
- **Morning reading:** a guided **2:30** read at **5s inhale / 5s exhale** resonance breathing (≈6 breaths/min) on a dark screen, with a live **R-R curve building across the screen** (bpm Y-axis, time-in-seconds X-axis), current HR + HRV shown live, and **averages at the end**. No "signal quality" copy. The read both standardizes the measurement and is itself a parasympathetic intervention.
- One strap connection serves two modes: the morning HRV read, and live in-session HR-zone tracking.
- **Don't mix sources in a baseline** — build the rolling baseline from one source; switching sources recalibrates (re-enter cold-start).
- **Architecture:** sensor capture behind a service layer; the HRV computation is a **pure function (unit-testable without hardware)**; sensor callbacks run off-main and marshal UI updates back to main explicitly.

## Design System
- Dark, **"calm precision."** Tokens: base `#0C0A10`, surface `#1C1822`, amethyst (feature surface) `#33203E`, **accent violet `#9B6DFF`**, text `#F3F0F8` / `#9B94A8` / `#6A6478`, lines `#272231`.
- **Recovery zone colors (semantic):** blue `#4C8DFF`, green `#34D27B`, amber `#F5A623`, red `#FF5247`. The brand accent must stay *out* of these hue families so a control is never confused for a recovery state.
- Type: **Inter** (Regular / Medium / Semi Bold / Bold). Big display numbers for readiness / HR / HRV.
- Figma source of truth: https://www.figma.com/design/CCVlatyKW7MSHRGE3PK50i
- See `docs/design.md` for screens (home states, reading flow, day recommendations) and rationale.

## Tech Stack
- **iOS 17+**, **Swift 6** strict concurrency, **SwiftUI**, `@Observable` (mark shared `@Observable` state `@MainActor`).
- **SwiftData** on-device (editing surface / source of truth for in-flight UX).
- **Firebase** (Auth, Firestore, Cloud Functions, Storage) for sync, content delivery, and the bounded LLM "why" narration.
- **RevenueCat** (subscriptions) + **SuperWall** (onboarding / paywall).
- **HealthKit** (recovery/workout reads, wearable fallback). **CoreBluetooth** (chest strap). **Claude API** via a Cloud Function for per-session "why" generation (bounded, structured — NOT open-ended chat).
- **Content-driven:** programs, sessions, the exercise bank, and the chassis library are hosted/versioned content — *adding content must not require an app release.*

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
