# Changelog

This plugin is a rebuild that carries over the Harness Engineering principles of the earlier `front-agent` (a generic React/Next plugin).

### Unreleased

**Bug-fix workflow**
- New `bugfix` intent (`fix`, `bug`, `error`, `broken`, `fails`, `crash`, `regression`, or "why" about a failure, in any language). `check`/`verify` route to review only when there is a diff to review and no failure symptom; a trivial fix with no failure ("fix this typo") stays Small change; no matching intent → one clarifying question
- Bugfix flow in `/review-harness`: reproduce (failing test, or a command and its output) → `plan.md → ## Bug` (`Symptom`, `Repro`, `Cause` as `file:line` + why, `Regression test`) → developer runs the regression test RED, then fixes → test-runner → reviewer → git-commit. Not reproducible → ask the user, never fix by guess. Never takes the Small change path; a fix of at most 2 files skips the approval wait but shows `Cause` and `Regression test` first. Run state: `run-state.sh start bugfix …`
- A regression test that passes before the fix means a wrong `Cause`: the loop back to reproduce counts as an attempt
- `developer`: for a bugfix, writes (or runs the existing) regression test before the fix and reports its failing line as `red:` in the handoff (new optional handoff field)
- `reviewer` static gates: bugfix with no regression test in the diff or the plan and no stated reason, or with no `red:` line → FAIL `[correctness]`; a change the `Cause` does not explain → FAIL `[scope]`

**Definition of done**
- `plan.md` gains `## Done When` (2–5 observable outcomes, each with its check: test name, command, or manual step) and `## Out of Scope` (1–2 lines), required for `feature`, `bugfix` and `refactor` (also in the `refactor-architect` plan format). A Small change states one `Done when:` line before the edit and passes it to the reviewer
- `reviewer` goal gate: reads `Intent`, `Done When` and `Out of Scope` (or the Small change `Done when:` line; skipped when neither exists). FAIL `[goal]` on a missing `Done When`, an unmet item (judged from test-runner output, or by running the command; manual steps go to `blockers` as `manual: <step>`, never FAIL), a TODO/stub/placeholder return where a `Done When` item expects working code, or a new export with no caller (public entry exports, file-routed / DI-registered / CLI entry points, test-only use, and callers named in `Out of Scope` are exempt). An `Out of Scope` edit is FAIL `[scope]`. New category `goal` in the reviewer's lists and the `#failure-patterns` format
- `test-runner` gets the `Done When` test/command checks in its prompt, so the reviewer has evidence for them
- Handoff: "max 6 bullets plus `red:` for bugfix"; a bugfix retry carries the first developer run's `red:` line to the re-spawned developer and the reviewer

