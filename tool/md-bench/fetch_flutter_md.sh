#!/usr/bin/env bash
# Copies the three pure-Dart files of flutter_md 0.2.0 (parser, nodes,
# markdown; MIT, github.com/DoctorinaAI/md) into lib/fmd/ so the bench can
# AOT-compile them: the package itself depends on the Flutter SDK.
set -euo pipefail
cd "$(dirname "$0")"
COMMIT=6e3193544ddc4c504938e5ff4eb7e1a4da34f0fa
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone --quiet https://github.com/DoctorinaAI/md "$tmp/md"
git -C "$tmp/md" checkout --quiet "$COMMIT"
mkdir -p lib/fmd
cp "$tmp/md/lib/src/"{parser,nodes,markdown}.dart lib/fmd/
cp "$tmp/md/LICENSE" lib/fmd/LICENSE
echo "flutter_md @ $COMMIT -> lib/fmd/"
