# Changelog

This plugin is a rebuild that carries over the Harness Engineering principles of the earlier `front-agent` (a generic React/Next plugin).

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
