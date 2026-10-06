#!/usr/bin/env bash
# Streaming benchmark, on a real phone: what an agent's answer costs while it
# streams into the chat screen (app/benchmark/stream_device_bench.dart).
# It builds a profile APK of the real
# `AgentSessionScreen` over an in-memory fake session (no network, no agent),
# installs it BESIDE the shipped app (own application id
# `...herdr_mobile.streambench`, own data; neither the shipped app nor the
# keyboard bench's `...kbbench` is touched), runs it, and turns what it logged
# into METRIC lines. Per case `<profile>_<closed|kb>_<name>`:
#
#   profile   synthetic = steady 40 tokens/s delivered in 200 ms bursts;
#             claude | omp | codex = that agent's recorded chunk cadence
#             (app/test/fixtures/traces/CADENCE.md); `kb` = keyboard open
#   frames, build_{p50,p95,max}_ms, raster_{p50,p95,max}_ms, total_p95_ms,
#   late_frames, dropped, jank_ms     per frame, from FrameTiming
#   chunk_cost_{mean,p95,max}_ms      per chunk: parse + reducer + notify
#   lag_{p50,p95,max}_ms, lag_chars_*  how long the oldest received character
#                                     that is not on screen has waited
#   end_move_{p95,max}_dp, end_move_over_line   per-frame move of the content's end
#   drift_{p95,max}_dp, drift_frames  distance of the view from the end while following
#   send_to_frame_ms, first_paint_ms, settled_pending_chars, probe_p95_ms
#
# The streamed answer is 20 KB of markdown under a 2000 row transcript. The
# transcript is the real one; the session is the bench's copy of the data path
# (see the header of app/benchmark/support/stream_session.dart).
#
# Needs an adb device that is awake and unlocked. HERDR_BENCH_DEVICE=host:port
# picks one (default: the only connected device). For a phone on Wi-Fi or
# Tailscale: Developer options > Wireless debugging, then `adb connect
# host:port` first (the port changes whenever Wireless debugging restarts);
# with the phone on this machine's LAN `adb mdns services` finds it and this
# script connects by itself (HERDR_BENCH_HOSTS: addresses to try, tailnet
# first). mDNS does not cross Tailscale: read the port on the phone and
# connect by hand.
#
#   STREAM_RUNS=1          runs on the device (medians are reported); default 1.
#                          One run takes about 10 minutes: 20 KB streams at
#                          160-440 characters a second, six cases.
#   STREAM_KB=20           size of the answer, KB
#   STREAM_ROWS=2000       rows of transcript above it
#   STREAM_PROFILES=synthetic,claude,omp,codex      cases with the keyboard closed
#   STREAM_KEYBOARD_PROFILES=synthetic,claude       cases with the keyboard open
#   STREAM_SMOOTH=1        Smooth text (the pacing of the live answer); 0 shows text
#                          as it arrives, to measure the reveal on and off
#   STREAM_NO_BUILD=1      reuse the APK of the last build
#   STREAM_TIMEOUT=1800    seconds to wait for one run
#
# Before the build it regenerates app/benchmark/support/trace_cadence.dart from
# the fixtures (`dart run benchmark/support/gen_trace_cadence.dart`).
set -euo pipefail

# Needs flutter and adb on PATH and ANDROID_HOME set (the Android SDK).
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
export ANDROID_HOME
cd "$(dirname "$0")/app"

pkg=dev.herdrmobile.herdr_mobile.streambench
activity=dev.herdrmobile.herdr_mobile.MainActivity
built=build/app/outputs/flutter-apk/app-profile.apk
apk=build/stream-bench.apk
runs="${STREAM_RUNS:-1}"
timeout_s="${STREAM_TIMEOUT:-1800}"

adb_ready() { adb devices | awk 'NR > 1 && $2 == "device" {print $1}' | head -1; }

# Wireless debugging moves to a new port whenever the phone's Wi-Fi blips, which
# leaves the old entry offline: drop those and connect to what the phone
# advertises now.
find_phone() {
  local found host port
  adb devices | awk 'NR > 1 && $2 == "offline" {print $1}' | xargs -r -n1 adb disconnect >/dev/null 2>&1 || true
  found="$(adb_ready)"
  for host in ${HERDR_BENCH_HOSTS:-100.78.185.62 192.168.110.195}; do
    for port in $(adb mdns services 2>/dev/null | awk '/_adb-tls-connect/ {print $NF}' | sed 's/.*://' | sort -u); do
      [ -n "$found" ] && break 2
      timeout 12 adb connect "$host:$port" >/dev/null 2>&1 || true
      found="$(adb_ready)"
    done
  done
  echo "$found"
}

