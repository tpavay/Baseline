# Baseline — Project Guide

## What Baseline Is
Baseline is an **AI-first adaptive training system** for iOS.
It helps people decide what to train, create and manage plans and workouts, execute and log their training, understand their history, and continuously adapt future training toward their goals.

AI is the primary interface and orchestration layer.
A user should be able to create, import, revise, schedule, execute, and log training through natural conversation with minimal friction.
The resulting plans, workouts, and logs remain structured, editable, and accessible through direct controls as well as conversation.

Baseline builds an evolving understanding of the user from their goals, preferences, constraints, training history, completed work, and explicit feedback, plus any information sources they choose to connect.
Apple Health, sleep, HRV, heart-rate monitors, and future integrations can improve its decisions, but no device, recovery signal, or data source is required.

Baseline is not tied to a sport or training style.
It can support strength, endurance, running, bodybuilding, functional fitness, mobility, HYROX, hybrid training, and other forms of exercise.
HYROX and recovery-aware training are supported use cases, not the product's identity.

**The core loop:** understand → plan → decide → train → log → learn → adapt.

**The job it does:** remove the friction and uncertainty between a person's goals and their next training action, while making the entire training system easy to create, change, follow, and learn from.

**Solo dev + AI assisted** (Tyler Pavay). Build-for-self first. Planned monetization: subscription (the recurring daily coach), via RevenueCat + SuperWall.

## What Baseline Is NOT (define the niche by exclusion)
- **Not tied to one sport, modality, training style, or goal.** Baseline supports specialized use cases without allowing any one of them to define the product.
- **Not a passive fitness tracker or readiness score.** Data matters when it improves a decision, plan, workout, explanation, or future adaptation.
- **Not a static plan.** Plans and workouts are living, versioned, editable objects that can adapt as the user's goals, context, and training change.
- **Not a generic logger.** Logging captures what actually happened so Baseline can explain progress, update its understanding, and improve future decisions.
- **Not an AI chat wrapper around unstructured data.** Conversation is the primary interface, but structured state is the source of truth and AI actions operate through validated domain tools.
- **Not dependent on wearables, HRV, or any single data source.** Baseline works with what the user chooses to provide and becomes more informed as optional sources are connected.
- **Not an autonomous black box.** Baseline proposes and explains; the user owns the plan and can inspect, edit, accept, or reject changes.

## Core Product Model
**The product loop:** understand → plan → decide → train → log → learn → adapt.

**Optional evidence stays optional.**
Health data, sleep, HRV, check-ins, connected devices, and future signals may improve Baseline's decisions but are never prerequisites.
If a user declines or disables a source, it stays out of the primary experience unless the user chooses to enable it again.
Baseline uses the available evidence and communicates meaningful uncertainty without treating an unavailable optional input as an error.

**Ask only when the answer could change the plan.**
Infer from known context and connected sources first.
If a material unknown or stale constraint could change the training decision, ask the smallest targeted question.
Never ask merely to complete a score or collect data that would not affect the recommendation.

**Question preferences are durable.**
A request such as "don't ask me about sleep again" becomes a structured, persistent preference that the user can change through conversation or settings.
A suppressed signal remains unknown and must never be silently inferred.
If a suppressed question is safety-critical, Baseline takes a conservative path and explains the limitation rather than assuming the user is safe to proceed.

**Preserve intent, adapt dose.**
When context warrants a change, preserve the session's intended adaptation where possible and adjust the fewest relevant training levers.
The relevant levers and substitutions depend on the training domain and belong in domain-specific planning policies rather than one universal recovery rule.

**Plan-aware recommendations.**
Baseline considers the user's goals, current plan and phase, scheduled work, recent completed training, active constraints, explicit context, and any optional evidence they provide.
It does not optimize one day in isolation or apply one training domain's rules universally.

**Evidence supports decisions, not scores.**
Baseline may derive internal, explainable measures from configured evidence when useful, but no global or user-facing readiness score is required.
The user-facing output is a specific training recommendation with the material reasons, constraints, and meaningful uncertainty behind it.
AI never invents input values, derived metrics, or certainty.

**Training logic is domain-specific.**
Every session has an intended training effect and relevant adaptation levers.
The appropriate levers, constraints, and substitutions depend on the training domain, plan, and individual rather than universal recovery bands or one sport's programming rules.

**The user's current condition matters.**
Explicit reports of pain, illness, unusual fatigue, or changed circumstances can constrain a recommendation even when passive data looks favorable.

**Training is structured, editable, and modality-agnostic.**
Baseline represents training using exercises, Workout Templates, Sessions, and Plans rather than leaving it as unstructured conversation.
A **Workout Template** is reusable training content that is not tied to a date.
A **Session** is a scheduled or completed occurrence containing both the intended training and what the user actually performed.
A **Plan** organizes sessions toward one or more goals over time and can evolve as the user's circumstances and training change.
The Session is the core unit for scheduling, execution, logging, and adaptation.

