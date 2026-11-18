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
INTENTS=$(sed -n 's/^| `\([a-z-]*\)` | .*| .* |$/\1/p' "$SK" | tr '\n' ' ')
eq "skill: intent table rows" "feature refactor bugfix review " "$INTENTS"
WFLIST=$(grep -o '`<workflow>` = `[^`]*`' "$SK"); TMPL=$(grep '^\[feature' "$SK")
for i in $INTENTS; do
  has "skill: run-state workflow list names $i" "$i" "$WFLIST"
  has "skill: plan template Intent names $i" "$i" "$TMPL"
  eq "skill: ### section for $i" 1 "$(grep -ci "^### $i\$" "$SK")"
done
has "skill: description names bug fix" "bug fix" "$(sed -n 's/^description: //p' "$SK")"
has "skill: review needs a diff and no symptom" "no failure symptom is described" "$(grep '^| `review`' "$SK")"
has "skill: Small change excludes bugfix" 'not a `refactor` or `bugfix` intent' "$(cat "$SK")"
for l in Symptom Repro Cause 'Regression test'; do
  eq "skill: plan template ## Bug has $l" 1 "$(sed -n '/^## Bug (bugfix only)/,/^$/p' "$SK" | grep -c "^- $l: ")"
done
BF=$(sed -n '/^### Bugfix/,/^### Refactor/p' "$SK")
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
PLAN=$(sed -n '/^# Plan: /,/^## Commit Units/p' "$SK")
for s in 'Done When' 'Out of Scope'; do
  eq "skill: plan template has ## $s" 1 "$(printf '%s\n' "$PLAN" | grep -c "^## $s\$")"
  eq "refactor-architect: plan format has ## $s" 1 "$(grep -c "^## $s\$" "$ROOT/agents/refactor-architect.md")"
done
has "skill: Done When item names its check" '- [observable outcome] — check: [test name, command, or manual step]' "$PLAN"
has "skill: Done When / Out of Scope required for feature, bugfix, refactor" \
  '**Done When / Out of Scope rules**: required for `feature`, `bugfix`, `refactor`; omit for `review`. `Done When` lists 2–5 observable outcomes' "$(cat "$SK")"
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
SC=$(sed -n '/^### Small change/,/^### Feature/p' "$SK")
has "skill: Small change states a done-when line" '`Done when: <observable outcome> — check: <test, command, or manual step>`' "$SC"
has "skill: Small change passes it to reviewer" 'Put that `Done when:` line in the `reviewer` prompt.' "$SC"
has "skill: handoff max bullets allows red:" 'max 6 bullets plus `red:` for bugfix' "$(cat "$SK")"
has "skill: retries carry the first red: line" "bugfix: the first developer run's \`red:\` line — carry it through every retry" \
  "$(sed -n '/^Retry context must contain only:/,/^$/p' "$SK")"
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
PLAN=$(sed -n '/^# Plan: /,/^## Commit Units/p' "$SK")
DC=$(printf '%s\n' "$PLAN" | sed -n '/^## Design Check$/,/^$/p')
for l in Callers/Consumers Pattern Tests; do
  eq "skill: Design Check has $l" 1 "$(printf '%s\n' "$DC" | grep -c "^- $l: ")"
done
has "skill: discovery lines filled from grep before approval" '`Callers/Consumers`, `Pattern`, `Tests` are also filled by the main session before approval, from grep' "$(cat "$SK")"
OR=$(printf '%s\n' "$PLAN" | sed -n '/^## Only When Relevant/,/^$/p')
for l in Migration 'Dependency upgrade' Performance; do
  eq "skill: Only When Relevant has $l" 1 "$(printf '%s\n' "$OR" | grep -c "^- $l: ")"
done
has "skill: Execution Steps tasks over 6 files" '(more than 6 Affected Files) Task 1: [file group] — tests:' "$PLAN"
has "skill: task rule" 'More than 6 Affected Files → `Execution Steps` become ordered `Task N` lines' "$(cat "$SK")"
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
CR=$(grep '^\*\*Contract rules\*\*' "$SK")
has "skill: breaking contract runs find-consumers.sh from the plugin root" 'run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/find-consumers.sh" <term...>`' "$CR"
has "skill: unchanged consumer repo needs an Out of Scope follow-up" 'gets its follow-up named in `Out of Scope`' "$CR"
has "skill: producer run first" 'The producer run goes first' "$CR"
has "skill: a pasted Contract block is Inputs.API in any intent" '**Pasted Contract (any intent, trigger or not)**: a `## Contract` block from the producer repo'"'"'s run is always the spec — record it as-is in `plan.md → Inputs.API`' \
  "$(sed -n '/^### 4. API Spec Check/,/^### 5/p' "$SK")"
