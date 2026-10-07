#!/usr/bin/env bash
# What watching agents costs the radio and the battery, deterministic, no phone
# (app/benchmark/background_bench_test.dart). The real fleet, connection, SSH
# transport, mux and notifier run over an in-memory SSH link and herdr on a
# virtual clock, and every message that would cross the radio is metered. The
# header of the bench says what is modelled (radio tail, packet overhead,
# round trip) and what is real.
#
#   bg_score_s_per_h       THE number (lower is better): radio-seconds per hour of
#                          the turbulent 2 h watch, plus an hour of radio for
#                          every share of the time a reachable machine was not
#                          watched and every share of the blocked agents that
#                          were never announced
#   bg_*, steady_*         the same run's parts: radio_cost_s_per_h,
#                          radio_active_s_per_h, wakeups_per_h, wire_kb_per_h,
#                          packets_per_h, timer_fires_per_h, unwatched_frac,
#                          attention_{episodes,missed,latency_p95_s,latency_max_s}
#                          (`steady_` = 1 h with nothing going wrong)
#   fg_*                   the board in front: kb and packets per minute
#   resume_*, cold_resume_*  back in front after a watch / after the 90 s
#                          suspension: ms until the board is true, kb
#   suspended_*, leave_*   notifications off: what is still sent after the
#                          grace period (should be 0), what leaving costs
#
# Lines starting with `#` say which timers of the app woke the CPU most.
# BENCH_TRACE=1 prints a line per 5 virtual minutes (link states, event
# subscriptions, wire counts). Needs Flutter >= 3.47 (HERDR_FLUTTER_BIN is
# the SDK's bin directory); a run takes about 10 s.
set -euo pipefail

bin="$("$(dirname "$0")/tool/flutter-bin.sh")"
export PATH="$bin:$PATH"

cd "$(dirname "$0")/app"
out="$(mktemp -t herdr-bg-bench.XXXXXX)"
trap 'rm -f "$out"' EXIT

# pub get also rewrites ios/ files, so only when the packages are not there.
if [ ! -f .dart_tool/package_config.json ] || [ pubspec.yaml -nt .dart_tool/package_config.json ]; then
  flutter pub get >/dev/null
  git checkout -- ios/Flutter 2>/dev/null || true
fi
if ! BENCH_OUT="$out" flutter test --no-pub benchmark/background_bench_test.dart >"$out.log" 2>&1; then
  tail -40 "$out.log" >&2
  rm -f "$out.log"
  echo "background bench failed" >&2
  exit 1
fi
rm -f "$out.log"
cat "$out"
