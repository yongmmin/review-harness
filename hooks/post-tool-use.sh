#!/bin/bash
# post-tool-use.sh
# Run compact validation after Write/Edit/MultiEdit/NotebookEdit on TypeScript files — or, in a registered
# repo with a `check_cmd`, on any file, using that command.
# Perf: incremental tsc + per-file debounce + tsc||eslint in parallel.

# Hook contract: Claude Code passes hook payload JSON on stdin; file path lives
# at .tool_input.file_path. Prefer jq (~5ms) over python3 (~80ms).
# Legacy $CLAUDE_TOOL_INPUT (top-level .file_path) kept as a compat fallback.
parse_file_path() {
  local input="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null
  else
    printf '%s' "$input" | python3 -c "import sys,json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('file_path', '') or d.get('file_path', ''))
except Exception: print('')" 2>/dev/null
  fi
}

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  INPUT="${CLAUDE_TOOL_INPUT:-{\}}"
fi
FILE_PATH=$(parse_file_path "$INPUT")

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Plugin-scoped rtk wrapper. Routes tsc/eslint through rtk when session
# mode opts in, else falls back to raw npx. Never affects other projects.
RTK_WRAP="$HOOK_DIR/rtk-wrap.sh"

compact_block() {
  printf '%s\n' "$1" | sed '/^$/d' | sed '/^--$/d' | head -n "$2"
}

# Debounce: skip if same file was validated within DEBOUNCE_SECONDS (exits the hook). Sets CACHE_DIR, DEBOUNCE_KEY.
DEBOUNCE_SECONDS=3
debounce_or_exit() {
  # Cache lives in the plugin state dir, never inside the consumer repo.
  STATE_DIR=$(bash "$HOOK_DIR/state-dir.sh" "$1" 2>/dev/null)
  [ -n "$STATE_DIR" ] || exit 0
  CACHE_DIR="$STATE_DIR/cache"
  mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0
  DEBOUNCE_KEY=$(printf '%s' "$FILE_PATH" | shasum | awk '{print $1}')
  DEBOUNCE_FILE="$CACHE_DIR/$DEBOUNCE_KEY.ts"
  NOW=$(date +%s)
  if [ -f "$DEBOUNCE_FILE" ]; then
    LAST=$(cat "$DEBOUNCE_FILE" 2>/dev/null)
    if [ -n "$LAST" ] && [ "$((NOW - LAST))" -lt "$DEBOUNCE_SECONDS" ]; then
      exit 0
    fi
  fi
  printf '%s' "$NOW" > "$DEBOUNCE_FILE"
}

# Emits $ERRORS (printed with $ERRORS_FMT: %b for the tsc/eslint blocks) as additionalContext, with the token
# budget on stderr.
ERRORS_FMT='%b'
emit_errors() {
  # Token budget instrumentation — stderr only (debug log; never reaches Claude on exit 0).
  BUDGET_WARN_BYTES="${REVIEW_HARNESS_BUDGET_WARN_BYTES:-8192}"
  ERR_BYTES=$(printf "$ERRORS_FMT" "$ERRORS" | wc -c | tr -d ' ')
  ERR_TOKENS=$((ERR_BYTES / 4))
  if [ "$ERR_BYTES" -gt "$BUDGET_WARN_BYTES" ]; then
    printf '[token-budget][warn] post-tool-use errors: %s bytes (~%s tokens) exceeds %s\n' \
      "$ERR_BYTES" "$ERR_TOKENS" "$BUDGET_WARN_BYTES" >&2
  else
    printf '[token-budget] post-tool-use errors: %s bytes (~%s tokens)\n' \
      "$ERR_BYTES" "$ERR_TOKENS" >&2
  fi

  # Hook contract (PostToolUse): plain-text stdout is NOT shown to Claude — it only
  # reaches the debug log. The reliable channel is JSON on stdout with
  # hookSpecificOutput.additionalContext (exit 0). Build it with a real JSON encoder
  # so tsc/eslint output containing quotes/backslashes never breaks the payload.
  MESSAGE=$(printf "PostToolUse validation failed: %s\n${ERRORS_FMT}\n\nFix the errors above before continuing. Do not declare completion while these remain." "$FILE_PATH" "$ERRORS")
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$MESSAGE" | jq -Rs '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:.}}'
  else
    printf '%s' "$MESSAGE" | python3 -c 'import sys,json; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":sys.stdin.read()}}))'
  fi
}

