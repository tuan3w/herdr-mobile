#!/bin/sh
# Installs herdr-tui, the desktop client for herdr-mobile sessions, from a GitHub release.
# No Rust, no checkout: the binary carries the keeper it needs.
#
#   curl -fsSL https://github.com/tuan3w/herdr-mobile/releases/latest/download/install.sh | sh
#   VERSION=v0.1.30 sh install.sh        # a specific release
#   BIN_DIR=/usr/local/bin sh install.sh # another folder (default ~/.local/bin)
#
# The download is checked against the release's SHA256SUMS before it is installed, and put
# in place by a rename, so a herdr-tui that is open keeps running.
# HERDR_TUI_BASE_URL overrides where files come from (a mirror, or a folder for tests).
set -eu

repo="tuan3w/herdr-mobile"
bin_dir="${BIN_DIR:-$HOME/.local/bin}"
if [ -n "${HERDR_TUI_BASE_URL:-}" ]; then
  base="$HERDR_TUI_BASE_URL"
elif [ -n "${VERSION:-}" ]; then
  base="https://github.com/$repo/releases/download/$VERSION"
else
  base="https://github.com/$repo/releases/latest/download"
fi

say() { printf 'herdr-tui: %s\n' "$*"; }
fail() { printf 'herdr-tui: %s\n' "$*" >&2; exit 1; }

os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
  Linux/x86_64) asset=herdr-tui-linux-x86_64 ;;
  Linux/aarch64 | Linux/arm64) asset=herdr-tui-linux-aarch64 ;;
  Darwin/arm64) asset=herdr-tui-macos-arm64 ;;
  Darwin/x86_64) asset=herdr-tui-macos-x86_64 ;;
  *) fail "no build for $os $arch" ;;
esac

if command -v curl >/dev/null 2>&1; then
  get() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  get() { wget -q "$1" -O "$2"; }
else
  fail "needs curl or wget"
fi
if command -v sha256sum >/dev/null 2>&1; then
  sum() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sum() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  fail "needs sha256sum or shasum to check the download"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "downloading $asset"
get "$base/$asset" "$tmp/$asset" || fail "could not download $base/$asset (does that release include herdr-tui?)"
get "$base/herdr-tui-SHA256SUMS" "$tmp/sums" || fail "could not download the checksums from $base"

want=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/sums")
[ -n "$want" ] || fail "the checksums do not list $asset"
have=$(sum "$tmp/$asset")
[ "$want" = "$have" ] || fail "checksum mismatch for $asset (wanted $want, got $have); nothing was installed"

mkdir -p "$bin_dir"
chmod 755 "$tmp/$asset"
mv "$tmp/$asset" "$bin_dir/herdr-tui.new"
mv "$bin_dir/herdr-tui.new" "$bin_dir/herdr-tui"
say "installed $bin_dir/herdr-tui ($("$bin_dir/herdr-tui" --version 2>&1 || echo unknown version))"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) say "$bin_dir is not on your PATH; add it to your shell profile" ;;
esac
say "start a session with: herdr-tui    list them with: herdr-tui ls"
