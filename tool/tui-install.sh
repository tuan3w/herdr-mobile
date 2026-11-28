#!/bin/sh
# Builds herdr-tui in release mode and installs it for the person developing it, so a change
# can be tried in a real terminal within seconds.
#
#   tool/tui-install.sh            build + install (about 6 s when only the viewer changed)
#   tool/tui-install.sh --check    fmt, clippy and tests first, install only if they pass
#
# Installs to ~/.local/bin/herdr-tui (HERDR_TUI_BIN_DIR to change it) by writing a neighbour and
# renaming it over the old one, so it works while a session is open: that session keeps running
# the old version, a new one gets the new. The keeper is part of the binary: nothing else to install.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
manifest="$repo/rust/Cargo.toml"
dest="${HERDR_TUI_BIN_DIR:-$HOME/.local/bin}"

if [ "${1:-}" = "--check" ]; then
    cargo fmt --manifest-path "$manifest" --all --check
    cargo clippy --manifest-path "$manifest" --workspace --all-targets --quiet -- -D warnings
    cargo test --manifest-path "$manifest" --workspace --quiet
fi

# Warnings are for --check; here only a failed build is worth the screen.
if ! out=$(cargo build --manifest-path "$manifest" --release --quiet 2>&1); then
    printf '%s\n' "$out"
    exit 1
fi
mkdir -p "$dest"
cp "$repo/rust/target/release/herdr-tui" "$dest/herdr-tui.new"
chmod 755 "$dest/herdr-tui.new"
mv -f "$dest/herdr-tui.new" "$dest/herdr-tui"

size=$(wc -c < "$dest/herdr-tui" | tr -d ' ')
echo "installed $dest/herdr-tui ($("$dest/herdr-tui" --version 2>&1), $((size / 1024)) KB)"
open=$(pgrep -x herdr-tui 2>/dev/null | wc -l | tr -d ' ')
if [ "$open" != "0" ]; then
    echo "$open open session(s) keep the old version until you reopen them (Ctrl-D, then herdr-tui attach ID)"
fi
