#!/usr/bin/env bash
# Writes the kinds of tool call and item the INSTALLED Claude Code and Codex
# know, into app/test/fixtures/schemas/, for test/agent_coverage_test.dart.
#
#   tool/sync-agent-schemas.sh            # both
#   tool/sync-agent-schemas.sh codex      # one
#
# Run it after the agents update (a weekly run is the point: agents change
# weekly). When the test then fails, a kind is new: add it to
# app/lib/data/observed/agent_coverage.dart (map it, show it generically, or
# say why it is ignored), capture a real log of it (tool/capture-*.sh), commit
# the new schema files with the mapper change.
#
# Sources (both ship with the agents, matched to their versions):
#   codex   `codex app-server generate-json-schema`: the ThreadItem variants
#           the rollout writes as `item_completed` items.
#   claude  the tool schemas of `@anthropic-ai/claude-agent-sdk`
#           (sdk-tools.d.ts): one `<Tool>Input` type per tool. Needs `npm`.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/app/test/fixtures/schemas
mkdir -p "$out"
want=${1:-all}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ "$want" = all ] || [ "$want" = codex ]; then
  command -v codex >/dev/null || { echo "sync-agent-schemas: codex is not on PATH" >&2; exit 1; }
  version=$(codex --version | sed 's/^codex-cli //')
  codex app-server generate-json-schema --out "$tmp/codex" >/dev/null
  python3 - "$tmp/codex" "$out/codex-items.txt" "$version" <<'PY'
import json, sys
src, dest, version = sys.argv[1:4]
defs = json.load(open(f"{src}/codex_app_server_protocol.v2.schemas.json"))["definitions"]
items = sorted(v["properties"]["type"]["enum"][0] for v in defs["ThreadItem"]["oneOf"])
collab = sorted(defs["CollabAgentTool"].get("enum", []))
kinds = sorted(defs["SubAgentActivityKind"].get("enum", []))
with open(dest, "w") as f:
    f.write(f"# codex {version}: ThreadItem types (`codex app-server generate-json-schema`)\n")
    for i in items: f.write(f"item {i}\n")
    for c in collab: f.write(f"collab-tool {c}\n")
    for k in kinds: f.write(f"subagent-kind {k}\n")
PY
  echo "wrote $out/codex-items.txt (codex $version)"
fi

if [ "$want" = all ] || [ "$want" = claude ]; then
  command -v npm >/dev/null || { echo "sync-agent-schemas: npm is not on PATH" >&2; exit 1; }
  # `npm pack` downloads the tarball and runs no install scripts. Pin a version
  # with SDK_VERSION=x.y.z to reproduce an older sync.
  (cd "$tmp" && npm pack "@anthropic-ai/claude-agent-sdk${SDK_VERSION:+@$SDK_VERSION}" --silent --ignore-scripts >/dev/null && tar --no-same-owner -xzf ./*.tgz)
  sdk=$(python3 - "$tmp/package/package.json" <<'PY'
import json, re, sys
v = json.load(open(sys.argv[1]))["version"]
print(v if re.fullmatch(r"[0-9A-Za-z.+-]+", v) else "unknown")
PY
)
  claude_version=$(claude --version 2>/dev/null | awk '{print $1}' | tr -cd '0-9A-Za-z.+-' || true)
  {
    echo "# @anthropic-ai/claude-agent-sdk $sdk tool input types (sdk-tools.d.ts); installed claude: ${claude_version:-unknown}"
    grep -oE '^export interface [A-Za-z]+Input\b' "$tmp/package/sdk-tools.d.ts" | awk '{print "tool " $3}' | sed 's/Input$//' | sort -u
  } >"$out/claude-tools.txt"
  echo "wrote $out/claude-tools.txt (sdk $sdk)"
fi
