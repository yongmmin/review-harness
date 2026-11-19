#!/bin/bash
# strategy-file.sh [--status] — prints the absolute path of the repo's strategy file:
#   <home>/strategy/<repo-name>-<sha1(git common dir)[0:12]>.md   (home = REVIEW_HARNESS_HOME or ~/.review-harness)
# Keyed on the git common dir, so every worktree of one repo shares the file (state-dir.sh is per work tree).
# --status prints one line: `none`, or `present · Goal: <the Goal line, at most 80 bytes, whole characters>`.
# Outside a git repo: `none` with --status (exit 0), else exit 2. Never creates the file or its folder;
# the /strategy skill does.
STATUS=0
case "${1:-}" in
  --status) STATUS=1 ;;
  '') ;;
  *) echo "usage: strategy-file.sh [--status]" >&2; exit 2 ;;
esac
top=$(git rev-parse --show-toplevel 2>/dev/null)
# --git-common-dir may be relative to the top level on older git; resolve it from there
common=$([ -n "$top" ] && cd "$top" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
if [ -z "$common" ]; then
  [ "$STATUS" = 1 ] && { echo none; exit 0; }
  echo "strategy-file: not inside a git repo" >&2; exit 2
fi
# <repo>/.git → <repo>; a bare <repo>.git → <repo>
case "$common" in */.git) name=$(basename "$(dirname "$common")") ;; *) name=$(basename "$common" .git) ;; esac
# Same hash tool order as state-dir.sh (shasum: macOS, sha1sum: coreutils, cksum: POSIX).
if command -v shasum >/dev/null 2>&1; then sum=shasum
elif command -v sha1sum >/dev/null 2>&1; then sum=sha1sum
else sum=cksum; fi
file="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/strategy/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._\n-' '_')-$(printf '%s' "$common" | $sum | cut -d' ' -f1 | cut -c1-12).md"
[ "$STATUS" = 1 ] || { printf '%s\n' "$file"; exit 0; }
[ -e "$file" ] || { echo none; exit 0; }
[ -r "$file" ] || { echo "strategy-file: cannot read $file" >&2; exit 2; }
# Cut by bytes in every locale, then iconv -c drops a character split by the cut (its exit code is ignored);
# without iconv the raw cut stands.
goal=$(sed -n 's/^Goal:[[:space:]]*//p' "$file" | head -n 1 | head -c 80)
command -v iconv >/dev/null 2>&1 && goal=$(printf '%s' "$goal" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
printf 'present · Goal: %s\n' "${goal:--}"
