#!/bin/bash
# tests/run.sh — smoke tests for the hooks. Needs bash, git, jq. Run: bash tests/run.sh
# Everything runs against a throwaway home and throwaway repos; nothing touches ~/.review-harness.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/hooks"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export REVIEW_HARNESS_HOME="$TMP/home"
unset CLAUDE_PLUGIN_ROOT REVIEW_HARNESS_ALLOW_CONFIG_EDITS REVIEW_HARNESS_RUN_STALE_SECONDS
PASS=0; FAIL=0

eq() { # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
has() { # has <name> <needle> <haystack>
  case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in: %s\n' "$1" "$2" "$3" ;; esac
}
lacks() { # lacks <name> <needle> <haystack>
  case "$3" in *"$2"*) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  unexpected: %s\n' "$1" "$2" ;; *) PASS=$((PASS + 1)) ;; esac
}
new_repo() { # new_repo <dir> — a git repo with one commit and one pending edit
  mkdir -p "$1" && git -C "$1" init -q && echo a > "$1/f.txt" && git -C "$1" add f.txt \
    && git -C "$1" -c user.name=t -c user.email=t@t.t commit -qm init && echo b >> "$1/f.txt"
}
# decision <stdout of a PreToolUse hook> → allow | deny | advice
decision() {
  [ -z "$1" ] && { echo allow; return; }
  printf '%s' "$1" | jq -r 'if .hookSpecificOutput.permissionDecision then .hookSpecificOutput.permissionDecision else "advice" end'
}
gate() { # gate <repo> [command] — run commit-gate.sh as Claude Code would
  decision "$(jq -n --arg c "${2:-git commit -m x}" --arg d "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | bash "$H/commit-gate.sh")"
}
rs() { (cd "$R" && bash "$H/run-state.sh" "$@" 2>&1); }

# --- state-dir -------------------------------------------------------------------------
R="$TMP/repo"; new_repo "$R"
has "state-dir lives under REVIEW_HARNESS_HOME" "$REVIEW_HARNESS_HOME/state/repo-" "$(bash "$H/state-dir.sh" "$R")"

# --- review gate -----------------------------------------------------------------------
eq "gate: no run → allow" allow "$(gate "$R")"
rs start small-change reviewer >/dev/null
eq "gate: active, no verdict → deny" deny "$(gate "$R")"
has "start refuses a second active run" "already exists" "$(rs start feature)"
eq "gate: other git commands pass" allow "$(gate "$R" "git status")"
eq "gate: git commit-tree is not a commit" allow "$(gate "$R" "git commit-tree abc")"
eq "gate: git -c k=v commit is caught" deny "$(gate "$R" "git -c user.name=x commit -m x")"
eq "gate: chained commit is caught" deny "$(gate "$R" "git add . && git commit -m x")"
rs verdict PASS >/dev/null; eq "verdict PASS exits 0" 0 "$?"
eq "gate: PASS, tree unchanged → allow" allow "$(gate "$R")"
git -C "$R" add -A
eq "gate: staging does not invalidate the review" allow "$(gate "$R")"
echo c >> "$R/f.txt"
eq "gate: edited after PASS → deny" deny "$(gate "$R")"
has "status reports an outdated PASS" "PASS(outdated" "$(rs status)"
rs override "user said so" >/dev/null
eq "gate: override for this tree → allow" allow "$(gate "$R")"
echo d >> "$R/f.txt"
eq "gate: override does not cover later edits" deny "$(gate "$R")"
has "reviewer FAIL counts as an attempt" "attempts: 1/3" "$(rs verdict FAIL)"
eq "gate: FAIL → deny" deny "$(gate "$R")"
has "test failure shares the counter" "attempts: 2/3" "$(rs attempt)"
has "third failure reaches the limit" "LIMIT REACHED" "$(rs verdict fail)"
eq "gate: stale active run → advice only" advice \
  "$(decision "$(jq -n --arg d "$R" '{tool_input:{command:"git commit"},cwd:$d}' | REVIEW_HARNESS_RUN_STALE_SECONDS=-1 bash "$H/commit-gate.sh")")"
rs abandon >/dev/null
eq "gate: abandoned → allow" allow "$(gate "$R")"
eq "status after abandon" none "$(rs status)"
rs override "after abandon" >/dev/null
(cd "$R" && bash "$H/run-state.sh" check >/dev/null 2>&1); eq "check: override after abandon passes" 0 "$?"

