#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <exercise-id> [exercise-id ...]" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/Baseline/Resources/ExerciseMedia/exercise-media-manifest.json"
exercise_ids=("$@")

if ! command -v jq >/dev/null 2>&1; then
  echo "Missing required command: jq" >&2
  exit 1
fi

for exercise_id in "${exercise_ids[@]}"; do
  status="$(jq -r --arg exercise_id "$exercise_id" '.exercises[$exercise_id].publicationStatus // "missing"' "$manifest")"
  if [[ "$status" != "ready" ]]; then
    echo "$exercise_id must have publicationStatus=ready; got $status" >&2
    exit 1
  fi
done

requested_ids="$(printf '%s\n' "${exercise_ids[@]}" | jq -R . | jq -s .)"
temporary_manifest="$(mktemp "${manifest}.XXXXXX")"
trap 'rm -f "$temporary_manifest"' EXIT

jq --argjson requested_ids "$requested_ids" \
  'reduce $requested_ids[] as $id (. ; .exercises[$id].publicationStatus = "published")' \
  "$manifest" > "$temporary_manifest"
mv "$temporary_manifest" "$manifest"

echo "Promoted ${#exercise_ids[@]} exercise media entries to published."
