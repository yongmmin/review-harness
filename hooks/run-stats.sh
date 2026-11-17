#!/bin/bash
# run-stats.sh [--repo <id|name>] [--since <days>] — summary (attempts, FAIL rate and categories, overrides,
# limit hits) of the run log that run-state.sh appends to
# ~/.review-harness/state/runs.jsonl (one line per finished run, all repos). Reads only.
#   --repo   a repo id (<name>-<hash>, the state folder name) or just the work-tree name
#   --since  only runs that ended in the last <days> days
set -u
usage() { echo "usage: run-stats.sh [--repo <id|name>] [--since <days>]" >&2; exit 2; }
REPO=""; SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ -n "${2:-}" ] || usage; REPO="$2"; shift 2 ;;
    --since) case "${2:-}" in ''|*[!0-9]*) usage ;; esac; SINCE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "run-stats: jq is required (install it, e.g. brew install jq or apt-get install jq)" >&2; exit 3; }
LOG="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/state/runs.jsonl"
[ -s "$LOG" ] || { echo "run-stats: no runs recorded yet ($LOG)"; exit 0; }

# A torn or hand-edited line is skipped, not fatal.
jq -Rnr --arg repo "$REPO" --arg since "$SINCE" --argjson now "$(date +%s)" '
  def pct(n; d): if d == 0 then "-" else "\((n * 100 / d + 0.5) | floor)% (\(n)/\(d))" end;
  def mean(xs): if (xs | length) == 0 then "-" else "\(((xs | add) / (xs | length) * 10 + 0.5 | floor) / 10)" end;
  # attempts = test failures + reviewer FAILs before the run ended; counted over runs whose last verdict is PASS
  def stats: {
    runs: length,
    to_pass: mean([.[] | select(.verdicts | last | .v == "PASS") | .attempts]),
    passed: ([.[] | select(.verdicts | last | .v == "PASS")] | length),
    fail: pct([.[] | select(any(.verdicts[]; .v == "FAIL"))] | length; length),
    # one count per [category] tag on a FAIL verdict; a FAIL recorded without tags counts as "untagged";
    # a re-judge after a dispute repeats the tags of its round, so it is skipped
    cats: ([.[] | .verdicts[] | select(.v == "FAIL" and (.rejudge | not)) | (.cats // ["untagged"]) | if . == [] then ["untagged"] else . end | .[]]
      | group_by(.) | map({k: .[0], n: length}) | sort_by(-.n, .k) | map("\(.k) \(.n)") | join(", ")
      | if . == "" then "-" else . end),
    override: pct([.[] | select(.override != null)] | length; length),
    limit: ([.[] | select(.end == "limit")] | length) };
  [inputs | fromjson? | objects
   | select($repo == "" or .repo == $repo or ((.repo // "") | sub("-[^-]*$"; "")) == $repo)
   | select($since == "" or (.ended_at // 0) >= $now - ($since | tonumber) * 86400)
   | .verdicts = [(.verdicts // [])[] | if type == "string" then {v: .} else . end]] as $runs
  | ($runs | stats) as $all
  | "runs: \($all.runs) (repo: \(if $repo == "" then "all" else $repo end), since: \(if $since == "" then "all" else "\($since)d" end))",
    if $all.runs == 0 then empty else
      "mean attempts before PASS: \($all.to_pass) (\($all.passed) runs ending in PASS)",
      "runs with a reviewer FAIL: \($all.fail)",
      "FAIL categories: \($all.cats)",
      "override rate: \($all.override)",
      "limit reached: \($all.limit)",
      "by workflow:",
      ($runs | group_by(.workflow) | .[] | (stats) as $w
        | "  \(.[0].workflow // "?"): runs \($w.runs) · attempts before PASS \($w.to_pass) · FAIL \($w.fail) · override \($w.override) · limit \($w.limit) · FAIL categories \($w.cats)")
    end' "$LOG"
