---
name: audit-rules
description: Audit the rules review-harness agents receive for drift — stale stack versions in the repo registry, version-bound overlay rules, duplicate rules, constraint budget, failure-ledger size, age and missing heading — judge the findings and apply only the edits the user approves, inside ~/.review-harness/. Invoke as /audit-rules.
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: audit-rules

**Trigger**: `/audit-rules` (plugin-namespaced: `/review-harness:audit-rules`)

**Purpose**: Rules drift from the repos they describe (a registry that names an old framework major, an overlay rule that FAILs the version the repos now run, copies of one rule in several files, a ledger past its GC limit). Each costs wrong FAILs or tokens on every run. The script finds the checkable facts; this skill judges them and proposes edits.

## Injected Context (at load — do not re-run)

```!
echo "home: ${REVIEW_HARNESS_HOME:-$HOME/.review-harness}"
bash "${CLAUDE_PLUGIN_ROOT}/hooks/audit-rules.sh" 2>&1; echo "exit: $?"
```

Paths in the findings are relative to `home:`; `<plugin>/` paths are under `${CLAUDE_PLUGIN_ROOT}`. A `budget <agent>` finding names an agent, not a file: its non-profile part is the `extract-constraints.sh <agent>` output without profiles (plugin `constraints.md` sections, `org/constraints.md`, the ledger for reviewer / test-runner, `org/agents/<agent>.md`). On `exit: 0` still run step 3; say "no drift found" only when step 3 also finds nothing. `exit: 2` → report the error line and stop.

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills audit-rules 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

---

## Workflow

1. **Read only what is cited.** For each finding, read the cited line with a few lines around it — not whole files. `stale-version`: also the repo's `package.json` entry it names.
2. **Judge.**
   - `stale-version`, `missing-path`: facts; propose the registry line with the current version, or ask whether the repo moved or was retired.
   - `version-rule`: a candidate. The reason lists every registered repo's version, `(=)` matching the rule and `(≠)` not. Decide whether the rule is still true (an intentional pin that some repos still need, a pin the repos already left, or a history note); a rule that forbids a version must not stand while `(=)` repos already run it. Say which side is current.
   - `duplicate`: is it the same rule in two places that load for the same agent? Keep the copy in the file the rule belongs to (an agent overlay for one agent, `org/constraints.md` `#org` for several, a profile for one stack) and drop the other. A copy in `<plugin>/` wins: drop the org copy.
   - `budget`: name the largest parts of that agent's non-profile output and what can move to a profile or an on-demand knowledge file.
   - `ledger-unloaded`: the ledger has entries but no `## #failure-patterns` heading, so no agent gets any of them. Offer to add that heading as the first line (before the GC below).
   - `ledger-size`, `ledger-old`: GC as the `constraints.md` header rule says — merge similar entries, drop entries older than 90 days, and never keep or re-add a rule another layer already enforces (a reviewer static gate, a profile, `#review` / `#org`, ESLint or tsc).
3. **Semantic pass, once.** Read `org/constraints.md`, `org/agents/*.md`, `org/skills/*.md`, `org/profiles/*.md` and the `#review` sections of `<plugin>/profiles/*.md` once, looking only for what the script cannot see: two rules demanding opposite things, or a rule contradicting the registry. Add what you find to the list.
4. **Propose.** At most 10 items, most costly first (wrong FAILs before token waste). A numbered list, each item `file:line — old line → new line` or `file:line — delete`, with a one-line reason. Ask the user which items to apply (`AskUserQuestion` multi-select, or "all" / numbers in the user's language).
5. **Apply only the items the user approves**, with Edit, one item at a time. Then run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/audit-rules.sh"` once more and report what is left.

## Constraints

- Edits only under `home:` (`~/.review-harness/`). It never edits the plugin's own files (`<plugin>/…`): a finding there goes into the report as a note for the plugin maintainer
- Organisation content stays in `~/.review-harness/`; never copy it into a repo
- It never runs git, and never edits before the user's yes
- No new rule files; edit or delete lines in the existing ones
