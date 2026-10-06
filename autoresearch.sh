#!/usr/bin/env bash
# Keyboard benchmark, on a real phone: what tapping the composer of an agent's
# tab costs (app/benchmark/keyboard_device_bench.dart). It builds a profile APK
# of the real app tree over an in-memory herdr (no network), installs it
# BESIDE the shipped app (own application id `...herdr_mobile.kbbench`, own
# data; the shipped app is never touched), runs it, and turns what it logged
# into METRIC lines:
#
#   snap_dp                  jump at the end of the keyboard's opening animation,
#                            dp (the last step of the layout's inset, idle
#                            agent; ~0 when the animation ends where it settles)
#   <scenario>_<open|close>_*  tap_to_first_ms, settle_ms (tap to the layout being
#                            within 10 dp of its end), anim_ms, steps, frames,
#                            dropped, jank_ms, ui/raster p95 and max, ...
#   cold_open_*              the first keyboard of the process
#   thermal_status, battery_temp_c   noise context: the phone throttles when hot
#
# Needs an adb device that is awake and unlocked. HERDR_BENCH_DEVICE=host:port
# picks one (default: the only connected device). For a phone on Wi-Fi:
# `adb connect host:port` first (Developer options > Wireless debugging).
#
#   KB_RUNS=2       runs on the device (medians are reported); default 2
#   KB_CONTROL=1    swap the app for the smallest Flutter text-field screen:
#                   what the control shows is the platform's, not the app's UI
#   KB_NO_BUILD=1   reuse the APK from the last build
#
# The other benchmarks (host, no device) stay runnable on their own:
#   BENCH_OUT=/tmp/x flutter test benchmark/{pane,startup,transfer}_bench.dart
set -euo pipefail

# Needs flutter and adb on PATH and ANDROID_HOME set (the Android SDK).
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
export ANDROID_HOME
cd "$(dirname "$0")/app"

pkg=dev.herdrmobile.herdr_mobile.kbbench
activity=dev.herdrmobile.herdr_mobile.MainActivity
apk=build/app/outputs/flutter-apk/app-profile.apk
runs="${KB_RUNS:-2}"

adb_ready() { adb devices | awk 'NR > 1 && $2 == "device" {print $1}' | head -1; }

# Wireless debugging moves to a new port whenever the phone's Wi-Fi blips, which
# leaves the old entry offline: drop those and connect to what the phone
# advertises now (HERDR_BENCH_HOSTS: addresses to try, tailnet first).
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
  # The run keeps the screen on while plugged in; put the setting back. A long
  # session leaves it on (touch /tmp/herdr-kb-keep-awake), because the Wi-Fi
  # link drops when the screen sleeps; remove the file and run
  # `adb shell settings put global stay_on_while_plugged_in 0` when done.
  [ -e /tmp/herdr-kb-keep-awake ] || phone shell settings put global stay_on_while_plugged_in "${stayon:-0}" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

if [ "${KB_NO_BUILD:-}" != 1 ]; then
  defines=()
  [ "${KB_CONTROL:-}" = 1 ] && defines+=(--dart-define=KB_CONTROL=true)
  flutter build apk --profile --target-platform android-arm64 \
    -t benchmark/keyboard_device_bench.dart \
    --android-project-arg=appIdSuffix=.kbbench "${defines[@]}" >&2
fi
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
  for _ in $(seq 1 240); do
    sleep 1
    grep -qE 'KBBENCH_(DONE|ERROR)' "$log" && break
  done
  sleep 1
  kill "$logpid" 2>/dev/null || true
  logpid=
  sed -E 's/^[A-Z]\/flutter *\( *[0-9]+\): //' "$log" | grep KBBENCH >"$work/run.$i" || true
  cat "$work/run.$i" >&2
  if grep -q 'KBBENCH_ERROR' "$work/run.$i" || ! grep -q 'KBBENCH_DONE' "$work/run.$i"; then
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
        m = re.match(r"KBBENCH_METRIC ([a-z0-9_]+)=(-?[0-9.]+)", line)
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
