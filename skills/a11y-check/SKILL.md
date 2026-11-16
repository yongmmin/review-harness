---
name: a11y-check
description: Accessibility audit of implemented UI (semantic HTML, ARIA, keyboard, contrast, lang) with 3D specifics — R3F Canvas aria-label, non-3D fallbacks. Auto-chained after ui-builder; also for "접근성 확인해줘", "a11y".
argument-hint: "[component-or-path]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh *)
---

# Skill: a11y-check

**Trigger**: `/a11y-check [path]` or auto-called after UI implementation

Target (may be empty → files changed in this task): `$ARGUMENTS`
**Purpose**: Verify a11y compliance. Cover semantic HTML, ARIA, keyboard, contrast — and 3D Canvas patterns.

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills a11y-check 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

---

## Checklist

### Semantic HTML
- [ ] Headings in correct hierarchy (h1 → h2 → h3)
- [ ] Lists use `ul`/`ol`/`li`
- [ ] Buttons use `<button>`, links use `<a href>`
- [ ] Forms use `<label>` with `htmlFor`
- [ ] Landmark regions: `<main>`, `<nav>`, `<header>`, `<footer>`

### ARIA
- [ ] Images have descriptive `alt` (or `alt=""` if decorative)
- [ ] Icon-only buttons have `aria-label`
- [ ] Loading states use `aria-live` or `aria-busy`
- [ ] Modal dialogs have `role="dialog"` and `aria-modal`
- [ ] No `aria-hidden` on focusable elements

### Keyboard Navigation
- [ ] All interactive elements keyboard-focusable
- [ ] Focus order logical
- [ ] Focus visible (no `outline: none` without replacement)
- [ ] Modals trap focus correctly

### Forms & Feedback
- [ ] Every input has a programmatic label; error messages linked via `aria-describedby` and announced (`role="alert"` or `aria-live`)
- [ ] Required/invalid state exposed via `aria-required` / `aria-invalid`, not color only

### Motion & Timing
- [ ] Animations respect `prefers-reduced-motion` (Tailwind `motion-reduce:` / `motion-safe:`); no auto-playing 3D camera motion without a pause path
- [ ] No content that flashes > 3 times/sec

### Color & Contrast
- [ ] Text contrast ratio ≥ 4.5:1 (normal)
- [ ] Text contrast ratio ≥ 3:1 (large)
- [ ] Information not conveyed by color alone
- [ ] When using design-system tokens, contrast is pre-verified if the design system's Storybook has the a11y addon. When local colors, verify with a tool

### Language & 3D
- [ ] Page `<html>` element has correct `lang` attribute for the UI language. Check `app/layout.tsx`
- [ ] 3D `<Canvas>` from R3F has `aria-label` describing the scene (since it's a single rendered surface, not navigable by screen readers — provide a textual summary)
- [ ] Keyboard alternatives for 3D interactions: if drag-to-rotate is the only way to interact, provide keyboard arrows or buttons too (where feasible)
- [ ] Interactive elements inside the 3D scene (click/hover for object info) should have a non-3D fallback list/table for screen-reader users — check if active feature provides one

---

## Output Format

```
## A11y Check Results: PASS / FAIL

### Issues (if FAIL)
1. [component:element] — [issue] → [fix]

### Warnings (non-blocking)
- [suggestion]
```

---

## Constraints

- Always run after any UI implementation
- FAIL items must be fixed before PR
- Prefer the repo's own tooling as evidence when available: `eslint-plugin-jsx-a11y` results, Storybook a11y addon output. A checklist pass without evidence is a Warning, not a PASS
- 3D Canvas a11y is best-effort — Three.js scene is not screen-reader navigable. Provide text/list alternatives at the page level
