---
name: review-harness
description: Single entry point for code work in a repo — feature/API wiring (UI work included), bug fix, refactor, or review. Classifies intent, writes plan.md, then orchestrates specialist agents (developer → test-runner → reviewer → git-commit). Use for requests (in any language) like "build this", "add this", "fix this", "why does this fail", "refactor", "review this". Not for git branch/PR creation (use /git-branch, /git-pr).
argument-hint: "[request] [--rtk=off|standard|aggressive|git-only]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*) Bash(git status *) Bash(git diff *) Bash(git branch *) Bash(git log *)
---

# Skill: review-harness

**Trigger**: `/review-harness [request]` — or auto-invoked when a message looks like code work (feature, bug fix, refactor, review)
**Purpose**: Handle setup, intent detection, planning, execution, verification with minimal context overhead.

---

## Session Context (auto-injected at load — do not re-run these commands)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null || echo "detect-repo unavailable"
```

- rtk mode (resolved): !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" --mode 2>/dev/null || echo off`
- rtk session flag: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" --has-flag 2>/dev/null || echo absent`
- state dir: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/state-dir.sh" --create 2>/dev/null || echo unavailable`
- register: !`[ -f "$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/state-dir.sh" 2>/dev/null)/register-declined" ] && echo declined || echo offer`
- run state: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" status 2>/dev/null || echo none`
- knowledge: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/knowledge-has-content.sh" 2>/dev/null && echo "has content" || echo "empty — skip search-knowledge"`
- 5h usage: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/usage-state.sh" 2>/dev/null || echo unknown`
- git: branch !`git branch --show-current 2>/dev/null || echo "(no git)"` · uncommitted paths: !`git status --porcelain 2>/dev/null | wc -l | tr -d " "`

Plugin root for every hook call below: `${CLAUDE_PLUGIN_ROOT}` (never a cwd-relative `hooks/…` path — cwd is the consumer repo, not the plugin).

**State dir**: the plugin never creates files inside the consumer repo. `plan.md`, `run-state.json`, the rtk flag, the `register-declined` flag, approvals and caches all live in the injected `state dir` (`~/.review-harness/state/<repo-id>/`, one per work tree). Every `plan.md` mentioned in this plugin means `<state dir>/plan.md`.

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills review-harness 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

---

## Canonical Rules

- This file is the canonical runtime workflow
- `README.md` is documentation only — do not load during execution
- Questions, option labels and report text in this skill are written in English. Present them in the user's language
- `review-harness` implements directly only on the Small change path below. Every other workflow goes through the specialist agents.
- In orchestration mode, Write/Edit limited to `plan.md`, `attempts.md` and the `register-declined` flag in the state dir, and the failure-pattern ledger (Small change path excepted)
- Active agents only: `developer`, `test-runner`, `reviewer`, `refactor-architect`
- Run `git`, `grep`/`find` and test commands via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" <cmd> [args...]`

---

## Request Gate

### 0. RTK Mode Gate

Resolve rtk token-filter mode before any agent spawn. Plugin-scoped — no global hook installed.

**Resolution order:**

1. **Inline arg** — if user message contains `--rtk=<mode>` or `--no-rtk`, persist with `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" --set <mode>` (use `off` for `--no-rtk`). Skip UI
2. **Env var** — if `REVIEW_HARNESS_RTK` is set, do nothing. Hard override
3. **Session flag** — if the injected `session flag: present` line says present, reuse the injected mode
4. **Otherwise** (flag absent, no env, no inline arg) — launch `AskUserQuestion`:
   - Q: `Compress command output with rtk for this work?`
   - Options: `Off — raw commands (default)` | `On — standard (Recommended)` | `On — aggressive (+ ultra-compact)` | `On — git-only`
   - After answer, call `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" --set <mode>`

Valid modes: `off | standard | aggressive | git-only`. Reject others with one-line error.

User can run `/rtk-toggle` to change mode mid-session.

### 0.5. Unfinished Run Gate

If the injected `run state` line is not `none`, a previous run in this work tree did not finish. Show that line and ask with `AskUserQuestion`: `Resume` | `Start new`.

