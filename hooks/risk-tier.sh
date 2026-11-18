#!/bin/bash
# risk-tier.sh [base]
# Scores the current change so the review can match it: line 1 `low`, `normal` or `high`, then one `reason: …` line
# per rule that fired. The change is collected as static-gates.sh collects it (lib/collect-change.sh): with base,
# everything since the merge base of <base> and HEAD plus the working tree; without, staged, unstaged and untracked
# against HEAD. Changed paths include deleted files; added lines are the diff's `+` lines.
#   high    any of: a changed path (both sides of a move), or an added line of a file that is neither a doc nor a
#           dependency file, holds an auth/session, payment, concurrency or parser word; a path under migration(s)/ or
#           ending in .sql; a path under the root hooks/ or .github/workflows/, or a file name holding the word gate(s);
#           10 or more changed files
#   normal  no high rule and a dependency file changed (`reason: dependency change`, also listed under high)
#   low     no high rule, no dependency file, at least one changed file, and either only docs or tests changed (docs,
#           images under docs/, *.test.*, *.spec.*, __tests__/, test/, tests/) or at most 2 files with at most 30 added
#           lines
#   normal  otherwise (an empty change included), with no reason line
# Docs: *.md, *.mdx, *.rst, *.txt (not requirements*/constraints*.txt or CMakeLists.txt) — their path counts, the
# words of their lines never do. Dependency files (*.lock, bun.lockb, package-lock.json, pnpm-lock.yaml, go.sum,
# requirements*.txt, constraints*.txt): neither their name nor their lines are scanned for words.
# Before the scan, ARIA role=, getByRole(, git checkout, sparse-checkout and actions/checkout are blanked, and a line is
# cut to its first 20,000 characters.
# Words are case-insensitive whole runs of letters and digits, also split at camelCase (getToken → get, token), so
# tokenizer, author, clock and parseInt are no hits. Paths match case-insensitively.
# Reads only; the real index is never written. Needs git ≥ 2.25.
# Exit: 0, or 2 on a usage error, outside a git repo, or when an internal git command fails.

umask 077   # the temp index and diff copies hold repo content
ME=risk-tier
usage() { echo "usage: risk-tier.sh [base]${1:+ — $1}" >&2; exit 2; }
[ $# -le 1 ] || usage
case "${1:-}" in -*) usage "unknown option: $1" ;; esac
. "$(dirname "${BASH_SOURCE[0]}")/lib/collect-change.sh" || exit 2
collect_change "${1:-}"
g diff --name-only --no-renames "$FROM" -- > "$IDX.names" 2> "$IDX.err" || gitfail diff
g diff -U0 --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$FROM" -- > "$IDX.diff" 2> "$IDX.err" \
  || gitfail diff