dev="${HERDR_BENCH_DEVICE:-$(adb_ready)}"
[ -n "$dev" ] || dev="$(find_phone)"
if [ -z "$dev" ]; then
  echo "no adb device: wake the phone, turn on Wireless debugging, adb connect host:port (or set HERDR_BENCH_DEVICE)" >&2
  exit 2
fi
phone() { adb -s "$dev" "$@"; }
# The link can drop while a build runs or between two runs.
ensure_phone() {
  phone shell true >/dev/null 2>&1 && return 0
  dev="$(find_phone)"
  [ -n "$dev" ] || { echo "the phone went away: wake it, check Wireless debugging" >&2; exit 2; }
}
echo "device: $dev $(phone shell getprop ro.product.model | tr -d '\r') (Android $(phone shell getprop ro.build.version.release | tr -d '\r'))" >&2

work="$(mktemp -d)"
stayon="$(phone shell settings get global stay_on_while_plugged_in | tr -d '\r')"
cleanup() {
  [ -n "${logpid:-}" ] && kill "$logpid" 2>/dev/null || true
  phone shell am force-stop "$pkg" >/dev/null 2>&1 || true
  # The run keeps the screen on while plugged in; put the setting back (unless
  # /tmp/herdr-kb-keep-awake exists, see autoresearch.sh).
  [ -e /tmp/herdr-kb-keep-awake ] || phone shell settings put global stay_on_while_plugged_in "${stayon:-0}" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

if [ "${STREAM_NO_BUILD:-}" != 1 ]; then
  dart run benchmark/support/gen_trace_cadence.dart >&2
  defines=()
  for v in STREAM_KB STREAM_ROWS STREAM_PROFILES STREAM_KEYBOARD_PROFILES STREAM_SMOOTH; do
    [ -n "${!v:-}" ] && defines+=("--dart-define=$v=${!v}")
  done
  flutter build apk --profile --target-platform android-arm64 \
    -t benchmark/stream_device_bench.dart \
    --android-project-arg=appIdSuffix=.streambench "${defines[@]}" >&2
  # The keyboard bench builds to the same path: keep this one apart.
  cp "$built" "$apk"
fi
[ -f "$apk" ] || { echo "no $apk: run without STREAM_NO_BUILD=1 first" >&2; exit 1; }
ensure_phone
timeout 300 adb -s "$dev" install -r -t "$apk" >&2

phone shell svc power stayon true >/dev/null
for i in $(seq 1 "$runs"); do
  ensure_phone
  log="$work/log.$i"
  : >"$log"
  phone shell input keyevent KEYCODE_WAKEUP
  phone shell am force-stop "$pkg"
  phone logcat -c
  adb -s "$dev" logcat -v brief -s flutter:I >"$log" &
  logpid=$!
  phone shell am start -W -n "$pkg/$activity" >/dev/null
  for _ in $(seq 1 "$timeout_s"); do
    sleep 1
    grep -qE 'STREAMBENCH_(DONE|ERROR)' "$log" && break
  done
  sleep 1
  kill "$logpid" 2>/dev/null || true
  logpid=
  sed -E 's/^[A-Z]\/flutter *\( *[0-9]+\): //' "$log" | grep STREAMBENCH >"$work/run.$i" || true
  cat "$work/run.$i" >&2
  if grep -q 'STREAMBENCH_ERROR' "$work/run.$i" || ! grep -q 'STREAMBENCH_DONE' "$work/run.$i"; then
    echo "run $i did not finish (phone locked or asleep? app crashed?)" >&2
    exit 1
  fi
done

thermal="$(phone shell dumpsys thermalservice | tr -d '\r' | sed -n 's/.*Thermal Status: *\([0-9]*\).*/\1/p' | head -1)"
temp="$(phone shell dumpsys battery | tr -d '\r' | sed -n 's/.*temperature: *\([0-9]*\).*/\1/p' | head -1)"

# Median of every metric across the runs.
python3 - "$work" "$runs" <<'PY'
import re, statistics, sys
work, runs = sys.argv[1], int(sys.argv[2])
values = {}
order = []
for i in range(1, runs + 1):
    for line in open(f"{work}/run.{i}"):
        m = re.match(r"STREAMBENCH_METRIC ([a-z0-9_]+)=(-?[0-9.]+)", line)
        if m:
            name = m.group(1)
            if name not in values:
                values[name] = []
                order.append(name)
            values[name].append(float(m.group(2)))
for name in order:
    v = statistics.median(values[name])
    print(f"METRIC {name}={v:.3f}")
PY
echo "METRIC thermal_status=${thermal:-0}"
echo "METRIC battery_temp_c=$(LC_ALL=C awk "BEGIN {print ${temp:-0} / 10}")"
