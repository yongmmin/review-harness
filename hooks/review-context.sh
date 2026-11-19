#!/bin/bash
# review-context.sh [base]
# Prints where a review of the current change starts, as one block of at most 4,096 bytes (anything over is cut and
# followed by one `… truncated` line). The change is collected as static-gates.sh collects it (lib/collect-change.sh):
# with base, everything since the merge base of <base> and HEAD plus the working tree; without, staged, unstaged and
# untracked against HEAD. Renames are detected. Sections in this order; an empty one is `<section>: none`:
#   files:    `<A|M|D|R> path +added -removed` per changed path (a rename: `R old -> new`; a binary file: +0 -0); at
#             most 30, then `files: +N more`, so the symbols and callers fit in the block
#   symbols:  `<name> (<added|removed|changed>) in <path>` per name defined on an added or removed line (changed: on
#             both sides in the same file); removed first, then changed, then added; at most 25, then
#             `symbols: +N more`. JS/TS/Vue/Svelte: `export [default] [async] function|const|let|class|interface|type|enum
#             Name`, and at the start of a line `function Name(` and `[const|let|var] Name = (…) =>`; shell: `Name()`
#             and `function Name`; Python: `def Name` and `class Name` (dunder names skipped)
#   callers:  `<name>: path, path (test), +N more` per listed symbol: the other tracked or untracked files holding the
#             name as a whole word (git grep -lwIF), the defining file and docs excluded (*.md, *.mdx, *.rst, *.txt,
#             not requirements*/constraints*.txt or CMakeLists.txt, as in risk-tier.sh), at most 8; `none` when no
#             file does
#   tests:    the changed test files (*.test.*, *.spec.*, __tests__/, test/, tests/)
# The names are regex hints, not a parse. Reads only; the real index is never written. Needs git ≥ 2.25.
# Exit: 0, or 2 on a usage error, outside a git repo, or when an internal git command fails.

umask 077   # the temp index and diff copies hold repo content
ME=review-context
usage() { echo "usage: review-context.sh [base]${1:+ — $1}" >&2; exit 2; }
[ $# -le 1 ] || usage
case "${1:-}" in -*) usage "unknown option: $1" ;; esac
. "$(dirname "${BASH_SOURCE[0]}")/lib/collect-change.sh" || exit 2
collect_change "${1:-}"
g diff -U0 -M --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$FROM" -- > "$IDX.diff" 2> "$IDX.err" \
  || gitfail diff
TESTRE='[.](test|spec)[.]|(^|/)(__tests__|test|tests)/'

