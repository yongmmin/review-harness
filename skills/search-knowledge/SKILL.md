---
name: search-knowledge
description: Return ≤3 compact bullets per source from ~/.front-harness/knowledge (knowledge/<org>/*.md for the active repo, knowledge/index.md, ~/.front-harness/wisdom) for a query — never full files. Auto-called by front-harness before planning; also "이거 관련해서 기록된 거 있어?".
argument-hint: "<query>"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: search-knowledge

**Trigger**: `/search-knowledge <query>` or auto-called by `front-harness`

## Injected Context (at load)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null | grep -E '^- (name|status):' || true
bash "${CLAUDE_PLUGIN_ROOT}/hooks/knowledge-has-content.sh" 2>/dev/null && echo "knowledge: has content" || echo "knowledge: EMPTY — answer 'No relevant entries found' and stop"
echo "knowledge root: ${FRONT_HARNESS_HOME:-$HOME/.front-harness}/knowledge"
```

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills search-knowledge 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

Query: `$ARGUMENTS`
**Purpose**: Load only smallest useful knowledge slice for current task. Prefer organisation knowledge when active repo is registered.

---

## Search Order

All `knowledge/...` paths below are relative to `~/.front-harness/`. Organisation knowledge lives in the `~/.front-harness/knowledge/` folder (outside the plugin): `knowledge/index.md` plus `knowledge/<org>/*.md`. It does not exist in a fresh clone (the injected `knowledge:` line then says EMPTY).

### When the injected Active Repo `name:` matched a registered repo:
1. `knowledge/<org>/*.md` — only the file(s) whose topic the query touches
2. `knowledge/index.md` — fallback for general project overview
3. `~/.front-harness/wisdom/summary.md` — only if query is broad/cross-project
4. Detail files in `~/.front-harness/wisdom/` — last resort

### When unmatched (no active registered repo):
1. `~/.front-harness/wisdom/summary.md`
2. `knowledge/index.md`
3. Detail files:
   - `~/.front-harness/wisdom/learnings.md`
   - `~/.front-harness/wisdom/decisions.md`
   - `~/.front-harness/wisdom/issues.md`
   - `knowledge/<org>/*.md` if query mentions organisation-related terms

---

## Fast-Skip Rules

- **Pre-spawn skip**: the injected `knowledge:` line already ran `knowledge-has-content.sh`. EMPTY → return `No relevant entries found` inline and stop — no agent spawn, no file reads
- Summaries contain only placeholders or no relevant matches → stop early
- Do not open detail files unless summary/index suggests relevant hit
- Do not load unrelated domains "just in case"

---

## Output Format

```markdown
## Knowledge Search: "[query]"

### Organisation (active repo: <name>)
- [max 3 one-line bullets from knowledge/<org>/*]

### Project (knowledge/index.md)
- [max 3 one-line bullets]

### Global wisdom
- [max 3 one-line bullets]
```

Rules:
- Max 3 bullets per section
- One line per bullet
- Prefer summaries over excerpts
- Cite source file:section in each bullet
- If nothing relevant: `No relevant entries found`
- Omit sections that have no hits

---

## Constraints

- Read-only — run inline (no subagent) unless the query spans 3+ knowledge files; then fork `Explore`
- Keep results compact enough to paste into next agent prompt
- When active repo is a registered repo, prioritize `knowledge/<org>/` over global wisdom
- Never load full files — extract only the relevant section
