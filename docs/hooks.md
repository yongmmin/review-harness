# Hooks and policy details

Detailed description moved out of the [README](../README.md). The reference documents at runtime are [`CLAUDE.md`](../CLAUDE.md), [`constraints.md`](../constraints.md), and [`skills/review-harness/SKILL.md`](../skills/review-harness/SKILL.md).

## Core principles

1. **Conductor** — the orchestrator does not write code itself and delegates to specialist agents
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
| **Commit** | **Runs automatically** when `run-state.sh check` passes (a reviewer PASS record for the current work tree, or a recorded user override. Conventional Commit). `commit-gate.sh` blocks `git commit` with the same check |
| **Push** | **Never runs automatically**. The user runs `git push -u origin <branch>` themselves |
| **PR creation** | The user calls `/git-pr` → the plugin prints the title + body + `gh pr create` command + prefilled URL. **Never runs `gh`** |

### Trigger phrases

| User input | Plugin response |
|---|---|
| `"create a branch"`, `/git-branch` | Lists existing branches → selects a base → asks for the name → prints the command |
| `"create a PR"`, `"write the PR body"`, `"get the PR ready"`, `/git-pr` | Prints the body + URL |
| `"push it"` | Politely declines + shows only the recommended command |

## 12 Hooks

The `hooks/` directory. Hooked automatically into session/tool events, or called as plugin-internal scripts.