- `Resume` → continue from the first `pending` step. Do not call `start` again
- `Start new` → run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" abandon`, then proceed as a new request
- A `STALE` run (not updated for over 24h) is asked the same way — the commit hook does not enforce it until the user decides

### 1. Knowledge (optional)

Project knowledge is optional. If `~/.review-harness/knowledge/index.md` (or `$REVIEW_HARNESS_HOME/knowledge/index.md`) is missing, continue with the generic rules.

### 1.5. Active Repo Gate

The `=== Active Repo ===` block is already injected above — do not re-run `detect-repo.sh`. Three branches:

- **Matched** → compact repo block becomes part of agent context. Apply repo-specific rules: path alias, layout (`src/` vs `app/`), env source, Tailwind version
- **Unmatched** AND user request implies code work → the register offer below
- **Unmatched** AND user request is generic (e.g. "/review-harness explain yourself") → continue without repo context
- **No Active Repo block at all** (no repo registry installed, no `~/.review-harness/knowledge/<org>/repos.md`) → continue with the generic rules; only the register offer below may ask

**Register offer** (applies with or without an org overlay): when the request implies code work, the repo is not registered (`status: not registered`, or no Active Repo block at all) and the injected `register:` line says `offer`, ask once with `AskUserQuestion`: `This repo is not registered. Register it now? (scans the repo, up to 3 questions, writes only after you confirm)` Options: `Register now` | `Continue without registering`. `Register now` → run the `register-repo` skill, then continue the request. `Continue without registering` → create the empty file `<state dir>/register-declined` (Write tool) so this work tree is not asked again, then continue. This is the only registration question in a run: it also answers an unmatched-repo question from an org overlay's bullet, so never ask both. `register: declined` → continue without asking either.

### 2. Ambiguity Check

Ask a clarification question before planning if ANY of:

**Generic ambiguity:**
- Target is unclear
- Scope is overly broad
- Request mixes multiple major tasks
- "Optimize"/"improve" doesn't specify dimension
- **Deictic reference**: user says "that", "this one", "the one above", "that component" (in any language) without a clear referent in this turn → ask "What exactly does X refer to?" Cite candidates from recent context if any

Rules: max 2 questions, only what blocks planning.

### 3. Intent Classification

Before classifying, check the Small change conditions (Workflow Selection → Small change). If they all hold, take that path; otherwise classify the intent below. A request that describes a failure or symptom is `bugfix` and never takes the Small change path; a trivial textual fix with no failure (e.g. "fix this typo") is not `bugfix` and stays on the Small change path. If no intent matches, ask one clarifying question.

| Intent | Detection | Workflow |
|--------|-----------|----------|
| `feature` | Keywords: `feature`, `add`, `connect`, `API`, `logic`, `build`, `form`, `button`, `page`, `screen`, `component`, `endpoint`, `migration`, `schema`, `handler` | Feature flow |
| `refactor` | Keywords: `refactor`, `clean up`, `improve`, `duplicate` | Refactor flow |
| `bugfix` | Keywords: `fix`, `bug`, `error`, `broken`, `fails`, `crash`, `regression`, or a "why" question about a failure | Bugfix flow |
| `review` | Keywords: `review`; `check`, `verify` only when a diff exists to review and no failure symptom is described (a symptom → `bugfix`) | Review fast-path |

Keywords are examples: match the same meaning in whatever language the user writes.

UI work is `feature` work. A design URL in the request (e.g. a figma.com link) is only a reference input: record it in `plan.md → Inputs.Design`. It does not select a workflow, and this plugin gives no design-tool instructions.

### 4. API Spec Check

