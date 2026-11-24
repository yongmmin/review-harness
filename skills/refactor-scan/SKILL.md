---
name: refactor-scan
description: Scan the active repo for repeated UI/state/API/style patterns and produce a refactor plan.md (extraction targets, shared-library contribution candidates, domain doc impact). Proposal only — no code changes until approval. For "refactor", "remove duplication", "improve structure" (any language), or when developer/reviewer reports 3+ duplicates.
argument-hint: "[path-or-pattern to focus on]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: refactor-scan

**Trigger**: `/refactor-scan [focus]` or suggested when `developer` or `reviewer` reports 3+ similar patterns

## Injected Context (at load)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null || true
```

- state dir: !`bash "${CLAUDE_PLUGIN_ROOT}/hooks/state-dir.sh" --create 2>/dev/null || echo unavailable`

Focus (may be empty → whole active repo): `$ARGUMENTS`
**Purpose**: Scan codebase for repeated patterns and produce refactoring proposal. Respect domain doc boundaries and shared-library upgrade paths.

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills refactor-scan 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

---

## Activation

- Manual: `/refactor-scan`
- Suggested: `developer` or `reviewer` reports 3+ duplicate patterns in a handoff/review

---

## Workflow

```text
Step 1: detect-repo → injected

Step 2: refactor-architect (`review-harness:refactor-architect`)
  → Pass the output of `bash "${CLAUDE_PLUGIN_ROOT}/hooks/extract-constraints.sh" refactor-architect "$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-profile.sh" <paths>)"` in the spawn prompt, where `<paths>` = the plan's Affected Files when a plan exists, else the focus path above, else nothing (it carries the constraints, the selected profiles' sections and the agent's org overlay)
  → Full active-repo scan for:
    - Duplicate API call patterns → service abstraction
    - Duplicate utility functions
    - Stack-specific targets: the `#detection` section of the profile passed to refactor-architect

Step 3: Produce refactor plan.md at `<state dir>/plan.md` (never in the repo); pass that absolute path to refactor-architect
  → List all detected patterns
  → Propose extraction targets (component/hook/utility/store)
  → For each: scope = single-repo OR shared-library contribution candidate
  → Estimate impact: files affected, domain doc impact, risk
  → Note any shared-library upgrade path implications

Step 4: Present to user → "Refactor plan ready. Review <absolute path of plan.md> to approve."

Step 5 (after approval):
  → Execute via developer (`review-harness:developer`) in slices ≤ ~5 files each; test-runner (or manual verify) after every slice — never one giant refactor commit
  → git-commit auto-chains on reviewer PASS
  → [DONE — await user git ops]
```

`git-branch` and `git-pr` are user-invoked.

---

## Output Format

```
## Refactor Scan Results

### High Priority (3+ occurrences)
1. loading/error/data state pattern — 5 files → extract: useAsyncData hook
   - Domain impact: docs/general/general.md (Hooks section)
   - Risk: none
2. Card layout pattern — 4 files → extract: BaseCard component
   - Shared-library candidate: similar primitive may belong in the design system → follow-up

### Medium Priority
1. Filter + pagination pattern — 3 files → extract: useFilteredList hook

### Low Priority
1. formatDate utility — 2 files → extract: lib/utils.ts (probably overkill)
```

---

## Constraints

- Scan only, no changes in this step
- Always produce plan.md before any refactoring
- Always flag shared-library contribution candidates separately from local refactors
- Always list domain doc impact per extraction
- Never write backend code from a frontend session
- No auto-branch / no auto-PR