**Verification**
- Test baseline: in `feature`, `bugfix` and `refactor`, `test-runner` runs once before `developer` (`mode: baseline`, run-state step `baseline`) and writes the already-failing tests to `<state dir>/baseline.txt`; later runs count only new failures (a bugfix's regression test always counts). The user is told in one line when the baseline has failures. `run-state.sh start` deletes the previous run's baseline
- Test results in the commit gate: new `run-state.sh tests pass|fail|none|manual-confirmed` (recorded by `test-runner` with the work-tree hash; active run only). `check` blocks on `fail`, on `none` the user has not confirmed, and on a confirmation of an older work tree; `manual-confirmed` is accepted only over `none`. A run with no tests record (review fast-path, older flows) is gated as before. `status` shows the tests record
- No-tests repos: on `no_tests_configured`, `/review-harness` shows the `Done When` manual steps (or the Small change `Done when:` check) after reviewer PASS and records `manual-confirmed` only after the user's explicit yes
- `test-runner` runs the `Done When` command checks also when the repo has no test command, then one whole-project check (registry `check_cmd`, else `npx tsc --noEmit` with a `tsconfig.json`) reported as `check:`
- `developer` runs the new tests and confirms they fail for the intended reason before implementing (`/tdd` points to that rule instead of repeating it). Its output is the handoff block only, with an optional `assumptions:` line (also in the handoff schema); "Output code only" is gone from `developer` and `constraints.md #completion`
- `post-tool-use.sh`: when the tsc block shows the edited file's errors, a line `other files: N more errors` counts the errors elsewhere that are not shown
- `reviewer`: a stub that `Out of Scope` names is not an out-of-scope edit

**Planning discovery and task decomposition**
- `plan.md → ## Design Check` gains `Callers/Consumers` (every file using a changed export, route or event, or `none — new`), `Pattern` (one neighbouring file to imitate) and `Tests` (existing tests covering the area + new ones), filled by the main session from grep before approval
- More than 6 Affected Files → `Execution Steps` become ordered `Task N` lines (file group + that task's tests); `developer` runs each task's tests before the next. `developer` updates every `Callers/Consumers` file or marks it `no change needed: <reason>` in the plan
- New plan section `## Only When Relevant`: `Migration` (rollback, existing data), `Dependency upgrade` (breaking changelog items), `Performance` (measurement + target) — written only when the change has that part
- `reviewer` contract gate: a `Callers/Consumers` file neither in the diff nor marked `no change needed: <reason>` → FAIL `[contract]`
- `refactor-architect`: when no test covers the target area, the first Migration Step writes characterization tests, unless the user explicitly waives it (recorded under `## Risk`)

**Verification follow-ups**
- `run-state.sh check` blocks a `tests pass` recorded for an older work tree (code changed after the test run). No tests record still leaves the gate to the review alone
- `run-state.sh done` and `abandon` also delete `baseline.txt`, so `/tdd` and `/refactor-scan` never read a stale baseline. `test-runner` no longer runs steps 5–7 in baseline mode when no test command exists
- The Small change path has no test baseline: with already-failing tests the user is told and may override

**Measurement**
- Run log: `run-state.sh done` / `abandon` of an active run appends one JSON line to `~/.review-harness/state/runs.jsonl` (all repos, honours `REVIEW_HARNESS_HOME`, never rewritten): repo id, workflow, start/end/duration, attempts, reviewer verdict sequence with the `[category]` tags of each FAIL, test result, override reason, end (`done` / `abandoned` / `limit` when attempts reached the maximum) and files changed since the commit the run started from (left out when there was none). The run state now keeps `verdicts` (`{v, cats}`; older string entries are still read) and `base` for it. A failed append warns and never changes the exit code; a standalone review record (no active run) is not logged
- `run-state.sh verdict FAIL <category...>`: the reviewer appends the `[category]` tags of its FAIL issues (`agents/reviewer.md` step 6, the verdict command in `/review-harness` and `/code-review`). Words outside the reviewer's category list are ignored with a warning; PASS takes none. Exit codes and attempt counting are unchanged
- New `hooks/run-stats.sh [--repo <id|name>] [--since <days>]`: runs, mean attempts before PASS, share of runs with a reviewer FAIL, FAIL category counts (`untagged` for a FAIL recorded without tags), override rate, limit-reached count, and the same per workflow. Needs `jq` (clear message without it); skips torn lines
- Bench: three plan-based cases that look fine without the plan — `goal-not-wired` (`[goal]`), `bug-cause-elsewhere` (`[scope]` / `[correctness]` against `Cause`), `contract-caller-missed` (`[contract]`). A case may ship `plan.md` and `handoff.md`; `prompt.sh <arm> <fixture> [case-dir]` copies the plan next to the fixture and passes it as `plan_path` with the handoff lines. `expect.txt` may give the expected categories on line 4 (`score.sh` adds `category=match|other`). New `bench_next` skeleton in `bench/lib.sh`
- `bench/README.md`: three runs per cell for new results, cells for the plan-based cases, a design note for a developer-side bench (hidden acceptance tests; deferred, not built), and an "A/B on real tasks" procedure that reads `runs.jsonl` per arm

**Runtime rules now reach plugin users**
- A plugin's root `CLAUDE.md` is not loaded in a user's session (`claude plugin validate` warns about it), so rules kept only there never applied outside this repo. They now live in the skill or agent that acts on them: Write/Edit limits, context-budget limits and "pass `extract-constraints.sh` output as-is" in `/review-harness`; rtk wrapping in the `developer` and `reviewer` agents; "never `rtk init -g`" in `/rtk-toggle`. `CLAUDE.md` is now the maintainer file
- The `review-harness` skill description also lists bug-fix requests ("fix this") for auto-invocation

**Fixed**
- `detect-repo.sh` printed no `hint` line and no `=== End Active Repo ===` marker when the org hint file was missing
- `/register-repo` printed `no matches found` under zsh when no org registry exists
- `scan-repo.sh` printed a broken `local_path` for a folder name containing a backtick (backticks are now stripped)

### v0.6.0 (2026-11-16)

**Register a repo without writing `repos.md` by hand**
- New `hooks/scan-repo.sh [dir]`: prints a proposed registry block for the repo root — `local_path`, `role: TODO`, `stack` (package.json deps with major version, Python packages, Go version, Rust), `layout`, `path_alias` from `tsconfig.json`, `test_cmd` from `detect-test-cmd.sh`, `check_cmd` (`ruff check .` with a ruff config, `go vet ./...` with `go.mod`; none for TypeScript, which tsc/eslint already cover) and workspace patterns in `special`. Reads only; the same files give the same block
- New `/register-repo` skill: shows the scan, asks up to 3 questions (role, test/check commands, up to 3 team rules for `special`), shows the final block and appends it only after the user confirms — to the registry `detect-repo.sh` reads, else the only `knowledge/<org>/` folder, else the flat `knowledge/repos.md` — then checks it with `detect-repo.sh`. An already registered repo is shown and left unchanged. No new registry keys
- `/review-harness` Active Repo Gate: for code work in an unregistered repo, or with no registry at all, offers `/register-repo` once per work tree; "continue" creates `<state dir>/register-declined` and the offer is not repeated. `detect-repo.sh` is unchanged

**Renamed to `review-harness`** (the entries below keep the names that were current at the time)
- Plugin, marketplace and entry skill: `front-harness` → `review-harness` (`/review-harness`, agents `review-harness:<agent>`)
- Home folder: `~/.front-harness/` → `~/.review-harness/`. Environment variables: `FRONT_HARNESS_HOME` → `REVIEW_HARNESS_HOME`, `FE_HARNESS_*` → `REVIEW_HARNESS_*`
- No fallback to the old names. To migrate: `mv ~/.front-harness ~/.review-harness`, replace the old path inside your own overlay and knowledge files, uninstall `front-harness@front-harness` and install `review-harness@review-harness`
- Added `tests/run.sh` (hook smoke tests) and CI on Linux and macOS

**Stack rules moved into a profile** (wording unchanged, only the location)
- New `profiles/web-frontend.md` (tags `#code-rules`, `#implementation`, `#review`, `#detection`) holds the TypeScript / React / Next.js / Tailwind / Zustand / TanStack Query / Socket.IO rules that were in `constraints.md`, `agents/developer.md`, `agents/reviewer.md`, `agents/refactor-architect.md` and the `code-review` / `refactor-scan` skills
- `hooks/extract-constraints.sh <agent> [profile]`: appends the agent's profile sections as a `## Profile — <name>` block. No default profile; an unknown name exits 2 with nothing on stdout. The 8192-byte budget warning measures the non-profile part, profile bytes are reported separately
- Every skill passes `web-frontend`, so agents receive the same rules as before
- Review category `react-perf` renamed to `performance`. The Three.js / R3F gates (`three-perf`) left the public rules; keep them in your organisation overlay if you need them

**Profiles chosen from the change, test commands for more stacks**
- New `hooks/detect-profile.sh [path...]`: picks profiles from the changed files (`.tsx`/`.jsx`/`.vue`/`.svelte`/styles → `web-frontend`; controllers, `routes/`, `api/`, SQL, migrations → `web-api`; both → also `web-common`). Any other file (e.g. a `.ts` hook, an `api/` route, a changed `package.json`) counts by the dependencies of its nearest `package.json` / `pyproject.toml` / `requirements*.txt`, so monorepo packages are judged separately; a clean tree uses the repo-root manifest. Prints only profiles that exist, so a profile applies once its file lands; a Python or Go change gets the generic rules instead of the React gates
- Skills pass `detect-profile.sh` output to `extract-constraints.sh` instead of a fixed `web-frontend` (developer / refactor-architect: the plan's Affected Files; reviewer / test-runner / code-review: the current changes). The reviewer's first output line is `Profile: <names|none>`
- `extract-constraints.sh` takes a comma list of profiles (one block each, in order; any unknown name exits 2); an empty argument means no profile. Single-profile output is unchanged
- New `hooks/detect-test-cmd.sh [dir]`: registry `test_cmd`, `package.json` `scripts.test` (pnpm/bun/yarn/npm by lockfile, npm's placeholder ignored), vitest/jest config, a bun lockfile (`bun test`), pytest, `go.mod`, `Cargo.toml`. Used by test-runner and the `tdd` probe
- Registry keys `test_cmd` and `check_cmd`; `detect-repo.sh` now also prints `local_path`. With `check_cmd`, `post-tool-use.sh` runs it from the registered `local_path` after any edit in that repo instead of tsc/eslint; without it nothing changes
- `pre-tool-use.sh` also gates lock files and `.env` / `.env.*` (except `.env.example`, `.env.sample`, `.env.template`)
- `feature` intent keywords gain `endpoint`, `migration`, `schema`, `handler`

**`web-api` and `web-common` profiles** (every gate comes from a real bug fix)
- New `profiles/web-api.md`: `#implementation` (developer, 6 do's) and `#review` (reviewer, 17 gates: 4xx for client errors, param and DTO validation, no internals in error bodies, exception filters that never respond, write-after-read without upsert/atomic update/transaction, transaction client not passed on, unawaited promises, unstable pagination order, missing owner / soft-delete predicate, unescaped `$regex`/`$where`, authorization from client headers, CORS with credentials, `sameSite: 'none'` without `secure`, breaking contract changes, per-instance socket targeting, destructive migrations or hand-written DDL without `IF NOT EXISTS`, boot-time failure on a feature-only env var). The gates that cannot be fully decided from a diff (write-after-read, owner predicate, contract change) carry an explicit escape
- New `profiles/web-common.md` (`#review`): consumer not updated for a contract change in the same change set, client header / `withCredentials` the API's CORS does not allow, env URL without a scheme or env key missing from one environment, exact status-code branch on an endpoint whose mapping changes
- `constraints.md` `#review` (every repo): password / token / webhook URL in a tracked env or config file, or a literal secret fallback → FAIL (`.env.example`-style placeholders and `${VAR}` references pass)
- `detect-profile.sh`: an `api/` or `routes/` path no longer adds `web-api` when the nearest manifest is a frontend-only package (a client `src/api/` folder), except Next.js server routes under `app/api/` or `pages/api/`. `*.sql`, migrations, `*.controller.*` and the new `src/server/` rule always add it (a Next app with Prisma migrations gets the migration gate). With no manifest or a backend manifest nothing changes
- The `web-frontend` profile block is unchanged
- Org profile overlay: `~/.review-harness/org/profiles/<profile>.md` (same `## #tag` format) is appended inside that profile's block under `### Org rules — <profile>`, so organisation rules for a stack load only with it and count as profile bytes. An org file alone does not make a profile valid (unknown public profile still exits 2); with no org file the output is unchanged
- `agents/reviewer.md` and the `#failure-patterns` ledger format: one category list, `correctness | performance | design | scope | security | contract | ops | state-mgmt` (the ledger's `org` category is dropped)

**Fixed**
- `agents/test-runner.md`, `agents/refactor-architect.md`: cwd-relative `bash hooks/...` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks/..."` (the cwd is the consumer repo)
- `run-state.sh override` after `abandon` now starts a fresh idle record, so `check` sees the override (it used to exit 3)
- `run-state.sh` work-tree hash no longer writes blobs into the consumer's `.git/objects`: new objects go to a temp store with the repo's store as alternate. The hash value is unchanged, so recorded PASSes stay valid
- The wisdom folder follows `REVIEW_HARNESS_HOME` (`session-start.sh`, `knowledge-has-content.sh`, `save-knowledge`)
- `extract-constraints.sh` replaces `${CLAUDE_PLUGIN_ROOT}` with the plugin path in its output, as `org-overlay.sh` does
- `state-dir.sh` falls back to `sha1sum`, then `cksum`, when `shasum` is missing, so same-named repos no longer share state
- The session-start knowledge summary prints the first 5 `- **Key**:` lines of `knowledge/index.md` instead of a fixed key list
- Docs that contradicted the code: README (stack support today, `.env*` protection only after `install.sh`), `code-review` (no commit follows a PASS), `CLAUDE.md` handoff (max 6 bullets with `plan_path`), `docs/hooks.md` (Small change exception, hooks auto-discovered), knowledge is optional (no `/setup`), `/rtk` → `/rtk-toggle`, neutral test example in `agents/developer.md`

### v0.5.0 (2026-11-16)

**Focus on code development quality — UI/design-only features removed**
- Removed 5 skills and 2 agents dedicated to UI/design implementation. The remaining workflows are Feature / Small change / Review / Refactor, with 10 skills and 4 agents
- UI requests are classified as `feature`. A design URL is only a reference input written to `plan.md → Inputs.Design` and does not select a workflow
- The `Reuse` item in `plan.md` is filled in by the main session at plan time. If it is empty, reviewer FAILs
- Added reviewer static gates: importing code from another app repo, missing accessible name on an icon-only button, click elements that cannot be operated by keyboard, `.npmrc` staged, raw hex while tokens are wired up, server state kept in Zustand
- Added developer rules: no imports from another app repo, check the Tailwind major version, browser-only imports use `dynamic({ssr:false})`

**Organisation overlay and knowledge moved outside the plugin folder**
- The overlay is read from `~/.front-harness/org/` and knowledge from `~/.front-harness/knowledge/` (changeable with `FRONT_HARNESS_HOME`). The plugin folder contains no organisation-specific files
- Rewrote the README for a generic harness and added a "Preparing knowledge" section. A skill that generates knowledge automatically is planned for 0.6.0

### v0.4.0 (2026-11-16)

**Review gate enforced by a file, not by the conversation**
- `hooks/run-state.sh` + `run-state.json`: records the workflow type, per-step completion, retry count, the reviewer verdict and the work tree hash at review time. Every workflow (including Small change) calls `start` in its first step
- `git-commit` proceeds only when `run-state.sh check` passes: PASS + matching hash, or a recorded user override. If the code changes after the review, a re-review is required. `git add` / commit do not change the hash
- `hooks/commit-gate.sh` (PreToolUse Bash): a safety net that denies `git commit` using the same check. No state file → pass, an active run older than 24 hours → advice only
- Only reviewer records the verdict. If the record is missing, reviewer is spawned once more, and if it is still missing the run is treated as having no verdict (commit stays blocked)
- Reviewer FAIL also counts toward the same `MAX_ATTEMPTS = 3` as test failures. When the limit is reached, the remaining fix list is reported
- If there is an unfinished run, the skill asks "Resume / Start new" at start (`abandon`)

**The plugin creates no files inside the consumer repo**
- Moved `.front-harness-cache/` (rtk flag, approval records, debounce cache) and `plan.md` to `~/.front-harness/state/<repo-id>/` (`hooks/state-dir.sh`, keyed on the absolute path of the work tree, so separated per worktree)
- The rtk mode is stored per work tree, not globally in the plugin directory
- `.front-harness-cache/` / `plan.md` left over in existing repos are not deleted automatically

**Organisation-specific content separated**
- Separated organisation-specific content from the repository; the files in the repository keep only generic rules (`hooks/org-overlay.sh`)

### v0.3.1 (2026-11-16)

- Agent model tiering: reviewer / refactor-architect → `fable`, developer / test-runner stay on `opus`
- Added the `front-harness` Small change path: changes touching 2 or fewer existing files with no new elements are implemented directly by the main session → test-runner → reviewer → git-commit
- `constraints.md #failure-patterns` GC: removed 6 entries older than 90 days. The 2 entries for missing useEffect cleanup / index-as-key were promoted to static gates in `agents/reviewer.md`
- The Small change path skips writing `plan.md` and waiting for approval
- Usage-based model selection: when 5-hour usage is ≥ 80%, ask once before spawning reviewer / refactor-architect (`Keep Fable` / `Opus for this run`), and the choice holds for that run. Shared by `front-harness` / `code-review` / `refactor-scan` (`hooks/usage-state.sh`; usage is written to `~/.claude/usage-state.json` by the status line wrapper). Below 80% or `unknown`, it does not ask and the frontmatter value applies
- `plugin.json` / `marketplace.json` 0.3.1

### v0.3.0 (2026-09-23)

**Hook contract fix — restored 2 feedback loops that had been silently dead**
- `post-tool-use.sh`: was emitting tsc/eslint errors as plain-text stdout + exit 2. Plain-text stdout from PostToolUse is not delivered to Claude (debug log only). → Delivered as `hookSpecificOutput.additionalContext` JSON (encoded with jq/python3). Added detection of ESLint flat config (`eslint.config.{js,mjs,cjs,ts,mts}`) and `.eslintrc.{cjs,yml,yaml}`
- `pre-tool-use.sh`: the "REVIEW REQUIRED" warning was ineffective for the same reason. → Actually blocks with `permissionDecision: deny`. After user approval, `bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-tool-use.sh" --approve <path>` records an approval with a 30-minute TTL → the retry passes. Can be bypassed entirely with `FE_HARNESS_ALLOW_CONFIG_EDITS=1`

**Skill path bug fix**
- Every skill used the cwd-relative path `bash hooks/...` → all of them failed when run from a consumer repo (cwd). Replaced with the absolute path `${CLAUDE_PLUGIN_ROOT}/hooks/...`

**Latest skill spec applied (per code.claude.com/docs/en/skills)**
- `!`cmd`` / ```` ```! ```` dynamic context injection: detect-repo, rtk mode, knowledge presence, `git branch -a`, `git diff --stat`, test framework probe, etc. are inserted automatically at skill load time → saves 2–4 tool calls per skill; the rule "do not re-run detect-repo" is stated explicitly
- `disable-model-invocation: true`: git-branch / git-pr / rtk-toggle (user-driven only; the description is dropped from context, saving tokens)
- `allowed-tools`: pre-approves read-only git commands and plugin hook scripts (removes permission prompts)
- Standardised `argument-hint` and `$ARGUMENTS` passing
- Rewrote descriptions for trigger accuracy (when to fire / when not to / including Korean trigger phrases)
- Removed the dead `**Model**: claude-opus-4-8` line from the body (for a skill model, only the frontmatter field is valid)

**Agents**
- `model: opus` alias (recommended by the docs) + `effort:` + `color:`. Dropped the procedure of editing 7 files on a model bump. The commit trailer is the model-agnostic `Co-Authored-By: Claude <noreply@anthropic.com>`
- Spawn rule stated explicitly: when installed as a plugin, `subagent_type` uses the `front-harness:<agent>` namespace

**Other**
- `plugin.json`: non-standard `knowledge` key → moved to `metadata` (removes the `claude plugin validate` warning), added `displayName`/`keywords`, 0.3.0
- `git-commit`: guard against staging `plan.md` and `.front-harness-cache/`
- `refactor-scan`: runs per slice (≤5 files) + verifies after each slice

### v0.2.0 (2026-07-10)

**Hook wiring repair (previously the hooks were not actually running)**

- `hooks.json`: `$(dirname "$0")` → `${CLAUDE_PLUGIN_ROOT}/hooks/...` (bug where the hook script path was not resolved)
- `pre/post-tool-use.sh`: parse the hook payload from stdin JSON `.tool_input.file_path` (the former `$CLAUDE_TOOL_INPUT` env is the fallback)
- `post-tool-use.sh`: relative-path infinite loop guard, PID-based temp files, `eslint --max-warnings=0`
- `rtk-wrap.sh`: fixed the bug where `npx` was lost in rtk mode (local binary resolution is kept)
- `session-start.sh`: fixed the bug where cache cleanup deleted `rtk-session.flag` every 60 minutes
- `detect-repo.sh`: fixed prefix false positives (`my-app-api` was matched as `my-app`)
- `knowledge-has-content.sh`: BSD grep compatibility + reflects the actual knowledge tree
- `install.sh`: removed the overwrite on settings.json parse failure (loss of the entire settings) + `.bak` backup

**Install method switched — symlinks → proper plugin registration**

- With the symlink method only skills were activated and hooks/agents were not loaded → switched to a 2-step install with `/plugin marketplace add` + `/plugin install`
- Rewrote `install.sh`: removed symlink creation, cleans up old-version links automatically (only after confirming plugin registration — prevents all skills from dying when run before registration), and only handles the settings deny rules + rtk detection + registration guidance
- Added `name`/`owner` fields to `marketplace.json`, `plugin.json` v0.2.0

**Agent structure**

- 7 → 6: merged `api-integrator` into `developer` (removes the loss of context on write handoff = a cause of duplicate code, and also resolves the ordering defect so that API code is written before test-runner)
- Added YAML frontmatter to all agents (`name`/`description`/`model: claude-opus-4-8`/`tools` scoping) — the former `**Model**:` notation in the body was not read by the harness, so the pin was ineffective

**Context diet**

- `#failure-patterns` distilled from 40 entries → 6 (removed duplicates of the reviewer gates/ESLint). Reviewer extract 9.4KB → within budget (8KB)
- Replaced the GC rule from line-count based → byte based (3072B)
- Aligned the tag table with the actual behaviour of extract-constraints.sh

### v0.1.0 (2026-05-27)

**Initial setup**

- Plugin skeleton (`.claude-plugin/`, `agents/`, `skills/`, `hooks/`, `CLAUDE.md`, `constraints.md`)
- Ported 7 agents + 17 skills + 7 hooks (English, token-minimised)
- Pinned all agent models to `claude-opus-4-7`

**Repo context**

- Seeded 21 failure-patterns in `constraints.md`
- New `hooks/detect-repo.sh`: cwd → repo matching
- New skills to register/look up/add entries in the repo registry

**User-Driven Git policy**

- Changed `git-branch` / `git-pr` so they do not run automatically
- Removed the automatic `git-branch → git-commit → git-pr` chain from the workflow chain → `git-commit → [DONE — await user git ops]`
- `/git-branch` first lists existing branches and selects a base (main/stage/production, etc.) → asks for the name → prints the command
- `/git-pr` only generates the body + URL and does not run `gh`
- Removed the `git-issue` skill — on 3 consecutive failures it only reports the context to the user (creating an issue is the user's call)

**codex-review removed**

- Removed the `codex-review` skill — the parallel `[reviewer || codex-review]` gate → simplified to a single `reviewer` gate. All 4 reference sites cleaned up
