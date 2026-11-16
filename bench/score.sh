#!/bin/bash
# bench/score.sh <expect.txt> <review-output> — prints `caught extra=N` or `missed extra=N`.
#   caught: the verdict is FAIL and one numbered line under `### Issues` contains the expected file's basename
#           (expect line 3; `|` separates acceptable files) and one expect line-2 keyword. Case-insensitive.
#   extra:  FAIL issue lines that do not match (false or additional findings); 0 when the verdict is not FAIL.
set -eu
[ $# -eq 2 ] && [ -f "$1" ] && [ -f "$2" ] || { echo "usage: score.sh <expect.txt> <review-output>" >&2; exit 2; }
lower() { tr '[:upper:]' '[:lower:]'; }
KEYS=$(sed -n 2p "$1" | lower)
FILES=$(sed -n 3p "$1" | tr '|' '\n' | sed 's#.*/##' | tr '\n' '|' | lower)
OUT=$(lower < "$2")

has_any() { # has_any <haystack> <a|b|c> — true if any non-empty |-separated needle is a substring
  local n rest="$2|"
  while [ -n "$rest" ]; do
    n=${rest%%|*}; rest=${rest#*|}
    [ -n "$n" ] && case "$1" in *"$n"*) return 0 ;; esac
  done
  return 1
}

CAUGHT=0; EXTRA=0
if printf '%s\n' "$OUT" | grep -q 'code review verdict:[^a-z]*fail'; then
  ISSUES=$(printf '%s\n' "$OUT" | awk '/^#+[ \t]*issues/ { on = 1; next } /^#/ { on = 0 } on && /^[ \t]*[0-9]+[.)]/')
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if has_any "$line" "$FILES" && has_any "$line" "$KEYS"; then CAUGHT=1; else EXTRA=$((EXTRA + 1)); fi
  done <<EOF
$ISSUES
EOF
fi
if [ "$CAUGHT" = 1 ]; then echo "caught extra=$EXTRA"; else echo "missed extra=$EXTRA"; fi
