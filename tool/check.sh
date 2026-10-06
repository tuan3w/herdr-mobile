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
  echo "==> flutter test"
  flutter test
fi
echo "OK"
