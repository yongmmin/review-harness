# review-harness Maintainer Rules

Maintainer file for working on this repository. Claude Code does not load a plugin's root `CLAUDE.md` for plugin users, so nothing here reaches a consumer session. Consumer runtime rules live in `skills/` and `agents/` (hooks enforce them); a rule a consumer session needs goes into the one skill or agent that acts on it, never only here. Human docs belong in `README.md`, `docs/`, and `CHANGELOG.md`.

---

## Where Consumer Rules Live

- Entry, intent routing, API Spec Check, Plan Gate / Design Check, agent spawning, context budget, handoff schema, run state, review gate, harness loop, skip rules, git ops policy → `skills/review-harness/SKILL.md` (canonical runtime spec). The parts one path needs sit in sibling files the core points to with a `→ read` line and reads only on that path: `register-offer.md`, `api-spec.md`, `web-guidance.md`, `plan-gate.md` (plan template, Design Check / Done When / Contract rules), `small-change.md`, `bugfix.md`, `git-ops.md`, `retry.md` (harness loop body, retry context)
- Injected session context and org overlay → each `skills/*/SKILL.md`
- rtk modes, resolution order, no global install → `skills/rtk-toggle/SKILL.md`; rtk wrapping inside agents → `agents/test-runner.md`, `agents/developer.md`, `agents/reviewer.md`
- Agent rules → `agents/*.md` (developer and reviewer read the touched repos' own rules via `hooks/repo-rules.sh` themselves), plus the `hooks/extract-constraints.sh` output passed at spawn (`constraints.md` and `profiles/*.md` tagged sections, `#org`, agent overlay)

---

## Repo Rules

- Files in this repository must never contain organisation-specific names, paths or URLs. Such content goes to `~/.review-harness/org/` (rules) or `~/.review-harness/knowledge/` (repo registry, domain knowledge)
- Organisation content lives outside the plugin folder: overlays in `~/.review-harness/org/`, repo registry and domain knowledge in `~/.review-harness/knowledge/` (`index.md`, `<org>/*.md` incl. `repos.md`). When absent, overlays are empty, `detect-repo.sh` prints nothing, knowledge reports empty, and the generic rules apply alone — never treat that as an error
- Session start: compact summaries only (`hooks/session-start.sh`)

---

## Hook Contract (why the hooks emit JSON)

- `PreToolUse` plain-text stdout is invisible to Claude → `pre-tool-use.sh` emits `permissionDecision: deny` + reason for protected config files; approval is recorded with `bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-tool-use.sh" --approve <path>` (30-min TTL, per project) after the user says yes
- `PostToolUse` plain-text stdout is invisible too → `post-tool-use.sh` emits `hookSpecificOutput.additionalContext` with the compact tsc/eslint errors (exit 0). An agent that sees `PostToolUse validation failed` must fix before continuing
- `PreToolUse` on `Bash` → `commit-gate.sh` denies `git commit` while a run is `active` and `run-state.sh check` fails (no verdict, FAIL, code changed after the review or the last test run, failing tests, or no tests without the user's manual confirmation). No state file or no active run → silent pass; an active run untouched for 24h → `additionalContext` advice only, no deny. It only sees Claude's Bash calls, never the user's own terminal
- `SubagentStart` / `SubagentStop` → `agent-usage.sh` records per-agent tokens and time into the active run silently: no output, always exit 0, never blocks
- `SessionStart` stdout IS context → `session-start.sh` keeps printing plain text

---

## Budget Measurement

- `hooks/extract-constraints.sh` and `hooks/post-tool-use.sh` log bytes/tokens to stderr
- Warn threshold: 8192 bytes (~2K tokens), override via `REVIEW_HARNESS_BUDGET_WARN_BYTES`
- stderr never reaches agent context
- `[warn]` line → prune that `constraints.md` section or split into a tighter tag

---

## Model Routing

Agents set a family alias via YAML frontmatter `model:` in each `agents/*.md` — resolves to the newest model of that family automatically (Claude Code docs recommend aliases over full IDs). Tiered: `fable` for reviewer/refactor-architect, `opus` for developer/test-runner. `effort:` is per agent (`high` for developer/reviewer/refactor-architect, `medium` for test-runner). Before each reviewer spawn, `review-harness` and `code-review` run `hooks/risk-tier.sh`: `low` spawns the reviewer with `model: "opus"` and `effort: "medium"`, `high` makes it run at least 2 executable probes, `normal` keeps the frontmatter. Before each developer spawn, `review-harness` runs `hooks/risk-tier.sh --paths` on the plan's Affected Files: `low` spawns the developer with `effort: "medium"` (never for a bugfix plan), otherwise the frontmatter applies. Both rules live in the core `skills/review-harness/SKILL.md` → Agent Spawning. To pin a version for benchmarking, set a full ID (e.g. `claude-opus-4-8`) in the 4 agent files only — skills carry no model field and the commit trailer is model-agnostic (`Co-Authored-By: Claude <noreply@anthropic.com>`).
