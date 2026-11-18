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
#                               after verdict names who recorded it ([a-z-]+, else "unknown") — shown, never enforced.
#                               The verdict right after a dispute, on the disputed work tree, is a re-judge: marked,
#                               and a FAIL counts no attempt
#   dispute <issue id...>       record the developer's dispute of the last FAIL on its unchanged work tree; one per
#                               review round (a re-judge opens none), exit 2 when it is used; exit 1 after a code
#                               change or at the attempt limit; never counts as an attempt
#   tests pass|fail|none|manual-confirmed
#                               record the test result + work-tree hash (active run only); manual-confirmed
#                               (the user's yes to the manual checks) only replaces none; pass and
#                               manual-confirmed hold only for the work tree they were recorded on
#   override <reason>           record an explicit user override for the current work tree
#   check [--active-only]       commit gate. exit 0 ok · 1 blocked · 3 nothing to enforce · 4 stale run
#   done | abandon              close the run (and delete its baseline.txt); an active run also appends one
#                               summary line to <state root>/runs.jsonl (read by run-stats.sh), never rewritten
#   status                      one-line summary ("none" when there is nothing to resume)
#   hash                        print the current work-tree hash
#   agent-start <id> <type>     (agent-usage.sh) open an active-time span for a subagent in agents.json; active,
#                               non-stale run only, else no-op
#   agent-stop <id> <type> <transcript>
#                               (agent-usage.sh) close the span and replace the agent's tokens / tool calls / model
#                               from its transcript; an agent this run never started is ignored
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_ATTEMPTS=3
CATEGORIES="correctness performance design scope goal security contract ops state-mgmt"   # = agents/reviewer.md
ORG_CATEGORIES=$(grep -xE '[a-z-]+' "${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/org/categories.txt" 2>/dev/null | tr '\n' ' ')
STALE_SECONDS="${REVIEW_HARNESS_RUN_STALE_SECONDS:-86400}"

command -v jq >/dev/null 2>&1 || { echo "run-state: jq is required" >&2; exit 3; }
STATE_DIR=$(bash "$HERE/state-dir.sh" "$PWD") || exit 3
FILE="$STATE_DIR/run-state.json"
AGENTS="$STATE_DIR/agents.json"   # per-agent usage of the active run; never in $FILE, see agent-start

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

agents_json() { local a; a=$(jq -c 'objects' "$AGENTS" 2>/dev/null); echo "${a:-"{}"}"; }