**Trigger**: intent is `feature` AND request contains API keyword: `fetch`, `axios`, `API`, `GraphQL`, `query`, `mutation`, `Apollo`, `WebSocket`, `endpoint`, `server`, `backend`, `connect`, `data`, `load`, `save`, `realtime` (or the same meaning in the user's language)

If triggered, ask once in user's language:
> "Do you have an API spec? (Swagger/OpenAPI URL, GraphQL schema, a `.md`/`.yaml` file, or paste the endpoint)"

| Response | Action |
|----------|--------|
| URL or file | Record in `plan.md → Inputs.API`; fetch on demand in `developer` only |
| Endpoint/query pasted | Record as-is in `plan.md → Inputs.API` |
| None | Ask: "What request/response shape do you expect?" — record described shape |

**Pasted Contract (any intent, trigger or not)**: a `## Contract` block from the producer repo's run is always the spec — record it as-is in `plan.md → Inputs.API` and ask nothing more.

**Token budget:**
- Pass API spec only to `developer` — never to others (reviewer sees resulting code, not the spec)
- If URL provided, `developer` fetches only relevant endpoint(s) on demand

### 4.5. Web Guidance Search

**Trigger**: a `plan.md` will be written (never on the Small change path or for `review`) AND `detect-profile.sh` on the planned Affected Files includes `web-frontend` AND the change adds or changes UI or client behaviour (markup, CSS/layout, forms, dialogs, tables, a11y, client-side JS such as dates or sanitization) — not 3D/canvas-only, styling-token-only or tooling.

If triggered, before writing `plan.md`, run one visible Bash call per capability, at most 3: `npx -y modern-web-guidance@1.0.1 search "<2–5 word action query>"` (prints `[{id, description}]`). Record the ids that match the change in `plan.md → Inputs.Web guidance`; no match or not triggered → `none`. `npx` missing, the network blocked, permission denied, or any other CLI error or timeout → stop searching at that first one, write `unavailable` and continue. Never ask the user, never retry in a loop. Only `developer` reads guides (`retrieve`); `reviewer` runs `legacy-scan` (`profiles/web-frontend.md`).

### 5. Review Fast-Path

If intent is `review`, **skip Plan Gate entirely**. Spawn `reviewer` directly on current changes. No `plan.md`, no approval wait. Reviewer verdict (PASS/FAIL) is final output; no commit/push follows.

Applies only when intent is exactly `review`.

### 6. Plan Gate

Create `plan.md`, then wait for explicit user approval before execution (Bugfix exception: Workflow Selection → Bugfix).

```markdown
# Plan: [task name]

## Goal
[what and why]

## Done When
- [observable outcome] — check: [test name, command, or manual step]

## Out of Scope
- [what this change leaves untouched]

## Intent
[feature / bugfix / refactor / review]

## Inputs
- Design: [reference URL or none]
- API: [spec, endpoint, or none]
- Web guidance: [guide ids, none, or unavailable]

## Affected Files
- path/to/file.tsx - [change]

## Bug (bugfix only)
- Symptom: [observed vs expected]
- Repro: [failing test id, or command + its key output line]
- Cause: [file:line — why it fails]
- Regression test: [test file + name, or "none — <why none is possible>"]

## Design Check
- Reuse: [component/hook/util to reuse, or "none — new primitive justified because X"]
- Responsibility: [how logic splits across files]
- Risk: [conflict with existing pattern, or "none"]
- Callers/Consumers: [each changed export / route / event → files that use it, or "none — new"]
- Pattern: [one neighbouring file to imitate]
- Tests: [existing test files covering the area; new tests to add]

## Contract (only when another repo may use what changes)
- Producer: [this repo]
- Consumers: [repo → files from find-consumers.sh, or "none — <reason>"]
- Compatibility: [additive | breaking]
- Deploy order: [e.g. producer first; for breaking: consumers updated first, or both together]

## Only When Relevant (omit lines that do not apply)
- Migration: [rollback path; what happens to existing data]
- Dependency upgrade: [breaking changelog items that touch this repo]
- Performance: [how it is measured; target value]

## Execution Steps
- Step 1: [agent] - [task]
- Step 2: [agent] - [task]
- (more than 6 Affected Files) Task 1: [file group] — tests: [that task's test files or command]

## Branch
[feat|fix|ui|refactor]/[task-name]

## Commit Units
- [type]: [description]
```

**Design Check rules**:
- Required for `feature`, `bugfix`, `refactor`. Omit for `review`
- Max 1 line per bullet. No prose
- If `Reuse` says "new primitive", justification must be one concrete reason — not vague "for flexibility"
- `Reuse` is filled at plan time by the main session — no agent does it for you. Before writing the plan, search the repo and the shared packages it depends on for an existing component/hook/util that covers the request, and use project knowledge
- `Reuse` must never be empty: name what is reused, or write "none — new primitive justified because X". `reviewer` FAILs a plan whose `Reuse` line is empty
- `Callers/Consumers`, `Pattern`, `Tests` are also filled by the main session before approval, from grep (not memory). `Callers/Consumers` names every file that uses each changed exported symbol, route or event; a file the change will leave alone gets `no change needed: <reason>` — `reviewer` FAILs a listed file that is neither changed nor marked
- More than 6 Affected Files → `Execution Steps` become ordered `Task N` lines (file group + that task's tests); `developer` runs each task's tests before the next
- `developer` reads `plan.md` as the canonical Design Check. The Reuse line is the single source of truth
- Caught design mistakes BEFORE implementation. Read by user during approval and re-read by `reviewer` during design check

**Done When / Out of Scope rules**: required for `feature`, `bugfix`, `refactor`; omit for `review`. `Done When` lists 2–5 observable outcomes (behavior a user, caller or test sees — not "code written"), each with its check: a test name, a command, or a manual step. `Out of Scope` is 1–2 lines naming what the change must not touch. `reviewer` checks both.

**Contract rules**: write `## Contract` only when the change adds, changes or removes a route, socket event or request/response field another repo may use. `breaking` = renamed, removed, type changed, a response field made optional/nullable, a new required request field, or an existing optional request field made required (a request field made optional is not breaking). For `breaking`, run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/find-consumers.sh" <term...>` from the repo root with every renamed, removed, retyped, now-optional or now-required field, route and event; it greps the other registered repos — list the hits per repo under `Consumers`. A consumer repo this run does not change gets its follow-up named in `Out of Scope`. `reviewer` FAILs a breaking contract with no consumers listed. The producer run goes first; the consumer repo's run takes this block as its `Inputs.API` (Completion).

**Only When Relevant**: write a line only when the change has that part (a schema or data migration, a dependency version bump, a performance goal); otherwise omit the section. No new intent for these.

`plan.md` is a working artifact: write it to `<state dir>/plan.md`, never to the consumer repo. Every time you write or update it, tell the user its full absolute path in one line.

Ask: `Please review <absolute path of plan.md>. Approve it and I will execute.`

---

## Agent Spawning

Spawn specialists with the `Agent` tool. When installed as a plugin, the `subagent_type` is namespaced: `review-harness:developer`, `review-harness:reviewer`, etc. If the namespaced type is not listed (legacy `.claude/agents/` copy), fall back to the bare name. Never re-implement an agent's role inline because the type was not found — report it.

**Usage downgrade**: the injected `5h usage` line reads `N% (resets HH:MM)` or `unknown`.

- If N is 80 or higher, ask once with `AskUserQuestion` before the first `reviewer` or `refactor-architect` spawn. Put the current usage N% and the reset time in the question. Options: `Keep Fable` | `Opus for this run`
- Keep the answer until this skill run ends, including skills it chains into. Do not ask again per spawn
- `Opus for this run` → spawn both agents with the Agent tool's `model: "opus"` parameter (it overrides the agent's frontmatter). `Keep Fable` → pass no `model`
- If N is below 80 or the value is `unknown`, do not ask; pass no `model` so the frontmatter value applies

## Context Budget

Per agent call, include only:

1. The relevant `agents/*.md`
2. Relevant `constraints.md` and profile sections via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/extract-constraints.sh" <agent-name> "$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-profile.sh" <paths>)"`, where `<paths>` = the plan's Affected Files for developer / refactor-architect and nothing for reviewer / test-runner (current changes) — pass its output in the spawn prompt as-is (it carries the constraints, the selected profiles' sections and the agent's org overlay); never read `~/.review-harness/org/` separately
3. Minimal `plan.md` excerpt — for `test-runner`, include the `Done When` test/command checks (or the Small change `Done when:` check) so it runs them
4. Compact handoff block
5. Exact files needed

Never inline full `constraints.md`. Never pass unrelated files or raw verbose logs.

### Compact Handoff Schema

```markdown
## Handoff
- plan_path: /abs/path/to/state-dir/plan.md
- changed_files: path1, path2
- reusable_components: Button, Card
- decisions: keep existing filter sidebar pattern
- blockers: cart.spec.ts failing
- test_status: not_run | passed:npm run test | failed:npm run test
- red: <regression test's failing output line before the fix> (bugfix only)
- assumptions: <what developer assumed where the plan was silent> (developer only)
- root cause: <file:line — why the last change did not fix it> (developer, when the same test or issue fails again)
- self-check: <rule hit → fixed>; … | clean (developer only)
- guidance: <id> applied | <id> not applied — <reason> (developer only, when Inputs.Web guidance lists ids)
```

Rules: omit empty fields, max 6 bullets plus `red:` for bugfix, `assumptions:`, `root cause:`, `self-check:` and `guidance:`, one line each, no prose, identifiers/paths/commands preferred. `plan_path` is always the absolute path — agents never look for `plan.md` in the repo.

---

## Workflow Selection

`||` = run in parallel — launch both concurrently and wait for both.

**Run state (first step of EVERY workflow, Small change included)**: before anything else in the chosen workflow, run

```
bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" start <workflow> <step> <step> ...
```

with `<workflow>` = `small-change | feature | bugfix | refactor | review` and the workflow's steps in order (e.g. `start feature baseline developer test-runner reviewer git-commit`). If it refuses because a run is already active, go back to Request Gate 0.5. Then keep the file current — the script computes every counter, timestamp and hash; never write those values yourself:

- step finished → `run-state.sh step <name>`
- tests failed → `run-state.sh attempt`
- reviewer verdict → recorded by `reviewer` itself with `run-state.sh verdict PASS|FAIL`. Give the reviewer the `plan_path` (when a plan exists) and put this absolute command in its prompt: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" verdict <PASS|FAIL> [FAIL issue categories...] --by reviewer`. If the reviewer's reply has no `review: … recorded` line, spawn `reviewer` once more to record it. If the line is still missing, treat the run as having no verdict: never record a verdict yourself, stop, and report to the user that the review was not recorded. `git-commit` stays blocked in that state
- test result → recorded by `test-runner` itself: put `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" tests <pass|fail|none>` in its prompt (not in the baseline run)
- last commit made, or a `review` workflow finished → `run-state.sh done`

**Review gate**: `reviewer` is the single quality gate, and it is enforced from the state file, not from the conversation. `git-commit` proceeds only when `run-state.sh check` passes: a recorded PASS whose work-tree hash equals the current work tree and no blocking test result, or a recorded user override. FAIL, a missing verdict, code changed after the review or after the last test run, a `tests fail`, or a `tests none` the user has not confirmed all block the commit; the fix list feeds the retry loop. The `commit-gate.sh` PreToolUse hook denies `git commit` on the same check as a backstop.

**Test baseline** (`feature`, `bugfix`, `refactor`): before `developer`, spawn `test-runner` with `mode: baseline`. It writes the already-failing tests to `<state dir>/baseline.txt`, and later runs count only new failures. If it lists any, tell the user in one line: `N tests already fail before this change: <ids> — they do not count against it.` Then `run-state.sh step baseline` (also on `no_tests_configured`). A bugfix's regression test appears there only if it already exists.

**No tests** (`test-runner` reports `no_tests_configured`): after reviewer PASS, show the user the `Done When` manual steps (Small change: the `Done when:` check) with the test-runner's command results, and ask with `AskUserQuestion`: `Checked — commit` | `Not yet`. Record `run-state.sh tests manual-confirmed` only after the user explicitly says yes; otherwise stop before `git-commit`.

### Shared Skip Rules

- Skip `search-knowledge` if knowledge is empty/irrelevant. Use the injected `knowledge:` line (exit != 0 of `knowledge-has-content.sh`) means placeholder-only — skip agent spawn entirely
- Pass `plan.md → Inputs.API` to `developer` only when the change touches data fetching/mutation
- Pass the developer's `guidance:` line to `reviewer` when `Inputs.Web guidance` lists ids (any intent, like a bugfix's `red:`)
- Skip `save-knowledge` if no durable learning

