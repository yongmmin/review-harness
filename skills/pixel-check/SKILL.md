---
name: pixel-check
description: Compare implemented UI against a Figma frame and report only blocker-level deviations (spacing >4px, typography, raw hex instead of design-system tokens, missing interactive states, missing 'use client'/dynamic ssr:false). Auto-chained after ui-builder in the Figma flow; also "피그마랑 비교해줘".
argument-hint: "[figma-url] [component-path]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: pixel-check

**Trigger**: `/pixel-check [figma-url]` or auto-called after `ui-builder`

## Injected Context (at load)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null || true
```

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills pixel-check 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

Inputs: `$ARGUMENTS`
**Purpose**: Flag only deviations large enough to matter before review. Verify tokens come from the design system when one is wired.

---

## Check Criteria

| Category | Check | Blocker threshold |
|----------|-------|-------------------|
| Spacing | gap/padding/margin match 4px grid | >4px off |
| Typography | font size/weight/line-height/letter-spacing | Any deviation |
| Color | Design-system token used when a design system is adopted; or repo's Tailwind config when not | Raw hex / rgba in production code |
| Component | Design-system primitive used when one exists | Local re-implementation of an existing design-system primitive |
| 3D | Existing 3D package primitive used when applicable | Custom Three.js when the package covers it |
| States | hover/focus/disabled/loading/error rendered | Any interactive state missing |
| Responsive | breakpoint behavior matches Figma variants | Layout breaks at defined breakpoint |
| `'use client'` | Present on every component using hooks/browser APIs | Missing |
| `dynamic({ssr:false})` | Wraps Three.js / LiveKit / browser-only imports | Missing — causes SSR crash |

---

## Workflow

```text
1. detect-repo (injected — design-system adoption status, Tailwind version)
2. Figma MCP: `get_screenshot` for the visual, `get_design_context` for tokens/spacing (load the `figma-design-to-code` skill first if the session lists it). Never eyeball from memory — if the Figma MCP is unavailable, report `Pixel check skipped — Figma MCP not connected` and stop
3. Compare against check criteria above
4. Cross-check: are design-system primitives used where applicable?
5. Report only blocker-level or major deviations
```

---

## Notes

- **Design-system adoption status per repo**: check whether the active repo's `globals.css` imports the design system's tokens. If present → design-system tokens are required. If absent → repo's own Tailwind config is the spec (don't fail for missing design-system tokens yet)
- **Tailwind v3 vs v4**: class generation differs slightly — verify the actual classes resolve in the active repo's setup
- **3D package coverage**: if Figma shows a 3D viewport and the repo has a 3D primitives package, the implementation should use it, not custom Three.js

---

## Output Format

```markdown
## Pixel Check Results

### Blockers
- [element]: [expected] vs [actual]

### Notes
- [non-blocking major deviation]

Overall: PASS | NEEDS REVISION
```

Rules: omit empty sections. Ignore minor browser rendering differences.
