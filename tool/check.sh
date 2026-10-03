#!/usr/bin/env bash
# One command for "is the app healthy?": analyze + unit tests.
# Usage: tool/check.sh [--quick]   (--quick skips tests)
set -euo pipefail

FLUTTER_BIN="${HERDR_FLUTTER_BIN:-/media/fatman/data/sdks/flutter/bin}"
[ -d "$FLUTTER_BIN" ] && export PATH="$FLUTTER_BIN:$PATH"

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
