---
name: rtk-toggle
description: Set or show the rtk token-compression mode (off | standard | aggressive | git-only) that review-harness applies to its internal git/tsc/eslint/test/grep calls this session. Plugin-scoped, no global hook. Invoke as /rtk-toggle <mode> or /rtk-toggle status.
argument-hint: "[off|standard|aggressive|git-only|status]"
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh *) Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh *)
---

# Skill: rtk-toggle

**Trigger**: `/rtk-toggle [mode]` (plugin-namespaced: `/review-harness:rtk-toggle`). `/rtk` in older docs refers to this skill.

Current mode (injected): !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" --mode 2>/dev/null || echo off` · env override `REVIEW_HARNESS_RTK`: !`echo "${REVIEW_HARNESS_RTK:-unset}"` · rtk binary: !`command -v rtk >/dev/null 2>&1 && rtk --version 2>/dev/null | head -1 || echo "not installed (raw fallback)"`

Requested: `$ARGUMENTS`
**Purpose**: Let user choose whether this plugin's internal Bash calls (tsc, eslint, git, gh, test runners, grep/find/ls) pipe through `rtk` for token compression.

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills rtk-toggle 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

---

## Modes

| Mode | Behavior |
|------|----------|
| `off` | Raw commands. Default when `rtk` is not installed |
| `standard` | `rtk` applied to git/gh/tsc/eslint/test/grep/find/ls. Default when `rtk` is installed |
| `aggressive` | Same as `standard` plus the `--ultra-compact` flag |
| `git-only` | `rtk` applied only to git/gh; everything else raw |

In every mode `git diff`, `git show` and `gh … diff` run raw: rtk truncates them, and the reviewer reads the change through them.

---

## Trigger Routes

1. **Explicit arg**: `/rtk-toggle standard`, `/rtk-toggle off`, etc. — write mode and report
2. **No arg**: launch AskUserQuestion picker, let user choose
3. **Status query**: `/rtk-toggle status` — print currently resolved mode without change

---

## Resolution Order (read by `${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh`)

1. `REVIEW_HARNESS_RTK` env var — hard override, never touched by this skill
2. `~/.review-harness/state/<repo-id>/rtk-session.flag` — written by this skill and by `/review-harness` (per work tree, outside the repo)
3. Default: `standard` when the `rtk` binary is on PATH, else `off` (only the real rtk counts: `rtk --version` starts with `rtk`)

---

## Implementation

### When user provides mode arg

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" --set <mode>
```

Valid modes: `off | standard | aggressive | git-only`. Reject others with one-line error.

### When user runs `/rtk-toggle status`

Report the injected `Current mode` value — no command needed. If `REVIEW_HARNESS_RTK` is set, mention env var is overriding flag file.

### When user runs `/rtk-toggle` with no arg

Use `AskUserQuestion` with one question, 4 options (off / standard / aggressive / git-only). After answer, persist with `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" --set <answer>`.

---

## Output

Single compact line:

```
rtk mode: standard (session flag written)
```

No prose, no emojis, no explanation of rtk internals.

---

## Guarantees

- Never installs or uninstalls rtk globally: never run `rtk init -g`, never write rtk hooks to `~/.claude/settings.json`
- Only writes `rtk-session.flag` in the plugin state dir (`~/.review-harness/state/<repo-id>/`) — nothing in the consumer repo
- If rtk is not installed, mode still writes; `rtk-wrap.sh` silently falls back to raw at runtime
