#!/bin/bash
# bench/prompt.sh <arm> <fixture-dir> [case-dir] — prints the complete reviewer prompt for one benchmark arm.
#   pre-split   9c81361  reviewer.md + extract-constraints.sh reviewer (no profiles yet)
#   pre-stage4  53dd721  reviewer.md + extract-constraints.sh reviewer "<its detect-profile.sh in the fixture>"
#   current     HEAD     same as pre-stage4 with HEAD's files
# Each revision is unpacked with `git archive` into a temp dir under $TMPDIR (removed on exit) and run with an
# empty REVIEW_HARNESS_HOME: public plugin only, no org overlay or org profile rules.
# With a case-dir holding plan.md, the plan is copied to <fixture-dir>.plan.md (as opaque as the fixture path) and
# given as plan_path, the way /review-harness passes it; the lines of the case's handoff.md, if any, follow it.
set -euo pipefail
usage() { echo "usage: prompt.sh <pre-split|pre-stage4|current> <fixture-dir> [case-dir]" >&2; exit 2; }
ARM="${1:-}"; FIX="${2:-}"; CASE="${3:-}"
case "$ARM" in pre-split) REV=9c81361 ;; pre-stage4) REV=53dd721 ;; current) REV=HEAD ;; *) usage ;; esac
[ -n "$FIX" ] && [ -d "$FIX" ] || usage
[ -z "$CASE" ] || [ -d "$CASE" ] || usage
FIX=$(cd "$FIX" && pwd -P)
PLAN=""
if [ -n "$CASE" ] && [ -f "$CASE/plan.md" ]; then PLAN="$FIX.plan.md"; cp "$CASE/plan.md" "$PLAN"; fi
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rh-bench.XXXXXX")
trap 'rm -rf "${WORK:?}"' EXIT
P="$WORK/plugin"
mkdir "$P" "$WORK/home"
git -C "$REPO" archive "$REV" | tar -x -C "$P"
export REVIEW_HARNESS_HOME="$WORK/home"
unset CLAUDE_PLUGIN_ROOT

if [ "$ARM" = pre-split ]; then
  RULES=$(bash "$P/hooks/extract-constraints.sh" reviewer 2>/dev/null)
else
  PROFILES=$(cd "$FIX" && bash "$P/hooks/detect-profile.sh")
  RULES=$(bash "$P/hooks/extract-constraints.sh" reviewer "$PROFILES" 2>/dev/null)
fi

awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$P/agents/reviewer.md"
printf '\n%s\n\n' "$RULES"
cat <<EOF
## Task

Review the uncommitted changes in $FIX with \`git -C $FIX diff\` and reading files. Output exactly the plugin's reviewer Output Format. Do not edit files, do not run run-state.sh, do not record a verdict.
EOF
if [ -n "$PLAN" ]; then
  printf '\n## Handoff\n- plan_path: %s\n' "$PLAN"
  if [ -f "$CASE/handoff.md" ]; then cat "$CASE/handoff.md"; fi
fi
