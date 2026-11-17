#!/bin/bash
# agent-usage.sh — SubagentStart / SubagentStop hook (plugin agents only, see hooks.json). Records each agent's
# active time and its transcript's token usage in the active run via `run-state.sh agent-start|agent-stop`.
# Never blocks a subagent and never injects context: no stdout, always exit 0. No jq, no active run, bad input →
# nothing recorded.
command -v jq >/dev/null 2>&1 || exit 0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)
f() { printf '%s' "$INPUT" | jq -r "$1 // \"\"" 2>/dev/null; }
ID=$(f .agent_id); TYPE=$(f .agent_type)
[ -n "$ID" ] && [ -n "$TYPE" ] || exit 0
case "$(f .hook_event_name)" in
  SubagentStart) set -- agent-start "$ID" "$TYPE" ;;
  SubagentStop) set -- agent-stop "$ID" "$TYPE" "$(f .agent_transcript_path)" ;;
  *) exit 0 ;;
esac
CWD=$(f .cwd)
[ -d "$CWD" ] || CWD="$PWD"
(cd "$CWD" && bash "$HERE/run-state.sh" "$@") >/dev/null 2>&1
exit 0
