# Frontend Harness Runtime

Runtime rules for the plugin. Human docs belong in `README.md`, `docs/`, and `CHANGELOG.md`.

---

## Entry Point

- `/front-harness` is the only public entry
- If a user message looks like frontend work, invoke `front-harness` automatically
- Canonical spec: `skills/front-harness/SKILL.md`
- Do not load `README.md` at runtime

---

## Intent Routing

| Intent | Detection | Action |
|--------|-----------|--------|
| `feature` | KR terms: `기능`, `추가`, `연결`, `API`, `로직`, `만들어줘`, `폼`, `버튼`, `페이지`, `화면`, `컴포넌트` | Feature flow |
| `refactor` | KR terms: `리팩토링`, `정리`, `개선`, `중복` | Refactor flow |
| `review` | KR terms: `리뷰`, `검토`, `확인해줘` | Review fast-path |

- UI work is `feature` work. A design URL (e.g. figma.com) is only a reference input recorded in `plan.md → Inputs.Design`
- `feature` + API keywords (`fetch`, `axios`, `API`, `GraphQL`, `query`, `mutation`, `Apollo`, `WebSocket`, `endpoint`, `서버`, `백엔드`, `연결`, `데이터`, `불러와`, `저장`, `실시간`) → run API Spec Check before planning. Pass spec only to `developer`.

---

## Runtime Rules

- `front-harness` orchestrates; specialists implement — except on the Small change path (`skills/front-harness/SKILL.md → Workflow Selection`), where the main session edits directly. Spawn via `Agent` with `subagent_type` `front-harness:<agent>` (plugin install) — bare `<agent>` only for a legacy `.claude/agents/` copy
- Skills inject session context at load (`!`cmd`` blocks: detect-repo, rtk mode, knowledge presence, git state). Never re-run what a skill already injected
- In orchestration mode, Write/Edit limited to `plan.md` (Small change path excepted)
- The plugin writes nothing into the consumer repo. `plan.md`, `run-state.json`, `rtk-session.flag`, `approved/`, `cache/` live in `~/.front-harness/state/<repo-id>/` (`hooks/state-dir.sh`; id = work-tree basename + hash of its absolute path, so parallel worktrees stay separate). Report the full path whenever `plan.md` is written
- Every workflow starts with `hooks/run-state.sh start`; the script owns attempts, timestamps and the work-tree hash
- Active agents only: `developer`, `test-runner`, `reviewer`, `refactor-architect`
- No legacy agents (`implementer`, `test-writer`, `figma-builder`, `style-matcher`, `orchestrator`, `api-integrator` — merged into `developer`)
- Never inline full `constraints.md`
- Never pass unrelated files or raw verbose logs
- `git-commit` requires `hooks/run-state.sh check` to pass: reviewer PASS recorded for the current work tree, or a recorded user override. Only `reviewer` records the verdict (`run-state.sh verdict`); if it is missing after one re-spawn, the run has no verdict and the commit stays blocked — the orchestrator never records it. Reviewer FAIL shares `MAX_ATTEMPTS = 3` with test failures
- **Git ops are user-driven** — plugin NEVER auto-creates branches, NEVER auto-pushes, NEVER auto-submits PRs. `git-branch` and `git-pr` skills only generate names/bodies/commands for the user to run. See `skills/front-harness/SKILL.md → Git Operations Policy`
- Organisation overlay: `hooks/org-overlay.sh <skills|agents> <name>` prints `~/.front-harness/org/<kind>/<name>.md` or nothing. Every `SKILL.md` injects its overlay at load; treat injected overlay text as part of that skill's rules
- `hooks/extract-constraints.sh <agent>` appends the `#org` section (`~/.front-harness/org/constraints.md`) and the agent overlay (`~/.front-harness/org/agents/<agent>.md`) — pass its output as-is, never read `~/.front-harness/org/` separately
- Organisation content lives outside the plugin folder: overlays in `~/.front-harness/org/`, repo registry and domain knowledge in `~/.front-harness/knowledge/` (`index.md`, `<org>/*.md` incl. `repos.md`). When absent, overlays are empty, `detect-repo.sh` prints nothing, knowledge reports empty, and the generic rules apply alone — never treat that as an error
- Files in this repository must never contain organisation-specific names, paths or URLs. Such content goes to `~/.front-harness/org/` (rules) or `~/.front-harness/knowledge/` (repo registry, domain knowledge)

