---
name: git-commit
description: Create a scoped Conventional Commit after reviewer PASS (auto-chained by review-harness, or "commit this" after a review). Stages intended files only, runs pre-commit checks (plus the org overlay's, if installed), never pushes.
argument-hint: "[scope-or-note]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*) Bash(git status *) Bash(git diff *) Bash(git log *) Bash(git branch *) Bash(git add *) Bash(git commit *) Bash(git rev-parse *)
---

# Skill: git-commit

**Trigger**: called by `review-harness` after reviewer PASS (auto-chained), or `/git-commit` by the user once a review has passed

## Injected Context (at load — do not re-run)

```!
echo "branch: $(git branch --show-current 2>/dev/null)"
echo "--- status ---"; git status --porcelain 2>/dev/null | head -60 || true
echo "--- staged stat ---"; git diff --cached --stat 2>/dev/null | tail -20 || true
```

**Purpose**: Commit staged changes with Conventional Commit messages. Verify repo conventions before committing.

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills git-commit 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

---

## Workflow

1. **Verify reviewer PASS from the state file** — run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" check`. Never rely on what the conversation says about the review
   - exit 0 → proceed
   - exit 1 → abort and report the printed reason. "code changed after the review" means the reviewer must run again on the current changes; a failed test run, or code changed after the test run, means test-runner must pass again on the current changes; a missing manual confirmation means the user must confirm the manual checks first (`review-harness` → No tests)
   - exit 3 (no state) → no review is on record: ask the user to run `/code-review` first, or to explicitly override
   - exit 4 (stale run) → show the message and ask the user whether to resume or abandon that run
   - Explicit user override ("commit without review") → record it with `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" override "<user's reason>"`, then proceed. The `commit-gate.sh` hook enforces the same check on `git commit`
2. **Detect active repo** via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD"` (skip if `review-harness` already injected the Active Repo block this session)
3. **Stage intended files only** — never `git add .` / `git add -A`
4. **Pre-commit checks**:
   - Verify no `.env*` file is staged
   - Verify no secrets in diff (basic regex: `API_KEY=`, `SECRET=`, `password=`, `BEGIN PRIVATE KEY`)
   - Verify no `.npmrc` is staged
   - Verify `plan.md` and `.front-harness-cache/` are NOT staged (legacy leftovers from < 0.4.0 — the plugin now keeps them in `~/.review-harness/state/`)
5. **Generate Conventional Commit message** (see format below)
6. **Run `git commit`** with the message (this is the auto-chained step that DOES execute)
7. After the last commit of the run, close it: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" done`
8. **Never push** — push is user's action (see Git Operations Policy)

---

## Conventional Commit Format

```
<type>(<scope>): <subject>

<body>

Co-Authored-By: Claude <noreply@anthropic.com>
```

### Type
- `feat` — new feature
- `fix` — bug fix
- `refactor` — code restructure, no behavior change
- `style` — formatting/style only
- `docs` — documentation
- `test` — tests added/modified
- `chore` — tooling, config, dependencies
- `perf` — performance improvement
- `ui` — UI/visual changes

### Scope (optional but recommended)
- Use the domain name from `docs/{domain}/` if applicable
- e.g. `feat(events): add capture event filter`
- e.g. `refactor(tools): extract useToolInteraction hook`

### Subject
- ≤ 70 chars
- Imperative mood ("add", not "added")
- No trailing period
- Korean OK for the subject if the team convention uses it; English preferred for cross-repo consistency

### Body
- Wrap at 72 chars
- 2-4 short paragraphs MAX
- WHY over WHAT

---

## Output Format (after commit)

```
## Committed

Branch:  <current-branch>
Hash:    <short-sha>
Message: <first line of commit message>

### Files
- path/to/file1.tsx
- path/to/file2.test.tsx

### Next steps (user-driven)
- Push yourself: git push -u origin <branch>
- Ready for a PR: /git-pr
```

---

## Constraints

- Stage only intended files (`git add <path>` per file). Never `git add .` / `git add -A`
- Never commit secrets, `.npmrc`, or `.env*` files
- Never commit with failing tests (or, for no-test repos, without the user's confirmation of the manual checks)
- Never use `--no-verify` to bypass hooks
- Route `git` inspection beyond the injected block (`diff`, `log`) through `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" git ...`
- Never stage `plan.md`, `.front-harness-cache/`, `.env*`, `.npmrc`
- Never push — that's user-driven
