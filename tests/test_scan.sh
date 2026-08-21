#!/usr/bin/env bash
# Tests for scan.sh: tricky filenames, protocol shape, sorting, and
# folder creation. Run from anywhere; needs only coreutils + bash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/scan.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; fails=1; }

# ---- fixture ----------------------------------------------------------------
MEDIA="$TMP/media folder"
mkdir -p "$MEDIA/sub dir"
printf 'x' > "$MEDIA/plain.jpg"
printf 'x' > "$MEDIA/a photo #1?.jpg"
printf 'x' > "$MEDIA/100%.png"
printf 'x' > "$MEDIA/  leading spaces  .gif"
printf 'x' > "$MEDIA/photo.jpg.icloud"
printf 'x' > "$MEDIA/sub dir/line
break.mp4"          # literal newline inside the filename
printf 'x' > "$MEDIA/not-media.txt"
printf 'x' > "$MEDIA/no-extension"

OUT="$("$SCAN" "$MEDIA")"
[[ -n "$OUT" ]] || fail "scan produced no output"

# ---- root record ------------------------------------------------------------
ROOT_REC="$(printf '%s\n' "$OUT" | sed -n '1p')"
case "$ROOT_REC" in
  "R "*)
    ROOT_DEC="$(printf '%s' "${ROOT_REC#R }" | base64 -d)"
    if [[ "$ROOT_DEC" == "$(realpath -m "$MEDIA")" ]]; then ok "root record decodes to canonical folder"; else fail "root record mismatch: '$ROOT_DEC'"; fi
    ;;
  *) fail "first line is not the root record: '$ROOT_REC'" ;;
esac

# ---- file records -----------------------------------------------------------
decode_files() {
  printf '%s\n' "$OUT" | grep '^F ' | sed 's/^F //' | while IFS= read -r b; do
    printf '%s\n' "$(printf '%s' "$b" | base64 -d)"
  done
}

FILES="$(decode_files)"
FILES_FILE="$TMP/files.txt"
printf '%s\n' "$FILES" > "$FILES_FILE"

# grep -q on a FILE (a pipe + -q + pipefail = SIGPIPE hazard)
has() { grep -F -x -q -- "$1" "$FILES_FILE"; }

has "$MEDIA/plain.jpg" && ok "plain.jpg listed" || fail "plain.jpg missing"
has "$MEDIA/a photo #1?.jpg" && ok "spaces/#/? filename listed" || fail "spaces/#/? filename missing"
has "$MEDIA/100%.png" && ok "percent filename listed" || fail "percent filename missing"
has "$MEDIA/  leading spaces  .gif" && ok "leading-space filename listed" || fail "leading-space filename missing"
if has "$MEDIA/photo.jpg.icloud"; then fail "icloud placeholder listed"; else ok ".icloud placeholder never matches a media extension"; fi
has "$MEDIA/sub dir/line
break.mp4" && ok "newline filename listed" || fail "newline filename missing"
if has "$MEDIA/not-media.txt"; then fail ".txt listed"; else ok ".txt excluded"; fi
if has "$MEDIA/no-extension"; then fail "extensionless file listed"; else ok "extensionless file excluded"; fi

# ---- sorting ----------------------------------------------------------------
FIRST="$(printf '%s\n' "$FILES" | head -1)"
if [[ "$FIRST" == "$MEDIA/  leading spaces  .gif" ]]; then ok "output is sorted"; else fail "unexpected first file: '$FIRST'"; fi

# ---- folder creation --------------------------------------------------------
NEW="$TMP/brand new folder"
OUT2="$("$SCAN" "$NEW")"
if [[ -d "$NEW" ]]; then ok "missing folder is created"; else fail "folder not created"; fi
if [[ "$(printf '%s\n' "$OUT2" | grep -c '^F ')" == "0" ]]; then ok "empty folder yields no file records"; else fail "unexpected file records in empty folder"; fi

# ---- protocol sanity --------------------------------------------------------
if printf '%s\n' "$OUT" | grep -qv '^[RF] '; then fail "record lines are not all R/F"; else ok "all records well-formed"; fi

# ---- exit status ------------------------------------------------------------
if "$SCAN" >/dev/null 2>&1; then fail "missing argument should fail"; else ok "missing argument fails"; fi

echo
if [[ "$fails" -eq 0 ]]; then echo "test_scan: ALL PASS"; else echo "test_scan: FAILURES"; exit 1; fi