### Small change

Use this path when ALL hold:
- the change touches at most 2 existing files and creates no new file
- it adds no new component, hook, store, endpoint, or socket event
- it is not a `refactor` or `bugfix` intent

```
main session implements -> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops]
```

The main session makes the edit itself; spawning `developer` costs more than the change. `reviewer` stays the quality gate, and the org overlay's gates (if installed) apply as usual. If the change grows past the conditions above while you work, stop and switch to the Feature path.

This path skips `plan.md` and the approval wait (Request Gate 6): say in one line what you are about to change and one `Done when: <observable outcome> — check: <test, command, or manual step>` line, then make the edit. Put that `Done when:` line in the `reviewer` prompt.

It also has no test baseline: a test that already failed before the edit counts as a failure and blocks the commit. Tell the user which tests fail and that they may predate the edit; only the user can choose an override (`run-state.sh override <reason>`).

### Feature

```
search-knowledge? -> test-runner (baseline) -> developer
-> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops] -> save-knowledge?
```

`developer` owns API integration inline (types → hook/service → UI states) — all code exists before `test-runner` runs, so tests always cover the full change.

### Bugfix

```
reproduce -> plan.md (## Bug) -> user approval
-> test-runner (baseline) -> developer (regression test RED, then fix) -> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops] -> save-knowledge?
```

