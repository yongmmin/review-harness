---
name: review-harness
description: Single entry point for code work in a repo — feature/API wiring (UI work included), bug fix, refactor, or review. Classifies intent, writes plan.md, then orchestrates specialist agents (developer → test-runner → reviewer → git-commit). Use for requests (in any language) like "build this", "add this", "fix this", "why does this fail", "refactor", "review this". Not for git branch/PR creation (use /git-branch, /git-pr).
argument-hint: "[request] [--rtk=off|standard|aggressive|git-only]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*) Bash(git status *) Bash(git diff *) Bash(git branch *) Bash(git log *)
---

# Skill: review-harness

**Trigger**: `/review-harness [request]` — or auto-invoked when a message looks like code work (feature, bug fix, refactor, review)
**Purpose**: setup, intent detection, planning, execution and verification at minimal context cost.

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
- git: branch !`git branch --show-current 2>/dev/null || echo "(no git)"` · uncommitted paths: !`git status --porcelain 2>/dev/null | wc -l | tr -d " "`

Plugin root for every hook call below: `${CLAUDE_PLUGIN_ROOT}` (never a cwd-relative `hooks/…` path — cwd is the consumer repo, not the plugin).

**State dir**: the plugin never creates files in the consumer repo; `plan.md`, `run-state.json`, flags, approvals and caches live in the injected `state dir` (one per work tree). Every `plan.md` here means `<state dir>/plan.md`.

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills review-harness 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

---

## Canonical Rules

- This file is the canonical runtime workflow; `README.md` is documentation only
- Questions, option labels and report text in this skill are written in English. Present them in the user's language
- `review-harness` implements directly only on the Small change path below. Every other workflow goes through the specialist agents: `developer`, `test-runner`, `reviewer`, `refactor-architect`
- In orchestration mode, Write/Edit limited to `plan.md`, `attempts.md` and the `register-declined` flag in the state dir, and the failure-pattern ledger (Small change path excepted)
- Run `git`, `grep`/`find` and test commands via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" <cmd> [args...]`. The request carries `--rtk=<off|standard|aggressive|git-only>` or `--no-rtk` → persist it first with `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" --set <mode>` (use `off` for `--no-rtk`; reject any other mode with a one-line error); otherwise the injected mode applies and nothing is asked
- Files read through a `→ read` pointer below are read raw: replace the `CLAUDE_PLUGIN_ROOT` variable in them with the plugin root named in Session Context.

---

## Request Gate

### 1. Unfinished Run Gate

If the injected `run state` line is not `none`, a previous run in this work tree did not finish. Show that line and ask with `AskUserQuestion`: `Resume` | `Start new`.

- `Resume` → run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" resume`, then continue from the first `pending` step. Do not call `start` again
- `Start new` → run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" abandon`, then proceed as a new request
- A `STALE` run (not updated for over 24h) is asked the same way — the commit hook does not enforce it until the user decides

### 2. Active Repo Gate

The `=== Active Repo ===` block is already injected above — do not re-run `detect-repo.sh`. Matched → the block (stack, layout, path alias, commands) is part of agent context. With no block or no match, continue with the generic rules.

The request implies code work and the repo is not registered (`status: not registered`, or no Active Repo block at all) → read `${CLAUDE_PLUGIN_ROOT}/skills/review-harness/register-offer.md` before asking anything in this step

### 3. Intent

| Intent | When | Workflow |
|--------|------|----------|
| `review` | a diff to judge, and no failure described | Review fast-path: no `plan.md`, no approval wait, no commit — the reviewer's PASS/FAIL verdict is the final output |
| `bugfix` | the request describes a failure or symptom, or asks why something fails | Bugfix flow — never the Small change path |
| `refactor` | restructuring with no behaviour change | Refactor flow |
| `feature` | any other change, UI work included | Feature flow, or the Small change path when all its conditions hold |

