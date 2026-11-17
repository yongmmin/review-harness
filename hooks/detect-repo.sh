#!/bin/bash
# detect-repo.sh
# Match current working directory (passed as $1, or $PWD) against registered
# repos and emit a compact summary. Registry files: every ~/.review-harness/knowledge/<org>/repos.md in
# sorted order, then the flat knowledge/repos.md; the first block that matches wins.
#
# Output (stdout, compact — meant to be loaded into agent context):
#   === Active Repo ===
#   - name: <repo-name>
#   - role: <one-liner>
#   - stack: <comma-list>
#   - layout: src/|app/
#   - env: <env variable the repo reads>
#   - path_alias: @/* → ...
#   - local_path: <registered path> (post-tool-use.sh runs check_cmd there)
#   - test_cmd / check_cmd: <commands> (read by detect-test-cmd.sh / post-tool-use.sh)
#   - <extra keys listed in ~/.review-harness/org/detect-repo-keys.txt, if any>
#   - doc_routing: <path>
#   === End Active Repo ===
#
# If no match: prints a "not registered" notice and exits 0 (non-fatal).

set -e

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# No registry → exit silently below. find-consumers.sh and register-repo read the same list.
RH_HOME="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}"
REPOS_FILES=()
for f in "$RH_HOME"/knowledge/*/repos.md "$RH_HOME/knowledge/repos.md"; do
  if [ -f "$f" ]; then REPOS_FILES+=("$f"); fi
done
CWD="${1:-$PWD}"

# Resolve to absolute path (handles ~ expansion if caller did it)
ABS_CWD=$(cd "$CWD" 2>/dev/null && pwd || echo "$CWD")

if [ ${#REPOS_FILES[@]} -eq 0 ]; then
  exit 0
fi

# Find the first repo whose local_path is a prefix of ABS_CWD
# Awk pass: read every registry file in order, capture the most recent ### heading as repo name,
# emit the file and the name when local_path matches.
FOUND=$(awk -v cwd="$ABS_CWD" '
  FNR == 1 { repo = "" }
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
        print FILENAME
        print repo
        exit
      }
    }
  }
' "${REPOS_FILES[@]}")
REPOS_FILE=$(printf '%s\n' "$FOUND" | sed -n 1p)
MATCHED=$(printf '%s\n' "$FOUND" | sed -n 2p)

if [ -z "$MATCHED" ]; then
  echo "=== Active Repo ==="
  echo "- status: not registered"
  echo "- cwd: $ABS_CWD"
  # Org overlays can supply their own hint line (~/.review-harness/org/detect-repo-hint.txt).
  HINT=$(head -n 1 "$RH_HOME/org/detect-repo-hint.txt" 2>/dev/null) || true  # set -e: a missing file must not cut the block
  echo "- hint: ${HINT:-register the repo in ${REPOS_FILES[0]}}"
  echo "=== End Active Repo ==="
  exit 0
fi

# Emit the matched repo's metadata block (between its ### header and the next ###) from the file that matched
# Registry keys to print. Org overlays can add their own keys (one per line).
KEYS="local_path|role|stack|layout|env|path_alias|doc_routing|tests|test_cmd|check_cmd|port|special|status"
EXTRA_KEYS=$(grep -E '^[A-Za-z0-9_]+$' "$RH_HOME/org/detect-repo-keys.txt" 2>/dev/null | paste -sd'|' -)
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