# A standalone verdict (no active run) is recorded but never enforced by the hook.
R="$TMP/idle"; new_repo "$R"
rs verdict FAIL >/dev/null
eq "gate: idle FAIL is not enforced by the hook" allow "$(gate "$R")"
(cd "$R" && bash "$H/run-state.sh" check >/dev/null 2>&1); eq "check: idle FAIL blocks /git-commit" 1 "$?"

# Hashing the work tree must not write into the repo's object store, and must give the same id as
# the earlier method (a temp index with objects written to the repo), so recorded PASSes stay valid.
objcount() { find "$1" -type f | wc -l | tr -d ' '; }
R="$TMP/hashrepo"; new_repo "$R"; echo new > "$R/untracked.txt"
N0=$(objcount "$R/.git/objects"); HNEW=$(rs hash)
eq "hash: no objects written to the repo" "$N0" "$(objcount "$R/.git/objects")"
cp -p "$R/.git/index" "$TMP/old-index"
HOLD=$(GIT_INDEX_FILE="$TMP/old-index" git -C "$R" add -A . && GIT_INDEX_FILE="$TMP/old-index" git -C "$R" write-tree)
eq "hash: same tree id as the earlier method" "$HOLD" "$HNEW"
git -C "$R" worktree add -q "$TMP/hashwt" 2>/dev/null; echo wt > "$TMP/hashwt/wt.txt"
N0=$(objcount "$R/.git/objects"); HWT=$(cd "$TMP/hashwt" && bash "$H/run-state.sh" hash)
case "$HWT" in error|nogit) eq "hash: works in a linked worktree" tree "$HWT" ;; *) PASS=$((PASS + 1)) ;; esac
eq "hash: linked worktree writes no objects" "$N0" "$(objcount "$R/.git/objects")"
# A ':' in the repo path must not break the alternate: an unchanged file older than the index is
# not re-hashed, so write-tree can only find its blob in the repo's store.
R="$TMP/co:lon"; mkdir -p "$R" && git -C "$R" init -q && echo a > "$R/f.txt" && touch -t 202001010000 "$R/f.txt" \
  && git -C "$R" add f.txt
cp -p "$R/.git/index" "$TMP/colon-index"
HOLD=$(GIT_INDEX_FILE="$TMP/colon-index" git -C "$R" add -A . && GIT_INDEX_FILE="$TMP/colon-index" git -C "$R" write-tree)
eq "hash: ':' in repo path keeps the alternate" "$HOLD" "$(rs hash)"

# --- detect-repo -----------------------------------------------------------------------
eq "detect-repo: no registry → silent" "" "$(bash "$H/detect-repo.sh" "$TMP")"

# --- wisdom ----------------------------------------------------------------------------
# The wisdom folder follows REVIEW_HARNESS_HOME like everything else (HOME points at an empty dir).
mkdir -p "$TMP/wh/knowledge" "$TMP/wh/wisdom" "$TMP/emptyhome"; echo "- a wisdom line" > "$TMP/wh/wisdom/summary.md"
has "session-start: wisdom under REVIEW_HARNESS_HOME" "a wisdom line" \
  "$(cd "$TMP" && HOME="$TMP/emptyhome" REVIEW_HARNESS_HOME="$TMP/wh" bash "$H/session-start.sh")"
