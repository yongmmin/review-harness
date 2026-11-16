#!/bin/bash
# extract-constraints.sh
# Usage: extract-constraints.sh <agent-name> [profile]
# Prints only constraints.md sections relevant to the given agent, then — when a profile is named —
# the agent's sections of profiles/<profile>.md (stack-specific rules). There is no default profile.
# review-harness MUST call this before spawning an agent instead of passing the whole file.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSTRAINTS="$PLUGIN_DIR/constraints.md"
AGENT="${1:-}"
PROFILE="${2:-}"

if [ -z "$AGENT" ]; then
  echo "usage: extract-constraints.sh <agent-name> [profile]" >&2
  exit 2
fi
case "$PROFILE" in */*|.*) echo "usage: extract-constraints.sh <agent-name> [profile]" >&2; exit 2 ;; esac
PROFILE_FILE="$PLUGIN_DIR/profiles/$PROFILE.md"
# Fail closed: a mistyped profile must not silently drop every stack rule.
if [ -n "$PROFILE" ] && [ ! -f "$PROFILE_FILE" ]; then
  echo "extract-constraints: unknown profile '$PROFILE'" >&2
  exit 2
fi

if [ ! -f "$CONSTRAINTS" ]; then
  exit 0
fi

# Section tag → target agents (mirrors the tables in constraints.md and profiles/*.md)
case "$AGENT" in
  developer)
    SECTIONS="code-rules filesystem completion org"
    PROFILE_SECTIONS="code-rules implementation"
    ;;
  test-runner)
    SECTIONS="completion failure-patterns"
    PROFILE_SECTIONS=""
    ;;
  reviewer)
    SECTIONS="review failure-patterns org"
    PROFILE_SECTIONS="review"
    ;;
  refactor-architect)
    SECTIONS="code-rules org"
    PROFILE_SECTIONS="code-rules detection"
    ;;
  *)
    exit 0
    ;;
esac

# Extract each section from first `## #tag` heading to next `## ` or `---`
# `org` is the organisation-specific section: it lives in ~/.review-harness/org/constraints.md
# and is simply absent when no organisation overlay is installed.
FH_HOME="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}"
ORG_CONSTRAINTS="$FH_HOME/org/constraints.md"
extract_section() {
  local tag="$1" file="${2:-$CONSTRAINTS}"
  [ "$tag" = org ] && file="$ORG_CONSTRAINTS"
  [ -f "$file" ] || return 0
  awk -v tag="## #$tag" '
    BEGIN { printing = 0 }
    $0 == tag { printing = 1; print; next }
    printing && /^## #/ { exit }
    printing { print }
  ' "$file"
}

OUTPUT=""
for tag in $SECTIONS; do
  SECTION_OUT=$(extract_section "$tag")
  OUTPUT="${OUTPUT}${SECTION_OUT}"$'\n\n'
done

# Stack profile (profiles/<profile>.md): same `## #tag` format, kept apart so its bytes are reported separately.
PROFILE_OUT=""
if [ -n "$PROFILE" ]; then
  for tag in $PROFILE_SECTIONS; do
    SECTION_OUT=$(extract_section "$tag" "$PROFILE_FILE")
    [ -n "$SECTION_OUT" ] && PROFILE_OUT="${PROFILE_OUT}${SECTION_OUT}"$'\n\n'
  done
  [ -n "$PROFILE_OUT" ] && PROFILE_OUT="## Profile — ${PROFILE} (part of this agent's instructions)"$'\n\n'"${PROFILE_OUT}"
fi

# Org overlay for this agent (~/.review-harness/org/agents/<agent>.md) — the organisation-specific part of
# the agent's instructions. Absent when no overlay is installed.
AGENT_OVERLAY=$(bash "$PLUGIN_DIR/hooks/org-overlay.sh" agents "$AGENT" 2>/dev/null)
OVERLAY_OUT=""
if [ -n "$AGENT_OVERLAY" ]; then
  OVERLAY_OUT="## Org overlay — ${AGENT} (part of this agent's instructions)"$'\n\n'"${AGENT_OVERLAY}"$'\n'
fi

printf '%s%s%s' "$OUTPUT" "$PROFILE_OUT" "$OVERLAY_OUT"

# Token budget instrumentation. 8KB ≈ 2K tokens at ~4 chars/token.
# Emits to stderr only — never pollutes stdout consumed by the agent.
# The threshold measures the non-profile part; profile bytes are reported separately (moving rules into a
# profile does not change total agent context, so it must not trip the warning).
BUDGET_WARN_BYTES="${REVIEW_HARNESS_BUDGET_WARN_BYTES:-8192}"
BYTES=$(printf '%s%s' "$OUTPUT" "$OVERLAY_OUT" | wc -c | tr -d ' ')
APPROX_TOKENS=$((BYTES / 4))
PROFILE_NOTE=""
if [ -n "$PROFILE" ]; then
  PROFILE_BYTES=$(printf '%s' "$PROFILE_OUT" | wc -c | tr -d ' ')
  PROFILE_NOTE=$(printf ' + profile %s: %s bytes (~%s tokens)' "$PROFILE" "$PROFILE_BYTES" "$((PROFILE_BYTES / 4))")
fi
if [ "$BYTES" -gt "$BUDGET_WARN_BYTES" ]; then
  printf '[token-budget][warn] extract-constraints %s: %s bytes (~%s tokens) exceeds %s%s\n' \
    "$AGENT" "$BYTES" "$APPROX_TOKENS" "$BUDGET_WARN_BYTES" "$PROFILE_NOTE" >&2
else
  printf '[token-budget] extract-constraints %s: %s bytes (~%s tokens)%s\n' \
    "$AGENT" "$BYTES" "$APPROX_TOKENS" "$PROFILE_NOTE" >&2
fi
