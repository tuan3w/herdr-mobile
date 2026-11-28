#!/bin/sh
# Installs herdr-host, the host-side helper the phone runs over SSH, from a
# GitHub release. No Rust, no checkout, no interpreter: the binary is self-contained.
#
#   curl -fsSL https://github.com/tuan3w/herdr-mobile/releases/latest/download/install-host.sh | sh
#   VERSION=v0.1.70 sh install-host.sh              # a specific release
#
# The download is checked against the release's herdr-host-SHA256SUMS before it is
# installed, and put in place by a rename, so a herdr-host that is running keeps
# running. It is installed to ~/.herdr-mobile/bin/herdr-host-<version> (private,
# 0700, not on the PATH: the phone execs it by absolute path, a person never runs
# it). <version> is what the binary says with --version, so the app finds exactly
# the build it was released with; `herdr-host serve` removes old ones.
# HERDR_HOST_BASE_URL overrides where the files come from (a mirror, or a folder
# for tests). On success it prints {"ok":true} as its last stdout line; progress
# goes to stderr. This exact text is embedded in the phone by
# keeper_command.dart's keeperInstallCommand (a test keeps the two in step).
set -eu

repo="tuan3w/herdr-mobile"
bin_dir="$HOME/.herdr-mobile/bin"
if [ -n "${HERDR_HOST_BASE_URL:-}" ]; then
  base="$HERDR_HOST_BASE_URL"
elif [ -n "${VERSION:-}" ]; then
  base="https://github.com/$repo/releases/download/$VERSION"
else
  base="https://github.com/$repo/releases/latest/download"
fi

say() { printf 'herdr-host: %s\n' "$*" >&2; }
fail() { printf 'herdr-host: %s\n' "$*" >&2; exit 1; }

os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
  Linux/x86_64) asset=herdr-host-linux-x86_64 ;;
  Linux/aarch64 | Linux/arm64) asset=herdr-host-linux-aarch64 ;;
  Darwin/arm64) asset=herdr-host-macos-arm64 ;;
  Darwin/x86_64) asset=herdr-host-macos-x86_64 ;;
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
get "$base/$asset" "$tmp/$asset" || fail "could not download $base/$asset (does that release include herdr-host?)"
get "$base/herdr-host-SHA256SUMS" "$tmp/sums" || fail "could not download the checksums from $base"

want=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/sums")
[ -n "$want" ] || fail "the checksums do not list $asset"
have=$(sum "$tmp/$asset")
[ "$want" = "$have" ] || fail "checksum mismatch for $asset (wanted $want, got $have); nothing was installed"

mkdir -p "$bin_dir"
chmod 700 "$HOME/.herdr-mobile" 2>/dev/null || true
chmod 755 "$tmp/$asset"
mv "$tmp/$asset" "$bin_dir/herdr-host.new"
# Run it from here, not from $tmp, which may be mounted noexec.
ver=$("$bin_dir/herdr-host.new" --version 2>/dev/null | awk 'NR == 1 { print $2 }')
case "$ver" in
  "" | *[!0-9A-Za-z.+-]*)
    rm -f "$bin_dir/herdr-host.new"
    fail "the download does not run on this machine (no version from --version)" ;;
esac
mv "$bin_dir/herdr-host.new" "$bin_dir/herdr-host-$ver"
chmod 700 "$bin_dir/herdr-host-$ver"
say "installed $bin_dir/herdr-host-$ver"
printf '{"ok":true}\n'
