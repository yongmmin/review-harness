#!/bin/bash
# find-consumers.sh <term...>
# Read-only. For a breaking contract change (renamed/removed/now-optional route, socket event or field):
# searches every repo in the registry detect-repo.sh reads, except the one containing $PWD, for each term
# (literal; whole-word when the term starts and ends with a word character, so a route still matches
# inside a URL) and prints one line per hit:
#   <repo>: <path>:<line>: <trimmed text>
# At most 20 hits per repo, then `<repo>: +N more`; `<repo>: no match`; `<repo>: local_path not found: <path>`.
# Skips node_modules, .git, dist, build, .next, out, coverage, storybook-static (rg also skips gitignored and hidden files).
# No registry or no other repo → one notice line. Exit 0; no term → exit 2.

[ $# -gt 0 ] || { echo "usage: find-consumers.sh <term...>" >&2; exit 2; }
RH_HOME="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}"
REPOS_FILE=$(ls "$RH_HOME"/knowledge/*/repos.md 2>/dev/null | head -n 1)
REPOS_FILE="${REPOS_FILE:-$RH_HOME/knowledge/repos.md}"
[ -f "$REPOS_FILE" ] || { echo "find-consumers: no repo registry ($REPOS_FILE) — consumers not searched"; exit 0; }
CWD=$(pwd)
MAX=20
SKIP="node_modules .git dist build .next out coverage storybook-static"

# File-derived text stays on one line with no backticks, control characters or Unicode bidi controls
# (U+202A–U+202E, U+2066–U+2069 as UTF-8 bytes); same hygiene as scan-repo.sh.
BIDI1=$(printf '\342\200[\252-\256]'); BIDI2=$(printf '\342\201[\246-\251]')
clean() { LC_ALL=C tr -d '\000-\010\013-\037\177`' | LC_ALL=C sed -e "s/$BIDI1//g" -e "s/$BIDI2//g"; }

WORD=(); LIT=()
for t in "$@"; do
  case "$t" in
    "") ;;
    [A-Za-z0-9_]|[A-Za-z0-9_]*[A-Za-z0-9_]) WORD+=(-e "$t") ;;
    *) LIT+=(-e "$t") ;;
  esac
done
[ $((${#WORD[@]} + ${#LIT[@]})) -gt 0 ] || { echo "usage: find-consumers.sh <term...> (terms must not be empty)" >&2; exit 2; }
HAS_RG=0; command -v rg >/dev/null 2>&1 && HAS_RG=1
tool() { # tool <dir> [-w] -e <term>... → ./path:line:text
  local d="$1" a=(); shift
  if [ "$HAS_RG" = 1 ]; then
    for s in $SKIP; do a+=(-g "!$s/"); done
    (cd "$d" && rg --no-config --color never --no-heading -n -F "${a[@]}" "$@" . 2>/dev/null)
  else
    for s in $SKIP; do a+=(--exclude-dir="$s"); done
    (cd "$d" && grep -rnIF --color=never "${a[@]}" "$@" . 2>/dev/null)
  fi
}
search() { # search <dir> → ./path:line:text, unsorted; a line hit by both kinds of term comes twice
  [ ${#WORD[@]} -gt 0 ] && tool "$1" -w "${WORD[@]}"
  [ ${#LIT[@]} -gt 0 ] && tool "$1" "${LIT[@]}"
  return 0
}

FOUND=0
# name<TAB>local_path per registered repo, same parsing as detect-repo.sh
while IFS="$(printf '\t')" read -r name path; do
  [ -z "$path" ] && continue
  [ "$CWD" = "$path" ] && continue
  case "$CWD" in "$path"/*) continue ;; esac
  FOUND=1
  name=$(printf '%s' "$name" | clean)
  if [ ! -d "$path" ]; then echo "$name: local_path not found: $path"; continue; fi
  # shortcut: a ':' inside a file path splits it wrongly; the line is still printed.
  # shortcut: the 160-byte cap can split a multi-byte character (mawk and some BSD awk builds count bytes); cut by characters when it matters.
  search "$path" | sort -u -t: -k1,1 -k2,2n | clean | awk -v n="$name" -v max="$MAX" '
    { sub(/^\.\//, ""); i = index($0, ":"); f = substr($0, 1, i - 1); r = substr($0, i + 1)
      j = index(r, ":"); ln = substr(r, 1, j - 1); t = substr(r, j + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", t); gsub(/\t/, " ", t)
      if (length(t) > 160) t = substr(t, 1, 160) "..."
      if (NR <= max) print n ": " f ":" ln ": " t }
    END { if (NR == 0) print n ": no match"; else if (NR > max) print n ": +" NR - max " more" }'
done <<EOF
$(awk '/^### / { repo = $0; sub(/^### */, "", repo); next }
  /^- \*\*local_path\*\*:/ { if (match($0, /`[^`]+`/)) print repo "\t" substr($0, RSTART + 1, RLENGTH - 2) }' "$REPOS_FILE")
EOF

[ "$FOUND" = 1 ] || echo "find-consumers: no other registered repo in $REPOS_FILE — consumers not searched"
exit 0
