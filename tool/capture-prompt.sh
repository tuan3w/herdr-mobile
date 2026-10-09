#!/usr/bin/env bash
# Saves what a herdr pane shows right now as a prompt fixture for
# app/test/prompt_corpus_test.dart: the agent's label and herdr's version as a
# `# key: value` header, then the last 60 rows (a dialog sits above the blank rows under it, which count) with their colours.
#
#   tool/capture-prompt.sh <pane-id> [name]
#
# Run it on a host that has `herdr`, while the agent is showing the screen worth
# keeping (a permission prompt, a question tool, a /model picker). The file is
# app/test/fixtures/prompts/<agent>/<name>.txt; <name> defaults to a timestamp.
# It never overwrites. Then run the corpus test with UPDATE_EXPECTED=1 to write
# the .expected file, and read that file against the screen before committing.
#
# Environment:
#   PROMPT_AGENT     agent label to use when herdr detects none in the pane
#   PROMPT_FIXTURES  fixtures directory (default: app/test/fixtures/prompts
#                    next to this script's repository)
set -euo pipefail

die() {
  echo "capture-prompt: $*" >&2
  exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: ${0##*/} <pane-id> [name]"
pane=$1
name=${2:-$(date +%Y%m%d-%H%M%S)}

[[ $pane =~ ^[A-Za-z0-9:_.-]+$ ]] || die "not a pane id: $pane"
[[ $name =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "name must be lower case letters, digits, . _ - : $name"
command -v herdr >/dev/null || die "herdr is not on PATH (run this on a host that has it)"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixtures=${PROMPT_FIXTURES:-$root/app/test/fixtures/prompts}

# A string field of herdr's compact JSON (`"agent":"claude"`); jq when present.
field() {
  if command -v jq >/dev/null; then
    jq -r --arg k "$1" '.result.pane[$k] // empty' <<<"$info"
  else
    sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" <<<"$info" | head -n 1
  fi
}

info=$(herdr pane get "$pane") || die "herdr cannot find pane $pane"
agent=${PROMPT_AGENT:-$(field agent)}
[ -n "$agent" ] || die "herdr detects no agent in $pane; set PROMPT_AGENT=<label> to name it"
[[ $agent =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "odd agent label: $agent"
status=$(field agent_status)
version=$(herdr --version | sed 's/^herdr[[:space:]]*//')

out=$fixtures/$agent/$name.txt
[ ! -e "$out" ] || die "$out exists; pick another name"
[ ! -e "${out%.txt}.expected" ] || die "${out%.txt}.expected exists; pick another name"

screen=$(herdr pane read "$pane" --source recent --lines 60 --ansi) || die "cannot read $pane"

# The read ends with the blank rows under the cursor: drop them, so the
# question is what the detector finds last, as on a phone.
esc=$'\033'
rows=()
while IFS= read -r line; do rows+=("${line%$'\r'}"); done <<<"$screen"
last=${#rows[@]}
while [ "$last" -gt 0 ]; do
  plain=$(sed -E "s/${esc}\\[[0-9;?]*[ -\\/]*[@-~]//g" <<<"${rows[last - 1]}")
  [[ $plain =~ [^[:space:]] ]] && break
  last=$((last - 1))
done
[ "$last" -gt 0 ] || die "pane $pane is empty"

mkdir -p "$fixtures/$agent"
(
  set -o noclobber
  {
    echo "# agent: $agent"
    echo "# herdr: $version"
    echo "# status: ${status:-unknown}"
    echo "# captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# source: herdr pane read --source recent --lines 60 --ansi"
    printf '%s\n' "${rows[@]:0:last}"
  } >"$out"
)
echo "wrote $out"
echo "Check it for paths, names and anything private, then:"
echo "  cd app && UPDATE_EXPECTED=1 flutter test test/prompt_corpus_test.dart"
