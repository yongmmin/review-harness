#!/bin/bash
# bench/dev-score.sh <case-dir> <out-dir> — scores one finished developer-side run (an out-dir of dev-run.sh) and
# prints one JSON line. Never runs a model.
#   tests_touched  base test files (tracked test/** and *.test.js of a fresh fixture) the run deleted or removed lines
#                  from; they are restored to the base version before the tests run
#   accept         "pass/tests" of the case's hidden tests (accept/*.test.js copied to test/accept/)
#   regressions    failing base tests
#   cost_usd       the largest total_cost_usd in driver/*.json: a resumed call reports the session's running total
#   *_tokens       the last call's modelUsage (running total, subagents included); without one, the calls' own
#                  usage added up (main loop only)
#   turns          num_turns added up; wall_s, user_replies, aborted, arm from run.json
#   attempts, verdicts, end, override from runs.jsonl (harness); plan_callers, plan_done_when, plan_bug from plan.md
#   test_runs      Bash calls in the transcripts that run the tests; contaminated: a transcript names this repo or
#                  the case's hidden files
#   solved         every hidden test passes, no regression, not aborted, harness run not ended at limit/abandoned,
#                  not contaminated
# Exit 2 with one stderr line: usage, node missing or older than 20, or the hidden tests reported 0 tests.
set -euo pipefail
usage() { echo "usage: dev-score.sh <case-dir> <out-dir>" >&2; exit 2; }
CASE="${1:-}"; OUT="${2:-}"
[ -n "$CASE" ] && [ -f "$CASE/setup.sh" ] && [ -d "$CASE/accept" ] || usage
[ -n "$OUT" ] && [ -d "$OUT/work" ] && [ -f "$OUT/run.json" ] || usage
# Without this check a shell with no node (or an old one) scored every run "0/0" and unsolved, silently.
NODE_V=$(node --version 2>/dev/null || true); NODE_M=${NODE_V#v}; NODE_M=${NODE_M%%.*}
case "$NODE_M" in ''|*[!0-9]*) NODE_M=0 ;; esac
if [ "$NODE_M" -lt 20 ]; then
  echo "dev-score: node 20+ is needed to run the tests (found: ${NODE_V:-none}); load it in this shell first" >&2; exit 2
fi
CASE=$(cd "$CASE" && pwd -P); OUT=$(cd "$OUT" && pwd -P)
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

T=$(mktemp -d "${TMPDIR:-/tmp}/s.XXXXXX")
trap 'rm -rf "${T:?}"' EXIT
bash "$CASE/setup.sh" "$T/base" >/dev/null
cp -R "$OUT/work" "$T/work"

BASE_TESTS=$(git -C "$T/base" ls-files -- 'test/*' '*.test.js' | sort -u)
TOUCHED=0
for f in $BASE_TESTS; do
  if [ ! -f "$T/work/$f" ]; then TOUCHED=$((TOUCHED + 1)); mkdir -p "$(dirname "$T/work/$f")"
  elif [ "$(git diff --no-index --numstat "$T/base/$f" "$T/work/$f" | awk '{ n += $2 } END { print n + 0 }')" -gt 0 ]; then
    TOUCHED=$((TOUCHED + 1))
  fi
  cp "$T/base/$f" "$T/work/$f"
done

