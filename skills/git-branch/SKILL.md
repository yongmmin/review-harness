---
name: git-branch
description: Suggest a task branch name with explicit base-branch selection. Lists existing branches, asks which base, prints the create command. Never executes git — the user runs it.
argument-hint: "[new-branch-name]"
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/state-dir.sh *) Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh *) Bash(git branch *) Bash(git status *) Bash(git log *) Bash(git remote *) Bash(git rev-parse *)
---

# Skill: git-branch

**Trigger**: user-invoked only — the user runs `/git-branch [name]` (this skill is hidden from model invocation)
**Purpose**: Help the user create a task branch by **first discovering existing branches**, then asking which base to fork from, then suggesting a name. **Plugin does NOT execute git commands** — it prints the command the user runs themselves.

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills git-branch 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

---

## Policy

- Plugin never runs `git branch` / `git checkout -b` / `git switch -c` / `git fetch` / `git pull`
- Plugin only **reads** (`git branch -a`, `git remote -v`) to discover existing state
- Plugin asks for base + name and prints a copy-pasteable command
- User executes the commands — keeps full control over local git state

---

## Workflow

### Step 1 — Discover existing branches

Already injected at load — do **not** re-run:

```!
echo "current: $(git branch --show-current 2>/dev/null || echo '(detached/no git)')"
echo "--- branches (local + remote) ---"
git branch -a --format='%(refname:short)  %(committerdate:relative)  %(subject)' 2>/dev/null | head -60 || true
echo "--- uncommitted: $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') path(s) ---"
```

Requested name (may be empty): `$ARGUMENTS`

Parse the block above and categorize:
- **Current branch** (where user is now)
- **Integration branches** — name matches one of: `main`, `master`, `develop`, `development`, `stage`, `staging`, `production`, `prod`, `release`
- **Other branches** — skipped for selection but countable

Note: only inspects what's already known locally. If remote refs look stale, mention it but do not auto-fetch.

### Step 2 — Confirm base branch

If exactly ONE integration branch exists locally → default to it, confirm with one-line question
If MULTIPLE candidates → ask via `AskUserQuestion`:

> "Which branch should it fork from?" (ask in the user's language)

Options (max 4, ordered by precedence):
1. The branch the user is currently on, if it's an integration branch
2. `main` or `master` if present
3. Other integration branches in order: `develop` → `stage`/`staging` → `production`/`prod` → `release`

For each option, label format: `<name> — <last commit subject snippet>` (if compactly available via `git log -1 --format=%s <branch>`).

`AskUserQuestion` auto-includes "Other" — user can type any branch name not in the preset list (including remote-only branches).

If user picks a branch that is **remote-only** (e.g. `origin/stage` not present locally), the printed command uses `origin/<base>` form (see Step 4).

### Step 3 — Confirm new branch name

- If user provided a name inline (`/git-branch <name>`) → skip if already valid prefix; else normalize and confirm
- Otherwise ask: "What should the branch be called?" (ask in the user's language). Single text input
- If active task has `plan.md` (it lives in the plugin state dir: `$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/state-dir.sh")/plan.md`, not in the repo), suggest its `## Branch` line as default

Validate against naming convention (below). If invalid, normalize and ask user to confirm.

### Step 4 — Print the command

Two patterns depending on base state:

**Local base (default — no network)**
```bash
git checkout <base>
git checkout -b <new-name>
```

**Remote base (fresher, if user wants up-to-date)**
```bash
git fetch origin <base>
git checkout -b <new-name> origin/<base>
```

---

## Naming Convention

| Type | Prefix | Example |
|------|--------|---------|
| Feature | `feat/` | `feat/user-login-form` |
| Bug fix | `fix/` | `fix/cart-quantity-overflow` |
| Refactor | `refactor/` | `refactor/auth-module` |
| Redesign | `redesign/` | `redesign/header-nav` |
| UI | `ui/` | `ui/product-card` |
| Hotfix | `hotfix/` | `hotfix/payment-500-error` |

Rules:
- Lowercase only
- Hyphens between words (no spaces, no underscores)
- Prefix must match the work type

---

## Output Format

```
## Branch suggestion

Base:       <base-branch>   (local | remote-only)
New name:   <prefix>/<task-name>
Current:    <current-branch> (where you are now)

### Commands to run

# Option A — start from local base (no network)
git checkout <base>
git checkout -b <new-name>

# Option B — start from remote base (fresher)
git fetch origin <base>
git checkout -b <new-name> origin/<base>

### Notes
- Confirm you have no uncommitted changes before switching branches
- If <base> is behind origin, prefer Option B
- Push later with: git push -u origin <new-name>
```

If the user's current branch already has uncommitted changes, append a warning:
> "⚠️ uncommitted changes detected — stash or commit before switching."

(Detection: the injected `uncommitted:` count is non-zero. Read-only.)

---

## Constraints

- **Never execute git commands that change state** — only read (`git branch -a`, `git status --porcelain`, `git log -1 --format=%s`, `git remote -v`, `git branch --show-current`)
- **Never run `git fetch` automatically** — only print it in the command for the user
- **Never push** — push is a separate user action
- If `plan.md` exists, the `## Branch` line is the canonical name default
- If user types `/git-branch <name>` with `<name>` already having a valid prefix, use as-is. Else prepend the inferred prefix from intent
- Any further inspection beyond the injected block goes through `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" git ...` when rtk mode is on
