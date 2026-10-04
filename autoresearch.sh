#!/usr/bin/env bash
# Transfer benchmark: the real transport stack (IsolateTransport -> dartssh2 ->
# remote mux -> unix socket) against a deterministic fake herdr
# (app/benchmark/fake_herdr.py), over SSH to this machine's own sshd. Snapshot
# refreshes, 300-row pane reads and 24-row preview reads through HerdrApi.
# Prints METRIC lines: transfer_ms (client CPU + wire bytes at a modelled
# 1.25 MB/s link), wire_kb, cpu_ms, wall_ms, and the same per workload.
#
# The startup benchmark (app/benchmark/startup_bench.dart) and the pane
# benchmark (app/benchmark/pane_bench.dart) guard the other hot paths:
#   BENCH_OUT=/tmp/x flutter test benchmark/startup_bench.dart
set -euo pipefail

export PATH=/media/fatman/data/sdks/flutter/bin:$PATH
cd "$(dirname "$0")/app"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
export BENCH_OUT="$out"

flutter test benchmark/transfer_bench.dart --no-pub >&2

grep -E '^METRIC ' "$out"
grep -q '^METRIC ' "$out"
