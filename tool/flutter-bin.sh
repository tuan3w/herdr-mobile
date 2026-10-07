#!/usr/bin/env bash
# Prints the bin directory of a Flutter SDK whose Dart satisfies the `sdk:`
# constraint of app/pubspec.yaml, and exits 1 (saying what it found) when there
# is none. Every script that runs flutter or dart gets it from here:
#
#   bin="$(tool/flutter-bin.sh)" && export PATH="$bin:$PATH"
#
# Why: a machine often has more than one Flutter, and the one on PATH can be
# too old for the repo's Dart (3.10 against ^3.13.5 failed pub get with a
# resolver error that never says which SDK ran).
#
# Order: HERDR_FLUTTER_BIN (an explicit choice: used only if it fits, never
# silently replaced), then `flutter` on PATH, then the usual install places,
# newest version first within each glob. The Dart version comes from
# <sdk>/bin/cache/dart-sdk/version, read without starting flutter (which takes
# seconds); an SDK that never ran has no such file and is asked `dart --version`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

# `sdk: ^3.13.5` under `environment:` -> 3.13.5. Anything but a caret
# constraint accepts any SDK (the resolver then says what is wrong).
need="$(sed -n 's/^  sdk: *\^\([0-9][0-9.]*\).*/\1/p' "$root/app/pubspec.yaml" | head -n 1)"

dart_version() { # sdk bin dir -> x.y.z, or nothing
  local v=""
  if [ -f "$1/cache/dart-sdk/version" ]; then
    v="$(head -n 1 "$1/cache/dart-sdk/version")"
  elif [ -x "$1/dart" ]; then
    v="$("$1/dart" --version 2>&1 | sed -n 's/.*Dart SDK version: *\([0-9][0-9.]*\).*/\1/p' | head -n 1)"
  fi
  printf '%s' "${v%%[!0-9.]*}" # 3.14.0-12.0.dev -> 3.14.0
}

fits() { # version -> whether ^need allows it: same major, not older
  [ -n "$1" ] || return 1
  [ -n "$need" ] || return 0
  [ "${1%%.*}" = "${need%%.*}" ] || return 1
  [ "$(printf '%s\n%s\n' "$need" "$1" | sort -V | head -n 1)" = "$need" ]
}

seen=""
tried() { seen="$seen  $1 (Dart ${2:-unknown})"$'\n'; }

if [ -n "${HERDR_FLUTTER_BIN:-}" ]; then
  v="$(dart_version "$HERDR_FLUTTER_BIN")"
  if [ -x "$HERDR_FLUTTER_BIN/flutter" ] && fits "$v"; then
    printf '%s\n' "$HERDR_FLUTTER_BIN"
    exit 0
  fi
  echo "HERDR_FLUTTER_BIN=$HERDR_FLUTTER_BIN has Dart ${v:-unknown}; app/pubspec.yaml needs ^$need." >&2
  exit 1
fi

candidates=()
if on_path="$(command -v flutter 2>/dev/null)"; then
  # A symlink (Homebrew, a shim) points into the real SDK.
  real="$(readlink -f "$on_path" 2>/dev/null || printf '%s' "$on_path")"
  candidates+=("$(dirname "$real")")
fi
for pattern in "$HOME/.cache/flutter-*/bin" "$HOME/fvm/versions/*/bin" "$HOME/.puro/envs/*/flutter/bin"; do
  # Newest version first: the glob sorts 3.9 after 3.47, sort -V does not.
  while IFS= read -r d; do
    [ -n "$d" ] && candidates+=("$d")
  done < <(compgen -G "$pattern" | sort -rV || true)
done
candidates+=("$HOME/fvm/default/bin" "$HOME/flutter/bin" "$HOME/development/flutter/bin" "/opt/flutter/bin" "/usr/local/flutter/bin")

for bin in "${candidates[@]}"; do
  [ -x "$bin/flutter" ] || continue
  case "$seen" in *"  $bin ("*) continue ;; esac
  v="$(dart_version "$bin")"
  if fits "$v"; then
    if [ -n "$seen" ]; then
      printf 'Using %s (Dart %s): app/pubspec.yaml needs ^%s, and these do not fit:\n%s' "$bin" "$v" "$need" "$seen" >&2
    fi
    printf '%s\n' "$bin"
    exit 0
  fi
  tried "$bin" "$v"
done

if [ -n "$seen" ]; then
  printf 'No Flutter here has a Dart that fits ^%s (app/pubspec.yaml). Found:\n%s' "$need" "$seen" >&2
else
  echo "No Flutter found (PATH, ~/.cache/flutter-*, fvm, puro, ~/flutter). Install one whose Dart fits ^$need, or set HERDR_FLUTTER_BIN to its bin directory." >&2
fi
exit 1
