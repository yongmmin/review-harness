---
name: save-knowledge
description: Persist a durable learning, decision, or repo fact after a task — routes organisation-specific knowledge to ~/.review-harness/knowledge/<org>/*.md and cross-project wisdom to ~/.review-harness/wisdom. Use for "record this", "remember this" (any language), or when a reusable pattern/gotcha emerged; skip one-off mistakes.
argument-hint: "<what to save>"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: save-knowledge

**Trigger**: `/save-knowledge <topic>` or auto-called after task completion

## Injected Context (at load)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null | grep -E '^- (name|status):' || true
echo "knowledge root: ${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/knowledge"
W="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/wisdom/summary.md"; echo "wisdom summary lines: $([ -f "$W" ] && wc -l < "$W" | tr -d ' ' || echo 0) / 20"
```

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills save-knowledge 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

To save: `$ARGUMENTS`

All `knowledge/...` destinations below are relative to `~/.review-harness/`.
**Purpose**: Persist durable learnings. Organisation conventions go into `knowledge/<org>/`; truly cross-project wisdom goes to the global hub.

Organisation knowledge lives in the `~/.review-harness/knowledge/` folder (outside the plugin): `knowledge/index.md` plus `knowledge/<org>/*.md`. It does not exist until an organisation sets it up. The org overlay, when installed, names `<org>` and the concrete file routing.

---

## Routing Decision (first step)

Classify the learning:

| Type | Destination |
|------|-------------|
| Organisation-specific knowledge (repo registration / metadata, architecture / cross-repo invariant, convention, stack pattern, design system primitive, QA process) | `knowledge/<org>/<topic>.md` — the existing file for that topic |
| **Truly cross-project** wisdom (works in any React/Next codebase, not organisation-specific) | `~/.review-harness/wisdom/<learnings\|decisions\|issues>.md` |
| Component pattern reusable across THIS active repo only | The repo's own docs (plugin doesn't touch — flag for user) |

If unsure → ask user. Don't default to global wisdom for organisation-specific info.

---

## Workflow

1. Determine routing (table above)
2. Open destination file, find appropriate section
3. Append entry (do not delete existing entries unless explicitly compacting). Dedupe first: grep the destination for a key phrase of the new entry — if present, update that line in place
4. Update `~/.review-harness/wisdom/summary.md` if a global-wisdom file was touched (keep summary under 20 lines, prune oldest)
5. Report to user: "Saved to <path> — <section>"

---

## Entry Format

### Organisation knowledge files (`knowledge/<org>/*.md`)
Match existing structure. Use markdown subheadings, tables, code blocks.

### Global wisdom
```
- [YYYY-MM-DD] [project-name] content
```

### summary.md (global wisdom)
```markdown
# Wisdom Summary
> 20-line limit.

## Learnings
- [keep latest 3 only]

## Decisions
- [keep latest 3 only]

## Issues
- [keep latest 3 only]
```

---

## Triage

### Save to `knowledge/<org>/` when:
- Learning is about repo structure, env config, deployment, GitHub Packages auth
- Pattern uses the organisation's internal packages
- Convention is documented in any `.claude/CLAUDE.md` across the organisation's repos
- Failure mode is repo-specific

### Save to global wisdom when:
- Learning applies to ANY React/Next.js codebase (e.g. "useEffect cleanup is necessary for subscriptions")
- Not tied to the organisation's stack choices
- Could be useful if user worked on a totally unrelated personal project

### Skip saving when:
- It's already documented in the affected repo's own docs
- It's a one-off mistake (typo, file-specific edge case)
- It's a temporary workaround rather than a stable rule

---

## Constraints

- `summary.md` must never exceed 20 lines
- learnings/decisions/issues.md have 300-line limit
- Always include project/repo name in each entry for traceability
- Never duplicate an entry that already exists — update in place if newer info available
- For organisation-specific info, default to `knowledge/<org>/` not global wisdom — global is for cross-project lessons only
- Never write to a repo's own `docs/` from this skill — that's the user's action in the relevant repo session
