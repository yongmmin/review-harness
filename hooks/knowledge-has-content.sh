#!/bin/bash
# knowledge-has-content.sh
# Exit 0 if knowledge/* contains any real content beyond placeholders.
# Exit 1 if only placeholders or empty. review-harness uses this to skip
# spawning search-knowledge agent when nothing would be found.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KNOWLEDGE_DIR="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/knowledge"

if [ ! -d "$KNOWLEDGE_DIR" ]; then
  exit 1
fi

# Also check global wisdom summary (search-knowledge reads this first)
WISDOM_DIR="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/wisdom"
WISDOM_SUMMARY="$WISDOM_DIR/summary.md"

# Placeholder patterns indicating "no real content yet"
PLACEHOLDER_RE='(_No .* yet\.?_|_none_|_none —_)'

has_real_content() {
  local file="$1"
  [ ! -f "$file" ] && return 1
  local remaining
  remaining=$(grep -vE '^[[:space:]]*(#|>|\||---|$)' "$file" \
    | grep -vE "$PLACEHOLDER_RE" \
    | grep -vE '^[[:space:]]*-[[:space:]]*(_none_|—)' \
    | sed '/^[[:space:]]*$/d')
  [ -n "$remaining" ]
}

# Check each candidate file; first hit wins.
# Knowledge tree: ~/.review-harness/knowledge/index.md + ~/.review-harness/knowledge/<org>/*.md
# (unmatched glob passes through as a literal path and fails the -f check).
for f in \
  "$WISDOM_SUMMARY" \
  "$KNOWLEDGE_DIR/index.md" \
  "$KNOWLEDGE_DIR"/*/*.md \
  "$WISDOM_DIR/learnings.md" \
  "$WISDOM_DIR/decisions.md" \
  "$WISDOM_DIR/issues.md"
do
  if has_real_content "$f"; then
    exit 0
  fi
done

exit 1
