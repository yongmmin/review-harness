#!/bin/bash
# tests/run.sh — smoke tests for the hooks. Needs bash, git, jq. Run: bash tests/run.sh
# Everything runs against a throwaway home and throwaway repos; nothing touches ~/.review-harness.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/hooks"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export REVIEW_HARNESS_HOME="$TMP/home"
unset CLAUDE_PLUGIN_ROOT REVIEW_HARNESS_ALLOW_CONFIG_EDITS REVIEW_HARNESS_RUN_STALE_SECONDS REVIEW_HARNESS_RTK
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
echo "- **x**: y" > "$TMP/wh/knowledge/index.md"
has "session-start: Source names the knowledge index under REVIEW_HARNESS_HOME" "- Source: $TMP/wh/knowledge/index.md (" \
  "$(cd "$TMP" && HOME="$TMP/emptyhome" REVIEW_HARNESS_HOME="$TMP/wh" bash "$H/session-start.sh")"
rm -f "$TMP/wh/knowledge/index.md"
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
OUT=$(bash "$H/detect-repo.sh" "$TMP/my-app-api")   # no org/detect-repo-hint.txt exists yet
has "detect-repo: unmatched, no hint file → default hint" "- hint: register the repo in" "$OUT"
eq "detect-repo: unmatched, no hint file → end marker" "=== End Active Repo ===" "$(printf '%s\n' "$OUT" | tail -n 1)"

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
lacks "profile: developer does not get the #review section, only its rule lines" "React performance — FAIL if any:" "$OUT"
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
# Real web-api / web-common profiles: per-agent routing, and web-frontend output unchanged by their presence.
OUT=$(bash "$H/extract-constraints.sh" reviewer web-api 2>/dev/null)
has "web-api: reviewer gets the block" "## Profile — web-api" "$OUT"
has "web-api: reviewer gets #review (4xx rule)" "500-class exception" "$OUT"
lacks "web-api: reviewer does not get #implementation" "**Write after read**" "$OUT"
OUT=$(bash "$H/extract-constraints.sh" developer web-api 2>/dev/null)
has "web-api: developer gets #implementation" "**Write after read**" "$OUT"
lacks "web-api: developer does not get the #review section, only its rule lines" "Static review gates — FAIL if any:" "$OUT"
has "web-common: reviewer gets the block" "## Profile — web-common" "$(bash "$H/extract-constraints.sh" reviewer web-common 2>/dev/null)"
eq "web-api: test-runner has no profile section" "$(bash "$H/extract-constraints.sh" test-runner 2>/dev/null)" \
  "$(bash "$H/extract-constraints.sh" test-runner web-api 2>/dev/null)"
OUT=$(bash "$H/extract-constraints.sh" reviewer web-frontend,web-api 2>/dev/null)
has "profile: list → one block per profile, in order" \
  "## Profile — web-api (part of this agent's instructions)"$'\n\n'"## #review"$'\n\n'"Static review gates — FAIL if any:" "$OUT"
case "$OUT" in *"## Profile — web-frontend"*"## Profile — web-api"*) PASS=$((PASS + 1)) ;; *) eq "profile: list keeps order" ordered unordered ;; esac
# A plugin copy without the web-api / web-common files: web-frontend output must be byte-identical.
PC="$TMP/plugin-copy"; mkdir -p "$PC" && cp -R "$ROOT/hooks" "$ROOT/profiles" "$ROOT/constraints.md" "$PC/"
rm -f "$PC/profiles/web-api.md" "$PC/profiles/web-common.md"
OUT=$(bash "$H/extract-constraints.sh" reviewer web-frontend 2>/dev/null)
eq "web-frontend: reviewer output unchanged by the web-api profile" \
  "$(bash "$PC/hooks/extract-constraints.sh" reviewer web-frontend 2>/dev/null)" "$OUT"
lacks "web-frontend: no web-api text leaks in" "500-class exception" "$OUT"

# --- detect-profile --------------------------------------------------------------------
dp() { bash "$H/detect-profile.sh" "$@"; }
eq "detect-profile: .tsx → web-frontend" web-frontend "$(cd "$TMP" && dp src/App.tsx)"
eq "detect-profile: .py only → none" "" "$(cd "$TMP" && dp app/main.py)"
eq "detect-profile: controller, no manifest → web-api" web-api "$(cd "$TMP" && dp src/user.controller.ts)"
eq "detect-profile: migrations .sql, no manifest → web-api" web-api "$(cd "$TMP" && dp db/migrations/001.sql)"
eq "detect-profile: .tsx + routes/ → all three" "web-frontend,web-api,web-common" "$(cd "$TMP" && dp src/App.tsx routes/x.ts)"
eq "detect-profile: profiles that do not exist are not printed" web-frontend \
  "$(cd "$TMP" && bash "$PC/hooks/detect-profile.sh" src/App.tsx routes/x.ts)"
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
# Monorepo: each unmatched path counts by its nearest manifest.
M="$TMP/mono"; mkdir -p "$M/apps/web" "$M/apps/api" "$M/packages/util" "$M/services/py" && git -C "$M" init -q
echo '{"dependencies":{"next":"14","react":"18"}}' > "$M/apps/web/package.json"
echo '{"dependencies":{"@nestjs/core":"10"}}' > "$M/apps/api/package.json"
echo '{"dependencies":{"lodash":"4"}}' > "$M/packages/util/package.json"
printf '[project]\ndependencies = ["fastapi>=0.110"]\n' > "$M/services/py/pyproject.toml"
eq "detect-profile: monorepo react .ts + nest .ts → all three" "web-frontend,web-api,web-common" \
  "$(cd "$M" && dp apps/web/src/a.ts apps/api/src/b.ts)"
eq "detect-profile: .ts in a package with neither → none" "" "$(cd "$M" && dp packages/util/src/c.ts)"
eq "detect-profile: .py under a fastapi pyproject → web-api" web-api "$(cd "$M" && dp services/py/app/main.py)"
# API-name rules: a frontend-only package's api/ and routes/ folders are client code; Next server routes are not.
eq "detect-profile: src/api/ .ts in a react package → web-frontend" web-frontend "$(cd "$C" && dp src/api/client.ts)"
eq "detect-profile: src/routes/ .tsx in a react package → web-frontend" web-frontend "$(cd "$C" && dp src/routes/Home.tsx)"
eq "detect-profile: Next app/api route → all three" "web-frontend,web-api,web-common" \
  "$(cd "$M" && dp apps/web/app/api/orders/route.ts)"
eq "detect-profile: Next pages/api route → all three" "web-frontend,web-api,web-common" \
  "$(cd "$M" && dp apps/web/src/pages/api/x.ts)"
eq "detect-profile: nest controller → web-api" web-api "$(cd "$M" && dp apps/api/src/users/users.controller.ts)"
eq "detect-profile: nest src/api/ .ts → web-api" web-api "$(cd "$M" && dp apps/api/src/api/x.ts)"
eq "detect-profile: api/ under a package with neither → web-api" web-api "$(cd "$M" && dp packages/util/api/x.ts)"
eq "detect-profile: Next package prisma migration → includes web-api" "web-frontend,web-api,web-common" \
  "$(cd "$M" && dp apps/web/prisma/migrations/x/migration.sql)"
eq "detect-profile: Next package src/server/ → includes web-api" "web-frontend,web-api,web-common" \
  "$(cd "$M" && dp apps/web/src/server/db.ts)"
eq "detect-profile: .tsx under api/, no manifest → all three" "web-frontend,web-api,web-common" "$(cd "$TMP" && dp api/Form.tsx)"
mkdir -p "$M/apps/ssr" && echo '{"dependencies":{"react":"18","express":"4"}}' > "$M/apps/ssr/package.json"
eq "detect-profile: api/ in a react + express package → all three" "web-frontend,web-api,web-common" \
  "$(cd "$M" && dp apps/ssr/src/api/x.ts)"

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

# --- scan-repo -------------------------------------------------------------------------
sr() { bash "$H/scan-repo.sh" "$@" 2>/dev/null; }
snap() { (cd "$1" && find . -print | sort && find . -type f -exec cksum {} + | sort); }
NX="$TMP/next-app"; mkdir -p "$NX/src/app" && git -C "$NX" init -q
cat > "$NX/package.json" <<'EOF'
{"dependencies":{"next":"^14.2.3","react":"18.3.1","zustand":"^4.5.0"},
 "devDependencies":{"tailwindcss":"^4.0.0","typescript":"~5.4.0","eslint":"8"}}
EOF
printf '{\n  // comment line\n  "compilerOptions": {"paths": {"@/*": ["./src/*"]}}\n}\n' > "$NX/tsconfig.json"
touch "$NX/vitest.config.ts"; git -C "$NX" add -A
EXP="### next-app
- **local_path**: \`$NX\`
- **role**: TODO
- **stack**: next 14, react 18, typescript 5, tailwindcss 4, zustand 4
- **layout**: \`src/\`
- **path_alias**: \`@/*\` → \`./src/*\`
- **test_cmd**: \`npx vitest run\`"
BEFORE=$(snap "$NX")
eq "scan-repo: next + tailwind v4 + tsconfig paths + vitest" "$EXP" "$(sr "$NX")"
eq "scan-repo: from a subdirectory → the repo root block" "$EXP" "$(cd "$NX/src/app" && sr)"
eq "scan-repo: writes nothing" "$BEFORE" "$(snap "$NX")"
PYA="$TMP/fast-api"; mkdir -p "$PYA/app"
printf '[project]\ndependencies = ["fastapi>=0.110", "pydantic>=2"]\n[tool.pytest.ini_options]\n[tool.ruff]\n' > "$PYA/pyproject.toml"
OUT=$(sr "$PYA")
has "scan-repo: fastapi stack" "- **stack**: python, fastapi, pydantic" "$OUT"
has "scan-repo: pytest" "- **test_cmd**: \`python -m pytest\`" "$OUT"
has "scan-repo: ruff → check_cmd" "- **check_cmd**: \`ruff check .\`" "$OUT"
has "scan-repo: app/ layout" "- **layout**: \`app/\`" "$OUT"
GO="$TMP/go-svc"; mkdir -p "$GO"; printf 'module example.com/x\n\ngo 1.22\n' > "$GO/go.mod"
OUT=$(sr "$GO")
has "scan-repo: go version" "- **stack**: go 1.22" "$OUT"
has "scan-repo: go vet check_cmd" "- **check_cmd**: \`go vet ./...\`" "$OUT"
mkdir -p "$TMP/empty-dir"
eq "scan-repo: empty dir → name, path, role only" "### empty-dir
- **local_path**: \`$TMP/empty-dir\`
- **role**: TODO" "$(sr "$TMP/empty-dir")"
WS="$TMP/pnpm-mono"; mkdir -p "$WS"; echo '{"devDependencies":{"typescript":"5"}}' > "$WS/package.json"
printf "packages:\n  - 'apps/*'\n  - \"packages/*\"\nonlyBuiltDependencies:\n  - esbuild\n" > "$WS/pnpm-workspace.yaml"
OUT=$(sr "$WS")
has "scan-repo: pnpm workspace → special" "- **special**: workspaces: apps/*, packages/*" "$OUT"
lacks "scan-repo: pnpm workspace stops at the next key" "esbuild" "$OUT"
lacks "scan-repo: TS repo gets no check_cmd" "check_cmd" "$OUT"
echo '{"workspaces":["web","api"]}' > "$TMP/empty-dir/package.json"
has "scan-repo: npm workspaces → special" "- **special**: workspaces: web, api" "$(sr "$TMP/empty-dir")"
rm -f "$TMP/empty-dir/package.json"
# File-derived values must stay on their own line: a newline in a tsconfig path cannot inject registry keys.
INJ="$TMP/inject"; mkdir -p "$INJ"
printf '%s\n' '{"compilerOptions":{"paths":{"@/*":["./src/*`\n- **test_cmd**: `echo PWNED-TEST`\r\n- **check_cmd**: `echo PWNED-CHECK"],' \
  '"x\n### evil":["./x/*"],"empty/*":[]}}}' > "$INJ/tsconfig.json"
OUT=$(sr "$INJ")
eq "scan-repo: tsconfig newline injects no keys" "local_path role path_alias" \
  "$(printf '%s\n' "$OUT" | sed -n 's/^- \*\*\([a-z_]*\)\*\*:.*/\1/p' | paste -sd' ' -)"
eq "scan-repo: one heading only" 1 "$(printf '%s\n' "$OUT" | grep -c '^###')"
lacks "scan-repo: empty paths array is skipped, no null" "null" "$OUT"
mkdir -p "$TMP/injhome/knowledge" && printf '%s\n' "$OUT" > "$TMP/injhome/knowledge/repos.md"
has "scan-repo: injected block is still registered" "- name: inject" "$(REVIEW_HARNESS_HOME="$TMP/injhome" bash "$H/detect-repo.sh" "$INJ")"
eq "scan-repo: injected tsconfig gives no test_cmd" "" "$(REVIEW_HARNESS_HOME="$TMP/injhome" dt "$INJ")"
# A backtick in the repo path would cut the local_path span short: the scan refuses it.
BT="$TMP/tick\`dir"; mkdir -p "$BT/sub"
for d in "$BT" "$BT/sub"; do
  OUT=$(bash "$H/scan-repo.sh" "$d" 2>&1 >/dev/null); RC=$?
  eq "scan-repo: backtick in the repo path → exit 1 (${d#$TMP/})" 1 "$RC"
  eq "scan-repo: backtick in the repo path → no block (${d#$TMP/})" "" "$(sr "$d")"
  has "scan-repo: backtick in the repo path → says why (${d#$TMP/})" "contains a backtick" "$OUT"
done
# Round trip: the proposed block, appended to a flat registry, is matched by detect-repo.sh and read by detect-test-cmd.sh.
RT="$TMP/rthome"; mkdir -p "$RT/knowledge"; sr "$NX" > "$RT/knowledge/repos.md"
OUT=$(REVIEW_HARNESS_HOME="$RT" bash "$H/detect-repo.sh" "$NX/src")
has "scan-repo round trip: detect-repo matches" "- name: next-app" "$OUT"
has "scan-repo round trip: registry test_cmd read back" "- test_cmd: \`npx vitest run\`" "$OUT"
# register-repo: the injected block names the registry file it will append to.
RR="$ROOT/skills/register-repo/SKILL.md"
target() { (cd "$NX" && REVIEW_HARNESS_HOME="$1" CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$(awk '/^```!$/{f=1;next} /^```$/{if(f)exit} f' "$RR")" 2>/dev/null \
  | sed -n 's/^registry file: //p'); }
mkdir -p "$TMP/rr0/knowledge"; eq "register-repo: no org folder → flat registry" "$TMP/rr0/knowledge/repos.md" "$(target "$TMP/rr0")"
mkdir -p "$TMP/rr1/knowledge/acme"; eq "register-repo: one org folder → its repos.md" "$TMP/rr1/knowledge/acme/repos.md" "$(target "$TMP/rr1")"
mkdir -p "$TMP/rr2/knowledge/a" "$TMP/rr2/knowledge/b"; touch "$TMP/rr2/knowledge/b/repos.md"
eq "register-repo: the registry detect-repo reads" "$TMP/rr2/knowledge/b/repos.md" "$(target "$TMP/rr2")"
mkdir -p "$TMP/rr3/knowledge/a" "$TMP/rr3/knowledge/b"; eq "register-repo: two org folders, no registry → flat" "$TMP/rr3/knowledge/repos.md" "$(target "$TMP/rr3")"
mkdir -p "$TMP/rr4/knowledge/acme"; touch "$TMP/rr4/knowledge/repos.md"
eq "register-repo: flat registry + one org folder without repos.md → flat" "$TMP/rr4/knowledge/repos.md" "$(target "$TMP/rr4")"
dups() { (cd "$NX" && REVIEW_HARNESS_HOME="$1" CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$(awk '/^```!$/{f=1;next} /^```$/{if(f)exit} f' "$RR")" 2>/dev/null \
  | sed -n "s/^existing headings named 'next-app' in registry file: //p"); }
eq "register-repo: no registry file → 0 same-name headings" 0 "$(dups "$TMP/rr0")"
printf '### next-app\n- **local_path**: `/elsewhere/next-app`\n' >> "$TMP/rr4/knowledge/repos.md"
eq "register-repo: same-name heading counted" 1 "$(dups "$TMP/rr4")"
has "register-repo: injects the scan" "- **role**: TODO" "$(cd "$NX" && REVIEW_HARNESS_HOME="$TMP/rr0" CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$(awk '/^```!$/{f=1;next} /^```$/{if(f)exit} f' "$RR")" 2>/dev/null)"
BT="$TMP/bad\`dir"; mkdir -p "$BT"
has "register-repo: a failed scan shows its reason" "scan unavailable: scan-repo: the repo path contains a backtick" \
  "$(cd "$BT" && REVIEW_HARNESS_HOME="$TMP/rr0" CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$(awk '/^```!$/{f=1;next} /^```$/{if(f)exit} f' "$RR")" 2>/dev/null)"
# The injected block runs in the user's shell: under zsh an unmatched glob must not print "no matches found".
if command -v zsh >/dev/null 2>&1; then
  zt() { (cd "$NX" && REVIEW_HARNESS_HOME="$1" CLAUDE_PLUGIN_ROOT="$ROOT" zsh -f -c "$(awk '/^```!$/{f=1;next} /^```$/{if(f)exit} f' "$RR")" 2>&1); }
  OUT=$(zt "$TMP/rr0")
  lacks "register-repo: zsh, no org folder → no glob error" "no matches found" "$OUT"
  has "register-repo: zsh, no org folder → flat registry" "registry file: $TMP/rr0/knowledge/repos.md" "$OUT"
  OUT=$(zt "$TMP/rr1")
  lacks "register-repo: zsh, one org folder → no glob error" "no matches found" "$OUT"
  has "register-repo: zsh, one org folder → its repos.md" "registry file: $TMP/rr1/knowledge/acme/repos.md" "$OUT"
else
  echo "skip: register-repo zsh tests (zsh not installed)"
fi
# review-harness: the injected register line follows the per-work-tree decline flag.
RCMD=$(sed -n 's/^- register: !`\(.*\)`$/\1/p' "$ROOT/skills/review-harness/SKILL.md")
reg() { (cd "$NX" && CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$RCMD"); }
eq "review-harness: register offer by default" offer "$(reg)"
touch "$(bash "$H/state-dir.sh" --create "$NX")/register-declined"
eq "review-harness: declined flag stops the offer" declined "$(reg)"

# --- find-consumers: other registered repos that use a changed name ----------------------
FC="$TMP/fc"; mkdir -p "$FC/home/knowledge/acme" "$FC/api/src" "$FC/web/src" "$FC/admin/src" "$FC/big"
printf 'export class UserDto { userName: string }\n' > "$FC/api/src/user.dto.ts"
printf 'const n = res.userName;\n\tlabel(`${res.userName}`)\r\nconst x = userNameX;\n' > "$FC/web/src/a.ts"
FCSKIP="node_modules dist .next build out coverage storybook-static .git"
for d in $FCSKIP; do mkdir -p "$FC/web/$d"; echo 'userName' > "$FC/web/$d/f.js"; done
echo 'nothing here' > "$FC/admin/src/b.ts"
printf '%s\n' 'get("/api/users")' 'fetch("https://x.io/api/users?id=1")' > "$FC/web/src/r.ts"
printf 'const evilTerm = "\342\200\256x\342\201\246y\342\200\252";\n' > "$FC/web/src/z.ts"
i=1; while [ $i -le 25 ]; do echo "userName $i"; i=$((i + 1)); done > "$FC/big/many.ts"
cat > "$FC/home/knowledge/acme/repos.md" <<EOF
### api
- **local_path**: \`$FC/api\`

### web (\`@acme/web\`)
- **local_path**: \`$FC/web\`$SP

### admin
- **local_path**: \`$FC/admin\`

### big
- **local_path**: \`$FC/big\`

### gone
- **local_path**: \`$FC/gone\`
EOF
fcons() { (cd "$1" && shift && REVIEW_HARNESS_HOME="${FCH:-$FC/home}" bash "$H/find-consumers.sh" "$@" 2>&1); }
BEFORE=$(snap "$FC")
OUT=$(fcons "$FC/api/src" userName)
eq "find-consumers: hits per other repo, word match, trimmed, safe" "web (@acme/web): src/a.ts:1: const n = res.userName;
web (@acme/web): src/a.ts:2: label(\${res.userName})
admin: no match" "$(printf '%s\n' "$OUT" | sed -n 1,3p)"
lacks "find-consumers: the current repo is skipped" "api:" "$OUT"
for d in $FCSKIP; do lacks "find-consumers: skips $d/" ": $d/" "$OUT"; done
eq "find-consumers: 20 lines per repo, then a count" "20 big: +5 more" \
  "$(printf '%s\n' "$OUT" | grep -c '^big: many.ts:') $(printf '%s\n' "$OUT" | grep '^big: +')"
has "find-consumers: missing local_path is reported" "gone: local_path not found: $FC/gone" "$OUT"
eq "find-consumers: writes nothing" "$BEFORE" "$(snap "$FC")"
eq "find-consumers: several terms in one search" "3" "$(fcons "$FC/api" nothing res.userName | grep -c '^\(admin\|web\)')"
has "find-consumers: a term starting with - is a term" "web (@acme/web): no match" "$(fcons "$FC/api" --version)"
eq "find-consumers: no term → exit 2" 2 "$(fcons "$FC/api" >/dev/null; echo $?)"
mkdir -p "$TMP/norg"; for t in awk sed grep tr head sort cat ls dirname; do ln -sf "$(command -v $t)" "$TMP/norg/$t"; done
eq "find-consumers: grep fallback gives the same output" "$OUT" \
  "$(cd "$FC/api/src" && PATH="$TMP/norg" REVIEW_HARNESS_HOME="$FC/home" "$BASH" "$H/find-consumers.sh" userName 2>&1)"
# A term with a non-word end (a route) is a plain literal match: whole-word would miss it inside a URL.
RT='web (@acme/web): src/r.ts:1: get("/api/users")
web (@acme/web): src/r.ts:2: fetch("https://x.io/api/users?id=1")'
has "find-consumers: route term inside a URL (rg or grep)" "$RT" "$(fcons "$FC/api" /api/users)"
has "find-consumers: route term inside a URL, grep fallback" "$RT" \
  "$(cd "$FC/api" && PATH="$TMP/norg" REVIEW_HARNESS_HOME="$FC/home" "$BASH" "$H/find-consumers.sh" /api/users 2>&1)"
eq "find-consumers: a line hit by a word and a route term prints once" 1 "$(fcons "$FC/api" get /api/users | grep -c 'src/r.ts:1:')"
eq "find-consumers: Unicode bidi controls stripped" 'web (@acme/web): src/z.ts:1: const evilTerm = "xy";' "$(fcons "$FC/api" evilTerm | grep 'z.ts')"
OUT=$(FCH="$FC/none" fcons "$FC/api" userName; echo "exit $?")
eq "find-consumers: no registry → one notice, exit 0" "1 exit 0" "$(printf '%s\n' "$OUT" | grep -vc '^exit') $(printf '%s\n' "$OUT" | tail -n 1)"
has "find-consumers: no registry notice" "no repo registry" "$OUT"
mkdir -p "$FC/flat/knowledge"; printf '### api\n- **local_path**: `%s`\n' "$FC/api" > "$FC/flat/knowledge/repos.md"
has "find-consumers: only the current repo registered → notice" "no other registered repo" "$(FCH="$FC/flat" fcons "$FC/api" userName)"
has "find-consumers: flat registry, unregistered cwd searches all" "api: src/user.dto.ts:1: export class UserDto { userName: string }" \
  "$(FCH="$FC/flat" fcons "$TMP" userName)"

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
# Org profile overlay (org/profiles/<name>.md): loaded only inside that profile's block.
ec() { bash "$H/extract-constraints.sh" "$@"; }
FE_BEFORE=$(ec reviewer web-frontend 2>/dev/null); API_BEFORE=$(ec reviewer web-api 2>/dev/null)
TR_BEFORE=$(ec test-runner web-api 2>/dev/null); BUDGET_BEFORE=$(ec reviewer web-api 2>&1 >/dev/null | sed 's/ + profile.*//')
mkdir -p "$REVIEW_HARNESS_HOME/org/profiles"
printf 'preamble ORG-PRE\n\n## #implementation\n\n- org api do\n\n## #review\n\n- org api gate\n' > "$REVIEW_HARNESS_HOME/org/profiles/web-api.md"
printf '## #review\n\n- org nope gate\n' > "$REVIEW_HARNESS_HOME/org/profiles/nope.md"
OUT=$(ec reviewer web-api,web-common 2>/dev/null)
case "$OUT" in
  *"Static review gates — FAIL if any:"*"### Org rules — web-api"$'\n\n'"## #review"$'\n\n'"- org api gate"$'\n\n'"## Profile — web-common"*) PASS=$((PASS + 1)) ;;
  *) eq "org profile: reviewer gets it inside the web-api block, after the public rules" inside elsewhere ;;
esac
lacks "org profile: reviewer does not get its #implementation" "org api do" "$OUT"
lacks "org profile: preamble never extracted" "ORG-PRE" "$OUT"
has "org profile: developer gets its #implementation" "- org api do" "$(ec developer web-api 2>/dev/null)"
eq "org profile: test-runner unchanged" "$TR_BEFORE" "$(ec test-runner web-api 2>/dev/null)"
eq "org profile: other profiles unchanged" "$FE_BEFORE" "$(ec reviewer web-frontend 2>/dev/null)"
eq "org profile: bytes count in the profile part" "$BUDGET_BEFORE" "$(ec reviewer web-api 2>&1 >/dev/null | sed 's/ + profile.*//')"
rm -f "$REVIEW_HARNESS_HOME/org/profiles/web-api.md"
eq "org profile: removed → output as before" "$API_BEFORE" "$(ec reviewer web-api 2>/dev/null)"
OUT=$(ec reviewer nope 2>/dev/null); eq "org profile: org file alone does not make a profile valid" 2 "$?"

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

# --- workflows: intent table, plan template and flows agree -----------------------------
SK="$ROOT/skills/review-harness/SKILL.md"
SKD="$ROOT/skills/review-harness"
# SKILL.md is a core plus situational files, each read through one pointer line in the core.
SKP='→ read `${CLAUDE_PLUGIN_ROOT}/skills/review-harness/'
eq "skill split: the pure-move fixture is gone" no "$([ -e "$ROOT/tests/fixtures/review-harness-SKILL.pre-split.md" ] && echo yes || echo no)"
lacks "skill split: the added core line names the variable without \${}" '${CLAUDE_PLUGIN_ROOT}' "$(grep -F 'are read raw: replace the' "$SK")"
eq "skill split: core is at most 20000 bytes" yes "$([ "$(wc -c < "$SK" | tr -d ' ')" -le 20000 ] && echo yes || echo no)"
SKN=0
for f in "$SKD"/*.md; do
  b=$(basename "$f"); [ "$b" = SKILL.md ] && continue
  SKN=$((SKN + 1))
  eq "skill split: one pointer to $b" 1 "$(grep -cF "$SKP$b\` before " "$SK")"
done
eq "skill split: one pointer line per situational file" "$SKN" "$(grep -cF "$SKP" "$SK")"
eq "skill split: 10 situational files" 10 "$SKN"
SKX=$(for f in "$SKD"/*.md; do [ "$f" = "$SK" ] || cat "$f"; done | grep 'CLAUDE_PLUGIN_ROOT' | grep -v 'hooks/repo-rules.sh"')
eq "skill split: hook calls stay in the core but the one Contract rules line (and repo-rules.sh)" 1 "$(printf '%s' "$SKX" | grep -c .)"
has "skill split: that line is the Contract rules line" '**Contract rules**' "$(printf '%s\n' "$SKX" | head -n 1 | cut -c1-20)"
INTENTS=$(sed -n 's/^| `\([a-z-]*\)` | .*| .* |$/\1/p' "$SK" | tr '\n' ' ')
eq "skill: intent table rows" "feature refactor bugfix review " "$INTENTS"
WFLIST=$(grep -o '`<workflow>` = `[^`]*`' "$SK"); TMPL=$(grep '^\[feature' "$SKD/plan-gate.md")
for i in $INTENTS; do
  has "skill: run-state workflow list names $i" "$i" "$WFLIST"
  has "skill: plan template Intent names $i" "$i" "$TMPL"
  eq "skill: ### section for $i" 1 "$(grep -ci "^### $i\$" "$SK")"
done
has "skill: description names bug fix" "bug fix" "$(sed -n 's/^description: //p' "$SK")"
has "skill: review needs a diff and no symptom" "no failure symptom is described" "$(grep '^| `review`' "$SK")"
has "skill: Small change excludes bugfix" 'not a `refactor` or `bugfix` intent' "$(cat "$SK")"
has "skill: Small change allows 3 files, 1 new test file" 'the change touches at most 3 files, of which at most 1 is a new test file and the rest already exist' "$(cat "$SK")"
lacks "skill: Small change 2-file rule is gone" 'at most 2 existing files' "$(cat "$SK")"
has "small-change.md: names the 3-file limit" 'at most 3 files, at most 1 of them a new test file' "$(cat "$SKD/small-change.md")"
has "readme: Small change allows 3 files" 'touches at most 3 files, at most 1 of them a new test file,' "$(cat "$ROOT/README.md")"
lacks "readme: Small change 2-file rule is gone" 'at most 2 existing files' "$(cat "$ROOT/README.md")"
RG=$(sed -n '/^### 0\. RTK Mode Gate/,/^### 0\.5/p' "$SK")
lacks "skill: rtk gate asks no question" 'AskUserQuestion' "$RG"
has "skill: rtk default applies with no question" 'no question: the default applies (`standard` when the `rtk` binary is installed, else `off`); `/rtk-toggle` changes it' "$RG"
has "rtk-toggle: default is standard when rtk is installed" 'Default: `standard` when the `rtk` binary is on PATH, else `off`' "$(cat "$ROOT/skills/rtk-toggle/SKILL.md")"
lacks "readme: no first-use rtk question" 'On first use it asks' "$(cat "$ROOT/README.md")"
has "readme: rtk default" 'rtk is on by default (`standard`) when the `rtk` binary is installed' "$(cat "$ROOT/README.md")"
lacks "docs/hooks.md: no rtk picker on first use" 'picker is shown automatically' "$(cat "$ROOT/docs/hooks.md")"
has "docs/hooks.md: rtk default" '`standard` when the `rtk` binary is installed, else `off`' "$(cat "$ROOT/docs/hooks.md")"
has "docs/skills.md: RTK Mode Gate states the default" '**RTK Mode Gate** — no question: `standard` when the `rtk` binary is installed, else `off`' "$(cat "$ROOT/docs/skills.md")"
for f in README.md CLAUDE.md CHANGELOG.md docs/skills.md docs/hooks.md skills/review-harness/SKILL.md; do
  lacks "$f: no model-routing.md" 'model-routing.md' "$(cat "$ROOT/$f")"
done
for l in Symptom Repro Cause 'Regression test'; do
  eq "skill: plan template ## Bug has $l" 1 "$(sed -n '/^## Bug (bugfix only)/,/^$/p' "$SKD/plan-gate.md" | grep -c "^- $l: ")"
done
BF=$(cat "$SKD/bugfix.md")
has "skill: bugfix flow order" "reproduce -> plan.md (## Bug) -> user approval
-> test-runner (baseline) -> developer (regression test RED, then fix) -> test-runner -> reviewer" "$BF"
has "skill: bugfix never fixes by guess" "Never fix by guess" "$BF"
has "skill: bugfix harness loop" '`feature`, `bugfix` and `refactor`' "$(cat "$SK")"
RV=$(cat "$ROOT/agents/reviewer.md")
has "reviewer: bugfix regression gate" 'none named in the plan'"'"'s `Regression test` line, and no `Regression test: none — <reason>` → FAIL `[correctness]`' "$RV"
has "reviewer: bugfix gate reads red:" 'no `red:` line' "$RV"
has "reviewer: bugfix gate keys on ## Intent" 'plan `## Intent` is `bugfix`' "$RV"
has "developer: bugfix may run an existing test" 'or run the existing test named there' "$(cat "$ROOT/agents/developer.md")"
has "skill: handoff schema has optional red:" '- red: <' "$(sed -n '/^### Compact Handoff Schema/,/^Rules:/p' "$SK")"
has "skill: bugfix passes red: to reviewer" 'red:` line to `reviewer`' "$BF"
has "skill: first pass passes guidance: to reviewer (any intent)" 'Pass the developer'"'"'s `guidance:` line to `reviewer` when `Inputs.Web guidance` lists ids' \
  "$(sed -n '/^### Shared Skip Rules/,/^### Small change/p' "$SK")"
has "skill: cause loop-back counts an attempt" 'run `run-state.sh attempt` (stop and report at `LIMIT REACHED`), then redo reproduce' "$BF"
has "skill: plain review keyword unchanged" '| Keywords: `review`; `check`, `verify` only when a diff exists' "$(grep '^| `review`' "$SK")"
has "skill: no intent match → one question" 'If no intent matches, ask one clarifying question.' "$(cat "$SK")"
has "skill: trivial typo fix stays Small change" '"fix this typo") is not `bugfix` and stays on the Small change path' "$(cat "$SK")"
has "reviewer: bugfix cause gate" '`Cause` line does not explain → FAIL `[scope]`' "$(cat "$ROOT/agents/reviewer.md")"
has "developer: bugfix RED line in handoff" '`red: <line>`' "$(cat "$ROOT/agents/developer.md")"
# The documented start command works as written.
new_repo "$TMP/bugfix"; R="$TMP/bugfix"
BFCMD=$(printf '%s\n' "$BF" | sed -n 's/^Run state: `\(start bugfix[^`]*\)`.*/\1/p')
eq "run-state: documented bugfix start" "run-state: started 'bugfix'" "$(rs $BFCMD | sed 's/ →.*//')"
has "run-state: bugfix status" "active: bugfix · done: - · pending: reproduce,baseline,developer,test-runner,reviewer,git-commit" "$(rs status)"
rs step reproduce >/dev/null; rs verdict PASS >/dev/null
eq "run-state: bugfix PASS passes check" 0 "$( (cd "$R" && bash "$H/run-state.sh" check >/dev/null 2>&1); echo $?)"

