# Global Constraints

> **On-demand loading**: do not pass this whole file to every agent. Each agent gets only its tagged sections.
> Extract via `bash hooks/extract-constraints.sh <agent-name> [profile]`. Never inline the full file.
> Stack-specific rules live in `profiles/<name>.md` with the same `## #tag` format.
>
> | Section tag | Target agents |
> |-------------|---------------|
> | `#code-rules` | developer, refactor-architect |
> | `#filesystem` | developer |
> | `#completion` | developer, test-runner |
> | `#review` | reviewer |
> | `#failure-patterns` | reviewer, test-runner — the per-user ledger `~/.review-harness/failure-patterns.md` (honours `REVIEW_HARNESS_HOME`), not this file; its path reaches those agents as a `ledger: <path>` line |
> | `#org` | developer, reviewer, refactor-architect — organisation-specific rules, read from `~/.review-harness/org/constraints.md` (absent when no organisation overlay is installed) |
>
> **Ledger** (`failure-patterns.md`): reviewer, test-runner and the orchestrator's LIMIT step append repeatable AI mistakes under its `## #failure-patterns` heading (a new file starts with that heading). Format: `- [YYYY-MM-DD] [category:correctness|performance|design|scope|goal|security|contract|ops|state-mgmt] [pattern] - [rule]`. It holds ONLY patterns not caught anywhere else.
>
> **GC rule**: if `#failure-patterns` exceeds 3072 bytes (watch the `[token-budget]` stderr line from `extract-constraints.sh`), merge similar rules and drop entries older than 90 days. Never re-add a rule that is already a static gate in `agents/reviewer.md` or a profile (`profiles/*.md`), a rule in `#review`/`#org`, or enforced by ESLint/tsc — the ledger is only for gaps those layers miss.

---

## #code-rules

- No new libraries/packages. Use existing `package.json` deps only
- No direct external API calls. Go through internal wrappers/service layer
- No `console.log` in production code
- YAGNI: implement only what was requested

---

## #filesystem

- `src/` — read/write allowed
- `.env*` — HARD BLOCKED (settings.json deny)
- `package.json` — requires explicit user approval (PreToolUse DENIES until `bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-tool-use.sh" --approve <path>` is run after the user says yes; 30-min TTL)
- `next.config.{js,ts,mjs}` — same approval gate
- `tsconfig.json`, `tsconfig.*.json` — same approval gate
- Plugin working files (`plan.md`, run state, approvals, caches) live in `~/.review-harness/state/<repo-id>/` — never create them inside the repo. A legacy `plan.md` or `.front-harness-cache/` left in a repo: never stage or commit
- `node_modules/` — no access
- Do not modify code outside request scope

---

## #completion

- Never declare completion without test results
- If `harness_loop` reaches `MAX_ATTEMPTS` (3 — test failures and reviewer FAILs share one counter kept by `run-state.sh`), do not declare completion. Stop and report the full failure context (failing command, file, error excerpt, attempted fixes) to the user. The user decides whether to file an issue
- No explanations, summaries, or "I did X" narration

---

## #review

- No `git-commit` without a reviewer PASS recorded for the current work tree (`run-state.sh check`), or an explicit user override recorded with `run-state.sh override`
- Repeatable FAIL rules: `agents/reviewer.md` step 5

Logic correctness — FAIL if any:
- Property access on nullable without guard
- Async op without error surfaced to UI
- Edge cases unhandled: empty list, zero, boundary input

Secrets — FAIL if any:
- Password/token/webhook URL in tracked env/config or as `process.env.X || '<value>'` → `[security]`; `.env.example`-style placeholders, `${VAR}` pass

Design quality — FAIL if any:
- Duplicates an existing component/hook/util in the repo or its shared packages
- Single component mixes 2+ responsibilities (fetch + render + business logic) where extraction is trivial
- New abstraction with one caller and no near-term second use
- Props drilling 3+ levels where context/composition/colocation is the standard fix
- Magic values inlined where named constant/enum is project pattern
- Logic that belongs in pure function embedded in component body, blocking testability

Design quality — PASS notes:
- Three similar lines is acceptable; do not demand abstraction for hypothetical reuse
- Style-only or naming preferences are not failures