# awk prints `F<files line>`, `S<name>\t<kind>\t<path>` (removed, changed, added) and `T<test path>` records.
# LC_ALL=C: macOS awk in a UTF-8 locale aborts at a non-UTF-8 byte.
# shortcut: a path git quotes (a `"`, `\` or control character in it) is shown as git prints it and gets no symbols;
# rare in source trees.
LC_ALL=C awk -v tre="$TESTRE" '
  function lang(x) {
    if (x ~ /\.(js|jsx|ts|tsx|mjs|cjs|vue|svelte)$/) return "js"
    if (x ~ /\.(sh|bash)$/) return "sh"
    return x ~ /\.py$/ ? "py" : ""
  }
  # sym(t) — the name line t defines in a file of language L, or ""
  function sym(t,   s) {
    s = ""
    if (L == "js") {
      if (t ~ /^[ \t]*export[ \t]+(default[ \t]+)?(async[ \t]+)?(function|const|let|class|interface|type|enum)[ \t*]/) {
        s = t; sub(/^[ \t]*export[ \t]+(default[ \t]+)?(async[ \t]+)?(function|const|let|class|interface|type|enum)[ \t*]+/, "", s)
      } else if (t ~ /^(async[ \t]+)?function[ \t*]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*\(/) {
        s = t; sub(/^(async[ \t]+)?function[ \t*]+/, "", s)
      } else if (t ~ /^((const|let|var)[ \t]+)?[A-Za-z_$][A-Za-z0-9_$]*[ \t]*=[ \t]*(async[ \t]*)?\(.*=>/) {
        s = t; sub(/^(const|let|var)[ \t]+/, "", s)
      }
    } else if (L == "sh") {
      s = t; if (!sub(/^[ \t]*function[ \t]+/, "", s) && s !~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/) s = ""
      sub(/^[ \t]+/, "", s)
    } else if (L == "py") {
      s = t; if (!sub(/^[ \t]*((async[ \t]+)?def|class)[ \t]+/, "", s)) s = ""
    }
    if (!match(s, /^[A-Za-z_$][A-Za-z0-9_$]*/)) return ""
    s = substr(s, 1, RLENGTH)
    return s ~ /^__.*__$/ ? "" : s
  }
  function note(t, side,   nm, k) {
    if (L == "" || (nm = sym(t)) == "") return
    k = nm SUBSEP p
    if (!(k in seen)) { seen[k] = 1; ord[++ns] = k }
    if (side == "+") ad[k] = 1; else rm[k] = 1
  }
  function flush() {
    if (!started) return
    print "F" st " " (st == "R" ? old " -> " : "") p " +" (a + 0) " -" (r + 0)
    if (p ~ tre) tl[++nt] = p
  }
  /^diff --git / {
    flush(); started = 1; hdr = 1; st = "M"; a = r = 0
    # `diff --git a/X b/X`: X is the first half; a rename gets its paths from the rename lines below
    s = substr($0, 14); n = length(s); p = substr(s, 1, (n - 3) / 2)
    if (n % 2 == 0 || substr(s, (n - 3) / 2 + 1) != " b/" p) p = substr($0, 12)
    old = p; L = lang(p); next
  }
  hdr && /^new file mode/ { st = "A"; next }
  hdr && /^deleted file mode/ { st = "D"; next }
  hdr && /^rename from / { st = "R"; old = substr($0, 13); next }
  hdr && /^rename to / { p = substr($0, 11); L = lang(p); next }
  /^@@/ { hdr = 0; next }
  hdr { next }
  /^\+/ { a++; note(substr($0, 2), "+"); next }
  /^-/ { r++; note(substr($0, 2), "-") }
  END {
    flush()
    split("removed changed added", pass, " ")
    for (j = 1; j <= 3; j++) for (i = 1; i <= ns; i++) {
      k = ord[i]; kind = (k in ad) ? ((k in rm) ? "changed" : "added") : "removed"
      if (kind == pass[j]) { x = index(k, SUBSEP); print "S" substr(k, 1, x - 1) "\t" kind "\t" substr(k, x + 1) }
    }
    for (i = 1; i <= nt; i++) print "T" tl[i]
  }' "$IDX.diff" > "$IDX.names" || exit 2

files=; syms=; cals=; tests=; nf=0; ns=0
while IFS= read -r l; do
  case "$l" in
    F*) nf=$((nf + 1)); [ "$nf" -gt 30 ] || files="$files${l#F}"$'\n' ;;
    T*) tests="$tests${l#T}"$'\n' ;;
    S*)
      ns=$((ns + 1)); [ "$ns" -le 25 ] || continue
      l=${l#S}; name=${l%%$'\t'*}; l=${l#*$'\t'}; kind=${l%%$'\t'*}; path=${l#*$'\t'}
      syms="$syms$name ($kind) in $path"$'\n'
      c=$(g grep -lwIF --untracked -e "$name" 2> "$IDX.err"); [ $? -le 1 ] || gitfail grep   # 1: no match
      cals="$cals$name: $(printf '%s\n' "$c" | LC_ALL=C awk -v self="$path" -v tre="$TESTRE" '
        $0 == "" || $0 == self { next }
        { b = tolower($0); sub(/.*\//, "", b) }
        b ~ /\.(md|mdx|rst|txt)$/ && b !~ /^(requirements.*|constraints.*|cmakelists)\.txt$/ { next }   # prose, not a caller
        { if (++n <= 8) s = s (n > 1 ? ", " : "") $0 ($0 ~ tre ? " (test)" : "") }
        END { if (n > 8) s = s ", +" (n - 8) " more"; print (n ? s : "none") }')"$'\n' ;;
  esac
done < "$IDX.names"
[ "$nf" -le 30 ] || files="${files}files: +$((nf - 30)) more"$'\n'
[ "$ns" -le 25 ] || syms="${syms}symbols: +$((ns - 25)) more"$'\n'

sec() { if [ -n "$2" ]; then printf '%s:\n%s' "$1" "$2"; else printf '%s: none\n' "$1"; fi; }
# The cut keeps whole lines and leaves room for the 14-byte `… truncated` line.
{ sec files "$files"; sec symbols "$syms"; sec callers "$cals"; sec tests "$tests"; } | LC_ALL=C awk -v cap=4096 '
  { l[NR] = $0; n += length($0) + 1 }
  END {
    for (i = 1; i <= NR; i++) {
      if (n > cap && m + length(l[i]) + 1 > cap - 14) { print "… truncated"; exit }
      m += length(l[i]) + 1; print l[i]
    }
  }'
