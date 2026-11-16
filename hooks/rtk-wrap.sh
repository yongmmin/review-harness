#!/bin/bash
# rtk-wrap.sh — Plugin-scoped rtk command wrapper.
#
# Goal: let /front-harness opt into rtk per session without affecting any
# other Claude Code project on the machine (no global hook installed).
#
# Resolution order for mode:
#   1. FE_HARNESS_RTK env var — hard override
#        off | standard | aggressive | git-only
#   2. <state dir>/rtk-session.flag — set by /front-harness UI or /rtk
#        (state dir = ~/.front-harness/state/<repo-id>/, see state-dir.sh; per work tree)
#   3. default: off
#
# Usage:
#   bash hooks/rtk-wrap.sh <command> [args...]
#     - Decides whether to prefix with `rtk` based on mode + command kind.
#     - Always execs the command; falls back to raw if rtk missing or off.
#
#   bash hooks/rtk-wrap.sh --mode
#     - Prints resolved mode string (off/standard/aggressive/git-only).
#
#   bash hooks/rtk-wrap.sh --set <mode>
#     - Writes mode to session flag file.
#
#   bash hooks/rtk-wrap.sh --clear
#     - Removes session flag file.
#
#   bash hooks/rtk-wrap.sh --has-flag
#     - Prints "present" or "absent".

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Nothing is written into the consumer repo or the plugin dir: the flag lives in the state dir.
STATE_DIR="$(bash "$PLUGIN_DIR/hooks/state-dir.sh" "$PWD" 2>/dev/null)"
FLAG_FILE="${STATE_DIR:-/nonexistent}/rtk-session.flag"

resolve_mode() {
  if [ -n "${FE_HARNESS_RTK:-}" ]; then
    printf '%s\n' "$FE_HARNESS_RTK"
    return
  fi
  if [ -f "$FLAG_FILE" ]; then
    local val
    val=$(head -n 1 "$FLAG_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$val" ]; then
      printf '%s\n' "$val"
      return
    fi
  fi
  printf 'off\n'
}

# Maps a command binary to an rtk subcommand category, or empty if rtk has no handler.
rtk_handles() {
  local cmd="$1"
  case "$cmd" in
    git|gh)                   echo "git" ;;
    tsc|eslint|biome|prettier|ruff|rubocop|golangci-lint) echo "lint" ;;
    next)                     echo "build" ;;
    jest|vitest|playwright|pytest|rspec|rake)             echo "test" ;;
    cargo|go)                                             echo "build" ;;
    ls|tree|cat|read|find|grep|rg|diff|json|docker|kubectl|aws|curl|wget|log|env|deps)
                              echo "other" ;;
    *)                        echo "" ;;
  esac
}

should_prefix() {
  local mode="$1" category="$2"
  [ -z "$category" ] && return 1
  case "$mode" in
    off)         return 1 ;;
    git-only)    [ "$category" = "git" ] && return 0 || return 1 ;;
    standard|aggressive) return 0 ;;
    *)           return 1 ;;
  esac
}

case "${1:-}" in
  --mode)
    resolve_mode
    exit 0
    ;;
  --set)
    shift
    [ -n "$STATE_DIR" ] || { echo "rtk-wrap: cannot resolve state dir" >&2; exit 1; }
    bash "$PLUGIN_DIR/hooks/state-dir.sh" --create "$PWD" >/dev/null
    printf '%s\n' "${1:-off}" > "$FLAG_FILE"
    exit 0
    ;;
  --clear)
    rm -f "$FLAG_FILE"
    exit 0
    ;;
  --has-flag)
    [ -f "$FLAG_FILE" ] && echo present || echo absent
    exit 0
    ;;
  "")
    echo "usage: rtk-wrap.sh <command> [args...] | --mode | --set <mode> | --clear | --has-flag" >&2
    exit 2
    ;;
esac

MODE=$(resolve_mode)
CMD="$1"; shift
CATEGORY=$(rtk_handles "$CMD")

# Strip npx prefix when deciding category (npx tsc → tsc category)
if [ "$CMD" = "npx" ] && [ -n "${1:-}" ]; then
  CATEGORY=$(rtk_handles "$1")
fi

if should_prefix "$MODE" "$CATEGORY" && command -v rtk >/dev/null 2>&1; then
  EXTRA=""
  if [ "$MODE" = "aggressive" ]; then
    EXTRA="-u"
  fi
  # Preserve the original command as-is (npx included) — stripping npx would
  # make rtk resolve tsc/eslint globally and miss node_modules/.bin binaries.
  exec rtk $EXTRA "$CMD" "$@"
fi

exec "$CMD" "$@"
