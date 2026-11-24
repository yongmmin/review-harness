#!/bin/bash
# repo-rules.sh [path...] — per touched repo, its own rule files and the docs they link to. Reads only.
# Paths: each argument split at commas; backticks, blanks, a leading ./ and a glob tail (from the first *) dropped;
# relative to $PWD; a path that does not exist yet is resolved through its nearest existing ancestor.
# No arguments: the cwd repo's change (git diff HEAD + untracked; a repo without commits: ls-files + untracked).
# Per repo:  repo: <toplevel>
#            rules: <file> (<bytes> B)[ · auto-loaded]   (CLAUDE.md, .claude/CLAUDE.md, AGENTS.md, .claude/rules/*.md,
#                                                        and a CLAUDE.md between the root and a changed path) | rules: none
#            docs: N linked · M match the change
#            - match <doc> — <rule line> (every one)   then   - <doc> — <rule line> (at most 30, then +N more)
# auto-loaded = a root CLAUDE.md, .claude/CLAUDE.md or .claude/rules/*.md of the repo containing $PWD, which Claude Code
# loads for a session started there — so run this from the directory the session started in, before any cd.
# A doc is a markdown link target ending .md that exists and lies inside the repo by path (symlinks are not resolved,
# so a doc reached through an in-repo symlink can be listed, possibly twice); `match` = a backticked path token on its
# line equals a changed repo-relative path or is a directory of one. Lists facts only — the agents judge.
# Exit 0; 2 with one stderr line on a usage error, no repo, or an unreadable rule file.
fail() { echo "repo-rules: $1" >&2; exit 2; }
# Bytes everywhere: under a UTF-8 locale, bash 4+ `read` swallows the newline after a character the 200-byte cut split.
export LC_ALL=C
NL='
'
CWDTOP=$(git rev-parse --show-toplevel 2>/dev/null)
REPOS=""; RECS=""; OUTSIDE=""
add_rec() { # add_rec <top> <repo-relative path>
  case "$NL$REPOS$NL" in *"$NL$1$NL"*) ;; *) REPOS="$REPOS${REPOS:+$NL}$1" ;; esac
  RECS="$RECS$1	$2$NL"
}

