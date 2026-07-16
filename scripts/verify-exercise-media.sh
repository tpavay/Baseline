#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <firebase-storage-bucket> <exercise-id> [exercise-id ...]" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bucket="$1"
shift
exercise_ids=("$@")
generated_root="$repo_root/.generated"
manifest="$repo_root/Baseline/Resources/ExerciseMedia/exercise-media-manifest.json"
expected_cache_control='public,max-age=31536000,immutable'

for command_name in jq gcloud openssl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

verified_count=0
for exercise_id in "${exercise_ids[@]}"; do
  status="$(jq -r --arg exercise_id "$exercise_id" '.exercises[$exercise_id].publicationStatus // "missing"' "$manifest")"
  if [[ "$status" != "ready" && "$status" != "published" ]]; then
    echo "$exercise_id must be ready or published; got $status" >&2
    exit 1
  fi

  while IFS= read -r storage_path; do
    local_path="$generated_root/$storage_path"
    if [[ ! -f "$local_path" ]]; then
      echo "Missing normalized asset for $exercise_id: $local_path" >&2
      exit 1
    fi

    metadata="$(CLOUDSDK_PYTHON_WARNINGS=ignore gcloud storage objects describe \
      "gs://$bucket/$storage_path" --format=json 2>/dev/null)"
    local_md5="$(openssl dgst -md5 -binary "$local_path" | openssl base64 -A)"
    local_size="$(stat -f '%z' "$local_path")"

    if ! jq -e \
      --arg path "$storage_path" \
      --arg md5 "$local_md5" \
      --arg cache_control "$expected_cache_control" \
      --argjson size "$local_size" \
      '.name == $path
       and .content_type == "image/png"
       and .cache_control == $cache_control
       and .md5_hash == $md5
       and .size == $size
       and .size < (5 * 1024 * 1024)' <<< "$metadata" >/dev/null; then
      echo "Remote verification failed: gs://$bucket/$storage_path" >&2
      exit 1
    fi

    ((verified_count += 1))
  done < <(jq -r --arg exercise_id "$exercise_id" \
    '.exercises[$exercise_id] | [.thumbnailPath, .detailPath][]' "$manifest")
done

echo "Verified $verified_count objects in gs://$bucket"
