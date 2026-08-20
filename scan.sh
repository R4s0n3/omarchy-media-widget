#!/usr/bin/env bash
# List every media file under $1 (recursively) as a file:// URL, one per line.
set -euo pipefail

folder="$1"
exts=('*.jpg' '*.jpeg' '*.png' '*.gif' '*.webp' '*.bmp' '*.avif' '*.mp4' '*.mov' '*.m4v' '*.webm' '*.mkv' '*.avi')

if [[ ! -d "$folder" ]]; then
  exit 0
fi

args=()
for ext in "${exts[@]}"; do
  args+=(-o -iname "$ext")
done
args=("${args[@]:1}")

find "$folder" -type f \( "${args[@]}" \) -print0 2>/dev/null \
  | sort -z \
  | while IFS= read -r -d '' f; do printf 'file://%s\n' "$f"; done