#!/usr/bin/env bash
# Open the desktop's folder picker and print the chosen path on stdout.
# Exit code 1 means the user cancelled; exit code 2 means no picker is available.
set -euo pipefail

if command -v zenity >/dev/null 2>&1; then
  zenity --file-selection --directory --title="Pick a media folder" 2>/dev/null
  exit $?
fi

if command -v kdialog >/dev/null 2>&1; then
  kdialog --getexistingdirectory "$HOME" 2>/dev/null
  exit $?
fi

echo "No folder picker found (install zenity or kdialog)." >&2
exit 2