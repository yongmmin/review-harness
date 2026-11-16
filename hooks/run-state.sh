#!/bin/bash
# run-state.sh — file-backed run state for the review-harness review gate.
# State file: <state dir>/run-state.json (see state-dir.sh). Run it from the consumer repo.
# The script computes every value itself (attempt counter, timestamps, work-tree hash);
# callers never pass numbers or hashes.
#
#   start <workflow> [step...]  create a run; refuses while another run is active
#   step <name>                 mark a step done
#   attempt                     count a failed attempt (test failure); exit 2 at the limit
#   verdict PASS|FAIL           record the reviewer verdict + work-tree hash; FAIL counts as an attempt
#   override <reason>           record an explicit user override for the current work tree
#   check [--active-only]       commit gate. exit 0 ok · 1 blocked · 3 nothing to enforce · 4 stale run
#   done | abandon              close the run
#   status                      one-line summary ("none" when there is nothing to resume)
#   hash                        print the current work-tree hash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_ATTEMPTS=3
STALE_SECONDS="${REVIEW_HARNESS_RUN_STALE_SECONDS:-86400}"

command -v jq >/dev/null 2>&1 || { echo "run-state: jq is required" >&2; exit 3; }
STATE_DIR=$(bash "$HERE/state-dir.sh" "$PWD") || exit 3
FILE="$STATE_DIR/run-state.json"

now() { date +%s; }
st() { { [ -f "$FILE" ] && jq -er '.status' "$FILE" 2>/dev/null; } || echo none; }
get() { jq -r "$1" "$FILE" 2>/dev/null; }
need_file() { [ -f "$FILE" ] || { echo "run-state: no run state. Call: run-state.sh start <workflow> [step...]" >&2; exit 1; }; }

