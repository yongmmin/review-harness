---
name: component-audit
description: Find reusable components before writing any new UI — searches the installed design-system package (Storybook), other shared packages, then the active repo's local components, and returns ≤3 candidates per source. Use before building a button/tab/card/modal/3D primitive, or when asked "이미 있는 컴포넌트 있어?".
argument-hint: "[what you are about to build]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: component-audit

**Trigger**: `/component-audit [target]` or auto-called before UI work

## Injected Context (at load)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null || true
```

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills component-audit 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

Audit target: `$ARGUMENTS`
**Purpose**: Surface most relevant reusable components without loading unnecessary context. Respect the search order: external packages first.

---

## Workflow

```text
1. detect-repo (injected above)
2. component-auditor agent (`front-harness:component-auditor`) — walks search order:
   a. Installed design-system package (and its Storybook, if it has one)
   b. Other shared packages (e.g. a 3D primitives package, if 3D request)
   c. Active repo's local components/ (or src/components/)
   d. Sister repo reference (mention only, never import)
3. Return up to 3 reuse candidates per source
4. If design-system primitive obviously missing → flag as design-system contribution candidate
5. If 3+ similar local patterns repeat → suggest refactor-architect
```

When spawning the component-auditor agent, pass the output of `bash "${CLAUDE_PLUGIN_ROOT}/hooks/extract-constraints.sh" <agent>` in the spawn prompt (it carries the constraints and the agent's org overlay).

---

## Why External First

- The design-system package provides the canonical primitives (Button, Tag, Tabs). Building locally creates future migration debt
- A shared 3D package owns 3D primitives — duplicating them locally is wrong
- Sister-app components are **reference only** — polyrepo, no cross-app import

---

## Constraints

- Read-only
- Keep result compact enough to paste into handoff block
- Route `grep`/`rg`/`find`/`ls` through `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" <cmd> ...`
- Cite paths AND (for the design system) Storybook URL fragments so user can verify
- Never propose import from a sister app