lacks "skill: pasted Contract is not a trigger-only table row" '| `## Contract` block pasted' "$(cat "$SK")"
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
HL=$(sed -n '/^## Harness Loop/,/^## Completion/p' "$SK")
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
HL=$(sed -n '/^## Harness Loop/,/^## Completion/p' "$SK")
lacks "skill: LIMIT no longer writes constraints.md" "constraints.md #failure-patterns" "$HL"
has "skill: LIMIT appends to the ledger path" 'the `ledger:` path' "$HL"
has "skill: LIMIT names the ledger format" 'entry format and scope of agents/reviewer.md step 5; a new file starts with `## #failure-patterns`' "$HL"
has "skill: LIMIT replan on the Small change path" '(Small change: no plan — ask the user, or switch to the Feature path)' "$(sed -n '/prints "LIMIT REACHED"/,/^```$/p' "$SK")"
has "skill: dispute re-judge is no attempt line" 'not a dispute re-judge' "$HL"
has "skill: attempts line per retry" 'N. hypothesis → change → result' "$HL"
has "skill: attempts in plan.md or attempts.md" '`## Attempts` in plan.md' "$HL"
has "skill: attempts.md without a plan" '<state dir>/attempts.md' "$HL"
has "skill: retry context carries the Attempts lines" 'the Attempts lines' "$(sed -n '/^Retry context must contain only:/,/^$/p' "$SK")"
has "skill: third failure of the same test or issue asks about the plan" 'whether the plan is wrong' "$HL"
has "skill: orchestrator may write attempts.md" '`attempts.md`' "$(sed -n '/^## Canonical Rules/,/^---$/p' "$SK")"
has "skill: handoff schema allows root cause:" '- root cause: <' "$(sed -n '/^### Compact Handoff Schema/,/^Rules:/p' "$SK")"
has "skill: handoff schema has the developer self-check: line" '- self-check: <rule hit → fixed>; … | clean (developer only)' "$(sed -n '/^### Compact Handoff Schema/,/^Rules:/p' "$SK")"
has "skill: handoff Rules line names self-check:" '`root cause:` and `self-check:`' "$(grep '^Rules: omit empty fields' "$SK")"
has "developer: root cause on the second failure" '`root cause: <file:line' "$(cat "$ROOT/agents/developer.md")"
README_STATE=$(cat "$ROOT/README.md")
has "readme: attempts.md in the state table" '| `attempts.md` |' "$README_STATE"
has "readme: failure-patterns.md documented" '| `failure-patterns.md` |' "$README_STATE"
R="$TMP/attempts"; new_repo "$R"; SD=$(bash "$H/state-dir.sh" --create "$R"); echo "1. x → y → z" > "$SD/attempts.md"
rs start small-change test-runner reviewer >/dev/null
eq "run-state: start clears the previous run's attempts.md" absent "$([ -f "$SD/attempts.md" ] && echo present || echo absent)"
rs abandon >/dev/null

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
R="$TMP/agentrepo"; new_repo "$R"; SD=$(bash "$H/state-dir.sh" "$R"); AF="$SD/run-state.json"; AG="$SD/agents.json"; ALOG="$REVIEW_HARNESS_HOME/state/runs.jsonl"
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
aj() { jq -c "$1" "$AG"; }
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
eq "agent-usage: start opens a span in agents.json, type without plugin prefix" '{"type":"developer","open":true,"s":0}' "$(aj '.a1 | {type, open: (.open | type == "number"), s}')"
age .a1.open 5 "$AG"; OUT=$(au SubagentStop a1); RC=$?
eq "agent-usage: stop → silent, exit 0" "0:" "$RC:$OUT"
eq "agent-usage: run-state.json (gate fields, updated_at) untouched by start/stop" "$G0" "$(gatefields)"
eq "agent-usage: run-state.json holds no agent data" false "$(jq 'has("agents")' "$AF")"
eq "agent-usage: stop → deduplicated tokens, tools, model (not <synthetic>), span closed" '{"model":"claude-x","in":11,"out":7,"cr":103,"cw":24,"tools":2,"open":null}' \
  "$(aj '.a1 | {model, in, out, cr, cw, tools, open}')"
