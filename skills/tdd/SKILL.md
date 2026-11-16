---
name: tdd
description: Implement a feature test-first (RED → GREEN → REFACTOR) with the developer agent; for repos without a test framework falls back to implementation + manual verification. Use for "tests first", "do it with TDD" (any language), or any feature/logic change where a test runner exists.
argument-hint: "<feature description>"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: tdd

**Trigger**: `/tdd <feature description>` — `front-harness` `feature` flow uses this cycle

## Injected Context (at load)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null || true
echo "--- test tooling probe ---"
[ -f package.json ] && node -e 'const p=require("./package.json");const s=p.scripts||{};console.log("scripts:",Object.keys(s).filter(k=>/test|vitest|jest|playwright|e2e/i.test(k)).join(", ")||"none");const d={...p.dependencies,...p.devDependencies};console.log("frameworks:",["vitest","jest","@playwright/test","@testing-library/react","cypress"].filter(k=>d[k]).join(", ")||"none")' 2>/dev/null || echo "no package.json in cwd"
```

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills tdd 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

Feature: `$ARGUMENTS`

**Purpose**: Execute full TDD cycle with minimal agent fan-out. Adapts behavior per repo's test maturity.

---

## Workflow

```text
1. detect-repo                  -> injected
2. framework status             -> from the injected probe: any test script/framework = configured, else no_tests_configured (no agent spawn needed for the probe)
3a. If configured:
    developer            -> RED + GREEN
    test-runner          -> verify pass/fail
    refactor-architect?  -> only if real duplication or design debt
    reviewer             -> final review
3b. If no_tests_configured:
    developer            -> implementation
    user manual verify   -> front-harness asks user to manually verify
    reviewer             -> final review
```

For every agent spawned above, pass the output of `bash "${CLAUDE_PLUGIN_ROOT}/hooks/extract-constraints.sh" <agent>` in the spawn prompt (it carries the constraints and the agent's org overlay).

---

## RED (only when framework configured)
- Write tests first
- Confirm they fail for the intended reason
- Tests describe behavior, not internals

## GREEN
- Implement smallest change to pass
- Hand off to `test-runner`

## REFACTOR
- Run only if meaningful duplication or design debt
- Re-run tests after refactor (or re-verify manually for no-test repos)

---

## Per-Repo Test Reality

The injected probe is the truth about whether a test framework is configured.

When skipping RED:
- Plugin reports `"TDD skipped — no test framework configured for this repo. Falling back to implementation + manual verification."`
- Developer implements

---

## Constraints

- Never skip RED when framework IS configured
- Never weaken tests to force GREEN
- Never fake "pass" status when no tests run — use the no_tests_configured fallback
- Keep outputs compact; test evidence comes from `test-runner`
