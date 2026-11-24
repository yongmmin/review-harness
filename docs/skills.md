# Skills and Agents details

Detailed description moved out of the [README](../README.md). The reference documents at runtime are each `skills/*/SKILL.md`, the situational files next to `skills/review-harness/SKILL.md`, and `agents/*.md`.

## `/review-harness` flow

1. **RTK Mode Gate** — no question: `standard` when the `rtk` binary is installed, else `off`; an inline `--rtk=<mode>`, `REVIEW_HARNESS_RTK` or `/rtk-toggle` overrides it (off/standard/aggressive/git-only)
2. **Active Repo Gate** — `hooks/detect-repo.sh` matches cwd → repo. If there is no registry (`~/.review-harness/knowledge/<org>/repos.md`) it proceeds with the generic rules; for code work in a repo that is not registered (or with no registry at all) it offers `/register-repo` once per work tree; choosing to continue records `register-declined` in the state dir so it is not asked again
3. **Ambiguity Check** — up to 2 questions when ambiguous. Detects requests whose target is unclear, such as demonstratives ("that", "this"), and asks for clarification. The organisation overlay can add detection items
4. **Web Guidance Search** — when a `plan.md` will be written for UI or client-behaviour work under the `web-frontend` profile, up to 3 `npx -y modern-web-guidance@1.0.1 search` calls (stopping at the first failure); the matching guide ids go to `plan.md → Inputs.Web guidance` (`none` or `unavailable` otherwise, never a question). The developer `retrieve`s those ids; the developer's self-check and the reviewer run `legacy-scan` on each changed UI file (at most 5) ([README](../README.md#modern-web-guidance))
5. **Plan Gate** — when the repo has a strategy file (`/strategy`), first a strategy check: is the request the highest-leverage move for its goal? If not, one alternative and one question (`Proceed as asked` / `Do the alternative`), never a block; the outcome is recorded with `run-state.sh strategy`. Then it writes `plan.md` (with a `## Why` line) to `~/.review-harness/state/<repo-id>/`, reports the full path, and waits for user approval (skipped on the Small change path)
6. **Workflow execution** — a different chain per intent (feature/bugfix/refactor/review) or the Small change path. A bugfix reproduces the failure and records its cause before any fix, and never takes the Small change path. UI work is handled as feature
7. **`[DONE]`** — automatic up to git-commit; after that it is in the user's hands

The core `skills/review-harness/SKILL.md` keeps the gates, routing, agent spawning, handoff schema, run state and review gate. Each part only one path needs sits in a sibling file the core names in a `→ read` line, read only on that path: `register-offer.md` (step 2), `api-spec.md` (API Spec Check), `web-guidance.md` (step 4), `strategy-gate.md` (step 5, when a strategy file exists: the strategy check), `plan-gate.md` (step 5: plan template and its rules), `small-change.md`, `bugfix.md` and `retry.md` (step 6: Small change, Bugfix, retries after a failure), `git-ops.md` (branch, push or PR requests).

## 13 Skills

The entry point + auxiliary commands. All can be called as `/<skill-name>`. Every skill has the organisation overlay injected at load via `hooks/org-overlay.sh skills <name>` (if absent, only the generic rules apply).

### Entry point (1)

- **`/review-harness`** — the single public entry point. RTK Mode Gate → Active Repo Gate → Ambiguity Check → Intent Classification → API Spec Check → Web Guidance Search → Plan Gate → workflow execution

### Context / knowledge (3)

- **`/register-repo`** — registers the current repo: `hooks/scan-repo.sh` proposes the `repos.md` block from the repo's files (stack, layout, path alias, `test_cmd`, `check_cmd`, workspaces), up to 3 questions fill in role, commands and team rules (`special`), and the block is appended to the registry only after the user confirms. An already registered repo is shown, not changed

- **`/save-knowledge`** — routes organisation-specific learnings to `~/.review-harness/knowledge/<org>/*.md` and only truly cross-project ones to `~/.review-harness/wisdom/*.md`
- **`/search-knowledge`** — returns only 3 or fewer bullets per source from `~/.review-harness/knowledge/` (`index.md`, `<org>/*.md`) and global wisdom. If knowledge is empty, the call itself is skipped

### TDD (1)

- **`/tdd`** — RED→GREEN for repos with a test framework configured; for repos without one, a graceful skip followed by the implementation + manual verification path

### Review (1)

- **`/code-review`** — 4 general categories (correctness/performance/design/scope). Outputs PASS/FAIL. The organisation overlay can add FAIL gates

### Refactor (1)

- **`/refactor-scan`** — scans codebase patterns → proposes a refactor `plan.md`. No code changes before approval

### Git (3) — **all user-driven**

