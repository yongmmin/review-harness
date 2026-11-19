#!/bin/bash
# audit-rules.sh
# Prints checkable facts about rule drift, one line per finding: `<kind> <location> — <reason>`.
# Reads $REVIEW_HARNESS_HOME (default ~/.review-harness) and the plugin's constraints.md and profiles/*.md.
# Home files are shown relative to that home, plugin files as `<plugin>/...`.
#   stale-version  a registry `stack` token `<Name> <major>[.x]` whose major differs from the repo's package.json
#                  (dependencies, then devDependencies; a 0.x version compares major.minor; a range uses its first
#                  part and is noted; workspace:, *, tags and URLs are skipped). Names: Next, React, TS/TypeScript,
#                  NestJS, Prisma, Tailwind, Zustand, Three, Storybook, Vite, Express; other names are skipped
#   missing-path   a registry `local_path` that does not exist
#   version-rule   an org overlay or plugin profile line (outside code fences) naming one of those frameworks, spelled
#                  as one (a capital, a .js suffix or backticks), with a version some registered repo does not run (`N+`
#                  only flags repos below N); the reason lists every registered repo's version, `(=)` or `(≠)` — a
#                  candidate to judge
#   duplicate      the same `- ` bullet (whitespace-normalised, 30+ chars) in two or more rule files
#   budget         the non-profile part of extract-constraints.sh for an agent over its warn threshold (location =
#                  the agent name; one run per agent without a profile, since that part is the same for every profile)
#   ledger-size    failure-patterns.md over 3,072 bytes
#   ledger-old     a ledger entry dated more than 90 days before today (REVIEW_HARNESS_TODAY=YYYY-MM-DD overrides)
#   ledger-unloaded  ledger entries with no `## #failure-patterns` heading: extract-constraints.sh passes none of them
# Org overlay = org/constraints.md and org/{agents,skills,profiles}/*.md, the files agents and skills load.
# Reads only; never writes (no temp files, no here-strings). Findings print as found. Missing folders mean no findings. jq is optional.
# Exit: 0 no findings, 1 findings, 2 usage error or internal failure (an unreadable file, a failed parse): one stderr
# line, findings printed before it stay printed.

usage() { echo "usage: audit-rules.sh${1:+ — $1}" >&2; exit 2; }
die() { echo "audit-rules: $1" >&2; exit 2; }
[ $# -eq 0 ] || usage "takes no arguments"
TODAY="${REVIEW_HARNESS_TODAY:-$(date +%Y-%m-%d)}"
case "$TODAY" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) usage "REVIEW_HARNESS_TODAY must be YYYY-MM-DD" ;; esac
set -o pipefail
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RH_HOME="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}"
LEDGER="$RH_HOME/failure-patterns.md"
LEDGER_LIMIT=3072
export LC_ALL=C   # macOS awk in a UTF-8 locale aborts at the first non-UTF-8 byte

