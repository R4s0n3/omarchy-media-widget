#!/usr/bin/env bash
# Runs every test suite for the media widget. Exit 0 only if all pass.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run() {
  local desc="$1"
  shift
  echo "== $desc"
  "$@"
  echo
}

failed=0

run "QML model tests" bash -c 'QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input '"$DIR"'/tst_media.qml -o -,txt' || failed=1
run "scan.sh tests" "$DIR/test_scan.sh" || failed=1
run "sync_icloud.sh tests" "$DIR/test_icloud.sh" || failed=1

if [[ "$failed" -ne 0 ]]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
echo "ALL TEST SUITES PASSED"