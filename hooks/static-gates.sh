#!/bin/bash
# static-gates.sh [base]
# Reports the review rules a grep can decide, from the ADDED lines and changed paths of the current change.
#   With base: everything since the merge base of <base> and HEAD (commits, staged, unstaged) plus untracked files.
#   Without: staged, unstaged and untracked against HEAD; with no HEAD, every tracked or untracked file is added.
# One line per hit, `<hard|note> [category] path:line — rule`, nothing else (a path hit uses line 1):
#   hard [ops]      console.log( in a JS/TS/Vue/Svelte file that is not a test
#   hard [security] a .env / .env.* file (names ending in .example/.sample/.template pass)
#   hard [security] process.env.NAME || or ?? followed by a non-empty string literal, NAME secret-like: a segment
#                   (split on `_`, and on camelCase when NAME has lower case) is [API]KEY, or ends in SECRET, TOKEN,
#                   PASSWORD, PASSWD, WEBHOOK, CREDENTIAL or PRIVATE, each with an optional plural S and trailing
#                   digits (any case: APIKEY, API_KEYS, X_API_KEY2, AUTH_TOKENS hard; HOTKEY, KEYCLOAK, TOKENIZER
#                   not); other names → note. Every fallback on a line counts; one hit per line, hard when any is
#                   secret-like
#   note [goal]     TODO, FIXME or XXX (whole word)
#   note [goal]     a new export whose name no other tracked or untracked file mentions (whole word)
# Deleted files, removed lines, binary files and nested repos are never reported. Reads only; no network;
# the real index is never written (untracked files are added intent-to-add in a temporary copy).
# Needs git ≥ 2.25 (--pathspec-from-file).
# Exit: 1 when any hard hit, else 0; 2 on a usage error, outside a git repo, or when an internal git command fails
# (for example an unreadable untracked file): git's error, then one line naming the command.

umask 077   # the temp index and diff copies hold repo content
usage() { echo "usage: static-gates.sh [base]${1:+ — $1}" >&2; exit 2; }
# git's stderr is kept in $IDX.err and shown only on failure (add -N with nothing untracked is chatty).
gitfail() { cat "$IDX.err" >&2 2>/dev/null; echo "static-gates: git $1 failed (see the git error above)" >&2; exit 2; }
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
trap 'rm -f "$IDX" "$IDX.lock" "$IDX.names" "$IDX.diff" "$IDX.err"' EXIT
REAL_IDX=$(git rev-parse --git-path index)
if [ -f "$REAL_IDX" ]; then cp "$REAL_IDX" "$IDX"; else rm -f "$IDX"; fi   # an empty file is not a valid index
export GIT_INDEX_FILE="$IDX"
# git ≥ 2.34 refuses an untracked path outside a sparse-checkout cone unless --sparse is given (older git has
# neither the check nor the option). Option names in `-h` are never translated.
SPARSE=(); git add -h 2>&1 | grep -qE -- '--(\[no-\])?sparse' && SPARSE=(--sparse)
# entries ending in `/` are nested repos or worktrees
g ls-files -z --others --exclude-standard | while IFS= read -r -d '' f; do
  case "$f" in */) ;; *) printf '%s\0' "$f" ;; esac
done | git --literal-pathspecs add -N ${SPARSE[@]+"${SPARSE[@]}"} --pathspec-from-file=- --pathspec-file-nul 2> "$IDX.err" \
  || gitfail "add -N"
# Both diffs go to files first: a failure inside a process substitution would look like an empty, clean change.
g diff -z --name-only --diff-filter=d "$FROM" -- > "$IDX.names" 2> "$IDX.err" || gitfail diff
g diff -U0 --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$FROM" -- > "$IDX.diff" 2> "$IDX.err" \
  || gitfail diff

HARD=0
while IFS= read -r -d '' p; do
  case "${p##*/}" in
    *.example|*.sample|*.template) ;;
    .env|.env.*) echo "hard [security] $p:1 — .env file in the change"; HARD=1 ;;
  esac
done < "$IDX.names"

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
# LC_ALL=C: macOS awk in a UTF-8 locale aborts at a non-UTF-8 byte, which would end the parse with exit 0.
done < <(LC_ALL=C awk -v sq="'" '
  # secret(name) — 1 when a segment of name is [API]KEY or ends in a secret word, each with an optional S and digits
  # (KEY only as the whole segment: HOTKEY, MONKEY, KEYCLOAK are notes)
  function secret(nm,   s, i, c, segs, k) {
    s = nm
    if (nm ~ /[a-z]/) {   # camelCase: split before an upper-case letter after a lower-case letter or digit, or
      s = ""              # before the last capital of an acronym (APIKey → API_Key)
      for (i = 1; i <= length(nm); i++) {
        c = substr(nm, i, 1)
        if (i > 1 && c ~ /[A-Z]/ && (substr(nm, i - 1, 1) ~ /[a-z0-9]/ || (substr(nm, i - 1, 1) ~ /[A-Z]/ && substr(nm, i + 1, 1) ~ /[a-z]/))) s = s "_"
        s = s c
      }
    }
    for (k = split(toupper(s), segs, "_"); k > 0; k--)
      if (segs[k] ~ /^(API)?KEYS?[0-9]*$/ || segs[k] ~ /(SECRET|TOKEN|PASSWORD|PASSWD|WEBHOOK|CREDENTIAL|PRIVATE)S?[0-9]*$/) return 1
    return 0
  }
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
    found = hard = 0; r = t
    while (match(r, fallback)) {
      found = 1; name = substr(r, RSTART + 12); r = substr(r, RSTART + RLENGTH)
      match(name, /^[A-Za-z0-9_]+/); if (secret(substr(name, 1, RLENGTH))) hard = 1
    }
    if (hard) print "hard [security] " f ":" n sep "secret fallback literal"
    else if (found) print "note [security] " f ":" n sep "literal fallback for an env var"
    if (t ~ /(^|[^A-Za-z0-9_])(TODO|FIXME|XXX)([^A-Za-z0-9_]|$)/) print "note [goal] " f ":" n sep "TODO/FIXME/XXX left in the change"
    if (js && t ~ /^[ \t]*export[ \t]/) {
      s = t; sub(/^[ \t]*export[ \t]+/, "", s)
      if (s ~ /^default[ \t]+function[ \t]+/) sub(/^default[ \t]+function[ \t]+/, "", s)
      else if (s ~ /^(async[ \t]+)?(function|const|let|class|interface|type|enum)[ \t]+/) sub(/^(async[ \t]+)?(function|const|let|class|interface|type|enum)[ \t]+/, "", s)
      else s = ""
      if (match(s, /^[A-Za-z_$][A-Za-z0-9_$]*/)) print "E\t" f "\t" n "\t" substr(s, 1, RLENGTH)
    }
    n++
  }' "$IDX.diff")

exit $HARD
