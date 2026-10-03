#!/usr/bin/env bash
# Regenerates docs/screenshots/*.png: renders the demo fleet through the real
# widgets (real fonts, phone-sized surface, light and dark), then frames each
# render in a device mock-up with a headline.
#
# Needs Flutter on PATH and Pillow (`pip install pillow`).
set -euo pipefail
cd "$(dirname "$0")/../.."
RAW="${HERDR_RAW_DIR:-/tmp/herdr_raw}"
rm -rf "$RAW"
(cd app && HERDR_RAW_DIR="$RAW" flutter test screenshot_test/store_shots_test.dart)
python3 tool/screenshots/compose.py "$RAW" docs/screenshots
