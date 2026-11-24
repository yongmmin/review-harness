#!/bin/bash
# run-state.sh — file-backed run state for the review-harness review gate.
# State file: <state dir>/run-state.json (see state-dir.sh). Run it from the consumer repo.
# The script computes every value itself (attempt counter, timestamps, work-tree hash);
# callers never pass numbers or hashes.
#
#   start <workflow> [step...]  create a run (clears the previous baseline.txt and attempts.md); refuses while
#                               another run is active
#   step <name>                 mark a step done
#   attempt                     count a failed attempt (test failure); exit 2 at the limit
#   verdict PASS|FAIL [category...] [--by <word>]
#                               record the reviewer verdict + work-tree hash; FAIL counts as an attempt and may
#                               carry the [category] tags of its issues (kept for the run log; unknown words warn;
#                               <home>/org/categories.txt adds words, one [a-z-]+ per line). `--by <word>` anywhere
#                               after verdict names who recorded it ([a-z-]+, else "unknown") — shown, never enforced
#   tests pass|fail|none|manual-confirmed
#                               record the test result + work-tree hash (active run only); manual-confirmed
#                               (the user's yes to the manual checks) only replaces none; pass and
#                               manual-confirmed hold only for the work tree they were recorded on
#   override <reason>           record an explicit user override for the current work tree
#   check [--active-only]       commit gate. exit 0 ok · 1 blocked · 3 nothing to enforce · 4 stale run
#   done | abandon              close the run (and delete its baseline.txt); an active run also appends one
#                               summary line to <state root>/runs.jsonl (read by run-stats.sh), never rewritten
#   resume                      mark an active run (stale or not) as touched now, so a run the user chose to resume
#                               is no longer stale; exit 1 when no run is active
#   status                      one-line summary ("none" when there is nothing to resume)
#   hash                        print the current work-tree hash
#   agent-start <id> <type>     (agent-usage.sh) open an active-time span for a subagent in agents.jsonl; active,
#                               non-stale run only, else no-op
#   agent-stop <id> <type> <transcript>
#                               (agent-usage.sh) close the span and replace the agent's tokens / tool calls / model
#                               from its transcript; an agent this run never started is ignored
#   agents                      print the folded per-agent object of agents.jsonl ({} when empty)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_ATTEMPTS=3
CATEGORIES="correctness performance design scope goal security contract ops state-mgmt convention"   # = agents/reviewer.md
ORG_CATEGORIES=$(grep -xE '[a-z-]+' "${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/org/categories.txt" 2>/dev/null | tr '\n' ' ')
STALE_SECONDS="${REVIEW_HARNESS_RUN_STALE_SECONDS:-86400}"

command -v jq >/dev/null 2>&1 || { echo "run-state: jq is required" >&2; exit 3; }
STATE_DIR=$(bash "$HERE/state-dir.sh" "$PWD") || exit 3
FILE="$STATE_DIR/run-state.json"
AGENTS="$STATE_DIR/agents.jsonl"   # per-agent usage of the active run; never in $FILE, see agent-start

now() { date +%s; }
st() { { [ -f "$FILE" ] && jq -er '.status' "$FILE" 2>/dev/null; } || echo none; }
get() { jq -r "$1" "$FILE" 2>/dev/null; }
need_file() { [ -f "$FILE" ] || { echo "run-state: no run state. Call: run-state.sh start <workflow> [step...]" >&2; exit 1; }; }

