#!/usr/bin/env bash
# One command for "is the app healthy?": analyze + unit tests.
# Usage: tool/check.sh [--quick]   (--quick skips tests)
set -euo pipefail

# flutter from PATH; HERDR_FLUTTER_BIN=<sdk>/bin overrides.
if [ -n "${HERDR_FLUTTER_BIN:-}" ]; then export PATH="$HERDR_FLUTTER_BIN:$PATH"; fi

cd "$(dirname "$0")/../app"

echo "==> flutter pub get"
flutter pub get >/dev/null

echo "==> flutter analyze"
flutter analyze

if [ "${1:-}" != "--quick" ]; then
  # flutter test runs cores/2 files at once by default. Most of the suite
  # waits (real processes, timers, sockets) rather than computes, so cores/2
  # leaves the CPU idle: on 8 cores the whole run used ~3 of them. One file per
  # core keeps it busy. HERDR_TEST_JOBS overrides.
  jobs="${HERDR_TEST_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
  echo "==> flutter test"
  flutter test -j "$jobs"
fi
echo "OK"