# LC_ALL=C: macOS awk in a UTF-8 locale aborts at a non-UTF-8 byte.
LC_ALL=C awk '
  # words(t) — lower-case letter/digit runs of t, then the same runs split at camelCase (APIToken → API Token)
  function words(t,   s, i, c, n) {
    s = ""; n = length(t)
    for (i = 1; i <= n; i++) {
      c = substr(t, i, 1)
      if (i > 1 && c ~ /[A-Z]/ && (substr(t, i - 1, 1) ~ /[a-z0-9]/ || (substr(t, i - 1, 1) ~ /[A-Z]/ && substr(t, i + 1, 1) ~ /[a-z]/))) s = s " "
      s = s c
    }
    return tolower(t " " s)
  }
  # isdoc / isdep take a lower-case path
  function isdoc(lp) { sub(/.*\//, "", lp); return lp ~ /\.(md|mdx|rst|txt)$/ && lp !~ /^(requirements.*|constraints.*|cmakelists)\.txt$/ }
  function isdep(lp) {
    sub(/.*\//, "", lp)
    return lp ~ /\.lock$/ || lp ~ /^(bun\.lockb|package-lock\.json|pnpm-lock\.yaml|go\.sum)$/ || lp ~ /^(requirements|constraints).*\.txt$/
  }
  # scan(t, where) — keeps the first hit of each word rule. Only the letter/digit runs that hold a candidate are split
  # at camelCase. Measured noise is blanked first: ARIA role=, getByRole(, git checkout, sparse-checkout, actions/checkout.
  # shortcut: only the first 20,000 characters of a line are scanned (macOS awk split() slows down sharply on longer
  # lines), and runs over 80 characters (minified or encoded data) are skipped; raise the caps if a real hit is missed.
  function scan(t, where,   p, m, j, w, n, k, r) {
    if (length(t) > 20000) t = substr(t, 1, 20000)
    gsub(/role=["\047{]|ByRole\(|(git[ \t]+|sparse-|actions\/)checkout/, " ", t)
    if (tolower(t) !~ pre) return
    m = split(t, p, /[^A-Za-z0-9]+/)
    for (j = 1; j <= m; j++) {
      if (length(p[j]) > 80 || tolower(p[j]) !~ pre) continue
      n = split(words(p[j]), w, " ")
      for (k = 1; k <= n; k++) for (r = 1; r <= nw; r++) if (!(r in hit) && w[k] ~ re[r]) hit[r] = "(" w[k] ") in " where
    }
  }
  BEGIN {
    nw = 4
    label[1] = "auth/session term"; re[1] = "^(auth|authn|authz|authenticat[a-z]*|authori[sz][a-z]*|oauth[0-9]*|sessions?|tokens?|permissions?|roles?|acls?|rbac|passwords?|passwd|jwts?|login|logout|credentials?)$"
    label[2] = "payment term";      re[2] = "^(payments?|billing|checkouts?|invoices?|stripe|refunds?)$"
    label[3] = "concurrency term";  re[3] = "^(locks?|locked|locking|unlock(s|ed|ing)?|mutex(es)?|semaphores?|workers?|queues?|queued|queu(e)?ing|concurrency|concurrent)$"
    label[4] = "parser term";       re[4] = "^(parsers?|parsing|deseriali[sz][a-z]*)$"
    pre = "auth|session|token|permission|role|acl|rbac|passw|jwt|login|logout|credential|payment|billing|checkout|invoice|stripe|refund|lock|mutex|semaphore|worker|queu|concurren|pars|deseriali"
  }
  FILENAME == ARGV[1] {
    files++; lp = tolower($0); b = $0; sub(/.*\//, "", b)
    if (isdep(lp)) dep = "reason: dependency change\n"; else scan($0, $0)
    if (mig == "" && (lp ~ /(^|\/)migrations?\// || lp ~ /\.sql$/)) mig = $0
    if (ctl == "" && (lp ~ /^(hooks|\.github\/workflows)\// || words(b) ~ /(^|[^a-z0-9])gates?([^a-z0-9]|$)/)) ctl = $0
    if (!(isdoc(lp) || lp ~ /(^|\/)docs\/.*\.(png|jpe?g|gif|svg|webp)$/ || lp ~ /\.(test|spec)\./ || lp ~ /(^|\/)(__tests__|test|tests)\//)) code = 1
    next
  }
  # Header lines run from `diff ` to the first `@@`, so an added line whose text starts with `++` is never a header.
  /^diff / { hdr = 1; f = ""; skip = 0; next }
  hdr && /^\+\+\+ / { f = substr($0, 5); sub(/\t$/, "", f); sub(/^b\//, "", f); skip = isdoc(tolower(f)) || isdep(tolower(f)); next }
  /^@@/ { hdr = 0; next }
  hdr || !/^\+/ { next }
  { added++; if (!skip) scan(substr($0, 2), f) }
  END {
    for (r = 1; r <= nw; r++) if (r in hit) out = out "reason: " label[r] " " hit[r] "\n"
    if (mig != "") out = out "reason: migration path " mig "\n"
    if (ctl != "") out = out "reason: hook, workflow or gate path " ctl "\n"
    if (files >= 10) out = out "reason: " files " files changed\n"
    if (out != "") { printf "high\n%s%s", out, dep; exit }
    if (dep != "") { printf "normal\n%s", dep; exit }
    if (files && !code) out = "reason: docs or tests only\n"
    if (files && files <= 2 && added <= 30) out = out "reason: small change: " (files + 0) " files, " (added + 0) " added lines\n"
    printf "%s\n%s", (out != "" ? "low" : "normal"), out
  }' "$IDX.names" "$IDX.diff"
