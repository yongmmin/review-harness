# review-harness

A review-gated coding harness for Claude Code. You give it one line — `/review-harness "what you want"` — and it hands plan → implement → test → review to specialist agents (developer / test-runner / reviewer / refactor-architect), and only lets a change be committed after the reviewer returns PASS. The workflow and the review gate are stack-neutral. Stack-specific rules live in profiles (`profiles/<name>.md`), and each run picks the profiles from the files the change touches; three ship today — `web-frontend` (TypeScript, React, Next.js), `web-api` (API servers such as NestJS, Express or FastAPI, with their ORM and migrations) and `web-common` (a change that touches frontend and API code together). Other stacks run on the generic rules, and you can add rules for your own stack with an overlay. The test step finds JavaScript, Python, Go and Rust test commands, or the `test_cmd` you register for a repo. Organisation-specific knowledge (repo structure, internal conventions) is not part of the plugin; each user prepares it on their own machine.

## Install / Update

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
| `~/.review-harness/knowledge/<org>/repos.md` | Repo registry, used to match the current directory to a repo |
| `~/.review-harness/knowledge/<org>/*.md` | Domain knowledge (architecture, conventions, …) |
| `~/.review-harness/org/skills/<skill>.md` | Organisation rules appended to a skill |
| `~/.review-harness/org/agents/<agent>.md` | Organisation rules appended to an agent |
| `~/.review-harness/org/constraints.md` | A `## #org` section appended to agent constraints |
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

Requests can be written in any language. On first use it asks once which output-compression (rtk) mode to use.

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
- **Small change** is a change that touches at most 2 existing files and creates no new file, component, hook, store, endpoint or socket event. It skips writing `plan.md` and waiting for approval. A bug fix never takes this path. It also has no test baseline, so a test that already failed before the edit blocks the commit; you are told which, and you may override.
- **Bugfix** is any request that describes a failure. Nothing is fixed until the failure is reproduced (a failing test, or a command and its output) and traced to a `file:line` cause; if it cannot be reproduced, it asks you for the symptom and environment. A fix of at most 2 files skips the approval wait but shows you the cause and the regression test first. The reviewer FAILs a fix with no regression test (and no stated reason none is possible) or with changes the cause does not explain.
- Everything else writes `plan.md` and runs after you approve it. The plan's `Reuse` line (what is reused, or one concrete reason for building something new) cannot be empty; the reviewer FAILs an empty one. The plan also lists `Done When` (2–5 observable outcomes, each with the test, command or manual step that checks it) and `Out of Scope`; the reviewer FAILs an unmet outcome, a TODO or stub left in new code, a new export nothing calls, or an edit outside scope. Before approval the plan also names, from a search of the code, every file that uses a changed export, route or event (`Callers/Consumers`), one neighbouring file to imitate (`Pattern`) and the tests that cover the area (`Tests`); the reviewer FAILs a listed caller that is neither changed nor marked `no change needed`. A plan touching more than 6 files is split into ordered tasks, each with its own tests, and a refactor of untested code starts with characterization tests unless you waive them. A Small change states one `Done when:` line instead.
- The baseline run records tests that already fail before the change; afterwards only new failures count, and you are told in one line if there were any. After the tests, test-runner also runs the repo's `check_cmd` (or `tsc --noEmit` when there is a `tsconfig.json`) once and reports it.
- In a repo with no test command, you are shown the manual checks from `Done When` and asked to confirm them before the commit.
- Test failures and reviewer FAILs share a limit of 3 retries. At the limit it stops and reports what is still wrong.
- Everything after `DONE` (branch, push, PR) is yours to do.

## Agents and models

| Agent | Role | model | effort |
|---|---|---|---|
| developer | TDD implementation + API integration (types → hook/service → UI states) | `opus` | high |
| test-runner | Runs tests and summarises the result | `opus` | medium |
| reviewer | Reviews the change (correctness / performance / design / scope). The single quality gate before commit | `fable` | high |
| refactor-architect | Detects duplicated patterns and proposes extractions (writes `plan.md` only) | `fable` | high |