# agents_update [jq opts...] <filter> — apply the filter to agents.json (temp + mv) under a mkdir lock; gives up
# silently after ~3s (well inside the hook's 10s timeout; a busy CI runner needed more than 1s for 6 parallel starts).
agents_update() {
  local filter="${*: -1}" i=0
  set -- "${@:1:$#-1}"
  until mkdir "$AGENTS.lock" 2>/dev/null; do
    # A lock older than a minute was left by a killed call (a live one holds it well under a second): break it.
    # shortcut: two waiters breaking the same stale lock at once can both write; one entry may be lost (telemetry only).
    if [ -n "$(find "$AGENTS.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$AGENTS.lock" 2>/dev/null; then continue; fi
    i=$((i + 1)); [ "$i" -ge 60 ] && return 0; sleep 0.05
  done
  agents_json | jq --argjson now "$(now)" "$@" "$filter" > "$AGENTS.$$.tmp" && mv -f "$AGENTS.$$.tmp" "$AGENTS"
  rm -f "$AGENTS.$$.tmp"; rmdir "$AGENTS.lock"
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
     verdicts: [(.verdicts // [])[] | if type == "string" then {v: .} else . end], disputes: (.disputes // 0),
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
    rm -rf "$AGENTS" "$AGENTS.lock"
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
    # a re-judge only when the disputed code is unchanged; any verdict closes the dispute
    rejudge=$(jq -r --arg h "$h" '.dispute.pending == true and .dispute.tree == $h' "$FILE" 2>/dev/null)
    update --arg v "$v" --arg h "$h" --argjson cats "$cats" --argjson rj "${rejudge:-false}" --arg by "$by" \
      '.review = {verdict: $v, tree: $h, at: $now, by: $by}
      | .verdicts = (.verdicts // []) + [{v: $v} + (if $cats == [] then {} else {cats: $cats} end) + (if $rj then {rejudge: true} else {} end) + {by: $by}]
      | if .dispute.pending == true then .dispute.pending = false else . end
      | if $v == "FAIL" and ($rj | not) then .attempts += 1 else . end
      | if $v == "PASS" and any(.steps[]; .name == "reviewer") then .steps |= map(if .name == "reviewer" then .done = true else . end) else . end' || exit 1
    echo "review: $v recorded for work tree $h$([ "$rejudge" = true ] && echo " (re-judge after a dispute — not an attempt)")"
    # PASS exits 0; FAIL exits with report_attempts (2 at the limit)
    [ "$v" = PASS ] || report_attempts
    ;;
  dispute)
    [ -z "${2:-}" ] && { echo "usage: run-state.sh dispute <issue id...>" >&2; exit 2; }
    { [ "$(st)" = active ] && [ "$(get '.review.verdict // ""')" = FAIL ]; } \
      || { echo "run-state: nothing to dispute — no reviewer FAIL in an active run" >&2; exit 1; }
    [ "$(get '.attempts')" -ge "$MAX_ATTEMPTS" ] && { echo "run-state: limit reached — stop and report the remaining failures to the user" >&2; exit 1; }
    h=$(tree_hash)
    [ "$h" = "$(get '.review.tree // ""')" ] \
      || { echo "run-state: code changed since the FAIL — not a dispute. Run test-runner and reviewer on the change" >&2; exit 1; }
    # round = reviews that were not re-judges, so a re-judge never opens a second dispute
    round=$(get '[.verdicts[]? | select(type != "object" or (.rejudge | not))] | length')
    if [ "$(get '.dispute.round // -1')" = "$round" ]; then
      echo "run-state: this review round's dispute is used — patch the issues instead" >&2; exit 2
    fi
    update --argjson r "$round" --arg i "${*:2}" --arg h "$h" '.dispute = {round: $r, issues: $i, tree: $h, pending: true} | .disputes = (.disputes // 0) + 1' || exit 1
    echo "dispute: issue ${*:2} recorded for review round $round — re-run reviewer on it only; not an attempt"
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
    rm -f "$STATE_DIR/baseline.txt"   # so /tdd or /refactor-scan never read this run's baseline
    [ -f "$FILE" ] || { echo "run-state: none"; exit 0; }
    [ "$1" = done ] && new=done || new=abandoned
    [ "$(st)" = active ] && log_run "$new"
    rm -rf "$AGENTS" "$AGENTS.lock"
    update --arg s "$new" '.status = $s' && echo "run-state: $new"
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
  # Agent usage lives in agents.json, never in run-state.json: the hook fires asynchronously, so writing the gate's
  # file could drop a verdict or test result recorded at the same moment, and would reset the stale clock
  # (updated_at). Parallel agent-start/stop calls serialise on a mkdir lock; a call that cannot take it within ~3s
  # records nothing, and a lock left by a killed call is broken once it is over a minute old — telemetry only, never
  # the gate. Tokens are replaced on every stop, so a later stop of the same agent (resume) corrects a
  # transcript that was still being written.
  agent-start)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: run-state.sh agent-start <id> <type>" >&2; exit 2; }
    [ "$(st)" = active ] && ! is_stale || exit 0
    agents_update --arg id "$2" --arg t "${3##*:}" \
      '.[$id] = (.[$id] // {type: $t, model: null, s: 0, in: 0, out: 0, cr: 0, cw: 0, tools: 0}) + {open: $now}'
    ;;
  agent-stop)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: run-state.sh agent-stop <id> <type> <transcript>" >&2; exit 2; }
    [ "$(st)" = active ] && ! is_stale && jq -e --arg id "$2" '.[$id] != null' "$AGENTS" >/dev/null 2>&1 || exit 0
    # One usage per message.id (it repeats on a line per content block; the last line wins); a torn line is skipped.
    u=$([ -r "${4:-}" ] && jq -Rnc '[inputs | fromjson? | objects | select(.type == "assistant") | .message | objects] as $m
      | (reduce ($m[] | select(.id != null)) as $x ({}; .[$x.id] = ($x.usage // {})) | [.[]]) as $u
      | {in: ($u | map(.input_tokens // 0) | add // 0), out: ($u | map(.output_tokens // 0) | add // 0),
         cr: ($u | map(.cache_read_input_tokens // 0) | add // 0), cw: ($u | map(.cache_creation_input_tokens // 0) | add // 0),
         tools: ([$m[] | .content | arrays | .[] | objects | select(.type == "tool_use") | .id] | unique | length)}
      + ([$m[] | .model | strings | select(. != "<synthetic>")] | if . == [] then {} else {model: last} end)' "$4" 2>/dev/null)
    agents_update --arg id "$2" --argjson u "${u:-null}" \
      'if .[$id] then .[$id] |= ((if .open then .s += ($now - .open) | .open = null else . end) + ($u // {})) else . end'
    ;;
  *) echo "usage: run-state.sh start|step|attempt|verdict|dispute|tests|override|check|done|abandon|status|hash|agent-start|agent-stop" >&2; exit 2 ;;
esac
