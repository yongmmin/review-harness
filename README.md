# review-harness

[![test](https://github.com/yongmmin/review-harness/actions/workflows/test.yml/badge.svg)](https://github.com/yongmmin/review-harness/actions/workflows/test.yml)
[![version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Fyongmmin%2Freview-harness%2Fmain%2F.claude-plugin%2Fplugin.json&query=%24.version&label=version)](CHANGELOG.md)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-d97757)](https://docs.claude.com/en/docs/claude-code/plugins)

**Claude Code writes the code. A second agent has to approve it before it can be committed.**

```
/plugin marketplace add yongmmin/review-harness
/plugin install review-harness@review-harness
/review-harness add a status filter to GET /orders
```

A review-gated coding harness for Claude Code. You give it one line — `/review-harness "what you want"` — and it hands plan → implement → test → review to specialist agents (developer / test-runner / reviewer / refactor-architect), and only lets a change be committed after the reviewer returns PASS. The workflow and the review gate are stack-neutral. Stack-specific rules live in profiles (`profiles/<name>.md`), and each run picks the profiles from the files the change touches; three ship today — `web-frontend` (TypeScript, React, Next.js), `web-api` (API servers such as NestJS, Express or FastAPI, with their ORM and migrations) and `web-common` (a change that touches frontend and API code together). Other stacks run on the generic rules, and you can add rules for your own stack with an overlay. The test step finds JavaScript, Python, Go and Rust test commands, or the `test_cmd` you register for a repo. Organisation-specific knowledge (repo structure, internal conventions) is not part of the plugin; each user prepares it on their own machine.

How it keeps the first review passing and the review honest:

- **The developer sees the reviewer's rules.** It gets the review checklist and your past failure patterns, and checks its own diff before handoff with two scripts: `static-gates.sh` (grep-decidable rules such as `console.log`, `.env` files, secret fallbacks) and `review-context.sh` (changed symbols and every file that calls them).
- **Review strength follows risk.** `risk-tier.sh` scores each change. A small or docs-only change gets a cheaper reviewer. A risky one (auth, payment, migrations, concurrency, hooks/CI, 10+ files) makes the reviewer run executable probes instead of only reading code.
- **The commit gate is a hook.** It is not a promise in a prompt. See [Rules you need to know](#rules-you-need-to-know).
- **Every run is measured**: first-review PASS rate, retries, and tokens and time per agent. See [Measuring runs](#measuring-runs).

## Install / Update

**Quick install.** Run this inside a Claude Code session; no clone is needed:

```
/plugin marketplace add yongmmin/review-harness
/plugin install review-harness@review-harness
```

Open a new session, and `/plugin` lists it. To update later, follow **Update** below. The steps below are the manual route. They also add `.env*` edit protection to your global settings.

**1. Clone and bootstrap**

```bash
git clone https://github.com/yongmmin/review-harness.git ~/claude-plugins/review-harness
cd ~/claude-plugins/review-harness
chmod +x install.sh && ./install.sh
```

`install.sh` adds `.env*` protection rules to `~/.claude/settings.json` (it writes a `.bak` backup first) and prints the commands for the next step.

**2. Register the plugin (required)** — inside a Claude Code session:

```
/plugin marketplace add ~/claude-plugins/review-harness
/plugin install review-harness@review-harness
```

Hooks and agents are only active after this step. Open a new session and check with `/plugin`.

**Update** — the marketplace is registered from a local directory, so it does not update automatically:

```bash
cd ~/claude-plugins/review-harness && git pull
claude plugin marketplace update review-harness
claude plugin update review-harness@review-harness
```

Apply it to an open session with `/reload-plugins`. `jq` is required for the review gate and the usage display; `rtk` is optional. Details: [docs/hooks.md](docs/hooks.md).

## Preparing knowledge

With only the plugin installed, it runs on generic rules. To make it aware of your organisation's repos and conventions, create the two folders below yourself. Both live outside the plugin folder, so they never end up in git.

| Location | Content |
|---|---|
| `~/.review-harness/knowledge/index.md` | Overview summarised at session start |
| `~/.review-harness/knowledge/<org>/repos.md` | Repo registry, used to match the current directory to a repo (with several org folders, each is read in sorted order; the first match wins) |
| `~/.review-harness/knowledge/<org>/*.md` | Domain knowledge (architecture, conventions, …) |
| `~/.review-harness/org/skills/<skill>.md` | Organisation rules appended to a skill |
| `~/.review-harness/org/agents/<agent>.md` | Organisation rules appended to an agent |
| `~/.review-harness/org/constraints.md` | A `## #org` section appended to agent constraints |
| `~/.review-harness/org/categories.txt` | Extra reviewer FAIL categories for the run log, one `[a-z-]+` word per line |
| `~/.review-harness/org/profiles/<profile>.md` | Organisation rules for one profile, in the same `## #tag` format; loaded only when that profile is selected, inside its block |

To register a repo, run `/register-repo` inside it: it scans the repo's manifests (stack, layout, path alias, test and check commands), asks up to 3 questions (role, commands, team rules) and appends the block to `repos.md` only after you confirm. `/review-harness` offers it once per work tree when the repo is not registered. The other files are written by hand. `repos.md` holds one block per repo in this format:

```markdown
### my-app
- **local_path**: `/absolute/path/to/my-app`
- **role**: one-line description
- **layout**: `src/`
- **test_cmd**: `make test`
- **check_cmd**: `ruff check .`
```

`test_cmd` and `check_cmd` are optional. `test_cmd` is the command the test step runs, ahead of auto-detection. `check_cmd` runs from the registered `local_path` after every edit in that repo, instead of tsc/eslint; a non-zero exit is reported back to Claude. A `check_cmd` that runs longer than the 60-second hook timeout is killed and reports nothing, so keep it fast.

Profile selection looks at file names first (`.tsx`/`.jsx`/`.vue`/`.svelte`/style files → `web-frontend`; controllers, `routes/`, `api/`, `src/server/`, SQL and migrations → `web-api`; both in one change → also `web-common`). Any other file (a `.ts` hook, a `.py` module, a changed `package.json`) counts by the dependencies of its nearest `package.json` / `pyproject.toml` / `requirements*.txt`, so in a monorepo each package is judged by its own manifest. An `api/` or `routes/` folder inside a frontend-only package is client code and gets only `web-frontend`; Next.js server routes (`app/api/`, `pages/api/`), SQL, migrations, controllers and `src/server/` there still get `web-api`. With no changed files it uses the manifest at the repo root.

Then check from the plugin folder:

```bash
bash hooks/detect-repo.sh /absolute/path/to/my-app     # an Active Repo block means the repo is registered
bash hooks/scan-repo.sh /absolute/path/to/my-app       # the block /register-repo would propose (reads only)
bash hooks/org-overlay.sh skills review-harness         # prints the overlay you wrote
bash hooks/extract-constraints.sh reviewer web-frontend   # #org section, then the web-frontend profile block, then the agent overlay
bash hooks/detect-profile.sh src/App.tsx                 # profiles for these paths (no args: the current changes)
bash hooks/detect-test-cmd.sh /absolute/path/to/my-app    # the test command the test step will run
bash hooks/find-consumers.sh userName                    # from a repo: the other registered repos that use this name (reads only)
bash hooks/static-gates.sh                               # from a repo: grep-decidable review rules on the current change (reads only)
bash hooks/risk-tier.sh                                  # from a repo: low / normal / high for the current change, with reasons (reads only)
bash hooks/review-context.sh                             # from a repo: changed files, changed symbols, their callers, changed tests (reads only)
bash hooks/audit-rules.sh                                # rule drift: stale registry versions, version-bound or duplicate rules, budget, ledger (reads only)
bash hooks/repo-rules.sh src/a.ts ../api/src/b.ts         # each touched repo's rule files and the docs they link to (reads only)
```

Knowledge gained during work can be added to the same folders with `/save-knowledge`. When the folders are empty, overlays print nothing and only the generic rules apply, with no repo matching and no organisation rules.

## Quick start

Open Claude Code in your project directory:

| Command | What it does |
|---|---|
| `/review-harness connect the payment API to the checkout screen` | Add a feature (UI included): approve the plan (`plan.md`) → implement → test → review → commit |
| `/review-harness refactor this code` | Find duplicated patterns and propose a refactor plan first |
| `/code-review` | Review the current changes as PASS / FAIL |
| `/git-branch` | Suggest a branch name and the `git checkout -b` command (you run it) |
| `/git-pr` | Write the PR title, body and `gh pr create` command (you run it) |
| `/rtk-toggle` | Change the output-compression mode for the plugin's internal commands |
| `/audit-rules` | Find rules that drifted from your repos (stale versions, version-bound or duplicate rules, budget, ledger) and apply the fixes you approve |

Requests can be written in any language. Output compression: rtk is on by default (`standard`) when the `rtk` binary is installed, otherwise off, with no question; `/rtk-toggle` changes it.

## Workflow

```
Feature        search-knowledge? → test-runner (baseline) → developer → test-runner → reviewer → git-commit → DONE

Small change   main session edits directly → test-runner → reviewer → git-commit → DONE

Bugfix         reproduce → plan.md (Symptom, Repro, Cause, Regression test) → approval
               → test-runner (baseline) → developer (regression test fails first, then fix) → test-runner → reviewer → git-commit → DONE

Refactor       search-knowledge? → refactor-architect → user re-approval
               → test-runner (baseline) → developer → test-runner → reviewer → git-commit → DONE

Review         reviewer
```

- `?` marks a step that is skipped when not needed. UI work is handled as Feature.
- **Small change** is a change that touches at most 3 files, at most 1 of them a new test file, and creates no new component, hook, store, endpoint or socket event. It skips writing `plan.md` and waiting for approval. A bug fix never takes this path. It also has no test baseline, so a test that already failed before the edit blocks the commit; you are told which, and you may override.
- **Bugfix** is any request that describes a failure. Nothing is fixed until the failure is reproduced (a failing test, or a command and its output) and traced to a `file:line` cause; if it cannot be reproduced, it asks you for the symptom and environment. A fix of at most 2 files skips the approval wait but shows you the cause and the regression test first. The reviewer FAILs a fix with no regression test (and no stated reason none is possible) or with changes the cause does not explain.
- Everything else writes `plan.md` and runs after you approve it. The plan's `Reuse` line (what is reused, or one concrete reason for building something new) cannot be empty; the reviewer FAILs an empty one. The plan also lists `Done When` (2–5 observable outcomes, each with the test, command or manual step that checks it) and `Out of Scope`; the reviewer FAILs an unmet outcome, a TODO or stub left in new code, a new export nothing calls, or an edit outside scope. Before approval the plan also names, from a search of the code, every file that uses a changed export, route or event (`Callers/Consumers`), one neighbouring file to imitate (`Pattern`) and the tests that cover the area (`Tests`); the reviewer FAILs a listed caller that is neither changed nor marked `no change needed`. A plan touching more than 6 files is split into ordered tasks, each with its own tests, and a refactor of untested code starts with characterization tests unless you waive them. A Small change states one `Done when:` line instead.
- The baseline run records tests that already fail before the change; afterwards only new failures count, and you are told in one line if there were any. After the tests, test-runner also runs the repo's `check_cmd` (or `tsc --noEmit` when there is a `tsconfig.json`) once and reports it.
- In a repo with no test command, you are shown the manual checks from `Done When` and asked to confirm them before the commit.
- Before handoff, the developer runs a self-check and reports it as a `self-check:` line. It holds the diff against the review checklist, which holds the reviewer's `#review` rules, the profile rules and your failure-pattern ledger. It also runs `static-gates.sh`, fixing every `hard` hit, and `review-context.sh`, updating or justifying every caller of a changed or removed symbol. The reviewer starts from the same two scripts. A `hard` hit, or an unchanged caller of a removed symbol, is a FAIL unless the plan names it.
- **Each repo's own rules**: the developer and the reviewer run `repo-rules.sh` on the planned files themselves, on every spawn and retry. It lists each touched repo's `CLAUDE.md`, `AGENTS.md` and `.claude/rules/*.md` and the docs they link to, marking the docs whose line names a path the change touches; both read the files the session did not auto-load and the matching docs. The reviewer FAILs a change that breaks a rule written there as `[convention]`, quoting it as `file:line`; a rule worded as a preference is only a note. Token cost (an estimate, not measured): each spawn reads the other repos' rule files and the matching docs; the session repo's auto-loaded `CLAUDE.md` is skipped. That is about (the sizes of the `rules:` files not auto-loaded + the matching docs) ÷ 4 tokens per developer or reviewer spawn, e.g. a 57 KB `CLAUDE.md` ≈ 15K tokens.
- Test failures and reviewer FAILs share a limit of 3 retries. At the limit it stops and reports what is still wrong.
- Each reviewer issue carries a route: `patch` (fixed in the next retry), `replan` (the plan is wrong: `plan.md` is updated and you approve it again before the retry) or `defer` (outside this change: listed in the final report, never retried, and not a reason to FAIL). Every FAIL reason is listed at once. A developer with evidence that an issue is wrong reports it instead of patching it, and the run stops for your decision. Every retry re-runs the tests before the reviewer.
- **Changes across repos**: when a change adds, changes or removes a route, socket event or request/response field another repo may use, the plan gets a `## Contract` (producer, consumer repos, `additive` or `breaking`, deploy order). For a breaking one, `find-consumers.sh` searches the other registered repos for each renamed or removed name and the hits go into the plan; the reviewer FAILs a breaking contract with no consumers listed, or a consumer repo with hits that is neither changed nor named as a follow-up in `Out of Scope`. Run the producer repo first: its final report ends with the `## Contract` block, which you paste into the consumer repo's run as its API spec.
- Everything after `DONE` (branch, push, PR) is yours to do.

## Agents and models

| Agent | Role | model | effort |
|---|---|---|---|
| developer | TDD implementation + API integration (types → hook/service → UI states) | `opus` | high |
| test-runner | Runs tests and summarises the result | `opus` | medium |
| reviewer | Reviews the change (correctness / performance / design / scope). The single quality gate before commit | `fable` | high |
| refactor-architect | Detects duplicated patterns and proposes extractions (writes `plan.md` only) | `fable` | high |

The model is the `model:` value in each `agents/*.md` frontmatter.

The review is matched to the change: before each reviewer spawn, `hooks/risk-tier.sh` scores it `low`, `normal` or `high`. A `low` change (docs or tests only, or at most 2 files with at most 30 added lines, no dependency file such as a lockfile, and no risky path or code word; words in `*.md`/`*.mdx`/`*.rst`/`*.txt` docs do not count) is reviewed with `opus` at `medium` effort; a `high` change (auth, payment, migrations, concurrency, parsers, hooks/CI/gates, or 10+ files) makes the reviewer write and run at least 2 executable probes in a temp dir.

The developer is matched to the plan the same way: before each developer spawn, `hooks/risk-tier.sh --paths <plan Affected Files>` scores the planned paths alone. A `low` plan (at most 3 paths, no risky path, no dependency file) spawns the developer at `medium` effort; `normal`, `high` and bugfix plans keep the frontmatter effort.

## Rules you need to know

1. **You run the git operations.** The plugin commits automatically, but for branches, pushes and PRs it only writes the commands and text.
2. **No commit without a reviewer PASS.** The verdict is stored in a file together with a hash of the work tree at review time. If you change code after the review, it must be reviewed again (`git add` does not count as a change). A failed test run, a test run older than the current code, or a repo without tests whose manual checks you have not confirmed, also blocks the commit. While a run is active, Claude's `merge`, `cherry-pick`, `revert`, `am` and `rebase --continue` are held to the same check. To commit anyway, say so explicitly; it is recorded as an override.
3. **An organisation overlay can add rules.** Example: a gate that requires QA documents to be updated when behaviour changes.
4. **Editing `package.json`, `next.config.*`, `tsconfig*.json`, lock files (`package-lock.json`, `pnpm-lock.yaml`, `poetry.lock`, `go.sum`, …) or `.env` / `.env.*` (except `.env.example`, `.env.sample`, `.env.template`) needs your approval.** After `install.sh`, `.env*` files cannot be edited, in every project (the deny rules go into your global `~/.claude/settings.json`).

## Measuring runs

Every finished run appends one line to `~/.review-harness/state/runs.jsonl`. To summarise it, run:

```bash
bash <plugin folder>/hooks/run-stats.sh [--repo <name>] [--since <days>]
```

The output covers:
- the number of runs and the **first-review PASS rate** (runs whose first verdict was PASS);
- retries before PASS, the share of runs with a FAIL, and FAIL categories;
- the override rate and how many runs hit the limit;
- median tokens and active minutes per run, and each agent's share of tokens;
- median weighted cost per run in input-equivalent tokens (cache read x0.1, cache write x1.25, output x5), since the raw total is mostly cheap cache reads. These come from the `SubagentStart`/`SubagentStop` hook and cover subagents only; they start with the first session opened after installing or updating.

Use it to check whether a rule change, a profile or an overlay actually helps.

At plan approval the harness also shows an expected time, from the same log: `run-stats.sh --estimate <workflow>` prints the median and the middle half of the wall time of finished runs of that workflow (this repo's when it has 5 or more, all repos' otherwise). With fewer than 5 runs it shows nothing.

## Where state is stored

The plugin never creates files inside the repo you are working in. Run state lives in `~/.review-harness/state/<repo-id>/`. `<repo-id>` is the work-tree name plus a hash of its absolute path, so each git worktree gets its own.

| File | Content |
|---|---|
| `run-state.json` | Current workflow, completed steps, retry count, reviewer verdict, test result |
| `agents.jsonl` | Per-subagent active time, tokens and tool calls for the current run (`agent-usage.sh`), one appended line per agent start or stop; summarised into `runs.jsonl` by `done` or `abandon` |
| `baseline.txt` | Tests that already failed before the current run's change |
| `attempts.md` | One line per failed attempt (`N. hypothesis → change → result`) on a path without `plan.md` (Small change); with a plan the lines go to its `## Attempts`. Cleared by `run-state.sh start` |
| `plan.md` | The plan awaiting approval. Its full path is reported every time it is written |
| `rtk-session.flag` | Output-compression mode |
| `register-declined` | You chose not to register this repo; `/review-harness` stops offering `/register-repo` here |
| `approved/` | Approvals for config-file edits (30-minute TTL) |
| `cache/` | tsc / eslint temporary files (cleaned after 1 hour) |

One file sits directly in `~/.review-harness/state/`, shared by all repos:

| File | Content |
|---|---|
| `runs.jsonl` | One line per finished run (appended by `run-state.sh done` / `abandon`, never rewritten): workflow, attempts, reviewer verdicts with their FAIL categories and who recorded them (`by`: `reviewer`, else `unknown`), test result, override reason, end (`done` / `abandoned` / `limit`), duration, files changed, and per agent type (spawns, active seconds, tokens, tool calls) plus run token totals when the `SubagentStart`/`SubagentStop` hook recorded them (subagents only). `bash <plugin folder>/hooks/run-stats.sh [--repo <name>] [--since <days>]` summarises it, including the first-review PASS rate and median tokens / active minutes per run |

One file sits directly in `~/.review-harness/`, also shared by all repos:

| File | Content |
|---|---|
| `failure-patterns.md` | The failure-pattern ledger: repeatable AI mistakes that no other rule catches, under a `## #failure-patterns` heading. Appended by `reviewer` / `test-runner` (and at the attempt limit); `extract-constraints.sh` gives it to both with its path, and its entries (no path) to `developer` in the review checklist. Yours alone — a plugin update never touches it |

If a run is interrupted, the next `/review-harness` asks whether to resume it or start new.

## More documentation

- [docs/skills.md](docs/skills.md) — the 10 skills, the `/review-harness` flow, `/git-pr` output, agents
- [docs/hooks.md](docs/hooks.md) — the 22 hook scripts, git policy, config-file protection and how to remove it, constraints, RTK, overlay and knowledge layout
- [CHANGELOG.md](CHANGELOG.md) — version history
- [skills/review-harness/SKILL.md](skills/review-harness/SKILL.md) — the workflow definition used at runtime; the parts one path needs (plan template, bugfix, retry loop, …) sit in sibling `skills/review-harness/*.md` files it reads only on that path
- [constraints.md](constraints.md) — agent rules
- [CLAUDE.md](CLAUDE.md) — maintainer rules for working on this repo (not loaded for plugin users; runtime rules live in `skills/` and `agents/`)
- [profiles/web-frontend.md](profiles/web-frontend.md) — stack-specific agent rules (TypeScript / React / Next.js), loaded per agent by tag
- [profiles/web-api.md](profiles/web-api.md) — API server rules (error mapping, validation, data integrity, access, contracts, realtime, migrations, boot), each from a real bug fix
- [profiles/web-common.md](profiles/web-common.md) — rules for a change that spans frontend and API (consumers, CORS, env config, status codes)
- [tests/run.sh](tests/run.sh) — hook smoke tests: `bash tests/run.sh` (needs `git` and `jq`; runs in CI on Linux and macOS)

License: [MIT](LICENSE). External PRs are not accepted.
