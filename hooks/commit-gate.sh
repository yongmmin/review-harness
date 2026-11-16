#!/bin/bash
# commit-gate.sh — PreToolUse(Bash) backstop for the review gate.
# Denies `git commit` while a review-harness run is active and its recorded reviewer PASS
# does not match the current work tree (see run-state.sh check). It only sees Claude's
# Bash calls: commits the user types in their own terminal are never affected.
# No state file, or no active run → silent pass. Active run idle for >24h → advice only.
# Known limit: matches the command text, so `git -C <other repo> commit` is checked against
# the session cwd and commits made through a script are not seen.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
printf '%s\n' "$CMD" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+commit([[:space:]]|$)' || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -d "$CWD" ] || CWD="$PWD"
OUT=$(cd "$CWD" && bash "$HERE/run-state.sh" check --active-only 2>&1); RC=$?

case "$RC" in
  1) jq -n --arg r "COMMIT BLOCKED by the review-harness review gate — $OUT If the user explicitly says to commit anyway, record that with: bash \"$HERE/run-state.sh\" override \"<reason>\" and retry. Do not bypass this gate by committing another way." \
       '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
  4) jq -n --arg r "$OUT" '{systemMessage:$r, hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}' ;;
esac
exit 0
