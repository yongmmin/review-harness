# Hooks and policy details

Detailed description moved out of the [README](../README.md). The reference documents at runtime are [`skills/review-harness/SKILL.md`](../skills/review-harness/SKILL.md) with the situational files next to it (read only on their path), the other `skills/*/SKILL.md` and `agents/*.md`, and [`constraints.md`](../constraints.md) (through `extract-constraints.sh`). [`CLAUDE.md`](../CLAUDE.md) holds maintainer rules and is not loaded for plugin users.

## Core principles

1. **Conductor** — the orchestrator does not write code itself and delegates to specialist agents. Exception: on the Small change path the main session edits directly
2. **Evidence First** — no declaring completion without test run results
3. **YAGNI** — implement only what was explicitly requested. No speculative features
4. **Reuse First** — at plan time the main session first looks for reusable components, hooks and utils and writes them in the `Reuse` item of `plan.md`. If it is empty, reviewer FAILs
5. **Token Budget** — pass only the minimum context to every agent (partial loading of constraints.md by tag, token measurement on stderr)
6. **User-Driven Git** — branch creation / push / PR are all triggered by the user

## Install details

`install.sh` (creates no symlinks since v0.2.0):

1. Cleans up the skill symlinks / command stubs of the old install method (only those owned by this plugin)
2. Adds `.env*` protection rules to `permissions.deny` in `~/.claude/settings.json` (a plugin cannot modify user settings, so only this step is kept as a script. Backs up to `.bak` before writing)
3. Detects the `rtk` binary (optional. Works without it)
4. Checks whether the plugin is registered + shows the 2-step commands below

> ⚠️ Skill symlinks alone **do not activate hooks (the automatic `tsc`/`eslint` feedback loop) or agents frontmatter (model pin / tool scoping).** `hooks.json` and `agents/` are read by the harness only when installed as a plugin, and `${CLAUDE_PLUGIN_ROOT}` is injected only then. After installing, check with `/plugin` in a new session.

## Git policy (USER-DRIVEN)

| Operation | Plugin behaviour |
|---|---|
| **Branch creation** | The user calls `/git-branch` → the plugin (1) lists existing branches with `git branch -a` (read-only), (2) selects a base via `AskUserQuestion` (main / stage / production, etc.), (3) asks for the new name, (4) prints the `git checkout -b <name>` command. **Never runs it** |
| **Commit** | **Runs automatically** when `run-state.sh check` passes (a reviewer PASS record for the current work tree and no blocking test result, or a recorded user override. Conventional Commit). `commit-gate.sh` blocks `git commit` with the same check |
| **Push** | **Never runs automatically**. The user runs `git push -u origin <branch>` themselves |
| **PR creation** | The user calls `/git-pr` → the plugin prints the title + body + `gh pr create` command + prefilled URL. **Never runs `gh`** |

### Trigger phrases

| User input | Plugin response |
|---|---|
| `"create a branch"`, `/git-branch` | Lists existing branches → selects a base → asks for the name → prints the command |
| `"create a PR"`, `"write the PR body"`, `"get the PR ready"`, `/git-pr` | Prints the body + URL |
| `"push it"` | Politely declines + shows only the recommended command |

## 24 Hooks

The `hooks/` directory. Hooked automatically into session/tool events, or called as plugin-internal scripts.

