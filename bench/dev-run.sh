#!/bin/bash
# bench/dev-run.sh <plain|harness> <case-dir> <out-dir> — one developer-side run (arm × case). Builds the case's
# fixture in an opaque temp dir, runs `claude -p` on task.md there (harness: as `/review-harness:review-harness
# <task>` with this repo's HEAD as the plugin), answers questions as a fixed user proxy, enforces the caps, and copies
# the artifacts to <out-dir>. No scoring: dev-score.sh reads <out-dir>.
#   DEV_BENCH_BUDGET_USD  cost cap over all calls (default 15)    DEV_BENCH_TIME_S  wall-time cap (default 2700)
#   DEV_BENCH_BARE=1      `--bare` instead of `--setting-sources project --strict-mcp-config`
# Isolation: own CLAUDE_CONFIG_DIR and REVIEW_HARNESS_HOME, rtk off, neutral git identity, and a plugin copy of the
# runtime files only (no bench/, tests/, docs or changelog that could describe the cases).
set -euo pipefail
usage() { echo "usage: dev-run.sh <plain|harness> <case-dir> <out-dir>" >&2; exit 2; }
ARM="${1:-}"; CASE="${2:-}"; OUT="${3:-}"
case "$ARM" in plain|harness) ;; *) usage ;; esac
[ -n "$CASE" ] && [ -f "$CASE/setup.sh" ] && [ -f "$CASE/task.md" ] && [ -n "$OUT" ] || usage
if [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then echo "dev-run: $OUT exists and is not empty" >&2; exit 2; fi
CASE=$(cd "$CASE" && pwd -P); ID=$(basename "$CASE")
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BUDGET="${DEV_BENCH_BUDGET_USD:-15}"; LIMIT="${DEV_BENCH_TIME_S:-2700}"

W=$(mktemp -d "${TMPDIR:-/tmp}/w.XXXXXX")
pid=""; dog=""
cleanup() {
  [ -z "$pid" ] || kill -TERM -- "-$pid" 2>/dev/null || true
  [ -z "$dog" ] || kill -- "-$dog" 2>/dev/null || true
  rm -rf "${W:?}"
}
trap cleanup EXIT
if printf '%s' "$W" | grep -qiE "bench|accept|solution|trap|$ID"; then
  echo "dev-run: work dir $W names the benchmark or the case; set TMPDIR to a neutral path" >&2; exit 2
fi
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd -P)
mkdir "$W/home" "$W/cfg" "$OUT/driver"
bash "$CASE/setup.sh" "$W/repo" >/dev/null

export REVIEW_HARNESS_RTK=off REVIEW_HARNESS_HOME="$W/home" CLAUDE_CONFIG_DIR="$W/cfg"
export GIT_AUTHOR_NAME='Sam Lee' GIT_AUTHOR_EMAIL=sam.lee@example.com   # same neutral identity as lib.sh
export GIT_COMMITTER_NAME='Sam Lee' GIT_COMMITTER_EMAIL=sam.lee@example.com
unset CLAUDE_PLUGIN_ROOT

PROMPT=$(cat "$CASE/task.md"); REV=""
FLAGS=(--setting-sources project --strict-mcp-config); [ "${DEV_BENCH_BARE:-}" = 1 ] && FLAGS=(--bare)
if [ "$ARM" = harness ]; then
  mkdir "$W/plugin"
  git -C "$REPO" archive HEAD .claude-plugin agents hooks skills profiles constraints.md | tar -x -C "$W/plugin"
  REV=$(git -C "$REPO" rev-parse --short HEAD)
  : > "$(bash "$W/plugin/hooks/state-dir.sh" --create "$W/repo")/register-declined"   # no /register-repo offer
  FLAGS+=(--plugin-dir "$W/plugin"); PROMPT="/review-harness:review-harness $PROMPT"
fi

START=$(date +%s); DEADLINE=$((START + LIMIT))
COST=0; N=0; REPLIES=0; ABORTED=null; SID=""
while :; do
  LEFT=$((DEADLINE - $(date +%s)))
  [ "$LEFT" -gt 0 ] || { ABORTED='"time"'; break; }
  N=$((N + 1)); F=$(printf '%s/driver/%02d.json' "$OUT" "$N")
  REM=$(awk -v b="$BUDGET" -v c="$COST" 'BEGIN { printf "%.2f", b - c }')
  # Own process groups (set -m), so the watchdog can kill claude with everything it started.
  set -m
  (cd "$W/repo" && exec claude -p "$PROMPT" --model opus --output-format json --permission-mode bypassPermissions \
    --disallowedTools AskUserQuestion --max-budget-usd "$REM" "${FLAGS[@]}" ${SID:+--resume "$SID"}) \
    < /dev/null > "$F" 2>> "$OUT/driver/stderr.log" &
  pid=$!
  (sleep "$LEFT"; kill -TERM -- "-$pid" 2>/dev/null && : > "$W/timed-out") > /dev/null 2>&1 &
  dog=$!
  set +m
  wait "$pid" || true; pid=""
  kill -- "-$dog" 2>/dev/null || true; wait "$dog" 2>/dev/null || true; dog=""
  [ ! -f "$W/timed-out" ] || { ABORTED='"time"'; break; }
  COST=$(awk -v a="$COST" -v b="$(jq -r '.total_cost_usd // 0' "$F" 2>/dev/null || echo 0)" 'BEGIN { print a + b }')
  SID=$(jq -r '.session_id // empty' "$F" 2>/dev/null || true)
  if awk -v c="$COST" -v b="$BUDGET" 'BEGIN { exit !(c >= b) }'; then ABORTED='"cost"'; break; fi
  ASKS=$(jq -r '(.result // "") | .[-400:] | contains("?")' "$F" 2>/dev/null || echo false)
  [ "$ASKS" = true ] && [ "$REPLIES" -lt 4 ] && [ -n "$SID" ] || break
  REPLIES=$((REPLIES + 1))
  if [ "$REPLIES" = 1 ]; then PROMPT='Approved. Go ahead.'
  else PROMPT="I can't answer more questions — use your best judgement and finish the task."; fi
done
WALL=$(($(date +%s) - START))

cp -R "$W/repo" "$OUT/work"
[ ! -d "$W/cfg/projects" ] || cp -R "$W/cfg/projects" "$OUT/transcripts"
if [ "$ARM" = harness ]; then
  [ ! -f "$W/home/state/runs.jsonl" ] || cp "$W/home/state/runs.jsonl" "$OUT/runs.jsonl"
  for p in "$W"/home/state/*/plan.md; do [ ! -f "$p" ] || cp "$p" "$OUT/plan.md"; done
fi
jq -n --arg arm "$ARM" --arg case "$ID" --arg rev "$REV" --argjson wall "$WALL" --argjson replies "$REPLIES" \
  --argjson aborted "$ABORTED" --argjson calls "$N" \
  '{arm: $arm, case: $case} + (if $rev == "" then {} else {plugin_rev: $rev} end)
   + {wall_s: $wall, user_replies: $replies, aborted: $aborted, calls: $calls}' > "$OUT/run.json"
printf '%s\t%s\t%s\n' "$(basename "$OUT")" "$ID" "$ARM" >> "$(dirname "$OUT")/map.tsv"
jq -c . "$OUT/run.json"
