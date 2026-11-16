#!/usr/bin/env bash
# Prints the 5-hour rate-limit usage recorded by the user's status line wrapper in
# ~/.claude/usage-state.json as "<integer>% (resets HH:MM)" in local time, or "unknown"
# when the file is missing, older than 10 minutes, or its window has already reset.
f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/usage-state.json"
jq -r 'now as $n
  | if ($n - (.updated_at // 0)) > 600 or (.resets_at != null and $n > .resets_at) or .five_hour_used_percentage == null
    then "unknown"
    else "\(.five_hour_used_percentage | floor)% (resets \(if .resets_at then (.resets_at | strflocaltime("%H:%M")) else "unknown" end))" end' "$f" 2>/dev/null || echo unknown
