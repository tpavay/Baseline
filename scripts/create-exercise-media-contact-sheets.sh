#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <exercise-id> [exercise-id ...]" >&2
  exit 1
fi

for command_name in jq magick; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generated_root="$repo_root/.generated"
output_dir="$repo_root/.generated/exercise-media-qa"
manifest="$repo_root/Baseline/Resources/ExerciseMedia/exercise-media-manifest.json"
exercise_ids=("$@")
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$output_dir"
tile_columns="${#exercise_ids[@]}"
if (( tile_columns > 5 )); then
  tile_columns=5
fi

font_path='/System/Library/Fonts/Supplemental/Arial.ttf'
if [[ ! -f "$font_path" ]]; then
  font_path='/System/Library/Fonts/SFNS.ttf'
fi
if [[ ! -f "$font_path" ]]; then
  echo "No supported system font found for QA sheet labels." >&2
  exit 1
fi

create_sheet() {
  local background="$1"
  local text_color="$2"
  local image_size="$3"
  local tile_width="$4"
  local tile_height="$5"
  local output_name="$6"
  local tiles=()
  local index=0

  for exercise_id in "${exercise_ids[@]}"; do
    thumbnail_path="$(jq -r --arg exercise_id "$exercise_id" \
      '.exercises[$exercise_id].thumbnailPath // empty' "$manifest")"
    if [[ -z "$thumbnail_path" ]]; then
      echo "Unknown exercise ID: $exercise_id" >&2
      exit 1
    fi
    source="$generated_root/$thumbnail_path"
    if [[ ! -f "$source" ]]; then
      echo "Missing thumbnail: $source" >&2
      exit 1
    fi

    tile="$temp_dir/${output_name}-${index}.png"
    magick -size "${tile_width}x${tile_height}" "xc:$background" \
      \( "$source" -resize "${image_size}x${image_size}" \) \
      -gravity north -geometry +0+8 -composite \
      -font "$font_path" -fill "$text_color" -pointsize 11 \
      -gravity south -annotate +0+8 "$exercise_id" \
      "$tile"
    tiles+=("$tile")
    ((index += 1))
  done

  magick montage "${tiles[@]}" -font "$font_path" -tile "${tile_columns}x" \
    -geometry +8+8 -background "$background" \
    "$output_dir/$output_name.png"
}

create_sheet '#0C0A10' '#F3F0F8' 150 180 190 thumbnails-dark
create_sheet '#F3F0F8' '#0C0A10' 150 180 190 thumbnails-light
create_sheet '#0C0A10' '#F3F0F8' 48 100 82 thumbnails-48pt

echo "Created QA sheets in ${output_dir#"$repo_root/"}"
