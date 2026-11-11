#!/usr/bin/env bash
# Records real ACP traces of an agent as test fixtures, with timestamps:
# every JSON-RPC line, both ways, one JSONL file per scenario.
#
#   tool/capture-trace.sh <omp|claude|codex|pi|kimi|cursor|opencode|hermes|copilot|all> [scenario ...] [--force]
#
# Scenarios (tiny, cheap prompts, see tool/capture_trace.py): markdown, tools,
# plan, thinking; omp also ask; claude also subagent; omp, claude, codex and
# cursor also permission (kimi has markdown, tools, plan; cursor markdown, tools,
# permission; kimi, opencode, hermes and copilot markdown, tools, subagent; OpenCode needs 2.x on PATH, Hermes and
# Copilot an OpenAI-compatible endpoint, see capture_trace.py). Default: every scenario the agent has. Files land in
# app/test/fixtures/traces/<agent>/<scenario>.jsonl (+ .meta.json), and an
# existing one is never overwritten without --force.
#
# What it does and does not touch (the driver's docstring has the details):
#   * the agent runs in a fresh scratch git repo under /tmp, deleted after;
#   * omp's, codex's and opencode's stores are redirected to temp dirs, and
#     opencode also gets an empty HOME, no *_API_KEY/*_TOKEN/*_SECRET variable
#     and {"permission": "ask"} (by default it runs shell and edits unasked);
#   * Claude's, kimi's and cursor's stores are not redirected (a login token
#     rotates on refresh, a refreshed copy would invalidate the owner's).
#     Claude's project folder for the scratch directory is removed after.
#     Limitation: a kimi or cursor capture leaves a session with a deleted
#     working directory in the real ~/.kimi-code or ~/.cursor, which the app's
#     Past sessions lists; delete it by hand, this tool leaves other tools'
#     files alone;
#   * permissions are answered by the driver: allow-once only for commands and
#     paths inside the scratch directory, only in scenarios that expect one;
#   * an agent whose login is missing or expired is skipped with a note (pi's
#     is expired, docs/AGENT_SESSIONS.md), never worked around;
#   * fixtures are redacted ($HOME, user and host name, emails, tokens).
# A turn costs real tokens: a few cents each. Needs python3 and the agent's
# own binary (omp) or npx (claude, codex, pi) on PATH.
#
# Afterwards: `flutter test test/traces_test.dart` checks the files, and
# `python3 tool/trace_cadence.py` rewrites app/test/fixtures/traces/CADENCE.md.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { sed -n '2,/^set -e/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 64; }
exec python3 tool/capture_trace.py "$@"
