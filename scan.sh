#!/usr/bin/env bash
# List every media file under $1 (recursively) as base64-encoded records, one
# per line:
#
#   R <base64 of canonical root walked>
#   F <base64 of a media file path>
#
# Base64 keeps filenames with spaces, hashes, percent signs, or even newlines
# intact across the line-based pipe. The QML side decodes the records and
# validates that every file stays below the canonical root.
#
# The folder is created first so scanning never races a folder that does not
# exist yet (the watcher retries on its own schedule).
set -euo pipefail

folder="$1"
exts=('*.jpg' '*.jpeg' '*.png' '*.gif' '*.webp' '*.bmp' '*.avif' '*.mp4' '*.mov' '*.m4v' '*.webm' '*.mkv' '*.avi')

if [[ ! -d "$folder" ]]; then
  mkdir -p "$folder" 2>/dev/null || exit 0
fi

# Canonicalize so the emitted paths (and the root record) match each other
# even when the configured folder goes through symlinks.
canon="$(realpath -m -- "$folder" 2>/dev/null || printf '%s' "$folder")"

args=()
for ext in "${exts[@]}"; do
  args+=(-o -iname "$ext")
done
args=("${args[@]:1}")

printf 'R %s\n' "$(printf '%s' "$canon" | base64 -w0 2>/dev/null)"

find "$canon" -type f \( "${args[@]}" \) -print0 2>/dev/null \
  | LC_ALL=C sort -z \
  | while IFS= read -r -d '' f; do
      printf 'F %s\n' "$(printf '%s' "$f" | base64 -w0 2>/dev/null)"
    done