# A registered repo with `check_cmd` (detect-repo.sh) validates every edited file with that command, run from
# the repo's registered local_path, instead of tsc/eslint. Without it, the TypeScript path below runs exactly as before.
# The grep pre-check keeps edits in repos without any check_cmd from paying for a detect-repo.sh run.
CHECK_CMD=""
RH_KNOWLEDGE="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/knowledge"
if grep -qs 'check_cmd' "$RH_KNOWLEDGE"/*/repos.md "$RH_KNOWLEDGE/repos.md"; then
  REPO_INFO=$(bash "$HOOK_DIR/detect-repo.sh" "$(dirname "$FILE_PATH")" 2>/dev/null)
  # reg_value <key> — registry value with surrounding whitespace and one pair of backticks removed
  reg_value() {
    printf '%s\n' "$REPO_INFO" | sed -n "s/^- $1:[[:space:]]*//p" | head -n 1 \
      | sed -e 's/[[:space:]]*$//' -e 's/^`\(.*\)`$/\1/'
  }
  CHECK_CMD=$(reg_value check_cmd)
fi
if [ -n "$CHECK_CMD" ]; then
  REPO_ROOT=$(reg_value local_path)
  debounce_or_exit "$REPO_ROOT"
  # shortcut: check_cmd is a shell string, so rtk-wrap sees `bash` and runs it raw (no rtk compression);
  # split it into argv only if rtk compression of check output is wanted.
  CHECK_OUT=$(cd "$REPO_ROOT" && bash "$RTK_WRAP" bash -c "$CHECK_CMD" 2>&1)
  CHECK_EXIT=$?
  if [ "$CHECK_EXIT" != "0" ]; then
    RELEVANT=$(compact_block "$CHECK_OUT" 12)
    # Real newlines and %s: raw command output must never be read as printf escapes (`\c` would cut it).
    ERRORS=$'\n'"[check_cmd Error]"$'\n'"${RELEVANT:-exit $CHECK_EXIT, no output}"
    ERRORS_FMT='%s'
    emit_errors
  fi
  exit 0
fi

if [[ "$FILE_PATH" != *.ts && "$FILE_PATH" != *.tsx ]]; then
  exit 0
fi

