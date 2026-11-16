---
name: review-harness
description: Single entry point for code work in a repo — feature/API wiring (UI work included), refactor, or review. Classifies intent, writes plan.md, then orchestrates specialist agents (developer → test-runner → reviewer → git-commit). Use for requests (in any language) like "build this", "add this", "refactor", "review this". Not for git branch/PR creation (use /git-branch, /git-pr).
argument-hint: "[request] [--rtk=off|standard|aggressive|git-only]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*) Bash(git status *) Bash(git diff *) Bash(git branch *) Bash(git log *)
---

# Skill: review-harness

**Trigger**: `/review-harness [request]` — or auto-invoked when a message looks like code work (feature, refactor, review)
**Purpose**: Handle setup, intent detection, planning, execution, verification with minimal context overhead.

---

## Session Context (auto-injected at load — do not re-run these commands)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null || echo "detect-repo unavailable"
```

- rtk mode (resolved): !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" --mode 2>/dev/null || echo off`
- rtk session flag: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" --has-flag 2>/dev/null || echo absent`
- state dir: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/state-dir.sh" --create 2>/dev/null || echo unavailable`
- run state: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" status 2>/dev/null || echo none`
- knowledge: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/knowledge-has-content.sh" 2>/dev/null && echo "has content" || echo "empty — skip search-knowledge"`
- 5h usage: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/usage-state.sh" 2>/dev/null || echo unknown`
- git: branch !`git branch --show-current 2>/dev/null || echo "(no git)"` · uncommitted paths: !`git status --porcelain 2>/dev/null | wc -l | tr -d " "`

Plugin root for every hook call below: `${CLAUDE_PLUGIN_ROOT}` (never a cwd-relative `hooks/…` path — cwd is the consumer repo, not the plugin).

**State dir**: the plugin never creates files inside the consumer repo. `plan.md`, `run-state.json`, the rtk flag, approvals and caches all live in the injected `state dir` (`~/.review-harness/state/<repo-id>/`, one per work tree). Every `plan.md` mentioned in this plugin means `<state dir>/plan.md`.

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
- Active agents only: `developer`, `test-runner`, `reviewer`, `refactor-architect`

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

User can re-run `/rtk` to change mode mid-session.

### 0.5. Unfinished Run Gate

If the injected `run state` line is not `none`, a previous run in this work tree did not finish. Show that line and ask with `AskUserQuestion`: `Resume` | `Start new`.

- `Resume` → continue from the first `pending` step. Do not call `start` again
- `Start new` → run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" abandon`, then proceed as a new request
- A `STALE` run (not updated for over 24h) is asked the same way — the commit hook does not enforce it until the user decides

### 1. Lazy Setup

If `~/.review-harness/knowledge/index.md` is missing, initialize project knowledge there automatically. Do not ask user to run `/setup`.

### 1.5. Active Repo Gate

The `=== Active Repo ===` block is already injected above — do not re-run `detect-repo.sh`. Three branches:

- **Matched** → compact repo block becomes part of agent context. Apply repo-specific rules: path alias, layout (`src/` vs `app/`), env source, Tailwind version
- **Unmatched** AND user request implies code work → ask: "This directory is not registered. Register the repo (see the `hint` line in the Active Repo block), or continue for this task only?"
- **Unmatched** AND user request is generic (e.g. "/review-harness explain yourself") → continue without repo context
- **No Active Repo block at all** (no repo registry installed, no `~/.review-harness/knowledge/<org>/repos.md`) → continue with the generic rules; do not ask

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

Before classifying, check the Small change conditions (Workflow Selection → Small change). If they all hold, take that path; otherwise classify the intent below.

| Intent | Detection | Workflow |
|--------|-----------|----------|
| `feature` | Keywords: `feature`, `add`, `connect`, `API`, `logic`, `build`, `form`, `button`, `page`, `screen`, `component` | Feature flow |
| `refactor` | Keywords: `refactor`, `clean up`, `improve`, `duplicate` | Refactor flow |
| `review` | Keywords: `review`, `check`, `verify` | Review fast-path |

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

**Token budget:**
- Pass API spec only to `developer` — never to others (reviewer sees resulting code, not the spec)
- If URL provided, `developer` fetches only relevant endpoint(s) on demand

### 5. Review Fast-Path

If intent is `review`, **skip Plan Gate entirely**. Spawn `reviewer` directly on current changes. No `plan.md`, no approval wait. Reviewer verdict (PASS/FAIL) is final output; no commit/push follows.

Applies only when intent is exactly `review`.

### 6. Plan Gate

Create `plan.md`, then wait for explicit user approval before execution.

```markdown
# Plan: [task name]

## Goal
[what and why]

## Intent
[feature / refactor / review]

## Inputs
- Design: [reference URL or none]
- API: [spec, endpoint, or none]

## Affected Files
- path/to/file.tsx - [change]

## Design Check
- Reuse: [component/hook/util to reuse, or "none — new primitive justified because X"]
- Responsibility: [how logic splits across files]
- Risk: [conflict with existing pattern, or "none"]

## Execution Steps
- Step 1: [agent] - [task]
- Step 2: [agent] - [task]

## Branch
[feat|fix|ui|refactor]/[task-name]

## Commit Units
- [type]: [description]
```

