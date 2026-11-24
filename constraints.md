# Global Constraints

> **On-demand loading**: do not pass this whole file to every agent. Each agent gets only its tagged sections.
> Extract via `bash hooks/extract-constraints.sh <agent-name> [profile]`. Never inline the full file.
> Stack-specific rules live in `profiles/<name>.md` with the same `## #tag` format.
>
> | Section tag | Target agents |
> |-------------|---------------|
> | `#code-rules` | developer, refactor-architect |
> | `#filesystem` | developer |
> | `#review` | reviewer; developer as a checklist (rule lines only, in its `## Review checklist` block) |
> | `#failure-patterns` | reviewer — the per-user ledger `~/.review-harness/failure-patterns.md` (honours `REVIEW_HARNESS_HOME`), not this file; its path reaches the reviewer as a `ledger: <path>` line. Developer gets its entries in the checklist, without the path |
> | `#org` | developer, reviewer, refactor-architect — organisation-specific rules, read from `~/.review-harness/org/constraints.md` (absent when no organisation overlay is installed) |
>
> **Ledger** (`failure-patterns.md`): the reviewer and the orchestrator's LIMIT step append repeatable AI mistakes under its `## #failure-patterns` heading (a new file starts with that heading). Format and scope: `agents/reviewer.md` → Ledger. Keep it under 3072 bytes (`/audit-rules` reports the size and entries older than 90 days): merge similar rules, and move a lesson about one repo into that repo's own rule files.

---

## #code-rules

- No new libraries/packages. Use the repo's existing dependencies only, unless the plan says otherwise

---

## #filesystem

- `.env*` — HARD BLOCKED (settings.json deny)
- `package.json`, lock files, `next.config.{js,ts,mjs}`, `tsconfig.json`, `tsconfig.*.json` — require explicit user approval (PreToolUse DENIES until `bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-tool-use.sh" --approve <path>` is run after the user says yes; 30-min TTL)
- Plugin working files (`plan.md`, run state, approvals, caches) live in `~/.review-harness/state/<repo-id>/` — never create them inside the repo
- Do not modify code outside request scope

---

## #review

Secrets — FAIL if any:
- Password/token/webhook URL in tracked env/config or as `process.env.X || '<value>'` → `[security]`; `.env.example`-style placeholders, `${VAR}` pass

Not failures:
- PASS: three similar lines — do not demand abstraction for hypothetical reuse
- PASS: style-only or naming preferences
