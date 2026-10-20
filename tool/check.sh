#!/usr/bin/env bash
# One command for "is the app healthy?": analyze + design lint + unit tests.
# Usage: tool/check.sh [--quick | --tests]
#   --quick  analyze and design lint only (skips the tests)
#   --tests  the tests only (CI runs the other half as its own job)
# HERDR_TEST_SHARD=<i>/<n> runs shard i (0-based) of n of the tests; CI uses
# it to spread them over runners.
# HERDR_TEST_ONLY=timing | rest runs only the tests tagged `timing` (those that
# depend on real time, see app/dart_test.yaml), at half the jobs so they have
# CPU to spare, or everything else; unset runs all of them.
set -euo pipefail

# A flutter whose Dart fits app/pubspec.yaml (tool/flutter-bin.sh picks it;
# HERDR_FLUTTER_BIN=<sdk>/bin forces one).
bin="$("$(dirname "$0")/flutter-bin.sh")"
export PATH="$bin:$PATH"

cd "$(dirname "$0")/../app"

echo "==> flutter pub get"
flutter pub get >/dev/null

if [ "${1:-}" != "--tests" ]; then
  echo "==> flutter analyze"
  flutter analyze

  # Every value a screen draws with comes from the kit (docs/DESIGN.md,
  # "Enforcement"); a finding names the token or component to use instead.
  echo "==> design lint"
  dart run ../tool/design_lint.dart
fi

if [ "${1:-}" != "--quick" ]; then
  # One flutter_tester per test file costs a compile and an engine start per
  # file: the compiler is a single process, so with 308 files the run was
  # mostly files waiting to be compiled, whatever -j said. The experimental
  # runner compiles every file into one kernel once and runs each file in an
  # isolate of one engine. Its generated package config resolves the
  # relative `"rootUri": "../"` of this package against the wrong directory
  # (Flutter 3.47: the project path has no trailing slash), so every
  # package:herdr_mobile import fails to compile; an absolute root works.
  # The pub-written file is put back afterwards.
  config=.dart_tool/package_config.json
  cp "$config" "$config.orig"
  trap 'mv -f "$config.orig" "$config"' EXIT
  sed -i "s#\"rootUri\": \"../\"#\"rootUri\": \"file://$PWD/\"#" "$config"
  jobs="${HERDR_TEST_JOBS:-$(nproc)}"
  tags=()
  case "${HERDR_TEST_ONLY:-}" in
    timing)
      tags=(--tags timing)
      jobs="${HERDR_TEST_JOBS:-$(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 ))}"
      ;;
    rest) tags=(--exclude-tags timing) ;;
    "") ;;
    *) echo "HERDR_TEST_ONLY must be timing or rest, not ${HERDR_TEST_ONLY}" >&2; exit 2 ;;
  esac
  shard=()
  if [ -n "${HERDR_TEST_SHARD:-}" ]; then
    shard=(--shard-index "${HERDR_TEST_SHARD%/*}" --total-shards "${HERDR_TEST_SHARD#*/}")
  fi
  echo "==> flutter test"
  flutter test --no-pub --experimental-faster-testing -j "$jobs" ${tags[@]+"${tags[@]}"} ${shard[@]+"${shard[@]}"}
fi
echo "OK"
