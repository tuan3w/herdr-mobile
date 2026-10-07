#!/usr/bin/env bash
# What pulling and parsing a chat costs on a slow link, deterministic, no phone
# and no network. Two benches run one after the other (a wall-time bench, so
# never in parallel; about 45 s):
#
#  * app/benchmark/observed_open_bench_test.dart: the chat of an agent that runs
#    in a herdr pane (the app reads the agent's session log over SSH: the real
#    host helper, SshLogSource, ObservedAgentSession, OmpLogMapper and the
#    reducer; SSH itself is replaced by `sh -c`). `cold`: first open;
#    `relink`: back to a chat the app already held.
#  * app/benchmark/session_open_wire_bench_test.dart: the chat of an agent the
#    app started itself (the keeper, `AcpAgentSession`), `zip` variant, `cold`
#    (nothing on the phone) and `copy` (the saved transcript is on the phone).
#
#   open_score_ms          the modelled time to a live chat, in ms, summed over
#                          the 3 links (40 ms 30 Mbit, 120 ms 10 Mbit, 300 ms
#                          2 Mbit) and the 4 scenarios above: `obs_score_ms` +
#                          `keeper_score_ms`. A trend number: the two parts are
#                          modelled differently (the wire bench counts round
#                          trips, bytes and phone CPU, not host time; the
#                          observed bench also counts the host's start), so
#                          read the parts, not the sum, to see what moved.
#   obs_*                  the observed bench's parts: wire_kb, first_byte_ms
#                          (host start and read), gate_ms (channel held back),
#                          post_ms (parse and apply on the main isolate),
#                          pre_ms, host_ms, phone_cpu_ms, open_<link>_ms,
#                          fold_cpu_ms (mapper + reducer alone, thread CPU),
#                          replay_kb, replay_zip_ratio, items
#   keeper_*               the wire bench's numbers for the zip variant
#                          (keeper_zip_cold_*, keeper_zip_copy_*)
#
# The links, the `*_ms` of this machine (JIT, asserts on) and the workload (a
# generated omp log in the shape of a real one) are assumptions: compare changes
# with them, never quote them for a phone. The headers of the two benches say
# what is real and what is modelled. Needs python3 and Flutter >= 3.47
# (HERDR_FLUTTER_BIN is the SDK's bin directory).
set -euo pipefail

bin="$("$(dirname "$0")/tool/flutter-bin.sh")"
export PATH="$bin:$PATH"

cd "$(dirname "$0")/app"
tmp="$(mktemp -d -t herdr-open-bench.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

# pub get also rewrites ios/ files, so only when the packages are not there.
if [ ! -f .dart_tool/package_config.json ] || [ pubspec.yaml -nt .dart_tool/package_config.json ]; then
  flutter pub get >/dev/null
  git checkout -- ios/Flutter 2>/dev/null || true
fi

run() { # name, test file
  if ! BENCH_OUT="$tmp/$1.txt" flutter test --no-pub "$2" >"$tmp/$1.log" 2>&1; then
    tail -40 "$tmp/$1.log" >&2
    echo "$1 bench failed" >&2
    exit 1
  fi
  if ! grep -q '^METRIC ' "$tmp/$1.txt"; then
    echo "$1 bench printed no metrics" >&2
    exit 1
  fi
}

run observed benchmark/observed_open_bench_test.dart
run keeper benchmark/session_open_wire_bench_test.dart

metric() { # file, name
  awk -F= -v n="METRIC $2" '$1 == n { print $2 }' "$1"
}

obs_score="$(metric "$tmp/observed.txt" obs_score_ms)"
# The 6 rows of the zip variant (cold and copy, 3 links): fewer means a metric
# was renamed, and a partial sum would look like an improvement.
keeper_rows="$(grep -cE '^METRIC zip_(cold|copy)_open_(fast|mid|slow)_ms=' "$tmp/keeper.txt" || true)"
keeper_score="$(awk -F= '
  $1 ~ /^METRIC zip_(cold|copy)_open_(fast|mid|slow)_ms$/ { s += $2 }
  END { printf "%.3f", s }' "$tmp/keeper.txt")"
if [ -z "$obs_score" ] || [ "$keeper_rows" != "6" ]; then
  echo "a bench did not report its score (observed: '${obs_score:-none}', keeper rows: $keeper_rows of 6)" >&2
  exit 1
fi
total="$(awk -v a="$obs_score" -v b="$keeper_score" 'BEGIN { printf "%.3f", a + b }')"

echo "METRIC open_score_ms=$total"
echo "METRIC keeper_score_ms=$keeper_score"
cat "$tmp/observed.txt"
grep '^METRIC zip_' "$tmp/keeper.txt" | sed 's/^METRIC /METRIC keeper_/'