Run state: `start bugfix reproduce baseline developer test-runner reviewer git-commit`.

- **Reproduce first**: run the failing test, or a command that shows the failure (request, script, CLI), and record it in `Repro`. Then trace it to `Cause` (`file:line` + why). If neither reproduces it, stop and ask the user for the exact symptom and environment (input, logs, version). Never fix by guess
- **Fix of at most 2 files**: skip the approval wait, but show the user the `Cause` and `Regression test` lines before `developer` starts. The plan is still written
- **"Why" only**: if the user asked why but not for a fix, stop after `Cause`, report the `## Bug` lines and ask whether to fix (`run-state.sh done` if not)
- If `developer` reports the regression test passing before the fix, the `Cause` is wrong: run `run-state.sh attempt` (stop and report at `LIMIT REACHED`), then redo reproduce — run state still shows `reproduce` done; redo it anyway
- Pass the developer's `red:` line to `reviewer`

### Refactor

```
search-knowledge? -> refactor-architect -> user re-approval
-> test-runner (baseline) -> developer -> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops] -> save-knowledge?
```

If the user waives the characterization-test step at re-approval, remove it from `plan.md` and add `Characterization tests: waived by user — <reason>` under `## Risk`.

### Review

Fast-path: bypasses Plan Gate (see Request Gate step 5).