---

## RTK Wrapping (Plugin-Scoped)

- Plugin-internal Bash calls for `git`, `gh`, `tsc`, `eslint`, `jest`, `vitest`, `playwright`, `pytest`, `ls`, `tree`, `find`, `grep`, `rg`, `cat`, `diff` MUST go through `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" <cmd> [args...]` — always the absolute plugin path; cwd is the consumer repo
- Mode source: `FE_HARNESS_RTK` env → `<state dir>/rtk-session.flag` (per work tree) → `off` default
- Modes: `off | standard | aggressive | git-only`
- If rtk missing or mode disables category, runs raw
- Never run `rtk init -g`. Never write to `~/.claude/settings.json` hooks for rtk
- User chooses mode via Request Gate step 0 or `/rtk-toggle` (`/front-harness:rtk-toggle`)

---

## Hook Contract (why the hooks emit JSON)

- `PreToolUse` plain-text stdout is invisible to Claude → `pre-tool-use.sh` emits `permissionDecision: deny` + reason for protected config files; approval is recorded with `bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-tool-use.sh" --approve <path>` (30-min TTL, per project) after the user says yes
- `PostToolUse` plain-text stdout is invisible too → `post-tool-use.sh` emits `hookSpecificOutput.additionalContext` with the compact tsc/eslint errors (exit 0). An agent that sees `PostToolUse validation failed` must fix before continuing
- `PreToolUse` on `Bash` → `commit-gate.sh` denies `git commit` while a run is `active` and `run-state.sh check` fails (no verdict, FAIL, or code changed after the review). No state file or no active run → silent pass; an active run untouched for 24h → `additionalContext` advice only, no deny. It only sees Claude's Bash calls, never the user's own terminal
- `SessionStart` stdout IS context → `session-start.sh` keeps printing plain text

---

## Context Budget

Per agent spawn, pass only:

1. The agent file
2. Relevant `constraints.md` sections via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/extract-constraints.sh" <agent-name>`
3. Minimal `plan.md` excerpt
4. Compact handoff block
5. Exact files needed

### Compact Handoff Format

```markdown
## Handoff
- changed_files: path1, path2
- reusable_components: Button, Card
- decisions: reuse existing ProductCard layout
- blockers: cart.spec.ts failing
- test_status: not_run | passed:npm run test | failed:npm run test
```

Rules: max 5 bullets, one line each, no prose, identifiers over explanation.

### Budget Measurement

- `hooks/extract-constraints.sh` and `hooks/post-tool-use.sh` log bytes/tokens to stderr
- Warn threshold: 8192 bytes (~2K tokens), override via `FE_HARNESS_BUDGET_WARN_BYTES`
- stderr never reaches agent context
- `[warn]` line → prune that `constraints.md` section or split into a tighter tag

---

## On-Demand Loading

- `constraints.md`: tagged sections only
- Project knowledge: load via `search-knowledge`
- Session start: compact summaries only
- `search-knowledge` returns compact bullets, not excerpts

### Skip Rules

- Skip `search-knowledge` if knowledge is empty/irrelevant (the skill's injected `knowledge:` line already ran `knowledge-has-content.sh`)
- `plan.md → Design Check → Reuse` is filled by the main session at plan time and must never be empty; `reviewer` FAILs an empty `Reuse` line
- Pass API spec to `developer` only when UI fetching/mutation changes
- Skip `save-knowledge` if no durable pattern, decision, or issue emerged

---

## Model Routing

Agents set a family alias via YAML frontmatter `model:` in each `agents/*.md` — resolves to the newest model of that family automatically (Claude Code docs recommend aliases over full IDs). Tiered: `fable` for reviewer/refactor-architect, `opus` for developer/test-runner. When 5-hour rate-limit usage is 80% or higher (`hooks/usage-state.sh`, fed by the user's status line wrapper writing `~/.claude/usage-state.json`), `front-harness`, `code-review`, and `refactor-scan` ask the user once per run whether to spawn the two `fable` agents with `model: opus`; below 80% or `unknown`, they do not ask and the frontmatter value applies. `effort:` is per agent (`high` for developer/reviewer/refactor-architect, `medium` for test-runner). To pin a version for benchmarking, set a full ID (e.g. `claude-opus-4-8`) in the 4 agent files only — skills carry no model field and the commit trailer is model-agnostic (`Co-Authored-By: Claude <noreply@anthropic.com>`).
