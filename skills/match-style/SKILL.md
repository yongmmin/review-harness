---
name: match-style
description: Build new UI without a Figma design by matching the product's existing visual language — design-system primitives first, then neighbor-file className/spacing conventions. For "기존 스타일에 맞춰서 만들어줘", "비슷하게 만들어줘" when no figma.com URL is given.
argument-hint: "<what to build> [reference-component-path]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: match-style

**Trigger**: `/match-style <description>` — `front-harness` routes `ui` intent (no Figma URL) here

## Injected Context (at load)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null || true
```

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills match-style 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

Request: `$ARGUMENTS`
**Purpose**: Build new UI by reusing and extending the product's existing visual language. Respect the active repo's design system adoption state.

---

## Workflow

```text
1. detect-repo (injected)
2. component-auditor (`front-harness:component-auditor`; installed design-system package → local)
3. ui-builder
4. a11y-check
5. reviewer
6. git-commit (auto on PASS)
7. [DONE — await user git ops]
```

For every agent spawned above, pass the output of `bash "${CLAUDE_PLUGIN_ROOT}/hooks/extract-constraints.sh" <agent>` in the spawn prompt (it carries the constraints and the agent's org overlay).

`git-branch` and `git-pr` are user-invoked per Git Operations Policy.

---

## Style Source Order

1. **Installed design-system package** — check it (and its Storybook, if it has one) for the requested primitive. If it exists, use the design-system export. Use its token colors when the design system is wired
2. **Active repo's existing patterns** — match neighbor files' className conventions, spacing rhythm, button/form/card styles
3. **New pattern** — only if neither the design system nor local has it. Justify in handoff

---

## Style Extraction (when the design system doesn't cover)

```tsx
// Follows existing card pattern: rounded-xl border border-gray-200 shadow-sm p-6
// Matches button convention in this repo: primary uses bg-blue-600 text-white
```

Extract from neighbor:
- Colors, typography, spacing rhythm
- Border radius, shadow patterns
- Button / form / card variants

When a design system gets adopted later, replacement is mechanical because we used the same semantic naming.

---

## Constraints

- Inspect existing components BEFORE adding new patterns
- Keep responsive behavior mobile-first
- Do not invent a new design language when the design system or repo already has one
- Do not import from sister apps (only published shared packages are cross-app importable)
- No `console.log` (only `console.error`)
- 3D via `dynamic({ssr:false})`
- No auto-branch / no auto-PR