| Hook | Trigger | Role |
|---|---|---|
| **`session-start.sh`** | SessionStart | Prints the compact summary of `~/.review-harness/knowledge/index.md` + calls `detect-repo.sh` to inject the active repo metadata into context + cleans up files older than 1 hour in `~/.review-harness/state/<repo-id>/cache/` |
| **`pre-tool-use.sh`** | PreToolUse (Write\|Edit\|MultiEdit\|NotebookEdit) | Denies edits to `package.json`/`next.config.*`/`tsconfig.json`. After user approval, `pre-tool-use.sh --approve <path>` records an approval with a 30-minute TTL → the retry passes |
| **`post-tool-use.sh`** | PostToolUse (Write\|Edit\|MultiEdit\|NotebookEdit) | On saving a TS/TSX file, runs incremental tsc + eslint in parallel, and on failure emits compact errors only (3-second debounce, automatic cache cleanup). Logs the token budget to stderr |
| **`detect-repo.sh`** | session-start + skill load | Parses with awk which repo in `~/.review-harness/knowledge/<org>/repos.md` the `cwd` matches. On a match, prints compact metadata (`name`/`role`/`stack`/`layout`/`env`/`path_alias`/`doc_routing`, etc.). If there is no registry it prints nothing, and if there is no match it prints `not registered` |
| **`extract-constraints.sh`** | Just before agent spawn | `extract-constraints.sh <agent> [profile]`. Extracts from `constraints.md` only the section tags that agent needs (`#code-rules`/`#filesystem`/`#completion`/`#review`/`#failure-patterns`) + appends the `#org` section of `~/.review-harness/org/constraints.md`, the agent's sections of `profiles/<profile>.md` and the agent overlay. Unknown profile → exit 2, nothing printed. Logs the token budget to stderr |
| **`org-overlay.sh`** | Skill load + `extract-constraints.sh` | Prints the organisation overlay (`~/.review-harness/org/skills\|agents/<name>.md`). If absent, prints nothing |
| **`knowledge-has-content.sh`** | Just before a `/search-knowledge` call | Quickly verifies whether the knowledge/wisdom files have real content beyond placeholders. If empty, the `/search-knowledge` call itself is skipped |
| **`rtk-wrap.sh`** | Plugin-internal Bash calls | Wraps calls to `git`/`gh`/`tsc`/`eslint`/`jest`/`vitest`/`grep`/`find`/`ls`, etc. in `rtk` to compress output (per mode). Falls back to the raw command when `rtk` is not installed. No effect on other projects |
| **`usage-state.sh`** | On load of `/review-harness`, `/code-review`, `/refactor-scan` | Reads the 5-hour usage from `~/.claude/usage-state.json` (written by the user's status line wrapper) and prints `N% (resets HH:MM)`. `unknown` when the file is missing / older than 10 minutes / the window has reset |
| **`state-dir.sh`** | Called by other hooks / skills | Prints the path of the per-work-tree state directory `~/.review-harness/state/<repo-id>/` (`<repo-id>` = work tree name + hash of its absolute path). The plugin creates no files inside the consumer repo |
| **`run-state.sh`** | First step of every workflow + reviewer + git-commit | Manages `run-state.json`: `start` / `step` / `attempt` / `verdict` / `override` / `check` / `done` / `abandon` / `status`. Retry counts, timestamps and the work tree hash are all computed by the script |
| **`commit-gate.sh`** | PreToolUse (Bash) | Denies `git commit` when, in an active run, the reviewer PASS does not match the current work tree. No state file → pass, a run left untouched for more than 24 hours → advice only |

### Installing hooks

`hooks.json` is registered through the `hooks` key of `plugin.json` — but **only when installed as a plugin** (`/plugin install`, see [README install](../README.md#install--update)). Skill symlinks alone do not load the hooks.

## How to remove tool boundaries

`install.sh` automatically adds the following rules to `permissions.deny` in `~/.claude/settings.json`:

| File | Handling |
|---|---|
| `.env*` | No edits — hard-blocked by settings.json Deny rules (all of Write/Edit/MultiEdit/NotebookEdit) |
| `package.json` | User approval required before editing — the PreToolUse hook denies (`pre-tool-use.sh --approve <path>` or `REVIEW_HARNESS_ALLOW_CONFIG_EDITS=1`) |
| `next.config.js/ts/mjs` / `tsconfig.json` | Same approval gate |

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

[`constraints.md`](../constraints.md) holds the generic rules; a profile ([`profiles/web-frontend.md`](../profiles/web-frontend.md)) holds the stack-specific rules in the same `## #tag` format. Each agent partially loads only its own tags. Every skill passes the `web-frontend` profile; without a profile argument no stack rules are loaded.

### Tag mapping

| Tag | Target agents |
|---|---|
| `#code-rules` | developer / refactor-architect |
| `#filesystem` | developer |
| `#completion` | developer / test-runner |
| `#review` | reviewer |
| `#failure-patterns` | reviewer / test-runner |
| `#org` | developer / reviewer / refactor-architect (lives in `~/.review-harness/org/constraints.md`. Omitted if absent) |

Profile tags (`profiles/web-frontend.md`):

| Tag | Target agents |
|---|---|
| `#code-rules` | developer / refactor-architect |
| `#implementation` | developer |
| `#review` | reviewer |
| `#detection` | refactor-architect |

### Token budget measurement

- `hooks/extract-constraints.sh` and `hooks/post-tool-use.sh` log bytes/estimated tokens to **stderr** on every call
- Warning threshold: 8192 bytes (~2K tokens). It measures the non-profile part; profile bytes are reported separately on the same line
- Override with the environment variable `REVIEW_HARNESS_BUDGET_WARN_BYTES`
- stderr does not reach the agent context — for observation only
- If a `[warn]` line appears, shrink that `constraints.md` section or split it into a smaller tag

### `#failure-patterns` ledger (distilled 2026-07-10)

This ledger keeps **only patterns that other layers cannot catch** — rules already enforced by the static gates in reviewer.md or a profile (`profiles/*.md`) / `#review`·`#org` rules / ESLint(tsc) are not added. 34 of the 40 seeds were duplicates and were removed.

Currently 0 entries (2026-11-16 GC: all 6 removed as older than 90 days).

GC rule: when it exceeds 3072 bytes (observed via extract-constraints.sh stderr), merge similar rules + remove entries 90 days or older.

### Deterministic enforcement (2026-07-10)

Some rules of the duplicate-variable/redeclaration kind are enforced by each repo's ESLint, not by the prompt. Which rules are turned on differs per repo, and the organisation overlay can keep a per-repo summary of the current state. The PostToolUse hook runs `eslint --max-warnings=0` per edited file, so even `warn` rules are blocking in the hook, while existing CI is unchanged.

## RTK integration (optional)

[rtk](https://github.com/rtk-ai/rtk) is a CLI tool that compresses the tokens of command output. The plugin integrates it only as **optional/session-limited/plugin-scoped** — no effect on other projects.

### Modes

| Mode | Behaviour |
|---|---|
| `off` | Raw commands as-is (default) |
| `standard` | Applies `rtk` (git/gh/tsc/eslint/test/grep/find/ls) |
| `aggressive` | standard + `-u` (ultra-compact) |
| `git-only` | `rtk` compresses git/gh only, the rest is raw |

### Choosing a mode

- **First session**: the picker is shown automatically when `/review-harness` is called
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
│   └── constraints.md          # `## #org` constraints section
├── knowledge/
│   ├── index.md                # compact summary loaded automatically at session start
│   └── <org>/
│       ├── repos.md            # repo registry (read by detect-repo.sh)
│       └── *.md                # domain knowledge
├── state/<repo-id>/            # run state (run-state.json, plan.md, etc.)
└── wisdom/                     # cross-project learnings
```

- `hooks/org-overlay.sh <skills|agents> <name>` prints the overlay file. If the file does not exist it prints nothing
- Every `SKILL.md` has its own overlay injected at load time
- `hooks/extract-constraints.sh <agent> [profile]` appends the `#org` section, the profile sections and the agent overlay after the content the orchestrator passes to the agent
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
