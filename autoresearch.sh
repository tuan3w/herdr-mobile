#!/usr/bin/env bash
# How long the CI check takes (.github/workflows/ci.yml runs `tool/check.sh`:
# pub get, analyze, test). This runs that exact script, so every change to
# check.sh, the tests, analysis_options or pubspec shows up in the number.
#
#   ci_wall_s    THE number (lower is better): wall seconds of tool/check.sh
#   pub_get_s, analyze_s, test_s   its three steps (from the `==>` markers)
#   cpu_s        user+sys CPU seconds of the whole run (all children). Wall time
#                on a CI runner is about cpu_s / cores, floored by the longest
#                test file, so this is the number that survives a different machine
#   cores        cores here. A GitHub runner has 4 and `flutter test` runs
#                cores-2 files at once, so CI is 2 wide where a laptop is 6+ wide
#
# Not modelled (unverified, cannot be measured off the runner): checkout, the
# Flutter SDK and pub-cache restore in subosito/flutter-action, a cold
# `pub get`, and the 4-core CPU. Slowness the run only shows with a cold cache
# needs a CI log to see.
#
# Flutter >= 3.47: HERDR_FLUTTER_BIN is the SDK's bin directory (defaults to
# ~/.cache/flutter-3.47.6/bin when that exists and nothing else is set).
# A run takes about 4 minutes on 8 cores and fails if analyze or any test fails.
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${HERDR_FLUTTER_BIN:-}" ] && [ -d "$HOME/.cache/flutter-3.47.6/bin" ]; then
  export HERDR_FLUTTER_BIN="$HOME/.cache/flutter-3.47.6/bin"
fi

exec python3 - <<'PY'
import os, resource, subprocess, sys, time

def cpu():
    r = resource.getrusage(resource.RUSAGE_CHILDREN)
    return r.ru_utime + r.ru_stime

cpu0, t0 = cpu(), time.monotonic()
p = subprocess.Popen(["tool/check.sh"], stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, bufsize=1)
marks, tail = [], []
for line in p.stdout:
    now = time.monotonic()
    if line.startswith("==> "):
        marks.append((line[4:].strip(), now))
    tail.append(line)
    tail = tail[-40:]
    sys.stdout.write(line)
    sys.stdout.flush()
rc = p.wait()
end = time.monotonic()
if rc != 0:
    sys.stderr.write("tool/check.sh failed (exit %d)\n" % rc)
    sys.exit(rc)

# Each step lasts until the next marker, the last until the process ends.
steps = {}
for i, (name, t) in enumerate(marks):
    nxt = marks[i + 1][1] if i + 1 < len(marks) else end
    steps[name] = nxt - t
names = {"flutter pub get": "pub_get_s", "flutter analyze": "analyze_s",
         "flutter test": "test_s"}
print("METRIC ci_wall_s=%.2f" % (end - t0))
for k, m in names.items():
    if k in steps:
        print("METRIC %s=%.2f" % (m, steps[k]))
print("METRIC cpu_s=%.1f" % (cpu() - cpu0))
print("METRIC cores=%d" % (os.cpu_count() or 0))
PY