# Same registry files and order as detect-repo.sh.
REPOS_FILES=()
for f in "$RH_HOME"/knowledge/*/repos.md "$RH_HOME/knowledge/repos.md"; do
  [ -f "$f" ] || continue
  [ -r "$f" ] || die "cannot read $f"
  REPOS_FILES+=("$f")
done
RULE_FILES=()   # order: plugin constraints, plugin profiles, org overlay, ledger
for f in "$PLUGIN_DIR/constraints.md" "$PLUGIN_DIR"/profiles/*.md "$RH_HOME/org/constraints.md" \
  "$RH_HOME"/org/agents/*.md "$RH_HOME"/org/skills/*.md "$RH_HOME"/org/profiles/*.md "$LEDGER"; do
  [ -f "$f" ] || continue
  [ -r "$f" ] || die "cannot read $f"
  RULE_FILES+=("$f")
done

# package.json → `name<TAB>version` lines, dependencies first, then devDependencies.
deps() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '(.dependencies // {}), (.devDependencies // {}) | to_entries[] | "\(.key)\t\(.value)"' "$1"
  else
    # shortcut: reads at most one dependencies block per line (npm's own formatting is one key per line); a fully
    # minified package.json with both blocks on one line loses the second.
    awk 'function pairs(s,   q) {
        while (match(s, /"[^"]+"[ \t]*:[ \t]*"[^"]*"/)) { split(substr(s, RSTART, RLENGTH), q, "\""); print q[2] "\t" q[4]; s = substr(s, RSTART + RLENGTH) }
      }
      { line = $0 }
      !d && match(line, /"(dependencies|devDependencies)"[ \t]*:[ \t]*\{/) { line = substr(line, RSTART + RLENGTH); d = 1 }
      d { if ((i = index(line, "}")) > 0) { line = substr(line, 1, i - 1); d = 0 }; pairs(line) }' "$1"
  fi
}

# Registry blocks → `B<TAB>file<TAB>repo<TAB>path line<TAB>path<TAB>stack line<TAB>stack` per block with a local_path
# (repo `-` when the local_path comes before any `### ` heading of its file).
BLOCKS=""
if [ ${#REPOS_FILES[@]} -gt 0 ]; then
  BLOCKS=$(awk '
    function flush() { if (path != "") print "B\t" file "\t" (repo == "" ? "-" : repo) "\t" pl "\t" path "\t" sl "\t" stack; path = stack = ""; sl = 0 }
    FNR == 1 { flush(); file = FILENAME; repo = "" }
    /^### / { flush(); repo = $2; next }
    /^- \*\*local_path\*\*:/ { if (match($0, /`[^`]+`/)) { path = substr($0, RSTART + 1, RLENGTH - 2); pl = FNR } }
    /^- \*\*stack\*\*:/ { stack = $0; sub(/^- \*\*stack\*\*:[ \t]*/, "", stack); gsub(/\t/, " ", stack); sl = FNR }
    END { flush() }' "${REPOS_FILES[@]}") || die "cannot parse the registry"
fi

# `M<TAB>file<TAB>repo<TAB>path line<TAB>path` per missing path, `V<TAB>path<TAB>package<TAB>version` per dependency.
REPO_FACTS=$(printf '%s\n' "$BLOCKS" | while IFS=$'\t' read -r tag file repo pl path _; do
  [ "$tag" = B ] || continue
  if [ ! -e "$path" ]; then
    printf 'M\t%s\t%s\t%s\t%s\n' "$file" "$repo" "$pl" "$path"
  elif [ -f "$path/package.json" ]; then
    [ -r "$path/package.json" ] || die "cannot read $path/package.json"
    deps "$path/package.json" | awk -v p="$path" '{ print "V\t" p "\t" $0 }' || die "cannot parse $path/package.json"
  fi
done) || exit 2

LEDGER_BYTES=0
[ -f "$LEDGER" ] && { LEDGER_BYTES=$(wc -c < "$LEDGER" | tr -d ' ') || die "cannot read $LEDGER"; }