A trivial textual fix with no failure (e.g. "fix this typo") is not `bugfix`. When what to change or where is unclear, ask before planning: max 2 questions, only what blocks planning.

### 4. Plan Gate

Intent is `feature`, `bugfix` or `refactor` and the Small change path is not taken → read `${CLAUDE_PLUGIN_ROOT}/skills/review-harness/plan-gate.md` before writing or updating `plan.md`

Create `plan.md`, then wait for explicit user approval before execution (Bugfix exception: Workflow Selection → Bugfix).

The change calls an API whose request/response shape you do not have, or the request carries a pasted `## Contract` block → read `${CLAUDE_PLUGIN_ROOT}/skills/review-harness/api-spec.md` before recording `plan.md → Inputs.API`

---

## Agent Spawning

Spawn specialists with the `Agent` tool. When installed as a plugin, the `subagent_type` is namespaced: `review-harness:developer`, `review-harness:reviewer`, etc. If the namespaced type is not listed (legacy `.claude/agents/` copy), fall back to the bare name. Never re-implement an agent's role inline because the type was not found — report it.

**Developer effort**: before each `developer` spawn, run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/risk-tier.sh" --paths <plan Affected Files>`. `low` → spawn `developer` with `effort: "medium"`; `normal`, `high` or a script failure → no override. A `bugfix` plan never gets this override (root-cause work).

**Risk tier**: before each `reviewer` spawn, run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/risk-tier.sh" [base]` (the base only when the change is committed) and put its output in the reviewer prompt as `risk: <tier>` plus its `reason:` lines; the script fails → `risk: normal`. `low` → spawn `reviewer` with `model: "opus"` and `effort: "medium"`; `normal` and `high` → no override (`high`: the reviewer runs probes).

## Context Budget

Per agent call, include only:

1. The output of `bash "${CLAUDE_PLUGIN_ROOT}/hooks/extract-constraints.sh" <agent-name> "$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-profile.sh" <paths>)"`, where `<paths>` = the plan's Affected Files for developer / refactor-architect and nothing for reviewer / test-runner (current changes) — pass its output in the spawn prompt as-is (it carries the constraints, the selected profiles' sections and the agent's org overlay); never read `~/.review-harness/org/` separately
2. Minimal `plan.md` excerpt — for `test-runner`, include the `Done When` test/command checks (or the Small change `Done when:` check) so it runs them. Pass `plan.md → Inputs.API` to `developer` only when the change touches data fetching/mutation
3. Compact handoff block
4. Exact files needed

Never inline full `constraints.md`, unrelated files or raw verbose logs.

### Compact Handoff Schema

```markdown
## Handoff
- plan_path: /abs/path/to/state-dir/plan.md
- changed_files: path1, path2
- decisions: keep existing filter sidebar pattern
- blockers: cart.spec.ts failing
- test_status: not_run | passed:npm run test | failed:npm run test
- red: <regression test's failing output line before the fix> (bugfix only)
- assumptions: <what developer assumed where the plan was silent> (developer only)
- root cause: <file:line — why the last change did not fix it> (developer, when the same test or issue fails again)
- self-check: <rule hit → fixed>; … | clean (developer only)
```

Rules: omit empty fields, one line each, no prose, identifiers/paths/commands preferred. `plan_path` is always the absolute path — agents never look for `plan.md` in the repo.

---

## Workflow Selection

**Run state (first step of EVERY workflow, Small change included)**: before anything else in the chosen workflow, run

```
bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" start <workflow> <step> <step> ...
```

with `<workflow>` = `small-change | feature | bugfix | refactor | review` and the workflow's steps in order (e.g. `start feature baseline developer test-runner reviewer git-commit`). If it refuses because a run is already active, go back to Request Gate 1. Then keep the file current — the script computes every counter, timestamp and hash; never write those values yourself:

- step finished → `run-state.sh step <name>`
- tests failed → `run-state.sh attempt`
- reviewer verdict → recorded by `reviewer` itself with `run-state.sh verdict PASS|FAIL`. Give the reviewer the `plan_path` (when a plan exists) and put this absolute command in its prompt: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" verdict <PASS|FAIL> [FAIL issue categories...] --by reviewer`. If the reviewer's reply has no `review: … recorded` line, spawn `reviewer` once more to record it. If the line is still missing, treat the run as having no verdict: never record a verdict yourself, stop, and report to the user that the review was not recorded. `git-commit` stays blocked in that state
- test result → recorded by `test-runner` itself: put `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" tests <pass|fail|none>` in its prompt (not in the baseline run)
- last commit made, or a `review` workflow finished → `run-state.sh done`

**Review gate**: `git-commit` proceeds only when `run-state.sh check` passes; the `commit-gate.sh` PreToolUse hook denies `git commit` on the same check. The state file decides, never your memory of the conversation, and a FAIL's fix list feeds the retry loop.

**Test baseline** (`feature`, `bugfix`, `refactor`): before `developer`, spawn `test-runner` with `mode: baseline`. It writes the already-failing tests to `<state dir>/baseline.txt`, and later runs count only new failures. If it lists any, tell the user in one line: `N tests already fail before this change: <ids> — they do not count against it.` Then `run-state.sh step baseline` (also on `no_tests_configured`). A bugfix's regression test appears there only if it already exists.

**No tests** (`test-runner` reports `no_tests_configured`): after reviewer PASS, show the user the `Done When` manual steps (Small change: the `Done when:` check) with the test-runner's command results, and ask with `AskUserQuestion`: `Checked — commit` | `Not yet`. Record `run-state.sh tests manual-confirmed` only after the user explicitly says yes; otherwise stop before `git-commit`.

Skip `search-knowledge` when the injected `knowledge:` line says empty or the knowledge is irrelevant; run `save-knowledge` only when a reusable pattern, decision or repeatable issue emerged.

### Small change

Use this path when ALL hold:
- the change touches at most 3 files, of which at most 1 is a new test file and the rest already exist
- it adds no new component, hook, store, endpoint, or socket event
- it is not a `refactor` or `bugfix` intent

All three hold → read `${CLAUDE_PLUGIN_ROOT}/skills/review-harness/small-change.md` before `run-state.sh start` or any Small change step

### Feature

```
search-knowledge? -> test-runner (baseline) -> developer
-> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops] -> save-knowledge?
```

### Bugfix

Intent is `bugfix` → read `${CLAUDE_PLUGIN_ROOT}/skills/review-harness/bugfix.md` before `run-state.sh start` or any Bugfix step

### Refactor

```
search-knowledge? -> refactor-architect -> user re-approval
-> test-runner (baseline) -> developer -> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops] -> save-knowledge?
```

If the user waives the characterization-test step at re-approval, remove it from `plan.md` and add `Characterization tests: waived by user — <reason>` under `## Risk`.

### Review

```
reviewer -> run-state.sh done
```

---

## Harness Loop

Use retry loop for `feature`, `bugfix` and `refactor` implementation steps (Small change: the main session is the implementer).

Tests fail, `reviewer` returns FAIL, `developer` reports an issue as `wrong:`, or `run-state.sh` prints `LIMIT REACHED` → read `${CLAUDE_PLUGIN_ROOT}/skills/review-harness/retry.md` before the retry or the stop report

---

## Completion

- Never declare completion without test evidence when applicable
- Never move to `git-commit` without reviewer PASS — verified by `run-state.sh check`, not by memory of the conversation
- **Never auto-create branches or PRs, never auto-push** — after `[DONE]`, report `Implementation + review complete` and name the user's next steps: `/git-branch`, `/git-pr`, or `git push -u origin <branch-name>`
- List the reviewer's `defer` issues in the final report (also at `LIMIT REACHED`)
- A plan with `## Contract`: end the final report with that block verbatim and one line asking the user to paste it into the consumer repo's `/review-harness` run, which records it as `Inputs.API`