**Creation and import are first-class paths.**
Users can describe, paste, photograph, import, or manually assemble training.
Every path resolves into the same validated, native training models.
Baseline surfaces ambiguity instead of inventing missing details, and all resulting content remains editable through conversation and direct controls.

**The user owns the result.**
Baseline can propose and apply changes, but those changes remain inspectable, editable, and reversible before, during, and after training.

**The exercise system is extensible.**
Exercises and their logging requirements must support different modalities without encoding one sport's assumptions.
The built-in catalog can evolve without an app release, and users can create custom exercises.
Implementation details for the catalog, logging schemas, aliases, and import matching live in `docs/engine-and-data-model.md`.

## Product Experience
Baseline should feel calm, precise, conversational, and low-friction.
Lead with the user's next training action and make it easy to understand or change.
Metrics, evidence, and technical detail support the recommendation rather than becoming the primary experience.

Use centralized design tokens and reusable components rather than hard-coded visual values.
For UI work, inspect the [Figma file](https://www.figma.com/design/CCVlatyKW7MSHRGE3PK50i) and `docs/design-system/` before designing or implementing an interface.
Use the `lavish` skill and Lavish AXI to create reviewable interactive prototypes for new screens, flows, or material visual changes when the direction is not already established.
Lavish prototypes must use Baseline's design system rather than fallback styling.

When a visual artifact conflicts with the product principles in this guide, the product principles take precedence until the artifact is updated.
Detailed tokens, typography, components, and visual patterns belong in the design-system documentation and Figma rather than this always-loaded guide.

## Technical Baseline
- **Platform:** iOS 17+, Swift 6 with complete strict concurrency, SwiftUI, and Observation.
- **Persistence:** SwiftData for on-device persistence. Keep domain models and decision logic independent of SwiftUI and SwiftData, and access persistence through repository boundaries.
- **Backend:** Firebase Auth, Firestore, Cloud Functions, Storage, and App Check. Keep privileged operations and provider credentials on the server.
- **AI architecture:** AI requests cross a provider boundary and act through validated domain tools. Structured application state remains the source of truth. Anthropic is the current server-side provider, not a permanent architectural dependency.
- **Apple frameworks:** HealthKit, CoreBluetooth, Vision, and other system frameworks are optional feature integrations. Load the relevant skills and technical documentation when working in those domains.
- **Dependencies:** Do not add or replace third-party dependencies without Tyler's approval. `project.yml` is the canonical dependency and target configuration.

## System Surfaces
- Model Baseline's capabilities as reusable, validated domain actions and entities.
- In-app AI, direct controls, App Intents, Siri, Shortcuts, Spotlight, widgets, and future interfaces must reuse the same domain services and tool contracts rather than implementing separate business logic.
- System integrations are optional adapters. Baseline's core training system must remain usable without them.
- Health data access follows least privilege. Reads and any future writes must be explicitly authorized, consistent with user intent, provenance-preserving, and resistant to duplicate imports or writes.
- Surface adapters must not invent unavailable data or make external frameworks the source of truth.
- Load the relevant specialized skill and verify current platform APIs before implementing an integration.

## Project Tooling
- `project.yml` is the committed, canonical XcodeGen specification for targets, dependencies, build settings, and generated Info.plist values.
- `Baseline.xcodeproj` and `Baseline/Info.plist` are generated and ignored. Never edit or commit them directly.
- Run `xcodegen generate` after pulling changes or modifying project configuration, dependencies, resources, or source membership.
- Application source lives under `Baseline/`, organized primarily by feature. Tests live under `BaselineTests/`.
- A fresh clone or worktree cannot build until `Baseline/App/Firebase/GoogleService-Info-Dev.plist` (Debug) and `-Production.plist` (Release) are present.
  They are gitignored secrets, so copy them from an existing checkout or re-download them from the Firebase console; the whole `Firebase/` directory is absent until you do.
- The Cloud Functions in `functions/` need `npm ci` before `npm run build` (tsc) or `npm test`.
  Without it, tsc reports dozens of missing-type errors in files you did not touch. There is no lint script; `npm run build` is the type gate.
- Sign-in gates the app at launch, so a plain simulator run reaches the auth screen and no further; there is no bypass.
  To look at a screen, host it in an app-hosted test: attach a `UIWindow` to the window scene from `UIApplication.shared.connectedScenes`, give it a `UIHostingController` root, then `drawHierarchy` into a `UIGraphicsImageRenderer`.
  An unattached window renders blank, and `ImageRenderer` is not a substitute: it cannot rasterize `ScrollView` content or `TextField`.

---

# Engineering Principles

## Boundaries
- Views render state and forward user intent.
- Presentation models hold UI state and invoke domain capabilities.
  They do not contain business rules or import SwiftUI.
- Domain models, policies, and engines own business meaning and decision logic.
- Repositories and service adapters own persistence, networking, sensors, and system-framework interaction.
- Domain logic must remain independent of SwiftUI, SwiftData, Firebase, HealthKit, and other infrastructure frameworks.

## Design
- Prefer small, cohesive types with clear ownership and one primary responsibility.
- Use dependency injection for business logic and side effects.
  Do not hide business behavior behind global singletons.
- Build the smallest clear solution that satisfies the current requirement.
- Remove duplication when a stable shared abstraction is evident.
  Do not create speculative flexibility.

## Testability
- Make decision rules, calculations, parsing, validation, and state transitions pure and deterministic where practical.
- New behavior and bug fixes require automated tests proportionate to their risk.
- Tests should exercise behavior without a view tree, network, database, or hardware whenever those dependencies can be replaced at a boundary.

## Performance
- SwiftUI render paths must remain side-effect-free and inexpensive.
- Compute, cache, or persist expensive derived state outside `body`.
- Use stable identities for collections and long-lived state.

## Code Hygiene
- Prefer clarity over cleverness.
- Remove dead code, commented experiments, obsolete compatibility paths, and refactoring scaffolding.
- Comments explain decisions, constraints, and non-obvious tradeoffs rather than restating the code.

# iOS Platform Rules
- Do not raise the iOS 17 deployment target without Tyler's approval.
- Gate newer APIs with availability checks and preserve a supported iOS 17 path.
- Prefer SwiftUI, Observation, and structured concurrency for application code.
- Use UIKit, dispatch queues, unsafe sendability, or other lower-level mechanisms when required by a system framework or when they provide a clear quality benefit.
- Isolate those mechanisms behind a narrow boundary and document the invariant that makes them safe.
- Treat Swift 6 concurrency diagnostics as correctness issues.
- Do not silence isolation or sendability errors without understanding, documenting, and testing the underlying ownership model.
- Never commit credentials, API keys, signing material, production tokens, or unredacted sensitive user data.

# Skills And Progressive Disclosure
- Keep this guide limited to context and rules that apply broadly across the project.
- Put conditional domain knowledge, implementation guidance, and repeatable workflows in Agent Skills.
- Store project-specific skills under `.agents/skills/` so supported agent harnesses discover the same canonical skill.
- Create and update skills using `skill-creator`.
- Give every skill a precise description that states when it should and should not load.
- When a task matches an installed skill, load and follow it before acting.
- If a task spans multiple domains, use every skill materially required for the work.
- Do not maintain a manual registry of installed skills in this guide.
  Installed skill metadata is the discovery source.
- If a referenced skill is unavailable in the active harness, say so rather than pretending to have loaded it.

# Firestore Schema-Change Rule
- Strict `hasOnly` + `hasAll` field validation on every collection. Adding/removing/renaming a field in the app **requires a matching `firestore.rules` update**. Deploy the same rules to all environments. Order: (1) update rules, (2) update Swift model + write logic, (3) deploy rules before/with the app.

# CI/CD & Deployment
- **Branches:** `main` (production-ready), `develop` (integration / default base), `feature/*` · `fix/*` · `chore/*` off `develop`.
- **Issue-first:** resolve work to a GitHub issue before coding; branch names include the issue number (`feature/issue-<n>-<slug>`); PRs target `develop` and include `Closes #<n>`.
- **CI:** GitHub Actions on PRs to `develop` — build + run the test suite on an iPhone simulator.
- **Distribution:** `.github/workflows/deploy-staging.yml` is the staging tier — push to `develop` builds the IPA (Fastlane `build_staging`), deploys Firebase to `baseline-app-staging`, and uploads to TestFlight (`upload_testflight`). Staging uses bundle id `com.tylerpavay.Baseline.staging` via the `Staging` build config in `project.yml`. `match` for signing (CI readonly) **reuses Ascend's `ascend-match-signing` repo** — Baseline shares Apple team `QWGVB7TN4T`, so the ASC API key and match repo are shared. Firebase deploys authenticate via `FIREBASE_TOKEN` (mirrors Ascend); OIDC + GCP Workload Identity Federation remains the intended future hardening. Prod tier is not built yet.

# Privacy & Compliance
- Keep `PrivacyInfo.xcprivacy`, the privacy policy, the App Store privacy questionnaire, and `NS*UsageDescription` strings in sync.
- Because Baseline prescribes training **intensity**: keep risk language lightweight but present — an assumption-of-risk / not-medical-advice clause lives in the ToS, accepted via a one-line footnote at the onboarding commitment step, plus a contextual "training guidance, not medical advice — stop if you feel unwell" line on prescription surfaces. **No standalone disclaimer screen and no PAR-Q** (decided 2026-07: cut for onboarding friction). Keep the **HYROX® trademark disclaimer** ("registered trademark of its owner; not affiliated with / endorsed by HYROX"). Get a lawyer to review the ToS.

---

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

---

This is the canonical project context for all AI providers (Claude, Codex, Cursor, etc.). `AGENTS.md` is a symlink to this file — edit one, edit both.
