# Firebase Backend & Auth Setup

Baseline uses **Firebase Auth + Firestore** with separate **dev**, **staging**, and **prod** projects, mirroring the Ascend setup. Sign-in is **Apple + Google** with a hard gate (must sign in before using the app).

## Environments

| Env  | Firebase project ID  | Project # | `.firebaserc` alias | Build config | Plist |
|------|----------------------|-----------|---------------------|--------------|-------|
| Dev  | `baseline-app-dev`   | 121306436388 | `dev` (default)  | **Debug**    | `GoogleService-Info-Dev.plist` |
| Staging | `baseline-app-staging` | 773651861110 | `staging`      | **Staging**  | `GoogleService-Info-Staging.plist` |
| Prod | `baseline-app-prod`  | 1963302344   | `prod`           | **Release**  | `GoogleService-Info-Production.plist` |

- **iOS app (dev + prod):** bundle ID `com.tylerpavay.Baseline` (same ID across those two envs → one Apple Sign-In config). **Staging** overrides the bundle id to `com.tylerpavay.Baseline.staging` (via the `Staging` config in `project.yml`) so it installs alongside a future prod build and gets its own App Store Connect record + `match` profile.
- **Staging is the CI/CD tier.** The `staging` alias, `Staging` build config, and plist-selection branch are in place, the `baseline-app-staging` Firebase iOS app is registered with its OAuth client, and its real `REVERSED_CLIENT_ID` is wired into `project.yml`'s `CFBundleURLTypes`, so the Staging build's URL-scheme guard passes. See the staging pipeline in `.github/workflows/deploy-staging.yml` and the CI/CD notes in `CLAUDE.md`.
- Console: https://console.firebase.google.com/ (signed in as pavayt@gmail.com).

## How environment selection works

- The `GoogleService-Info-*.plist` files live in `Baseline/App/Firebase/` and are **gitignored** (not committed).
- They are **excluded** from the app bundle directly (see `project.yml` → `sources.excludes`).
- A build phase script, [`scripts/select-firebase-plist.sh`](../scripts/select-firebase-plist.sh), copies the right one to `GoogleService-Info.plist` in the built app based on `$CONFIGURATION` (Debug→Dev, Staging→Staging, Release→Prod). It also validates the plist's bundle ID and that its Google `REVERSED_CLIENT_ID` is registered as a URL scheme.
- All three envs' Google redirect URL schemes (dev/staging/prod) are declared in `project.yml` and listed in the generated `Baseline/Info.plist` (`CFBundleURLTypes`).
- `FirebaseApp.configure()` (in `BaselineApp.swift`) then loads whichever plist the script placed.

## What's already done (automated)

- ✅ All three Firebase projects created + iOS app registered in each.
- ✅ **Google** sign-in provider enabled and deployed (OAuth clients provisioned → plists have `CLIENT_ID`/`REVERSED_CLIENT_ID`).
- ✅ Firestore database created in each, with **locked rules** (`firestore.rules`, deny-all by default) deployed.
- ✅ App wired: SPM deps (firebase-ios-sdk, GoogleSignIn-iOS), `Baseline.entitlements` (Sign in with Apple), `AuthService` / `AuthViewModel` / `AuthView` + root gate.

## Manual steps still required (only you can do these)

1. **Apple Developer portal** (https://developer.apple.com/account → Identifiers):
   - Ensure App ID `com.tylerpavay.Baseline` exists and has the **Sign in with Apple** capability enabled.
   - Requires a paid Apple Developer membership.
2. **Development Team for device builds:** `DEVELOPMENT_TEAM` is configured in `project.yml` and must remain there because XcodeGen regenerates the Xcode project.
   Do not treat a change made only in Xcode's Signing & Capabilities editor as persistent.
3. **Firebase Console → Authentication → Sign-in method → enable Apple** in **both** projects (`baseline-app-dev` and `baseline-app-prod`). Apple is **not** configurable via the CLI/MCP, so this is a manual toggle. For a native iOS-only app you can enable it without a Services ID / key.
4. (Optional) Confirm **Google** shows as enabled under the same Sign-in method screen.

Until step 3 is done, Apple sign-in will fail at the Firebase exchange; Google sign-in works now.

## Common commands

```sh
xcodegen generate                       # after pulling or adding files

# Deploy Firestore rules to an env (uses .firebaserc aliases):
firebase deploy --only firestore --project dev
firebase deploy --only firestore --project prod
```

## Re-downloading a lost plist

The plists are gitignored. To restore one: Firebase Console → Project settings → your iOS app → **GoogleService-Info.plist**, then save it as `Baseline/App/Firebase/GoogleService-Info-Dev.plist` (or `-Staging.plist` / `-Production.plist`).

## Cloud Functions secrets (LLM observability)

The chat and workout-import functions, including the streaming `streamWorkoutImport` endpoint, read Langfuse credentials only through Firebase `defineSecret` bindings; the keys never reach iOS.
Until these three secrets exist, any deploy that includes those functions fails, so set them per environment before deploying.

Set them with `firebase functions:secrets:set` (it prompts for the value interactively - never pass a key on the command line and never commit one):

```sh
# Dev project (baseline-app-dev)
firebase functions:secrets:set LANGFUSE_SECRET_KEY --project dev   # paste the Langfuse secret key when prompted
firebase functions:secrets:set LANGFUSE_PUBLIC_KEY --project dev   # paste the Langfuse public key when prompted
firebase functions:secrets:set LANGFUSE_BASE_URL --project dev     # plain config, not sensitive: https://us.cloud.langfuse.com
```

Repeat each command with `--project prod` for `baseline-app-prod`.

- `LANGFUSE_SECRET_KEY` / `LANGFUSE_PUBLIC_KEY` come from the Langfuse project settings and are sensitive - they stay server-side only.
- `LANGFUSE_BASE_URL` is plain configuration and defaults to `https://us.cloud.langfuse.com` (use the EU host only if the Langfuse project is EU-hosted).
- Tracing is fully fail-open: if the secrets are unset or Langfuse is unreachable, the functions still run normally and no telemetry failure changes app behavior.
- Optional per-environment sampling knob: set the `LLM_OBSERVABILITY_SAMPLE_RATE` env var (0-1) to sample telemetry; unset defaults to full tracing.

## Firestore rules

Currently **deny-all** (no client collections yet). Per the project rule, each new model ships with its own strict `hasOnly` + `hasAll` per-collection rule, deployed before/with the app.
