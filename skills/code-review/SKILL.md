---
name: code-review
description: Compact PASS/FAIL code review of uncommitted or branch changes via the reviewer agent ("review this", "check this" in any language, before push/PR). Applies the org overlay's FAIL gates and pre-push review format when one is installed and the active repo is registered.
argument-hint: "[path-or-scope] [--base <branch>]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*) Bash(git status *) Bash(git diff *) Bash(git log *) Bash(git branch *)
---

# Skill: code-review

**Trigger**: `/code-review [scope]`, "review this" (any language), or auto-chained after implementation

## Injected Context (at load — do not re-run)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null || true
echo "branch: $(git branch --show-current 2>/dev/null)"
echo "--- uncommitted (stat) ---"; git diff --stat 2>/dev/null | tail -25 || true
echo "--- staged (stat) ---"; git diff --cached --stat 2>/dev/null | tail -25 || true
echo "--- ahead of main (name-status) ---"; git diff main...HEAD --name-status 2>/dev/null | head -60 || true
```

- 5h usage: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/usage-state.sh" 2>/dev/null || echo unknown`

Usage downgrade (same rule as `review-harness` → Agent Spawning): if the `5h usage` value above is 80% or higher, ask once with `AskUserQuestion` before spawning — state the usage and reset time, options `Keep Fable` | `Opus for this run` (ask in the user's language). On Opus, pass `model: "opus"` to the Agent tool; otherwise pass no `model`. Below 80% or `unknown`: do not ask. If `review-harness` already asked in this run, reuse that answer.

Risk tier (same rule as `review-harness` → Agent Spawning): when the review target is a diff (not an explicit path), run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/risk-tier.sh" [base]` (the `--base` branch, or `main`, when the target is the branch diff) before spawning and pass its output as `risk: <tier>` plus its `reason:` lines; the script fails → `risk: normal`. `low` → pass `model: "opus"` and `effort: "medium"`; `normal` / `high` → no override; `Keep Fable` does not change `low`. An explicit path target gets no `risk:` line.

Scope hint from user (may be empty): `$ARGUMENTS`

Review target precedence: explicit `$ARGUMENTS` path → uncommitted + staged diff → if both empty, the branch diff vs `main` (or `--base`). If all are empty, say so and stop — never review the whole repo.

**Purpose**: Produce compact PASS/FAIL review with actionable findings. Apply the org overlay's FAIL gates when active repo is registered.

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills code-review 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

---

## Workflow

```text
1. detect-repo (already injected)
2. spawn reviewer (Agent tool, subagent_type `review-harness:reviewer`; bare `reviewer` if not namespaced)
   -> pass ONLY: the output of `bash "${CLAUDE_PLUGIN_ROOT}/hooks/extract-constraints.sh" reviewer "$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-profile.sh" <paths>)"`
      (`<paths>` = the review target's file list — the explicit path, or the branch diff's files; nothing when the target is the uncommitted diff, which detect-profile.sh reads itself. The output carries the constraints, the selected profiles' sections and the agent's org overlay),
      the Active Repo block, the file list above, the review target, and the verdict command
      `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-state.sh" verdict <PASS|FAIL> [FAIL issue categories...] --by reviewer`. Reviewer reads diffs itself
      and records its own verdict with that command (the script stores the work-tree hash).
      No `review: … recorded` line in the reply -> spawn reviewer once more to record it. Still missing ->
      no verdict: never record it yourself; report that to the user. git-commit stays blocked.
3. On FAIL -> return compact fix list, with each issue's `route:` (`defer` issues are notes, not FAIL reasons)
4. On PASS -> report PASS. No commit follows from this skill; a later git-commit verifies the recorded verdict with `run-state.sh check`
```

If push-intent detected (user said push/PR) and the org overlay defines a pre-push review format, reviewer outputs that format instead of PASS/FAIL.

---

## Review Scope

### Generic (always)
- Stack-specific checks: the `#review` section of the profile passed to the reviewer
- Security and secrets
- Loading, empty, error states present
- Regressions and duplicated patterns
- Design quality (reuse over duplicate, single responsibility, abstraction adequacy)

### Org-specific (when active repo registered)
- The checks listed in the Org Overlay section above, if an overlay is installed

---

## Constraints

- Use `reviewer` agent only
- Keep output concise and actionable
- Cite file:line for every finding
- Org overlay rules apply only when the injected Active Repo block matched
- Reviewer verdict is final output — no commit/push follows from this skill (git-commit auto-chains only inside `review-harness`)