**Design Check rules**:
- Required for `feature`, `refactor`. Omit for `review`
- Max 1 line per bullet. No prose
- If `Reuse` says "new primitive", justification must be one concrete reason — not vague "for flexibility"
- `Reuse` is filled at plan time by the main session — no agent does it for you. Before writing the plan, search the repo and the shared packages it depends on for an existing component/hook/util that covers the request, and use project knowledge
- `Reuse` must never be empty: name what is reused, or write "none — new primitive justified because X". `reviewer` FAILs a plan whose `Reuse` line is empty
- `developer` reads `plan.md` as the canonical Design Check. The Reuse line is the single source of truth
- Caught design mistakes BEFORE implementation. Read by user during approval and re-read by `reviewer` during design check

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
2. Relevant `constraints.md` and profile sections via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/extract-constraints.sh" <agent-name> web-frontend` — pass its output in the spawn prompt (it carries the constraints, the profile's sections and the agent's org overlay)
3. Minimal `plan.md` excerpt
4. Compact handoff block
5. Exact files needed

### Compact Handoff Schema

```markdown
## Handoff
- plan_path: /abs/path/to/state-dir/plan.md
- changed_files: path1, path2
- reusable_components: Button, Card
- decisions: keep existing filter sidebar pattern
- blockers: cart.spec.ts failing
- test_status: not_run | passed:npm run test | failed:npm run test
```

Rules: omit empty fields, max 6 bullets, one line each, no prose, identifiers/paths/commands preferred. `plan_path` is always the absolute path — agents never look for `plan.md` in the repo.

---

## Workflow Selection

`||` = run in parallel — launch both concurrently and wait for both.

**Run state (first step of EVERY workflow, Small change included)**: before anything else in the chosen workflow, run

```
bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" start <workflow> <step> <step> ...
```

with `<workflow>` = `small-change | feature | refactor | review` and the workflow's steps in order (e.g. `start feature developer test-runner reviewer git-commit`). If it refuses because a run is already active, go back to Request Gate 0.5. Then keep the file current — the script computes every counter, timestamp and hash; never write those values yourself:

- step finished → `run-state.sh step <name>`
- tests failed → `run-state.sh attempt`
- reviewer verdict → recorded by `reviewer` itself with `run-state.sh verdict PASS|FAIL`. Give the reviewer the `plan_path` (when a plan exists) and put this absolute command in its prompt: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" verdict <PASS|FAIL>`. If the reviewer's reply has no `review: … recorded` line, spawn `reviewer` once more to record it. If the line is still missing, treat the run as having no verdict: never record a verdict yourself, stop, and report to the user that the review was not recorded. `git-commit` stays blocked in that state
- last commit made, or a `review` workflow finished → `run-state.sh done`

**Review gate**: `reviewer` is the single quality gate, and it is enforced from the state file, not from the conversation. `git-commit` proceeds only when `run-state.sh check` passes: a recorded PASS whose work-tree hash equals the current work tree, or a recorded user override. FAIL, a missing verdict, or code changed after the review all block the commit; the fix list feeds the retry loop. The `commit-gate.sh` PreToolUse hook denies `git commit` on the same check as a backstop.

### Shared Skip Rules

- Skip `search-knowledge` if knowledge is empty/irrelevant. Use the injected `knowledge:` line (exit != 0 of `knowledge-has-content.sh`) means placeholder-only — skip agent spawn entirely
- Pass `plan.md → Inputs.API` to `developer` only when the change touches data fetching/mutation
- Skip `save-knowledge` if no durable learning

### Small change

Use this path when ALL hold:
- the change touches at most 2 existing files and creates no new file
- it adds no new component, hook, store, endpoint, or socket event
- it is not a `refactor` intent

```
main session implements -> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops]
```

The main session makes the edit itself; spawning `developer` costs more than the change. `reviewer` stays the quality gate, and the org overlay's gates (if installed) apply as usual. If the change grows past the conditions above while you work, stop and switch to the Feature path.

This path skips `plan.md` and the approval wait (Request Gate 6): say in one line what you are about to change, then make the edit.

### Feature

```
search-knowledge? -> developer
-> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops] -> save-knowledge?
```

`developer` owns API integration inline (types → hook/service → UI states) — all code exists before `test-runner` runs, so tests always cover the full change.

### Refactor

```
search-knowledge? -> refactor-architect -> user re-approval
-> developer -> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops] -> save-knowledge?
```

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

Use retry loop for `feature` and `refactor` implementation steps.

```text
MAX_ATTEMPTS = 3   # one shared counter in run-state.json; the script increments it

run implementation agent
run test-runner when applicable
run reviewer

if tests fail:
  run-state.sh attempt
  retry with only the failing error context

if reviewer returns FAIL:
  (run-state.sh verdict FAIL already counted the attempt)
  retry with only the reviewer's fix list

if the script prints "LIMIT REACHED" (exit 2):
  record a repeatable failure pattern if appropriate (append to constraints.md #failure-patterns)
  stop and report full failure context — including the remaining reviewer fix list — to user
  user decides whether to file a GitHub issue manually (plugin does not auto-create issues)
```

Test failures and reviewer FAILs count against the same `MAX_ATTEMPTS`.

Retry context must contain only:
- failing command
- failing file/test identifier
- shortest useful error excerpt, or the reviewer's fix list

Never resend full previous transcript.

---

## Completion

- Never declare completion without test evidence when applicable
- Never move to `git-commit` without reviewer PASS — verified by `run-state.sh check`, not by memory of the conversation
- **Never auto-create branches or PRs** — these are user-driven (see "Git Operations Policy")
- **Never auto-push** — `git push` is the user's action
- Save knowledge only if reusable pattern, decision, or repeatable issue emerged
