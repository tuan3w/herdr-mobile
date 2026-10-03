#!/usr/bin/env bash
# Pane hot-path benchmark: history merge + ANSI parse + wrap + row prepare +
# layout/paint of a streaming 300-row, ~140 KB pane at phone size.
# Deterministic (seeded workload, no network). Prints METRIC lines.
set -euo pipefail

export PATH=/media/fatman/data/sdks/flutter/bin:$PATH
cd "$(dirname "$0")/app"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
export BENCH_OUT="$out"

flutter test benchmark/pane_bench.dart --no-pub >&2

grep -E '^METRIC ' "$out"
grep -q '^METRIC ' "$out"
