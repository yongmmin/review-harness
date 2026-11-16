#!/bin/bash
# org-overlay.sh <skills|agents> <name>
# Prints the private, organisation-specific overlay for a skill or agent:
#   <plugin>/private/<kind>/<name>.md
# `private/` is gitignored — it holds everything that is specific to one organisation
# (repo names, internal conventions, QA process). The tracked files stay generic.
# No overlay installed (fresh clone) → prints nothing and the generic rules apply alone.
# `${CLAUDE_PLUGIN_ROOT}` inside an overlay is replaced with the plugin path, because
# overlay text is command output and does not go through skill substitution.
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in skills|agents) ;; *) echo "usage: org-overlay.sh <skills|agents> <name>" >&2; exit 2 ;; esac
case "${2:-}" in ""|*/*|.*) echo "usage: org-overlay.sh <skills|agents> <name>" >&2; exit 2 ;; esac
f="$PLUGIN_DIR/private/$1/$2.md"
[ -f "$f" ] || exit 0
awk -v root="$PLUGIN_DIR" '{ out=""; s=$0; while ((i = index(s, "${CLAUDE_PLUGIN_ROOT}")) > 0) { out = out substr(s, 1, i-1) root; s = substr(s, i + 21) } print out s }' "$f"
