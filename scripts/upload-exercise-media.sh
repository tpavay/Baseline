#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <firebase-storage-bucket>" >&2
  echo "Example: $0 baseline-app-dev.firebasestorage.app" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bucket="$1"
generated_root="$repo_root/.generated"
manifest="$repo_root/Baseline/Resources/ExerciseMedia/exercise-media-manifest.json"

for command_name in jq gcloud; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

jq -r '.exercises | to_entries[] | select(.value.publicationStatus == "ready") | [.key, .value.thumbnailPath, .value.detailPath] | @tsv' "$manifest" |
while IFS=$'\t' read -r exercise_id thumbnail_path detail_path; do
  for storage_path in "$thumbnail_path" "$detail_path"; do
    local_path="$generated_root/$storage_path"
    if [[ ! -f "$local_path" ]]; then
      echo "Missing normalized asset for $exercise_id: $local_path" >&2
      exit 1
    fi

    gcloud storage cp \
      --cache-control='public,max-age=31536000,immutable' \
      --content-type='image/png' \
      "$local_path" "gs://$bucket/$storage_path"
  done
done

echo "Upload complete. Verify the objects, then promote their manifest statuses from ready to published."