```
reviewer -> run-state.sh done
```

---

## Git Operations Policy (USER-DRIVEN)

The plugin does **NOT** auto-create branches or submit PRs. Both are the user's explicit action.

| Operation | Plugin behavior |
|-----------|-----------------|
| **Branch create** | User invokes `/git-branch` or asks naturally. Plugin: (1) **lists existing branches** via `git branch -a` (read-only), (2) asks user which **base branch** to fork from via `AskUserQuestion` (main / stage / production / etc.), (3) asks for the new branch name, (4) prints `git checkout -b <name>` (or `origin/<base>` variant). **Never executes.** |
| **Commit** | Auto-chained after reviewer PASS (current behavior) — produces Conventional Commit |
| **Push** | **Never auto-pushes.** User pushes themselves |
| **PR create** | User invokes `/git-pr` or asks naturally. Plugin generates title + body + copy-pasteable `gh pr create` command + prefilled GitHub compare URL. **Never executes `gh`.** |

### Trigger phrases (any language)

| User says | Plugin action |
|-----------|---------------|
| "create a branch" / `/git-branch` | Run `git-branch` skill (ask name, print command) |
| "create a PR" / "write the PR body" / "get the PR ready" / `/git-pr` | Run `git-pr` skill (generate body + URL) |
| "push it" | Refuse politely — push is the user's action. Plugin can show the suggested command but does not run it |

