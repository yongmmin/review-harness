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

# --- detect-test-cmd -------------------------------------------------------------------
REG="$TMP/reg-app"; mkdir -p "$REG/app" && git -C "$REG" init -q && echo 'x = 1' > "$REG/app/x.py"
echo '{"scripts":{"test":"vitest"}}' > "$REG/package.json"
cat >> "$REVIEW_HARNESS_HOME/knowledge/acme/repos.md" <<EOF

### reg-app
- **local_path**: \`$TMP/reg-app\`
- **test_cmd**: \`make test\`
- **check_cmd**: \`echo CHECK-MARKER; exit 1\`
EOF
dt() { bash "$H/detect-test-cmd.sh" "$1"; }
eq "detect-test-cmd: registry test_cmd wins over package.json" "make test" "$(dt "$REG")"
mkdir -p "$TMP/t-go" "$TMP/t-rs" "$TMP/t-npm" "$TMP/t-pnpm" "$TMP/t-none"
echo 'module x' > "$TMP/t-go/go.mod"; eq "detect-test-cmd: go.mod" "go test ./..." "$(dt "$TMP/t-go")"
echo '[package]' > "$TMP/t-rs/Cargo.toml"; eq "detect-test-cmd: Cargo.toml" "cargo test" "$(dt "$TMP/t-rs")"
echo '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}' > "$TMP/t-npm/package.json"
eq "detect-test-cmd: npm placeholder → nothing" "" "$(dt "$TMP/t-npm")"
echo '{"scripts":{"test":"vitest run"}}' > "$TMP/t-pnpm/package.json"; touch "$TMP/t-pnpm/pnpm-lock.yaml"
eq "detect-test-cmd: scripts.test + pnpm lock" "pnpm test" "$(dt "$TMP/t-pnpm")"
eq "detect-test-cmd: nothing found → empty" "" "$(dt "$TMP/t-none")"

# --- post-tool-use: registry check_cmd -------------------------------------------------
pt() { jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}' | bash "$H/post-tool-use.sh" 2>/dev/null; }
has "post-tool-use: failing check_cmd → additionalContext" "CHECK-MARKER" \
  "$(pt "$REG/app/x.py" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
echo 'x = 1' > "$TMP/my-app/src/a.py"
eq "post-tool-use: .py without check_cmd → no output" "" "$(pt "$TMP/my-app/src/a.py")"

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
eq "profile: every skill call site uses detect-profile.sh" "" \
  "$(grep -h 'hooks/extract-constraints.sh"' "$ROOT"/skills/*/SKILL.md | grep -v 'hooks/detect-profile.sh')"
OUT=$(bash "$H/extract-constraints.sh" reviewer web-frontend,nope 2>/dev/null); eq "profile: list with an unknown name → exit 2" 2 "$?"
eq "profile: list with an unknown name → empty stdout" "" "$OUT"
bash "$H/extract-constraints.sh" reviewer web-frontend,../constraints >/dev/null 2>&1; eq "profile: list rejects path traversal" 2 "$?"
eq "profile: empty argument = no profile" "$BASE" "$(bash "$H/extract-constraints.sh" reviewer "" 2>/dev/null)"

# --- detect-profile --------------------------------------------------------------------
dp() { bash "$H/detect-profile.sh" "$@"; }
eq "detect-profile: .tsx → web-frontend" web-frontend "$(cd "$TMP" && dp src/App.tsx)"
eq "detect-profile: .py only → none" "" "$(cd "$TMP" && dp app/main.py)"
eq "detect-profile: controller only → none (no web-api profile yet)" "" "$(cd "$TMP" && dp src/user.controller.ts)"
# Multi-profile path: a plugin copy with stub web-api / web-common profiles.
PC="$TMP/plugin-copy"; mkdir -p "$PC" && cp -R "$ROOT/hooks" "$ROOT/profiles" "$ROOT/constraints.md" "$PC/"
printf '## #review\n\n- api stub rule\n' > "$PC/profiles/web-api.md"
printf '## #review\n\n- common stub rule\n' > "$PC/profiles/web-common.md"
eq "detect-profile: .tsx + routes/ → all three" "web-frontend,web-api,web-common" \
  "$(cd "$TMP" && bash "$PC/hooks/detect-profile.sh" src/App.tsx routes/x.ts)"
OUT=$(bash "$PC/hooks/extract-constraints.sh" reviewer web-frontend,web-api 2>/dev/null)
has "profile: list → one block per profile, in order" \
  "## Profile — web-api (part of this agent's instructions)"$'\n\n'"## #review"$'\n\n'"- api stub rule" "$OUT"
case "$OUT" in *"## Profile — web-frontend"*"## Profile — web-api"*) PASS=$((PASS + 1)) ;; *) eq "profile: list keeps order" ordered unordered ;; esac
F="$TMP/fe"; mkdir -p "$F/src" && git -C "$F" init -q && echo 'x' > "$F/src/App.tsx"
eq "detect-profile: no args → untracked .tsx" web-frontend "$(cd "$F" && dp)"
# Clean tree (history via commit-tree, never `git commit`): fall back to package.json deps.
C="$TMP/clean-fe"; mkdir -p "$C" && git -C "$C" init -q && echo '{"dependencies":{"react":"18"}}' > "$C/package.json" \
  && git -C "$C" add -A && git -C "$C" update-ref HEAD \
  "$(git -C "$C" -c user.name=t -c user.email=t@t.t commit-tree "$(git -C "$C" write-tree)" -m init)"
eq "detect-profile: clean tree + react dep → web-frontend" web-frontend "$(cd "$C" && dp)"
eq "detect-profile: .ts only in a react package → web-frontend" web-frontend "$(cd "$C" && dp src/hooks/useOrder.ts)"
echo '{"dependencies":{"react":"19"}}' > "$C/package.json"
eq "detect-profile: changed package.json counts by its own deps" web-frontend "$(cd "$C" && dp)"
# Monorepo: each unmatched path counts by its nearest manifest (stub profiles in the plugin copy).
M="$TMP/mono"; mkdir -p "$M/apps/web" "$M/apps/api" "$M/packages/util" "$M/services/py" && git -C "$M" init -q
echo '{"dependencies":{"next":"14","react":"18"}}' > "$M/apps/web/package.json"
echo '{"dependencies":{"@nestjs/core":"10"}}' > "$M/apps/api/package.json"
echo '{"dependencies":{"lodash":"4"}}' > "$M/packages/util/package.json"
printf '[project]\ndependencies = ["fastapi>=0.110"]\n' > "$M/services/py/pyproject.toml"
eq "detect-profile: monorepo react .ts + nest .ts → all three" "web-frontend,web-api,web-common" \
  "$(cd "$M" && bash "$PC/hooks/detect-profile.sh" apps/web/src/a.ts apps/api/src/b.ts)"
eq "detect-profile: .ts in a package with neither → none" "" \
  "$(cd "$M" && bash "$PC/hooks/detect-profile.sh" packages/util/src/c.ts)"
eq "detect-profile: .py under a fastapi pyproject → web-api" web-api \
  "$(cd "$M" && bash "$PC/hooks/detect-profile.sh" services/py/app/main.py)"
# An API-name match must not cut off the manifest: a React package keeps its frontend rules.
eq "detect-profile: src/api/ .ts in a react package → web-frontend" web-frontend "$(cd "$C" && dp src/api/client.ts)"
eq "detect-profile: Next app/api route → web-frontend" web-frontend "$(cd "$M" && dp apps/web/app/api/orders/route.ts)"
eq "detect-profile: src/api/ .ts in a react package, stubs → all three" "web-frontend,web-api,web-common" \
  "$(cd "$C" && bash "$PC/hooks/detect-profile.sh" src/api/client.ts)"
echo x > "$F/src/한글.tsx"; rm -f "$F/src/App.tsx"
eq "detect-profile: non-ASCII .tsx name matches" web-frontend "$(cd "$F" && dp)"

# --- registry: local_path, trailing whitespace, flat registry ---------------------------
SP='  '
mkdir -p "$TMP/nogit/sub" "$M/apps/api/src"
cat >> "$REVIEW_HARNESS_HOME/knowledge/acme/repos.md" <<EOF

### mono-api
- **local_path**: \`$M/apps/api\`
- **check_cmd**: \`pwd; exit 1\`

### nogit
- **local_path**: \`$TMP/nogit\`
- **test_cmd**: \`make test\`$SP
- **check_cmd**: \`echo 'x\cy END-MARK'; pwd; exit 1\`$SP
EOF
ctx() { pt "$1" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }
has "post-tool-use: check_cmd runs in a monorepo package's local_path" "$M/apps/api"$'\n' "$(ctx "$M/apps/api/src/b.ts")"
OUT=$(ctx "$TMP/nogit/sub/x.py")
has "post-tool-use: check_cmd runs in a non-git local_path" "$TMP/nogit"$'\n' "$OUT"
has "post-tool-use: trailing whitespace + \\c in output kept verbatim" 'x\cy END-MARK' "$OUT"
eq "detect-test-cmd: trailing whitespace after the backticks" "make test" "$(dt "$TMP/nogit")"
mkdir -p "$TMP/flathome/knowledge" "$TMP/flat"
printf '### flat\n- **local_path**: `%s`\n- **check_cmd**: `echo FLAT-MARK; exit 1`\n' "$TMP/flat" > "$TMP/flathome/knowledge/repos.md"
has "post-tool-use: check_cmd from the flat knowledge/repos.md" "FLAT-MARK" \
  "$(REVIEW_HARNESS_HOME="$TMP/flathome" ctx "$TMP/flat/a.py")"

# --- bun -------------------------------------------------------------------------------
mkdir -p "$TMP/t-bun" "$TMP/t-bunrun"; touch "$TMP/t-bun/bun.lockb" "$TMP/t-bunrun/bun.lock"
echo '{}' > "$TMP/t-bun/package.json"; echo '{"scripts":{"test":"vitest"}}' > "$TMP/t-bunrun/package.json"
eq "detect-test-cmd: bun lockfile, no scripts.test → bun test" "bun test" "$(dt "$TMP/t-bun")"
eq "detect-test-cmd: scripts.test + bun.lock → bun run test" "bun run test" "$(dt "$TMP/t-bunrun")"

# Done criterion: a Python repo loads no React rules and finds pytest.
PY="$TMP/py"; mkdir -p "$PY/app" && git -C "$PY" init -q && printf '[tool.pytest.ini_options]\n' > "$PY/pyproject.toml" \
  && echo 'x = 1' > "$PY/app/main.py" && git -C "$PY" add -A
PROF=$(cd "$PY" && dp)
eq "python: detect-profile → none" "" "$PROF"
lacks "python: reviewer constraints carry no React rules" "React" "$(bash "$H/extract-constraints.sh" reviewer "$PROF" 2>/dev/null)"
eq "python: detect-test-cmd → pytest" "python -m pytest" "$(bash "$H/detect-test-cmd.sh" "$PY")"
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
eq "pre-tool-use: .env → deny" deny "$(edit "$P/.env")"
eq "pre-tool-use: .env.local → deny" deny "$(edit "$P/.env.local")"
eq "pre-tool-use: .env.example → allow" allow "$(edit "$P/.env.example")"
eq "pre-tool-use: pnpm-lock.yaml → deny" deny "$(edit "$P/pnpm-lock.yaml")"
eq "pre-tool-use: go.sum → deny" deny "$(edit "$P/go.sum")"
eq "pre-tool-use: bun.lock → deny" deny "$(edit "$P/bun.lock")"

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
