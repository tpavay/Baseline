# Firebase Backend & Auth Setup

Baseline uses **Firebase Auth + Firestore** with separate **dev** and **prod** projects, mirroring the Ascend setup. Sign-in is **Apple + Google** with a hard gate (must sign in before using the app).

## Environments

| Env  | Firebase project ID  | Project # | `.firebaserc` alias | Build config | Plist |
|------|----------------------|-----------|---------------------|--------------|-------|
| Dev  | `baseline-app-dev`   | 121306436388 | `dev` (default)  | **Debug**    | `GoogleService-Info-Dev.plist` |
| Prod | `baseline-app-prod`  | 1963302344   | `prod`           | **Release**  | `GoogleService-Info-Production.plist` |

- **iOS app (both projects):** bundle ID `com.tylerpavay.Baseline` (same ID across envs → one Apple Sign-In config).
- Console: https://console.firebase.google.com/ (signed in as pavayt@gmail.com).

## How environment selection works

- The two `GoogleService-Info-*.plist` files live in `Baseline/App/Firebase/` and are **gitignored** (not committed).
- They are **excluded** from the app bundle directly (see `project.yml` → `sources.excludes`).
- A build phase script, [`scripts/select-firebase-plist.sh`](../scripts/select-firebase-plist.sh), copies the right one to `GoogleService-Info.plist` in the built app based on `$CONFIGURATION` (Debug→Dev, Release→Prod). It also validates the plist's bundle ID and that its Google `REVERSED_CLIENT_ID` is registered as a URL scheme.
- Both envs' Google redirect URL schemes are listed in the generated `Baseline/Info.plist` (`CFBundleURLTypes`).
- `FirebaseApp.configure()` (in `BaselineApp.swift`) then loads whichever plist the script placed.

## What's already done (automated)

- ✅ Both Firebase projects created + iOS app registered in each.
- ✅ **Google** sign-in provider enabled and deployed (OAuth clients provisioned → plists have `CLIENT_ID`/`REVERSED_CLIENT_ID`).
- ✅ Firestore database created in each, with **locked rules** (`firestore.rules`, deny-all by default) deployed.
- ✅ App wired: SPM deps (firebase-ios-sdk, GoogleSignIn-iOS), `Baseline.entitlements` (Sign in with Apple), `AuthService` / `AuthViewModel` / `AuthView` + root gate.

## Manual steps still required (only you can do these)

1. **Apple Developer portal** (https://developer.apple.com/account → Identifiers):
   - Ensure App ID `com.tylerpavay.Baseline` exists and has the **Sign in with Apple** capability enabled.
   - Requires a paid Apple Developer membership.
2. **Set your Development Team** for device builds: edit `DEVELOPMENT_TEAM` in `project.yml` (then `xcodegen generate`) or set it in Xcode → Signing & Capabilities. (Simulator builds work without it.)
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

The plists are gitignored. To restore one: Firebase Console → Project settings → your iOS app → **GoogleService-Info.plist**, then save it as `Baseline/App/Firebase/GoogleService-Info-Dev.plist` (or `-Production.plist`).

## Firestore rules

Currently **deny-all** (no client collections yet). Per the project rule, each new model ships with its own strict `hasOnly` + `hasAll` per-collection rule, deployed before/with the app.
