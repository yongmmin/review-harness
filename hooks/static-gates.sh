#!/bin/bash
# static-gates.sh [base]
# Reports the review rules a grep can decide, from the ADDED lines and changed paths of the current change.
#   With base: everything since the merge base of <base> and HEAD (commits, staged, unstaged) plus untracked files.
#   Without: staged, unstaged and untracked against HEAD; with no HEAD, every tracked or untracked file is added.
# One line per hit, `<hard|note> [category] path:line — rule`, nothing else (a path hit uses line 1):
#   hard [ops]      console.log( in a JS/TS/Vue/Svelte file that is not a test
#   hard [security] a .env / .env.* file (names ending in .example/.sample/.template pass)
#   hard [security] process.env.NAME || or ?? followed by a non-empty string literal, NAME secret-like
#                   (SECRET, TOKEN, PASSWORD, PASSWD, KEY, WEBHOOK, CREDENTIAL, PRIVATE; any case); other names → note
#   note [goal]     TODO, FIXME or XXX (whole word)
#   note [goal]     a new export whose name no other tracked or untracked file mentions (whole word)
# Deleted files, removed lines, binary files and nested repos are never reported. Reads only; no network;
# the real index is never written (untracked files are added intent-to-add in a temporary copy).
# Exit: 1 when any hard hit, else 0; 2 on a usage error or outside a git repo.

usage() { echo "usage: static-gates.sh [base]${1:+ — $1}" >&2; exit 2; }
[ $# -le 1 ] || usage
case "${1:-}" in -*) usage "unknown option: $1" ;; esac
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "static-gates: not a git repository" >&2; exit 2; }
cd "$ROOT" || exit 2
g() { git -c core.quotePath=false "$@"; }

if [ -n "${1:-}" ]; then
  FROM=$(git merge-base "$1" HEAD 2>/dev/null) || usage "no merge base with HEAD: $1"
elif git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  FROM=HEAD
else
  FROM=$(git hash-object -t tree /dev/null)   # the empty tree: every tracked file is added
fi

# One diff covers untracked files too: they are added intent-to-add in a copy of the index.
IDX=$(mktemp "${TMPDIR:-/tmp}/static-gates.XXXXXX") || exit 2
trap 'rm -f "$IDX" "$IDX.lock"' EXIT
REAL_IDX=$(git rev-parse --git-path index)
if [ -f "$REAL_IDX" ]; then cp "$REAL_IDX" "$IDX"; else rm -f "$IDX"; fi   # an empty file is not a valid index
export GIT_INDEX_FILE="$IDX"
# entries ending in `/` are nested repos or worktrees
g ls-files -z --others --exclude-standard | while IFS= read -r -d '' f; do
  case "$f" in */) ;; *) printf '%s\0' "$f" ;; esac
done | git --literal-pathspecs add -N --pathspec-from-file=- --pathspec-file-nul 2>/dev/null

HARD=0
while IFS= read -r -d '' p; do
  case "${p##*/}" in
    *.example|*.sample|*.template) ;;
    .env|.env.*) echo "hard [security] $p:1 — .env file in the change"; HARD=1 ;;
  esac
done < <(g diff -z --name-only --diff-filter=d "$FROM" --)

# awk prints hit lines, and `E<TAB>path<TAB>line<TAB>name` for each new export; the caller check is a git grep below.
# Header lines run from `diff ` to the first `@@`, so an added line whose text starts with `++` is never a header.
# Context lines (diff.interHunkContext can add them even with -U0) advance the line number.
# shortcut: a path git quotes (a `"`, `\` or control character in it) keeps its quotes, so it fails the extension
# test and the console.log and export checks skip it; rare in source trees.
while IFS= read -r line; do
  case "$line" in
    E$'\t'*)
      rest=${line#E$'\t'}; name=${rest##*$'\t'}; rest=${rest%$'\t'*}; ln=${rest##*$'\t'}; f=${rest%$'\t'*}
      g grep -lwIF --untracked -e "$name" | grep -qvxF -- "$f" \
        || echo "note [goal] $f:$ln — new export with no caller: $name" ;;
    hard\ *) echo "$line"; HARD=1 ;;
    *) echo "$line" ;;
  esac
done < <(g diff -U0 --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$FROM" -- | awk -v sq="'" '
  BEGIN {
    fallback = "process\\.env\\.[A-Za-z_][A-Za-z0-9_]*[ \t]*(\\|\\||\\?\\?)[ \t]*(" sq "[^" sq "]|\"[^\"]|`[^`])"
    sep = " — "
  }
  /^diff / { hdr = 1; f = ""; next }
  hdr && /^\+\+\+ / {
    f = substr($0, 5); sub(/\t$/, "", f)
    if (f == "/dev/null") f = ""; else sub(/^b\//, "", f)
    next
  }
  /^@@/ { hdr = 0; match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
  !hdr && /^ / { n++; next }
  hdr || f == "" || !/^\+/ { next }
  {
    t = substr($0, 2)
    js = f ~ /\.(js|jsx|ts|tsx|mjs|cjs|vue|svelte)$/
    test = f ~ /\.(test|spec)\./ || f ~ /(^|\/)(__tests__|test|tests)\//
    if (js && !test && index(t, "console.log(")) print "hard [ops] " f ":" n sep "no console.log in production code"
    if (match(t, fallback)) {
      name = substr(t, RSTART + 12); match(name, /^[A-Za-z0-9_]+/); name = toupper(substr(name, 1, RLENGTH))
      if (name ~ /SECRET|TOKEN|PASSWORD|PASSWD|KEY|WEBHOOK|CREDENTIAL|PRIVATE/) print "hard [security] " f ":" n sep "secret fallback literal"
      else print "note [security] " f ":" n sep "literal fallback for an env var"
    }
    if (t ~ /(^|[^A-Za-z0-9_])(TODO|FIXME|XXX)([^A-Za-z0-9_]|$)/) print "note [goal] " f ":" n sep "TODO/FIXME/XXX left in the change"
    if (js && t ~ /^[ \t]*export[ \t]/) {
      s = t; sub(/^[ \t]*export[ \t]+/, "", s)
      if (s ~ /^default[ \t]+function[ \t]+/) sub(/^default[ \t]+function[ \t]+/, "", s)
      else if (s ~ /^(async[ \t]+)?(function|const|let|class|interface|type|enum)[ \t]+/) sub(/^(async[ \t]+)?(function|const|let|class|interface|type|enum)[ \t]+/, "", s)
      else s = ""
      if (match(s, /^[A-Za-z_$][A-Za-z0-9_$]*/)) print "E\t" f "\t" n "\t" substr(s, 1, RLENGTH)
    }
    n++
  }')

exit $HARD
