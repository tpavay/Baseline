#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${1:-$HOME/Downloads}"
output_dir="${2:-$repo_root/.generated}"
manifest="$repo_root/Baseline/Resources/ExerciseMedia/exercise-media-manifest.json"

for command_name in jq magick; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

mkdir -p "$output_dir"

jq -r '.exercises | to_entries[] | [.key, .value.sourceFilename, .value.thumbnailPath, .value.detailPath] | @tsv' "$manifest" |
while IFS=$'\t' read -r exercise_id source_filename thumbnail_path detail_path; do
  source_path="$source_dir/$source_filename"
  thumbnail_output="$output_dir/$thumbnail_path"
  detail_output="$output_dir/$detail_path"

  if [[ ! -f "$source_path" ]]; then
    echo "Missing source for $exercise_id: $source_path" >&2
    exit 1
  fi

  source_metadata="$(magick identify -format '%w %h %[channels]' "$source_path")"
  read -r width height has_alpha <<< "$source_metadata"
  if [[ "$width" != "1024" || "$height" != "1024" || "$has_alpha" != *a* ]]; then
    echo "$source_filename must be a 1024x1024 image with alpha; got ${width}x${height} $has_alpha" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$thumbnail_output")" "$(dirname "$detail_output")"

  magick "$source_path" \
    -alpha on -trim +repage \
    -resize '880x880>' \
    -gravity center -background none -extent 1024x1024 \
    "$detail_output"

  magick "$source_path" \
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