After the workflow chain reaches `[DONE]`, the plugin reports:

```
✅ Implementation + review complete.

Next steps (user-driven):
- No branch yet: run `/git-branch` to create one
- Ready for a PR: run `/git-pr`
- Push yourself: `git push -u origin <branch-name>`
```

---

## Harness Loop

Use retry loop for `feature`, `bugfix` and `refactor` implementation steps (Small change: the main session is the implementer).

```text
MAX_ATTEMPTS = 3   # one shared counter in run-state.json; the script increments it

run implementation agent
run test-runner when applicable
run reviewer

every failed attempt (tests or reviewer FAIL; not a dispute re-judge):
  append one line to `## Attempts` in plan.md (no plan: <state dir>/attempts.md):
    N. hypothesis → change → result   # what the attempt assumed, what it changed, which test/issue failed

if tests fail:
  run-state.sh attempt
  retry with only the failing error context

if reviewer returns FAIL:
  (run-state.sh verdict FAIL already counted the attempt)
  act on each issue's route:
    replan -> update plan.md for it and get the user's re-approval before the retry
              (Small change: no plan — ask the user, or switch to the Feature path)
    patch  -> retry with only the patch / replan issues as the fix list
    defer  -> never retried; keep for the final report

if developer answers `dispute: <issue id> — <evidence>` instead of patching (no code change):
  run-state.sh dispute <issue id...>   # exit 2: this round's dispute is used — retry with the fix list
  re-run reviewer with the dispute lines; its verdict is not an attempt
  an issue it keeps goes back into the fix list and cannot be disputed again

if the script prints "LIMIT REACHED" (exit 2):
  record a repeatable failure pattern if appropriate (append to the `ledger:` path from extract-constraints.sh,
    in the entry format and scope of agents/reviewer.md step 5; a new file starts with `## #failure-patterns`)
  stop and report full failure context — including the remaining reviewer fix list — to user
  if the same test or issue failed in every attempt, ask the user whether the plan is wrong:
    Replan -> revise plan.md, re-approval, then run-state.sh abandon and start a new run
              (Small change: no plan — ask the user, or switch to the Feature path)
    Stop   -> end here
  user decides whether to file a GitHub issue manually (plugin does not auto-create issues)
```

Test failures and reviewer FAILs count against the same `MAX_ATTEMPTS`; disputes do not.

Every retry runs `test-runner` again before `reviewer`, on the Small change path too: the tests record holds only for the work tree it was taken on. Only the dispute re-judge, which changes no code, skips it.

Retry context must contain only:
- failing command
- failing file/test identifier
- shortest useful error excerpt, or the reviewer's `patch` / `replan` issues
- the Attempts lines so far, so the retry does not repeat an idea that already failed; on the second failure of the same test or issue the developer gives `root cause:` before editing
- bugfix: the first developer run's `red:` line — carry it through every retry so a re-spawned developer's handoff, and the `reviewer` prompt, never drop it; the same for the developer's `guidance:` line whenever `Inputs.Web guidance` lists ids (any intent)

Never resend full previous transcript.

---

## Completion

- Never declare completion without test evidence when applicable
- Never move to `git-commit` without reviewer PASS — verified by `run-state.sh check`, not by memory of the conversation
- **Never auto-create branches or PRs** — these are user-driven (see "Git Operations Policy")
- **Never auto-push** — `git push` is the user's action
- Save knowledge only if reusable pattern, decision, or repeatable issue emerged
- List the reviewer's `defer` issues in the final report (also at `LIMIT REACHED`)
- A plan with `## Contract`: end the final report with that block verbatim and one line asking the user to paste it into the consumer repo's `/review-harness` run, which records it as `Inputs.API`