# Findings go out as they are found; the last awk counts them for the exit code.
{
printf '%s\n%s\n' "$BLOCKS" "$REPO_FACTS" | awk -v home="$RH_HOME/" -v plugin="$PLUGIN_DIR/" -v ledger="$LEDGER" -v today="$TODAY" \
  -v lbytes="$LEDGER_BYTES" -v llimit="$LEDGER_LIMIT" '
  function canon(w) {
    w = tolower(w); sub(/^[^a-z0-9]+/, "", w); sub(/[^a-z0-9]+$/, "", w); sub(/\.js$/, "", w)
    if (w == "ts") return "typescript"
    if (w == "tailwindcss") return "tailwind"
    return (w in pkgs) ? w : ""
  }
  # ver(v): fills V["maj"], V["min"], V["shown"], V["range"]; 0 when v is not a version
  function ver(v,   first, p) {
    first = v; sub(/^[ \t^~>=<v]+/, "", first)
    V["range"] = (first ~ /[ \t|]/) ? v : ""   # `^14 || ^15`, `>=14 <16`, `14 - 15`: the first part counts
    if (!match(first, /^[0-9]+(\.[0-9x]+)*/)) return 0
    V["shown"] = substr(first, 1, RLENGTH)
    split(V["shown"], p, "."); V["maj"] = p[1] + 0; V["min"] = p[2] + 0
    return 1
  }
  function key(maj, min) { return maj == 0 ? "0." min : maj }
  function rel(f) { if (index(f, home) == 1) return substr(f, length(home) + 1); if (index(f, plugin) == 1) return "<plugin>/" substr(f, length(plugin) + 1); return f }
  function days(d,   y, m, dd, era, yoe, doy) {   # days from civil (proleptic Gregorian)
    y = substr(d, 1, 4) + 0; m = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
    if (m <= 2) y--
    era = int(y / 400); yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + dd - 1
    return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  }
  # tokens(s): words of s; a `**Name**` or `Name,` keeps its name; backticks stay (version-rule reads them)
  function tokens(s) { gsub(/[,()*]/, " ", s); return split(s, W, /[ \t]+/) }
  # actual(b, c): the first package.json version of framework c in block b, or ""
  function actual(b, c,   n, ps, j) {
    n = split(pkgs[c], ps, ",")
    for (j = 1; j <= n; j++) if ((Bp[b], ps[j]) in dep) return dep[Bp[b], ps[j]]
    return ""
  }
  function stale(   b, nt, i, c, v, a, sm, sn) {
    if (staled++) return
    for (b = 1; b <= nb; b++) {
      if (Bsl[b] == 0) continue
      nt = tokens(Bs[b])
      for (i = 1; i < nt; i++) {
        gsub(/`/, "", W[i]); gsub(/`/, "", W[i + 1])
        c = canon(W[i]); v = W[i + 1]
        if (c == "" || v !~ /^v?[0-9]+(\.[0-9x]+)*$/) continue
        a = actual(b, c)
        if (a == "" || a ~ /^(workspace:|\*)/ || !ver(v)) continue
        sm = V["maj"]; sn = V["min"]
        if (!ver(a)) continue
        if (key(V["maj"], V["min"]) != key(sm, sn))
          printf "stale-version %s:%s%s%s: stack says %s %s, package.json has %s%s\n", Bf[b], Bsl[b], sep, Br[b], W[i], v, V["shown"], (V["range"] != "" ? " (range: " V["range"] ")" : "")
      }
    }
  }
  BEGIN {
    n = split("next:next react:react typescript:typescript nestjs:@nestjs/core prisma:prisma,@prisma/client tailwind:tailwindcss zustand:zustand three:three storybook:storybook vite:vite express:express", m, " ")
    for (i = 1; i <= n; i++) { split(m[i], kv, ":"); pkgs[kv[1]] = kv[2] }
    sep = " — "
  }
  # --- repo facts (stdin, always the first input; FILENAME for stdin differs between awks) --------
  NR == FNR {
    split($0, f, "\t")
    if (f[1] == "B") { nb++; Bf[nb] = rel(f[2]); Br[nb] = f[3]; Bp[nb] = f[5]; Bsl[nb] = f[6]; Bs[nb] = f[7] }
    else if (f[1] == "M") print "missing-path " rel(f[2]) ":" f[4] sep f[3] ": " f[5] " not found"
    else if (f[1] == "V") { k = f[2] SUBSEP f[3]; if (!(k in dep)) dep[k] = f[4] }
    next
  }
  # --- rule files ----------------------------------------------------------------------------
  FNR == 1 { stale(); fence = 0; isled = (FILENAME == ledger); isver = !isled && index(FILENAME, plugin "constraints.md") != 1 }
  isled && $0 == "## #failure-patterns" { lhead = 1 }
  /^[ \t]*```/ { fence = !fence; next }
  isled && /^- / { lentries++ }
  isled && /^- \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ {
    d = substr($0, 4, 10); age = days(today) - days(d)
    if (age > 90) print "ledger-old " rel(FILENAME) ":" FNR sep "dated " d ", " age " days old (GC limit 90)"
  }
  /^[ \t]*- / {
    t = $0; gsub(/[ \t]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
    if (length(t) >= 30 && !((t, FILENAME) in dseen)) {
      dseen[t, FILENAME] = 1
      if (!(t in dloc)) { dorder[++nd] = t; dloc[t] = rel(FILENAME) ":" FNR }
      else { dmore[t] = dmore[t] (dmore[t] == "" ? "" : ", ") rel(FILENAME) ":" FNR }
    }
  }
  # Framework spelling only (a capital, a .js suffix or backticks), so "the next 3 steps" is no rule.
  isver && !fence {
    nt = tokens($0)
    for (i = 1; i < nt; i++) {
      w = W[i]; v = W[i + 1]
      if (!(w ~ /`/ || w ~ /^[^A-Za-z0-9]*[A-Z]/ || tolower(w) ~ /\.js[^a-z0-9]*$/)) continue
      gsub(/`/, "", w); gsub(/`/, "", v)
      c = canon(w)
      if (c == "" || v !~ /^v?[0-9]+(\.[0-9x]+)*\+?[.;:]?$/) continue
      sub(/[.;:]$/, "", v); plus = (v ~ /\+$/)
      if ((FILENAME, FNR, w " " v) in vseen) continue
      vseen[FILENAME, FNR, w " " v] = 1
      ver(v); sm = V["maj"]; sn = V["min"]; repos = ""; differs = 0; split("", shown)
      for (b = 1; b <= nb; b++) {
        if ((Br[b], c) in shown || !ver(actual(b, c))) continue
        shown[Br[b], c] = 1
        bad = plus ? (V["maj"] < sm || (sm == 0 && V["maj"] == 0 && V["min"] < sn)) : key(V["maj"], V["min"]) != key(sm, sn)
        differs += bad
        repos = repos (repos == "" ? "" : ", ") Br[b] " " V["shown"] (bad ? " (≠)" : " (=)")
      }
      if (differs) print "version-rule " rel(FILENAME) ":" FNR sep "names " w " " v "; repos: " repos
    }
  }
  END {
    stale()
    for (i = 1; i <= nd; i++) if (dmore[dorder[i]] != "") print "duplicate " dloc[dorder[i]] sep "also in " dmore[dorder[i]]
    if (lentries && !lhead) print "ledger-unloaded " rel(ledger) sep lentries " entries but no \"## #failure-patterns\" heading, so extract-constraints.sh passes none to any agent"
    if (lbytes + 0 > llimit + 0) print "ledger-size " rel(ledger) sep lbytes " bytes, over the " llimit " GC limit"
  }' - ${RULE_FILES[@]+"${RULE_FILES[@]}"} || die "rule scan failed"

# budget: the warn line of extract-constraints.sh per agent; the non-profile part it measures is the same for every
# profile, so one run without a profile is enough.
for agent in developer reviewer test-runner refactor-architect; do
  err=$(bash "$PLUGIN_DIR/hooks/extract-constraints.sh" "$agent" 2>&1 >/dev/null) || die "extract-constraints.sh $agent failed"
  line=$(printf '%s\n' "$err" | sed -n 's/^\[token-budget\]\[warn\] extract-constraints [^:]*: \([0-9]*\) bytes (~\([0-9]*\) tokens) exceeds \([0-9]*\).*/\1 bytes (~\2 tokens), over the \3 budget (non-profile part)/p')
  [ -z "$line" ] || echo "budget $agent — extract-constraints: $line"
done
} | awk '{ print; n++ } END { exit n ? 1 : 0 }'
ST=("${PIPESTATUS[@]}")
[ "${ST[0]}" -eq 0 ] || exit 2
exit "${ST[1]}"
