#!/usr/bin/env bash
# One command for "is the app healthy?": analyze + unit tests.
# Usage: tool/check.sh [--quick]   (--quick skips tests)
set -euo pipefail

# A flutter whose Dart fits app/pubspec.yaml (tool/flutter-bin.sh picks it;
# HERDR_FLUTTER_BIN=<sdk>/bin forces one).
bin="$("$(dirname "$0")/flutter-bin.sh")"
export PATH="$bin:$PATH"

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
