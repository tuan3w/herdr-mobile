#!/usr/bin/env bash
# Scope packet for a herdr-review: what changed since <base>, in risk order, with the tests and
# docs that name each file and the type names the change removed that are still referenced.
# It is the plan for the review, not the review.
#
#   review_packet.sh [base]      base defaults to HEAD (uncommitted work); any rev works
#
# Read-only: it never touches the tree or the index. Always exits 0, so a caller never
# mistakes an empty packet for a failure. bash 3.2 (macOS) compatible; uses only git and grep.
set -u

cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || { echo "# Review packet"; echo "not inside a git repository"; exit 0; }

base="${1:-HEAD}"
if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  echo "# Review packet"
  echo "base '$base' is not a commit"
  exit 0
fi

dirty="$(git status --short | wc -l | tr -d ' ')"
tab="$(printf '\t')"

echo "# Review packet"
echo
echo "- base: $(git log -1 --format='%h %s' "$base")"
echo "- head: $(git log -1 --format='%h %s' HEAD)"
echo "- modified or untracked files in the working tree: $dirty"
if [ "$dirty" -gt 0 ]; then
  echo
  echo "The working tree has $dirty modified or untracked files. Review only the files you were asked about; do not stash, checkout or reset."
fi

# One record per changed file: "rank lines added deleted path". Binary files count as 0 lines.
rank_of() {
  case "$1" in
    app/lib/data/*|tool/*|app/android/*|.github/*) echo 0 ;;
    app/lib/*) echo 1 ;;
    app/test/*) echo 2 ;;
    *) echo 3 ;;
  esac
}

records=""
paths=""
nl='
'
while IFS="$tab" read -r a d p; do
  [ -z "$p" ] && continue
  [ "$a" = "-" ] && a=0
  [ "$d" = "-" ] && d=0
  records="$records$(rank_of "$p") $((a + d)) $a $d $p$nl"
  paths="$paths$p$nl"
done <<EOF
$(git diff --numstat "$base" 2>/dev/null)
EOF

while IFS= read -r p; do
  [ -z "$p" ] && continue
  a="$(wc -l < "$p" 2>/dev/null | tr -d ' ')"
  a="${a:-0}"
  records="$records$(rank_of "$p") $a $a 0 $p$nl"
  paths="$paths$p$nl"
done <<EOF
$(git ls-files -o --exclude-standard)
EOF

echo
echo "## Changes (risk order)"
echo
if [ -z "$paths" ]; then
  echo "none"
else
  printf '%s' "$records" | sort -k1,1n -k2,2nr | while read -r rk total a d p; do
    echo "+$a -$d  $p"
  done
fi

lib_files=""
while IFS= read -r p; do
  case "$p" in
    app/lib/*.dart) lib_files="$lib_files$p$nl" ;;
  esac
done <<EOF
$paths
EOF

echo
echo "## Tests that name each changed lib file"
echo
if [ -z "$lib_files" ]; then
  echo "none"
else
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    name="$(basename "$p" .dart)"
    hits="$(grep -rlE --include='*.dart' "(^|[/'\" ])$name\\.dart" app/test 2>/dev/null | while read -r f; do basename "$f"; done | sort | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    echo "$p: ${hits:-none}"
  done <<EOF
$lib_files
EOF
fi

echo
echo "## Docs that name each changed file"
echo
if [ -z "$lib_files" ]; then
  echo "none"
else
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    name="$(basename "$p" .dart)"
    hits=""
    for f in docs/*.md; do
      [ -f "$f" ] || continue
      case "$f" in docs/REVIEW-*) continue ;; esac
      if grep -qE "(^|[^A-Za-z0-9_])$name\\.dart" "$f"; then
        hits="${hits:+$hits, }$(basename "$f")"
      fi
    done
    echo "$p: ${hits:-none}"
  done <<EOF
$lib_files
EOF
fi

echo
echo "## Removed type names still referenced"
echo
# Removed declarations from the diff, with the file that removed each. A name that an added line
# declares again (a type that moved or was edited in place) was not removed, so it is skipped.
decl='^[-+][[:space:]]*(abstract |final |sealed |base |interface )*(class|enum|mixin|typedef|extension type) +([A-Za-z_][A-Za-z0-9_]*)'
removed=""
added=""
cur=""
while IFS= read -r line; do
  case "$line" in
    "diff --git "*) cur="${line##* b/}"; continue ;;
    "---"*|"+++"*) continue ;;
  esac
  if [[ "$line" =~ $decl ]]; then
    n="${BASH_REMATCH[3]}"
    case "$line" in
      -*) removed="$removed$n $cur$nl" ;;
      +*) added="$added$n$nl" ;;
    esac
  fi
done <<EOF
$(git diff -U0 "$base" 2>/dev/null)
EOF

found=0
seen=""
while read -r n f; do
  [ -z "$n" ] && continue
  case "$nl$seen" in *"$nl$n$nl"*) continue ;; esac
  seen="$seen$n$nl"
  case "$nl$added" in *"$nl$n$nl"*) continue ;; esac
  refs="$(grep -rnw --include='*.dart' "$n" app/lib app/test 2>/dev/null | grep -v "^$f:")"
  if [ -n "$refs" ]; then
    found=1
    echo "### $n (removed from $f)"
    echo "$refs"
  fi
done <<EOF
$removed
EOF
[ "$found" -eq 0 ] && echo "none"

echo
echo "## Next"
echo
echo "1. Read each changed file with its callers, consumers of added values and its twin (SKILL.md section 2)."
echo "2. Apply the three lenses: bugs, UI/UX from code, maintainability (SKILL.md section 3)."
echo "3. Prove every P1/P2 in a clean copy (references/reproduce.md)."
exit 0