eq "agent-usage: stop → active seconds" true "$(aj '.a1.s >= 5 and .a1.s < 60')"
au SubagentStart a1; age .a1.open 3 "$AG"; au SubagentStop a1
eq "agent-usage: resume → tokens replaced, not added" '{"in":11,"out":7,"tools":2}' "$(aj '.a1 | {in, out, tools}')"
eq "agent-usage: resume → second span added" true "$(aj '.a1.s >= 8 and .a1.s < 60')"
OUT=$(au SubagentStop a9); RC=$?
eq "agent-usage: unknown agent_id → silent, exit 0" "0:" "$RC:$OUT"
eq "agent-usage: unknown agent_id → no entry" null "$(aj '.a9')"
au SubagentStart a2 review-harness:reviewer; age .a2.open 2 "$AG"
OUT=$(au SubagentStop a2 review-harness:reviewer "$TMP/missing.jsonl"); RC=$?
eq "agent-usage: missing transcript → silent, exit 0" "0:" "$RC:$OUT"
eq "agent-usage: missing transcript → span kept, no tokens" '{"type":"reviewer","in":0,"time":true}' "$(aj '.a2 | {type, in, time: (.s >= 2)}')"
au SubagentStart a3 test-runner   # bare agent type (matcher allows it)
eq "agent-usage: bare agent type kept" '"test-runner"' "$(aj '.a3.type')"
for i in 1 2 3 4 5 6; do au SubagentStart "p$i" & done; wait
eq "agent-usage: parallel starts all recorded" 6 "$(aj '[keys[] | select(startswith("p"))] | length')"
jq 'with_entries(select(.key | startswith("p") | not))' "$AG" > "$AG.x" && mv "$AG.x" "$AG"
OUT=$(printf '{"hook_event_name":"SubagentStart"}' | PATH="$TMP/nojq" "$BASH" "$H/agent-usage.sh" 2>&1); RC=$?
eq "agent-usage: no jq → silent, exit 0" "0:" "$RC:$OUT"
OUT=$(printf 'not json' | bash "$H/agent-usage.sh" 2>&1); RC=$?
eq "agent-usage: bad input → silent, exit 0" "0:" "$RC:$OUT"
has "status: agent count" " · agents 3" "$(rs status)"
rs done >/dev/null
eq "agents.json: removed by done" false "$(exists "$AG")"
eq "run log: agents grouped by type" '[{"type":"developer","n":1,"in":11,"out":7,"cr":103,"cw":24,"tools":2},{"type":"reviewer","n":1,"in":0,"out":0,"cr":0,"cw":0,"tools":0},{"type":"test-runner","n":1,"in":0,"out":0,"cr":0,"cw":0,"tools":0}]' \
  "$(tail -n 1 "$ALOG" | jq -c '[.agents[] | del(.s)]')"
eq "run log: agent seconds summed" true "$(tail -n 1 "$ALOG" | jq '(.agents[0].s >= 8) and (.agents[1].s >= 2)')"
eq "run log: run token totals" '{"in":11,"out":7,"cr":103,"cw":24}' "$(tail -n 1 "$ALOG" | jq -c .tokens)"
echo '{"x":{"type":"developer","s":1,"in":1,"out":1,"cr":0,"cw":0,"tools":0}}' > "$AG"   # left over from a closed run
rs start feature >/dev/null
eq "agents.json: removed by start" false "$(exists "$AG")"
rs done >/dev/null
eq "run log: no agent data → no agents/tokens keys" false "$(tail -n 1 "$ALOG" | jq 'has("agents") or has("tokens")')"
lacks "status: no agent data → no agent count" "agents" "$(rs start feature >/dev/null; rs status)"
au SubagentStart b1; rs abandon >/dev/null
eq "agents.json: removed by abandon" false "$(exists "$AG")"
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

# --- small doc items ----------------------------------------------------------------------
has "refactor-architect: rtk-wrap line" 'via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" <cmd> [args...]`' "$RA"
has "skill: main session rtk-wrap line" 'via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" <cmd> [args...]`' "$(sed -n '/^## Canonical Rules/,/^---$/p' "$SK")"
has "test-runner: description names baseline.txt" "Writes only to baseline.txt and to append to the failure-pattern ledger" "$(sed -n 's/^description: //p' "$ROOT/agents/test-runner.md")"
RVW=$(sed -n '/^## #review/,/^Logic correctness/p' "$ROOT/constraints.md")
lacks "constraints #review: no #failure-patterns append rule" "append to \`#failure-patterns\`" "$RVW"
has "constraints #review: points to reviewer step 5" "agents/reviewer.md\` step 5" "$RVW"
has "find-consumers: header names every breaking kind" "renamed/removed/retyped/now-optional/now-required" "$(sed -n 3p "$H/find-consumers.sh")"
lacks "find-consumers: no 'same hygiene as scan-repo.sh'" "same hygiene as scan-repo.sh" "$(cat "$H/find-consumers.sh")"

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
