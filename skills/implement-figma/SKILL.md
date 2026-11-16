---
name: implement-figma
description: Implement a Figma frame as production React/Next.js UI — component-auditor → ui-builder → pixel-check → a11y-check → reviewer → git-commit. Uses the repo's design-system tokens/primitives first, dynamic({ssr:false}) for 3D. Trigger on any figma.com URL with an implementation ask ("이거 구현해줘", "피그마대로 만들어줘").
argument-hint: "<figma-url> [target-path]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: implement-figma

**Trigger**: `/implement-figma <figma-url>` — `front-harness` routes `figma` intent here

## Injected Context (at load)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null || true
```

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills implement-figma 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

Inputs: `$ARGUMENTS` — a `figma.com/design/<fileKey>/...?node-id=<a-b>` URL is required (nodeId `a-b` → `a:b`). If missing, ask for it before anything else.

**Purpose**: Build production-ready UI from Figma with compact verification. Respect the active repo's stack and design-system adoption status.

---

## Workflow

```text
1. detect-repo (injected — active repo, Tailwind version, design-system adoption state)
2. Parse Figma URL → fileKey + nodeId. Load the `figma-design-to-code` skill if listed, then `get_design_context` (+ `get_screenshot`) — the output is a REFERENCE to adapt to repo components/tokens, never pasted verbatim
3. component-auditor (`front-harness:component-auditor`; installed design-system package → local search order)
4. ui-builder (`front-harness:ui-builder`) — hand it: the design context excerpt, audit candidates, Active Repo block, extract-constraints output
5. pixel-check
6. a11y-check
7. reviewer
8. git-commit (auto on PASS)
9. [DONE — report ready, await user git ops]
```

For every agent spawned above, pass the output of `bash "${CLAUDE_PLUGIN_ROOT}/hooks/extract-constraints.sh" <agent>` in the spawn prompt (it carries the constraints and the agent's org overlay).

`git-branch` and `git-pr` are NOT auto-chained — they are user-invoked per Git Operations Policy in `skills/front-harness/SKILL.md`.

---

## Rules

### Design System first
- Before implementing a primitive (Button, Tag, Tabs, Modal, etc.) from the Figma spec, check the installed design-system package (and its Storybook, if it has one)
- If it exists there → use it
- Map Figma color/spacing/radius tokens to design-system tokens when a design system is adopted in this app
- If no design system is wired in the active repo yet, implement locally but use the same naming so future migration is mechanical

### Three.js / 3D scenes
- If Figma includes 3D viewport mockups, use the repo's existing 3D scene primitives/package when it has one
- Always `dynamic(() => import(...), { ssr: false })`
- Layout/positional Figma values map to camera config (orthographic for 2D, perspective for 3D)

### Tailwind version
- Active repo's Tailwind version affects class generation:
  - v3: `tailwind.config.ts` is the spec
  - v4: `@theme` in CSS + `@source` for libs

---

## Constraints

- Use design-system primitives when they exist (check the package/Storybook first, build locally only if missing)
- Keep responsive behavior mobile-first
- Prefer design-system tokens or repo's Tailwind config over raw Figma hex values
- All 3D imports via `dynamic({ssr:false})`
- No `console.log` (only `console.error`)
- No auto-branch / no auto-PR — user runs `/git-branch` and `/git-pr` explicitly when ready