| Hook | Trigger | Role |
|---|---|---|
| **`session-start.sh`** | SessionStart | Prints the compact summary of `~/.review-harness/knowledge/index.md` + calls `detect-repo.sh` to inject the active repo metadata into context + cleans up files older than 1 hour in `~/.review-harness/state/<repo-id>/cache/` |
| **`pre-tool-use.sh`** | PreToolUse (Write\|Edit\|MultiEdit\|NotebookEdit) | Denies edits to `package.json`/`next.config.*`/`tsconfig*.json`, lock files and `.env`/`.env.*` (not `.env.example`/`.env.sample`/`.env.template`). After user approval, `pre-tool-use.sh --approve <path>` records an approval with a 30-minute TTL → the retry passes |
| **`post-tool-use.sh`** | PostToolUse (Write\|Edit\|MultiEdit\|NotebookEdit) | On saving a TS/TSX file, runs incremental tsc + eslint in parallel, and on failure emits compact errors only — the edited file's tsc errors first, plus an `other files: N more errors` line when other files have errors that are not shown (3-second debounce, automatic cache cleanup). In a registered repo with `check_cmd`, runs that command from the registered `local_path` for any edited file instead, and emits its compact output when it exits non-zero (a `check_cmd` slower than the 60-second hook timeout is killed). Logs the token budget to stderr |
| **`detect-repo.sh`** | session-start + skill load | Parses with awk which repo the `cwd` matches, in every `~/.review-harness/knowledge/<org>/repos.md` (sorted) and then the flat `knowledge/repos.md`; the first match wins. On a match, prints compact metadata (`name`/`local_path`/`role`/`stack`/`layout`/`env`/`path_alias`/`doc_routing`/`test_cmd`/`check_cmd`, etc.). If there is no registry it prints nothing, and if there is no match it prints `not registered` |
| **`extract-constraints.sh`** | Just before agent spawn | `extract-constraints.sh <agent> [profile[,profile...]]`. Extracts from `constraints.md` only the section tags that agent needs (`#code-rules`/`#filesystem`/`#completion`/`#review`) + for reviewer / test-runner a `ledger: <absolute path>` line and the `#failure-patterns` section of `~/.review-harness/failure-patterns.md` (when present) + appends the `#org` section of `~/.review-harness/org/constraints.md`, the agent's sections of each `profiles/<profile>.md` (one `## Profile — <name>` block per profile, in the order given; the same sections of `~/.review-harness/org/profiles/<profile>.md`, when present, follow under `### Org rules — <name>` and count as profile bytes) and the agent overlay. For developer, a `## Review checklist — the reviewer FAILs on these (check your diff before handoff)` block goes before the overlay: only the rule lines (`- `) of `#review` from `constraints.md`, each profile and its org profile, and of the ledger — no prose, headings or `ledger:` line; no block when there are no lines. Any unknown profile → exit 2, nothing printed; an empty list = no profile. Logs the token budget to stderr |
| **`detect-profile.sh`** | Skills, at the `extract-constraints.sh` call site | `detect-profile.sh [path...]` → comma-separated profile names or an empty line. Paths: the arguments (developer / refactor-architect: the plan's Affected Files), else the current git changes. `.tsx`/`.jsx`/`.vue`/`.svelte`/style files → `web-frontend`; `*.controller.*`, `*.sql`, `migrations/`, `src/server/` → `web-api`; `routes/`, `api/` → `web-api` unless the nearest manifest is frontend-only (client code; Next.js `app/api/` and `pages/api/` still count); both → also `web-common`. Any path no frontend rule matched (API-name matches included) also counts by the dependencies of its nearest `package.json` / `pyproject.toml` / `requirements*.txt` (walking up to the git root; React/Next/Vue/Svelte → `web-frontend`, Nest/Express/Fastify/Koa/FastAPI/Django/Flask → `web-api`). No paths at all → the repo-root manifest. Prints only names that have a `profiles/<name>.md` |
| **`detect-test-cmd.sh`** | test-runner step 1 + `tdd` skill load | `detect-test-cmd.sh [dir]` → one test command or nothing. First match: registry `test_cmd`, `package.json` `scripts.test` (not npm's placeholder; pnpm/bun/yarn/npm by lockfile), `vitest.config.*`, `jest.config.*`, a bun lockfile (`bun test`), pytest markers, `go.mod`, `Cargo.toml` |
| **`scan-repo.sh`** | `register-repo` skill load | `scan-repo.sh [dir]` → a proposed `repos.md` block for the repo root (name, `local_path`, `role: TODO`, `stack` from package.json / Python / Go / Rust manifests, `layout`, `path_alias` from `tsconfig.json`, `test_cmd` from `detect-test-cmd.sh`, `check_cmd` for ruff or Go, workspace patterns in `special`). Reads only, never writes; lines with nothing found are left out. A repo path containing a backtick → exit 1 (the registry cannot hold it) |
| **`find-consumers.sh`** | Main session, for a `breaking` plan `## Contract` | `find-consumers.sh <term...>` → for every repo in the registry files `detect-repo.sh` reads (each `local_path` once) except the one containing the cwd, the lines of its `local_path` that contain a term (literal; whole word only when the term starts and ends with a word character, so a route still matches inside a URL; `rg` when installed, else `grep -rn`), as `<repo>: <path>:<line>: <text>`. Skips `node_modules`, `.git`, `dist`, `build`, `.next`, `out`, `coverage`, `storybook-static` (`rg` also skips gitignored and hidden files); at most 20 lines per repo, then `+N more`; `no match` / `local_path not found` lines per repo. Text is kept on one line without backticks, control characters or Unicode bidi controls. No registry or no other repo → one notice line. Reads only, exit 0 |
| **`static-gates.sh`** | developer self-check + reviewer, before the review | `static-gates.sh [base]` → the review rules a grep can decide, from the ADDED lines and changed paths: with `base`, everything since its merge base with HEAD plus the working tree; without, staged, unstaged and untracked against HEAD; with no HEAD, every tracked or untracked file. One line per hit, `<hard\|note> [category] path:line — rule`. Hard: `console.log(` in a non-test JS/TS/Vue/Svelte file `[ops]`; a `.env` / `.env.*` file, except names ending in `.example`/`.sample`/`.template` `[security]` (line 1); `process.env.NAME` with `\|\|` or `??` and a non-empty string literal, NAME secret-like: a name segment (split on `_`, and on camelCase when NAME has lower case) is `[API]KEY` or ends in SECRET, TOKEN, PASSWORD, PASSWD, WEBHOOK, CREDENTIAL or PRIVATE, each with an optional plural `S` and trailing digits, any case (`API_KEY`, `apiKey`, `SENDGRID_APIKEY`, `API_KEYS`, `X_API_KEY2`, `AUTH_TOKENS`, `JWT_SECRETS` hard; `HOTKEY_LAYOUT`, `KEYBOARD_MODE`, `MONKEY`, `KEYCLOAK_URL`, `TOKENIZER` notes); every fallback on a line counts, one hit per line `[security]`. Note: the same fallback for any other NAME `[security]`; `TODO`/`FIXME`/`XXX` `[goal]`; a new `export` whose name no other tracked or untracked file mentions `[goal]`. Deleted files, removed lines, binary files and nested repos are never reported. Untracked files go into one diff through a temporary copy of the index (intent-to-add); the real index is never written. Reads only, no network; needs git ≥ 2.25; exit 1 on a hard hit, 0 otherwise, 2 on a usage error, outside a git repo, or when an internal `git add -N` / `git diff` fails (e.g. an unreadable untracked file; git's error, then one line naming the command, never a silent clean 0). In a sparse checkout, untracked files outside the cone are added with `--sparse` (git ≥ 2.34), so they do not fail the run. Temp files are created with `umask 077` |
| **`risk-tier.sh`** | Main session, before each `reviewer` spawn (`/review-harness`, and `/code-review` on a diff target); with `--paths`, before each `developer` spawn (`/review-harness`) | `risk-tier.sh [base]` → line 1 `low`, `normal` or `high`, then one `reason: …` line per rule that fired. Collects the change as `static-gates.sh` does (both source `hooks/lib/collect-change.sh`), deleted paths and both sides of a move included. **high** (any match wins): a changed path, or an added line of a file that is neither a doc nor a dependency file, holding an auth/session (auth, oauth, session, token, permission, role, acl, rbac, password, passwd, jwt, login, logout, credential), payment (payment, billing, checkout, invoice, stripe, refund), concurrency (lock, mutex, semaphore, worker, queue, concurrency) or parser (parser, parsing, deserialize) word; a path under `migration(s)/` or ending in `.sql`; a path under the root `hooks/` or `.github/workflows/`, or a file name holding the word `gate(s)`; 10 or more changed files. **normal** with `reason: dependency change` when no high rule fired and a dependency file changed (`*.lock`, `bun.lockb`, `package-lock.json`, `pnpm-lock.yaml`, `go.sum`, `requirements*.txt`, `constraints*.txt`; under high the same reason is listed too). Docs are `*.md`, `*.mdx`, `*.rst` and `*.txt` (not `requirements*`/`constraints*.txt` or `CMakeLists.txt`): they count only through their path, never through the words of their added lines; code under a `docs/` folder is scanned like any code. A dependency file's name and lines are never scanned for words. **low** (no high rule, no dependency file, at least one changed file): only docs or tests changed (docs, images under `docs/`, `*.test.*`, `*.spec.*`, `__tests__/`, `test/`, `tests/`), or at most 2 files with at most 30 added lines. **normal** otherwise, an empty change included, with no reason line. Words are case-insensitive whole runs of letters and digits, also split at camelCase (`getToken` is a hit; `tokenizer`, `author`, `clock`, `parseInt`, `navigate` are not); before the scan, ARIA `role=`, `getByRole(`, `git checkout`, `sparse-checkout` and `actions/checkout@` are blanked, only the first 20,000 characters of an added line are scanned, and runs over 80 characters (minified or encoded data) are skipped, so a multi-megabyte one-line file takes about a second. `low` → the reviewer is spawned with `model: "opus"`, `effort: "medium"` (`Keep Fable` does not change that); `high` → the reviewer runs at least 2 executable probes in a temp dir. Reads only, real index never written; exit 0, or 2 on a usage error, outside a git repo or when git fails (the skill then uses `normal`). `risk-tier.sh --paths <path...>` scores a plan's Affected Files from the paths alone, without reading a diff (git runs only to find the repo root; each argument is split at commas, backticks, blanks and a leading `./` are dropped, an absolute path under the repo root is made relative): **high** on the same path rules (path words, migration, hooks/workflow/gate path, 10+ paths), **normal** on a dependency file, **low** with at most 3 paths (`reason: small plan: N paths`), **normal** otherwise; `low` → the developer is spawned with `effort: "medium"` (never for a bugfix plan); exit 2 when no path is left |
| **`review-context.sh`** | reviewer, after `static-gates.sh`; developer self-check | `review-context.sh [base]` → one block of at most 4,096 bytes (over that, cut at a line and followed by `… truncated`) on the change `static-gates.sh` sees (both source `hooks/lib/collect-change.sh`), renames detected. Sections in order, an empty one as `<section>: none`: `files:` one `<A\|M\|D\|R> path +added -removed` line per changed path (a rename `R old -> new`), at most 30 then `files: +N more` so symbols and callers still fit; `symbols:` one `<name> (<added\|removed\|changed>) in <path>` line per name defined on an added or removed line (changed: both sides of the same file), removed first, at most 25 then `symbols: +N more` — JS/TS/Vue/Svelte `export [default] [async] function\|const\|let\|class\|interface\|type\|enum Name`, `function Name(` and `Name = (…) =>` at the start of a line, shell `Name()` and `function Name`, Python `def Name` and `class Name` (regex hints, no parse); `callers:` `<name>: path, …` per listed symbol, the other tracked or untracked files holding the name as a whole word (`git grep -lwIF`), the defining file and docs excluded (`*.md`, `*.mdx`, `*.rst`, `*.txt`, not `requirements*`/`constraints*.txt` or `CMakeLists.txt`, the doc set of `risk-tier.sh`), test files marked `(test)`, at most 8 then `+N more`, or `none`; `tests:` the changed test files. Reads only, real index never written; exit 0, or 2 on a usage error, outside a git repo or when git fails. Temp files are created with `umask 077` |
| **`repo-rules.sh`** | developer (before writing code) + reviewer (`**Repo rules**` gate), on every spawn; main session for the plan's `Repo rules:` line and the Small change path | `repo-rules.sh [path...]` → per touched repo: `repo: <toplevel>`; one `rules: <file> (<bytes> B)` line per rule file present — `CLAUDE.md`, `.claude/CLAUDE.md`, `AGENTS.md`, `.claude/rules/*.md` (sorted) and a `CLAUDE.md` in any folder between the root and a changed path — with ` · auto-loaded` on the root `CLAUDE.md`, `.claude/CLAUDE.md` and `.claude/rules/*.md` of the repo containing `$PWD` (the files Claude Code loads for a session started there, so the agents run it from the directory they started in, before any `cd`), or `rules: none`; a change under `.claude/` does not list `.claude/CLAUDE.md` twice; then `docs: N linked · M match the change` and one line per linked doc, every `- match <doc> — <line>` first, then `- <doc> — <line>`, at most 30 of those, then `+N more`. A linked doc is a markdown link target in a rule file ending `.md` (`#anchor` dropped, `http(s):`/`mailto:` skipped), resolved from the rule file's folder, kept when it exists and lies inside the repo by path (symlinks are not resolved, so a doc reached through an in-repo symlink can be listed, possibly twice), listed once; `<line>` is the rule-file line holding the link, blanks collapsed, cut to 200 bytes without splitting a character (`iconv -c`). `match`: a backticked token on that line containing `/` (glob tail, trailing `/` and leading `./` dropped) equals a changed repo-relative path or is a folder of one. Paths: each argument split at commas, backticks, blanks, a leading `./` and a glob tail dropped, relative to `$PWD`; a path that does not exist yet goes through its nearest existing folder; grouped by git toplevel in order of first appearance; a path in no repo prints `outside a git repo: <path>`. No arguments: the cwd repo's `git diff --name-only --no-renames HEAD` plus untracked files (no commits: `ls-files` plus untracked); the change reaches awk on stdin and each folder is checked once, so thousands of paths take about a second. An `iconv` that prints nothing leaves the raw cut. The script runs under `LC_ALL=C`, so the cut and the line reading are byte-based in every locale. Lists facts only; the agents pick the docs that apply and the reviewer owns the FAIL (with no plan, it passes the paths of the `review-context.sh` `files:` block). Reads only; exit 0, or 2 with one stderr line on a usage error, no path in a repo, no arguments outside a repo, or an unreadable rule file |
| **`audit-rules.sh`** | `/audit-rules` skill load, or run by the user | `audit-rules.sh` → one line per finding, `<kind> <location> — <reason>`, on drift between the rules and the repos they describe. Reads `~/.review-harness/` (honours `REVIEW_HARNESS_HOME`; home files shown relative to it) and the plugin's `constraints.md` and `profiles/*.md` (shown as `<plugin>/…`). Kinds: `stale-version` — a registry `stack` token `<Name> <major>[.x]` (Next, React, TS/TypeScript, NestJS→`@nestjs/core`, Prisma→`prisma`/`@prisma/client`, Tailwind→`tailwindcss`, Zustand, Three, Storybook, Vite, Express; other names skipped) whose major differs from the repo's `package.json` `dependencies`/`devDependencies` (`^~>=<` stripped; a 0.x version compares major.minor; a range uses its first part and is noted; `workspace:`, `*`, tags and URLs skipped); `missing-path` — a `local_path` that does not exist; `version-rule` — a line outside code fences in the org overlay (`org/constraints.md`, `org/agents\|skills\|profiles/*.md`) or a plugin profile naming one of those frameworks, spelled as one (a capital, a `.js` suffix or backticks, so "the next 3 steps" is no rule), with a version some registered repo does not run (`N+` flags only repos below N); the reason lists every registered repo's version of it, `(=)` or `(≠)` — a candidate, not a verdict; `duplicate` — the same `- ` bullet (whitespace-normalised, 30+ characters) in two or more of the plugin constraints and profiles, the org overlay and the ledger; `budget` — an agent whose non-profile `extract-constraints.sh` part is over its warn threshold (location = the agent; one run per agent without a profile, since that part is the same for every profile); `ledger-size` — `failure-patterns.md` over 3,072 bytes; `ledger-old` — a ledger entry dated more than 90 days before today (`REVIEW_HARNESS_TODAY=YYYY-MM-DD` overrides); `ledger-unloaded` — ledger entries with no `## #failure-patterns` heading, so `extract-constraints.sh` passes none of them. A registry `local_path` before any `### ` heading is shown with repo `-`. Retired, hidden and `docs/` folders under `org/` are not read (nothing loads them). Reads only and writes nothing, not even a temp file (no here-strings); findings print as they are found; missing folders → no findings; `jq` optional (without it `package.json` is read line by line). Exit 0 no findings, 1 findings, 2 on a usage error or an internal failure (an unreadable registry, rule file or `package.json`, a failed parse), with one stderr line |
| **`org-overlay.sh`** | Skill load + `extract-constraints.sh` | Prints the organisation overlay (`~/.review-harness/org/skills\|agents/<name>.md`). If absent, prints nothing |
| **`knowledge-has-content.sh`** | Just before a `/search-knowledge` call | Quickly verifies whether the knowledge/wisdom files have real content beyond placeholders. If empty, the `/search-knowledge` call itself is skipped |
| **`rtk-wrap.sh`** | Plugin-internal Bash calls | Wraps calls to `git`/`gh`/`tsc`/`eslint`/`jest`/`vitest`/`grep`/`find`/`ls`, etc. in `rtk` to compress output (per mode). Falls back to the raw command when `rtk` is not installed, runs a command containing a `--` argument raw (rtk would drop it), and runs `git diff`, `git show` and `gh … diff` raw in every mode (rtk 0.40 cuts them to about 500 lines, 100 per hunk). With no env value and no session flag the mode is `standard` when `rtk --version` starts with `rtk`, else `off`. No effect on other projects |
| **`usage-state.sh`** | On load of `/review-harness`, `/code-review`, `/refactor-scan` | Reads the 5-hour usage from `~/.claude/usage-state.json` (written by the user's status line wrapper) and prints `N% (resets HH:MM)`. `unknown` when the file is missing / older than 10 minutes / the window has reset |
| **`state-dir.sh`** | Called by other hooks / skills | Prints the path of the per-work-tree state directory `~/.review-harness/state/<repo-id>/` (`<repo-id>` = work tree name + hash of its absolute path). The plugin creates no files inside the consumer repo |
| **`strategy-file.sh`** | Session Context of `/review-harness` (`--status`) + `/strategy` skill load | `strategy-file.sh [--status]` → the absolute path of the repo's strategy file, `~/.review-harness/strategy/<repo-name>-<hash>.md`, where name and hash come from the git **common** dir, so all worktrees of a repo share one file (unlike the per-work-tree state dir). `--status` prints one line: `none`, or `present · Goal: <the Goal line, at most 80 bytes, whole characters>` (`-` when there is none). Outside a git repo: `none` with `--status`, else exit 2; an unreadable file is exit 2. Never creates the file or its folder (`/strategy` does) |
| **`run-state.sh`** | First step of every workflow + reviewer + git-commit | Manages `run-state.json`: `start` / `step` / `attempt` / `verdict` / `tests` / `dispute` / `override` / `strategy` / `check` / `done` / `abandon` / `status`. `tests pass\|fail\|none\|manual-confirmed` records the test result (test-runner; `manual-confirmed` only after the user's yes, and only over `none`); `check` also blocks on `fail`, on an unconfirmed `none`, and on a `pass` or confirmation of an older work tree. A run without a tests record is gated on the review alone. `start`, `done` and `abandon` delete `baseline.txt`. `verdict FAIL <category...>` also keeps the `[category]` tags of the FAIL issues (unknown words are ignored with a warning; `~/.review-harness/org/categories.txt`, one `[a-z-]+` word per line, adds organisation categories). Every verdict records `by` = the `--by <word>` argument (the reviewer's command passes `--by reviewer`) or `unknown`, shown by `status` and in `runs.jsonl`, never enforced. `dispute <issue id...>` records the developer's dispute of the last FAIL (unchanged work tree and below the attempt limit, else exit 1; one per review round, exit 2 when used); the next verdict on the same work tree is a re-judge and a FAIL then counts no attempt. `agent-start` / `agent-stop` (called by `agent-usage.sh`) keep each subagent's active time, tokens (deduplicated per `message.id`, replaced on every stop), tool calls and model in `<state dir>/agents.jsonl`: one JSON line appended per start or stop, no lock, folded on read (a torn line is skipped, and a writer killed mid-line can also lose the next append, which lands on that unterminated line; a stop with no earlier start is skipped); never in `run-state.json`, so the gate's file and its stale clock are untouched; nothing is recorded for a stale run; deleted by `start`, `done` and `abandon`, together with an `agents.json` / `agents.json.lock` left by an older version. `agents` prints the folded object. `strategy aligned|suggested-followed|suggested-declined` records the outcome of the strategy check before planning (active run only, else exit 1; another value is exit 2); `check` never reads it, `status` adds ` · strategy <value>` once it is set, and `runs.jsonl` carries it as `strategy`. `done` / `abandon` of an active run append one summary line to `~/.review-harness/state/runs.jsonl` (all repos; never rewritten; a failed append only warns), with `agents` (per agent type) and `tokens` (run totals) when agent data exists. `status` adds ` · agents N`. Retry counts, timestamps and the work tree hash are all computed by the script |
| **`run-stats.sh`** | Run by the user | `run-stats.sh [--repo <id\|name>] [--since <days>]` summarises `runs.jsonl`: runs, first-review PASS rate (runs whose first verdict is PASS, of runs with a verdict), mean attempts before PASS, share of runs with a reviewer FAIL, FAIL category counts, override rate, limit-reached count, and the same per workflow; when runs carry agent data, median tokens (total and output) and active minutes per run and each agent type's share of tokens and median seconds (subagents only); when runs carry a strategy outcome, `strategy check: N runs · suggested K · followed F`. Reads only; needs `jq` |
| **`agent-usage.sh`** | SubagentStart / SubagentStop (`developer`, `test-runner`, `reviewer`, `refactor-architect`) | Passes the subagent's id, type and transcript path to `run-state.sh agent-start` / `agent-stop`, so an active run records per-agent tokens and time. Never blocks, prints nothing, always exits 0; no active run, no `jq` or an unreadable transcript → nothing recorded. The main session's tokens are not measured |
| **`commit-gate.sh`** | PreToolUse (Bash) | Denies commands that write git history — `git commit`, `merge`, `cherry-pick`, `revert`, `am` (their `--abort`/`--quit`/`--skip` pass) and `rebase --continue` — when, in an active run, `run-state.sh check` fails (the reviewer PASS does not match the current work tree, or a blocking test result). Also catches `/abs/path/git`, options before the subcommand (`-C`, `-c`, `--git-dir`, …) and commands in chains, `$( )` or quoted strings; read-only git commands always pass. No state file → pass, a run left untouched for more than 24 hours → advice only, no `jq` → advice that the gate is inactive |

### Installing hooks

Claude Code finds `hooks/hooks.json` in the plugin folder by itself (`plugin.json` has no `hooks` key) — but **only when installed as a plugin** (`/plugin install`, see [README install](../README.md#install--update)). Skill symlinks alone do not load the hooks.

## How to remove tool boundaries

`install.sh` automatically adds the following rules to `permissions.deny` in `~/.claude/settings.json`:

| File | Handling |
|---|---|
| `.env*` | No edits — hard-blocked by settings.json Deny rules (all of Write/Edit/MultiEdit/NotebookEdit) |
| `package.json` | User approval required before editing — the PreToolUse hook denies (`pre-tool-use.sh --approve <path>` or `REVIEW_HARNESS_ALLOW_CONFIG_EDITS=1`) |
| `next.config.js/ts/mjs` / `tsconfig.json` / `tsconfig.*.json` | Same approval gate |
| Lock files: `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lock`, `bun.lockb`, `poetry.lock`, `uv.lock`, `Pipfile.lock`, `Cargo.lock`, `go.sum`, `composer.lock`, `Gemfile.lock` | Same approval gate |
| `.env`, `.env.*` (except `.env.example`, `.env.sample`, `.env.template`) | Same approval gate in the hook, on top of the settings.json deny above |

### Removing rules

**1. Lift the `.env*` block** — delete the entries below from `~/.claude/settings.json`:
```json
"Write(.env*)",
"Edit(.env*)",
"MultiEdit(.env*)",
"NotebookEdit(.env*)"
```

**2. Disable the PreToolUse hooks** — delete the relevant entry from `PreToolUse` in `hooks/hooks.json` of this plugin repository (`Write|Edit|MultiEdit|NotebookEdit` = config file approval gate, `Bash` = `commit-gate.sh` review gate)

**3. Remove the plugin completely**:

```
/plugin uninstall review-harness@review-harness
/plugin marketplace remove review-harness
```

If remnants of an old-version (≤0.1.0) symlink install remain, running `./install.sh` once cleans them up automatically (or manually):
```bash
for skill in review-harness tdd code-review refactor-scan save-knowledge search-knowledge \
  git-branch git-commit git-pr rtk-toggle; do
  rm -f ~/.claude/skills/$skill
  rm -f ~/.claude/commands/$skill.md
done
```

## Constraints system

[`constraints.md`](../constraints.md) holds the generic rules; a profile ([`profiles/web-frontend.md`](../profiles/web-frontend.md), [`profiles/web-api.md`](../profiles/web-api.md), [`profiles/web-common.md`](../profiles/web-common.md)) holds the stack-specific rules in the same `## #tag` format. Each agent partially loads only its own tags. Skills pass the output of `detect-profile.sh` (the profiles that match the changed files); an empty selection loads no stack rules.

### Tag mapping

| Tag | Target agents |
|---|---|
| `#code-rules` | developer / refactor-architect |
| `#filesystem` | developer |
| `#completion` | developer / test-runner |
| `#review` | reviewer; developer as a checklist (rule lines only, in its `## Review checklist` block) |
| `#failure-patterns` | reviewer / test-runner (lives in `~/.review-harness/failure-patterns.md`, with a `ledger: <path>` line. Omitted if absent); developer as a checklist, with no `ledger:` line |
| `#org` | developer / reviewer / refactor-architect (lives in `~/.review-harness/org/constraints.md`. Omitted if absent) |

Profile tags:

| Tag | Target agents | `web-frontend` | `web-api` | `web-common` |
|---|---|---|---|---|
| `#code-rules` | developer / refactor-architect | yes | — | — |
| `#implementation` | developer | yes | yes | — |
| `#review` | reviewer; developer as a checklist | yes | yes | yes |
| `#detection` | refactor-architect | yes | — | — |

`web-api` covers API servers and their data layer (error mapping, validation, write-after-read, transactions, unawaited promises, owner and soft-delete filters, CORS and cookies, contract changes, socket targeting, migrations, boot-time env checks); `web-common` covers a change that spans both sides (consumers updated, CORS vs. client headers, env config, status codes). Every gate comes from a real bug fix. `web-frontend` also tells the developer to `retrieve` the modern-web-guidance ids the plan names, and the developer's self-check and the reviewer to run its `legacy-scan` on each changed UI file (at most 5) ([README](../README.md#modern-web-guidance)); no hook runs it.

### Token budget measurement

- `hooks/extract-constraints.sh` and `hooks/post-tool-use.sh` log bytes/estimated tokens to **stderr** on every call
- Warning threshold: 8192 bytes (~2K tokens). It measures the non-profile part; profile bytes and the developer's checklist bytes (`+ checklist: N bytes`) are reported separately on the same line
- Override with the environment variable `REVIEW_HARNESS_BUDGET_WARN_BYTES`
- stderr does not reach the agent context — for observation only
- If a `[warn]` line appears, shrink that `constraints.md` section or split it into a smaller tag

### `#failure-patterns` ledger (distilled 2026-07-10)

The ledger is `~/.review-harness/failure-patterns.md` (`$REVIEW_HARNESS_HOME/failure-patterns.md` when set): one per user, outside the plugin, so a plugin update never overwrites it and organisation-specific entries stay out of the public repo. Entries go under its `## #failure-patterns` heading in the format given in the `constraints.md` header. `reviewer` and `test-runner` append to the `ledger:` path printed by `extract-constraints.sh`; the orchestrator does the same at the attempt limit.

This ledger keeps **only patterns that other layers cannot catch** — rules already enforced by the static gates in reviewer.md or a profile (`profiles/*.md`) / `#review`·`#org` rules / ESLint(tsc) are not added. 34 of the 40 seeds were duplicates and were removed.

It held 0 entries when it moved out of `constraints.md` (2026-11-16 GC: all 6 removed as older than 90 days), so nothing was migrated.

GC rule: when it exceeds 3072 bytes (observed via extract-constraints.sh stderr), merge similar rules + remove entries 90 days or older.

### Deterministic enforcement (2026-07-10)

Some rules of the duplicate-variable/redeclaration kind are enforced by each repo's ESLint, not by the prompt. Which rules are turned on differs per repo, and the organisation overlay can keep a per-repo summary of the current state. The PostToolUse hook runs `eslint --max-warnings=0` per edited file, so even `warn` rules are blocking in the hook, while existing CI is unchanged.

## RTK integration (optional)

[rtk](https://github.com/rtk-ai/rtk) is a CLI tool that compresses the tokens of command output. The plugin integrates it only as **optional/session-limited/plugin-scoped** — no effect on other projects.

### Modes

| Mode | Behaviour |
|---|---|
| `off` | Raw commands as-is (default when `rtk` is not installed) |
| `standard` | Applies `rtk` (git/gh/tsc/eslint/test/grep/find/ls) (default when `rtk` is installed) |
| `aggressive` | standard + `--ultra-compact` |
| `git-only` | `rtk` compresses git/gh only, the rest is raw |

### Choosing a mode

- **Default**: no question; `standard` when the `rtk` binary is installed, else `off`
- **Manual change**: `/rtk-toggle` or with an argument such as `/rtk-toggle standard`
- **Status check**: `/rtk-toggle status` (the current mode is injected automatically at skill load)
- **Environment variable override**: `REVIEW_HARNESS_RTK=standard` (takes precedence over the session flag)

### Guarantees

- Never runs the global `rtk init -g`
- Never touches the hooks in `~/.claude/settings.json`
- The session flag is stored only in `~/.review-harness/state/<repo-id>/rtk-session.flag` (per work tree, outside the repo)
- Silent fallback to raw when `rtk` is not installed

## Organisation overlay and knowledge structure

Content specific to an organisation or company is not kept in this repository. It is kept only in `~/.review-harness/`, outside the plugin folder (the location can be changed with `REVIEW_HARNESS_HOME`).

```
~/.review-harness/
├── org/
│   ├── skills/<skill>.md       # per-skill organisation overlay
│   ├── agents/<agent>.md       # per-agent organisation overlay
│   ├── constraints.md          # `## #org` constraints section
│   └── categories.txt          # extra reviewer FAIL categories, one [a-z-]+ word per line
├── knowledge/
│   ├── index.md                # compact summary loaded automatically at session start
│   └── <org>/
│       ├── repos.md            # repo registry (read by detect-repo.sh; several org folders are read in sorted order)
│       └── *.md                # domain knowledge
├── state/<repo-id>/            # run state (run-state.json, plan.md, etc.)
├── strategy/<repo>-<hash>.md   # per-repo strategy file, shared by its worktrees (strategy-file.sh, /strategy)
└── wisdom/                     # cross-project learnings
```

- `hooks/org-overlay.sh <skills|agents> <name>` prints the overlay file. If the file does not exist it prints nothing
- Every `SKILL.md` has its own overlay injected at load time
- `hooks/extract-constraints.sh <agent> [profile[,profile...]]` appends the `#org` section, the profile sections and the agent overlay after the content the orchestrator passes to the agent
- If `org/` and `knowledge/` do not exist, the overlay is empty, `detect-repo.sh` prints nothing, and `knowledge-has-content.sh` reports empty. The plugin runs on the generic rules alone
- Detailed domain files are loaded on demand by `search-knowledge`. At session start only `index.md` is loaded automatically

### Global wisdom (cross-project learnings)

```
~/.review-harness/wisdom/
├── summary.md                  # 20-line limit
├── learnings.md
├── decisions.md
└── issues.md
```

Only truly cross-project learnings (not limited to a specific organisation) are stored here. Organisation-specific ones go to `~/.review-harness/knowledge/<org>/*` above.
