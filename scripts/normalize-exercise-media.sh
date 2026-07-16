#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${1:-$HOME/Downloads}"
output_dir="${2:-$repo_root/.generated}"
manifest="$repo_root/Baseline/Resources/ExerciseMedia/exercise-media-manifest.json"
foreground_source="$repo_root/scripts/extract-exercise-media-foreground.swift"

if (( $# > 0 )); then shift; fi
if (( $# > 0 )); then shift; fi
exercise_ids=("$@")

for command_name in jq magick xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

mkdir -p "$output_dir"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
xcrun swiftc "$foreground_source" -o "$temp_dir/extract-foreground"

if (( ${#exercise_ids[@]} > 0 )); then
  requested_ids="$(printf '%s\n' "${exercise_ids[@]}" | jq -R . | jq -s .)"
  for exercise_id in "${exercise_ids[@]}"; do
    if ! jq -e --arg exercise_id "$exercise_id" '.exercises[$exercise_id] != null' "$manifest" >/dev/null; then
      echo "Unknown exercise ID: $exercise_id" >&2
      exit 1
    fi
  done
  manifest_filter='.exercises | to_entries[] | select(.key as $id | $requested_ids | index($id))'
else
  requested_ids='[]'
  manifest_filter='.exercises | to_entries[]'
fi

jq -r --argjson requested_ids "$requested_ids" \
  "$manifest_filter | [.key, .value.sourceFilename, .value.thumbnailPath, .value.detailPath] | @tsv" \
  "$manifest" |
while IFS=$'\t' read -r exercise_id source_filename thumbnail_path detail_path; do
  source_path="$source_dir/$source_filename"
  thumbnail_output="$output_dir/$thumbnail_path"
  detail_output="$output_dir/$detail_path"

  if [[ ! -f "$source_path" ]]; then
    echo "Missing source for $exercise_id: $source_path" >&2
    exit 1
  fi

  source_metadata="$(magick identify -format '%w %h %[channels]' "$source_path")"
  read -r width height channels <<< "$source_metadata"
  if [[ "$width" != "1024" || "$height" != "1024" ]]; then
    echo "$source_filename must be 1024x1024; got ${width}x${height}" >&2
    exit 1
  fi

  working_source="$source_path"
  if [[ "$channels" != *a* ]]; then
    working_source="$temp_dir/${exercise_id}.png"
    "$temp_dir/extract-foreground" "$source_path" "$working_source"
  fi

  normalized_channels="$(magick identify -format '%[channels]' "$working_source")"
  if [[ "$normalized_channels" != *a* ]]; then
    echo "Foreground extraction did not produce alpha for $source_filename" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$thumbnail_output")" "$(dirname "$detail_output")"

  magick "$working_source" \
    -alpha on -trim +repage \
    -resize '880x880>' \
    -gravity center -background none -extent 1024x1024 \
    "$detail_output"

  magick "$working_source" \
    -alpha on -trim +repage \
    -resize '430x430>' \
    -gravity center -background none -extent 512x512 \
    "$thumbnail_output"

  for output in "$detail_output" "$thumbnail_output"; do
    dimensions="$(magick identify -format '%wx%h' "$output")"
    corner_alpha="$(magick "$output" -alpha extract -format '%[fx:p{0,0}]' info:)"
    if [[ "$corner_alpha" != "0" && "$corner_alpha" != "0.0" ]]; then
      echo "Transparent-corner validation failed for $output: $corner_alpha" >&2
      exit 1
    fi
    echo "Created $dimensions ${output#"$repo_root/"}"
  done
done
