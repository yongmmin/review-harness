#!/bin/bash
# pre-tool-use.sh
# PreToolUse gate for review-required config files (package.json, next.config.*, tsconfig*.json).
#
# Hook contract (PreToolUse):
#   - Plain-text stdout on exit 0 is NOT shown to Claude (debug log only), so a printed
#     "warning" is invisible. The only reliable channels are JSON on stdout:
#       hookSpecificOutput.permissionDecision = "allow" | "deny"  (+ permissionDecisionReason)
#       hookSpecificOutput.additionalContext                      (Claude sees it, call proceeds)
#   - We DENY by default and tell Claude how to obtain approval. After the user approves,
#     Claude records the approval with `bash hooks/pre-tool-use.sh --approve <file>` and retries.
#     Approvals live in <state dir>/approved/<sha1(path)> (state-dir.sh — outside the repo) and expire after
#     APPROVAL_TTL_SECONDS so a stale "yes" from an earlier task never leaks into the next one.
#
# Manual usage:
#   bash pre-tool-use.sh --approve <path>     # record approval (Claude runs this after user says yes)
#   bash pre-tool-use.sh --revoke  <path>     # drop approval
#   REVIEW_HARNESS_ALLOW_CONFIG_EDITS=1           # env escape hatch: skip the gate entirely

APPROVAL_TTL_SECONDS="${REVIEW_HARNESS_APPROVAL_TTL:-1800}"

find_project_root() {
  local dir; dir=$(dirname "$1")
  while [ "$dir" != "/" ] && [ "$dir" != "." ]; do
    [ -f "$dir/package.json" ] && { printf '%s' "$dir"; return; }
    local parent; parent=$(dirname "$dir")
    [ "$parent" = "$dir" ] && break
    dir="$parent"
  done
  printf '%s' "$(dirname "$1")"
}

approval_file() {
  local path="$1" root key state
  root=$(find_project_root "$path")
  key=$(printf '%s' "$path" | shasum | awk '{print $1}')
  state=$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state-dir.sh" "$root" 2>/dev/null)
  printf '%s/approved/%s' "${state:-/nonexistent}" "$key"
}

is_review_required() {
  case "$(basename "$1")" in
    package.json|next.config.js|next.config.ts|next.config.mjs|tsconfig.json|tsconfig.*.json) return 0 ;;
    *) return 1 ;;
  esac
}

emit_json() {
  # $1 decision (allow|deny) $2 reason
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg d "$1" --arg r "$2" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  else
    python3 -c 'import sys,json; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":sys.argv[1],"permissionDecisionReason":sys.argv[2]}}))' "$1" "$2"
  fi
}

case "${1:-}" in
  --approve)
    [ -z "${2:-}" ] && { echo "usage: pre-tool-use.sh --approve <path>" >&2; exit 2; }
    f=$(approval_file "$2"); mkdir -p "$(dirname "$f")"; date +%s > "$f"
    echo "approved: $2 (expires in ${APPROVAL_TTL_SECONDS}s)"; exit 0 ;;
  --revoke)
    [ -z "${2:-}" ] && { echo "usage: pre-tool-use.sh --revoke <path>" >&2; exit 2; }
    rm -f "$(approval_file "$2")"; echo "revoked: $2"; exit 0 ;;
esac

# --- hook mode: payload JSON on stdin --------------------------------------------------
INPUT=$(cat)
[ -z "$INPUT" ] && INPUT="${CLAUDE_TOOL_INPUT:-{\}}"
if command -v jq >/dev/null 2>&1; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)
else
  FILE_PATH=$(printf '%s' "$INPUT" | python3 -c "import sys,json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('file_path', '') or d.get('file_path', ''))
except Exception: print('')" 2>/dev/null)
fi

[ -z "$FILE_PATH" ] && exit 0
is_review_required "$FILE_PATH" || exit 0
[ "${REVIEW_HARNESS_ALLOW_CONFIG_EDITS:-0}" = "1" ] && exit 0

APPROVAL=$(approval_file "$FILE_PATH")
if [ -f "$APPROVAL" ]; then
  STAMP=$(cat "$APPROVAL" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ -n "$STAMP" ] && [ $((NOW - STAMP)) -lt "$APPROVAL_TTL_SECONDS" ]; then
    exit 0   # approved and fresh → normal permission flow
  fi
  rm -f "$APPROVAL"
fi

FILENAME=$(basename "$FILE_PATH")
HOOK_PATH="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/hooks/pre-tool-use.sh"
emit_json deny "REVIEW REQUIRED: '$FILENAME' is a protected config file (review-harness #filesystem). Ask the user for explicit approval, describing the exact change. If they approve, run: bash \"$HOOK_PATH\" --approve \"$FILE_PATH\"  and retry the edit. Do not work around this gate by writing via Bash."
exit 0
