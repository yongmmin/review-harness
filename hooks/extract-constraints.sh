#!/bin/bash
# extract-constraints.sh
# Usage: extract-constraints.sh <agent-name>
# Prints only constraints.md sections relevant to the given agent.
# front-harness MUST call this before spawning an agent instead of passing the whole file.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSTRAINTS="$PLUGIN_DIR/constraints.md"
AGENT="${1:-}"

if [ -z "$AGENT" ]; then
  echo "usage: extract-constraints.sh <agent-name>" >&2
  exit 2
fi

if [ ! -f "$CONSTRAINTS" ]; then
  exit 0
fi

# Section tag → target agents (mirrors table in constraints.md)
case "$AGENT" in
  developer|ui-builder)
    SECTIONS="code-rules filesystem completion org"
    ;;
  test-runner)
    SECTIONS="completion failure-patterns"
    ;;
  reviewer)
    SECTIONS="review failure-patterns org"
    ;;
  refactor-architect|component-auditor)
    SECTIONS="code-rules org"
    ;;
  *)
    exit 0
    ;;
esac

# Extract each section from first `## #tag` heading to next `## ` or `---`
# `org` is the organisation-specific section: it lives in the gitignored private/constraints.md
# and is simply absent in a fresh clone.
ORG_CONSTRAINTS="$PLUGIN_DIR/private/constraints.md"
extract_section() {
  local tag="$1" file="$CONSTRAINTS"
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

# Org overlay for this agent (private/agents/<agent>.md) — the organisation-specific part of
# the agent's instructions. Absent in a fresh clone.
AGENT_OVERLAY=$(bash "$PLUGIN_DIR/hooks/org-overlay.sh" agents "$AGENT" 2>/dev/null)
if [ -n "$AGENT_OVERLAY" ]; then
  OUTPUT="${OUTPUT}## Org overlay — ${AGENT} (part of this agent's instructions)"$'\n\n'"${AGENT_OVERLAY}"$'\n'
fi

printf '%s' "$OUTPUT"

# Token budget instrumentation. 8KB ≈ 2K tokens at ~4 chars/token.
# Emits to stderr only — never pollutes stdout consumed by the agent.
BUDGET_WARN_BYTES="${FE_HARNESS_BUDGET_WARN_BYTES:-8192}"
BYTES=$(printf '%s' "$OUTPUT" | wc -c | tr -d ' ')
APPROX_TOKENS=$((BYTES / 4))
if [ "$BYTES" -gt "$BUDGET_WARN_BYTES" ]; then
  printf '[token-budget][warn] extract-constraints %s: %s bytes (~%s tokens) exceeds %s\n' \
    "$AGENT" "$BYTES" "$APPROX_TOKENS" "$BUDGET_WARN_BYTES" >&2
else
  printf '[token-budget] extract-constraints %s: %s bytes (~%s tokens)\n' \
    "$AGENT" "$BYTES" "$APPROX_TOKENS" >&2
fi
