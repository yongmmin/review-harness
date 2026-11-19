---
name: strategy
description: Show, set or update this repo's strategy file (goal, metrics, hypotheses, decisions, kill criteria, non-goals) that /review-harness checks a request against before planning. Writes only on the user's yes, inside ~/.review-harness/. Invoke as /strategy [show | set | update <what>].
argument-hint: "[show | set | update <what>]"
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: strategy

**Trigger**: `/strategy [show | set | update <what>]` (plugin-namespaced: `/review-harness:strategy`)

**Purpose**: One small file per repo names the goal the work serves. `/review-harness` reads it before writing a plan, asks whether the request is the highest-leverage move, and records whether its advice was taken. This skill is the only thing that edits the file.

## Injected Context (at load — do not re-run)

```!
f=$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/strategy-file.sh" 2>&1) && { echo "file: $f"; cat "$f" 2>/dev/null || echo "(no strategy file yet)"; } || echo "unavailable: $f"
```

`unavailable:` → report that line (the folder is not a git repo) and stop. The file is shared by every worktree of the repo.

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills strategy 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

---

## Template

```
# Strategy — <repo name>
Goal: <the outcome the work serves, one line>
Metrics: <metric current-value (n=…)> · <metric current-value>
Hypotheses:
- [untested] <a change that should move a metric>
Decisions: <settled choices, `;`-separated>
Kill criteria: <when a rule, step or feature is removed>
Non-goals: <what the work will not do>
```

Hypothesis status words: `[untested]`, `[trying]`, `[valid]`, `[invalid]`.

## Workflow

- **No argument or `show`** — print the file as injected, or say there is none yet and offer `set`.
- **`set`** (also the first use) — ask at most 3 questions, in one `AskUserQuestion` when possible: goal, metric, non-goals. Fill the template from the answers (hypotheses, decisions and kill criteria may stay as one placeholder line each), show the full file and write it to the `file:` path only on the user's yes. An existing file is replaced only on that yes too.
- **`update <what>`** — one field: a hypothesis status, a decision line or a metric value. For a metric, `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-stats.sh" --repo <work-tree name> --since 30` gives the current first-review PASS rate and tokens per run. Show the old and the new line, and edit only on the user's yes.
- **Size** — keep the file at or under about 1,000 bytes. When an edit would pass that, merge the older decisions into one shorter line in the same edit and show it.

## Constraints

- Writes only the `file:` path (Write creates its folder); never a repo file
- It never runs git, and never edits before the user's yes
- Organisation content stays in `~/.review-harness/`; never copy it into a repo
