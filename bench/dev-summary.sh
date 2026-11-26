#!/bin/bash
# bench/dev-summary.sh <results-dir> — scores every run listed in <results-dir>/map.tsv (written by dev-run.sh) with
# dev-score.sh and prints one markdown table row per case and arm, then the harness-to-plain ratios. Never runs a model.
#   runs               runs of that case and arm
#   finished           runs that were not aborted and, for the harness, whose run log has an end (a harness run that
#                      stopped before its end, e.g. waiting for plan approval, is not finished)
#   solved             solved runs / runs (dev-score.sh's `solved`)
#   regressions        runs with a failing base test; tests edited: runs that changed a base test
#   first-review PASS  harness runs whose first reviewer verdict was PASS / runs with a verdict
#   cost, wall, replies  medians over the finished runs
#   ratios             harness median / plain median of cost and wall time, when both arms have a finished run
# Exit 2 with one stderr line: usage, no map.tsv, a run dev-score.sh cannot score.
set -euo pipefail
usage() { echo "usage: dev-summary.sh <results-dir>" >&2; exit 2; }
RES="${1:-}"; [ $# -eq 1 ] && [ -f "$RES/map.tsv" ] || usage
B=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
S=$(mktemp "${TMPDIR:-/tmp}/sum.XXXXXX") || { echo "dev-summary: no temp file" >&2; exit 2; }
trap 'rm -f "$S"' EXIT
while IFS=$'\t' read -r name id _; do
  [ -n "$name" ] || continue
  bash "$B/dev-score.sh" "$B/cases-dev/$id" "$RES/$name" >> "$S" || { echo "dev-summary: cannot score $name" >&2; exit 2; }
done < "$RES/map.tsv"
jq -rs '
  def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor]
           else (.[length / 2 - 1] + .[length / 2]) / 2 end;
  def r2: if . == null then "-" else (. * 100 | round / 100 | tostring) end;
  def fin: select(.aborted == null and (.arm == "plain" or .end != null));
  def cell: if . == null then "-" else tostring end;
  (group_by([.case, .arm]) | map(
    . as $g | ($g | map(fin)) as $f | ($g | map(select(.verdicts != null and (.verdicts | length) > 0))) as $v
    | {case: $g[0].case, arm: $g[0].arm, runs: ($g | length), finished: ($f | length),
       solved: ($g | map(select(.solved)) | length),
       regr: ($g | map(select(.regressions > 0)) | length), touched: ($g | map(select(.tests_touched > 0)) | length),
       first: (if ($v | length) == 0 then null else "\($v | map(select(.verdicts[0] == "PASS")) | length)/\($v | length)" end),
       cost: ($f | map(.cost_usd) | med), wall: ($f | map(.wall_s) | med), replies: ($f | map(.user_replies) | med)})) as $rows
  | "| Case | Arm | Runs | Finished | Solved | Regressions | Tests edited | First-review PASS | Median cost | Median wall | Median replies |",
    "|---|---|---|---|---|---|---|---|---|---|---|",
    ($rows[] | "| `\(.case)` | \(.arm) | \(.runs) | \(.finished) | \(.solved)/\(.runs) | \(.regr) | \(.touched) | \(.first | cell) | $\(.cost | r2) | \(.wall | cell) s | \(.replies | cell) |"),
    ($rows | group_by(.case)[] | (map(select(.arm == "plain"))[0]) as $p | (map(select(.arm == "harness"))[0]) as $h
     | select($p != null and $h != null and $p.cost != null and $h.cost != null and $p.cost > 0 and $p.wall > 0)
     | "", "`\($p.case)`: harness / plain — cost ×\($h.cost / $p.cost | r2), wall time ×\($h.wall / $p.wall | r2) (medians of \($h.finished) and \($p.finished) finished runs)")
' "$S"