# --- definition of done: plan sections, goal gate, one category list --------------------
PLAN=$(sed -n '/^# Plan: /,/^## Commit Units/p' "$SKD/plan-gate.md")
for s in 'Done When' 'Out of Scope'; do
  eq "skill: plan template has ## $s" 1 "$(printf '%s\n' "$PLAN" | grep -c "^## $s\$")"
  eq "refactor-architect: plan format has ## $s" 1 "$(grep -c "^## $s\$" "$ROOT/agents/refactor-architect.md")"
done
has "skill: Done When item names its check" '- [observable outcome] — check: [test name, command, or manual step]' "$PLAN"
has "skill: Done When / Out of Scope required for feature, bugfix, refactor" \
  '**Done When / Out of Scope rules**: required for `feature`, `bugfix`, `refactor`; omit for `review`. `Done When` lists 2–5 observable outcomes' "$(cat "$SKD/plan-gate.md")"
cats() { tr -d ' ' | tr '|' '\n'; }
C1=$(sed -n 's/.*\[category:\([a-z|-]*\)\].*/\1/p' "$ROOT/agents/reviewer.md" | cats)
C2=$(sed -n 's/^- `\[category\]`: `\([a-z |-]*\)`$/\1/p' "$ROOT/agents/reviewer.md" | cats)
C3=$(sed -n 's/.*\[category:\([a-z|-]*\)\].*/\1/p' "$ROOT/constraints.md" | cats)
has "reviewer: category list names goal" "goal" "$C1"
eq "reviewer: Output Format categories = failure-pattern categories" "$C1" "$C2"
eq "constraints: failure-pattern categories = reviewer's" "$C1" "$C3"
eq "run-state: verdict categories = reviewer's" "$(printf '%s\n' $C1 | sort | tr '\n' ' ')" \
  "$(sed -n 's/^CATEGORIES="\([^"]*\)".*/\1/p' "$H/run-state.sh" | tr ' ' '\n' | sort | tr '\n' ' ')"
has "reviewer: verdict FAIL carries its categories" '`… verdict FAIL` followed by the `[category]` tags of your FAIL issues' "$RV"
for f in review-harness code-review; do
  has "skill $f: verdict command takes FAIL categories" 'verdict <PASS|FAIL> [FAIL issue categories...]' "$(cat "$ROOT/skills/$f/SKILL.md")"
done
GG=$(sed -n '/^\*\*Goal gate\*\*/,/^---$/p' "$ROOT/agents/reviewer.md")
has "reviewer: goal gate reads the plan sections" 'also read `## Intent`, `## Done When` and `## Out of Scope`' "$GG"
lacks "reviewer: goal gate reads no unused ## Goal" '## Goal' "$GG"
has "reviewer: goal gate uses the Small change line" 'the `Done when:` line in your prompt is the only Done When item' "$GG"
has "reviewer: goal gate skip" 'With neither a plan_path nor a Small change `Done when:` line, skip this gate.' "$GG"
has "reviewer: goal gate FAILs [goal]" 'FAIL `[goal]` if any:' "$GG"
has "reviewer: missing Done When keyed on ## Intent" '`Done When` missing or empty when `## Intent` is `feature`, `bugfix` or `refactor`' "$GG"
has "reviewer: unmet item judged from test output" 'Judge a test or command check from `test_status` / the test-runner output; when that evidence is missing, run the command yourself.' "$GG"
has "reviewer: manual step never FAILs" 'A manual-step item never FAILs — list it in handoff `blockers` as `manual: <step>`' "$GG"
has "reviewer: stub rule only where Done When expects work" 'placeholder return (hardcoded or empty value where the logic should be) in something a Done When item expects to work' "$GG"
has "reviewer: stub exception — abstract/overridable, Out of Scope" 'Abstract/overridable members and stubs that `Out of Scope` names pass' "$GG"
has "reviewer: export rule" 'A new export with no caller in the change or the repo' "$GG"
for x in "exported from the package's public entry (index or \`package.json\` exports)" 'is a file-routed, decorator/DI-registered or CLI entry point' 'is used only by tests' 'or `Out of Scope` names the later change that calls it'; do
  has "reviewer: export exception — $x" "$x" "$GG"
done
has "reviewer: Out of Scope edit is [scope]" 'An edit to something `Out of Scope` names → FAIL `[scope]` (' "$GG"
has "reviewer: Out of Scope [scope] rule excepts named stubs" 'a stub that `Out of Scope` names' "$(sed -n '/^An edit to something `Out of Scope` names/p' "$ROOT/agents/reviewer.md")"
eq "refactor-architect: plan format has ## Intent refactor" "refactor" "$(sed -n '/^## Intent$/{n;p;}' "$ROOT/agents/refactor-architect.md")"
has "skill: test-runner gets the Done When checks" 'for `test-runner`, include the `Done When` test/command checks (or the Small change `Done when:` check) so it runs them' "$(cat "$SK")"
SC=$(cat "$SKD/small-change.md")
has "skill: Small change states a done-when line" '`Done when: <observable outcome> — check: <test, command, or manual step>`' "$SC"
has "skill: Small change passes it to reviewer" 'Put that `Done when:` line in the `reviewer` prompt.' "$SC"
has "skill: handoff max bullets allows red:" 'max 6 bullets plus `red:` for bugfix' "$(cat "$SK")"
has "skill: retries carry the first red: line" "bugfix: the first developer run's \`red:\` line — carry it through every retry" \
  "$(sed -n '/^Retry context must contain only:/,/^$/p' "$SKD/retry.md")"
has "developer: retry keeps the given red: line" 'On a retry, keep the `red:` line given in your prompt' "$(cat "$ROOT/agents/developer.md")"

# --- verification: test results in the commit gate --------------------------------------
R="$TMP/testsgate"; new_repo "$R"
chk() { (cd "$R" && bash "$H/run-state.sh" check "$@" 2>&1); }
rc() { "$@" >/dev/null 2>&1; echo $?; }
has "tests: no active run → not recorded" "no active run" "$(rs tests pass)"
eq "tests: no active run → exit 0" 0 "$(rc rs tests pass)"
SD=$(bash "$H/state-dir.sh" --create "$R"); echo "old.spec.ts > x" > "$SD/baseline.txt"
rs start feature baseline developer test-runner reviewer git-commit >/dev/null
eq "run-state: start clears the previous run's baseline" absent "$([ -f "$SD/baseline.txt" ] && echo present || echo absent)"
eq "tests: unknown status → exit 2" 2 "$(rc rs tests maybe)"
rs verdict PASS >/dev/null
eq "check: PASS, no tests record (older flows) → ok" 0 "$(rc chk)"
rs tests pass >/dev/null
eq "check: tests pass → ok" 0 "$(rc chk)"
has "status shows the tests record" "tests: pass" "$(rs status)"
has "tests: recorded line" "tests: fail recorded" "$(rs tests fail)"
eq "check: tests fail → blocked" 1 "$(rc chk)"
has "check: tests fail → reason" "the last test run failed" "$(chk)"
eq "gate: tests fail → deny" deny "$(gate "$R")"
eq "tests: manual-confirmed refused after fail" 1 "$(rc rs tests manual-confirmed)"
eq "check: still blocked after the refused confirmation" 1 "$(rc chk)"
rs tests none >/dev/null
eq "check: tests none, not confirmed → blocked" 1 "$(rc chk)"
has "check: tests none → asks for the user's confirmation" "only after the user explicitly confirms" "$(chk)"
eq "gate: tests none → deny" deny "$(gate "$R")"
rs tests manual-confirmed >/dev/null
eq "check: manual-confirmed for this tree → ok" 0 "$(rc chk)"
echo e >> "$R/f.txt"; rs verdict PASS >/dev/null
eq "check: manual confirmation of an older tree → blocked" 1 "$(rc chk)"
has "check: older confirmation → reason" "changed after the user's manual confirmation" "$(chk)"
rs tests manual-confirmed >/dev/null
eq "tests: re-confirm after a change → ok" 0 "$(rc chk)"
rs tests fail >/dev/null; echo f >> "$R/f.txt"; rs verdict PASS >/dev/null
eq "check: a fail recorded for an older tree still blocks" 1 "$(rc chk)"
rs override "user said commit anyway" >/dev/null
eq "check: user override passes a tests fail" 0 "$(rc chk)"
rs tests pass >/dev/null; echo g >> "$R/f.txt"; rs verdict PASS >/dev/null
eq "check: pass recorded for an older tree → blocked" 1 "$(rc chk)"
has "check: older test run → reason" "code changed after the last test run" "$(chk)"
eq "gate: pass for an older tree → deny" deny "$(gate "$R")"
rs tests pass >/dev/null
eq "check: re-run tests on the current tree → ok" 0 "$(rc chk)"
git -C "$R" add -A
eq "check: staging does not invalidate the test run" 0 "$(rc chk)"
# A new run starts with no tests record.
rs abandon >/dev/null; rs start small-change test-runner reviewer >/dev/null; rs verdict PASS >/dev/null
eq "check: a new run forgets the previous tests record" 0 "$(rc chk)"
echo "old.spec.ts > x" > "$SD/baseline.txt"; rs done >/dev/null
eq "run-state: done clears the baseline" absent "$([ -f "$SD/baseline.txt" ] && echo present || echo absent)"
rs start feature baseline >/dev/null; echo "old.spec.ts > x" > "$SD/baseline.txt"; rs abandon >/dev/null
eq "run-state: abandon clears the baseline" absent "$([ -f "$SD/baseline.txt" ] && echo present || echo absent)"

# --- verification: docs of the flow -----------------------------------------------------
TR=$(cat "$ROOT/agents/test-runner.md"); DV=$(cat "$ROOT/agents/developer.md")
has "skill: test-runner baseline before developer (feature)" "test-runner (baseline) -> developer" "$(sed -n '/^### Feature/,/^### Bugfix/p' "$SK")"
has "skill: test-runner baseline before developer (bugfix)" "test-runner (baseline) -> developer" "$BF"
has "skill: test-runner baseline before developer (refactor)" "test-runner (baseline) -> developer" "$(sed -n '/^### Refactor/,/^### Review/p' "$SK")"
has "skill: feature start example has the baseline step" "start feature baseline developer test-runner reviewer git-commit" "$(cat "$SK")"
has "skill: baseline failures told to the user in one line" "already fail before this change" "$(cat "$SK")"
has "skill: no-tests path needs the user's yes" 'Record `run-state.sh tests manual-confirmed` only after the user explicitly says yes' "$(cat "$SK")"
has "skill: test-runner gets the tests command" 'hooks/run-state.sh" tests <pass|fail|none>' "$(cat "$SK")"
has "test-runner: baseline file" "baseline.txt" "$TR"
has "test-runner: only new failures count" "only failures not in" "$TR"
has "test-runner: regression test always counts" "plan's \`Regression test\` always counts" "$TR"
has "test-runner: records tests status" 'hooks/run-state.sh" tests <pass|fail|none>' "$TR"
has "test-runner: Done When checks run without a test command" "also when no test command exists" "$TR"
has "test-runner: no-tests wording matches the skill" "orchestrator asks the user to confirm the manual checks" "$TR"
has "test-runner: whole-project check" 'otherwise `npx tsc --noEmit` when `tsconfig.json` exists' "$TR"
has "developer: RED is run, not only written" "run them and confirm they fail for the intended reason before implementing" "$DV"
lacks "developer: no 'code only' rule" "code only" "$DV"
has "developer: handoff may carry assumptions" '`assumptions:`' "$DV"
has "skill: handoff schema allows assumptions" "- assumptions: <" "$(sed -n '/^### Compact Handoff Schema/,/^Rules:/p' "$SK")"
lacks "constraints: no 'Output code only'" "Output code only" "$(cat "$ROOT/constraints.md")"
has "tdd: RED points at the developer rule" 'agents/developer.md` → Workflow' "$(cat "$ROOT/skills/tdd/SKILL.md")"
lacks "tdd: RED wording not duplicated" "Confirm they fail for the intended reason" "$(cat "$ROOT/skills/tdd/SKILL.md")"
has "git-commit: tests reasons named" "manual confirmation" "$(cat "$ROOT/skills/git-commit/SKILL.md")"

# --- planning discovery and task decomposition --------------------------------------------
PLAN=$(sed -n '/^# Plan: /,/^## Commit Units/p' "$SKD/plan-gate.md")
DC=$(printf '%s\n' "$PLAN" | sed -n '/^## Design Check$/,/^$/p')
for l in Callers/Consumers Pattern Tests; do
  eq "skill: Design Check has $l" 1 "$(printf '%s\n' "$DC" | grep -c "^- $l: ")"
done
has "skill: discovery lines filled from grep before approval" '`Callers/Consumers`, `Pattern`, `Tests` are also filled by the main session before approval, from grep' "$(cat "$SKD/plan-gate.md")"
OR=$(printf '%s\n' "$PLAN" | sed -n '/^## Only When Relevant/,/^$/p')
for l in Migration 'Dependency upgrade' Performance; do
  eq "skill: Only When Relevant has $l" 1 "$(printf '%s\n' "$OR" | grep -c "^- $l: ")"
done
has "skill: Execution Steps tasks over 6 files" '(more than 6 Affected Files) Task 1: [file group] — tests:' "$PLAN"
has "skill: task rule" 'More than 6 Affected Files → `Execution Steps` become ordered `Task N` lines' "$(cat "$SKD/plan-gate.md")"
has "developer: works task by task" 'With `Task N` steps, work task by task' "$DV"
has "developer: updates or marks callers" 'Update every file in `Callers/Consumers`, or append `no change needed: <reason>`' "$DV"
has "reviewer: contract gate" 'neither in the diff nor marked there `no change needed: <reason>` → FAIL `[contract]`' "$RV"

# --- changes across repos: plan Contract, consumer search, producer first, reviewer gate ------
CT=$(printf '%s\n' "$PLAN" | sed -n '/^## Contract (only when another repo may use what changes)$/,/^$/p')
for l in Producer Consumers Compatibility 'Deploy order'; do
  eq "skill: plan template ## Contract has $l" 1 "$(printf '%s\n' "$CT" | grep -c "^- $l: ")"
done
has "skill: Contract is additive or breaking" '- Compatibility: [additive | breaking]' "$CT"
has "skill: Contract consumers may be none with a reason" '"none — <reason>"' "$CT"
CR=$(grep '^\*\*Contract rules\*\*' "$SKD/plan-gate.md")
has "skill: breaking contract runs find-consumers.sh from the plugin root" 'run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/find-consumers.sh" <term...>`' "$CR"
has "skill: unchanged consumer repo needs an Out of Scope follow-up" 'gets its follow-up named in `Out of Scope`' "$CR"
has "skill: producer run first" 'The producer run goes first' "$CR"
has "skill: a pasted Contract block is Inputs.API in any intent" '**Pasted Contract (any intent, trigger or not)**: a `## Contract` block from the producer repo'"'"'s run is always the spec — record it as-is in `plan.md → Inputs.API`' \
  "$(cat "$SKD/api-spec.md")"
lacks "skill: pasted Contract is not a trigger-only table row" '| `## Contract` block pasted' "$(cat "$SKD"/*.md)"
for x in 'type changed' 'an existing optional request field made required' '(a request field made optional is not breaking)'; do
  has "skill: breaking definition — $x" "$x" "$CR"
done
has "skill: final report carries the Contract block" 'A plan with `## Contract`: end the final report with that block verbatim' "$(sed -n '/^## Completion/,$p' "$SK")"
has "reviewer: breaking contract with no consumers FAILs" 'A `## Contract` marked `breaking` whose `Consumers` line names no repo and no `none — <reason>` → FAIL `[contract]`' "$RV"
has "reviewer: unaddressed consumer hits FAIL" 'a consumer repo listed in that breaking contract with hits that the diff does not change and `Out of Scope` does not name as a follow-up → FAIL `[contract]`' "$RV"
for l in 18 44; do has "web-api: line $l points to the plan's Contract" 'the plan'"'"'s `## Contract`' "$(sed -n "${l}p" "$ROOT/profiles/web-api.md")"; done
NH=$(ls "$H"/*.sh | wc -l | tr -d ' ')
has "docs/hooks.md: hook count" "## $NH Hooks" "$(cat "$ROOT/docs/hooks.md")"
has "readme: hook count" "the $NH hook scripts" "$(cat "$ROOT/README.md")"
has "docs/hooks.md: find-consumers row" '| **`find-consumers.sh`** |' "$(cat "$ROOT/docs/hooks.md")"
RA=$(cat "$ROOT/agents/refactor-architect.md")
has "refactor-architect: characterization tests first" 'the first Migration Step is "Write characterization tests' "$RA"
has "refactor-architect: waiver recorded" 'Characterization tests: waived by user — <reason>' "$RA"
has "skill: refactor waiver recorded in the plan" 'Characterization tests: waived by user — <reason>' "$(sed -n '/^### Refactor/,/^### Review/p' "$SK")"
has "test-runner: baseline mode skips steps 5–7" 'Except in baseline mode (step 3), still run steps 5–7' "$TR"
has "skill: Small change has no baseline" 'It also has no test baseline' "$SC"
has "readme: Small change has no baseline" 'It also has no test baseline' "$(cat "$ROOT/README.md")"

# --- review triage: routes, disputes, issue count -------------------------------------------
RV=$(cat "$ROOT/agents/reviewer.md"); DV=$(cat "$ROOT/agents/developer.md")
OF=$(sed -n '/^## Output Format/,/^## Static Review Gates/p' "$ROOT/agents/reviewer.md")
has "reviewer: issue line carries a route" '-> [fix] (route: patch | replan | defer)' "$OF"
has "reviewer: defer is not a FAIL reason" '`defer` issues never make a FAIL' "$OF"
has "reviewer: every FAIL issue listed" 'List every `patch` / `replan` issue' "$OF"
lacks "reviewer: no 5-issue cap" "Max 5 issues" "$OF"
has "reviewer: dispute re-judges one issue" 're-judge only the disputed issue(s)' "$RV"
HL=$(sed -n '/^## Harness Loop/,/^## Completion/p' "$SK"; cat "$SKD/retry.md")
for r in 'patch  ->' 'replan ->' 'defer  ->'; do has "skill: harness loop routes $r" "$r" "$HL"; done
has "skill: replan needs re-approval" 'get the user'"'"'s re-approval' "$HL"
has "skill: dispute command in the loop" 'run-state.sh dispute <issue id...>' "$HL"
has "skill: every retry re-runs test-runner" 'Every retry runs `test-runner` again before `reviewer`, on the Small change path too' "$HL"
has "skill: defer items in the final report" 'reviewer'"'"'s `defer` issues' "$(sed -n '/^## Completion/,$p' "$SK")"
has "developer: may dispute once per issue" '`dispute: <issue id> — <evidence>`' "$DV"
has "code-review: FAIL list keeps routes" 'with each issue'"'"'s `route:`' "$(cat "$ROOT/skills/code-review/SKILL.md")"
FE=$(sed -n '/^## #review/,/^Review scope:/p' "$ROOT/profiles/web-frontend.md")
has "web-frontend: memo gates only on a hot path" 'only on a measured or obviously hot path' "$FE"
lacks "web-frontend: no unconditional inline-literal gate" $'\n- Inline object/function literal as prop without `useMemo`/`useCallback`\n' "$FE"

# --- retry memory and the failure-pattern ledger --------------------------------------------
LEDGER="$REVIEW_HARNESS_HOME/failure-patterns.md"
for a in reviewer test-runner; do
  has "ledger: $a gets the absolute ledger path" "ledger: $LEDGER" "$(ec $a 2>/dev/null)"
done
for a in developer refactor-architect; do lacks "ledger: $a gets no ledger line" "ledger: " "$(ec $a 2>/dev/null)"; done
lacks "ledger: absent file → no section" "## #failure-patterns" "$(ec reviewer 2>/dev/null)"
eq "constraints.md: no #failure-patterns section left" 0 "$(grep -c '^## #failure-patterns' "$ROOT/constraints.md")"
RV_NO_LEDGER=$(ec reviewer 2>&1 >/dev/null)
printf 'ledger preamble LP-X\n\n## #failure-patterns\n\n- [2026-11-17] [category:scope] edits outside plan - stay in Affected Files\n' > "$LEDGER"
for a in reviewer test-runner; do
  has "ledger: $a gets its entries" "- [2026-11-17] [category:scope] edits outside plan" "$(ec $a 2>/dev/null)"
  lacks "ledger: $a never gets the preamble" "LP-X" "$(ec $a 2>/dev/null)"
done
# Developer review checklist: only the rule lines of #review (constraints, each profile, its org profile) and
# the ledger entries, as one block at the end of the constraints part — no prose, no `## #` heading, no `ledger:`.
ckb() { ec developer "$@" 2>/dev/null | awk '/^## Review checklist/ { p = 1; print; next } p && /^## / { exit } p'; }
CKH="## Review checklist — the reviewer FAILs on these (check your diff before handoff)"
mkdir -p "$REVIEW_HARNESS_HOME/org/profiles"
printf '## #implementation\n\n- org fe do CK-IMPL\n\n## #review\n\nOrg prose CK-PROSE\n\n- org fe gate CK-ORG\n' > "$REVIEW_HARNESS_HOME/org/profiles/web-frontend.md"
CK=$(ckb web-frontend,web-api)
has "checklist: developer gets the block" "$CKH" "$CK"
eq "checklist: exactly one block" 1 "$(ec developer web-frontend,web-api 2>/dev/null | grep -c '^## Review checklist')"
has "checklist: constraints #review rule line" "- Property access on nullable without guard" "$CK"
has "checklist: profile #review rule line" '- `useEffect` missing dep or unstable ref causing infinite loop' "$CK"
has "checklist: second profile's #review rule line" "500-class exception" "$CK"
has "checklist: org profile #review rule line" "- org fe gate CK-ORG" "$CK"
lacks "checklist: no org profile #implementation" "CK-IMPL" "$CK"
has "checklist: ledger entries" "- [2026-11-17] [category:scope] edits outside plan" "$CK"
for x in "## #" "ledger:" "Logic correctness — FAIL if any:" "CK-PROSE" "**React / Next**"; do lacks "checklist: no prose or heading ($x)" "$x" "$CK"; done
eq "checklist: rule lines only" "" "$(printf '%s\n' "$CK" | sed 1d | grep -v '^- ' | grep -v '^$')"
lacks "ledger: developer gets no ledger line, even with a ledger" "ledger: " "$(ec developer 2>/dev/null)"
eq "checklist: ends the constraints part" "$CKH" "$(ec developer web-frontend 2>/dev/null | grep '^## ' | tail -n 1)"
CK=$(ckb)
lacks "checklist: no profile → no profile rule lines" '`useEffect` missing dep' "$CK"
lacks "checklist: no profile → no org profile rule lines" "CK-ORG" "$CK"
DEV_ERR=$(ec developer web-frontend 2>&1 >/dev/null)
has "checklist: bytes reported apart on stderr" " + checklist: " "$DEV_ERR"
MAIN=$(printf '%s' "$DEV_ERR" | sed 's/.*extract-constraints developer: \([0-9]*\) bytes.*/\1/')
lacks "checklist: bytes outside the warning threshold" "[warn]" "$(REVIEW_HARNESS_BUDGET_WARN_BYTES=$MAIN ec developer 2>&1 >/dev/null)"
for a in reviewer test-runner refactor-architect; do
  lacks "checklist: $a gets no block" "## Review checklist" "$(ec $a web-frontend,web-api 2>/dev/null)"
  lacks "checklist: $a stderr has no checklist note" "checklist" "$(ec $a web-frontend,web-api 2>&1 >/dev/null)"
done
rm -f "$REVIEW_HARNESS_HOME/org/profiles/web-frontend.md"
[ "$(ec reviewer 2>&1 >/dev/null | sed 's/.*: \([0-9]*\) bytes.*/\1/')" -gt "$(printf '%s' "$RV_NO_LEDGER" | sed 's/.*: \([0-9]*\) bytes.*/\1/')" ]
eq "ledger: entries count in the budget" 0 "$?"
rm -f "$LEDGER"
lacks "checklist: absent ledger → no ledger entries" "edits outside plan" "$(ckb)"
has "checklist: absent ledger → constraints rule lines stay" "- Property access on nullable without guard" "$(ckb)"
# A non-UTF-8 byte in the ledger: GNU grep in a UTF-8 locale would print "Binary file matches" instead of the lines.
printf '## #failure-patterns\n\n- [2026-11-18] [category:scope] bad \377 byte NB-1\n- [2026-11-18] [category:goal] after it NB-2\n' > "$LEDGER"
CK=$(LC_ALL=C.UTF-8 ec developer 2>/dev/null | LC_ALL=C sed -n '/^## Review checklist/,$p')   # the helper awk would trip on the byte too
has "checklist: line with a non-UTF-8 byte kept" "NB-1" "$CK"
has "checklist: line after a non-UTF-8 byte kept" "- [2026-11-18] [category:goal] after it NB-2" "$CK"
has "checklist: non-UTF-8 ledger → constraints rule lines stay" "- Property access on nullable without guard" "$CK"
lacks "checklist: non-UTF-8 ledger → no binary-file message" "Binary file" "$CK"
has "checklist: filter reads bytes as text (BSD grep only flags NUL)" "grep -a '^- '" "$(cat "$H/extract-constraints.sh")"
rm -f "$LEDGER"
NC="$TMP/plugin-noreview"; mkdir -p "$NC" && cp -R "$ROOT/hooks" "$ROOT/profiles" "$NC/"
awk '/^## #review/ { skip = 1; next } /^## #/ { skip = 0 } !skip' "$ROOT/constraints.md" > "$NC/constraints.md"
lacks "checklist: no rule lines → no block" "## Review checklist" "$(bash "$NC/hooks/extract-constraints.sh" developer 2>/dev/null)"
lacks "checklist: no rule lines → no stderr note" "checklist" "$(bash "$NC/hooks/extract-constraints.sh" developer 2>&1 >/dev/null)"
has "developer: self-check line in the handoff" '`self-check: <rule hit → fixed>; …` or `self-check: clean`' "$(cat "$ROOT/agents/developer.md")"
has "developer: Output rule allows self-check:" '`self-check:`' "$(grep -F '**Output**' "$ROOT/agents/developer.md")"
for f in reviewer test-runner; do
  AG=$(cat "$ROOT/agents/$f.md")
  lacks "$f: no constraints.md ledger" "constraints.md #failure-patterns" "$AG"
  has "$f: appends to the ledger path in its prompt" "ledger path given in your prompt" "$AG"
  has "$f: ledger scope clause" 'only rules that no static gate, profile, `#review`/`#org` rule or ESLint/tsc already enforces; one-off mistakes do not belong' "$AG"
  lacks "$f: no Edit tool left" "Bash, Edit" "$(sed -n 's/^tools: //p' "$ROOT/agents/$f.md")"
done
HL=$(sed -n '/^## Harness Loop/,/^## Completion/p' "$SK"; cat "$SKD/retry.md")
lacks "skill: LIMIT no longer writes constraints.md" "constraints.md #failure-patterns" "$HL"
has "skill: LIMIT appends to the ledger path" 'the `ledger:` path' "$HL"
has "skill: LIMIT names the ledger format" 'entry format and scope of agents/reviewer.md step 5; a new file starts with `## #failure-patterns`' "$HL"
has "skill: LIMIT replan on the Small change path" '(Small change: no plan — ask the user, or switch to the Feature path)' "$(sed -n '/prints "LIMIT REACHED"/,/^```$/p' "$SKD/retry.md")"
has "skill: dispute re-judge is no attempt line" 'not a dispute re-judge' "$HL"
has "skill: attempts line per retry" 'N. hypothesis → change → result' "$HL"
has "skill: attempts in plan.md or attempts.md" '`## Attempts` in plan.md' "$HL"
has "skill: attempts.md without a plan" '<state dir>/attempts.md' "$HL"
has "skill: retry context carries the Attempts lines" 'the Attempts lines' "$(sed -n '/^Retry context must contain only:/,/^$/p' "$SKD/retry.md")"
has "skill: third failure of the same test or issue asks about the plan" 'whether the plan is wrong' "$HL"
has "skill: orchestrator may write attempts.md" '`attempts.md`' "$(sed -n '/^## Canonical Rules/,/^---$/p' "$SK")"
has "skill: handoff schema allows root cause:" '- root cause: <' "$(sed -n '/^### Compact Handoff Schema/,/^Rules:/p' "$SK")"
has "skill: handoff schema has the developer self-check: line" '- self-check: <rule hit → fixed>; … | clean (developer only)' "$(sed -n '/^### Compact Handoff Schema/,/^Rules:/p' "$SK")"
has "skill: handoff Rules line names self-check: and guidance:" '`root cause:`, `self-check:` and `guidance:`' "$(grep '^Rules: omit empty fields' "$SK")"
has "developer: root cause on the second failure" '`root cause: <file:line' "$(cat "$ROOT/agents/developer.md")"
README_STATE=$(cat "$ROOT/README.md")
has "readme: attempts.md in the state table" '| `attempts.md` |' "$README_STATE"
has "readme: failure-patterns.md documented" '| `failure-patterns.md` |' "$README_STATE"
R="$TMP/attempts"; new_repo "$R"; SD=$(bash "$H/state-dir.sh" --create "$R"); echo "1. x → y → z" > "$SD/attempts.md"
rs start small-change test-runner reviewer >/dev/null
eq "run-state: start clears the previous run's attempts.md" absent "$([ -f "$SD/attempts.md" ] && echo present || echo absent)"
rs abandon >/dev/null

# --- modern web guidance: plan search, developer retrieve, reviewer legacy-scan ----------------
PINS=$(grep -rhoE 'modern-web-guidance@[A-Za-z0-9.-]*[A-Za-z0-9]' "$ROOT/skills" "$ROOT/agents" "$ROOT/profiles" "$ROOT/README.md" "$ROOT/docs" | sort -u)
eq "web guidance: one pinned version in skills, agents, profiles, README and docs" 1 "$(printf '%s\n' "$PINS" | grep -c .)"
case "$PINS" in modern-web-guidance@[0-9]*.[0-9]*.[0-9]*) PASS=$((PASS + 1)) ;; *) eq "web guidance: pin is x.y.z" x.y.z "$PINS" ;; esac
PIN=${PINS#modern-web-guidance@}
eq "web guidance: no @latest" "" "$(grep -rl 'modern-web-guidance@latest' "$ROOT/skills" "$ROOT/agents" "$ROOT/profiles" "$ROOT/README.md" "$ROOT/docs")"
eq "web guidance: no hook runs it" "" "$(grep -rl 'modern-web-guidance' "$H")"
has "skill: plan Inputs has Web guidance" '- Web guidance: [guide ids, none, or unavailable]' "$(sed -n '/^## Inputs/,/^$/p' "$SKD/plan-gate.md")"
WG=$(sed -n '/^### 4\.5\. Web Guidance Search/,/^### 5\./p' "$SK"; cat "$SKD/web-guidance.md")
has "skill: search step sits after the API Spec Check" "### 4.5. Web Guidance Search" "$(sed -n '/^### 4\. API Spec Check/,/^### 5\./p' "$SK")"
has "skill: search trigger is the web-frontend profile" '`detect-profile.sh` on the planned Affected Files includes `web-frontend`' "$WG"
has "skill: search only when a plan.md is written" 'a `plan.md` will be written (never on the Small change path or for `review`)' "$WG"
has "skill: search trigger skips non-UI work" 'not 3D/canvas-only, styling-token-only or tooling' "$WG"
has "skill: search command pinned" "npx -y modern-web-guidance@$PIN search \"<2–5 word action query>\"" "$WG"
has "skill: at most 3 searches" 'at most 3' "$WG"
has "skill: search unavailable never blocks" 'or any other CLI error or timeout → stop searching at that first one, write `unavailable` and continue. Never ask the user, never retry in a loop' "$WG"
has "skill: retries and reviewer carry guidance:" 'the same for the developer'"'"'s `guidance:` line whenever `Inputs.Web guidance` lists ids' "$(sed -n '/^Retry context must contain only:/,/^$/p' "$SKD/retry.md")"
has "skill: handoff schema has guidance:" '- guidance: <id> applied | <id> not applied — <reason> (developer only, when Inputs.Web guidance lists ids)' \
  "$(sed -n '/^### Compact Handoff Schema/,/^Rules:/p' "$SK")"
DEVO=$(ec developer web-frontend 2>/dev/null); REVO=$(ec reviewer web-frontend 2>/dev/null)
has "web guidance: developer retrieves the plan's ids" "npx -y modern-web-guidance@$PIN retrieve" "$DEVO"
has "web guidance: developer reads a saved temp file in full" 'read that file in full' "$DEVO"
EXEMPT="the plan, a stated browser policy, an existing repo or design-system component, this profile's rules, or an org rule"
has "web guidance: developer precedence list" "Precedence: $EXEMPT win over a guide" "$DEVO"
has "web guidance: guide CSS in the repo styling system" "write a guide's CSS in the repo's styling system and tokens (this profile's rules win)" "$DEVO"
has "web guidance: retry keeps guidance:" 'On a retry, keep the `guidance:` line from the prompt; `retrieve` again only when the fix list names a guide or a `legacy-scan` finding' "$DEVO"
has "web guidance: no dependency or polyfill" 'never adds a dependency or a polyfill unless the plan says so' "$DEVO"
has "web guidance: Baseline default" 'Baseline Widely Available unless the org overlay or the repo states a browser policy' "$DEVO"
has "web guidance: developer reports guidance:" '`guidance: <id> applied | <id> not applied — <reason>`' "$DEVO"
has "web guidance: developer self-check scans each file, bounded" "run \`npx -y modern-web-guidance@$PIN legacy-scan <file> --json\` on each added or modified UI file on its own (at most 5: the 5 with the most added lines)" "$DEVO"
has "web guidance: developer scan unavailable goes to self-check" '`legacy-scan: unavailable` in the `self-check:` line, not `blockers`' "$DEVO"
has "web guidance: developer checklist has the legacy-scan gate" '- `legacy-scan` finding on an ADDED line' "$DEVO"
lacks "web guidance: reviewer's unavailable → blockers rule stays out of the developer checklist" \
  '`legacy-scan: unavailable` in handoff `blockers`' "$(ckb web-frontend)"
for f in web-frontend web-api web-common; do
  has "$f: header table — #review reaches the developer checklist" '| `#review` | reviewer; developer (as its review checklist) |' "$(cat "$ROOT/profiles/$f.md")"
done
lacks "web guidance: reviewer never retrieves" "retrieve" "$REVO"
has "web guidance: reviewer scans each UI file, never a directory" "npx -y modern-web-guidance@$PIN legacy-scan <file> --json\` on each added or modified UI file on its own, never on a directory" "$REVO"
has "web guidance: reviewer scans at most 5 files" 'at most 5 files — with more, scan the 5 with the most added lines and put `legacy-scan: 5 of N files` in handoff `blockers`' "$REVO"
has "web guidance: reviewer UI file types" '`.tsx .jsx .vue .svelte .html .css .scss`' "$REVO"
has "web guidance: added-line finding → FAIL [design]" "rubric → FAIL \`[design]\`, unless $EXEMPT requires that pattern; on unchanged lines → a \`defer\` issue" "$REVO"
has "web guidance: unavailable is no FAIL" 'or any other CLI error or timeout) → `legacy-scan: unavailable` in handoff `blockers`, never a FAIL' "$REVO"
has "web guidance: missing guidance: → FAIL [goal]" 'the developer handoff has no `guidance:` line → FAIL `[goal]` (patch)' "$REVO"
README_WG=$(sed -n '/^## Modern web guidance/,/^## /p' "$ROOT/README.md")
has "readme: Modern web guidance section" "## Modern web guidance" "$README_WG"
has "readme: allowlist entry" "Bash(npx -y modern-web-guidance@$PIN *)" "$README_WG"
has "readme: hooks never run it" 'Hooks never run it' "$README_WG"
has "readme: token costs are estimates" 'Token cost (estimate, not measured)' "$README_WG"
has "readme: each retry repeats the reviewer scan" "each retry repeats the reviewer's scan" "$README_WG"
has "docs: flow names Web Guidance Search" 'Web Guidance Search' "$(cat "$ROOT/docs/skills.md")"
has "changelog: names modern-web-guidance" 'modern-web-guidance' "$(sed -n '/^### v0\.7\.0/,/^### v0\.6/p' "$ROOT/CHANGELOG.md")"

# --- post-tool-use: tsc count of errors in other files -------------------------------
TP="$TMP/tsproj"; mkdir -p "$TP/src" "$TMP/fakebin"; echo '{}' > "$TP/package.json"; echo '{}' > "$TP/tsconfig.json"
printf '#!/bin/sh\ncat "$TSC_FAKE_OUT"; exit 2\n' > "$TMP/fakebin/npx"; chmod +x "$TMP/fakebin/npx"
printf '%s\n' "src/other.ts(2,1): error TS2304: Cannot find name 'x'." "src/third.ts(3,1): error TS2304: Cannot find name 'y'." \
  "src/a.ts(1,7): error TS2322: Type 'number' is not assignable to type 'string'." > "$TMP/tsc-mixed.out"
printf '%s\n' "src/b.ts(1,1): error TS2304: Cannot find name 'z'." > "$TMP/tsc-own.out"
tsctx() { echo 'x' > "$TP/src/$1"; PATH="$TMP/fakebin:$PATH" TSC_FAKE_OUT="$2" REVIEW_HARNESS_RTK=off ctx "$TP/src/$1"; }
eq "post-tool-use: tsc block + other-files count" "[TypeScript Error]
src/a.ts(1,7): error TS2322: Type 'number' is not assignable to type 'string'.
other files: 2 more errors" "$(tsctx a.ts "$TMP/tsc-mixed.out" | sed -n '/^\[TypeScript Error\]/,/^$/p' | sed '/^$/d')"
lacks "post-tool-use: no count when only the edited file has errors" "other files:" "$(tsctx b.ts "$TMP/tsc-own.out")"
lacks "post-tool-use: no count on the all-files fallback" "other files:" "$(tsctx c.ts "$TMP/tsc-mixed.out")"

# --- run log (runs.jsonl) ----------------------------------------------------------------
RH="$TMP/loghome"; LOG="$RH/state/runs.jsonl"
rl() { # verdicts are recorded as the reviewer records them
  local by=(); [ "$1" = verdict ] && by=(--by reviewer)
  (cd "$R" && REVIEW_HARNESS_HOME="$RH" bash "$H/run-state.sh" "$@" ${by[@]+"${by[@]}"} 2>&1); }
lines() { wc -l < "$LOG" | tr -d ' '; }
R="$TMP/logrepo"; new_repo "$R"   # f.txt already edited
rl start feature developer reviewer >/dev/null; echo n > "$R/new.txt"
rl verdict FAIL '[goal]' contract >/dev/null; rl attempt >/dev/null; rl verdict PASS >/dev/null; rl tests pass >/dev/null
rl override "ship it" >/dev/null; rl done >/dev/null
eq "run log: done appends one line" 1 "$(lines)"
L=$(tail -n 1 "$LOG")
eq "run log: fields" '{"workflow":"feature","attempts":2,"verdicts":[{"v":"FAIL","cats":["goal","contract"],"by":"reviewer"},{"v":"PASS","by":"reviewer"}],"tests":"pass","override":"ship it","end":"done","files_changed":2}' \
  "$(printf '%s' "$L" | jq -c '{workflow, attempts, verdicts, tests, override, end, files_changed}')"
eq "run log: repo is the state folder id" "$(basename "$(REVIEW_HARNESS_HOME="$RH" bash "$H/state-dir.sh" "$R")")" "$(printf '%s' "$L" | jq -r .repo)"
eq "run log: duration = ended_at - started_at" true "$(printf '%s' "$L" | jq '.duration_s == .ended_at - .started_at and .duration_s >= 0')"
rl done >/dev/null
eq "run log: closing a closed run adds nothing" 1 "$(lines)"
rl start bugfix >/dev/null; rl abandon >/dev/null
eq "run log: abandon appends, earlier lines kept" "2 abandoned feature" "$(lines) $(tail -n 1 "$LOG" | jq -r .end) $(head -n 1 "$LOG" | jq -r .workflow)"
eq "run log: no reviewer verdict → empty sequence, null tests" '[] null' "$(tail -n 1 "$LOG" | jq -c .verdicts) $(tail -n 1 "$LOG" | jq .tests)"
rl start feature >/dev/null; rl verdict FAIL >/dev/null; rl verdict FAIL >/dev/null; rl verdict FAIL >/dev/null; rl done >/dev/null
eq "run log: attempts at the limit → end limit" limit "$(tail -n 1 "$LOG" | jq -r .end)"
rl verdict PASS >/dev/null; rl done >/dev/null
eq "run log: a standalone review record is not a run" 3 "$(lines)"
R="$TMP/logrepo-nocommit"; mkdir -p "$R" && git -C "$R" init -q && echo x > "$R/a.txt"
rl start small-change >/dev/null; rl done >/dev/null
eq "run log: no base commit → files_changed omitted" false "$(tail -n 1 "$LOG" | jq 'has("files_changed")')"
rm -f "$LOG"; mkdir "$LOG"   # an append that cannot succeed
rl start feature >/dev/null; OUT=$(rl done); RC=$?
eq "run log: failed append → done still exits 0" 0 "$RC"
has "run log: failed append → warning" "could not append the run" "$OUT"
eq "run log: failed append → run still closed" none "$(rl status)"
rmdir "$LOG"
# verdict categories
R="$TMP/catrepo"; new_repo "$R"; SD=$(REVIEW_HARNESS_HOME="$RH" bash "$H/state-dir.sh" "$R")
rl start feature >/dev/null
OUT=$(rl verdict FAIL '[Goal]' 'scope,' bogus goal); RC=$?
eq "verdict: FAIL with categories keeps the exit code" 0 "$RC"
has "verdict: unknown category → warning" "unknown category ignored: bogus" "$OUT"
has "verdict: categories do not change the attempt count" "attempts: 1/3" "$OUT"
eq "verdict: tags normalised, deduplicated, in order" '{"v":"FAIL","cats":["goal","scope"],"by":"reviewer"}' "$(jq -c '.verdicts[-1]' "$SD/run-state.json")"
rl verdict FAIL >/dev/null
eq "verdict: FAIL without tags stores no cats" '{"v":"FAIL","by":"reviewer"}' "$(jq -c '.verdicts[-1]' "$SD/run-state.json")"
has "verdict: PASS ignores categories" "categories are for FAIL only" "$(rl verdict PASS goal)"
eq "verdict: PASS stored without cats" '{"v":"PASS","by":"reviewer"}' "$(jq -c '.verdicts[-1]' "$SD/run-state.json")"
eq "verdict: unknown first word still exit 2" 2 "$(rc rl verdict MAYBE goal)"
# a run state written before categories (string verdicts) still logs as objects
jq '.verdicts = ["FAIL"] + .verdicts' "$SD/run-state.json" > "$SD/x" && mv "$SD/x" "$SD/run-state.json"
rl done >/dev/null
eq "run log: old string verdicts read back" '[{"v":"FAIL"},{"v":"FAIL","cats":["goal","scope"],"by":"reviewer"},{"v":"FAIL","by":"reviewer"},{"v":"PASS","by":"reviewer"}]' "$(tail -n 1 "$LOG" | jq -c .verdicts)"
eq "run log: no dispute → disputes 0" 0 "$(tail -n 1 "$LOG" | jq .disputes)"
# disputes: one per review round, never an attempt
R="$TMP/disputerepo"; new_repo "$R"; SD=$(REVIEW_HARNESS_HOME="$RH" bash "$H/state-dir.sh" "$R")
eq "dispute: no active run → exit 1" 1 "$(rc rl dispute 1)"
rl start feature developer test-runner reviewer >/dev/null
eq "dispute: no FAIL to dispute → exit 1" 1 "$(rc rl dispute 1)"
rl verdict FAIL goal scope >/dev/null
eq "dispute: no issue id → exit 2" 2 "$(rc rl dispute)"
OUT=$(rl dispute 2); RC=$?
eq "dispute: recorded → exit 0" 0 "$RC"
has "dispute: not counted as an attempt" "not an attempt" "$OUT"
eq "dispute: second in the same round → exit 2" 2 "$(rc rl dispute 1)"
has "dispute: re-judge FAIL is not an attempt" "attempts: 1/3" "$(rl verdict FAIL scope)"
eq "dispute: the re-judge opens no new round" 2 "$(rc rl dispute 1)"
eq "dispute: re-judge marked in the verdicts" '{"v":"FAIL","cats":["scope"],"rejudge":true,"by":"reviewer"}' "$(jq -c '.verdicts[-1]' "$SD/run-state.json")"
echo h >> "$R/f.txt"; has "dispute: the next review counts again" "attempts: 2/3" "$(rl verdict FAIL scope)"
rl dispute 1 >/dev/null; eq "dispute: allowed again in the next round" 0 "$?"
rl tests pass >/dev/null; rl verdict PASS >/dev/null
eq "dispute: upheld dispute → re-judge PASS passes check" 0 "$( (cd "$R" && REVIEW_HARNESS_HOME="$RH" bash "$H/run-state.sh" check >/dev/null 2>&1); echo $?)"
eq "dispute: attempts unchanged by disputes" 2 "$(jq .attempts "$SD/run-state.json")"
rl done >/dev/null
eq "run log: disputes counted" 2 "$(tail -n 1 "$LOG" | jq .disputes)"
eq "run log: re-judges kept in the verdicts" 'FAIL FAIL,rejudge FAIL PASS,rejudge' "$(tail -n 1 "$LOG" | jq -r '[.verdicts[] | .v + (if .rejudge then ",rejudge" else "" end)] | join(" ")')"
# a dispute followed by a code change is a normal review round, not a re-judge
rl start feature reviewer >/dev/null; rl verdict FAIL goal >/dev/null; rl dispute 1 >/dev/null
echo i >> "$R/f.txt"
has "dispute → edit → FAIL counts an attempt" "attempts: 2/3 — retry" "$(rl verdict FAIL scope)"
eq "dispute → edit → FAIL is no re-judge" '{"v":"FAIL","cats":["scope"],"by":"reviewer"}' "$(jq -c '.verdicts[-1]' "$SD/run-state.json")"
eq "dispute → edit: pending cleared" false "$(jq '.dispute.pending' "$SD/run-state.json")"
echo j >> "$R/f.txt"
eq "dispute: code changed since the FAIL → exit 1" 1 "$(rc rl dispute 1)"
has "dispute: code changed → reason" "code changed since the FAIL" "$(rl dispute 1)"
rl verdict FAIL >/dev/null
eq "dispute: at the limit → exit 1" 1 "$(rc rl dispute 1)"
has "dispute: at the limit → stop and report" "limit reached — stop and report" "$(rl dispute 1)"
rl done >/dev/null
mkdir -p "$TMP/edhome/state"; tail -n 1 "$LOG" > "$TMP/edhome/state/runs.jsonl"
has "run-stats: an edited-after-dispute FAIL keeps its categories" "FAIL categories: goal 1, scope 1, untagged 1" "$(REVIEW_HARNESS_HOME="$TMP/edhome" bash "$H/run-stats.sh")"
# an older state with a FAIL but no verdicts array may still dispute
rl start feature >/dev/null; rl verdict FAIL >/dev/null
jq 'del(.verdicts)' "$SD/run-state.json" > "$SD/x" && mv "$SD/x" "$SD/run-state.json"
eq "dispute: state without verdicts → allowed" 0 "$(rc rl dispute 1)"
rl abandon >/dev/null

# --- run-stats -------------------------------------------------------------------------
SH="$TMP/statshome"; mkdir -p "$SH/state"; NOW=$(date +%s)   # string verdicts = lines written before categories
cat > "$SH/state/runs.jsonl" <<EOF
{"repo":"web-aaaaaaaaaaaa","workflow":"feature","started_at":1000,"ended_at":2000,"duration_s":1000,"attempts":0,"verdicts":["PASS"],"tests":"pass","override":null,"end":"done","files_changed":4}
{"repo":"web-aaaaaaaaaaaa","workflow":"feature","started_at":1000,"ended_at":2000,"duration_s":1000,"attempts":2,"verdicts":[{"v":"FAIL","cats":["goal"]},{"v":"FAIL","cats":["goal","scope"]},{"v":"PASS"}],"tests":"pass","override":null,"end":"done"}
{"repo":"web-aaaaaaaaaaaa","workflow":"bugfix","started_at":1000,"ended_at":2000,"duration_s":1000,"attempts":3,"verdicts":["FAIL","FAIL","FAIL"],"tests":"fail","override":"user said ship it","end":"limit"}
{"repo":"web-api-bbbbbbbbbbbb","workflow":"small-change","started_at":1000,"ended_at":2000,"duration_s":1000,"attempts":0,"verdicts":["PASS"],"tests":null,"override":null,"end":"done"}
{"repo":"web-api-bbbbbbbbbbbb","workflow":"feature","started_at":$NOW,"ended_at":$NOW,"duration_s":0,"attempts":1,"verdicts":[],"tests":null,"override":null,"end":"abandoned"}
{"repo":"torn
EOF
st() { REVIEW_HARNESS_HOME="$SH" bash "$H/run-stats.sh" "$@" 2>&1; }
eq "run-stats: all runs" "runs: 5 (repo: all, since: all)
first review PASS: 50% (2/4)
mean attempts before PASS: 0.7 (3 runs ending in PASS)
runs with a reviewer FAIL: 40% (2/5)
FAIL categories: untagged 3, goal 2, scope 1
override rate: 20% (1/5)
limit reached: 1
by workflow:
  bugfix: runs 1 · attempts before PASS - · FAIL 100% (1/1) · override 100% (1/1) · limit 1 · FAIL categories untagged 3
  feature: runs 3 · attempts before PASS 1 · FAIL 33% (1/3) · override 0% (0/3) · limit 0 · FAIL categories goal 2, scope 1
  small-change: runs 1 · attempts before PASS 0 · FAIL 0% (0/1) · override 0% (0/1) · limit 0 · FAIL categories -" "$(st)"
has "run-stats: --repo by work-tree name, not a longer name sharing the prefix" "runs: 3 (repo: web, since: all)" "$(st --repo web)"
has "run-stats: --repo by full id" "runs: 2 (repo: web-api-bbbbbbbbbbbb" "$(st --repo web-api-bbbbbbbbbbbb)"
has "run-stats: --since keeps recent runs only" "runs: 1 (repo: all, since: 7d)" "$(st --since 7)"
eq "run-stats: nothing matches → count only" "runs: 0 (repo: nope, since: all)" "$(st --repo nope)"
eq "run-stats: bad --since → exit 2" 2 "$(rc st --since x)"
eq "run-stats: unknown flag → exit 2" 2 "$(rc st --all)"
has "run-stats: no log yet" "no runs recorded yet" "$(REVIEW_HARNESS_HOME="$TMP/nolog" bash "$H/run-stats.sh")"
mkdir -p "$TMP/rjhome/state"   # a re-judge after a dispute repeats its round's categories: counted once
echo '{"repo":"r-1","workflow":"feature","attempts":1,"verdicts":[{"v":"FAIL","cats":["goal","scope"]},{"v":"FAIL","cats":["scope"],"rejudge":true},{"v":"PASS"}],"end":"done"}' > "$TMP/rjhome/state/runs.jsonl"
has "run-stats: re-judge FAILs not counted in categories" "FAIL categories: goal 1, scope 1" "$(REVIEW_HARNESS_HOME="$TMP/rjhome" bash "$H/run-stats.sh")"
mkdir -p "$TMP/nojq"
has "run-stats: no jq → clear message" "jq is required" "$(PATH="$TMP/nojq" "$BASH" "$H/run-stats.sh" 2>&1)"
eq "run-stats: no jq → exit 3" 3 "$(PATH="$TMP/nojq" "$BASH" "$H/run-stats.sh" >/dev/null 2>&1; echo $?)"
lacks "run-stats: no agent data → no token lines" "subagents only" "$(st)"
mkdir -p "$TMP/aghome/state"
cat > "$TMP/aghome/state/runs.jsonl" <<'EOF'
{"repo":"r-1","workflow":"feature","attempts":0,"verdicts":[{"v":"PASS"}],"end":"done","agents":[{"type":"developer","n":1,"s":600,"in":100,"out":900,"cr":0,"cw":0,"tools":3},{"type":"reviewer","n":1,"s":120,"in":50,"out":50,"cr":0,"cw":0,"tools":1}],"tokens":{"in":150,"out":950,"cr":0,"cw":0}}
{"repo":"r-1","workflow":"feature","attempts":1,"verdicts":[{"v":"FAIL"},{"v":"PASS"}],"end":"done","agents":[{"type":"developer","n":2,"s":1200,"in":1000,"out":1000,"cr":0,"cw":0,"tools":5}],"tokens":{"in":1000,"out":1000,"cr":0,"cw":0}}
{"repo":"r-1","workflow":"bugfix","attempts":0,"verdicts":[],"end":"abandoned"}
EOF
OUT=$(REVIEW_HARNESS_HOME="$TMP/aghome" bash "$H/run-stats.sh")
eq "run-stats: first review PASS is the line after runs" "first review PASS: 50% (1/2)" "$(printf '%s\n' "$OUT" | sed -n 2p)"
has "run-stats: median tokens per run" "tokens per run (subagents only): median 1550 total, 975 output (2 runs with agent data)" "$OUT"
has "run-stats: median active minutes per run" "active minutes per run (subagents only): median 16" "$OUT"
has "run-stats: per-agent share and median seconds" "per agent (subagents only): developer 97% of tokens, median 900s · reviewer 3% of tokens, median 120s" "$OUT"
has "run-stats: old lines unchanged with agent data" "limit reached: 0" "$OUT"

# --- agent usage (SubagentStart / SubagentStop) --------------------------------------------
R="$TMP/agentrepo"; new_repo "$R"; SD=$(bash "$H/state-dir.sh" "$R"); AF="$SD/run-state.json"; AG="$SD/agents.jsonl"; ALOG="$REVIEW_HARNESS_HOME/state/runs.jsonl"
TR="$TMP/agent.jsonl"   # m1 repeats on two lines (one per content block); a <synthetic> model line; the last line is torn
cat > "$TR" <<'EOF'
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","timestamp":"t1","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20},"content":[{"type":"text","text":"hi"}]}}
{"type":"assistant","timestamp":"t2","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20},"content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"ok"}]}}
{"type":"assistant","timestamp":"t3","message":{"id":"m2","model":"claude-x","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4},"content":[{"type":"tool_use","id":"tu2","name":"Read","input":{}}]}}
{"type":"assistant","timestamp":"t4","message":{"id":"m4","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"x"}]}}
{"type":"assistant","message":{"id":"m3"
EOF
au() { # au <event> <agent_id> [agent_type] [transcript] — run agent-usage.sh as Claude Code would
  jq -n --arg e "$1" --arg id "$2" --arg t "${3:-review-harness:developer}" --arg tp "${4:-$TR}" --arg d "$R" \
    '{session_id:"s", transcript_path:"/x", cwd:$d, hook_event_name:$e, agent_id:$id, agent_type:$t}
     + (if $e == "SubagentStop" then {stop_hook_active:false, agent_transcript_path:$tp, last_assistant_message:"done"} else {} end)' \
    | bash "$H/agent-usage.sh"; }
aj() { rs agents | jq -c "$1"; }
agent_age() { # agent_age <id> <seconds> — move the id's last start line back by <seconds>
  jq -Rrs --arg id "$1" --argjson by "$2" '[split("\n")[] | select(length > 0)] as $l
    | ([range($l | length) | select($l[.] | fromjson? | .e == "start" and .id == $id)] | last) as $i
    | $l | .[$i] |= (fromjson | .ts -= $by | tojson) | .[]' "$AG" > "$AG.x" && mv "$AG.x" "$AG"; }
age() { jq --argjson by "$2" "$1 -= \$by" "$3" > "$3.x" && mv "$3.x" "$3"; }   # age <path> <seconds> <file>
gatefields() { jq -c '{review, verdicts, tests, attempts, updated_at}' "$AF"; }
exists() { [ -e "$1" ] && echo true || echo false; }
OUT=$(au SubagentStart a1); RC=$?
eq "agent-usage: no run → silent, exit 0" "0:" "$RC:$OUT"
eq "agent-usage: no run → nothing written" "false false" "$(exists "$AF") $(exists "$AG")"
rs start feature developer reviewer >/dev/null
age .updated_at 100 "$AF"; G0=$(gatefields)
OUT=$(au SubagentStart a1); RC=$?
eq "agent-usage: start → silent, exit 0" "0:" "$RC:$OUT"
eq "agent-usage: start opens a span in agents.jsonl, type without plugin prefix" '{"type":"developer","open":true,"s":0}' "$(aj '.a1 | {type, open: (.open | type == "number"), s}')"
agent_age a1 5; OUT=$(au SubagentStop a1); RC=$?
eq "agent-usage: stop → silent, exit 0" "0:" "$RC:$OUT"
eq "agent-usage: run-state.json (gate fields, updated_at) untouched by start/stop" "$G0" "$(gatefields)"
eq "agent-usage: run-state.json holds no agent data" false "$(jq 'has("agents")' "$AF")"
eq "agent-usage: stop → deduplicated tokens, tools, model (not <synthetic>), span closed" '{"model":"claude-x","in":11,"out":7,"cr":103,"cw":24,"tools":2,"open":null}' \
  "$(aj '.a1 | {model, in, out, cr, cw, tools, open}')"
eq "agent-usage: stop → active seconds" true "$(aj '.a1.s >= 5 and .a1.s < 60')"
au SubagentStart a1; agent_age a1 3; au SubagentStop a1
eq "agent-usage: resume → tokens replaced, not added" '{"in":11,"out":7,"tools":2}' "$(aj '.a1 | {in, out, tools}')"
eq "agent-usage: resume → second span added" true "$(aj '.a1.s >= 8 and .a1.s < 60')"
N0=$(wc -l < "$AG"); OUT=$(au SubagentStop a9); RC=$?
eq "agent-usage: unknown agent_id → silent, exit 0" "0:" "$RC:$OUT"
eq "agent-stop: unknown id exits early, nothing appended to agents.jsonl" "$N0" "$(wc -l < "$AG")"
eq "agent-usage: unknown agent_id → no entry" null "$(aj '.a9')"
au SubagentStart a2 review-harness:reviewer; agent_age a2 2
OUT=$(au SubagentStop a2 review-harness:reviewer "$TMP/missing.jsonl"); RC=$?
eq "agent-usage: missing transcript → silent, exit 0" "0:" "$RC:$OUT"
eq "agent-usage: missing transcript → span kept, no tokens" '{"type":"reviewer","in":0,"time":true}' "$(aj '.a2 | {type, in, time: (.s >= 2)}')"
au SubagentStart a3 test-runner   # bare agent type (matcher allows it)
eq "agent-usage: bare agent type kept" '"test-runner"' "$(aj '.a3.type')"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do { au SubagentStart "p$i"; au SubagentStop "p$i"; } & done; wait
eq "agent-usage: 12 parallel starts + interleaved stops all recorded and closed" 12 \
  "$(aj '[to_entries[] | select(.key | startswith("p")) | select(.value.open == null and .value.in == 11)] | length')"
grep -v '"id":"p' "$AG" > "$AG.x" && mv "$AG.x" "$AG"
printf '{"e":"start","id":"t\n' >> "$AG"   # a torn line (killed writer)
au SubagentStart t1; au SubagentStop t1
eq "agent-usage: torn line skipped, next line still read" '{"open":null,"in":11}' "$(aj '.t1 | {open, in}')"
printf '{"e":"stop","id":"z9","ts":1,"u":{"in":5}}\n' >> "$AG"
eq "agent-usage: stop with no earlier start ignored by the fold" null "$(aj '.z9')"
grep -v -e '"id":"t' -e '"id":"z9"' "$AG" > "$AG.x" && mv "$AG.x" "$AG"
OUT=$(printf '{"hook_event_name":"SubagentStart"}' | PATH="$TMP/nojq" "$BASH" "$H/agent-usage.sh" 2>&1); RC=$?
eq "agent-usage: no jq → silent, exit 0" "0:" "$RC:$OUT"
OUT=$(printf 'not json' | bash "$H/agent-usage.sh" 2>&1); RC=$?
eq "agent-usage: bad input → silent, exit 0" "0:" "$RC:$OUT"
has "status: agent count" " · agents 3" "$(rs status)"
rs done >/dev/null
eq "agents.jsonl: removed by done" false "$(exists "$AG")"
eq "run log: agents grouped by type" '[{"type":"developer","n":1,"in":11,"out":7,"cr":103,"cw":24,"tools":2},{"type":"reviewer","n":1,"in":0,"out":0,"cr":0,"cw":0,"tools":0},{"type":"test-runner","n":1,"in":0,"out":0,"cr":0,"cw":0,"tools":0}]' \
  "$(tail -n 1 "$ALOG" | jq -c '[.agents[] | del(.s)]')"
eq "run log: agent seconds summed" true "$(tail -n 1 "$ALOG" | jq '(.agents[0].s >= 8) and (.agents[1].s >= 2)')"
eq "run log: run token totals" '{"in":11,"out":7,"cr":103,"cw":24}' "$(tail -n 1 "$ALOG" | jq -c .tokens)"
echo '{"e":"start","id":"x","t":"developer","ts":1}' > "$AG"   # left over from a closed run
echo '{}' > "$SD/agents.json"; mkdir "$SD/agents.json.lock"   # left over from an older version
rs start feature >/dev/null
eq "agents.jsonl + old agents.json/lock: removed by start" "false false false" "$(exists "$AG") $(exists "$SD/agents.json") $(exists "$SD/agents.json.lock")"
rs done >/dev/null
eq "run log: no agent data → no agents/tokens keys" false "$(tail -n 1 "$ALOG" | jq 'has("agents") or has("tokens")')"
lacks "status: no agent data → no agent count" "agents" "$(rs start feature >/dev/null; rs status)"
au SubagentStart b1; echo '{}' > "$SD/agents.json"; mkdir "$SD/agents.json.lock"; rs abandon >/dev/null
eq "agents.jsonl + old agents.json/lock: removed by abandon" "false false false" "$(exists "$AG") $(exists "$SD/agents.json") $(exists "$SD/agents.json.lock")"
rs start feature >/dev/null; age .updated_at 200000 "$AF"; G0=$(gatefields)
eq "agent-usage: stale run → check --active-only exit 4 (before)" 4 "$(rc rs check --active-only)"
OUT=$(au SubagentStart s1); RC=$?
eq "agent-usage: stale run → silent, exit 0" "0:" "$RC:$OUT"
eq "agent-usage: stale run → check --active-only still exit 4" 4 "$(rc rs check --active-only)"
eq "agent-usage: stale run → nothing recorded, run-state.json untouched" "false $G0" "$(exists "$AG") $(gatefields)"
rs abandon >/dev/null
AM='^(review-harness:)?(developer|test-runner|reviewer|refactor-architect)$'
eq "hooks.json: SubagentStart/Stop matcher" "$AM $AM" "$(jq -r '[.hooks.SubagentStart[0].matcher, .hooks.SubagentStop[0].matcher] | join(" ")' "$H/hooks.json")"
eq "hooks.json: both run agent-usage.sh" 2 "$(jq '[.hooks.SubagentStart[0].hooks[0].command, .hooks.SubagentStop[0].hooks[0].command] | map(select(test("hooks/agent-usage.sh"))) | length' "$H/hooks.json")"
eq "hooks.json: matcher selects plugin agents only" "review-harness:developer reviewer" \
  "$(printf '%s\n' review-harness:developer reviewer Explore review-harness:developer-x other:reviewer | grep -E "$AM" | tr '\n' ' ' | sed 's/ $//')"

# --- bench -----------------------------------------------------------------------------
B="$ROOT/bench"
IDS=$(ls "$B/cases" | tr '\n' '|')
for c in "$B"/cases/*/; do
  c=$(basename "$c"); FX=$(mktemp -d "$TMP/review.XXXXXX")   # README recipe: opaque fixture dir
  echo "$FX" > "$TMP/fx-$c"
  bash "$B/cases/$c/setup.sh" "$FX" >/dev/null 2>&1; eq "bench $c: setup exits 0" 0 "$?"
  eq "bench $c: base commit exists" 0 "$(git -C "$FX" rev-parse -q --verify HEAD >/dev/null; echo $?)"
  eq "bench $c: base not made by git commit" "" "$(git -C "$FX" reflog --format=%gs | grep '^commit')"
  eq "bench $c: diff is non-empty" 1 "$(git -C "$FX" diff --quiet; echo $?)"
  case "$(wc -l < "$B/cases/$c/expect.txt" | tr -d ' ')" in 3|4) PASS=$((PASS + 1)) ;; *) eq "bench $c: expect.txt has 3 or 4 lines" 3 "$(wc -l < "$B/cases/$c/expect.txt")" ;; esac
  META="$FX
$(git -C "$FX" log --format='%an %ae %cn %ce %B') $(git -C "$FX" reflog --format=%gs)"
  eq "bench $c: no case id or 'bench' in path / log / reflog" "" "$(printf '%s\n' "$META" | grep -iE "bench|${IDS%|}")"
  eq "bench $c: no case id in any fixture file" "" "$(grep -rlE "${IDS%|}" "$FX")"
  eq "bench $c: no expect.txt in fixture" "" "$(find "$FX" -name expect.txt)"
done
for c in fe-effect-cleanup:web-frontend api-unawaited:web-api; do
  OUT=$(TMPDIR="$TMP" bash "$B/prompt.sh" current "$(cat "$TMP/fx-${c%%:*}")" 2>/dev/null)
  has "bench prompt ${c%%:*}: reviewer Output Format" "## Output Format" "$OUT"
  has "bench prompt ${c%%:*}: profile block" "## Profile — ${c#*:}" "$OUT"
  eq "bench prompt ${c%%:*}: no case id" "" "$(printf '%s\n' "$OUT" | grep -E "${IDS%|}")"
done
lacks "bench prompt: frontmatter stripped" "model: " "$OUT"
lacks "bench prompt: no case dir → no plan_path" "- plan_path: " "$OUT"
lacks "bench prompt: case dir without plan.md → no plan_path" "- plan_path: " \
  "$(TMPDIR="$TMP" bash "$B/prompt.sh" current "$(cat "$TMP/fx-api-unawaited")" "$B/cases/api-unawaited" 2>/dev/null)"
# Plan-based cases: the plan reaches the reviewer as plan_path at an opaque path, and the fixture is what the plan describes.
for c in goal-not-wired bug-cause-elsewhere contract-caller-missed; do
  FX=$(cd "$(cat "$TMP/fx-$c")" && pwd -P); CD="$B/cases/$c"
  eq "bench $c: plan and handoff name no case id or 'bench'" "" "$(cat "$CD/plan.md" "$CD/handoff.md" | grep -iE "bench|${IDS%|}")"
  OUT=$(TMPDIR="$TMP" bash "$B/prompt.sh" current "$FX" "$CD" 2>/dev/null)
  has "bench prompt $c: plan_path next to the fixture" "## Handoff"$'\n'"- plan_path: $FX.plan.md" "$OUT"
  eq "bench prompt $c: plan copied unchanged" "" "$(diff "$CD/plan.md" "$FX.plan.md" 2>&1)"
  has "bench prompt $c: handoff lines follow" "$(tail -n 1 "$CD/handoff.md")" "$OUT"
  eq "bench prompt $c: no case id" "" "$(printf '%s\n' "$OUT" | grep -E "${IDS%|}")"
  CATS4=$(sed -n 4p "$CD/expect.txt"); BAD=""
  for k in $(printf '%s' "$CATS4" | tr '|' ' '); do case " correctness performance design scope goal security contract ops state-mgmt " in *" $k "*) ;; *) BAD="$BAD $k" ;; esac; done
  eq "bench $c: expect line 4 lists known categories only" "" "$BAD"
  [ -n "$CATS4" ]; eq "bench $c: expect line 4 lists at least one category" 0 "$?"
done
DIFF=$(git -C "$(cat "$TMP/fx-goal-not-wired")" diff --name-only)
lacks "bench goal-not-wired: the page is not in the diff" "page.tsx" "$DIFF"
has "bench goal-not-wired: the plan expects the page" "src/app/orders/page.tsx - " "$(cat "$B/cases/goal-not-wired/plan.md")"
DIFF=$(git -C "$(cat "$TMP/fx-bug-cause-elsewhere")" diff --name-only)
has "bench bug-cause-elsewhere: the symptom file is fixed" "CartBadge.tsx" "$DIFF"
lacks "bench bug-cause-elsewhere: the Cause file is not" "cart.ts" "$DIFF"
lacks "bench bug-cause-elsewhere: naming the file alone is not a keyword" "cart" "$(sed -n 2p "$B/cases/bug-cause-elsewhere/expect.txt")"
has "bench bug-cause-elsewhere: Cause names it" "- Cause: src/store/cart.ts:" "$(cat "$B/cases/bug-cause-elsewhere/plan.md")"
DIFF=$(git -C "$(cat "$TMP/fx-contract-caller-missed")" diff --name-only)
CALLERS=$(sed -n 's/^- Callers\/Consumers: `formatPrice` → //p' "$B/cases/contract-caller-missed/plan.md" | tr ',' '\n' | tr -d ' ')
eq "bench contract-caller-missed: 3 callers listed, 2 in the diff" "3 2" \
  "$(printf '%s\n' "$CALLERS" | grep -c .) $(printf '%s\n' "$CALLERS" | grep -cxF "$DIFF")"
printf '%s\n' rule 'await|promise' src/a.service.ts > "$TMP/expect.txt"
printf '%s\n' '## Code Review Verdict: FAIL' '### Issues' '1. [correctness] [src/a.service.ts:3] - missing await' \
  '2. [design] [src/b.ts:1] - magic value' > "$TMP/out-hit.md"
printf '%s\n' '## Code Review Verdict: PASS' '### Handoff' '- changed_files: src/a.service.ts' > "$TMP/out-miss.md"
eq "bench score: FAIL with file + keyword → caught" "caught extra=1" "$(bash "$B/score.sh" "$TMP/expect.txt" "$TMP/out-hit.md")"
eq "bench score: PASS → missed" "missed extra=0" "$(bash "$B/score.sh" "$TMP/expect.txt" "$TMP/out-miss.md")"
echo 'correctness|ops' >> "$TMP/expect.txt"
eq "bench score: line 4 category matched" "caught extra=1 category=match" "$(bash "$B/score.sh" "$TMP/expect.txt" "$TMP/out-hit.md")"
printf '%s\n' rule 'await|promise' src/a.service.ts goal > "$TMP/expect.txt"
eq "bench score: line 4 category not matched" "caught extra=1 category=other" "$(bash "$B/score.sh" "$TMP/expect.txt" "$TMP/out-hit.md")"
eq "bench score: line 4, missed → no category" "missed extra=0" "$(bash "$B/score.sh" "$TMP/expect.txt" "$TMP/out-miss.md")"
printf '%s\n' '## Code Review Verdict: FAIL' '### Issues' '1. [design] [src/b.ts:1] - magic value (route: patch)' \
  '2. [correctness] [src/a.service.ts:3] - missing await (route: defer)' > "$TMP/out-defer.md"
eq "bench score: a defer line is neither caught nor extra" "missed extra=1" "$(bash "$B/score.sh" "$TMP/expect.txt" "$TMP/out-defer.md")"

# --- bench (developer side) ----------------------------------------------------------------
NM=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null); case "$NM" in ''|*[!0-9]*) NM=0 ;; esac
if [ "$NM" -lt 20 ]; then
  echo "skip: bench (developer side) — node 20+ not found"
else
FORBID="bench|accept|solution|trap|$(ls "$B/cases-dev" | tr '\n' '|')"; FORBID=${FORBID%|}
dfx() { # dfx <case> [patch] — fresh opaque fixture of a developer-side case, with cases-dev/<case>/<patch>.patch applied
  local d; d=$(mktemp -d "$TMP/w.XXXXXX"); bash "$B/cases-dev/$1/setup.sh" "$d" >/dev/null 2>&1 || return 1
  [ -z "${2:-}" ] || git -C "$d" apply "$B/cases-dev/$1/$2.patch" || return 1
  echo "$d"
}
ntest() { (cd "$1" && node --test >/dev/null 2>&1); echo $?; }   # exit code of the fixture's own tests
nhidden() { # nhidden <fixture> <case> — exit code of the case's hidden tests, run from test/accept/ as dev-score.sh does
  mkdir -p "$1/test/accept" && cp "$B/cases-dev/$2"/accept/*.test.js "$1/test/accept/" \
    && (cd "$1" && node --test test/accept/*.test.js >/dev/null 2>&1); echo $?; rm -rf "$1/test/accept"
}
for c in "$B"/cases-dev/*/; do
  c=$(basename "$c"); FX=$(dfx "$c"); eq "bench-dev $c: setup exits 0" 0 "$?"
  echo "$FX" > "$TMP/dfx-$c"
  eq "bench-dev $c: clean tree" "" "$(git -C "$FX" status --porcelain)"
  eq "bench-dev $c: base not made by git commit" "" "$(git -C "$FX" reflog --format=%gs | grep '^commit')"
  eq "bench-dev $c: base tests pass" 0 "$(ntest "$FX")"
  eq "bench-dev $c: hidden tests fail at base" 1 "$(nhidden "$FX" "$c")"
  META="$FX
$(git -C "$FX" log --format='%an %ae %cn %ce %B') $(git -C "$FX" reflog --format=%gs)"
  eq "bench-dev $c: no forbidden word in path / log / reflog" "" "$(printf '%s\n' "$META" | grep -iE "$FORBID")"
  eq "bench-dev $c: no forbidden word in fixture files or names" "" \
    "$(grep -rliE --exclude-dir=.git "$FORBID" "$FX"; find "$FX" -path "$FX/.git" -prune -o -print | sed "s|^$FX||" | grep -iE "$FORBID")"
  eq "bench-dev $c: no forbidden word in task.md" "" "$(grep -iE "$FORBID" "$B/cases-dev/$c/task.md")"
  for p in solution trap; do
    PF=$(dfx "$c" $p); eq "bench-dev $c: $p.patch applies" 0 "$?"
    eq "bench-dev $c: $p passes base tests" 0 "$(ntest "$PF")"
    echo "$PF" > "$TMP/dfx-$c-$p"
  done
  eq "bench-dev $c: solution passes hidden tests" 0 "$(nhidden "$(cat "$TMP/dfx-$c-solution")" "$c")"
  eq "bench-dev $c: trap fails hidden tests" 1 "$(nhidden "$(cat "$TMP/dfx-$c-trap")" "$c")"
done
CD="$B/cases-dev/dev-unwired"
dout() { # dout <out-dir> <work-dir> <arm> — a finished-run out-dir as dev-run.sh leaves it
  mkdir -p "$1" && cp -R "$2" "$1/work" && jq -nc --arg a "$3" '{arm: $a, wall_s: 7, user_replies: 1, aborted: null}' > "$1/run.json"
}
dscore() { TMPDIR="$TMP" bash "$B/dev-score.sh" "$CD" "$1" 2>/dev/null; }
dout "$TMP/ds-sol" "$(cat "$TMP/dfx-dev-unwired-solution")" plain
OUT=$(dscore "$TMP/ds-sol")
eq "bench dev-score: solution → solved, all hidden pass, no regression" "true 4/4 0 0" \
  "$(printf '%s' "$OUT" | jq -r '"\(.solved) \(.accept) \(.regressions) \(.tests_touched)"')"
eq "bench dev-score: run.json fields" "plain 7 1 null" "$(printf '%s' "$OUT" | jq -r '"\(.arm) \(.wall_s) \(.user_replies) \(.aborted)"')"
dout "$TMP/ds-trap" "$(cat "$TMP/dfx-dev-unwired-trap")" plain
eq "bench dev-score: trap → not solved, hidden tests fail" "false 2/4 0" \
  "$(dscore "$TMP/ds-trap" | jq -r '"\(.solved) \(.accept) \(.regressions)"')"
WK=$(dfx dev-unwired); rm "$WK/test/service.test.js"; sed -i.orig 's/(page - 1) \* limit/page * limit/' "$WK/src/orders/service.js"; rm "$WK/src/orders/service.js.orig"
dout "$TMP/ds-del" "$WK" plain
OUT=$(dscore "$TMP/ds-del")
eq "bench dev-score: deleted test + broken paging → touched and regressions" "1 true false" \
  "$(printf '%s' "$OUT" | jq -r '"\(.tests_touched) \(.regressions >= 1) \(.solved)"')"
WK=$(dfx dev-unwired); sed -i.orig '/listOrders returns no items past/,$d' "$WK/test/service.test.js"; rm "$WK/test/service.test.js.orig"
dout "$TMP/ds-cut" "$WK" plain
eq "bench dev-score: removed lines in a base test → touched" 1 "$(dscore "$TMP/ds-cut" | jq -r .tests_touched)"
dout "$TMP/ds-h" "$(cat "$TMP/dfx-dev-unwired-solution")" harness
mkdir -p "$TMP/ds-h/driver" "$TMP/ds-h/transcripts/p"
for n in 01 02; do jq -nc '{session_id: "s", total_cost_usd: 1.25, num_turns: 4, usage: {input_tokens: 10, output_tokens: 3, cache_read_input_tokens: 100}}' > "$TMP/ds-h/driver/$n.json"; done
printf '%s\n' '{"attempts":2,"verdicts":[{"v":"FAIL"},{"v":"PASS"}],"end":"done","override":null}' > "$TMP/ds-h/runs.jsonl"
printf '%s\n' '## Done When' '- GET works — check: test' '## Design Check' '- Callers/Consumers: src/routes/index.js' '## Bug' '' > "$TMP/ds-h/plan.md"
jq -nc '{message: {content: [{type: "tool_use", name: "Bash", input: {command: "node --test test/x.test.js"}}, {type: "tool_use", name: "Bash", input: {command: "ls"}}]}}' > "$TMP/ds-h/transcripts/p/s.jsonl"
OUT=$(dscore "$TMP/ds-h")
eq "bench dev-score: driver sums" "2.5 20 6 200 8" "$(printf '%s' "$OUT" | jq -r '"\(.cost_usd) \(.input_tokens) \(.output_tokens) \(.cache_read_tokens) \(.turns)"')"
eq "bench dev-score: harness run log and plan" "2 FAIL,PASS done 1 1 0" \
  "$(printf '%s' "$OUT" | jq -r '"\(.attempts) \(.verdicts | join(",")) \(.end) \(.plan_done_when) \(.plan_callers) \(.plan_bug)"')"
eq "bench dev-score: test runs from transcripts, clean → solved" "1 0 true" "$(printf '%s' "$OUT" | jq -r '"\(.test_runs) \(.contaminated) \(.solved)"')"
printf '%s\n' '{"attempts":3,"end":"limit"}' >> "$TMP/ds-h/runs.jsonl"
eq "bench dev-score: harness run ended at limit → not solved" "limit false" "$(dscore "$TMP/ds-h" | jq -r '"\(.end) \(.solved)"')"
sed -i.orig '$d' "$TMP/ds-h/runs.jsonl"; rm "$TMP/ds-h/runs.jsonl.orig"
echo '{"message":"cat bench/cases-dev/x/solution.patch"}' >> "$TMP/ds-h/transcripts/p/s.jsonl"
eq "bench dev-score: transcript names hidden files → contaminated, not solved" "1 false" "$(dscore "$TMP/ds-h" | jq -r '"\(.contaminated) \(.solved)"')"
eq "bench dev-score: no out-dir → usage" 2 "$(bash "$B/dev-score.sh" "$CD" "$TMP/nope" >/dev/null 2>&1; echo $?)"
# dev-run.sh with a stub claude first on PATH: STUB_ASK = calls 1..N end with "?", STUB_COST per call, STUB_SLEEP seconds
mkdir -p "$TMP/bin" "$TMP/dr/t"
cat > "$TMP/bin/claude" <<'EOF'
#!/bin/bash
n=$(($(cat "$STUB_DIR/n" 2>/dev/null || echo 0) + 1)); echo "$n" > "$STUB_DIR/n"
{ echo "call $n"; echo "cwd $PWD"; echo "env $CLAUDE_CONFIG_DIR $REVIEW_HARNESS_HOME $REVIEW_HARNESS_RTK"
  echo "plugin $(ls -A "$REVIEW_HARNESS_HOME/../plugin" 2>/dev/null | tr '\n' ' ')"
  echo "declined $(find "$REVIEW_HARNESS_HOME/state" -name register-declined 2>/dev/null | wc -l | tr -d ' ')"
  printf 'arg %s\n' "$@"; } >> "$STUB_DIR/log"
sleep "${STUB_SLEEP:-0}"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/p" "$REVIEW_HARNESS_HOME/state/x"
echo '{"message":{}}' >> "$CLAUDE_CONFIG_DIR/projects/p/s.jsonl"
echo '## Done When' > "$REVIEW_HARNESS_HOME/state/x/plan.md"; echo '{"end":"done"}' >> "$REVIEW_HARNESS_HOME/state/runs.jsonl"
r="Done."; [ "$n" -gt "${STUB_ASK:-0}" ] || r="Shall I go ahead?"
jq -nc --arg r "$r" --argjson c "${STUB_COST:-0.5}" '{session_id: "sess-1", total_cost_usd: $c, num_turns: 2, result: $r}'
EOF
chmod +x "$TMP/bin/claude"
drun() { # drun <name> <arm> [VAR=value ...] — exit code of dev-run.sh into $TMP/dr/<name>; the stub logs to $TMP/dr/s-<name>/log
  local n="$1" a="$2"; shift 2; mkdir -p "$TMP/dr/s-$n"
  env PATH="$TMP/bin:$PATH" STUB_DIR="$TMP/dr/s-$n" TMPDIR="$TMP/dr/t" "$@" bash "$B/dev-run.sh" "$a" "$CD" "$TMP/dr/$n" >/dev/null 2>&1; echo $?
}
art() { for f in driver/01.json work/package.json transcripts/p/s.jsonl plan.md runs.jsonl; do [ -e "$1/$f" ] && printf 1 || printf 0; done; }
rj() { jq -r "$2" "$TMP/dr/$1/run.json"; }
eq "bench dev-run plain: exit 0" 0 "$(drun p1 plain)"
L=$(cat "$TMP/dr/s-p1/log"); CWD=$(printf '%s\n' "$L" | sed -n 's/^cwd //p'); W=${CWD%/repo}
eq "bench dev-run plain: run.json" "plain dev-unwired 0 null 1 null" "$(rj p1 '"\(.arm) \(.case) \(.user_replies) \(.aborted) \(.calls) \(.plugin_rev)"')"
eq "bench dev-run plain: driver, work, transcripts copied; no harness files" 11100 "$(art "$TMP/dr/p1")"
eq "bench dev-run plain: claude runs in <work>/repo" "$W/repo" "$CWD"
eq "bench dev-run: work path names no case or benchmark" "" "$(printf '%s\n' "$CWD" | grep -iE "$FORBID")"
eq "bench dev-run: own config dir and home, rtk off" "env $W/cfg $W/home off" "$(printf '%s\n' "$L" | grep '^env ')"
eq "bench dev-run: work dir removed after the run" "" "$(ls -d "$W" 2>/dev/null)"
has "bench dev-run plain: prompt is task.md" "arg -p"$'\n'"arg $(cat "$CD/task.md")"$'\n' "$L"
ARGS=$(printf '%s\n' "$L" | sed -n 's/^arg //p' | tr '\n' ' ')
has "bench dev-run: claude flags" "--model opus --output-format json --permission-mode bypassPermissions --disallowedTools AskUserQuestion --max-budget-usd 15.00 --setting-sources project --strict-mcp-config " "$ARGS"
lacks "bench dev-run plain: no plugin" "--plugin-dir" "$ARGS"
lacks "bench dev-run: first call does not resume" "--resume" "$ARGS"
has "bench dev-run: map.tsv line" "p1	dev-unwired	plain" "$(cat "$TMP/dr/map.tsv")"
eq "bench dev-run: non-empty out-dir refused" 2 "$(drun p1 plain)"
mkdir -p "$TMP/dr/bench-t"
eq "bench dev-run: a work path naming the benchmark is refused" 2 "$(drun x1 plain TMPDIR="$TMP/dr/bench-t")"
eq "bench dev-run harness: exit 0" 0 "$(drun h1 harness)"
L=$(cat "$TMP/dr/s-h1/log"); PL=" $(printf '%s\n' "$L" | sed -n 's/^plugin //p')"
has "bench dev-run harness: prompt runs the skill" "arg /review-harness:review-harness $(head -c 20 "$CD/task.md")" "$L"
CWD=$(printf '%s\n' "$L" | sed -n 's/^cwd //p')
has "bench dev-run harness: --plugin-dir is the plugin copy" "arg --plugin-dir"$'\n'"arg ${CWD%/repo}/plugin" "$L"
for f in hooks .claude-plugin; do has "bench dev-run harness: plugin copy has $f" " $f " "$PL"; done
for f in bench tests README.md CHANGELOG.md; do lacks "bench dev-run harness: plugin copy has no $f" " $f " "$PL"; done
has "bench dev-run harness: register-declined pre-created" "declined 1" "$L"
eq "bench dev-run harness: plugin_rev" "$(git -C "$ROOT" rev-parse --short HEAD)" "$(rj h1 .plugin_rev)"
eq "bench dev-run harness: runs.jsonl and plan.md copied" 11111 "$(art "$TMP/dr/h1")"
eq "bench dev-run: '?' → one reply" "2 1 null" "$(drun a1 plain STUB_ASK=1 >/dev/null; rj a1 '"\(.calls) \(.user_replies) \(.aborted)"')"
L=$(cat "$TMP/dr/s-a1/log")
has "bench dev-run: the reply resumes the session" "arg --resume"$'\n'"arg sess-1" "$(printf '%s\n' "$L" | sed -n '/^call 2$/,$p')"
has "bench dev-run: first reply approves" "arg -p"$'\n'"arg Approved. Go ahead." "$L"
eq "bench dev-run: replies stop at 4" "5 4" "$(drun a2 plain STUB_ASK=9 >/dev/null; rj a2 '"\(.calls) \(.user_replies)"')"
has "bench dev-run: later replies say no more answers" "arg I can't answer more questions" "$(cat "$TMP/dr/s-a2/log")"
eq "bench dev-run: cost cap" '2 "cost"' "$(drun c1 plain STUB_ASK=9 STUB_COST=6 DEV_BENCH_BUDGET_USD=10 >/dev/null; rj c1 '"\(.calls) \(.aborted | tojson)"')"
has "bench dev-run: budget left goes to the next call" "arg --max-budget-usd"$'\n'"arg 4.00" "$(cat "$TMP/dr/s-c1/log")"
eq "bench dev-run: time cap kills the call" '1 "time" true' \
  "$(drun t1 plain STUB_SLEEP=5 DEV_BENCH_TIME_S=1 >/dev/null; rj t1 '"\(.calls) \(.aborted | tojson) \(.wall_s < 5)"')"
drun b1 plain DEV_BENCH_BARE=1 >/dev/null; ARGS=$(sed -n 's/^arg //p' "$TMP/dr/s-b1/log" | tr '\n' ' ')
has "bench dev-run: DEV_BENCH_BARE=1 → --bare" "--bare" "$ARGS"
lacks "bench dev-run: --bare replaces the config isolation" "--setting-sources" "$ARGS"
fi

# --- commit gate: other git forms and history-writing commands ----------------------------
R="$TMP/gate2"; new_repo "$R"; rs start small-change reviewer >/dev/null
for c in "/usr/bin/git commit -m x" "/opt/homebrew/bin/git commit" "git -C . commit -m x" "git -C \"/a b/c\" commit" \
  "git --git-dir .git commit" "git --git-dir=.git commit" "git --work-tree . commit" "git -c a=b -c 'c=d e' commit" \
  "git --no-pager commit" "git merge main" "git merge --ff-only main" "git merge --continue" "git cherry-pick abc" \
  "git revert HEAD" "git am x.patch" "git rebase --continue" "git status; git commit -m x" "git add . && /usr/bin/git commit" \
  "true || git merge x" "bash -c \"git commit -m x\"" "git commit -m \"--dry-run\"" "(cd sub && git commit)" "x=\$(git cherry-pick y)" \
  "git commit -m \"fix; merge --abort\"" "bash \"$H/rtk-wrap.sh\" git commit -m x" \
  "git commit -m \"fix --dry-run bug\"" "git commit -m 'a --dry-run'" "git commit -m --dry-run" "git commit --message --dry-run" \
  "git merge -m \"x --abort y\" main" "git am \"--abort.patch\"" "git status
git revert HEAD" \
  "git commit --trailer --dry-run -m x" "git commit --author --dry-run" "git commit -am --dry-run" "git commit -sm --dry-run" \
  "git commit -m x -- --dry-run" "git commit --dry-run --no-dry-run -m x" "git commit --dry-run --no-dr -m x" \
  "git merge --into-name --abort main" "git merge -X --abort main" "git merge --abort --no-abort main" \
  "git commit --mess --dry-run" "git commit --m --dry-run" "git commit --trail --dry-run -m x" "git merge --into --abort main" \
  "git merge --mess --abort main" "git am --dir --abort x.patch" "git commit --dry-run -m \"x\" --no-dry-run" \
  "git commit --dry-run \"--no-dry-run\" -m x" "git commit --dry-run -m x\$(date) --no-dry-run" \
  "git merge --abort \"\$B\" --no-abort" "X=--no-dry-run; git commit --dry-run \$X -m x" "git commit -m a\\ --dry-run" \
  "git commit --dry-run \\
--no-dry-run -m x" "git rebase \"--continue\"" "git rebase --cont\\inue" "git rebase \\
--continue" \
  "echo xgit commit --dry-run ;
git commit --dry-run \"--no-dry-run\" -m x" "git commit --dry-run 2>&1 --no-dry-run -m x" \
  "git commit --dry-run &>/dev/null --no-dry-run -m x" "git commit --dry-run >| o.txt --no-dry-run -m x" \
  "git merge --abort 2>&1 --no-abort main" "git rebase 2>&1 --continue" "git commit -m x > --dry-run" "git merge main 2> --abort" \
  "git commit -m x # --dry-run" "git merge main # --abort" "git cherry-pick abc # --skip" \
  "git commit --dry-run --no-dry-{run,run} -m x" "git rebase {--continue,}" "git commit --dry-run -F <(echo hi) --no-dry-run" \
  "git commit --dry-run --no-dry-ru[n] -m x" "git rebase;git commit -m x" \
  "git commit --dry-run -m5>x --no-dry-run" "git commit --dry-run -m 2&>x --no-dry-run" "git merge --abort -m5>x --no-abort main" \
  "git commit>x -m y" "git commit</dev/null -m y" "git merge>x main" "git rebase>x --continue" \
  "git commit -m x --end-of-options --dry-run" \
  "git merge -- --abort" "git cherry-pick -X --skip abc" "git revert --strategy --quit HEAD" "git am --directory --abort x.patch" \
  "git am -p --abort x.patch" "git rebase --cont" "git rebase --continu"; do
  eq "gate: $c → deny" deny "$(gate "$R" "$c")"
done
for c in "git log" "git log --grep=commit" "git log --oneline --merges" "git diff HEAD~1 -- a" "git show HEAD:commit.txt" \
  "git status" "git stash list" "git merge --abort" "git merge --quit" "git cherry-pick --abort" "git cherry-pick --skip" \
  "git revert --quit" "git am --abort" "git rebase --abort" "git rebase main" "git merge-base HEAD main" "git commit-tree abc" \
  "git branch --merged" "git config merge.ff false" "gitk commit" "legit commit" "git-lfs commit" \
  "git log && git merge --abort" "echo committed" "git commit --dry-run" "git commit -a --dry-run -m x" \
  "git am --show-current-patch" "git am --show-current-patch=diff" "git commit -m x --dry-run" \
  "git commit -s --dry-run" "git commit -mx --dry-run" "git commit --trailer a=b --dry-run" "git commit -am x --dry-run" \
  "git commit -v --dry-run --short" "git rebase -x make main" "git rebase --onto main topic" "git rebase --committer-date-is-author-date main" \
  "bash \"$H/rtk-wrap.sh\" git merge --abort" "(cd sub && git merge --abort)" "x=\$(git commit --dry-run)" \
  "git commit --dry-run 2>&1 | head" "git -C \"/a b\" commit --dry-run" "git commit --dry-run
git status" "git rebase; git status" "git commit -m x 2>&1 --dry-run" "git commit --dry-run >/dev/null 2>&1" \
  "git merge --abort; git status --short" "git cherry-pick --abort 2>/dev/null || true" "git rebase -i HEAD~3" \
  "git rebase main 2>&1 | tail -5" "git commit --dry-run -- src/a.ts" "git commit -m5>x --dry-run" "git rebase main>x"; do
  eq "gate: $c → allow" allow "$(gate "$R" "$c")"
done
rs abandon >/dev/null
# Without jq the gate cannot read the command or the run state: advice, never a silent pass or a deny.
mkdir -p "$TMP/nojqbin"; for t in bash cat grep sed dirname tr head; do ln -sf "$(command -v $t)" "$TMP/nojqbin/$t"; done
ngate() { printf '{"tool_input":{"command":"%s"},"cwd":"/"}' "$1" | PATH="$TMP/nojqbin" "$BASH" "$H/commit-gate.sh"; }
OUT=$(ngate "git commit -m x")
eq "gate: no jq, git commit → advice" advice "$(decision "$OUT")"
has "gate: no jq → says the gate is inactive" "inactive: jq is not installed" "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)"
eq "gate: no jq, git merge → advice" advice "$(decision "$(ngate "git merge main")")"
eq "gate: no jq, read-only git → silent" "" "$(ngate "git log")"

# --- verdict authorship -------------------------------------------------------------------
R="$TMP/actor"; new_repo "$R"; SD=$(bash "$H/state-dir.sh" "$R"); rs start feature reviewer >/dev/null
OUT=$(rs verdict FAIL --by reviewer scope)
eq "verdict: --by before a category → by" reviewer "$(jq -r '.verdicts[-1].by' "$SD/run-state.json")"
eq "verdict: --by is not a category" '["scope"]' "$(jq -c '.verdicts[-1].cats' "$SD/run-state.json")"
lacks "verdict: --by value is not warned as a category" "ignored: reviewer" "$OUT"
has "status: who recorded the review" "review: FAIL by reviewer" "$(rs status)"
rs verdict FAIL design --by reviewer >/dev/null
eq "verdict: --by last → by, categories kept" 'reviewer ["design"]' "$(jq -r '.verdicts[-1] | "\(.by) \(.cats | tostring)"' "$SD/run-state.json")"
OUT=$(rs verdict FAIL scope --by 'Bad Actor')
has "verdict: malformed --by → warning" "ignored --by" "$OUT"
eq "verdict: malformed --by → unknown" unknown "$(jq -r '.verdicts[-1].by' "$SD/run-state.json")"
has "verdict: --by without a value → warning" "ignored --by" "$(rs verdict FAIL --by)"
rs abandon >/dev/null; rs start feature reviewer >/dev/null
rs verdict FAIL --by reviewer scope >/dev/null
rs verdict PASS >/dev/null
eq "verdict: no --by → by unknown" unknown "$(jq -r '.verdicts[-1].by' "$SD/run-state.json")"
has "status: an unknown author is shown" "review: PASS(current) by unknown" "$(rs status)"
eq "verdict: an unknown author does not block" 0 "$( (cd "$R" && bash "$H/run-state.sh" check >/dev/null 2>&1); echo $?)"
rs done >/dev/null
eq "run log: verdict authors" "reviewer unknown" "$(tail -n 1 "$REVIEW_HARNESS_HOME/state/runs.jsonl" | jq -r '[.verdicts[].by] | join(" ")')"
for f in "$ROOT/agents/reviewer.md" "$ROOT/skills/review-harness/SKILL.md" "$ROOT/skills/code-review/SKILL.md"; do
  has "$(basename "$(dirname "$f")")/$(basename "$f"): reviewer verdict command sets the actor" \
    ' --by reviewer`' "$(grep 'run-state.sh" verdict' "$f")"
done

# --- org verdict categories ---------------------------------------------------------------
mkdir -p "$TMP/cathome/org"; printf 'qa-docs\nBad Word\n../x\n' > "$TMP/cathome/org/categories.txt"
R="$TMP/orgcat"; new_repo "$R"
OUT=$(cd "$R" && REVIEW_HARNESS_HOME="$TMP/cathome" bash "$H/run-state.sh" verdict FAIL qa-docs bogus bad 2>&1)
lacks "verdict: org category accepted" "ignored: qa-docs" "$OUT"
has "verdict: unknown category still warns" "unknown category ignored: bogus" "$OUT"
has "verdict: malformed org line is no category" "unknown category ignored: bad" "$OUT"
eq "verdict: org category stored" '["qa-docs"]' \
  "$(jq -c '.verdicts[-1].cats' "$(REVIEW_HARNESS_HOME="$TMP/cathome" bash "$H/state-dir.sh" "$R")/run-state.json")"
has "verdict: without the org file the word is unknown" "unknown category ignored: qa-docs" "$(rs verdict FAIL qa-docs)"

# --- hashing without shasum ---------------------------------------------------------------
mkdir -p "$TMP/nosha"
for t in bash cat grep sed awk dirname basename tr head cut date mkdir rm jq paste ls wc cksum sort find; do
  ln -sf "$(command -v $t)" "$TMP/nosha/$t"
done
P2="$TMP/proj-nosha"; mkdir -p "$P2"; echo '{}' > "$P2/package.json"
nedit() { decision "$(jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}' | PATH="$TMP/nosha" "$BASH" "$H/pre-tool-use.sh")"; }
eq "pre-tool-use: no shasum/sha1sum, not approved → deny" deny "$(nedit "$P2/package.json")"
PATH="$TMP/nosha" "$BASH" "$H/pre-tool-use.sh" --approve "$P2/package.json" >/dev/null 2>&1
eq "pre-tool-use: no shasum/sha1sum, approved → allow" allow "$(nedit "$P2/package.json")"
eq "pre-tool-use: no shasum/sha1sum, approval is per file" deny "$(nedit "$P2/tsconfig.json")"
npt() { jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}' | PATH="$TMP/nosha" "$BASH" "$H/post-tool-use.sh" 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }
has "post-tool-use: no shasum/sha1sum → first file checked" "END-MARK" "$(npt "$TMP/nogit/sub/n1.py")"
has "post-tool-use: no shasum/sha1sum → another file is not debounced with it" "END-MARK" "$(npt "$TMP/nogit/sub/n2.py")"

# --- several registry files ---------------------------------------------------------------
MH="$TMP/multihome"; mkdir -p "$MH/knowledge/a-org" "$MH/knowledge/b-org" "$TMP/multi-a" "$TMP/multi-b/src" "$TMP/multi-c" "$TMP/multi-d"
printf '### alpha\n- **local_path**: `%s`\n- **role**: in a\n\n### dup\n- **local_path**: `%s`\n- **role**: dup in a\n' "$TMP/multi-a" "$TMP/multi-d" > "$MH/knowledge/a-org/repos.md"
printf '### alpha\n- **local_path**: `%s`\n- **role**: alpha in b\n- **test_cmd**: `make b`\n\n### dup\n- **local_path**: `%s`\n- **role**: dup in b\n' \
  "$TMP/multi-b" "$TMP/multi-d" > "$MH/knowledge/b-org/repos.md"
printf '### gamma\n- **local_path**: `%s`\n' "$TMP/multi-c" > "$MH/knowledge/repos.md"
dr() { REVIEW_HARNESS_HOME="$MH" bash "$H/detect-repo.sh" "$1"; }
OUT=$(dr "$TMP/multi-b/src")
has "detect-repo: the second registry file is read" "- role: alpha in b" "$OUT"
lacks "detect-repo: the block comes from the file that matched" "- role: in a" "$OUT"
has "detect-repo: the first registry file is read" "- role: in a" "$(dr "$TMP/multi-a")"
eq "detect-repo: a path in two files → the first file in sorted order" "- role: dup in a" "$(dr "$TMP/multi-d" | grep role)"
has "detect-repo: the flat registry is read last" "- name: gamma" "$(dr "$TMP/multi-c")"
eq "detect-test-cmd: registry test_cmd from the second file" "make b" "$(REVIEW_HARNESS_HOME="$MH" dt "$TMP/multi-b")"
HINT=$(dr "$TMP" | sed -n 's/^- hint: register the repo in //p')
eq "detect-repo: unmatched hint names the first registry file" "$MH/knowledge/a-org/repos.md" "$HINT"
eq "register-repo: target = the file the hint names" "$HINT" "$(target "$MH")"
echo 'userName' > "$TMP/multi-b/src/x.ts"; echo 'userName' > "$TMP/multi-c/y.ts"
OUT=$(cd "$TMP/multi-a" && REVIEW_HARNESS_HOME="$MH" bash "$H/find-consumers.sh" userName 2>&1)
has "find-consumers: repos of every registry file" "alpha: src/x.ts:1: userName" "$OUT"
has "find-consumers: the flat registry too" "gamma: y.ts:1: userName" "$OUT"
eq "find-consumers: a path in two files is searched once" 1 "$(printf '%s\n' "$OUT" | grep -c '^dup: ')"

# --- rtk-wrap -----------------------------------------------------------------------------
FB="$TMP/fakertk"; mkdir -p "$FB"
cat > "$FB/rtk" <<'EOF'
#!/bin/bash
# Like rtk 0.40: drops a `--` right after the subcommand, and knows only --ultra-compact.
[ "$1" = --version ] && { echo "rtk 0.40.0"; exit 0; }
echo "RTK-RAN $1"; [ "$1" = --ultra-compact ] && shift
c=$1; s=$2; shift 2; [ "${1:-}" = -- ] && shift
exec "$c" "$s" "$@"
EOF
chmod +x "$FB/rtk"
R="$TMP/rtkrepo"; new_repo "$R"; echo x > "$R/gone.txt"; git -C "$R" add gone.txt; rm "$R/gone.txt"
rw() { (cd "$R" && PATH="$FB:$PATH" REVIEW_HARNESS_RTK="$1" bash "$H/rtk-wrap.sh" "${@:2}" 2>&1); }
OUT=$(rw standard git diff -- gone.txt)
has "rtk-wrap: '--' passed through unchanged" "deleted file mode" "$OUT"
lacks "rtk-wrap: '--' runs raw" "RTK-RAN" "$OUT"
has "rtk-wrap: no '--' → still through rtk" "RTK-RAN" "$(rw standard git status --short)"
eq "rtk-wrap: aggressive → --ultra-compact" "RTK-RAN --ultra-compact" "$(rw aggressive git status --short | head -n 1)"
# Default with no env and no flag: standard when an rtk binary is on PATH, else off. NORTK = PATH without any rtk.
NORTK=$(printf '%s\n' "$PATH" | tr ':' '\n' | while read -r d; do [ -n "$d" ] && [ ! -x "$d/rtk" ] && printf '%s:' "$d"; done)
NORTK=${NORTK%:}
rwm() { (cd "$R" && PATH="$1" bash "$H/rtk-wrap.sh" --mode 2>&1); }
eq "rtk-wrap: no env, no flag, rtk installed → standard" standard "$(rwm "$FB:$NORTK")"
eq "rtk-wrap: no env, no flag, no rtk → off" off "$(rwm "$NORTK")"
has "rtk-wrap: default standard routes through rtk" "RTK-RAN" "$(cd "$R" && PATH="$FB:$NORTK" bash "$H/rtk-wrap.sh" git status --short 2>&1)"
lacks "rtk-wrap: default off runs raw" "RTK-RAN" "$(cd "$R" && PATH="$NORTK" bash "$H/rtk-wrap.sh" git status --short 2>&1)"
eq "rtk-wrap: env beats the default" git-only "$(cd "$R" && PATH="$FB:$NORTK" REVIEW_HARNESS_RTK=git-only bash "$H/rtk-wrap.sh" --mode)"
(cd "$R" && bash "$H/rtk-wrap.sh" --set off)
eq "rtk-wrap: session flag beats the default" off "$(rwm "$FB:$NORTK")"
(cd "$R" && bash "$H/rtk-wrap.sh" --clear)
eq "rtk-wrap: --clear returns to the default" standard "$(rwm "$FB:$NORTK")"
FO="$TMP/otherrtk"; mkdir -p "$FO"; printf '#!/bin/sh\necho "Rust Type Kit 2.1"\n' > "$FO/rtk"; chmod +x "$FO/rtk"
eq "rtk-wrap: another tool named rtk → default off" off "$(rwm "$FO:$NORTK")"
# git diff / git show run raw in every mode: rtk 0.40 cuts them to ~500 lines (100 per hunk), and the reviewer reads them.
FM="$TMP/manglertk"; mkdir -p "$FM"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "rtk 0.40.0"; exit 0; }\necho MANGLED\n' > "$FM/rtk"; chmod +x "$FM/rtk"
git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t.t commit -qm two; echo c >> "$R/f.txt"
for m in standard aggressive git-only; do
  for c in "diff" "show --stat HEAD" "-C . diff HEAD"; do
    lacks "rtk-wrap: $m git $c runs raw" MANGLED "$(cd "$R" && PATH="$FM:$NORTK" REVIEW_HARNESS_RTK=$m bash "$H/rtk-wrap.sh" git $c 2>&1)"
  done
done
has "rtk-wrap: raw git diff output intact" "+c" "$(cd "$R" && PATH="$FM:$NORTK" bash "$H/rtk-wrap.sh" git diff 2>&1)"
has "rtk-wrap: git status still through rtk" MANGLED "$(cd "$R" && PATH="$FM:$NORTK" bash "$H/rtk-wrap.sh" git status 2>&1)"

# --- static-gates -------------------------------------------------------------------------
# Fixture lines that would trip the gates are split in this file (TO''DO, `%s` for `||`), so the script run on this
# repo's own diff stays quiet.
sg() { (cd "$R" && bash "$H/static-gates.sh" "$@" 2>&1); }
sgx() { (cd "$R" && bash "$H/static-gates.sh" "$@" >/dev/null 2>&1); echo $?; }
cm() { git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t.t commit -qm "$1"; }
R="$TMP/sg"; new_repo "$R"
eq "static-gates: a plain text edit → no output" "" "$(sg)"
eq "static-gates: no hit → exit 0" 0 "$(sgx)"
mkdir -p "$R/src/__tests__" "$R/tests" "$R/test" "$R/config" "$R/sp ace"
printf 'console.log("old")\nconst a = 1\n' > "$R/src/a.ts"
printf 'x\n' > "$R/sp ace/f s.ts"
printf 'console.log(1)\n' > "$R/src/gone.ts"
printf 'console.log("kept")\n' > "$R/src/kept.ts"
printf 'a\nb\nc\nd\ne\n' > "$R/src/ctx.ts"
printf 'K=1\n' > "$R/.env.prod"
printf '\000console.log(\n' > "$R/tracked.bin.js"
git -C "$R" config diff.interHunkContext 10
cm base; SGBASE=$(git -C "$R" rev-parse HEAD)
printf 'console.log("late")\n' > "$R/src/late.ts"; cm late
# the change: staged, unstaged, untracked and deleted files
printf 'const a = 1\nconst b = 2\nconsole.log(b)\n' > "$R/src/a.ts"
rm "$R/src/gone.ts" "$R/.env.prod"
printf 'console.log(2)\n' >> "$R/sp ace/f s.ts"
printf 'console.log(3)\n' > "$R/sp ace/new one.ts"
for f in src/__tests__/t.ts src/b.test.ts src/b.spec.tsx tests/x.js test/y.js notes.md; do printf 'console.log(4)\n' > "$R/$f"; done
printf '\000console.log(\n' > "$R/bin.js"; printf '\001\000console.log(5)\n' >> "$R/tracked.bin.js"
: > "$R/.env.local"; : > "$R/config/.env"; : > "$R/.env.example"; : > "$R/.env.sample"; : > "$R/.env.template"
: > "$R/.env.test.development.example"
OR='||'; NN='??'
printf 'const k = process.env.API_KEY %s "sk-1"\nconst e = process.env.EMPTY %s %s\nconst t = process.env.TOKEN %s %s\n' \
  "$OR" "$OR" "''" "$NN" "'abc'" > "$R/src/c.ts"
printf 'const n = process.env.NODE_ENV %s %s\nconst m = process.env.apiKey %s %s\n' "$OR" "'local'" "$OR" "'x'" >> "$R/src/c.ts"
printf 'const a = process.env.NODE_ENV %s %s, b = process.env.API_KEY %s %s\n' "$OR" "'a'" "$NN" "'b'" >> "$R/src/c.ts"   # :6
SG_NOTES='HOTKEY_LAYOUT KEYBOARD_MODE MONKEY KEYCLOAK_URL TOKENIZER'; SG_HARDS='JWT_SECRET GITHUB_TOKEN PRIVATE_KEY SENDGRID_APIKEY APIKEY API_KEYS TOKENS AUTH_TOKENS JWT_SECRETS PASSWORDS X_API_KEY2'
for v in $SG_NOTES $SG_HARDS; do   # :7 …
  printf 'const v = process.env.%s %s %s\n' "$v" "$OR" "'v'" >> "$R/src/c.ts"
done
printf 'Flag `process.env.X %s %s`\n' "$OR" "'<value>'" > "$R/doc.md"
printf 'A\nb\nc\nd\nconsole.log(e)\n' > "$R/src/ctx.ts"
printf 'x\n' > "$R/-"
mkdir -p "$R/nested"; git -C "$R/nested" init -q; printf 'console.log(9)\n' > "$R/nested/n.ts"
git -C "$R" add src/c.ts
printf '// %s later\nconst %s = 1\n' 'TO''DO' 'TO''DOS' > "$R/src/d.ts"
printf 'export function lonelyFn() {}\nexport const usedThing = 1\nexport default function Page() {}\nexport class Tested {}\nexport async function asyncLone() {}\n' > "$R/src/e.ts"
printf "import { usedThing } from './e'\n" > "$R/src/use.ts"
printf 'new Tested()\n' > "$R/src/e.test.ts"
printf 'let i = 0\n++i; console.log(i)\n' > "$R/src/plus.ts"
ST0=$(git -C "$R" status --porcelain); IX0=$(cksum < "$R/.git/index")
OUT=$(sg); RC=$(sgx)
eq "static-gates: real index untouched" "$IX0" "$(cksum < "$R/.git/index")"
eq "static-gates: git status unchanged" "$ST0" "$(git -C "$R" status --porcelain)"
eq "static-gates: hard hit → exit 1" 1 "$RC"
has "static-gates: console.log on its new line number" "hard [ops] src/a.ts:3 — no console.log in production code" "$OUT"
eq "static-gates: removed line not reported (one hit in src/a.ts, on its new line)" \
  "hard [ops] src/a.ts:3 — no console.log in production code" "$(printf '%s\n' "$OUT" | grep ' src/a.ts:')"
lacks "static-gates: unchanged file not reported" "kept.ts" "$OUT"
has "static-gates: context lines from diff.interHunkContext count" "hard [ops] src/ctx.ts:5 — no console.log" "$OUT"
has "static-gates: a file named - does not swallow the untracked files after it" "hard [ops] src/plus.ts:2" "$OUT"
lacks "static-gates: a nested repo is skipped" "nested" "$OUT"
lacks "static-gates: deleted file not reported" "gone.ts" "$OUT"
lacks "static-gates: deleted .env not reported" ".env.prod" "$OUT"
has "static-gates: tracked path with spaces" "hard [ops] sp ace/f s.ts:2 — no console.log" "$OUT"
has "static-gates: untracked path with spaces" "hard [ops] sp ace/new one.ts:1 — no console.log" "$OUT"
for f in src/__tests__/t.ts src/b.test.ts src/b.spec.tsx tests/x.js test/y.js notes.md bin.js tracked.bin.js; do
  lacks "static-gates: no console.log hit in $f" "$f:" "$OUT"
done
has "static-gates: an added line starting with ++ is still an added line" "hard [ops] src/plus.ts:2 — no console.log" "$OUT"
has "static-gates: untracked .env.local" "hard [security] .env.local:1 — .env file in the change" "$OUT"
has "static-gates: .env by basename" "hard [security] config/.env:1 — .env file in the change" "$OUT"
for f in .env.example .env.sample .env.template .env.test.development.example; do lacks "static-gates: $f passes" "$f" "$OUT"; done
has "static-gates: || fallback literal (staged)" "hard [security] src/c.ts:1 — secret fallback literal" "$OUT"
lacks "static-gates: empty fallback passes" "src/c.ts:2 " "$OUT"
has "static-gates: ?? fallback literal" "hard [security] src/c.ts:3 — secret fallback literal" "$OUT"
has "static-gates: a non-secret name is a note" "note [security] src/c.ts:4 — literal fallback for an env var" "$OUT"
has "static-gates: camelCase secret name (apiKey)" "hard [security] src/c.ts:5 — secret fallback literal" "$OUT"
has "static-gates: every fallback on a line is classified, not only the first" "hard [security] src/c.ts:6 — secret fallback literal" "$OUT"
eq "static-gates: one hit per fallback line" 1 "$(printf '%s\n' "$OUT" | grep -c ' src/c.ts:6 ')"
L=7; for v in $SG_NOTES; do
  has "static-gates: $v is a note (KEY only as a whole segment)" "note [security] src/c.ts:$L — literal fallback for an env var" "$OUT"; L=$((L + 1))
done
for v in $SG_HARDS; do
  has "static-gates: $v is hard" "hard [security] src/c.ts:$L — secret fallback literal" "$OUT"; L=$((L + 1))
done
has "static-gates: header names the git version" 'git ≥ 2.25' "$(sed -n '2,20p' "$H/static-gates.sh")"
has "static-gates: a doc quoting the rule is a note" "note [security] doc.md:1 — literal fallback" "$OUT"
lacks "static-gates: a doc quoting the rule is not hard" "hard [security] doc.md" "$OUT"
has "static-gates: TO""DO note" "note [goal] src/d.ts:1 — " "$OUT"
lacks "static-gates: TO""DO is matched as a whole word" "src/d.ts:2 " "$OUT"
has "static-gates: export with no caller" "note [goal] src/e.ts:1 — new export with no caller: lonelyFn" "$OUT"
lacks "static-gates: export used in another file" "usedThing" "$OUT"
has "static-gates: export default function" "note [goal] src/e.ts:3 — new export with no caller: Page" "$OUT"
lacks "static-gates: a test file is a caller" "Tested" "$OUT"
has "static-gates: export async function" "note [goal] src/e.ts:5 — new export with no caller: asyncLone" "$OUT"
lacks "static-gates: commits before the base are not reported without a base" "late.ts" "$OUT"
eq "static-gates: every line is a hit line" 0 \
  "$(printf '%s\n' "$OUT" | grep -cvE '^(hard|note) \[[a-z]+\] .+:[0-9]+ — ')"
eq "static-gates: same output from a subdirectory" "$OUT" "$(cd "$R/src" && bash "$H/static-gates.sh" 2>&1)"
OUTB=$(sg "$SGBASE")
has "static-gates: base → commits since the base" "hard [ops] src/late.ts:1 — no console.log" "$OUTB"
has "static-gates: base → plus the working tree" "hard [ops] src/a.ts:3 — no console.log" "$OUTB"
has "static-gates: base → plus untracked" "hard [security] .env.local:1" "$OUTB"
lacks "static-gates: base → nothing before the base" "kept.ts" "$OUTB"
R="$TMP/sg-notes"; new_repo "$R"; printf 'const %s = 1\n' 'TO''DO' > "$R/notes-only.ts"
OUT=$(sg)
has "static-gates: notes only → still reported" "note [goal] notes-only.ts:1" "$OUT"
eq "static-gates: notes only → exit 0" 0 "$(sgx)"
eq "static-gates: two arguments → exit 2" 2 "$(sgx a b)"
eq "static-gates: unknown base → exit 2" 2 "$(sgx no-such-ref)"
eq "static-gates: option-like base → exit 2" 2 "$(sgx --help)"
mkdir -p "$TMP/sg-nogit"; eq "static-gates: outside a git repo → exit 2" 2 "$(cd "$TMP/sg-nogit" && GIT_CEILING_DIRECTORIES="$TMP" bash "$H/static-gates.sh" >/dev/null 2>&1; echo $?)"
R="$TMP/sg-nonutf"; new_repo "$R"; printf 'const s = "\377"\nconsole.log(1)\n' > "$R/n.ts"
OUT=$(cd "$R" && LC_ALL=C.UTF-8 bash "$H/static-gates.sh" 2>&1); RC=$?
has "static-gates: a non-UTF-8 byte does not end the parse" "hard [ops] n.ts:2 — no console.log" "$OUT"
eq "static-gates: a non-UTF-8 byte → still exit 1" 1 "$RC"
R="$TMP/sg-clean"; new_repo "$R"; cm clean
eq "static-gates: success → nothing on stderr (git's add -N chatter is kept back)" "" "$(cd "$R" && bash "$H/static-gates.sh" 2>&1 >/dev/null)"
eq "static-gates: clean tree, nothing untracked → exit 0, no output" "0:" "$(sgx):$(sg)"
# An internal git failure is exit 2 with one stderr line, never a silent clean 0.
printf 'console.log(1)\n' > "$R/u.ts"
mkdir -p "$TMP/sg-gitfail"; REALGIT=$(command -v git)
printf '#!/bin/sh\ncase " $* " in *" add -N "*) exit 128 ;; esac\nexec "%s" "$@"\n' "$REALGIT" > "$TMP/sg-gitfail/git"; chmod +x "$TMP/sg-gitfail/git"
OUT=$(cd "$R" && PATH="$TMP/sg-gitfail:$PATH" bash "$H/static-gates.sh" 2>&1 >/dev/null); RC=$?
eq "static-gates: git add -N fails → exit 2" 2 "$RC"
eq "static-gates: git add -N fails → last stderr line names the command" "static-gates: git add -N failed (see the git error above)" "$(printf '%s\n' "$OUT" | tail -n 1)"
chmod 000 "$R/u.ts"
if [ -r "$R/u.ts" ]; then PASS=$((PASS + 3))   # root reads it anyway: nothing to test
else
  OUT=$(cd "$R" && bash "$H/static-gates.sh" 2>&1 >/dev/null); RC=$?
  eq "static-gates: unreadable untracked file → exit 2" 2 "$RC"
  has "static-gates: unreadable untracked file → git's own error shown" "Permission denied" "$OUT"
  eq "static-gates: unreadable untracked file → last line names the command" "static-gates: git diff failed (see the git error above)" "$(printf '%s\n' "$OUT" | tail -n 1)"
fi
chmod 644 "$R/u.ts"
R="$TMP/sg-sparse"; mkdir -p "$R/in" "$R/out"; git -C "$R" init -q; echo a > "$R/in/a.txt"; echo b > "$R/out/b.txt"; cm init
git -C "$R" sparse-checkout set --cone in
mkdir -p "$R/out"; printf 'x\n' > "$R/out/new.txt"; printf 'console.log(1)\n' > "$R/in/x.ts"
OUT=$(sg); RC=$(sgx)
eq "static-gates: sparse checkout, untracked file outside the cone → no exit 2" 1 "$RC"
has "static-gates: sparse checkout → in-cone hard hit reported" "hard [ops] in/x.ts:1 — no console.log" "$OUT"
eq "static-gates: umask 077 for its temp files" 1 "$(grep -c '^umask 077' "$H/static-gates.sh")"
for f in README.md profiles/web-frontend.md; do lacks "$f: no 'each changed UI file'" "each changed UI file" "$(cat "$ROOT/$f")"; done
R="$TMP/sg-nohead"; mkdir -p "$R"; git -C "$R" init -q
printf 'console.log(1)\n' > "$R/staged.ts"; git -C "$R" add staged.ts
printf 'x\nconsole.log(2)\n' > "$R/loose file.ts"
OUT=$(sg)
has "static-gates: no HEAD → tracked file counts as added" "hard [ops] staged.ts:1 — no console.log" "$OUT"
has "static-gates: no HEAD → untracked file counts as added" "hard [ops] loose file.ts:2 — no console.log" "$OUT"
eq "static-gates: no HEAD → exit 1" 1 "$(sgx)"
eq "static-gates: no HEAD with a base → exit 2" 2 "$(sgx main)"
lacks "static-gates: never runs npx" "npx" "$(grep -v '^#' "$H/static-gates.sh")"
has "developer: self-check runs static-gates.sh" 'run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/static-gates.sh"`' "$(cat "$ROOT/agents/developer.md")"
has "reviewer: static gates run the script first" '`bash "${CLAUDE_PLUGIN_ROOT}/hooks/static-gates.sh"`' "$(sed -n '/^## Static Review Gates/,/^## Constraints/p' "$ROOT/agents/reviewer.md")"
has "reviewer: note hits are never an automatic FAIL" '`note` hits feed the Goal gate' "$(cat "$ROOT/agents/reviewer.md")"
has "docs/hooks.md: static-gates row" '| **`static-gates.sh`** |' "$(cat "$ROOT/docs/hooks.md")"
has "docs/hooks.md: torn line skipped and the next append can be lost" \
  'a torn line is skipped, and a writer killed mid-line can also lose the next append' "$(cat "$ROOT/docs/hooks.md")"
has "readme: static-gates example" 'bash hooks/static-gates.sh' "$(cat "$ROOT/README.md")"

# --- risk-tier ----------------------------------------------------------------------------
rt() { (cd "$R" && bash "$H/risk-tier.sh" "$@" 2>&1); }
rtx() { (cd "$R" && bash "$H/risk-tier.sh" "$@" >/dev/null 2>&1); echo $?; }
RTN=0
rtrepo() { R="$TMP/rt-$RTN"; RTN=$((RTN + 1)); new_repo "$R"; git -C "$R" checkout -q -- f.txt; }
# rtin <name> <tier> <path> [line...] — a fresh repo whose only change is the untracked <path> holding the lines
rtin() {
  local n=$1 t=$2 p=$3; shift 3; [ $# -eq 0 ] && set -- x
  rtrepo; mkdir -p "$R/$(dirname "$p")"; printf '%s\n' "$@" > "$R/$p"
  eq "risk-tier: $n → $t" "$t" "$(rt | head -n 1)"
}
lines() { i=0; while [ "$i" -lt "$1" ]; do echo "line $i"; i=$((i + 1)); done; }
rtin "a one-line file" low src/plain.ts 'const a = 1'
rtin "auth path segment" high src/auth/index.ts
rtin "camelCase auth path" high src/AuthService.ts
rtin "upper-case session path" high src/SESSION/store.ts
rtin "tokenizer path is not auth" low src/tokenizer.ts
rtin "author path is not auth" low src/author.ts
rtin "token on an added line" high src/a.ts 'const t = getToken()'
rtin "SNAKE_CASE token" high src/a.ts 'const k = env.API_TOKEN'
rtin "tokenizer on an added line is not auth" low src/a.ts 'const tokenizer = 1'
for w in session permissions roles ACLs rbac authorization oauth OAuth2 password passwd JWT login logout credentials; do
  rtin "$w on an added line" high src/a.ts "use $w here"
done
rtin "an ARIA role attribute is not auth" low src/a.tsx '<div role="dialog" />'
rtin "getByRole( is not auth" low src/a.test.tsx 'screen.getByRole("button")'
rtin "a role check is auth" high src/a.ts 'if (user.role !== "admin") deny()'
rtin "a role guard path is auth" high src/guards/role.guard.ts
rtin "payment path" high src/payment/api.ts
for w in billing invoice stripe refunds; do rtin "$w on an added line" high src/a.ts "go($w)"; done
rtin "sparse-checkout is not a payment term" low src/a.sh 'git sparse-checkout set src'
rtin "git checkout is not a payment term" low src/a.sh 'git checkout main'
rtin "actions/checkout is not a payment term" low src/ci.yml '- uses: actions/checkout@v4'
rtin "an actions/checkout.ts path is payment" high app/actions/checkout.ts
rtin "an import from @/actions/checkout is payment" high src/a.ts 'import { go } from "@/actions/checkout"'
rtin "a checkout path is payment" high src/checkout/CheckoutPage.tsx
rtin "a checkout call is payment" high src/a.ts 'submitCheckout(cart)'
rtin "migrations/ path" high db/migrations/001.js
rtin "migration/ path" high db/Migration/001.js
rtin "*.sql path, any case" high db/Schema.SQL
for w in lock mutex Semaphore workers queue concurrency; do rtin "$w on an added line" high src/a.ts "a $w b"; done
for w in clock blocking; do rtin "$w is not a concurrency word" low src/a.ts "a $w b"; done
rtin "parser path" high src/parser.ts
rtin "deserialize on an added line" high src/a.ts 'deserializeUser(x)'
rtin "parseInt is not a parser term" low src/a.ts 'parseInt(x)'
rtin "root hooks/ path" high hooks/pre-commit
rtin "a nested hooks/ folder is not the hooks dir" low src/hooks/useThing.ts
rtin ".github/workflows/ path" high .github/workflows/ci.yml
rtin "*gate* name" high scripts/commit-gate.sh
rtin "Gates in camelCase name" high src/ReviewGates.ts
for f in src/navigate.ts src/aggregate.ts; do rtin "$f is not a gate" low "$f"; done
RTW='Rotate the token, take the lock, end the session.'
rtin "high words on added doc lines do not count (.md)" low README.md "$RTW"
for f in notes.txt guide.rst page.mdx; do rtin "high words on added doc lines do not count ($f)" low "$f" "$RTW"; done
rtin "the same words in a code file → high" high src/a.ts "$RTW"
rtin "a doc path still counts" high docs/auth.md
rtin "a non-doc file under docs/ is word-scanned" high docs/plain.yml "$RTW"
rtin "code under a docs/ folder is word-scanned" high app/docs/page.tsx 'const t = getToken()'
rtin "CMakeLists.txt is not a doc" high CMakeLists.txt 'find_package(mutex)'
rtrepo; mkdir -p "$R/docs/img"; for n in 1 2 3; do printf 'p\n' > "$R/docs/img/$n.svg"; done; printf 'text\n' > "$R/docs/guide.md"
eq "risk-tier: images under docs/ plus a doc → low (docs only)" low "$(rt | head -n 1)"
rtrepo; mkdir -p "$R/app/docs"; lines 60 > "$R/app/docs/page.tsx"
eq "risk-tier: plain code under docs/ is not docs-only → normal" normal "$(rt)"
rtrepo; printf 'requests==2.0\n' > "$R/requirements.txt"; OUT=$(rt)
eq "risk-tier: requirements.txt → normal (not docs-only)" normal "$(printf '%s\n' "$OUT" | head -n 1)"
has "risk-tier: requirements.txt → dependency reason" "reason: dependency change" "$OUT"
# lockfiles: never a lock/word hit, but a dependency change is at least normal
for f in package-lock.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb Cargo.lock poetry.lock Gemfile.lock composer.lock go.sum sub/yarn.lock Pipfile.lock uv.lock any.lock constraints.txt; do
  rtin "lockfile $f with high words → normal" normal "$f" 'proper-lockfile worker token mutex'
done
rtrepo; printf '{"version": "1.0.1"}\n' > "$R/package.json"; printf 'lock\n' > "$R/package-lock.json"; OUT=$(rt)
eq "risk-tier: manifest + lockfile bump → normal" normal "$(printf '%s\n' "$OUT" | head -n 1)"
has "risk-tier: dependency change → reason" "reason: dependency change" "$OUT"
lacks "risk-tier: lockfile → no concurrency reason" "concurrency" "$OUT"
rtin "a non-lockfile lock name still counts" high src/lock.ts
rtrepo; mkdir -p "$R/src"; printf 'x\n' > "$R/src/auth.ts"; printf 'x\n' > "$R/yarn.lock"; OUT=$(rt)
eq "risk-tier: lockfile plus a high path → high" high "$(printf '%s\n' "$OUT" | head -n 1)"
has "risk-tier: high keeps the dependency reason" "reason: dependency change" "$OUT"
# multi-file changes
rtrepo; mkdir -p "$R/docs/deep"; lines 40 > "$R/README.md"; lines 40 > "$R/docs/deep/guide.txt"; lines 40 > "$R/notes.MD"
OUT=$(rt)
eq "risk-tier: docs only → low" low "$(printf '%s\n' "$OUT" | head -n 1)"
has "risk-tier: docs only → reason" "reason: docs or tests only" "$OUT"
lacks "risk-tier: docs only, 120 lines → no small-change reason" "small change" "$OUT"
rtrepo; mkdir -p "$R/src/__tests__" "$R/test" "$R/tests/unit"
for f in src/a.test.ts src/b.spec.tsx src/__tests__/c.js test/d.py tests/unit/e.sh; do lines 40 > "$R/$f"; done
eq "risk-tier: tests only → low" low "$(rt | head -n 1)"
rtrepo; mkdir -p "$R/src"; lines 3 > "$R/README.md"; lines 3 > "$R/src/x.ts"; lines 3 > "$R/src/y.ts"
eq "risk-tier: docs plus 2 code files → normal, no reason lines" normal "$(rt)"
rtrepo; mkdir -p "$R/src"; lines 3 > "$R/src/x.ts"; lines 3 > "$R/src/y.ts"
OUT=$(rt)
eq "risk-tier: 2 files, 6 lines → low" low "$(printf '%s\n' "$OUT" | head -n 1)"
has "risk-tier: small change → reason" "reason: small change: 2 files, 6 added lines" "$OUT"
rtrepo; lines 30 > "$R/x.ts"; eq "risk-tier: 30 added lines → low" low "$(rt | head -n 1)"
rtrepo; lines 31 > "$R/x.ts"; eq "risk-tier: 31 added lines → normal" normal "$(rt | head -n 1)"
rtrepo; echo c >> "$R/f.txt"; eq "risk-tier: a tracked edit counts" low "$(rt | head -n 1)"
rtrepo; for i in 1 2 3 4 5 6 7 8 9; do echo x > "$R/n$i.ts"; done
eq "risk-tier: 9 files → normal" normal "$(rt | head -n 1)"
echo x > "$R/n10.ts"; OUT=$(rt)
eq "risk-tier: 10 files → high" high "$(printf '%s\n' "$OUT" | head -n 1)"
has "risk-tier: 10 files → reason" "reason: 10 files changed" "$OUT"
rtrepo; mkdir -p "$R/hooks"; echo x > "$R/hooks/x.sh"; cm hooks; rm "$R/hooks/x.sh"
eq "risk-tier: a deleted hooks/ file → high" high "$(rt | head -n 1)"
rtrepo; mkdir -p "$R/src/auth"; printf 'const t = getToken()\n' > "$R/src/auth/a.ts"; printf 'mutex\n' > "$R/src/b.ts"
OUT=$(rt)
has "risk-tier: auth reason names the path" "reason: auth/session term (auth) in src/auth/a.ts" "$OUT"
has "risk-tier: concurrency reason names the file of the added line" "reason: concurrency term (mutex) in src/b.ts" "$OUT"
eq "risk-tier: every line after the first is a reason" 0 "$(printf '%s\n' "$OUT" | sed 1d | grep -cv '^reason: ')"
ST0=$(git -C "$R" status --porcelain); IX0=$(cksum < "$R/.git/index")
eq "risk-tier: high → exit 0" 0 "$(rtx)"
eq "risk-tier: real index untouched" "$IX0" "$(cksum < "$R/.git/index")"
eq "risk-tier: git status unchanged" "$ST0" "$(git -C "$R" status --porcelain)"
eq "risk-tier: same output from a subdirectory" "$OUT" "$(cd "$R/src" && bash "$H/risk-tier.sh" 2>&1)"
# committed change: seen only with a base
rtrepo; RTB=$(git -C "$R" rev-parse HEAD); mkdir -p "$R/src"; echo x > "$R/src/billing.ts"; cm billing
eq "risk-tier: committed change, no base → normal (an empty change is never low)" normal "$(rt)"
eq "risk-tier: committed change with a base → high" high "$(rt "$RTB" | head -n 1)"
rtrepo; mkdir -p "$R/src"; echo x > "$R/src/auth.ts"; cm auth; RTB=$(git -C "$R" rev-parse HEAD)
git -C "$R" mv src/auth.ts src/plain.ts; cm move
eq "risk-tier: a committed move keeps its old path (auth.ts → plain.ts) → high" high "$(rt "$RTB" | head -n 1)"
# A 5 MB minified line: only its first 20,000 characters are scanned, so it stays fast.
rtrepo; mkdir -p "$R/src"; yes 'var block=aB;' | head -n 400000 | tr -d '\n' > "$R/src/min.js"; printf 'const t = getToken()\n' > "$R/src/b.ts"
RTS=$SECONDS; OUT=$(rt); RTS=$((SECONDS - RTS))
eq "risk-tier: a 5 MB one-line file plus getToken() → high" high "$(printf '%s\n' "$OUT" | head -n 1)"
eq "risk-tier: a 5 MB one-line file is scanned in under 20 s" yes "$([ "$RTS" -lt 20 ] && echo yes || echo "no ($RTS s)")"
# Racy entry: an edit of the same size whose mtime equals both the index entry and the index file. Git re-reads such
# an entry only while the copied index keeps the real index's mtime (touch -r); trustctime off makes it deterministic.
rtrepo; mkdir -p "$R/src"; printf 'const xxxxx = 1\n' > "$R/src/a.ts"; git -C "$R" config core.trustctime false
touch -t 202001010000 "$R/src/a.ts"; cm racy
printf 'const token = 1\n' > "$R/src/a.ts"; touch -t 202001010000 "$R/src/a.ts" "$R/.git/index"
eq "risk-tier: a racily clean same-size edit is still seen" high "$(rt | head -n 1)"
# The temp index copy holds repo content: it stays 0600 even when the real index is 0644 (a git wrapper reads its mode).
chmod 644 "$R/.git/index"; mkdir -p "$TMP/rt-mode"
printf '#!/bin/sh\ncase " $* " in *" add -N "*) ls -l "$GIT_INDEX_FILE" | cut -c1-10 > "%s" ;; esac\nexec "%s" "$@"\n' \
  "$TMP/rt-mode/seen" "$REALGIT" > "$TMP/rt-mode/git"; chmod +x "$TMP/rt-mode/git"
(cd "$R" && PATH="$TMP/rt-mode:$PATH" bash "$H/risk-tier.sh" >/dev/null 2>&1)
eq "risk-tier: the temp index is not group- or world-readable" "-rw-------" "$(cat "$TMP/rt-mode/seen" 2>/dev/null)"
R="$TMP/rt-nonutf"; new_repo "$R"; printf 'const s = "\377" + token\n' > "$R/n.ts"
eq "risk-tier: a non-UTF-8 byte does not end the parse" high "$(cd "$R" && LC_ALL=C.UTF-8 bash "$H/risk-tier.sh" 2>/dev/null | head -n 1)"
eq "risk-tier: two arguments → exit 2" 2 "$(rtx a b)"
eq "risk-tier: unknown base → exit 2" 2 "$(rtx no-such-ref)"
eq "risk-tier: option-like base → exit 2" 2 "$(rtx --help)"
mkdir -p "$TMP/rt-nogit"; eq "risk-tier: outside a git repo → exit 2" 2 "$(cd "$TMP/rt-nogit" && GIT_CEILING_DIRECTORIES="$TMP" bash "$H/risk-tier.sh" >/dev/null 2>&1; echo $?)"
eq "risk-tier: umask 077 for its temp files" 1 "$(grep -c '^umask 077' "$H/risk-tier.sh")"
# --paths scores a planned change from its paths alone: run outside a git repo, so any git call would fail.
rtp() { (cd "$TMP/rt-nogit" && GIT_CEILING_DIRECTORIES="$TMP" bash "$H/risk-tier.sh" --paths "$@" 2>&1); }
rtpx() { (cd "$TMP/rt-nogit" && GIT_CEILING_DIRECTORIES="$TMP" bash "$H/risk-tier.sh" --paths "$@" >/dev/null 2>&1); echo $?; }
OUT=$(rtp src/a.ts)
eq "risk-tier --paths: 1 plain path → low" low "$(printf '%s\n' "$OUT" | head -n 1)"
has "risk-tier --paths: low reason" "reason: small plan: 1 paths" "$OUT"
eq "risk-tier --paths: 3 plain paths → low" low "$(rtp src/a.ts src/b.ts src/a.test.ts | head -n 1)"
eq "risk-tier --paths: 4 plain paths → normal, no reason lines" normal "$(rtp src/a.ts src/b.ts src/c.ts src/d.ts)"
eq "risk-tier --paths: 4 doc paths → normal (no docs-only rule)" normal "$(rtp a.md b.md c.md d.md)"
eq "risk-tier --paths: tokenizer path is not auth → low" low "$(rtp src/tokenizer.ts | head -n 1)"
OUT=$(rtp src/plain.ts src/auth/index.ts)
eq "risk-tier --paths: auth path → high" high "$(printf '%s\n' "$OUT" | head -n 1)"
has "risk-tier --paths: auth reason names the path" "reason: auth/session term (auth) in src/auth/index.ts" "$OUT"
eq "risk-tier --paths: every line after the first is a reason" 0 "$(printf '%s\n' "$OUT" | sed 1d | grep -cv '^reason: ')"
eq "risk-tier --paths: migration path → high" high "$(rtp db/migrations/001.sql | head -n 1)"
eq "risk-tier --paths: hooks/ path → high" high "$(rtp hooks/x.sh | head -n 1)"
eq "risk-tier --paths: gate file name → high" high "$(rtp src/commit-gate.ts | head -n 1)"
OUT=$(rtp a b c d e f g h i j)
eq "risk-tier --paths: 10 paths → high" high "$(printf '%s\n' "$OUT" | head -n 1)"
has "risk-tier --paths: 10 paths → reason" "reason: 10 files changed" "$OUT"
eq "risk-tier --paths: 9 paths → normal" normal "$(rtp a b c d e f g h i | head -n 1)"
OUT=$(rtp package-lock.json src/a.ts)
eq "risk-tier --paths: a dependency file → normal" normal "$(printf '%s\n' "$OUT" | head -n 1)"
has "risk-tier --paths: dependency reason" "reason: dependency change" "$OUT"
eq "risk-tier --paths: no paths → exit 2" 2 "$(rtpx)"
eq "risk-tier --paths: outside a git repo → exit 0" 0 "$(rtpx src/a.ts)"
eq "risk-tier --paths: ./hooks/x.sh → high" high "$(rtp ./hooks/x.sh | head -n 1)"
eq "risk-tier --paths: backticked hooks/x.sh → high" high "$(rtp '`hooks/x.sh`' | head -n 1)"
eq "risk-tier --paths: ./.github/workflows/ci.yml → high" high "$(rtp ./.github/workflows/ci.yml | head -n 1)"
eq "risk-tier --paths: an empty argument → exit 2" 2 "$(rtpx '')"
eq "risk-tier --paths: only commas and backticks → exit 2" 2 "$(rtpx ',`,`')"
eq "risk-tier --paths: one comma-joined argument of 5 files counts 5 → normal" normal "$(rtp 'a.ts,b.ts,c.ts,d.ts,e.ts')"
has "risk-tier --paths: comma and space separated, empties dropped" "reason: small plan: 2 paths" "$(rtp 'a.ts, b.ts,,')"
rtrepo; mkdir -p "$R/src/auth" "$R/hooks"; echo 'getToken()' > "$R/src/auth/a.ts"; echo x > "$R/hooks/h.sh"
eq "risk-tier --paths: a risky diff in the repo is never read" low "$(rt --paths src/plain.ts | head -n 1)"
eq "risk-tier --paths: an absolute path inside the repo → high" high "$(rt --paths "$R/hooks/x.sh" | head -n 1)"
eq "risk-tier --paths: an absolute path from a subdirectory → high" high "$(cd "$R/src" && bash "$H/risk-tier.sh" --paths "$R/hooks/x.sh" 2>&1 | head -n 1)"
eq "risk-tier: that repo diff alone → high" high "$(rt | head -n 1)"
AS=$(sed -n '/^## Agent Spawning/,/^## Context Budget/p' "$SK")
has "skill: reviewer spawn runs risk-tier.sh" 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/risk-tier.sh"' "$AS"
has "skill: risk line in the reviewer prompt" '`risk: <tier>`' "$AS"
has "skill: low risk → opus, medium effort" '`low` → spawn `reviewer` with `model: "opus"` and `effort: "medium"`' "$AS"
has "skill: risk-tier failure → normal" 'fails → `risk: normal`' "$AS"
has "code-review: risk tier for a diff target" 'hooks/risk-tier.sh' "$(cat "$ROOT/skills/code-review/SKILL.md")"
PR=$(sed -n '/^\*\*Probes\*\*/p' "$ROOT/agents/reviewer.md")
has "reviewer: high risk → at least 2 executed probes" 'at least 2 executable probes' "$PR"
has "reviewer: probes never in the work tree" "never in the user's work tree" "$PR"
has "reviewer: probes handoff line" '`probes: N run, K failed`' "$PR"
has "reviewer: a dispute re-judge re-runs probes only for a probe issue" 'does not re-run probes unless the disputed issue came from a probe' "$PR"
has "skill: Keep Fable does not change low" '`Keep Fable` does not change `low`' "$AS"
has "code-review: Keep Fable does not change low" '`Keep Fable` does not change `low`' "$(cat "$ROOT/skills/code-review/SKILL.md")"
has "reviewer: probes line is a 4th handoff bullet" 'plus `probes:` when your prompt says `risk: high`' "$OF"
has "docs/hooks.md: risk-tier row" '| **`risk-tier.sh`** |' "$(cat "$ROOT/docs/hooks.md")"
has "readme: risk-tier example" 'bash hooks/risk-tier.sh' "$(cat "$ROOT/README.md")"
has "CLAUDE.md: model routing names risk tiers" 'risk-tier.sh' "$(sed -n '/^## Model Routing/,$p' "$ROOT/CLAUDE.md")"
has "usage-downgrade keeps its own pointer" 'usage-downgrade.md` before the first `reviewer` or `refactor-architect` spawn' "$(cat "$SK")"
has "routing: developer spawn runs --paths on Affected Files" 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/risk-tier.sh" --paths <plan Affected Files>' "$AS"
has "routing: low plan → developer medium effort" '`low` → spawn `developer` with `effort: "medium"`' "$AS"
has "routing: normal, high or failure → no developer override" '`normal`, `high` or a script failure → no override' "$AS"
has "routing: bugfix never gets the medium override" 'A `bugfix` plan never gets this override' "$AS"
has "docs/hooks.md: risk-tier --paths" 'risk-tier.sh --paths <path...>' "$(cat "$ROOT/docs/hooks.md")"
has "readme: developer medium on a low plan" 'risk-tier.sh --paths' "$(sed -n '/^## Agents and models/,/^## Rules/p' "$ROOT/README.md")"
has "CLAUDE.md: model routing names the developer plan tier" 'risk-tier.sh --paths' "$(sed -n '/^## Model Routing/,$p' "$ROOT/CLAUDE.md")"
has "changelog: unreleased names git diff/show raw" 'git diff` and `git show` run raw' "$(sed -n '/^### Unreleased/,/^### v0\.7\.0/p' "$ROOT/CHANGELOG.md")"
has "changelog: unreleased names risk-tier --paths" 'risk-tier.sh --paths' "$(sed -n '/^### Unreleased/,/^### v0\.7\.0/p' "$ROOT/CHANGELOG.md")"

# --- review-context -----------------------------------------------------------------------
rc() { (cd "$R" && bash "$H/review-context.sh" "$@" 2>&1); }
rcx() { (cd "$R" && bash "$H/review-context.sh" "$@" >/dev/null 2>&1); echo $?; }
R="$TMP/rc"; mkdir -p "$R/src" "$R/tools" "$R/py"; git -C "$R" init -q
printf 'export function keepFn() {}\nexport function goneFn() {}\nexport const oldName = 1\n' > "$R/src/lib.ts"
printf "import { goneFn, keepFn } from './lib'\ngoneFn()\nkeepFn()\n" > "$R/src/use.ts"
printf 'goneFn()\n' > "$R/src/lib.test.ts"
printf 'oldName\n' > "$R/src/other.ts"
printf 'Call newName to start.\n' > "$R/README.md"; printf 'newName\n' > "$R/docs.TXT"; printf 'Shape\n' > "$R/CMakeLists.txt"
printf 'export function deadFn() {}\n' > "$R/src/dead.ts"; printf 'deadFn()\n' > "$R/src/zombie.ts"
printf 'export function fetchUser() {}\n' > "$R/src/api.ts"; printf 'fetchUser()\n' > "$R/src/real.ts"
printf 'myfetchUser()\nfetchUserList()\n' > "$R/src/super.ts"
printf 'export const stay = 1\n' > "$R/src/moved.ts"
printf 'helper() { :; }\n' > "$R/tools/run.sh"; printf '. ./run.sh; helper\n' > "$R/tools/call.sh"
printf 'def pyfn():\n    pass\nclass Old:\n    pass\n' > "$R/py/m.py"; printf 'from m import pyfn, Old\n' > "$R/py/user.py"
cm base; RCB=$(git -C "$R" rev-parse HEAD)
printf 'export function keepFn(a) {}\nexport const newName = 1\nconst arrowFn = (x) => x\n' > "$R/src/lib.ts"
printf 'export default async function Page() {}\nexport interface Shape {}\nexport type Tp = 1\nexport enum En {}\nexport class Cl {}\nexport let lv = 1\nfunction plainFn(a) {}\n  function nestedFn() {}\n' >> "$R/src/lib.ts"
rm "$R/src/dead.ts"; git -C "$R" mv src/moved.ts src/renamed.ts; : > "$R/src/api.ts"
printf 'function newhelp {\n  :\n}\n' > "$R/tools/run.sh"
printf 'def pyfn(x):\n    pass\nclass New:\n    pass\n' > "$R/py/m.py"
printf 'keepFn()\n' > "$R/src/new.test.ts"
IX0=$(cksum < "$R/.git/index"); ST0=$(git -C "$R" status --porcelain)
OUT=$(rc)
eq "review-context: exit 0" 0 "$(rcx)"
eq "review-context: real index untouched" "$IX0" "$(cksum < "$R/.git/index")"
eq "review-context: git status unchanged" "$ST0" "$(git -C "$R" status --porcelain)"
eq "review-context: sections in order" "files: symbols: callers: tests: " "$(printf '%s\n' "$OUT" | grep -E '^(files|symbols|callers|tests):$' | tr '\n' ' ')"
has "review-context: modified file with counts" "M src/lib.ts +11 -3" "$OUT"
has "review-context: deleted file" "D src/dead.ts +0 -1" "$OUT"
has "review-context: rename keeps both paths" "R src/moved.ts -> src/renamed.ts +0 -0" "$OUT"
has "review-context: untracked file is added" "A src/new.test.ts +1 -0" "$OUT"
lacks "review-context: unchanged file not listed as changed" "M src/use.ts" "$OUT"
has "review-context: removed export" "goneFn (removed) in src/lib.ts" "$OUT"
has "review-context: removed const" "oldName (removed) in src/lib.ts" "$OUT"
has "review-context: changed export (both sides)" "keepFn (changed) in src/lib.ts" "$OUT"
has "review-context: added export" "newName (added) in src/lib.ts" "$OUT"
has "review-context: symbol in a deleted file" "deadFn (removed) in src/dead.ts" "$OUT"
for s in arrowFn Page Shape Tp En Cl lv plainFn; do has "review-context: JS/TS form $s" "$s (added) in src/lib.ts" "$OUT"; done
lacks "review-context: a nested function is not a symbol" "nestedFn" "$OUT"
has "review-context: shell name() removed" "helper (removed) in tools/run.sh" "$OUT"
has "review-context: shell function name added" "newhelp (added) in tools/run.sh" "$OUT"
has "review-context: python def changed" "pyfn (changed) in py/m.py" "$OUT"
has "review-context: python class removed" "Old (removed) in py/m.py" "$OUT"
has "review-context: python class added" "New (added) in py/m.py" "$OUT"
lacks "review-context: a pure rename has no symbols" "stay (" "$OUT"
eq "review-context: removed symbols come first" "removed" "$(printf '%s\n' "$OUT" | sed -n '/^symbols:/{n;p;}' | sed 's/.*(\([a-z]*\)).*/\1/')"
has "review-context: callers of a removed name, test marked, defining file excluded" "goneFn: src/lib.test.ts (test), src/use.ts" "$OUT"
has "review-context: caller of a removed const" "oldName: src/other.ts" "$OUT"
eq "review-context: callers match whole words (not myfetchUser, fetchUserList)" "fetchUser: src/real.ts" "$(printf '%s\n' "$OUT" | grep '^fetchUser: ')"
has "review-context: caller of a symbol in a deleted file" "deadFn: src/zombie.ts" "$OUT"
has "review-context: untracked caller found" "keepFn: src/new.test.ts (test), src/use.ts" "$OUT"
has "review-context: a name mentioned only in a README and a .TXT doc → none" "newName: none" "$OUT"
has "review-context: CMakeLists.txt is not a doc, so it stays a caller" "Shape: CMakeLists.txt" "$OUT"
has "review-context: shell caller" "helper: tools/call.sh" "$OUT"
has "review-context: python caller" "Old: py/user.py" "$OUT"
eq "review-context: tests section lists the changed test files" "src/new.test.ts" "$(printf '%s\n' "$OUT" | sed -n '/^tests:/,$p' | sed 1d)"
eq "review-context: same output from a subdirectory" "$OUT" "$(cd "$R/src" && bash "$H/review-context.sh" 2>&1)"
cm change
eq "review-context: committed change, no base → empty" "files: none
symbols: none
callers: none
tests: none" "$(rc)"
OUTB=$(rc "$RCB")
has "review-context: base → committed removals" "goneFn (removed) in src/lib.ts" "$OUTB"
has "review-context: base → committed rename" "R src/moved.ts -> src/renamed.ts +0 -0" "$OUTB"
eq "review-context: two arguments → exit 2" 2 "$(rcx a b)"
eq "review-context: unknown base → exit 2" 2 "$(rcx no-such-ref)"
eq "review-context: option-like base → exit 2" 2 "$(rcx --help)"
mkdir -p "$TMP/rc-nogit"; eq "review-context: outside a git repo → exit 2" 2 "$(cd "$TMP/rc-nogit" && GIT_CEILING_DIRECTORIES="$TMP" bash "$H/review-context.sh" >/dev/null 2>&1; echo $?)"
(cd "$R" && PATH="$TMP/sg-gitfail:$PATH" bash "$H/review-context.sh" >/dev/null 2>&1); RC=$?
eq "review-context: shared collection fails → exit 2" 2 "$RC"
eq "review-context: umask 077 for its temp files" 1 "$(grep -c '^umask 077' "$H/review-context.sh")"
R="$TMP/rc-nonutf"; new_repo "$R"; printf 'const s = "\377"\nexport function afterByte() {}\n' > "$R/n.ts"
has "review-context: a non-UTF-8 byte does not end the parse" "afterByte (added) in n.ts" "$(cd "$R" && LC_ALL=C.UTF-8 bash "$H/review-context.sh" 2>/dev/null)"
# caps: 30 symbols, 10 callers each → 25 symbols, 8 callers per symbol, then the 4 KB cut
R="$TMP/rc-caps"; mkdir -p "$R/callers"; git -C "$R" init -q
RCN=$(i=10; while [ "$i" -lt 40 ]; do printf 'sym%s ' "$i"; i=$((i + 1)); done)
for c in 0 1 2 3 4 5 6 7 8 9; do echo "$RCN" > "$R/callers/a-rather-long-caller-file-name-to-fill-the-block-$c.ts"; done
cm base
for s in $RCN; do echo "export function $s() {}"; done > "$R/defs.ts"
OUT=$(rc)
eq "review-context: at most 25 symbol lines" 25 "$(printf '%s\n' "$OUT" | grep -c ' (added) in defs.ts$')"
has "review-context: symbols over the cap are counted" "symbols: +5 more" "$OUT"
has "review-context: at most 8 callers, then +N more" "sym10: callers/a-rather-long-caller-file-name-to-fill-the-block-0.ts" "$OUT"
has "review-context: callers over the cap are counted" "-7.ts, +2 more" "$(printf '%s\n' "$OUT" | grep '^sym10: ')"
lacks "review-context: the 9th caller is not listed" "-8.ts" "$(printf '%s\n' "$OUT" | grep '^sym10: ')"
eq "review-context: over the byte cap → last line says truncated" "… truncated" "$(printf '%s\n' "$OUT" | tail -n 1)"
eq "review-context: output stays within 4 KB" yes "$([ "$(printf '%s\n' "$OUT" | LC_ALL=C wc -c | tr -d ' ')" -le 4096 ] && echo yes || echo no)"
# 120 touched files with long paths: the files section is capped, so a removed export and its caller stay in the block
R="$TMP/rc-wide"; mkdir -p "$R/src" "$R/a-rather-long-directory-name-for-many-files"; git -C "$R" init -q
printf 'export function dropped() {}\n' > "$R/src/lib.ts"; printf 'dropped()\n' > "$R/src/keep.ts"; cm base
: > "$R/src/lib.ts"
i=100; while [ "$i" -lt 220 ]; do echo x > "$R/a-rather-long-directory-name-for-many-files/file-$i.ts"; i=$((i + 1)); done
OUT=$(rc)
eq "review-context: at most 30 file lines" 30 "$(printf '%s\n' "$OUT" | grep -cE '^[AMDR] ')"
has "review-context: files over the cap are counted" "files: +91 more" "$OUT"
has "review-context: 120 files → the removed export is kept" "dropped (removed) in src/lib.ts" "$OUT"
has "review-context: 120 files → its untouched caller is kept" "dropped: src/keep.ts" "$OUT"
# short lines (many changed tests): the cut lands within one 12-byte line of the cap, the marker included
R="$TMP/rc-short"; mkdir -p "$R/tests"; git -C "$R" init -q
i=1000; while [ "$i" -lt 1500 ]; do echo x > "$R/tests/t$i"; i=$((i + 1)); done
RCW=$(rc | LC_ALL=C wc -c | tr -d ' ')
eq "review-context: short lines → cut between 4080 and 4096 bytes" yes "$([ "$RCW" -ge 4080 ] && [ "$RCW" -le 4096 ] && echo yes || echo "no ($RCW)")"
RVG=$(sed -n '/^## Static Review Gates/,/^## Constraints/p' "$ROOT/agents/reviewer.md")
has "reviewer: runs review-context.sh after static-gates" '`bash "${CLAUDE_PLUGIN_ROOT}/hooks/review-context.sh"`' "$RVG"
has "reviewer: unchanged caller of a removed symbol → contract FAIL" 'FAIL `[contract]` unless the plan' "$RVG"
has "developer: self-check runs review-context.sh" '`bash "${CLAUDE_PLUGIN_ROOT}/hooks/review-context.sh"`' "$(sed -n '/^6\. Self-check/p' "$ROOT/agents/developer.md")"
has "docs/hooks.md: review-context row" '| **`review-context.sh`** |' "$(cat "$ROOT/docs/hooks.md")"
has "readme: review-context example" 'bash hooks/review-context.sh' "$(cat "$ROOT/README.md")"
has "changelog: review-context entry" 'hooks/review-context.sh' "$(sed -n '/^### v0\.7\.0/,/^### v0\.6/p' "$ROOT/CHANGELOG.md")"

# --- small doc items ----------------------------------------------------------------------
has "refactor-architect: rtk-wrap line" 'via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" <cmd> [args...]`' "$RA"
has "skill: main session rtk-wrap line" 'via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" <cmd> [args...]`' "$(sed -n '/^## Canonical Rules/,/^---$/p' "$SK")"
has "test-runner: description names baseline.txt" "Writes only to baseline.txt and to append to the failure-pattern ledger" "$(sed -n 's/^description: //p' "$ROOT/agents/test-runner.md")"
RVW=$(sed -n '/^## #review/,/^Logic correctness/p' "$ROOT/constraints.md")
lacks "constraints #review: no #failure-patterns append rule" "append to \`#failure-patterns\`" "$RVW"
has "constraints #review: points to reviewer step 5" "agents/reviewer.md\` step 5" "$RVW"
has "find-consumers: header names every breaking kind" "renamed/removed/retyped/now-optional/now-required" "$(sed -n 3p "$H/find-consumers.sh")"
lacks "find-consumers: no 'same hygiene as scan-repo.sh'" "same hygiene as scan-repo.sh" "$(cat "$H/find-consumers.sh")"

# --- audit-rules ----------------------------------------------------------------------------
AH="$TMP/audithome"; AW="$TMP/audit-web"; AA="$TMP/audit-api"; AB="$TMP/audit-sb"
au() { REVIEW_HARNESS_HOME="$AH" REVIEW_HARNESS_TODAY=2026-06-01 bash "$H/audit-rules.sh" "$@" 2>&1; }
aux() { au "$@" >/dev/null; echo $?; }
mkdir -p "$AH"
eq "audit-rules: empty home → no output" "" "$(au)"
eq "audit-rules: empty home → exit 0" 0 "$(aux)"
eq "audit-rules: an argument → usage error" 2 "$(aux --fix)"
eq "audit-rules: malformed REVIEW_HARNESS_TODAY → usage error" 2 \
  "$(REVIEW_HARNESS_HOME="$AH" REVIEW_HARNESS_TODAY=june bash "$H/audit-rules.sh" >/dev/null 2>&1; echo $?)"
mkdir -p "$AH/knowledge/acme" "$AH/org/agents" "$AH/org/profiles" "$AH/org/retired" "$AH/org/.backup" "$AW" "$AA" "$AB"
cat > "$AW/package.json" <<'EOF'
{
  "name": "web-app",
  "peerDependencies": { "react": "^17.0.0" },
  "dependencies": {
    "next": "^15.5.2",
    "react": "18.3.1",
    "three": "~0.172.0",
    "tailwindcss": "workspace:*"
  },
  "devDependencies": {
    "typescript": ">=5.4.0"
  }
}
EOF
cat > "$AA/package.json" <<'EOF'
{
  "dependencies": {
    "@nestjs/core": "^10.0.0",
    "@prisma/client": "^5.1.0 || ^6.0.0",
    "express": "*"
  }
}
EOF
# a one-line empty dependencies block must not open a block that swallows `scripts`
cat > "$AB/package.json" <<'EOF'
{
  "dependencies": {},
  "scripts": {
    "storybook": "storybook dev"
  },
  "devDependencies": {
    "next": "14.2.0",
    "storybook": "^8.1.0"
  }
}
EOF
cat > "$AH/knowledge/acme/repos.md" <<EOF
# Repos

### web-app
- **local_path**: \`$AW\`
- **role**: web
- **stack**: Next 14.2.3, React 18, TS 5, Three 0.160, Tailwind v3, MUI 6, **Zustand 4 ONLY**

### api (\`@acme/api\`)
- **local_path**: \`$AA\`
- **stack**: NestJS 10, Prisma 6, Express 4

### gone-app
- **local_path**: \`$TMP/audit-gone\`
- **stack**: Next 15

### sb-app
- **local_path**: \`$AB\`
- **stack**: Storybook 7, Next 14
EOF
printf -- '- **local_path**: `%s`\n' "$TMP/audit-nohead" > "$AH/knowledge/repos.md"
DUPL='- Never call the billing service directly from a component'
cat > "$AH/org/agents/developer.md" <<EOF
# Org overlay: developer

- **Next.js 14.x only** — never upgrade to 15
- Use React 18 features only
- Next.js 14+ is fine here
- Next 16+ required by the new router; Next 16+ again
$DUPL
$DUPL
- short dup rule here
\`\`\`ts
// Next 13 example in a fence
\`\`\`
- In the next 3 steps, react 2 times
EOF
printf '## #org\n\n%s\n-   short dup rule here\n' "$(printf '%s' "$DUPL" | sed 's/ /   /g')" > "$AH/org/constraints.md"
printf '%s\n- Next 13 rule in a retired file\n' "$DUPL" > "$AH/org/retired/old.md"
printf -- '- Next 13 rule in a backup\n' > "$AH/org/.backup/old.md"
{ echo '## #failure-patterns'; echo
  echo '- [2026-01-01] [category:scope] old pattern - old rule'
  echo '- [2026-03-02] [category:scope] 91 days - rule'
  echo '- [2026-03-03] [category:scope] 90 days - rule'
  echo '- [2026-04-01] [category:scope] recent pattern - recent rule'; } > "$AH/failure-patterns.md"
BEFORE=$(ls -lR "$AH" "$AW" "$AA" "$AB")
OUT=$(au); RC=$(aux)
eq "audit-rules: findings → exit 1" 1 "$RC"
has "audit-rules: stale major" "stale-version knowledge/acme/repos.md:6 — web-app: stack says Next 14.2.3, package.json has 15.5.2" "$OUT"
has "audit-rules: 0.x compares the minor" "stale-version knowledge/acme/repos.md:6 — web-app: stack says Three 0.160, package.json has 0.172.0" "$OUT"
lacks "audit-rules: same major → no finding" "React 18," "$OUT"
lacks "audit-rules: devDependencies with >= → same major" "TS 5" "$OUT"
lacks "audit-rules: workspace range skipped" "Tailwind" "$OUT"
lacks "audit-rules: unknown name skipped" "MUI" "$OUT"
lacks "audit-rules: name not in package.json skipped" "Zustand" "$OUT"
lacks "audit-rules: peerDependencies not read" "17.0.0" "$OUT"
lacks "audit-rules: * range skipped" "Express" "$OUT"
has "audit-rules: range → first major, noted" "stale-version knowledge/acme/repos.md:10 — api: stack says Prisma 6, package.json has 5.1.0 (range: ^5.1.0 || ^6.0.0)" "$OUT"
lacks "audit-rules: NestJS maps to @nestjs/core" "NestJS" "$OUT"
has "audit-rules: missing local_path" "missing-path knowledge/acme/repos.md:13 — gone-app: $TMP/audit-gone not found" "$OUT"
has "audit-rules: version-bound rule lists every repo, = and ≠" "version-rule org/agents/developer.md:3 — names Next.js 14.x; repos: web-app 15.5.2 (≠), sb-app 14.2.0 (=)" "$OUT"
has "audit-rules: one-line {} dependencies → scripts not read as dependencies" "stale-version knowledge/acme/repos.md:18 — sb-app: stack says Storybook 7, package.json has 8.1.0" "$OUT"
has "audit-rules: local_path before any heading → repo -" "missing-path knowledge/repos.md:1 — -: $TMP/audit-nohead not found" "$OUT"
lacks "audit-rules: plain English 'next 3' is no rule" "names next" "$OUT"
lacks "audit-rules: plain English 'react 2' is no rule" "names react" "$OUT"
lacks "audit-rules: same major in a rule → no finding" "names React" "$OUT"
lacks "audit-rules: N+ met by every repo → no finding" "names Next.js 14+" "$OUT"
has "audit-rules: N+ above a repo → finding" "version-rule org/agents/developer.md:6 — names Next 16+; repos: web-app 15.5.2 (≠), sb-app 14.2.0 (≠)" "$OUT"
eq "audit-rules: a token named twice on one line → one finding" 1 "$(printf '%s\n' "$OUT" | grep -c 'developer.md:6 ')"
lacks "audit-rules: fenced code skipped" "names Next 13" "$OUT"
eq "audit-rules: retired and hidden org folders not read" "" "$(printf '%s\n' "$OUT" | grep -e 'retired' -e '\.backup')"
has "audit-rules: duplicate across files (whitespace-normalised)" "duplicate org/constraints.md:3 — also in org/agents/developer.md:7" "$OUT"
eq "audit-rules: duplicate group reported once" 1 "$(printf '%s\n' "$OUT" | grep -c '^duplicate ')"
lacks "audit-rules: short bullet is no duplicate" "developer.md:9" "$OUT"
has "audit-rules: old ledger entry" "ledger-old failure-patterns.md:3 — dated 2026-01-01, 151 days old" "$OUT"
has "audit-rules: 91 days is old" "ledger-old failure-patterns.md:4 — dated 2026-03-02, 91 days old" "$OUT"
lacks "audit-rules: 90 days is not old" "2026-03-03" "$OUT"
lacks "audit-rules: small ledger → no size finding" "ledger-size" "$OUT"
lacks "audit-rules: under budget → no budget finding" "budget " "$OUT"
lacks "audit-rules: ledger with its heading is loaded" "ledger-unloaded" "$OUT"
eq "audit-rules: every line is <kind> <location> — <reason>" "" \
  "$(printf '%s\n' "$OUT" | grep -vE '^(stale-version|missing-path|version-rule|duplicate|budget|ledger-size|ledger-old|ledger-unloaded) [^ ]+ — .')"
eq "audit-rules: nothing written" "$BEFORE" "$(ls -lR "$AH" "$AW" "$AA" "$AB")"
mkdir -p "$TMP/nojq"
for t in bash cat grep sed awk dirname basename tr head cut date ls wc sort find paste; do ln -sf "$(command -v $t)" "$TMP/nojq/$t"; done
eq "audit-rules: no jq → same findings" "$OUT" "$(PATH="$TMP/nojq" REVIEW_HARNESS_HOME="$AH" REVIEW_HARNESS_TODAY=2026-06-01 "$BASH" "$H/audit-rules.sh" 2>&1)"
i=0; while [ "$i" -lt 40 ]; do echo "- [2026-05-01] [category:scope] filler pattern number $i - filler rule $i" >> "$AH/failure-patterns.md"; i=$((i + 1)); done
OUT=$(au)
has "audit-rules: ledger over 3072 bytes" "ledger-size failure-patterns.md — $(wc -c < "$AH/failure-patterns.md" | tr -d ' ') bytes, over the 3072 GC limit" "$OUT"
OUT=$(REVIEW_HARNESS_BUDGET_WARN_BYTES=100 au)
has "audit-rules: budget over the threshold" "budget reviewer — extract-constraints: " "$OUT"
has "audit-rules: budget names the threshold" "over the 100 budget (non-profile part)" "$OUT"
eq "audit-rules: one budget line per agent" 4 "$(printf '%s\n' "$OUT" | grep -c '^budget ')"
eq "audit-rules: no here-string or heredoc (bash 3.2 writes them to a temp file)" 0 "$(grep -c '<<' "$H/audit-rules.sh")"
UH="$TMP/audit-unloaded"; mkdir -p "$UH"
printf -- '- [2026-05-01] [category:scope] a pattern - a rule\n- [2026-05-02] [category:scope] b pattern - b rule\n' > "$UH/failure-patterns.md"
OUT=$(REVIEW_HARNESS_HOME="$UH" REVIEW_HARNESS_TODAY=2026-06-01 bash "$H/audit-rules.sh" 2>&1)
has "audit-rules: ledger entries without the heading" 'ledger-unloaded failure-patterns.md — 2 entries but no "## #failure-patterns" heading' "$OUT"
if [ "$(id -u)" = 0 ]; then echo "skip audit-rules: unreadable file (running as root)"; else
  printf -- '- rule\n' > "$UH/failure-patterns.md"; mkdir -p "$UH/org/agents"; printf -- '- x\n' > "$UH/org/agents/reviewer.md"
  chmod 000 "$UH/org/agents/reviewer.md"
  OUT=$(REVIEW_HARNESS_HOME="$UH" bash "$H/audit-rules.sh" 2>&1); RC=$?
  chmod 644 "$UH/org/agents/reviewer.md"
  eq "audit-rules: unreadable overlay → exit 2" 2 "$RC"
  has "audit-rules: unreadable overlay → one error line" "audit-rules: cannot read $UH/org/agents/reviewer.md" "$OUT"
fi
PH="$TMP/audit-perf"; mkdir -p "$PH/org/agents"; cp -R "$AH/knowledge" "$PH/"
awk 'BEGIN { for (i = 0; i < 20000; i++) print "- Next 13 rule number " i " for the router, Next 13 again" }' > "$PH/org/agents/developer.md"
S=$(date +%s); NPERF=$(REVIEW_HARNESS_HOME="$PH" bash "$H/audit-rules.sh" 2>/dev/null | grep -c '^version-rule '); E=$(date +%s)
eq "audit-rules: 20,000 overlay lines → 20,000 findings" 20000 "$NPERF"
eq "audit-rules: 20,000 overlay lines in under 10 s" yes "$([ $((E - S)) -lt 10 ] && echo yes || echo "no ($((E - S)) s)")"
AS="$ROOT/skills/audit-rules/SKILL.md"
has "audit-rules skill: name" "name: audit-rules" "$(cat "$AS" 2>/dev/null)"
has "audit-rules skill: runs the script" 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/audit-rules.sh"' "$(cat "$AS" 2>/dev/null)"
has "audit-rules skill: org overlay line" 'hooks/org-overlay.sh" skills audit-rules' "$(cat "$AS" 2>/dev/null)"
has "audit-rules skill: edits only after approval" "only the items the user approves" "$(cat "$AS" 2>/dev/null)"
has "audit-rules skill: never runs git" "never runs git" "$(cat "$AS" 2>/dev/null)"
has "audit-rules skill: exit 0 still runs the semantic pass" 'On `exit: 0` still run step 3' "$(cat "$AS" 2>/dev/null)"
has "audit-rules skill: offers the missing ledger heading" '`ledger-unloaded`' "$(cat "$AS" 2>/dev/null)"
has "docs/hooks.md: ledger-unloaded kind" '`ledger-unloaded`' "$(cat "$ROOT/docs/hooks.md")"
NS=$(ls -d "$ROOT"/skills/*/ | wc -l | tr -d ' ')
has "docs/skills.md: skill count" "## $NS Skills" "$(cat "$ROOT/docs/skills.md")"
has "readme: skill count" "the $NS skills" "$(cat "$ROOT/README.md")"
has "docs/skills.md: audit-rules entry" '**`/audit-rules`**' "$(cat "$ROOT/docs/skills.md")"
has "docs/hooks.md: audit-rules row" '| **`audit-rules.sh`** |' "$(cat "$ROOT/docs/hooks.md")"
has "readme: quick start row" '| `/audit-rules` |' "$(cat "$ROOT/README.md")"
has "readme: check list line" 'bash hooks/audit-rules.sh' "$(cat "$ROOT/README.md")"
has "changelog: audit-rules entry" 'hooks/audit-rules.sh' "$(sed -n '/^### Unreleased/,/^### v0\.7\.0/p' "$ROOT/CHANGELOG.md")"

# --- strategy: per-repo file, /strategy, the gate before planning, recording ------------------
sx() { "$@" >/dev/null 2>&1; echo $?; }
sf() { (cd "$1" && shift && bash "$H/strategy-file.sh" "$@" 2>&1); }
SR="$TMP/stratrepo"; new_repo "$SR"; mkdir -p "$SR/sub"
SP=$(sf "$SR")
case "$SP" in "$REVIEW_HARNESS_HOME/strategy/stratrepo-"????????????.md) OK=yes ;; *) OK="no: $SP" ;; esac
eq "strategy-file: <home>/strategy/<repo-name>-<12 hex>.md" yes "$OK"
case "$SP" in "$REVIEW_HARNESS_HOME"/*) ;; *) SP="$TMP/strategy-path-missing/x.md" ;; esac   # a broken script never writes outside $TMP
eq "strategy-file: same path from a subdirectory" "$SP" "$(sf "$SR/sub")"
git -C "$SR" worktree add -q -b strat-wt "$TMP/strat-wt" 2>/dev/null
eq "strategy-file: a worktree shares the repo's file" "$SP" "$(sf "$TMP/strat-wt")"
lacks "strategy-file: unlike the state dir, keyed on the common dir" "$(bash "$H/state-dir.sh" "$TMP/strat-wt")" "$(bash "$H/state-dir.sh" "$SR")"
mkdir -p "$TMP/other"; new_repo "$TMP/other/stratrepo"
lacks "strategy-file: same name, other repo → other file" "$SP" "$(sf "$TMP/other/stratrepo")"
eq "strategy-file: --status with no file → none" none "$(sf "$SR" --status)"
eq "strategy-file: never creates the folder" no "$([ -e "$REVIEW_HARNESS_HOME/strategy" ] && echo yes || echo no)"
mkdir -p "$TMP/nogit"
eq "strategy-file: outside git, --status → none" none "$(sf "$TMP/nogit" --status)"
eq "strategy-file: outside git, --status exits 0" 0 "$(sx sf "$TMP/nogit" --status)"
eq "strategy-file: outside git → exit 2" 2 "$(sx sf "$TMP/nogit")"
eq "strategy-file: unknown argument → exit 2" 2 "$(sx sf "$SR" --create)"
SCMD=$(sed -n 's/^- strategy: !`\(.*\)`$/\1/p' "$SK")
eq "review-harness: injected strategy line, no file → none" none "$(cd "$SR" && CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$SCMD")"
G90='Goal: raise the first-review PASS rate and cut tokens per run without losing caught defects, by far'
mkdir -p "$(dirname "$SP")"; printf '# Strategy — x\n%s\nMetrics: m\n' "$G90" > "$SP"
eq "strategy-file: --status → present + the first 80 chars of the Goal" \
  "present · Goal: $(printf '%s' "${G90#Goal: }" | cut -c1-80)" "$(sf "$SR" --status)"
eq "strategy-file: --status is one line" 1 "$(sf "$SR" --status | wc -l | tr -d ' ')"
eq "review-harness: injected strategy line, file present" "$(sf "$SR" --status)" "$(cd "$TMP/strat-wt" && CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$SCMD")"
# a multibyte Goal under the C locale: at most 80 bytes, whole characters only (79 bytes here, never a split one)
printf '# Strategy\nGoal: a%s\n' "$(printf '가%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30)" > "$SP"
OUT=$(cd "$SR" && LC_ALL=C bash "$H/strategy-file.sh" --status 2>&1)
eq "strategy-file: multibyte Goal, C locale → whole characters" "present · Goal: a$(printf '가%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26)" "$OUT"
eq "strategy-file: multibyte Goal, C locale → valid UTF-8" 0 "$(printf '%s' "$OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; echo $?)"
printf '# Strategy\nMetrics: m\n' > "$SP"
eq "strategy-file: --status, no Goal line" "present · Goal: -" "$(sf "$SR" --status)"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$SP"; eq "strategy-file: unreadable file, --status → exit 2" 2 "$(sx sf "$SR" --status)"; chmod 644 "$SP"
fi
# run-state strategy: stored in run-state and in the run log, never read by check
R="$SR"; SD=$(bash "$H/state-dir.sh" "$R")
eq "run-state strategy: no active run → exit 1" 1 "$(sx rs strategy aligned)"
rs start feature reviewer >/dev/null
eq "run-state strategy: unknown value → exit 2" 2 "$(sx rs strategy maybe)"
eq "run-state strategy: no value → exit 2" 2 "$(sx rs strategy)"
lacks "run-state status: no strategy before it is recorded" "strategy" "$(rs status)"
for v in aligned suggested-declined suggested-followed; do
  rs strategy "$v" >/dev/null; eq "run-state strategy: $v stored" "$v" "$(jq -r .strategy "$SD/run-state.json")"
done
has "run-state status: shows the recorded strategy" " · strategy suggested-followed" "$(rs status)"
C0=$(cd "$R" && bash "$H/run-state.sh" check 2>&1; echo "rc=$?")
rs strategy aligned >/dev/null
eq "run-state strategy: check unchanged (no verdict)" "$C0" "$(cd "$R" && bash "$H/run-state.sh" check 2>&1; echo "rc=$?")"
rs verdict PASS --by reviewer >/dev/null; rs tests pass >/dev/null
C0=$(cd "$R" && bash "$H/run-state.sh" check 2>&1; echo "rc=$?")
rs strategy suggested-followed >/dev/null
eq "run-state strategy: check unchanged (PASS)" "$C0" "$(cd "$R" && bash "$H/run-state.sh" check 2>&1; echo "rc=$?")"
has "run-state strategy: PASS still passes" "rc=0" "$C0"
rs done >/dev/null
eq "run-state strategy: closed run → exit 1" 1 "$(sx rs strategy aligned)"
eq "run log: strategy field" suggested-followed "$(tail -n 1 "$REVIEW_HARNESS_HOME/state/runs.jsonl" | jq -r .strategy)"
rs start feature >/dev/null; rs done >/dev/null
eq "run log: no strategy → no field" false "$(tail -n 1 "$REVIEW_HARNESS_HOME/state/runs.jsonl" | jq 'has("strategy")')"
has "run-state: usage names strategy" "strategy" "$(rs bogus)"
STH="$TMP/strathome"; mkdir -p "$STH/state"
cat > "$STH/state/runs.jsonl" <<'EOF'
{"repo":"r-1","workflow":"feature","attempts":0,"verdicts":[{"v":"PASS"}],"end":"done","strategy":"aligned"}
{"repo":"r-1","workflow":"feature","attempts":0,"verdicts":[{"v":"PASS"}],"end":"done","strategy":"suggested-followed"}
{"repo":"r-1","workflow":"bugfix","attempts":0,"verdicts":[{"v":"PASS"}],"end":"done","strategy":"suggested-declined"}
{"repo":"r-1","workflow":"feature","attempts":0,"verdicts":[{"v":"PASS"}],"end":"done"}
EOF
has "run-stats: strategy check line" "strategy check: 3 runs · suggested 2 · followed 1" "$(REVIEW_HARNESS_HOME="$STH" bash "$H/run-stats.sh")"
lacks "run-stats: no strategy field → no strategy line" "strategy check" "$(REVIEW_HARNESS_HOME="$SH" bash "$H/run-stats.sh")"
# docs and skills
SG=$(cat "$SKD/strategy-gate.md" 2>/dev/null)
has "skill: strategy pointer keyed on the injected line" '`strategy` is present and a `plan.md` will be written → read `${CLAUDE_PLUGIN_ROOT}/skills/review-harness/strategy-gate.md` before writing the plan' "$(sed -n '/^### 6\. Plan Gate/,/^---$/p' "$SK")"
for x in 'run-stats.sh --repo' '`Proceed as asked`' '`Do the alternative`' 'never blocks' 'run-state.sh strategy aligned' 'suggested-followed' 'suggested-declined' '`/strategy update' "user's yes" '## Why'; do
  has "strategy-gate.md: $x" "$x" "$SG"
done
has "strategy-gate.md: asks at most once" 'AskUserQuestion' "$SG"
has "strategy-gate.md: skipped when the run already recorded it" 'resumed run whose injected `run state` line shows `strategy`' "$SG"
has "strategy-gate.md: the alternative is not re-checked" 'do not re-run this check on it, the outcome is `suggested-followed`' "$SG"
has "strategy-gate.md: the alternative re-enters the Request Gate" 're-enters the Request Gate at step 2' "$SG"
has "strategy-gate.md: a declined suggestion noted in ## Why" 'declined suggestion' "$SG"
has "docs/hooks.md: strategy/ in the home layout" '├── strategy/' "$(cat "$ROOT/docs/hooks.md")"
for f in docs/hooks.md CHANGELOG.md; do
  has "$f: Goal cut in whole characters" 'at most 80 bytes, whole characters' "$(cat "$ROOT/$f")"
done
eq "plan-gate: ## Why right after ## Goal" '## Why' "$(sed -n '/^## Goal$/,/^## /p' "$SKD/plan-gate.md" | sed -n '$p')"
has "plan-gate: Risk tier line under Affected Files" 'Risk tier: [' "$(sed -n '/^## Affected Files$/,/^$/p' "$SKD/plan-gate.md")"
ST="$ROOT/skills/strategy/SKILL.md"; STS=$(cat "$ST" 2>/dev/null)
has "strategy skill: name" "name: strategy" "$STS"
has "strategy skill: not model-invoked" "disable-model-invocation: true" "$STS"
has "strategy skill: locates the file with the script" 'hooks/strategy-file.sh"' "$STS"
has "strategy skill: org overlay line" 'hooks/org-overlay.sh" skills strategy' "$STS"
has "strategy skill: never runs git" "never runs git" "$STS"
has "strategy skill: at most 3 questions" "at most 3 questions" "$STS"
has "strategy skill: size cap" "1,000 bytes" "$STS"
has "strategy skill: metric from run-stats" "run-stats.sh" "$STS"
has "strategy skill: writes only on yes" "user's yes" "$STS"
STB=$(awk '/^```!$/{f=1;next} /^```$/{if(f)exit} f' "$ST")
has "strategy skill: injected block names the file" "file: $SP" "$(cd "$TMP/strat-wt" && CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$STB" 2>&1)"
has "strategy skill: injected block outside git" "unavailable: " "$(cd "$TMP/nogit" && CLAUDE_PLUGIN_ROOT="$ROOT" bash -c "$STB" 2>&1)"
has "readme: Strategy section" "## Strategy" "$(cat "$ROOT/README.md")"
has "readme: quick start row" '| `/strategy` |' "$(cat "$ROOT/README.md")"
has "docs/skills.md: strategy entry" '**`/strategy`**' "$(cat "$ROOT/docs/skills.md")"
has "docs/skills.md: strategy-gate.md in the sibling list" 'strategy-gate.md' "$(cat "$ROOT/docs/skills.md")"
has "docs/hooks.md: strategy-file row" '| **`strategy-file.sh`** |' "$(cat "$ROOT/docs/hooks.md")"
has "docs/hooks.md: run-state strategy" 'strategy aligned|suggested-followed|suggested-declined' "$(cat "$ROOT/docs/hooks.md")"
has "CLAUDE.md: sibling list names strategy-gate.md" 'strategy-gate.md' "$(sed -n '/^## Where Consumer Rules Live/,/^## Repo Rules/p' "$ROOT/CLAUDE.md")"
has "changelog: strategy entry" 'hooks/strategy-file.sh' "$(sed -n '/^### Unreleased/,/^### v0\.7\.0/p' "$ROOT/CHANGELOG.md")"

# --- repo-rules: each touched repo's rule files and the docs they link to --------------------
rr() { (cd "$1" && shift && bash "$H/repo-rules.sh" "$@" 2>&1); }
rrx() { (cd "$1" && shift && bash "$H/repo-rules.sh" "$@" >/dev/null 2>&1); echo $?; }
sz() { wc -c < "$1" | tr -d ' '; }
R1="$TMP/rr-fe"; R2="$TMP/rr-be"; new_repo "$R1"; new_repo "$R2"
P1=$(cd "$R1" && pwd -P); P2=$(cd "$R2" && pwd -P)
mkdir -p "$R1/docs" "$R1/.claude/rules" "$R1/src/feature" "$R1/src/render" "$R1/src/api" "$R2/docs"
for d in data-fetching render architecture api feature; do echo "# $d" > "$R1/docs/$d.md"; done
echo x > "$TMP/rr-outside.md"; echo x > "$R1/docs/pic.png"
# files where a skipped http/mailto link would resolve, so the skip is observable
mkdir -p "$R1/https:/example.com"; echo x > "$R1/https:/example.com/x.md"; echo x > "$R1/mailto:m.md"
cat > "$R1/CLAUDE.md" <<'MD'
# FE rules
Data   fetching: see [data](docs/data-fetching.md) for `src/hooks/queries/` hooks.
Render: [render](./docs/render.md#pipeline) covers `src/render/*.ts`.
Arch: [arch](docs/architecture.md) and again [arch2](docs/architecture.md "title").
Web: [ext](https://example.com/x.md) [mail](mailto:m.md)
Missing: [gone](docs/missing.md) Outside: [out](../rr-outside.md) Image: [img](docs/pic.png)
MD
printf 'API calls: [api](../../docs/api.md) go through `src/api/client.ts`.\n' > "$R1/.claude/rules/a.md"
printf '# b\n' > "$R1/.claude/rules/b.md"
printf 'Feature folder: [feat](../../docs/feature.md)\n' > "$R1/src/feature/CLAUDE.md"
echo '# be' > "$R2/AGENTS.md"; echo x > "$R2/docs/tools.md"
printf 'Tools: [tools](docs/tools.md) live in `src/tools/`.\n' > "$R2/CLAUDE.md"
OUT=$(rr "$R1" src/hooks/queries/useX.ts 'src/render/*' '`src/api/client.ts`, ./src/feature/new/thing.ts' "$R2/src/tools/newtool.ts")
eq "repo-rules: two repos in one call exit 0" 0 "$(rrx "$R1" src/x.ts "$R2/src/tools/newtool.ts")"
eq "repo-rules: repos in order of first appearance" "repo: $P1|repo: $P2" "$(printf '%s\n' "$OUT" | grep '^repo: ' | tr '\n' '|' | sed 's/|$//')"
has "repo-rules: cwd repo root CLAUDE.md is auto-loaded" "rules: $P1/CLAUDE.md ($(sz "$R1/CLAUDE.md") B) · auto-loaded" "$OUT"
has "repo-rules: .claude/rules sorted and auto-loaded" "rules: $P1/.claude/rules/a.md ($(sz "$R1/.claude/rules/a.md") B) · auto-loaded"$'\n'"rules: $P1/.claude/rules/b.md (4 B) · auto-loaded" "$OUT"
has "repo-rules: nested CLAUDE.md on a new path's way, not auto-loaded" "rules: $P1/src/feature/CLAUDE.md ($(sz "$R1/src/feature/CLAUDE.md") B)"$'\n' "$OUT"
has "repo-rules: the other repo's CLAUDE.md is not auto-loaded" "rules: $P2/CLAUDE.md ($(sz "$R2/CLAUDE.md") B)"$'\n' "$OUT"
has "repo-rules: AGENTS.md listed, never auto-loaded" "rules: $P2/AGENTS.md ($(sz "$R2/AGENTS.md") B)"$'\n' "$OUT"
has "repo-rules: link count, dedup, skips (http, mailto, missing, outside, not .md)" "docs: 5 linked · 3 match the change" "$OUT"
has "repo-rules: dir token matches a new file under it, blanks collapsed" "- match $P1/docs/data-fetching.md — Data fetching: see [data](docs/data-fetching.md) for \`src/hooks/queries/\` hooks." "$OUT"
has "repo-rules: ./ and #anchor dropped; glob tail in token and argument" "- match $P1/docs/render.md — " "$OUT"
has "repo-rules: exact file token, ../ link from .claude/rules" "- match $P1/docs/api.md — " "$OUT"
has "repo-rules: non-matching doc listed plain" "- $P1/docs/architecture.md — Arch: " "$OUT"
has "repo-rules: nested CLAUDE.md link resolved from its folder" "- $P1/docs/feature.md — Feature folder: " "$OUT"
eq "repo-rules: a doc linked twice is listed once" 1 "$(printf '%s\n' "$OUT" | grep -c 'docs/architecture.md —')"
for x in missing.md rr-outside.md pic.png example.com/x.md mailto:m.md; do lacks "repo-rules: skips $x" "$x —" "$OUT"; done
eq "repo-rules: match lines first" "match|match|match|plain|plain|" \
  "$(printf '%s\n' "$OUT" | awk -v r="repo: $P1" '$0 == r { f = 1; next } /^repo: / { f = 0 } f && /^- / { printf "%s|", ($2 == "match" ? "match" : "plain") }')"
has "repo-rules: second repo's doc matches its own change" "docs: 1 linked · 1 match the change"$'\n'"- match $P2/docs/tools.md — Tools: [tools](docs/tools.md) live in \`src/tools/\`." "$OUT"
OUT=$(rr "$R1" src/other.ts)
has "repo-rules: no match when the change misses every token; nested CLAUDE.md off the path not read" "docs: 4 linked · 0 match the change" "$OUT"
R3="$TMP/rr-bare"; new_repo "$R3"
eq "repo-rules: no rule files → rules: none" "repo: $(cd "$R3" && pwd -P)|rules: none|docs: 0 linked · 0 match the change|" "$(rr "$R3" f.txt | tr '\n' '|')"
mkdir -p "$TMP/rr-nogit"
OUT=$(rr "$R1" "$TMP/rr-nogit/a.ts" src/x.ts)
has "repo-rules: a path outside any repo gets its line" "outside a git repo: $TMP/rr-nogit/a.ts" "$OUT"
has "repo-rules: the other path still reports its repo" "repo: $P1" "$OUT"
eq "repo-rules: only paths outside repos → exit 2" 2 "$(rrx "$R1" "$TMP/rr-nogit/a.ts")"
eq "repo-rules: no arguments outside a repo → exit 2" 2 "$(rrx "$TMP/rr-nogit")"
eq "repo-rules: all-empty arguments → exit 2" 2 "$(rrx "$R1" ' , `` ,' '*' './')"
# no arguments: the diff against HEAD plus untracked files
echo a > "$R1/src/render/scene.ts"; git -C "$R1" add -A
git -C "$R1" -c user.name=t -c user.email=t@t.t commit -qm rules
echo b >> "$R1/src/render/scene.ts"; echo x > "$R1/src/api/client.ts"
OUT=$(rr "$R1")
has "repo-rules: no arguments → diff + untracked match" "docs: 4 linked · 2 match the change" "$OUT"
has "repo-rules: no arguments, tracked edit matches" "- match $P1/docs/render.md" "$OUT"
has "repo-rules: no arguments, untracked file matches" "- match $P1/docs/api.md" "$OUT"
R5="$TMP/rr-nocommit"; mkdir -p "$R5/docs" && git -C "$R5" init -q && echo x > "$R5/docs/x.md"
printf '[x](docs/x.md) `src/x/`\n' > "$R5/CLAUDE.md"; git -C "$R5" add CLAUDE.md; mkdir -p "$R5/src/x"; echo x > "$R5/src/x/a.ts"
has "repo-rules: repo without commits → ls-files + untracked" "docs: 1 linked · 1 match the change" "$(rr "$R5")"
# a multibyte line under the C locale: cut at 200 bytes, whole characters only (15 + 61 × 3 bytes)
R6="$TMP/rr-mb"; new_repo "$R6"; mkdir -p "$R6/docs"; echo x > "$R6/docs/x.md"
K100=$(i=0; while [ $i -lt 100 ]; do printf '가'; i=$((i + 1)); done)
K61=$(i=0; while [ $i -lt 61 ]; do printf '가'; i=$((i + 1)); done)
printf '[x](docs/x.md) %s\n' "$K100" > "$R6/CLAUDE.md"
OUT=$(cd "$R6" && LC_ALL=C bash "$H/repo-rules.sh" f.txt 2>&1)
has "repo-rules: multibyte line cut at 200 bytes, whole characters" "- $(cd "$R6" && pwd -P)/docs/x.md — [x](docs/x.md) $K61"$'\n' "$OUT"$'\n'
eq "repo-rules: multibyte line, C locale → valid UTF-8" 0 "$(printf '%s' "$OUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; echo $?)"
# the same cut under a UTF-8 locale: bash 4+ `read` must not swallow the newline after a split character
# (only bash 4+ shows it, so this can go red on Linux only; skipped when no UTF-8 locale exists)
UL=$(locale -a 2>/dev/null | grep -ixE 'c\.utf-?8|en_US\.utf-?8' | head -n 1)
if [ -n "$UL" ]; then
  eq "repo-rules: multibyte cut line under $UL → still 1 linked" 1 \
    "$(cd "$R6" && LC_ALL=$UL LANG=$UL bash "$H/repo-rules.sh" f.txt 2>&1 | grep -c '^docs: 1 linked')"
  printf '[gone](docs/missing.md)\n' >> "$R6/CLAUDE.md"
  OUT=$(cd "$R6" && LC_ALL=$UL LANG=$UL bash "$H/repo-rules.sh" f.txt 2>&1)
  has "repo-rules: under $UL the next record keeps its own checks" "docs: 1 linked · 0 match the change" "$OUT"
  lacks "repo-rules: under $UL a missing doc after a cut line is not listed" "missing.md" "$OUT"
fi
# at most 30 doc lines, then +N more
R7="$TMP/rr-cap"; new_repo "$R7"; mkdir -p "$R7/docs"
i=1; while [ $i -le 35 ]; do echo x > "$R7/docs/d$i.md"; echo "- [d$i](docs/d$i.md)" >> "$R7/CLAUDE.md"; i=$((i + 1)); done
OUT=$(rr "$R7" f.txt)
has "repo-rules: 35 docs counted" "docs: 35 linked · 0 match the change" "$OUT"
eq "repo-rules: at most 30 doc lines" 30 "$(printf '%s\n' "$OUT" | grep -c '^- ')"
has "repo-rules: the rest as +N more" "+5 more" "$OUT"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$R7/CLAUDE.md"; eq "repo-rules: unreadable rule file → exit 2" 2 "$(rrx "$R7" f.txt)"
  eq "repo-rules: unreadable rule file → one stderr line, no stdout" "1 0" \
    "$( (cd "$R7" && bash "$H/repo-rules.sh" f.txt 2>&1 >/dev/null) | wc -l | tr -d ' ') $( (cd "$R7" && bash "$H/repo-rules.sh" f.txt 2>/dev/null) | wc -l | tr -d ' ')"
  chmod 644 "$R7/CLAUDE.md"
fi
# auto-loaded follows $PWD: run from the second repo, its own files are the auto-loaded ones
OUT=$(rr "$R2" src/tools/a.ts "$R1/src/x.ts")
has "repo-rules: run from the second repo → its CLAUDE.md is auto-loaded" "rules: $P2/CLAUDE.md ($(sz "$R2/CLAUDE.md") B) · auto-loaded" "$OUT"
has "repo-rules: run from the second repo → the first repo's CLAUDE.md is not" "rules: $P1/CLAUDE.md ($(sz "$R1/CLAUDE.md") B)"$'\n' "$OUT"
# match docs are never capped; only the rest is, at 30
R8="$TMP/rr-capm"; new_repo "$R8"; mkdir -p "$R8/docs"
i=1; while [ $i -le 32 ]; do echo x > "$R8/docs/m$i.md"; echo "- [m$i](docs/m$i.md) \`src/m/\`" >> "$R8/CLAUDE.md"; i=$((i + 1)); done
i=1; while [ $i -le 35 ]; do echo x > "$R8/docs/d$i.md"; echo "- [d$i](docs/d$i.md)" >> "$R8/CLAUDE.md"; i=$((i + 1)); done
OUT=$(rr "$R8" src/m/x.ts)
has "repo-rules: 67 docs, 32 match" "docs: 67 linked · 32 match the change" "$OUT"
eq "repo-rules: every match doc listed" 32 "$(printf '%s\n' "$OUT" | grep -c '^- match ')"
eq "repo-rules: the rest capped at 30" 30 "$(printf '%s\n' "$OUT" | grep '^- ' | grep -vc '^- match ')"
has "repo-rules: +N more counts only the uncapped rest" "+5 more" "$OUT"
# a change under .claude/ lists .claude/CLAUDE.md once
mkdir -p "$R8/.claude/rules"; echo '# c' > "$R8/.claude/CLAUDE.md"
eq "repo-rules: .claude/CLAUDE.md listed once for a change under .claude/" 1 \
  "$(rr "$R8" .claude/rules/new.md .claude/CLAUDE.md | grep -c '/\.claude/CLAUDE\.md ')"
# iconv present but printing nothing → the raw docs block stays
mkdir -p "$TMP/rr-fakebin"; printf '#!/bin/sh\ncat >/dev/null\n' > "$TMP/rr-fakebin/iconv"; chmod +x "$TMP/rr-fakebin/iconv"
has "repo-rules: silent iconv keeps the docs block" "docs: 67 linked · 32 match the change" "$(cd "$R8" && PATH="$TMP/rr-fakebin:$PATH" bash "$H/repo-rules.sh" src/m/x.ts 2>&1)"
# ~3,000 untracked files with long paths (over 128 KB of names) in no-argument mode
R9="$TMP/rr-many"; new_repo "$R9"; LD=src/a-fairly-long-directory-name/another-long-directory-name
mkdir -p "$R9/$LD" "$R9/docs"; echo x > "$R9/docs/many.md"
printf 'Many: [many](../../../docs/many.md) `src/a-fairly-long-directory-name/`\n' > "$R9/$LD/CLAUDE.md"
(cd "$R9/$LD" && awk 'BEGIN { for (i = 1; i <= 3000; i++) printf "file-number-%04d-with-padding.ts\n", i }' | xargs touch)
S0=$SECONDS; OUT=$(rr "$R9"); S1=$SECONDS
has "repo-rules: 3,000 untracked files → nested CLAUDE.md found" "rules: $(cd "$R9" && pwd -P)/$LD/CLAUDE.md (" "$OUT"
has "repo-rules: 3,000 untracked files → its doc matches" "docs: 1 linked · 1 match the change" "$OUT"
eq "repo-rules: 3,000 untracked files in under 10 s" yes "$([ $((S1 - S0)) -lt 10 ] && echo yes || echo "no: $((S1 - S0)) s")"
# one line holding 1,000 links: quick, and each listed line cut to 200 bytes
R10="$TMP/rr-links"; new_repo "$R10"; mkdir -p "$R10/docs"
(cd "$R10/docs" && awk 'BEGIN { for (i = 1; i <= 1000; i++) printf "l%d.md\n", i }' | xargs touch)
awk 'BEGIN { for (i = 1; i <= 1000; i++) printf "[l%d](docs/l%d.md) ", i, i; print "" }' > "$R10/CLAUDE.md"
S0=$SECONDS; OUT=$(rr "$R10" f.txt); S1=$SECONDS
has "repo-rules: 1,000 links on one line counted" "docs: 1000 linked · 0 match the change" "$OUT"
eq "repo-rules: 1,000 links on one line in under 5 s" yes "$([ $((S1 - S0)) -lt 5 ] && echo yes || echo "no: $((S1 - S0)) s")"
eq "repo-rules: listed line at most 200 bytes" "" "$(printf '%s\n' "$OUT" | grep '^- ' | sed 's/^- [^ ]* — //' | LC_ALL=C awk 'length($0) > 200')"
# the agents run it themselves; the plan and small-change paths name it
DV=$(cat "$ROOT/agents/developer.md"); RV=$(cat "$ROOT/agents/reviewer.md")
has "developer: runs repo-rules.sh on the plan's Affected Files" 'hooks/repo-rules.sh" <plan Affected Files>' "$DV"
has "developer: repo rules outrank generic constraints" 'repo rules outrank' "$DV"
has "developer: handoff names the docs followed" 'repo-rules: ' "$DV"
has "reviewer: runs repo-rules.sh" 'hooks/repo-rules.sh" <plan Affected Files>' "$RV"
has "reviewer: no plan → the Change context files" 'no plan: the paths from the Change context `files:` block' "$RV"
has "reviewer: preference wording is a defer note" 'a line worded as a preference' "$RV"
for f in "$ROOT/agents/developer.md" "$ROOT/agents/reviewer.md" "$SKD/small-change.md"; do
  has "$(basename "$f"): run repo-rules.sh before any cd" 'from the directory you started in, before any `cd`' "$(cat "$f")"
done
has "docs/hooks.md: auto-loaded meaning" 'the repo containing `$PWD`' "$(cat "$ROOT/docs/hooks.md")"
has "repo-rules.sh: header states auto-loaded meaning" 'the repo containing $PWD' "$(head -n 20 "$H/repo-rules.sh")"
has "readme: repo-rules token cost estimate" 'estimate' "$(grep "Each repo's own rules" "$ROOT/README.md")"
has "changelog: repo-rules token cost estimate" 'estimate' "$(sed -n '/^\*\*Repo rules\*\*/,/^$/p' "$ROOT/CHANGELOG.md")"
has "reviewer: Repo rules gate" '**Repo rules**' "$RV"
has "reviewer: [convention] FAIL quotes the rule" 'FAIL `[convention]` quoting the rule as `file:line`' "$RV"
has "plan-gate: Design Check Repo rules line" '- Repo rules: [docs from repo-rules.sh <Affected Files>' "$(cat "$SKD/plan-gate.md")"
has "small-change: runs repo-rules.sh before the edit" 'hooks/repo-rules.sh" <files>' "$(cat "$SKD/small-change.md")"
has "docs/hooks.md: repo-rules row" '| **`repo-rules.sh`** |' "$(cat "$ROOT/docs/hooks.md")"
has "readme: repo-rules line" 'repo-rules.sh' "$(cat "$ROOT/README.md")"
has "changelog: repo-rules entry" 'hooks/repo-rules.sh' "$(sed -n '/^### Unreleased/,/^### v0\.7\.0/p' "$ROOT/CHANGELOG.md")"
has "CLAUDE.md: agent rules line names repo-rules.sh" 'hooks/repo-rules.sh' "$(grep '^- Agent rules' "$ROOT/CLAUDE.md")"

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
