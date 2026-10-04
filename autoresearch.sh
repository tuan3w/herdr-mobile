#!/usr/bin/env bash
# Startup benchmark: the real bootApp over seeded preferences (6 machines with
# cached snapshots), mounted, until every machine's cached agents are on the
# Agents board. Virtual time: CPU is measured, plugin latencies (keychain) are
# modelled; see the header of app/benchmark/startup_bench.dart.
# Deterministic (seeded, no network). Prints METRIC lines.
#
# The pane benchmark (app/benchmark/pane_bench.dart) is the guard for pane
# regressions: BENCH_OUT=/tmp/x flutter test benchmark/pane_bench.dart
set -euo pipefail

export PATH=/media/fatman/data/sdks/flutter/bin:$PATH
cd "$(dirname "$0")/app"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
export BENCH_OUT="$out"

flutter test benchmark/startup_bench.dart --no-pub >&2

grep -E '^METRIC ' "$out"
grep -q '^METRIC ' "$out"