# Skip test files — they often use separate tsconfig and produce noisy false positives.
case "$FILE_PATH" in
  *.spec.ts|*.spec.tsx|*.test.ts|*.test.tsx|*/__tests__/*|*/__mocks__/*)
    exit 0
    ;;
esac

if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

PROJECT_ROOT=$(dirname "$FILE_PATH")
while [ "$PROJECT_ROOT" != "/" ] && [ "$PROJECT_ROOT" != "." ]; do
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    break
  fi
  PARENT=$(dirname "$PROJECT_ROOT")
  # Guard against dirname fixpoints (e.g. relative paths) — avoid infinite loop.
  if [ "$PARENT" = "$PROJECT_ROOT" ]; then
    break
  fi
  PROJECT_ROOT="$PARENT"
done

if [ ! -f "$PROJECT_ROOT/package.json" ]; then
  exit 0
fi

debounce_or_exit "$PROJECT_ROOT"

MAX_TSC_LINES=8
MAX_ESLINT_LINES=12
FILENAME=$(basename "$FILE_PATH")
# Include PID so concurrent hook runs on the same file never clobber each other.
TSC_OUT_FILE="$CACHE_DIR/$DEBOUNCE_KEY.$$.tsc.out"
ESLINT_OUT_FILE="$CACHE_DIR/$DEBOUNCE_KEY.$$.eslint.out"
TSC_RC_FILE="$CACHE_DIR/$DEBOUNCE_KEY.$$.tsc.rc"
ESLINT_RC_FILE="$CACHE_DIR/$DEBOUNCE_KEY.$$.eslint.rc"
: > "$TSC_OUT_FILE" "$ESLINT_OUT_FILE"
echo 0 > "$TSC_RC_FILE"
echo 0 > "$ESLINT_RC_FILE"

# ESLint config discovery — flat config (eslint.config.*) and legacy .eslintrc.*.
has_eslint_config() {
  local f
  for f in eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts eslint.config.mts \
           .eslintrc.json .eslintrc.js .eslintrc.cjs .eslintrc.yml .eslintrc.yaml .eslintrc; do
    [ -f "$PROJECT_ROOT/$f" ] && return 0
  done
  return 1
}

TSC_PID=""
ESLINT_PID=""

if [ -f "$PROJECT_ROOT/tsconfig.json" ]; then
  (
    cd "$PROJECT_ROOT" && \
    bash "$RTK_WRAP" npx tsc --noEmit --incremental --pretty false > "$TSC_OUT_FILE" 2>&1
    echo $? > "$TSC_RC_FILE"
  ) &
  TSC_PID=$!
fi

if has_eslint_config; then
  (
    cd "$PROJECT_ROOT" && \
    bash "$RTK_WRAP" npx eslint --format unix --max-warnings=0 "$FILE_PATH" > "$ESLINT_OUT_FILE" 2>&1
    echo $? > "$ESLINT_RC_FILE"
  ) &
  ESLINT_PID=$!
fi

[ -n "$TSC_PID" ] && wait "$TSC_PID" 2>/dev/null
[ -n "$ESLINT_PID" ] && wait "$ESLINT_PID" 2>/dev/null

ERRORS=""

if [ -f "$PROJECT_ROOT/tsconfig.json" ]; then
  TSC_EXIT=$(cat "$TSC_RC_FILE" 2>/dev/null || echo 0)
  if [ "$TSC_EXIT" != "0" ]; then
    TSC_OUTPUT=$(cat "$TSC_OUT_FILE")
    RELEVANT=$(printf '%s\n' "$TSC_OUTPUT" | grep -F "$FILENAME" -A 1 | head -n $((MAX_TSC_LINES * 2)))
    OWN_BLOCK=1
    if [ -z "$RELEVANT" ]; then
      RELEVANT=$(printf '%s\n' "$TSC_OUTPUT" | head -n "$MAX_TSC_LINES")
      OWN_BLOCK=""
    fi
    RELEVANT=$(compact_block "$RELEVANT" "$MAX_TSC_LINES")
    if [ -n "$OWN_BLOCK" ]; then
      # Errors in other files that the edited-file block does not show (a context line may show one).
      OTHER=$(( $(printf '%s\n' "$TSC_OUTPUT" | grep -F -v "$FILENAME" | grep -c 'error TS') \
              - $(printf '%s\n' "$RELEVANT" | grep -F -v "$FILENAME" | grep -c 'error TS') ))
      [ "$OTHER" -gt 0 ] && RELEVANT="${RELEVANT}"$'\n'"other files: $OTHER more errors"
    fi
    if [ -n "$RELEVANT" ]; then
      ERRORS="${ERRORS}\n[TypeScript Error]\n${RELEVANT}"
    fi
  fi
fi

if has_eslint_config; then
  ESLINT_EXIT=$(cat "$ESLINT_RC_FILE" 2>/dev/null || echo 0)
  if [ "$ESLINT_EXIT" != "0" ]; then
    ESLINT_OUTPUT=$(cat "$ESLINT_OUT_FILE")
    RELEVANT=$(compact_block "$ESLINT_OUTPUT" "$MAX_ESLINT_LINES")
    if [ -n "$RELEVANT" ]; then
      ERRORS="${ERRORS}\n[ESLint Error]\n${RELEVANT}"
    fi
  fi
fi

rm -f "$TSC_OUT_FILE" "$ESLINT_OUT_FILE" "$TSC_RC_FILE" "$ESLINT_RC_FILE" 2>/dev/null

[ -n "$ERRORS" ] && emit_errors

exit 0