# Hash of the whole work tree (tracked + untracked, .gitignore respected), taken through a
# throwaway copy of the index. It changes only when file content changes: `git add` and
# `git commit` leave it untouched, so a review stays valid across staging and commit units.
tree_hash() {
  local root idx objs tmp tree
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "nogit"; return; }
  tmp=$(mktemp -d) || { echo "error"; return; }
  idx=$(git -C "$root" rev-parse --git-path index 2>/dev/null)
  case "$idx" in /*) ;; *) idx="$root/$idx" ;; esac
  objs=$(git -C "$root" rev-parse --git-path objects 2>/dev/null)
  case "$objs" in /*) ;; *) objs="$root/$objs" ;; esac
  # -p keeps the index mtime: git's racy-timestamp check compares file mtimes against it, and a
  # fresh mtime would make a same-second, same-size edit look unchanged.
  [ -f "$idx" ] && cp -p "$idx" "$tmp/index"
  # New blobs/trees go to the temp object store; the repo's store is an alternate, so no object is
  # added to the consumer's .git/objects (git may only refresh mtimes of objects already there).
  # The alternates file is newline-separated, unlike the ':'-separated env var, so any path works.
  mkdir -p "$tmp/objects/info" && printf '%s\n' "$objs" > "$tmp/objects/info/alternates"
  tree=$(export GIT_INDEX_FILE="$tmp/index" GIT_OBJECT_DIRECTORY="$tmp/objects"
         git -C "$root" add -A . >/dev/null 2>&1 && git -C "$root" write-tree 2>/dev/null)
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
  # base: the commit the run started from, so the run log can count the files it changed
  jq -n --arg wf "$1" --arg s "$2" --argjson steps "$3" --argjson now "$(now)" --argjson max "$MAX_ATTEMPTS" \
    --arg base "$(git rev-parse -q --verify HEAD 2>/dev/null)" \
    '{version:1, workflow:$wf, status:$s, started_at:$now, updated_at:$now, steps:$steps,
      attempts:0, max_attempts:$max, review:null, verdicts:[], tests:null, override:null}
      + ($base | if . == "" then {} else {base: .} end)' > "$FILE.$$.tmp" && mv -f "$FILE.$$.tmp" "$FILE"
}

# agents_json — fold agents.jsonl into {id: {type, model, open, s, in, out, cr, cw, tools}}. A torn line, or a stop
# with no earlier start for its id, is skipped; a start reopens an id (resume); a stop closes the span and replaces
# the token fields.
agents_json() {
  local a
  a=$(jq -Rnc 'reduce (inputs | fromjson? | objects | select((.id | type) == "string" and (.ts | type) == "number")) as $e ({};
      if $e.e == "start" then .[$e.id] = (.[$e.id] // {type: $e.t, model: null, s: 0, in: 0, out: 0, cr: 0, cw: 0, tools: 0}) + {open: $e.ts}
      elif $e.e == "stop" and .[$e.id] then .[$e.id] |= ((if .open then .s += ($e.ts - .open) | .open = null else . end) + ($e.u | objects // {}))
      else . end)' "$AGENTS" 2>/dev/null)
  echo "${a:-"{}"}"
}

# log_run <done|abandoned> — append this run's summary to <state root>/runs.jsonl. One short line in a single
# O_APPEND write, so concurrent runs never interleave; a failed write warns and never changes the exit code.
log_run() {
  local root base files=""
  root=$(git rev-parse --show-toplevel 2>/dev/null); base=$(get '.base // ""')
  if [ -n "$root" ] && [ -n "$base" ] && git -C "$root" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
    files=$({ git -C "$root" diff --name-only "$base" --; git -C "$root" ls-files -o --exclude-standard; } 2>/dev/null | sort -u | grep -c .)
  fi
  jq -c --arg end "$1" --arg repo "$(basename "$STATE_DIR")" --arg files "$files" --argjson now "$(now)" \
    --argjson ag "$(agents_json)" '
    {repo: $repo, workflow, started_at, ended_at: $now, duration_s: ($now - .started_at), attempts,
     verdicts: [(.verdicts // [])[] | if type == "string" then {v: .} else . end],
     tests: .tests.status, override: .override.reason,
     end: (if .attempts >= .max_attempts then "limit" else $end end)}
    + (if $files == "" then {} else {files_changed: ($files | tonumber)} end)
    + ([$ag[]] | if . == [] then {} else
        {agents: (group_by(.type) | map({type: .[0].type, n: length, s: (map(.s) | add), in: (map(.in) | add),
                  out: (map(.out) | add), cr: (map(.cr) | add), cw: (map(.cw) | add), tools: (map(.tools) | add)})),
         tokens: {in: (map(.in) | add), out: (map(.out) | add), cr: (map(.cr) | add), cw: (map(.cw) | add)}} end)' "$FILE" 2>/dev/null \
    | { IFS= read -r line && printf '%s\n' "$line" >> "$(dirname "$STATE_DIR")/runs.jsonl"; } 2>/dev/null \
    || echo "run-state: could not append the run to $(dirname "$STATE_DIR")/runs.jsonl" >&2
  return 0
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
    rm -f "$STATE_DIR/baseline.txt" "$STATE_DIR/attempts.md"   # the previous run's failing tests and attempts log
    rm -rf "$AGENTS" "$STATE_DIR/agents.json" "$STATE_DIR/agents.json.lock"   # .json(.lock): older versions
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
    case "$v" in PASS|FAIL) ;; *) echo "usage: run-state.sh verdict PASS|FAIL [category...] [--by <word>]" >&2; exit 2 ;; esac
    cats=""; by=unknown; want_by=0
    for w in "${@:3}"; do
      if [ "$want_by" = 1 ]; then   # the word after --by names who recorded the verdict
        want_by=0
        if printf '%s' "$w" | grep -qxE '[a-z-]+'; then by=$w; else echo "run-state: ignored --by $w — expected one [a-z-]+ word" >&2; fi
        continue
      fi
      [ "$w" = --by ] && { want_by=1; continue; }
      w=$(printf '%s' "$w" | tr -d '[],' | tr '[:upper:]' '[:lower:]')
      [ -n "$w" ] || continue
      if [ "$v" = PASS ]; then echo "run-state: categories are for FAIL only — ignored: $w" >&2; continue; fi
      case " $CATEGORIES $ORG_CATEGORIES " in *" $w "*) case " $cats " in *" $w "*) ;; *) cats="$cats $w" ;; esac ;;
        *) echo "run-state: unknown category ignored: $w (known: $CATEGORIES${ORG_CATEGORIES:+ $ORG_CATEGORIES})" >&2 ;; esac
    done
    [ "$want_by" = 1 ] && echo "run-state: ignored --by with no value" >&2
    cats=$(printf '%s\n' $cats | jq -R . | jq -cs 'map(select(length > 0))')
    # No active run (standalone /code-review): keep the verdict in an idle record so a later
    # /git-commit can check it, without making the commit hook enforce anything.
    [ "$(st)" = active ] || new_file review idle '[]'
    h=$(tree_hash)
    update --arg v "$v" --arg h "$h" --argjson cats "$cats" --arg by "$by" \
      '.review = {verdict: $v, tree: $h, at: $now, by: $by}
      | .verdicts = (.verdicts // []) + [{v: $v} + (if $cats == [] then {} else {cats: $cats} end) + {by: $by}]
      | if $v == "FAIL" then .attempts += 1 else . end
      | if $v == "PASS" and any(.steps[]; .name == "reviewer") then .steps |= map(if .name == "reviewer" then .done = true else . end) else . end' || exit 1
    echo "review: $v recorded for work tree $h"
    # PASS exits 0; FAIL exits with report_attempts (2 at the limit)
    [ "$v" = PASS ] || report_attempts
    ;;
  tests)
    case "${2:-}" in pass|fail|none|manual-confirmed) ;; *) echo "usage: run-state.sh tests pass|fail|none|manual-confirmed" >&2; exit 2 ;; esac
    [ "$(st)" = active ] || { echo "run-state: no active run — tests result not recorded"; exit 0; }
    if [ "$2" = manual-confirmed ]; then
      case "$(get '.tests.status // ""')" in none|manual-confirmed) ;;
        *) echo "run-state: manual-confirmed applies only after 'tests none' (no test command ran)" >&2; exit 1 ;; esac
    fi
    h=$(tree_hash)
    update --arg t "$2" --arg h "$h" '.tests = {status: $t, tree: $h, at: $now}' && echo "tests: $2 recorded for work tree $h"
    ;;
  override)
    [ -z "${2:-}" ] && { echo "usage: run-state.sh override <reason>" >&2; exit 2; }
    # No record, or a closed-out abandoned one: start an idle record so `check` sees the override.
    case "$(st)" in none|abandoned) new_file review idle '[]' ;; esac
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
    # No tests record (older flows, review fast-path) leaves the gate to the review alone.
    case "$(get '.tests.status // ""')" in
      fail) echo "blocked: the last test run failed. Fix it and re-run test-runner."; exit 1 ;;
      pass) [ "$(get .tests.tree)" = "$h" ] || {
        echo "blocked: code changed after the last test run (tested work tree $(get .tests.tree), current $h). Re-run test-runner on the current changes."; exit 1; } ;;
      none) echo "blocked: no test command ran. Show the user the manual checks; record 'run-state.sh tests manual-confirmed' only after the user explicitly confirms them."; exit 1 ;;
      manual-confirmed) [ "$(get .tests.tree)" = "$h" ] || {
        echo "blocked: code changed after the user's manual confirmation. Ask the user to confirm the manual checks again."; exit 1; } ;;
    esac
    echo "ok: reviewer PASS matches the current work tree ($h)"
    ;;
  done|abandon)
    rm -f "$STATE_DIR/baseline.txt"   # so a later run never reads this run's baseline
    [ -f "$FILE" ] || { echo "run-state: none"; exit 0; }
    [ "$1" = done ] && new=done || new=abandoned
    [ "$(st)" = active ] && log_run "$new"
    rm -rf "$AGENTS" "$STATE_DIR/agents.json" "$STATE_DIR/agents.json.lock"
    update --arg s "$new" '.status = $s' && echo "run-state: $new"
    ;;
  resume)
    [ "$(st)" = active ] || { echo "run-state: no active run to resume" >&2; exit 1; }
    update '.' && echo "run-state: resumed '$(get .workflow)' ($("$0" status))"
    ;;
  status)
    [ "$(st)" = active ] || { echo none; exit 0; }
    stale=""; is_stale && stale=" STALE(>$((STALE_SECONDS / 3600))h)"
    h=$(tree_hash)
    jq -r --arg h "$h" --arg stale "$stale" --argjson now "$(now)" --argjson ag "$(agents_json)" '
      "active\($stale): \(.workflow)"
      + " · done: \([.steps[] | select(.done) | .name] | join(",") | if . == "" then "-" else . end)"
      + " · pending: \([.steps[] | select(.done | not) | .name] | join(",") | if . == "" then "-" else . end)"
      + " · attempts \(.attempts)/\(.max_attempts)"
      + " · tests: \(.tests.status // "-")"
      + " · review: \(if .review == null then "none" elif .review.verdict == "FAIL" then "FAIL" elif .review.tree == $h then "PASS(current)" else "PASS(outdated — code changed)" end)\(if .review.by then " by \(.review.by)" else "" end)"
      + " · updated \((($now - .updated_at) / 60) | floor)m ago"
      + ($ag | length | if . > 0 then " · agents \(.)" else "" end)' "$FILE"
    ;;
  hash) tree_hash ;;
  agents) agents_json ;;
  # Agent usage lives in agents.jsonl, never in run-state.json: the hook fires asynchronously, so writing the gate's
  # file could drop a verdict or test result recorded at the same moment, and would reset the stale clock
  # (updated_at). Each agent-start / agent-stop appends one short JSON line in a single O_APPEND write, so parallel
  # calls never lose or interleave an entry and need no lock; agents_json folds the lines. Telemetry only, never the
  # gate. Tokens are replaced on every stop, so a later stop of the same agent (resume) corrects a transcript that
  # was still being written.
  agent-start)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: run-state.sh agent-start <id> <type>" >&2; exit 2; }
    [ "$(st)" = active ] && ! is_stale || exit 0
    printf '%s\n' "$(jq -nc --arg id "$2" --arg t "${3##*:}" --argjson ts "$(now)" '{e: "start", id: $id, t: $t, ts: $ts}')" >> "$AGENTS"
    ;;
  agent-stop)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: run-state.sh agent-stop <id> <type> <transcript>" >&2; exit 2; }
    [ "$(st)" = active ] && ! is_stale && agents_json | jq -e --arg id "$2" 'has($id)' >/dev/null 2>&1 || exit 0
    # One usage per message.id (it repeats on a line per content block; the last line wins); a torn line is skipped.
    u=$([ -r "${4:-}" ] && jq -Rnc '[inputs | fromjson? | objects | select(.type == "assistant") | .message | objects] as $m
      | (reduce ($m[] | select(.id != null)) as $x ({}; .[$x.id] = ($x.usage // {})) | [.[]]) as $u
      | {in: ($u | map(.input_tokens // 0) | add // 0), out: ($u | map(.output_tokens // 0) | add // 0),
         cr: ($u | map(.cache_read_input_tokens // 0) | add // 0), cw: ($u | map(.cache_creation_input_tokens // 0) | add // 0),
         tools: ([$m[] | .content | arrays | .[] | objects | select(.type == "tool_use") | .id] | unique | length)}
      + ([$m[] | .model | strings | select(. != "<synthetic>")] | if . == [] then {} else {model: last} end)' "$4" 2>/dev/null)
    printf '%s\n' "$(jq -nc --arg id "$2" --argjson ts "$(now)" --argjson u "${u:-null}" '{e: "stop", id: $id, ts: $ts, u: $u}')" >> "$AGENTS"
    ;;
  *) echo "usage: run-state.sh start|step|attempt|verdict|tests|override|check|done|abandon|resume|status|hash|agents|agent-start|agent-stop" >&2; exit 2 ;;
esac
