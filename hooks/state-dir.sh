#!/bin/bash
# state-dir.sh [--create] [dir]
# Prints the per-work-tree state directory: ~/.review-harness/state/<id>/
# Everything the plugin writes at runtime (run-state.json, plan.md, rtk-session.flag,
# approved/, cache/) lives there, so nothing is created inside the consumer repo.
# <id> = <work-tree basename>-<sha1(absolute work-tree path)[0:12]> — parallel git
# worktrees have different absolute paths, so each gets its own state.
# --create also makes the directory and records the work-tree path in <id>/repo-path.
CREATE=0
[ "${1:-}" = "--create" ] && { CREATE=1; shift; }
dir="${1:-$PWD}"
[ -d "$dir" ] || dir=$(dirname "$dir")
root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
[ -z "$root" ] && root=$(cd "$dir" 2>/dev/null && pwd -P)
[ -z "$root" ] && { echo "state-dir: cannot resolve $dir" >&2; exit 1; }
id="$(basename "$root" | tr -c 'A-Za-z0-9._\n-' '_')-$(printf '%s' "$root" | shasum | cut -c1-12)"
state="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/state/$id"
if [ "$CREATE" = 1 ]; then
  mkdir -p "$state" || exit 1
  [ -f "$state/repo-path" ] || printf '%s\n' "$root" > "$state/repo-path"
fi
printf '%s\n' "$state"