if [ $# -eq 0 ]; then
  [ -n "$CWDTOP" ] || fail "not inside a git repo (pass paths, or run from a repo)"
  g() { git -C "$CWDTOP" -c core.quotePath=false "$@"; }
  if g rev-parse -q --verify HEAD >/dev/null 2>&1; then NAMES=$(g diff --name-only --no-renames HEAD) || fail "git diff failed"
  else NAMES=$(g ls-files) || fail "git ls-files failed"; fi
  UNTR=$(g ls-files --others --exclude-standard) || fail "git ls-files failed"
  REPOS=$CWDTOP
  RECS=$(printf '%s\n%s\n' "$NAMES" "$UNTR" | awk -v t="$CWDTOP" '$0 != "" { print t "\t" $0 }')
else
  ARGS=$(printf '%s\n' "$@" | tr ',' '\n' | LC_ALL=C awk '{
    gsub(/`/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
    while (substr($0, 1, 2) == "./") $0 = substr($0, 3)
    k = index($0, "*"); if (k) $0 = substr($0, 1, k - 1)
    sub(/\/+$/, "")
    if ($0 != "") print
  }')
  [ -n "$ARGS" ] || fail "usage: repo-rules.sh [path...] — no path left after normalizing the arguments"
  while IFS= read -r p; do
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    d=$p; tail=""
    while [ ! -d "$d" ]; do tail="${d##*/}${tail:+/$tail}"; d=${d%/*}; [ -n "$d" ] || d=/; done
    top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)
    pd=$(cd "$d" 2>/dev/null && pwd -P)
    case "$pd/" in
      "$top/"*) [ -n "$top" ] && { r=${pd#"$top"}; r=${r#/}; add_rec "$top" "$r${r:+${tail:+/}}$tail"; continue; } ;;
    esac
    OUTSIDE="$OUTSIDE${NL}outside a git repo: $p"
  done <<EOF
$ARGS
EOF
  [ -n "$REPOS" ] || fail "no path is inside a git repo:$(printf '%s' "$OUTSIDE" | sed 's/^outside a git repo://' | tr '\n' ' ')"
fi

OUT=""
while IFS= read -r top; do
  CHANGED=$(printf '%s' "$RECS" | awk -F'\t' -v t="$top" '$1 == t && $2 != "" { print $2 }')
  auto=""; [ "$top" = "$CWDTOP" ] && auto=" · auto-loaded"
  RULES=""; RLINES=""; RF=()
  addrule() { # addrule <abs file> <suffix>
    [ -r "$1" ] || fail "cannot read $1"
    RF[${#RF[@]}]=$1; RULES="$RULES$1$NL"; RLINES="${RLINES}rules: $1 ($(wc -c < "$1" | tr -d ' ') B)$2$NL"
  }
  [ -f "$top/CLAUDE.md" ] && addrule "$top/CLAUDE.md" "$auto"
  [ -f "$top/.claude/CLAUDE.md" ] && addrule "$top/.claude/CLAUDE.md" "$auto"
  [ -f "$top/AGENTS.md" ] && addrule "$top/AGENTS.md" ""
  for f in "$top"/.claude/rules/*.md; do [ -f "$f" ] && addrule "$f" "$auto"; done
  # a CLAUDE.md in each folder between the root and a changed path (the path itself when it is a folder): each folder
  # once (awk stops at a seen prefix); .claude is skipped, its CLAUDE.md is a root rule file
  NESTED=$(printf '%s\n' "$CHANGED" | LC_ALL=C awk '{
      p = $0
      while (p != "" && !(p in s)) { s[p]; print p; if (!sub(/\/[^\/]*$/, "", p)) p = "" }
    }' | while IFS= read -r c; do
    [ "$c" != .claude ] && [ -f "$top/$c/CLAUDE.md" ] && printf '%s\n' "$top/$c/CLAUDE.md"
  done | LC_ALL=C sort)
  while IFS= read -r f; do [ -n "$f" ] && addrule "$f" ""; done <<EOF
$NESTED
EOF
  OUT="${OUT}repo: $top$NL${RLINES:-rules: none$NL}"
  # links: <1 when a path token on the line matches the change> TAB <doc path, normalized> TAB <line, 200 bytes>.
  # The change comes on stdin after a sentinel line (so an empty change still reads as the first input), never via env
  # or argv, which overflow on thousands of paths. Each doc is printed once, plus once more if a later line matches.
  LINKS=""
  if [ -n "$RULES" ]; then
    LINKS=$({ printf '\001\n'; printf '%s\n' "$CHANGED"; } | LC_ALL=C awk '
      FNR == 1 { f++ }
      f == 1 {   # the change: each path and every folder above it
        p = $0; while (p != "" && p != "\001" && !(p in P)) { P[p]; if (!sub(/\/[^\/]*$/, "", p)) p = "" }
        next
      }
      {
        L = $0; gsub(/[[:space:]]+/, " ", L); sub(/^ /, "", L); sub(/ $/, "", L)
        if (index(L, "](") == 0) next
        m = 0; s = L
        while (!m && match(s, /`[^`]+`/)) {
          t = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
          if (!index(t, "/")) continue
          k = index(t, "*"); if (k) t = substr(t, 1, k - 1)
          sub(/\/+$/, "", t); while (substr(t, 1, 2) == "./") t = substr(t, 3)
          if (t != "" && t in P) m = 1
        }
        s = L; dir = FILENAME; sub(/\/[^\/]*$/, "", dir)
        while (match(s, /\]\([^)]*\)/)) {
          t = substr(s, RSTART + 2, RLENGTH - 3); s = substr(s, RSTART + RLENGTH)
          sub(/^[ <]+/, "", t); sub(/[ >].*$/, "", t); sub(/#.*$/, "", t)
          if (t == "" || tolower(t) ~ /^(https?|mailto):/ || tolower(t) !~ /\.md$/) continue
          # resolve . and .. by text: the rule files sit under the physical toplevel already
          n = split((substr(t, 1, 1) == "/" ? "" : dir "/") t, seg, "/"); o = 0
          for (i = 1; i <= n; i++) {
            if (seg[i] == "" || seg[i] == ".") continue
            if (seg[i] == "..") { if (o) o--; continue }
            out[++o] = seg[i]
          }
          a = ""; for (i = 1; i <= o; i++) a = a "/" out[i]
          if (!(a in seen) || (m && !(a in seenm))) { seen[a]; if (m) seenm[a]; print m "\t" a "\t" substr(L, 1, 200) }
        }
      }' - "${RF[@]}") || fail "cannot scan the rule files of $top"
  fi
  DOCS=$(printf '%s\n' "$LINKS" | while IFS='	' read -r m abs line; do
    [ -n "$abs" ] && [ -f "$abs" ] || continue
    case "$abs" in ("$top"/*) printf '%s\t%s\t%s\n' "$m" "$abs" "$line" ;; esac
  done | LC_ALL=C awk -F'\t' '
    !($2 in at) { n++; at[$2] = n; d[n] = $2; m[n] = $1; l[n] = $3; next }
    $1 == 1 && !m[at[$2]] { m[at[$2]] = 1; l[at[$2]] = $3 }
    END {
      for (i = 1; i <= n; i++) mc += m[i]
      printf "docs: %d linked · %d match the change\n", n, mc
      for (i = 1; i <= n; i++) if (m[i]) print "- match " d[i] " — " l[i]
      for (i = 1; i <= n; i++) if (!m[i] && shown < 30) { print "- " d[i] " — " l[i]; shown++ }
      if (n - mc > 30) print "+" (n - mc - 30) " more"
    }')
  # the 200-byte cut may split a character: iconv -c drops the partial tail (exit code ignored); without iconv the raw cut stands
  # an iconv that prints nothing must not drop the block: keep the raw cut then
  if command -v iconv >/dev/null 2>&1; then c=$(printf '%s\n' "$DOCS" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null); [ -n "$c" ] && DOCS=$c; fi
  OUT="$OUT$DOCS$NL"
done <<EOF
$REPOS
EOF
printf '%s' "$OUT"
[ -n "$OUTSIDE" ] && printf '%s\n' "${OUTSIDE#"$NL"}"
exit 0
