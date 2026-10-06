#!/usr/bin/env bash
# Prints the release notes for one version: its section of CHANGELOG.md, from
# `## [<version>]` up to the next `## [`, without the heading. Fails when the
# section is missing or empty, so a release never ships without notes.
#
#   tool/release-notes.sh 0.1.0
set -euo pipefail
version="${1:?usage: tool/release-notes.sh <version>}"
cd "$(dirname "$0")/.."
notes="$(awk -v v="$version" '
  index($0, "## [" v "]") == 1 { on = 1; next }
  on && /^## \[/ { exit }
  on { print }
' CHANGELOG.md | sed -e '/./,$!d')"
if [ -z "${notes//[[:space:]]/}" ]; then
  echo "CHANGELOG.md has no notes for $version" >&2
  exit 1
fi
printf '%s\n' "$notes"