HOME="$TMP/emptyhome" REVIEW_HARNESS_HOME="$TMP/wh" bash "$H/knowledge-has-content.sh"
eq "knowledge-has-content: wisdom under REVIEW_HARNESS_HOME counts" 0 "$?"
mkdir -p "$REVIEW_HARNESS_HOME/knowledge/acme" "$TMP/my-app/src" "$TMP/my-app-api"
cat > "$REVIEW_HARNESS_HOME/knowledge/acme/repos.md" <<EOF
### my-app
- **local_path**: \`$TMP/my-app\`
- **role**: demo app
- **layout**: \`src/\`

### other
- **local_path**: \`$TMP/other\`
- **role**: not this one
EOF
OUT=$(bash "$H/detect-repo.sh" "$TMP/my-app/src")
has "detect-repo: subdirectory matches" "- name: my-app" "$OUT"
has "detect-repo: prints registry keys" "- role: demo app" "$OUT"
case "$OUT" in *"not this one"*) eq "detect-repo: stops at the next repo" clean leaked ;; *) PASS=$((PASS + 1)) ;; esac
has "detect-repo: sibling with the same prefix is not matched" "not registered" "$(bash "$H/detect-repo.sh" "$TMP/my-app-api")"

# --- org overlay + constraints ---------------------------------------------------------
eq "org-overlay: none installed → empty" "" "$(bash "$H/org-overlay.sh" agents reviewer)"
bash "$H/org-overlay.sh" agents ../x >/dev/null 2>&1; eq "org-overlay: rejects path traversal" 2 "$?"
BASE=$(bash "$H/extract-constraints.sh" reviewer 2>/dev/null)
has "constraints: reviewer gets #review" "## #review" "$BASE"
case "$BASE" in *"## #filesystem"*) eq "constraints: reviewer does not get #filesystem" absent present ;; *) PASS=$((PASS + 1)) ;; esac
has "constraints: developer gets #filesystem" "## #filesystem" "$(bash "$H/extract-constraints.sh" developer 2>/dev/null)"
OUT=$(bash "$H/extract-constraints.sh" developer 2>/dev/null)
lacks "constraints: no literal plugin-root placeholder" '${CLAUDE_PLUGIN_ROOT}' "$OUT"
has "constraints: plugin root substituted" "$ROOT/hooks/pre-tool-use.sh" "$OUT"
eq "constraints: unknown agent → empty" "" "$(bash "$H/extract-constraints.sh" nobody 2>/dev/null)"

# --- profiles --------------------------------------------------------------------------
lacks "profile: none passed → no profile block" "## Profile —" "$BASE"
lacks "profile: moved rules are absent without it" "React performance" "$BASE"
OUT=$(bash "$H/extract-constraints.sh" reviewer web-frontend 2>/dev/null)
has "profile: reviewer gets the block" "## Profile — web-frontend" "$OUT"
has "profile: reviewer gets #review" "React performance — FAIL if any" "$OUT"
lacks "profile: reviewer does not get #implementation" "### TanStack Query" "$OUT"
OUT=$(bash "$H/extract-constraints.sh" developer web-frontend 2>/dev/null)
has "profile: developer gets #implementation" "### TanStack Query" "$OUT"
lacks "profile: developer does not get #review" "React performance" "$OUT"
has "profile: refactor-architect gets #detection" "Same JSX structure" "$(bash "$H/extract-constraints.sh" refactor-architect web-frontend 2>/dev/null)"
eq "profile: test-runner has no profile section" "$(bash "$H/extract-constraints.sh" test-runner 2>/dev/null)" \
  "$(bash "$H/extract-constraints.sh" test-runner web-frontend 2>/dev/null)"
OUT=$(bash "$H/extract-constraints.sh" reviewer nope 2>/dev/null); eq "profile: unknown → exit 2" 2 "$?"
eq "profile: unknown → empty stdout" "" "$OUT"
bash "$H/extract-constraints.sh" reviewer ../constraints >/dev/null 2>&1; eq "profile: rejects path traversal" 2 "$?"
N=$(grep -h 'hooks/extract-constraints.sh"' "$ROOT"/skills/*/SKILL.md | wc -l | tr -d ' ')
[ "$N" -ge 4 ]; eq "profile: skill call sites found (>= 4, got $N)" 0 "$?"
eq "profile: every skill call site passes web-frontend" "" \
  "$(grep -h 'hooks/extract-constraints.sh"' "$ROOT"/skills/*/SKILL.md | grep -v web-frontend)"
mkdir -p "$REVIEW_HARNESS_HOME/org/agents"
printf '## #org\n\n- org rule one\n' > "$REVIEW_HARNESS_HOME/org/constraints.md"
printf 'run ${CLAUDE_PLUGIN_ROOT}/hooks/x.sh\n' > "$REVIEW_HARNESS_HOME/org/agents/reviewer.md"
eq "org-overlay: substitutes the plugin root" "run $ROOT/hooks/x.sh" "$(bash "$H/org-overlay.sh" agents reviewer)"
WITH=$(bash "$H/extract-constraints.sh" reviewer 2>/dev/null)
has "constraints: #org section appended" "- org rule one" "$WITH"
has "constraints: agent overlay appended" "Org overlay — reviewer" "$WITH"

# --- protected config files ------------------------------------------------------------
P="$TMP/proj"; mkdir -p "$P/src"; echo '{}' > "$P/package.json"
edit() { decision "$(jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}' | bash "$H/pre-tool-use.sh")"; }
eq "pre-tool-use: package.json → deny" deny "$(edit "$P/package.json")"
eq "pre-tool-use: ordinary file → allow" allow "$(edit "$P/src/a.ts")"
bash "$H/pre-tool-use.sh" --approve "$P/package.json" >/dev/null
eq "pre-tool-use: approved → allow" allow "$(edit "$P/package.json")"
bash "$H/pre-tool-use.sh" --revoke "$P/package.json" >/dev/null
eq "pre-tool-use: revoked → deny" deny "$(edit "$P/package.json")"

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