- **`/git-branch`** — lists existing branches → selects a base (main/stage/production, etc.) → asks for the name → prints the `git checkout -b` command. **Never runs it**
- **`/git-commit`** — runs automatically when `run-state.sh check` passes (a reviewer PASS record for the current work tree and no failed or unconfirmed test result, or a recorded user override). Generates a Conventional Commit message, protects .npmrc/.env, forbids --no-verify
- **`/git-pr`** — generates the title + body + `gh pr create` command + prefilled GitHub compare URL. **Never runs `gh`**

### Plugin operations (3)

- **`/audit-rules`** (`/review-harness:audit-rules`) — runs `hooks/audit-rules.sh` (stale registry versions, missing paths, version-bound overlay rules, duplicate rules, constraint budget, ledger size, age and missing heading), reads only the cited lines, judges `version-rule` and `duplicate` findings, and reads the org overlay and the profiles' `#review` sections once for rules that contradict each other — also when the script finds nothing. Proposes at most 10 numbered edits (file:line, old → new, or delete) and applies only the ones you approve, only under `~/.review-harness/` — never the plugin's files, never git. Ledger GC follows the `constraints.md` header rule
- **`/strategy`** (`/review-harness:strategy`) — shows, sets (at most 3 questions: goal, metric, non-goals) or updates one field of the repo's strategy file, located by `hooks/strategy-file.sh` (`~/.review-harness/strategy/<repo>-<hash>.md`, shared by all worktrees, kept to about 1,000 bytes). Writes only on the user's yes, never a repo file, never runs git. `/review-harness` reads the file before planning
- **`/rtk-toggle`** (`/review-harness:rtk-toggle`) — toggles the output compression mode of plugin-internal Bash calls (off/standard/aggressive/git-only). No effect on other projects (plugin-scoped)

## Git steps (user-triggered)

After the work is complete, the user explicitly:

```
/git-branch              # or "create a branch"
```
→ The plugin lists the current branches → selects a base via AskUserQuestion (main/stage/production, etc.) → asks for the new name → prints the command (the user runs it themselves)

```
git push -u origin <branch>
```
→ The user does this themselves

```
/git-pr                  # or "write the PR body"
```
→ The plugin prints the title + body + `gh pr create ...` command + prefilled GitHub compare URL (the user copies and runs it)

## `/git-pr` output

### Included automatically in the PR body

- **Summary** — why (up to 4 bullets)
- **Changed Areas** — where (folders/modules)
- **Test Plan** — checkboxes
- **QA** — only when the organisation overlay requires it (e.g. QA document update details)
- **Related** — Issue / Plan links

### Example output

```
## PR Ready

### Title
feat: add user-login-form with React Hook Form

### Body
<full markdown>

### Command to run (copy-paste)
gh pr create --base main --head feat/user-login-form ...

### Prefilled URL (browser fallback)
https://github.com/<owner>/<repo>/compare/main...feat/user-login-form?expand=1&title=...&body=...

### Reminders
- Push the branch first if you haven't: git push -u origin feat/user-login-form
```

## 4 Agents

Uses a model alias per role — `fable`/`opus` (YAML frontmatter `model:` + `effort:` + `color:`, including tool scoping). Each agent receives only the `constraints.md` and `profiles/<name>.md` sections it needs (the full files are not passed). Skills pass the output of `detect-profile.sh` — the profiles that match the changed files (developer / refactor-architect: the plan's Affected Files; reviewer: the review target) — and an empty selection loads no stack rules. If an organisation overlay (`~/.review-harness/org/agents/<agent>.md`, `#org` in `~/.review-harness/org/constraints.md`) exists, it is appended to the `hooks/extract-constraints.sh` output and passed along.

| Agent | Role |
|---|---|
| **developer** | TDD RED→GREEN implementation + API integration (handles types → hook/service → UI states inline). Follows the `Reuse` item of `plan.md` |
| **reviewer** | Review in 4 categories (correctness/performance/design/scope) + static gates. The single quality gate before commit. FAILs if `Reuse` in `plan.md` is empty, `[goal]` when a `Done When` item is unmet or new code is a stub or never called, `[scope]` for an `Out of Scope` edit, `[contract]` when a file in `Callers/Consumers` is neither changed nor marked `no change needed`, or a `breaking` `## Contract` lists no consumers or leaves a consumer repo with hits unaddressed. Every issue carries `route: patch \| replan \| defer`; `defer` is never a FAIL reason. Re-judges one disputed issue on request |
| **test-runner** | Records a baseline of already-failing tests before developer, then runs tests (only new failures count), the `Done When` command checks and one whole-project check (`check_cmd` or `tsc --noEmit`), and records the result in `run-state.json`. No fake PASS in repos without tests configured (`no_tests_configured`) |
| **refactor-architect** | Detects pattern duplication + proposes extractions (writes `plan.md` only) |
