#!/bin/sh
set -eu

# Selects the per-environment GoogleService-Info plist for the active build
# configuration and copies it into the app bundle as GoogleService-Info.plist,
# so FirebaseApp.configure() loads the right backend (dev vs prod).
#
#   Debug   -> GoogleService-Info-Dev.plist         (baseline-app-dev)
#   Release -> GoogleService-Info-Production.plist   (baseline-app-prod)
#
# Source plists live in Baseline/App/Firebase/ and are gitignored.

FIREBASE_DIR="${SRCROOT}/Baseline/App/Firebase"

case "${CONFIGURATION}" in
  Debug)   ENV_PLIST="GoogleService-Info-Dev.plist" ;;
  Release) ENV_PLIST="GoogleService-Info-Production.plist" ;;
  *)
    echo "error: Unknown configuration '${CONFIGURATION}' — cannot pick a Firebase plist."
    exit 1
    ;;
esac

source_plist="${FIREBASE_DIR}/${ENV_PLIST}"
if [ ! -f "${source_plist}" ]; then
  cat <<MSG
error: Missing Firebase config for ${CONFIGURATION}: ${source_plist}
       Expected GoogleService-Info-Dev.plist (Debug) / GoogleService-Info-Production.plist (Release)
       in Baseline/App/Firebase/. These are gitignored — re-download from the Firebase console if absent.
MSG
  exit 1
fi

# Guard: the plist must match the target bundle id.
plist_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :BUNDLE_ID' "${source_plist}" 2>/dev/null || true)"
if [ "${plist_bundle_id}" != "${PRODUCT_BUNDLE_IDENTIFIER}" ]; then
  echo "error: Firebase plist bundle id (${plist_bundle_id}) != target (${PRODUCT_BUNDLE_IDENTIFIER}) — ${source_plist}"
  exit 1
fi

# Guard: the Google reversed client id must be a registered URL scheme.
if [ -n "${INFOPLIST_FILE:-}" ] && [ -f "${SRCROOT}/${INFOPLIST_FILE}" ]; then
  reversed_client_id="$(/usr/libexec/PlistBuddy -c 'Print :REVERSED_CLIENT_ID' "${source_plist}" 2>/dev/null || true)"
  if [ -n "${reversed_client_id}" ] && \
     ! /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "${SRCROOT}/${INFOPLIST_FILE}" 2>/dev/null | grep -Fq "${reversed_client_id}"; then
    echo "error: Google URL scheme ${reversed_client_id} is missing from ${INFOPLIST_FILE} CFBundleURLTypes."
    exit 1
  fi
fi

dest_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "${dest_dir}"
cp "${source_plist}" "${dest_dir}/GoogleService-Info.plist"
echo "Selected ${ENV_PLIST} -> GoogleService-Info.plist (${CONFIGURATION})"