# Hash of the whole work tree (tracked + untracked, .gitignore respected), taken through a
# throwaway copy of the index. It changes only when file content changes: `git add` and
# `git commit` leave it untouched, so a review stays valid across staging and commit units.
tree_hash() {
  local root idx tmp tree
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "nogit"; return; }
  tmp=$(mktemp -d) || { echo "error"; return; }
  idx=$(git -C "$root" rev-parse --git-path index 2>/dev/null)
  case "$idx" in /*) ;; *) idx="$root/$idx" ;; esac
  # -p keeps the index mtime: git's racy-timestamp check compares file mtimes against it, and a
  # fresh mtime would make a same-second, same-size edit look unchanged.
  [ -f "$idx" ] && cp -p "$idx" "$tmp/index"
  tree=$(GIT_INDEX_FILE="$tmp/index" git -C "$root" add -A . >/dev/null 2>&1 \
         && GIT_INDEX_FILE="$tmp/index" git -C "$root" write-tree 2>/dev/null)
  rm -rf "$tmp"
  [ -n "$tree" ] && echo "$tree" || echo "error"
}

# update [jq opts...] <filter> — apply the filter, bump updated_at, write atomically.
update() {
  local filter="${*: -1}" tmp="$FILE.$$.tmp"
  set -- "${@:1:$#-1}"
  jq --argjson now "$(now)" "$@" "($filter) | .updated_at = \$now" "$FILE" > "$tmp" && mv -f "$tmp" "$FILE"
}

new_file() { # $1 workflow, $2 status, $3 steps json
  mkdir -p "$STATE_DIR" && bash "$HERE/state-dir.sh" --create "$PWD" >/dev/null
  jq -n --arg wf "$1" --arg s "$2" --argjson steps "$3" --argjson now "$(now)" --argjson max "$MAX_ATTEMPTS" \
    '{version:1, workflow:$wf, status:$s, started_at:$now, updated_at:$now, steps:$steps,
      attempts:0, max_attempts:$max, review:null, override:null}' > "$FILE.$$.tmp" && mv -f "$FILE.$$.tmp" "$FILE"
}

is_stale() { [ "$(st)" = active ] && [ $(( $(now) - $(get '.updated_at // 0') )) -gt "$STALE_SECONDS" ]; }

report_attempts() {
  local n; n=$(get '.attempts')
  if [ "$n" -ge "$MAX_ATTEMPTS" ]; then
    echo "attempts: $n/$MAX_ATTEMPTS — LIMIT REACHED. Stop retrying and report the remaining failures / fix list to the user."
    return 2
  fi
  echo "attempts: $n/$MAX_ATTEMPTS — retry allowed"
}

case "${1:-}" in
  start)
    [ -z "${2:-}" ] && { echo "usage: run-state.sh start <workflow> [step...]" >&2; exit 2; }
    if [ "$(st)" = active ]; then
      echo "run-state: an active run already exists ($("$0" status)). Ask the user whether to resume it, or run 'run-state.sh abandon' and start again." >&2
      exit 1
    fi
    wf="$2"; shift 2
    steps=$(printf '%s\n' "$@" | jq -R . | jq -cs 'map(select(length > 0) | {name: ., done: false})')
    new_file "$wf" active "$steps" && echo "run-state: started '$wf' → $FILE"
    ;;
  step)
    need_file; [ -z "${2:-}" ] && { echo "usage: run-state.sh step <name>" >&2; exit 2; }
    update --arg n "$2" 'if any(.steps[]; .name == $n) then .steps |= map(if .name == $n then .done = true else . end)
                         else .steps += [{name: $n, done: true}] end' && echo "step done: $2"
    ;;
  attempt)
    need_file; update '.attempts += 1' && report_attempts
    ;;
  verdict)
    v=$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')
    case "$v" in PASS|FAIL) ;; *) echo "usage: run-state.sh verdict PASS|FAIL" >&2; exit 2 ;; esac
    # No active run (standalone /code-review): keep the verdict in an idle record so a later
    # /git-commit can check it, without making the commit hook enforce anything.
    [ "$(st)" = active ] || new_file review idle '[]'
    h=$(tree_hash)
    update --arg v "$v" --arg h "$h" '.review = {verdict: $v, tree: $h, at: $now}
      | if $v == "FAIL" then .attempts += 1 else . end
      | if $v == "PASS" and any(.steps[]; .name == "reviewer") then .steps |= map(if .name == "reviewer" then .done = true else . end) else . end' || exit 1
    echo "review: $v recorded for work tree $h"
    [ "$v" = FAIL ] && { report_attempts; exit $?; }
    ;;
  override)
    [ -z "${2:-}" ] && { echo "usage: run-state.sh override <reason>" >&2; exit 2; }
    [ -f "$FILE" ] && [ "$(st)" != none ] || new_file review idle '[]'
    h=$(tree_hash)
    update --arg r "$2" --arg h "$h" '.override = {reason: $r, tree: $h, at: $now}' && echo "override recorded for work tree $h: $2"
    ;;
  check)
    s=$(st)
    case "$s" in none|abandoned) echo "run-state: none"; exit 3 ;; esac
    if [ "${2:-}" = "--active-only" ] && [ "$s" != active ]; then echo "run-state: no active run"; exit 3; fi
    if is_stale; then
      echo "run-state: STALE — the active '$(get .workflow)' run has not been updated for over $((STALE_SECONDS / 3600))h ($FILE). The review gate is not enforced for it. Ask the user whether to resume that run or drop it (run-state.sh abandon)."
      exit 4
    fi
    h=$(tree_hash)
    if [ "$(get '.override.tree // ""')" = "$h" ]; then echo "ok: user override recorded ($(get .override.reason))"; exit 0; fi
    case "$(get '.review.verdict // "none"')" in
      none) echo "blocked: no reviewer verdict is recorded for this run. Run the reviewer first."; exit 1 ;;
      FAIL) echo "blocked: the last reviewer verdict is FAIL. Fix the issues and re-run the reviewer."; exit 1 ;;
    esac
    if [ "$h" = error ] || [ "$(get .review.tree)" != "$h" ]; then
      echo "blocked: code changed after the review (reviewed work tree $(get .review.tree), current $h). Re-run the reviewer on the current changes."
      exit 1
    fi
    echo "ok: reviewer PASS matches the current work tree ($h)"
    ;;
  done|abandon)
    [ -f "$FILE" ] || { echo "run-state: none"; exit 0; }
    [ "$1" = done ] && new=done || new=abandoned
    update --arg s "$new" '.status = $s' && echo "run-state: $new"
    ;;
  status)
    [ "$(st)" = active ] || { echo none; exit 0; }
    stale=""; is_stale && stale=" STALE(>$((STALE_SECONDS / 3600))h)"
    h=$(tree_hash)
    jq -r --arg h "$h" --arg stale "$stale" --argjson now "$(now)" '
      "active\($stale): \(.workflow)"
      + " · done: \([.steps[] | select(.done) | .name] | join(",") | if . == "" then "-" else . end)"
      + " · pending: \([.steps[] | select(.done | not) | .name] | join(",") | if . == "" then "-" else . end)"
      + " · attempts \(.attempts)/\(.max_attempts)"
      + " · review: \(if .review == null then "none" elif .review.verdict == "FAIL" then "FAIL" elif .review.tree == $h then "PASS(current)" else "PASS(outdated — code changed)" end)"
      + " · updated \((($now - .updated_at) / 60) | floor)m ago"' "$FILE"
    ;;
  hash) tree_hash ;;
  *) echo "usage: run-state.sh start|step|attempt|verdict|override|check|done|abandon|status|hash" >&2; exit 2 ;;
esac