mkdir -p "$T/work/test/accept"
cp "$CASE"/accept/*.test.js "$T/work/test/accept/"
tap() { # tap <field> <files...> — the "# <field> N" count of a TAP run of <files> in the scored work tree
  local k="$1"; shift
  (cd "$T/work" && node --test --test-reporter=tap "$@" 2>/dev/null || true) | awk -v k="$k" '$1 == "#" && $2 == k { n = $3 } END { print n + 0 }'
}
HIDDEN=$(cd "$T/work" && ls test/accept/*.test.js)
# shellcheck disable=SC2086 # file lists are word-split on purpose (paths have no spaces)
A_PASS=$(tap pass $HIDDEN); A_TESTS=$(tap tests $HIDDEN)
if [ "$A_TESTS" -eq 0 ]; then
  echo "dev-score: the hidden tests reported 0 tests, so they did not run; this is a scoring error, not a score" >&2; exit 2
fi
# shellcheck disable=SC2086
REGR=$(tap fail $BASE_TESTS)

DRIVER=$(for f in "$OUT"/driver/*.json; do [ -f "$f" ] || continue; jq -c . "$f" 2>/dev/null || true; done | jq -sc .)
RUNLOG=""; [ -f "$OUT/runs.jsonl" ] && RUNLOG=$(tail -n 1 "$OUT/runs.jsonl" | jq -c . 2>/dev/null || true)
[ -n "$RUNLOG" ] || RUNLOG='{}'
sec() { # sec <heading> — 1 when plan.md has the section with a non-empty line before the next heading
  [ -f "$OUT/plan.md" ] || { echo 0; return; }
  awk -v h="$1" '$0 == h { s = 1; next } /^## / { s = 0 } s && NF { n = 1 } END { print n + 0 }' "$OUT/plan.md"
}
CALLERS=0; [ -f "$OUT/plan.md" ] && grep -qE '^- Callers/Consumers:[[:space:]]*[^[:space:]]' "$OUT/plan.md" && CALLERS=1
TEST_RUNS=0; CONTAM=0
if [ -d "$OUT/transcripts" ]; then
  TEST_RUNS=$(find "$OUT/transcripts" -name '*.jsonl' -exec cat {} + \
    | jq -R -r 'fromjson? | .message.content? | arrays | .[] | select(.type? == "tool_use" and .name? == "Bash") | .input.command // empty' \
    | grep -cE 'node --test|npm (run )?test' || true)
  grep -rqF -e "$REPO" -e cases-dev -e /accept/ -e solution.patch -e trap.patch -e trap.md "$OUT/transcripts" && CONTAM=1
fi

jq -nc --arg case "$(basename "$CASE")" --slurpfile run "$OUT/run.json" --argjson d "$DRIVER" --argjson log "$RUNLOG" \
  --argjson ap "$A_PASS" --argjson at "$A_TESTS" --argjson regr "$REGR" --argjson touched "$TOUCHED" \
  --argjson callers "$CALLERS" --argjson dw "$(sec '## Done When')" --argjson bug "$(sec '## Bug')" \
  --argjson tr "${TEST_RUNS:-0}" --argjson contam "$CONTAM" '
  $run[0] as $r
  | ($d | map(.modelUsage // {} | select(length > 0)) | last) as $mu
  | def tok($mk; $uk): if $mu then ([$mu[] | .[$mk] // 0] | add) else ([$d[] | .usage[$uk] // 0] | add // 0) end;
  {case: $case, arm: $r.arm, accept: "\($ap)/\($at)", regressions: $regr, tests_touched: $touched,
     cost_usd: ([$d[].total_cost_usd // 0] | max // 0),
     input_tokens: tok("inputTokens"; "input_tokens"),
     output_tokens: tok("outputTokens"; "output_tokens"),
     cache_read_tokens: tok("cacheReadInputTokens"; "cache_read_input_tokens"),
     turns: ([$d[].num_turns // 0] | add // 0),
     wall_s: $r.wall_s, user_replies: $r.user_replies, aborted: $r.aborted,
     attempts: $log.attempts, verdicts: ($log.verdicts | if . then map(.v) else null end), end: $log.end,
     override: $log.override, plan_callers: $callers, plan_done_when: $dw, plan_bug: $bug,
     test_runs: $tr, contaminated: $contam}
  | .solved = ($at > 0 and $ap == $at and $regr == 0 and .aborted == null
               and (.arm == "plain" or (.end != "limit" and .end != "abandoned")) and $contam == 0)'
