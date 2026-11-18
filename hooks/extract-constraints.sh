#!/bin/bash
# extract-constraints.sh
# Usage: extract-constraints.sh <agent-name> [profile[,profile...]]
# Prints only constraints.md sections relevant to the given agent (the failure-pattern ledger comes from
# ~/.review-harness/failure-patterns.md, with its path on a `ledger:` line), then — for each profile named —
# the agent's sections of profiles/<profile>.md (stack-specific rules), followed by the same sections of the
# org file ~/.review-harness/org/profiles/<profile>.md when present. There is no default profile;
# an empty list (e.g. empty detect-profile.sh output) means none. The developer also gets a
# `## Review checklist` block: the rule lines of every #review section and of the ledger.
# review-harness MUST call this before spawning an agent instead of passing the whole file.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSTRAINTS="$PLUGIN_DIR/constraints.md"
AGENT="${1:-}"
PROFILES="${2:-}"
set -f   # the profile list is word-split below; never glob-expand it
PROFILE_LIST=$(printf '%s' "$PROFILES" | tr ',' ' ')

if [ -z "$AGENT" ]; then
  echo "usage: extract-constraints.sh <agent-name> [profile[,profile...]]" >&2
  exit 2
fi
for PROFILE in $PROFILE_LIST; do
  case "$PROFILE" in */*|.*) echo "usage: extract-constraints.sh <agent-name> [profile[,profile...]]" >&2; exit 2 ;; esac
  # Fail closed: a mistyped profile must not silently drop every stack rule.
  if [ ! -f "$PLUGIN_DIR/profiles/$PROFILE.md" ]; then
    echo "extract-constraints: unknown profile '$PROFILE'" >&2
    exit 2
  fi
done

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

# Extract each section from its `## #tag` heading to the next `## #` heading
# `org` is the organisation-specific section: it lives in ~/.review-harness/org/constraints.md
# and is simply absent when no organisation overlay is installed.
# `failure-patterns` is the per-user ledger ~/.review-harness/failure-patterns.md (outside the plugin, so a
# plugin update never overwrites it); its agents also get a `ledger: <path>` line to append to.
RH_HOME="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}"
ORG_CONSTRAINTS="$RH_HOME/org/constraints.md"
LEDGER="$RH_HOME/failure-patterns.md"
extract_section() {
  local tag="$1" file="${2:-$CONSTRAINTS}"
  [ "$tag" = org ] && file="$ORG_CONSTRAINTS"
  [ "$tag" = failure-patterns ] && { file="$LEDGER"; printf 'ledger: %s\n\n' "$LEDGER"; }
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

# Stack profiles (profiles/<profile>.md): same `## #tag` format, one block per profile in the order given,
# kept apart so their bytes are reported separately.
PROFILE_OUT=""
for PROFILE in $PROFILE_LIST; do
  ONE_OUT=""
  for tag in $PROFILE_SECTIONS; do
    SECTION_OUT=$(extract_section "$tag" "$PLUGIN_DIR/profiles/$PROFILE.md")
    [ -n "$SECTION_OUT" ] && ONE_OUT="${ONE_OUT}${SECTION_OUT}"$'\n\n'
  done
  # Org rules for this profile (~/.review-harness/org/profiles/<profile>.md): loaded only with the profile.
  ORG_OUT=""
  for tag in $PROFILE_SECTIONS; do
    SECTION_OUT=$(extract_section "$tag" "$RH_HOME/org/profiles/$PROFILE.md")
    [ -n "$SECTION_OUT" ] && ORG_OUT="${ORG_OUT}${SECTION_OUT}"$'\n\n'
  done
  [ -n "$ORG_OUT" ] && ONE_OUT="${ONE_OUT}### Org rules — ${PROFILE}"$'\n\n'"${ORG_OUT}"
  [ -n "$ONE_OUT" ] && PROFILE_OUT="${PROFILE_OUT}## Profile — ${PROFILE} (part of this agent's instructions)"$'\n\n'"${ONE_OUT}"
done

# Developer only: what the reviewer FAILs on — the rule lines of #review (constraints, each profile, its org
# profile) and the ledger entries — as one checklist. Rule lines only: no prose, no headings and no `ledger:`
# line, so the developer never gets a path to append to. Its bytes are reported apart from the threshold.
CHECKLIST_OUT=""
if [ "$AGENT" = developer ]; then
  CHECKLIST=$( {
    extract_section review
    for PROFILE in $PROFILE_LIST; do
      extract_section review "$PLUGIN_DIR/profiles/$PROFILE.md"
      extract_section review "$RH_HOME/org/profiles/$PROFILE.md"
    done
    extract_section failure-patterns
  } | grep '^- ')
  [ -n "$CHECKLIST" ] && CHECKLIST_OUT="## Review checklist — the reviewer FAILs on these (check your diff before handoff)"$'\n\n'"${CHECKLIST}"$'\n\n'
fi

# Org overlay for this agent (~/.review-harness/org/agents/<agent>.md) — the organisation-specific part of
# the agent's instructions. Absent when no overlay is installed.
AGENT_OVERLAY=$(bash "$PLUGIN_DIR/hooks/org-overlay.sh" agents "$AGENT" 2>/dev/null)
OVERLAY_OUT=""
if [ -n "$AGENT_OVERLAY" ]; then
  OVERLAY_OUT="## Org overlay — ${AGENT} (part of this agent's instructions)"$'\n\n'"${AGENT_OVERLAY}"$'\n'
fi

# `${CLAUDE_PLUGIN_ROOT}` in the text → the plugin path (same substitution as org-overlay.sh): this is
# command output, so skill substitution never reaches it.
printf '%s%s%s%s' "$OUTPUT" "$PROFILE_OUT" "$CHECKLIST_OUT" "$OVERLAY_OUT" \
  | awk -v root="$PLUGIN_DIR" '{ out=""; s=$0; while ((i = index(s, "${CLAUDE_PLUGIN_ROOT}")) > 0) { out = out substr(s, 1, i-1) root; s = substr(s, i + 21) } print out s }'

# Token budget instrumentation. 8KB ≈ 2K tokens at ~4 chars/token.
# Emits to stderr only — never pollutes stdout consumed by the agent.
# The threshold measures the non-profile part; profile and checklist bytes are reported separately (moving
# rules into a profile does not change total agent context, so it must not trip the warning).
BUDGET_WARN_BYTES="${REVIEW_HARNESS_BUDGET_WARN_BYTES:-8192}"
BYTES=$(printf '%s%s' "$OUTPUT" "$OVERLAY_OUT" | wc -c | tr -d ' ')
APPROX_TOKENS=$((BYTES / 4))
PROFILE_NOTE=""
if [ -n "$PROFILE_LIST" ]; then
  PROFILE_BYTES=$(printf '%s' "$PROFILE_OUT" | wc -c | tr -d ' ')
  PROFILE_NOTE=$(printf ' + profile %s: %s bytes (~%s tokens)' "$PROFILES" "$PROFILE_BYTES" "$((PROFILE_BYTES / 4))")
fi
if [ -n "$CHECKLIST_OUT" ]; then
  CHECKLIST_BYTES=$(printf '%s' "$CHECKLIST_OUT" | wc -c | tr -d ' ')
  PROFILE_NOTE=$(printf '%s + checklist: %s bytes (~%s tokens)' "$PROFILE_NOTE" "$CHECKLIST_BYTES" "$((CHECKLIST_BYTES / 4))")
fi
if [ "$BYTES" -gt "$BUDGET_WARN_BYTES" ]; then
  printf '[token-budget][warn] extract-constraints %s: %s bytes (~%s tokens) exceeds %s%s\n' \
    "$AGENT" "$BYTES" "$APPROX_TOKENS" "$BUDGET_WARN_BYTES" "$PROFILE_NOTE" >&2
else
  printf '[token-budget] extract-constraints %s: %s bytes (~%s tokens)%s\n' \
    "$AGENT" "$BYTES" "$APPROX_TOKENS" "$PROFILE_NOTE" >&2
fi
