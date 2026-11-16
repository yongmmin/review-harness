#!/bin/bash
# detect-repo.sh
# Match current working directory (passed as $1, or $PWD) against registered
# repos in knowledge/<org>/repos.md (gitignored, org-specific) and emit a compact summary.
#
# Output (stdout, compact — meant to be loaded into agent context):
#   === Active Repo ===
#   - name: <repo-name>
#   - role: <one-liner>
#   - stack: <comma-list>
#   - layout: src/|app/
#   - env: <env variable the repo reads>
#   - path_alias: @/* → ...
#   - <extra keys listed in private/detect-repo-keys.txt, if any>
#   - doc_routing: <path>
#   === End Active Repo ===
#
# If no match: prints a "not registered" notice and exits 0 (non-fatal).

set -e

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# First registry found wins. No registry (fresh clone) → exit silently below.
REPOS_FILE=$(ls "$PLUGIN_DIR"/knowledge/*/repos.md 2>/dev/null | head -n 1)
REPOS_FILE="${REPOS_FILE:-$PLUGIN_DIR/knowledge/repos.md}"
CWD="${1:-$PWD}"

# Resolve to absolute path (handles ~ expansion if caller did it)
ABS_CWD=$(cd "$CWD" 2>/dev/null && pwd || echo "$CWD")

if [ ! -f "$REPOS_FILE" ]; then
  exit 0
fi

# Find the first repo whose local_path is a prefix of ABS_CWD
# Awk pass: read repos.md, capture the most recent ### heading as repo name,
# emit when local_path matches.
MATCHED=$(awk -v cwd="$ABS_CWD" '
  /^### / {
    repo = $0
    sub(/^### */, "", repo)
    next
  }
  /^- \*\*local_path\*\*:/ {
    # Extract path between backticks
    line = $0
    if (match(line, /`[^`]+`/)) {
      path = substr(line, RSTART + 1, RLENGTH - 2)
      # Match only on path boundaries: exact repo root, or a subdirectory of it.
      # Bare prefix match would misroute e.g. my-app-api → my-app.
      if (cwd == path || index(cwd, path "/") == 1) {
        print repo
        exit
      }
    }
  }
' "$REPOS_FILE")

if [ -z "$MATCHED" ]; then
  echo "=== Active Repo ==="
  echo "- status: not registered"
  echo "- cwd: $ABS_CWD"
  # Org overlays can supply their own hint line (private/detect-repo-hint.txt).
  HINT=$(head -n 1 "$PLUGIN_DIR/private/detect-repo-hint.txt" 2>/dev/null)
  echo "- hint: ${HINT:-register the repo in ${REPOS_FILE#$PLUGIN_DIR/}}"
  echo "=== End Active Repo ==="
  exit 0
fi

# Emit the matched repo's metadata block (between its ### header and the next ###)
# Registry keys to print. Org overlays can add their own keys (one per line).
KEYS="role|stack|layout|env|path_alias|doc_routing|tests|port|special|status"
EXTRA_KEYS=$(grep -E '^[A-Za-z0-9_]+$' "$PLUGIN_DIR/private/detect-repo-keys.txt" 2>/dev/null | paste -sd'|' -)
[ -n "$EXTRA_KEYS" ] && KEYS="$KEYS|$EXTRA_KEYS"

awk -v target="$MATCHED" -v keys="$KEYS" '
  /^### / {
    repo = $0
    sub(/^### */, "", repo)
    if (repo == target) {
      printing = 1
      print "=== Active Repo ==="
      print "- name: " repo
      next
    } else if (printing) {
      exit
    }
  }
  printing && $0 ~ ("^- \\*\\*(" keys ")\\*\\*:") {
    # Strip markdown bold markers for cleaner output
    line = $0
    gsub(/\*\*/, "", line)
    print line
  }
  END {
    if (printing) print "=== End Active Repo ==="
  }
' "$REPOS_FILE"