The model is the `model:` value in each `agents/*.md` frontmatter.

## Rules you need to know

1. **You run the git operations.** The plugin commits automatically, but for branches, pushes and PRs it only writes the commands and text.
2. **No commit without a reviewer PASS.** The verdict is stored in a file together with a hash of the work tree at review time. If you change code after the review, it must be reviewed again (`git add` does not count as a change). A failed test run, a test run older than the current code, or a repo without tests whose manual checks you have not confirmed, also blocks the commit. To commit anyway, say so explicitly; it is recorded as an override.
3. **An organisation overlay can add rules.** Example: a gate that requires QA documents to be updated when behaviour changes.
4. **At 80% of the 5-hour usage limit it asks which model to use.** Before starting reviewer / refactor-architect it asks once: `Keep Fable` / `Opus for this run`. Usage is read from `~/.claude/usage-state.json`, written by your status line; if the file is missing or older than 10 minutes it does not ask.
5. **Editing `package.json`, `next.config.*`, `tsconfig*.json`, lock files (`package-lock.json`, `pnpm-lock.yaml`, `poetry.lock`, `go.sum`, …) or `.env` / `.env.*` (except `.env.example`, `.env.sample`, `.env.template`) needs your approval.** After `install.sh`, `.env*` files cannot be edited, in every project (the deny rules go into your global `~/.claude/settings.json`).

## Where state is stored

The plugin never creates files inside the repo you are working in. Run state lives in `~/.review-harness/state/<repo-id>/`. `<repo-id>` is the work-tree name plus a hash of its absolute path, so each git worktree gets its own.

| File | Content |
|---|---|
| `run-state.json` | Current workflow, completed steps, retry count, reviewer verdict, test result |
| `baseline.txt` | Tests that already failed before the current run's change |
| `plan.md` | The plan awaiting approval. Its full path is reported every time it is written |
| `rtk-session.flag` | Output-compression mode |
| `register-declined` | You chose not to register this repo; `/review-harness` stops offering `/register-repo` here |
| `approved/` | Approvals for config-file edits (30-minute TTL) |
| `cache/` | tsc / eslint temporary files (cleaned after 1 hour) |

One file sits directly in `~/.review-harness/state/`, shared by all repos:

| File | Content |
|---|---|
| `runs.jsonl` | One line per finished run (appended by `run-state.sh done` / `abandon`, never rewritten): workflow, attempts, reviewer verdicts with their FAIL categories, test result, override reason, end (`done` / `abandoned` / `limit`), duration, files changed. `bash <plugin folder>/hooks/run-stats.sh [--repo <name>] [--since <days>]` summarises it |

If a run is interrupted, the next `/review-harness` asks whether to resume it or start new.

## More documentation

- [docs/skills.md](docs/skills.md) — the 11 skills, the `/review-harness` flow, `/git-pr` output, agents
- [docs/hooks.md](docs/hooks.md) — the 16 hook scripts, git policy, config-file protection and how to remove it, constraints, RTK, overlay and knowledge layout
- [CHANGELOG.md](CHANGELOG.md) — version history
- [skills/review-harness/SKILL.md](skills/review-harness/SKILL.md) — the workflow definition used at runtime
- [constraints.md](constraints.md) — agent rules
- [CLAUDE.md](CLAUDE.md) — maintainer rules for working on this repo (not loaded for plugin users; runtime rules live in `skills/` and `agents/`)
- [profiles/web-frontend.md](profiles/web-frontend.md) — stack-specific agent rules (TypeScript / React / Next.js), loaded per agent by tag
- [profiles/web-api.md](profiles/web-api.md) — API server rules (error mapping, validation, data integrity, access, contracts, realtime, migrations, boot), each from a real bug fix
- [profiles/web-common.md](profiles/web-common.md) — rules for a change that spans frontend and API (consumers, CORS, env config, status codes)
- [tests/run.sh](tests/run.sh) — hook smoke tests: `bash tests/run.sh` (needs `git` and `jq`; runs in CI on Linux and macOS)

License: [MIT](LICENSE). External PRs are not accepted.
