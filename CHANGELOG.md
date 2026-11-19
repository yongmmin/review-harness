# Changelog

This plugin is a rebuild that carries over the Harness Engineering principles of the earlier `front-agent` (a generic React/Next plugin).

### Unreleased

**Token cost**
- rtk is on by default: `hooks/rtk-wrap.sh` resolves inline arg/flag → `REVIEW_HARNESS_RTK` → session flag → `standard` when an `rtk` binary is on PATH, else `off`. `/review-harness` no longer asks for a mode on first use; `/rtk-toggle` changes it. The bench driver keeps `REVIEW_HARNESS_RTK=off`
- New `risk-tier.sh --paths <path...>`: scores a planned change from its paths alone, without reading a diff (`high` on the existing path rules or 10+ paths, `normal` on a dependency file, `low` with at most 3 paths, `normal` otherwise; each argument is split at commas, backticks and a leading `./` are dropped and an absolute path under the repo root is made relative; exit 2 when no path is left). Before each `developer` spawn, `/review-harness` runs it on the plan's Affected Files and spawns the developer at `effort: "medium"` on `low`; `normal`, `high`, a failure and every bugfix plan keep the frontmatter effort
- `hooks/rtk-wrap.sh`: `git diff` and `git show` run raw in every mode (`gh` diff too), because rtk 0.40 cuts them to about 500 lines (100 per hunk) and the reviewer reads the change through them; this also applies to an explicit opt-in. The default turns on only for the real rtk (`rtk --version` starts with `rtk`)
- Small change path: at most 3 files (was 2), at most 1 of them a new test file

**Developer-side bench**
- New `bench/dev-run.sh <plain|harness> <case-dir> <out-dir>`: one end-to-end `claude -p` run of a task in a throwaway fixture, in a temp dir with its own config dir and plugin home, rtk off; the harness arm loads a `git archive HEAD` copy of the plugin's runtime files only (`.claude-plugin`, `agents`, `hooks`, `skills`, `profiles`, `constraints.md`). Fixed user-proxy replies (at most 4, through `--resume`), cost cap (`DEV_BENCH_BUDGET_USD`, default 15) and wall-time cap (`DEV_BENCH_TIME_S`, default 2700, kills the call's process group); copies the fixture, driver outputs, transcripts, `runs.jsonl` and `plan.md` to the out-dir with a `run.json`
- New `bench/dev-score.sh <case-dir> <out-dir>`: one JSON line per run — hidden tests passed, regressions, base tests the run edited, cost, tokens, turns, wall time, user replies, harness attempts / verdicts / end, plan sections present, test runs and a contamination flag; `solved` needs all hidden tests, no regression, no abort, no `limit`/`abandoned` end and a clean transcript
- First developer-side case on a zero-dependency Node 20 skeleton (new `bench_node` in `bench/lib.sh`), with a correct and a plausible wrong patch that `tests/run.sh` checks against the hidden tests
- `tests/run.sh`: the case (clean base, base tests pass, hidden tests fail at base, both patches, no revealing words), the scorer, and the driver against a stub `claude`; skipped with one line when node 20+ is missing

### v0.7.0 (2026-11-19)

Highlights:
- **Measurement.** Per-agent tokens and time are recorded, and run-stats shows the first-review PASS rate. On this repo, first-review PASS went from 2 of 9 runs before the developer self-check to 4 of 8 after it. Both sets are small and the tasks differed.
- **Developer self-check.** The developer gets the review checklist and the failure ledger, and runs `static-gates.sh` and `review-context.sh` before handoff.
- **Review strength by risk.** `risk-tier.sh` sends a cheaper reviewer for low risk and makes the reviewer run executable probes for high risk.
- **Modern web guidance.** For web UI work there is a plan-time search, a developer retrieve and a reviewer `legacy-scan`.
- **Main skill split.** The core skill went from 31.8 KB to 19.8 KB; parts only one path needs are read on that path alone.

**Review context**
- New `hooks/review-context.sh [base]`: one block of at most 4,096 bytes (cut at a line, then `… truncated`) on the change `static-gates.sh` sees (it sources `hooks/lib/collect-change.sh`), renames detected: `files:` (`<A|M|D|R> path +added -removed`, at most 30, so symbols and callers still fit), `symbols:` (`<name> (<added|removed|changed>) in <path>` for JS/TS/Vue/Svelte exports, top-level functions and arrow functions, shell `Name()` / `function Name`, Python `def` / `class`, found on added or removed lines; removed first, at most 25), `callers:` (per symbol, the other tracked or untracked files holding the name as a whole word via `git grep -lwIF`, the defining file and docs (`*.md`, `*.mdx`, `*.rst`, `*.txt`, the doc set of `risk-tier.sh`) excluded, tests marked `(test)`, at most 8), `tests:` (the changed test files); an empty section prints `<section>: none`. Exit 0, or 2 on a usage error, outside a git repo or when git fails
- `reviewer`: runs it after `static-gates.sh` and starts from its block; every listed caller of a `removed` or `changed` symbol is in the diff or checked, and a caller of a removed symbol left unchanged is a FAIL `[contract]` unless the plan's `Callers/Consumers` marks it `no change needed`. `developer`: the self-check runs it and updates or justifies each such caller
- Fixes from the risk-tier review: `risk-tier.sh` blanks only the GitHub Action form `actions/checkout@`, so `app/actions/checkout.ts` and an import from `@/actions/checkout` are `high` again; `hooks/lib/collect-change.sh` copies the index with `cp` and `touch -r` instead of `cp -p`, so the temporary index stays mode 0600 while keeping the mtime git's racy-entry check needs

**Review strength by risk**
- New `hooks/risk-tier.sh [base]`: line 1 `low`, `normal` or `high`, then one `reason: …` line per rule that fired, on the change `static-gates.sh` sees (deleted paths and both sides of a move included; both scripts now source `hooks/lib/collect-change.sh`, which copies the index with `cp` and `touch -r`, so the copy stays 0600 and git's racy-entry check still sees a same-second, same-size edit). `high` (any match wins): an auth/session (auth, oauth, session, token, permission, role, acl, rbac, password, passwd, jwt, login, logout, credential), payment (payment, billing, checkout, invoice, stripe, refund), concurrency (lock, mutex, semaphore, worker, queue, concurrency) or parser (parser, parsing, deserialize) word in a changed path or in an added line of a file that is neither a doc (`*.md`, `*.mdx`, `*.rst`, `*.txt` but not `requirements*`/`constraints*.txt` or `CMakeLists.txt`) nor a dependency file (case-insensitive whole words, also split at camelCase: `getToken` hits, `tokenizer` does not; ARIA `role=`, `getByRole(`, `git checkout`, `sparse-checkout` and `actions/checkout@` (the GitHub Action form only, so `app/actions/checkout.ts` still counts) are blanked first; only the first 20,000 characters of an added line and runs of at most 80 characters are scanned, so a multi-megabyte minified line takes about a second), a `migration(s)/` or `.sql` path, a path under the root `hooks/` or `.github/workflows/` or a file name holding the word `gate(s)`, or 10+ changed files. A dependency file (`*.lock`, `bun.lockb`, `package-lock.json`, `pnpm-lock.yaml`, `go.sum`, `requirements*.txt`, `constraints*.txt`) is never a word hit, by name or content, but makes the change at least `normal` with `reason: dependency change`. `low` (no high rule, no dependency file, at least one file): docs (or images under `docs/`) or tests only, or at most 2 files with at most 30 added lines; an empty change is `normal`. Exit 0, or 2 on a usage error, outside a git repo or when git fails
- `/review-harness` (Agent Spawning) and `/code-review` (diff targets only) run it before each `reviewer` spawn and pass `risk: <tier>` plus its reasons; `low` → `model: "opus"`, `effort: "medium"`; `normal` / `high` → no override; a script failure counts as `normal`; `Opus for this run` still applies on every tier; `Keep Fable` does not change `low`
- `reviewer`: with `risk: high` it writes and runs at least 2 executable probes against the changed behaviour in a temp dir or throwaway copy (never the work tree), a probe showing a defect is a FAIL with its category, and the handoff carries a 4th bullet `probes: N run, K failed`; a dispute re-judge re-runs probes only when the disputed issue came from a probe
- The main-skill split's pure-move test and its fixture `tests/fixtures/review-harness-SKILL.pre-split.md` are deleted, since this change rewords the core; the size and one-pointer-per-file tests stay

**Main skill split**
- `skills/review-harness/SKILL.md` (31,834 bytes, read on every run) is split into a core (19,277 bytes) and 9 sibling files the core names in one ``→ read `${CLAUDE_PLUGIN_ROOT}/skills/review-harness/<file>.md` before <step>`` line each, read only on that path: `register-offer.md`, `api-spec.md`, `web-guidance.md`, `plan-gate.md` (plan template and its rules; read by every run that writes a plan), `usage-downgrade.md`, `small-change.md`, `bugfix.md`, `git-ops.md`, `retry.md`. A pure move: no rule is reworded; one core line is added (in a file read through a pointer, replace the `CLAUDE_PLUGIN_ROOT` variable with the plugin root named in Session Context; it names the variable without `${…}` because the loader substitutes that form inside SKILL.md). A test compares the old file (frozen in `tests/fixtures/review-harness-SKILL.pre-split.md`) with the new files line by line; the next PR that rewords a rule deletes that test and the fixture
- Needs one live check: reading the sibling files from a consumer repo may prompt for Read permission on the plugin directory (`allowed-tools` has no `Read` entry); if it does, a `Read(...)` entry is the fix. Also check once that a breaking-contract plan in a consumer repo runs `find-consumers.sh` by its absolute plugin path (that call now sits in `plan-gate.md`)

**Modern web guidance**
- `/review-harness` step 4.5 Web Guidance Search: only when a `plan.md` will be written (never on the Small change path or for `review`), `detect-profile.sh` on the planned files gives `web-frontend` and the change touches UI or client behaviour (not 3D/canvas-only, styling-token-only or tooling), the main session runs at most 3 `npx -y modern-web-guidance@1.0.1 search` calls and records the matching guide ids in the new `plan.md → Inputs.Web guidance` line (`none` or `unavailable` otherwise). `npx` missing, network blocked, permission denied or any other CLI error or timeout → stop at that first one, write `unavailable`; never asks, never retries
- `web-frontend #implementation`: the developer `retrieve`s exactly the listed ids and reports the new `guidance:` handoff line (on a retry it keeps that line and retrieves again only when the fix list names a guide or a legacy-scan finding). Precedence, the same list as the reviewer's exemption: the plan, a stated browser policy, an existing repo or design-system component, the profile's rules, or an org rule win over a guide; guide CSS goes into the repo's styling system and tokens; no new dependency or polyfill unless planned; Baseline Widely Available unless a browser policy says otherwise. Its self-check runs the reviewer's `legacy-scan` with the same bound; unavailable → `legacy-scan: unavailable` in `self-check:`
- `web-frontend #review`: the reviewer runs `legacy-scan` on each changed UI file on its own (never a directory; at most 5, the ones with the most added lines, noted in `blockers`); a finding on an added line that survives its rubric → FAIL `[design]` unless that precedence list requires the pattern, on unchanged lines → `defer`; unavailable or any CLI error or timeout → `legacy-scan: unavailable` in `blockers`, never a FAIL; listed ids with no `guidance:` line → FAIL `[goal]`
- The retry context and the `reviewer` prompt carry the developer's `guidance:` line, like `red:`
- Follow-ups: the first `reviewer` prompt (any intent, not only retries) carries the developer's `guidance:` line when `Inputs.Web guidance` lists ids; `legacy-scan` runs on each added or modified UI file (developer self-check, reviewer and README); the reviewer's "unavailable → `blockers`" rule is prose, so it no longer reaches the developer checklist against the developer's "`self-check:`, not `blockers`" rule
- One pinned version across skills, agents, profiles, README and docs (tested, no `@latest`); no hook runs it. README: "Modern web guidance" (what runs when, estimated token cost, allowlist entry, browser policy line)

**Static gates**
- New `hooks/static-gates.sh [base]`: reports the review rules a grep can decide from the ADDED lines and changed paths of the change (with `base`: since its merge base plus the working tree; without: staged, unstaged and untracked; no HEAD: every file), one `<hard|note> [category] path:line — rule` line per hit. Hard (exit 1): `console.log(` in a non-test JS/TS/Vue/Svelte file `[ops]`, a `.env`/`.env.*` file, except names ending in `.example`/`.sample`/`.template` `[security]`, a `process.env` fallback to a non-empty string literal when the variable name looks like a secret (SECRET, TOKEN, PASSWORD, PASSWD, KEY, WEBHOOK, CREDENTIAL, PRIVATE; any case) `[security]`. Notes (exit 0): the same fallback for any other name `[security]`, `TODO`/`FIXME`/`XXX` and a new export with no other file naming it `[goal]`. Deleted files, removed lines, binary files and nested repos are never reported; untracked files join one diff through a temporary copy of the index, so the real index is never written; reads only, no network; exit 2 on a usage error or outside a git repo
- `developer` runs it first in the self-check and fixes every hard hit; `reviewer` runs it first in the Static Review Gates: a hard hit is a FAIL with its category unless `Out of Scope` or `Design Check` names it, note hits feed the Goal gate and never FAIL on their own
- Follow-ups: exit 2 when the internal `git add -N` or `git diff` fails (e.g. an unreadable untracked file) instead of a silent clean 0, printing git's error and then `static-gates: git <cmd> failed (see the git error above)`; in a sparse checkout an untracked file outside the cone no longer fails every run (`git add -N --sparse` when git supports it); temp files are created with `umask 077`; the header states git ≥ 2.25; its diff parser runs with `LC_ALL=C`, so a non-UTF-8 byte in an added line no longer ends the parse with a silent exit 0 on macOS. Every `process.env` fallback on a line is classified (hard when any is secret-like), and secret names match on name segments (split on `_`, and on camelCase for names with lower case): a segment equal to `[API]KEY`, or ending in SECRET, TOKEN, PASSWORD, PASSWD, WEBHOOK, CREDENTIAL or PRIVATE, each with an optional plural `S` and trailing digits, is hard — `API_KEY`, `apiKey`, `SENDGRID_APIKEY`, `API_KEYS`, `X_API_KEY2`, `AUTH_TOKENS`, `JWT_SECRETS`, `PASSWORDS` stay hard, `HOTKEY_LAYOUT`, `KEYBOARD_MODE`, `MONKEY`, `KEYCLOAK_URL`, `TOKENIZER` become notes. `developer` and `reviewer` put an exit-2 stderr line in `blockers`

**Developer review checklist**
- `extract-constraints.sh developer [profiles]` ends its constraints part (before the agent overlay) with one `## Review checklist — the reviewer FAILs on these (check your diff before handoff)` block: only the rule lines of `constraints.md #review`, each profile's `#review` and its org profile's `#review`, and the ledger entries — no prose, headings or `ledger:` line. No lines → no block. Its bytes show as `+ checklist: N bytes` on the stderr budget line and do not count toward the 8192 warning. Reviewer, test-runner and refactor-architect output is unchanged
- `developer`: a self-check step before handoff holds the diff against the checklist and the reviewer gates (`Done When` met, `Callers/Consumers` handled, no TODO/stub return, no new export without a caller, no edit outside the plan); the handoff carries `self-check: <rule hit → fixed>; …` or `self-check: clean` (also in the handoff schema), an unfixable hit goes to `blockers`
- Follow-ups: a non-UTF-8 byte in the ledger no longer drops checklist lines (`grep -a` for the filter; the section `awk` runs with `LC_ALL=C`, since macOS awk in a UTF-8 locale aborts at such a byte); the profile header tables say `#review` reaches the reviewer and the developer (as its review checklist)

**Agent usage**
- New `hooks/agent-usage.sh` on `SubagentStart` / `SubagentStop` (matcher `^(review-harness:)?(developer|test-runner|reviewer|refactor-architect)$`): records each plugin agent's active time (sum of start→stop spans, resumes included), tokens (input, output, cache read, cache write; one count per `message.id` of its transcript, replaced on every stop) and tool calls of the active run in `<state dir>/agents.jsonl` (never in `run-state.json`: the review gate's file and its stale clock stay untouched; deleted by `start`, `done`, `abandon`), through new `run-state.sh agent-start` / `agent-stop`. Never blocks, prints nothing, always exits 0; no active run, a stale run, no `jq`, an unreadable transcript or an agent the run never started → nothing recorded. Main-session tokens are not measured
- `runs.jsonl` gains `agents` (per agent type: `n`, `s`, `in`, `out`, `cr`, `cw`, `tools`) and `tokens` (run totals) when agent data exists; `run-state.sh status` adds ` · agents N`
- `agents.jsonl` is append-only: each `agent-start` / `agent-stop` appends one JSON line in a single write and readers fold the lines, so parallel agents never lose an entry (the earlier locked read-modify-write of `agents.json` could starve a waiter on a busy CI runner and drop it). No lock, no temp file. `start`, `done` and `abandon` also delete an `agents.json` / `agents.json.lock` left by an older version; `run-state.sh agents` prints the folded object
- Follow-ups: a test pins the `agent-stop` early exit for an id the run never started (nothing appended); `docs/hooks.md` states that a torn line is skipped and that a writer killed mid-line can also lose the next append
- `run-stats.sh`: `first review PASS: N% (k/n)` right after the runs line (runs whose first verdict is PASS, of runs with a verdict); with agent data, median tokens per run (total and output), median active minutes per run and a per-agent line (share of tokens, median seconds), all labelled "subagents only"

**Bug-fix workflow**
- New `bugfix` intent (`fix`, `bug`, `error`, `broken`, `fails`, `crash`, `regression`, or "why" about a failure, in any language). `check`/`verify` route to review only when there is a diff to review and no failure symptom; a trivial fix with no failure ("fix this typo") stays Small change; no matching intent → one clarifying question
- Bugfix flow in `/review-harness`: reproduce (failing test, or a command and its output) → `plan.md → ## Bug` (`Symptom`, `Repro`, `Cause` as `file:line` + why, `Regression test`) → developer runs the regression test RED, then fixes → test-runner → reviewer → git-commit. Not reproducible → ask the user, never fix by guess. Never takes the Small change path; a fix of at most 2 files skips the approval wait but shows `Cause` and `Regression test` first. Run state: `run-state.sh start bugfix …`
- A regression test that passes before the fix means a wrong `Cause`: the loop back to reproduce counts as an attempt
- `developer`: for a bugfix, writes (or runs the existing) regression test before the fix and reports its failing line as `red:` in the handoff (new optional handoff field)
- `reviewer` static gates: bugfix with no regression test in the diff or the plan and no stated reason, or with no `red:` line → FAIL `[correctness]`; a change the `Cause` does not explain → FAIL `[scope]`

**Definition of done**
- `plan.md` gains `## Done When` (2–5 observable outcomes, each with its check: test name, command, or manual step) and `## Out of Scope` (1–2 lines), required for `feature`, `bugfix` and `refactor` (also in the `refactor-architect` plan format). A Small change states one `Done when:` line before the edit and passes it to the reviewer
- `reviewer` goal gate: reads `Intent`, `Done When` and `Out of Scope` (or the Small change `Done when:` line; skipped when neither exists). FAIL `[goal]` on a missing `Done When`, an unmet item (judged from test-runner output, or by running the command; manual steps go to `blockers` as `manual: <step>`, never FAIL), a TODO/stub/placeholder return where a `Done When` item expects working code, or a new export with no caller (public entry exports, file-routed / DI-registered / CLI entry points, test-only use, and callers named in `Out of Scope` are exempt). An `Out of Scope` edit is FAIL `[scope]`. New category `goal` in the reviewer's lists and the `#failure-patterns` format
- `test-runner` gets the `Done When` test/command checks in its prompt, so the reviewer has evidence for them
- Handoff: "max 6 bullets plus `red:` for bugfix"; a bugfix retry carries the first developer run's `red:` line to the re-spawned developer and the reviewer

**Verification**
- Test baseline: in `feature`, `bugfix` and `refactor`, `test-runner` runs once before `developer` (`mode: baseline`, run-state step `baseline`) and writes the already-failing tests to `<state dir>/baseline.txt`; later runs count only new failures (a bugfix's regression test always counts). The user is told in one line when the baseline has failures. `run-state.sh start` deletes the previous run's baseline
- Test results in the commit gate: new `run-state.sh tests pass|fail|none|manual-confirmed` (recorded by `test-runner` with the work-tree hash; active run only). `check` blocks on `fail`, on `none` the user has not confirmed, and on a confirmation of an older work tree; `manual-confirmed` is accepted only over `none`. A run with no tests record (review fast-path, older flows) is gated as before. `status` shows the tests record
- No-tests repos: on `no_tests_configured`, `/review-harness` shows the `Done When` manual steps (or the Small change `Done when:` check) after reviewer PASS and records `manual-confirmed` only after the user's explicit yes
- `test-runner` runs the `Done When` command checks also when the repo has no test command, then one whole-project check (registry `check_cmd`, else `npx tsc --noEmit` with a `tsconfig.json`) reported as `check:`
- `developer` runs the new tests and confirms they fail for the intended reason before implementing (`/tdd` points to that rule instead of repeating it). Its output is the handoff block only, with an optional `assumptions:` line (also in the handoff schema); "Output code only" is gone from `developer` and `constraints.md #completion`
- `post-tool-use.sh`: when the tsc block shows the edited file's errors, a line `other files: N more errors` counts the errors elsewhere that are not shown
- `reviewer`: a stub that `Out of Scope` names is not an out-of-scope edit

**Planning discovery and task decomposition**
- `plan.md → ## Design Check` gains `Callers/Consumers` (every file using a changed export, route or event, or `none — new`), `Pattern` (one neighbouring file to imitate) and `Tests` (existing tests covering the area + new ones), filled by the main session from grep before approval
- More than 6 Affected Files → `Execution Steps` become ordered `Task N` lines (file group + that task's tests); `developer` runs each task's tests before the next. `developer` updates every `Callers/Consumers` file or marks it `no change needed: <reason>` in the plan
- New plan section `## Only When Relevant`: `Migration` (rollback, existing data), `Dependency upgrade` (breaking changelog items), `Performance` (measurement + target) — written only when the change has that part
- `reviewer` contract gate: a `Callers/Consumers` file neither in the diff nor marked `no change needed: <reason>` → FAIL `[contract]`
- `refactor-architect`: when no test covers the target area, the first Migration Step writes characterization tests, unless the user explicitly waives it (recorded under `## Risk`)

**Verification follow-ups**
- `run-state.sh check` blocks a `tests pass` recorded for an older work tree (code changed after the test run). No tests record still leaves the gate to the review alone
- `run-state.sh done` and `abandon` also delete `baseline.txt`, so `/tdd` and `/refactor-scan` never read a stale baseline. `test-runner` no longer runs steps 5–7 in baseline mode when no test command exists
- The Small change path has no test baseline: with already-failing tests the user is told and may override

**Measurement**
- Run log: `run-state.sh done` / `abandon` of an active run appends one JSON line to `~/.review-harness/state/runs.jsonl` (all repos, honours `REVIEW_HARNESS_HOME`, never rewritten): repo id, workflow, start/end/duration, attempts, reviewer verdict sequence with the `[category]` tags of each FAIL, test result, override reason, end (`done` / `abandoned` / `limit` when attempts reached the maximum) and files changed since the commit the run started from (left out when there was none). The run state now keeps `verdicts` (`{v, cats}`; older string entries are still read) and `base` for it. A failed append warns and never changes the exit code; a standalone review record (no active run) is not logged
- `run-state.sh verdict FAIL <category...>`: the reviewer appends the `[category]` tags of its FAIL issues (`agents/reviewer.md` step 6, the verdict command in `/review-harness` and `/code-review`). Words outside the reviewer's category list are ignored with a warning; PASS takes none. Exit codes and attempt counting are unchanged
- New `hooks/run-stats.sh [--repo <id|name>] [--since <days>]`: runs, mean attempts before PASS, share of runs with a reviewer FAIL, FAIL category counts (`untagged` for a FAIL recorded without tags), override rate, limit-reached count, and the same per workflow. Needs `jq` (clear message without it); skips torn lines
- Bench: three plan-based cases that look fine without the plan — `goal-not-wired` (`[goal]`), `bug-cause-elsewhere` (`[scope]` / `[correctness]` against `Cause`), `contract-caller-missed` (`[contract]`). A case may ship `plan.md` and `handoff.md`; `prompt.sh <arm> <fixture> [case-dir]` copies the plan next to the fixture and passes it as `plan_path` with the handoff lines. `expect.txt` may give the expected categories on line 4 (`score.sh` adds `category=match|other`). New `bench_next` skeleton in `bench/lib.sh`
- `bench/README.md`: three runs per cell for new results, cells for the plan-based cases, a design note for a developer-side bench (hidden acceptance tests; deferred, not built), and an "A/B on real tasks" procedure that reads `runs.jsonl` per arm
- `bench/README.md` Run 3 (plan-based cases, one run per cell): 9 of 9 caught in every arm; with the plan the current reviewer uses the intended category 3 of 3 (pre-stage4: 1 of 3), so the plan changes the footing of the FAIL, not detection

**Review triage**
- `reviewer` issues end with `route: patch | replan | defer`. Only `patch` / `replan` issues make a FAIL (and give the verdict categories); `defer` issues are notes for the final report. Every FAIL reason is listed at once ("Max 5 issues" is gone); at most 5 `defer` issues
- Harness Loop: `replan` → the main session updates `plan.md` and gets the user's re-approval before the retry (Small change: ask, or switch to Feature); `defer` → never retried, listed in the final report. Every retry re-runs `test-runner` before `reviewer`, Small change included, since the tests record holds only for the work tree it was taken on
- Dispute: `developer` may answer `dispute: <issue id> — <evidence>` once per issue instead of patching; the reviewer re-judges only that issue. New `run-state.sh dispute <issue id...>` (active run with a FAIL on the unchanged work tree, below the attempt limit; one per review round, exit 2 when used). The next verdict on the disputed work tree is marked `rejudge` and a FAIL then counts no attempt; a code change after the dispute makes it a normal review. Tiered review formats map Critical → `patch` (or `replan`), Warning and Suggestion → `defer` (a Warning that must be fixed is promoted to Critical). `runs.jsonl` gains `disputes`; `run-stats.sh` skips re-judges in the FAIL categories; `bench/score.sh` ignores `route: defer` lines
- `web-frontend` profile: the inline-literal-prop and missing-`React.memo` gates FAIL only on a measured or obviously hot path (large-list item, per-frame/animation callback, high-frequency input) — elsewhere they false-FAILed under React Compiler

**Retry memory**
- Attempts log: every failed attempt adds one line `N. hypothesis → change → result` to `## Attempts` in `plan.md`, or to `<state dir>/attempts.md` on a path without a plan (Small change). The orchestrator writes it (its Write/Edit allowance now names `attempts.md` and the ledger) and passes the lines with every retry context, so a retry does not repeat an idea that already failed. `run-state.sh start` clears `attempts.md`
- Root cause: when the same test or reviewer issue fails a second time, `developer` writes `root cause: <file:line — why the last change did not fix it>` in the handoff (new optional field) before editing. At `LIMIT REACHED`, if the same test or issue failed in every attempt, the orchestrator asks the user whether the plan is wrong (`Replan` → revised plan, re-approval, new run | `Stop`)

**Failure-pattern ledger moved out of the plugin**
- The ledger is now `~/.review-harness/failure-patterns.md` (honours `REVIEW_HARNESS_HOME`; same `## #failure-patterns` section format), not `constraints.md`: agents only received extracted text and could not locate the file, a plugin update overwrote it, and organisation-specific entries would have landed in a public file. `extract-constraints.sh` reads the section from there (absent file → nothing) and prints `ledger: <absolute path>` for `reviewer` and `test-runner`, which append to that path; the orchestrator's LIMIT step uses the same path. `constraints.md` keeps only the format, scope and GC description in its header. The old section had no entries, so nothing was migrated. Reviewer base extract: 8175 → 7330 bytes

**Runtime rules now reach plugin users**
- A plugin's root `CLAUDE.md` is not loaded in a user's session (`claude plugin validate` warns about it), so rules kept only there never applied outside this repo. They now live in the skill or agent that acts on them: Write/Edit limits, context-budget limits and "pass `extract-constraints.sh` output as-is" in `/review-harness`; rtk wrapping in the `developer` and `reviewer` agents; "never `rtk init -g`" in `/rtk-toggle`. `CLAUDE.md` is now the maintainer file
- The `review-harness` skill description also lists bug-fix requests ("fix this") for auto-invocation

**Changes across repos**
- `plan.md` gains `## Contract` (only when the change adds, changes or removes a route, socket event or request/response field another repo may use): `Producer`, `Consumers` (repo → files, or `none — <reason>`), `Compatibility` (`additive | breaking`), `Deploy order`. The `web-api` profile's "list every consumer" rule and contract gate now point to it
- New `hooks/find-consumers.sh <term...>` (reads only): greps the `local_path` of every other repo in the registry `detect-repo.sh` reads for each term (literal; whole word only when the term starts and ends with a word character, so a route still matches inside a URL; `rg`, else `grep -rn`; skips `node_modules`, `.git`, `dist`, `build`, `.next`, `out`, `coverage`, `storybook-static`), at most 20 lines per repo plus `+N more`, one line per hit without backticks, control characters or Unicode bidi controls. No registry or no other repo → one notice. For a `breaking` contract the main session runs it for every renamed, removed, retyped, now-optional or now-required field, route and event (`breaking` also covers a type change and an optional request field made required; a request field made optional is not breaking) and lists the hits under `Consumers`
- Order: the producer run goes first and its final report ends with the `## Contract` block; a `## Contract` block pasted into the consumer repo's run is recorded as `Inputs.API` in any intent (not only when the API Spec Check triggers), without asking for another spec
- `reviewer` contract gate: a `breaking` contract with no consumer repos and no `none — <reason>`, or a consumer repo listed in that breaking contract with hits that the diff does not change and `Out of Scope` does not name as a follow-up → FAIL `[contract]`

**Gate hardening**
- `commit-gate.sh` also catches `git` by absolute path (`/usr/bin/git commit`), global options before the subcommand (`-C <dir>`, `-c k=v`, `--git-dir`/`--work-tree` with a separate value, quoted values), and the history-writing `merge` (also `--ff-only` and `--continue`), `cherry-pick`, `revert`, `am` and `rebase --continue` — inside `&&` / `;` / `|` chains, `$( )` and quoted strings too. Their `--abort` / `--quit` / `--skip` pass, as do read-only commands (`log`, `diff`, `show`, `status`, `stash list`, `merge-base`, `commit-tree`) and a plain `rebase`
- `commit-gate.sh` without `jq`: no longer a silent pass — a history-writing command gets advice (`additionalContext`, not a deny) that the gate is inactive
- Verdict authorship: `run-state.sh verdict` takes `--by <word>` anywhere after `verdict` (`[a-z-]+`, else ignored with a warning) and records it as `by` (default `unknown`) in the review and each `verdicts` entry, so `status` and `runs.jsonl` show who recorded it. The reviewer's verdict command (`agents/reviewer.md`, `/review-harness`, `/code-review`) ends with `--by reviewer`, keeping the `bash <plugin>/hooks/…` shape that `allowed-tools` matches. Not enforced
- Org verdict categories: `~/.review-harness/org/categories.txt` (one `[a-z-]+` word per line) adds categories `run-state.sh verdict FAIL` accepts; other words still warn
- `refactor-architect` and the main session route `git`, `grep`/`find` and test commands through `rtk-wrap.sh`, like the other agents
- `constraints.md #review`: the two failure-pattern lines are one pointer to `agents/reviewer.md` step 5 (the reviewer's base extract shrinks)
- `commit-gate.sh` lets the read-only `git commit --dry-run` and `git am --show-current-patch` pass, and its header says `git pull` (which can create a merge commit) is not covered; `/register-repo` prints scan-repo's reason after `scan unavailable:` instead of the bare notice
- `commit-gate.sh` reads options per subcommand: the value of an option that takes one (`--trailer`, `--author`, `-X`, `--into-name`, also by a unique prefix like `--mess`, and after the last letter of a bundle like `-am`), anything after `--` or `--end-of-options`, and a negated `--no-dry-run` / `--no-abort` (or a prefix of it) no longer make a write look like a dry run or an abort; `rebase --cont` (a prefix of `--continue`) is gated. A dry run, abort or plain rebase now passes only when the git command after the subcommand ends at a command separator and holds only plain word characters and redirects (`2>&1`, `>/dev/null`; a redirect target is not read as an option). A quote, backtick, `\`, `$`, `#`, glob, brace or `( )` could hide a `--no-dry-run` or `"--continue"`, so such forms — and quoted mentions like `echo "git rebase main"` — are gated as writes

**Fixed**
- `detect-repo.sh` printed no `hint` line and no `=== End Active Repo ===` marker when the org hint file was missing
- `/register-repo` printed `no matches found` under zsh when no org registry exists
- `scan-repo.sh` printed a broken `local_path` for a folder name containing a backtick: it now refuses such a repo path (exit 1, with the reason), so `/register-repo` stops at its scan step
- `detect-repo.sh` read only the first `knowledge/<org>/repos.md`: it now matches against every org registry in sorted order, then the flat `knowledge/repos.md` (first match wins; the block is printed from the file that matched; the not-registered hint names the first file, which is `/register-repo`'s target). `find-consumers.sh` searches the repos of the same files, each `local_path` once
- `pre-tool-use.sh` / `post-tool-use.sh` needed `shasum`: they now hash with the same fallback as `state-dir.sh` (`shasum` → `sha1sum` → `cksum`), so approvals and the edit debounce work on systems without `shasum`
- `session-start.sh` showed `~/.review-harness/knowledge/index.md` as the source even when `REVIEW_HARNESS_HOME` points elsewhere; it shows the real path
- `rtk-wrap.sh`: rtk dropped a `--` separator (rtk 0.40 drops a `--`, so `rtk grep -n -- '--continue' <file>` reads the dash pattern as an option), so a command containing `--` now runs raw; `aggressive` mode passed `-u`, which rtk does not accept — it passes `--ultra-compact`
- `test-runner` description now names `baseline.txt` among the files it writes; `find-consumers.sh` header lists every breaking kind (renamed/removed/retyped/now-optional/now-required)

### v0.6.0 (2026-11-16)

**Register a repo without writing `repos.md` by hand**
- New `hooks/scan-repo.sh [dir]`: prints a proposed registry block for the repo root — `local_path`, `role: TODO`, `stack` (package.json deps with major version, Python packages, Go version, Rust), `layout`, `path_alias` from `tsconfig.json`, `test_cmd` from `detect-test-cmd.sh`, `check_cmd` (`ruff check .` with a ruff config, `go vet ./...` with `go.mod`; none for TypeScript, which tsc/eslint already cover) and workspace patterns in `special`. Reads only; the same files give the same block
- New `/register-repo` skill: shows the scan, asks up to 3 questions (role, test/check commands, up to 3 team rules for `special`), shows the final block and appends it only after the user confirms — to the registry `detect-repo.sh` reads, else the only `knowledge/<org>/` folder, else the flat `knowledge/repos.md` — then checks it with `detect-repo.sh`. An already registered repo is shown and left unchanged. No new registry keys
- `/review-harness` Active Repo Gate: for code work in an unregistered repo, or with no registry at all, offers `/register-repo` once per work tree; "continue" creates `<state dir>/register-declined` and the offer is not repeated. `detect-repo.sh` is unchanged

**Renamed to `review-harness`** (the entries below keep the names that were current at the time)
- Plugin, marketplace and entry skill: `front-harness` → `review-harness` (`/review-harness`, agents `review-harness:<agent>`)
- Home folder: `~/.front-harness/` → `~/.review-harness/`. Environment variables: `FRONT_HARNESS_HOME` → `REVIEW_HARNESS_HOME`, `FE_HARNESS_*` → `REVIEW_HARNESS_*`
- No fallback to the old names. To migrate: `mv ~/.front-harness ~/.review-harness`, replace the old path inside your own overlay and knowledge files, uninstall `front-harness@front-harness` and install `review-harness@review-harness`
- Added `tests/run.sh` (hook smoke tests) and CI on Linux and macOS

**Stack rules moved into a profile** (wording unchanged, only the location)
- New `profiles/web-frontend.md` (tags `#code-rules`, `#implementation`, `#review`, `#detection`) holds the TypeScript / React / Next.js / Tailwind / Zustand / TanStack Query / Socket.IO rules that were in `constraints.md`, `agents/developer.md`, `agents/reviewer.md`, `agents/refactor-architect.md` and the `code-review` / `refactor-scan` skills
- `hooks/extract-constraints.sh <agent> [profile]`: appends the agent's profile sections as a `## Profile — <name>` block. No default profile; an unknown name exits 2 with nothing on stdout. The 8192-byte budget warning measures the non-profile part, profile bytes are reported separately
- Every skill passes `web-frontend`, so agents receive the same rules as before
- Review category `react-perf` renamed to `performance`. The Three.js / R3F gates (`three-perf`) left the public rules; keep them in your organisation overlay if you need them

**Profiles chosen from the change, test commands for more stacks**
- New `hooks/detect-profile.sh [path...]`: picks profiles from the changed files (`.tsx`/`.jsx`/`.vue`/`.svelte`/styles → `web-frontend`; controllers, `routes/`, `api/`, SQL, migrations → `web-api`; both → also `web-common`). Any other file (e.g. a `.ts` hook, an `api/` route, a changed `package.json`) counts by the dependencies of its nearest `package.json` / `pyproject.toml` / `requirements*.txt`, so monorepo packages are judged separately; a clean tree uses the repo-root manifest. Prints only profiles that exist, so a profile applies once its file lands; a Python or Go change gets the generic rules instead of the React gates
- Skills pass `detect-profile.sh` output to `extract-constraints.sh` instead of a fixed `web-frontend` (developer / refactor-architect: the plan's Affected Files; reviewer / test-runner / code-review: the current changes). The reviewer's first output line is `Profile: <names|none>`
- `extract-constraints.sh` takes a comma list of profiles (one block each, in order; any unknown name exits 2); an empty argument means no profile. Single-profile output is unchanged
- New `hooks/detect-test-cmd.sh [dir]`: registry `test_cmd`, `package.json` `scripts.test` (pnpm/bun/yarn/npm by lockfile, npm's placeholder ignored), vitest/jest config, a bun lockfile (`bun test`), pytest, `go.mod`, `Cargo.toml`. Used by test-runner and the `tdd` probe
- Registry keys `test_cmd` and `check_cmd`; `detect-repo.sh` now also prints `local_path`. With `check_cmd`, `post-tool-use.sh` runs it from the registered `local_path` after any edit in that repo instead of tsc/eslint; without it nothing changes
- `pre-tool-use.sh` also gates lock files and `.env` / `.env.*` (except `.env.example`, `.env.sample`, `.env.template`)
- `feature` intent keywords gain `endpoint`, `migration`, `schema`, `handler`

**`web-api` and `web-common` profiles** (every gate comes from a real bug fix)
- New `profiles/web-api.md`: `#implementation` (developer, 6 do's) and `#review` (reviewer, 17 gates: 4xx for client errors, param and DTO validation, no internals in error bodies, exception filters that never respond, write-after-read without upsert/atomic update/transaction, transaction client not passed on, unawaited promises, unstable pagination order, missing owner / soft-delete predicate, unescaped `$regex`/`$where`, authorization from client headers, CORS with credentials, `sameSite: 'none'` without `secure`, breaking contract changes, per-instance socket targeting, destructive migrations or hand-written DDL without `IF NOT EXISTS`, boot-time failure on a feature-only env var). The gates that cannot be fully decided from a diff (write-after-read, owner predicate, contract change) carry an explicit escape
- New `profiles/web-common.md` (`#review`): consumer not updated for a contract change in the same change set, client header / `withCredentials` the API's CORS does not allow, env URL without a scheme or env key missing from one environment, exact status-code branch on an endpoint whose mapping changes
- `constraints.md` `#review` (every repo): password / token / webhook URL in a tracked env or config file, or a literal secret fallback → FAIL (`.env.example`-style placeholders and `${VAR}` references pass)
- `detect-profile.sh`: an `api/` or `routes/` path no longer adds `web-api` when the nearest manifest is a frontend-only package (a client `src/api/` folder), except Next.js server routes under `app/api/` or `pages/api/`. `*.sql`, migrations, `*.controller.*` and the new `src/server/` rule always add it (a Next app with Prisma migrations gets the migration gate). With no manifest or a backend manifest nothing changes
- The `web-frontend` profile block is unchanged
- Org profile overlay: `~/.review-harness/org/profiles/<profile>.md` (same `## #tag` format) is appended inside that profile's block under `### Org rules — <profile>`, so organisation rules for a stack load only with it and count as profile bytes. An org file alone does not make a profile valid (unknown public profile still exits 2); with no org file the output is unchanged
- `agents/reviewer.md` and the `#failure-patterns` ledger format: one category list, `correctness | performance | design | scope | security | contract | ops | state-mgmt` (the ledger's `org` category is dropped)

**Fixed**
- `agents/test-runner.md`, `agents/refactor-architect.md`: cwd-relative `bash hooks/...` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks/..."` (the cwd is the consumer repo)
- `run-state.sh override` after `abandon` now starts a fresh idle record, so `check` sees the override (it used to exit 3)
- `run-state.sh` work-tree hash no longer writes blobs into the consumer's `.git/objects`: new objects go to a temp store with the repo's store as alternate. The hash value is unchanged, so recorded PASSes stay valid
- The wisdom folder follows `REVIEW_HARNESS_HOME` (`session-start.sh`, `knowledge-has-content.sh`, `save-knowledge`)
- `extract-constraints.sh` replaces `${CLAUDE_PLUGIN_ROOT}` with the plugin path in its output, as `org-overlay.sh` does
- `state-dir.sh` falls back to `sha1sum`, then `cksum`, when `shasum` is missing, so same-named repos no longer share state
- The session-start knowledge summary prints the first 5 `- **Key**:` lines of `knowledge/index.md` instead of a fixed key list
- Docs that contradicted the code: README (stack support today, `.env*` protection only after `install.sh`), `code-review` (no commit follows a PASS), `CLAUDE.md` handoff (max 6 bullets with `plan_path`), `docs/hooks.md` (Small change exception, hooks auto-discovered), knowledge is optional (no `/setup`), `/rtk` → `/rtk-toggle`, neutral test example in `agents/developer.md`

### v0.5.0 (2026-11-16)

**Focus on code development quality — UI/design-only features removed**
- Removed 5 skills and 2 agents dedicated to UI/design implementation. The remaining workflows are Feature / Small change / Review / Refactor, with 10 skills and 4 agents
- UI requests are classified as `feature`. A design URL is only a reference input written to `plan.md → Inputs.Design` and does not select a workflow
- The `Reuse` item in `plan.md` is filled in by the main session at plan time. If it is empty, reviewer FAILs
- Added reviewer static gates: importing code from another app repo, missing accessible name on an icon-only button, click elements that cannot be operated by keyboard, `.npmrc` staged, raw hex while tokens are wired up, server state kept in Zustand
- Added developer rules: no imports from another app repo, check the Tailwind major version, browser-only imports use `dynamic({ssr:false})`

**Organisation overlay and knowledge moved outside the plugin folder**
- The overlay is read from `~/.front-harness/org/` and knowledge from `~/.front-harness/knowledge/` (changeable with `FRONT_HARNESS_HOME`). The plugin folder contains no organisation-specific files
- Rewrote the README for a generic harness and added a "Preparing knowledge" section. A skill that generates knowledge automatically is planned for 0.6.0

### v0.4.0 (2026-11-16)

**Review gate enforced by a file, not by the conversation**
- `hooks/run-state.sh` + `run-state.json`: records the workflow type, per-step completion, retry count, the reviewer verdict and the work tree hash at review time. Every workflow (including Small change) calls `start` in its first step
- `git-commit` proceeds only when `run-state.sh check` passes: PASS + matching hash, or a recorded user override. If the code changes after the review, a re-review is required. `git add` / commit do not change the hash
- `hooks/commit-gate.sh` (PreToolUse Bash): a safety net that denies `git commit` using the same check. No state file → pass, an active run older than 24 hours → advice only
- Only reviewer records the verdict. If the record is missing, reviewer is spawned once more, and if it is still missing the run is treated as having no verdict (commit stays blocked)
- Reviewer FAIL also counts toward the same `MAX_ATTEMPTS = 3` as test failures. When the limit is reached, the remaining fix list is reported
- If there is an unfinished run, the skill asks "Resume / Start new" at start (`abandon`)

**The plugin creates no files inside the consumer repo**
- Moved `.front-harness-cache/` (rtk flag, approval records, debounce cache) and `plan.md` to `~/.front-harness/state/<repo-id>/` (`hooks/state-dir.sh`, keyed on the absolute path of the work tree, so separated per worktree)
- The rtk mode is stored per work tree, not globally in the plugin directory
- `.front-harness-cache/` / `plan.md` left over in existing repos are not deleted automatically

**Organisation-specific content separated**
- Separated organisation-specific content from the repository; the files in the repository keep only generic rules (`hooks/org-overlay.sh`)

### v0.3.1 (2026-11-16)

- Agent model tiering: reviewer / refactor-architect → `fable`, developer / test-runner stay on `opus`
- Added the `front-harness` Small change path: changes touching 2 or fewer existing files with no new elements are implemented directly by the main session → test-runner → reviewer → git-commit
- `constraints.md #failure-patterns` GC: removed 6 entries older than 90 days. The 2 entries for missing useEffect cleanup / index-as-key were promoted to static gates in `agents/reviewer.md`
- The Small change path skips writing `plan.md` and waiting for approval
- Usage-based model selection: when 5-hour usage is ≥ 80%, ask once before spawning reviewer / refactor-architect (`Keep Fable` / `Opus for this run`), and the choice holds for that run. Shared by `front-harness` / `code-review` / `refactor-scan` (`hooks/usage-state.sh`; usage is written to `~/.claude/usage-state.json` by the status line wrapper). Below 80% or `unknown`, it does not ask and the frontmatter value applies
- `plugin.json` / `marketplace.json` 0.3.1

### v0.3.0 (2026-09-23)

**Hook contract fix — restored 2 feedback loops that had been silently dead**
- `post-tool-use.sh`: was emitting tsc/eslint errors as plain-text stdout + exit 2. Plain-text stdout from PostToolUse is not delivered to Claude (debug log only). → Delivered as `hookSpecificOutput.additionalContext` JSON (encoded with jq/python3). Added detection of ESLint flat config (`eslint.config.{js,mjs,cjs,ts,mts}`) and `.eslintrc.{cjs,yml,yaml}`
- `pre-tool-use.sh`: the "REVIEW REQUIRED" warning was ineffective for the same reason. → Actually blocks with `permissionDecision: deny`. After user approval, `bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-tool-use.sh" --approve <path>` records an approval with a 30-minute TTL → the retry passes. Can be bypassed entirely with `FE_HARNESS_ALLOW_CONFIG_EDITS=1`

**Skill path bug fix**
- Every skill used the cwd-relative path `bash hooks/...` → all of them failed when run from a consumer repo (cwd). Replaced with the absolute path `${CLAUDE_PLUGIN_ROOT}/hooks/...`

**Latest skill spec applied (per code.claude.com/docs/en/skills)**
- `!`cmd`` / ```` ```! ```` dynamic context injection: detect-repo, rtk mode, knowledge presence, `git branch -a`, `git diff --stat`, test framework probe, etc. are inserted automatically at skill load time → saves 2–4 tool calls per skill; the rule "do not re-run detect-repo" is stated explicitly
- `disable-model-invocation: true`: git-branch / git-pr / rtk-toggle (user-driven only; the description is dropped from context, saving tokens)
- `allowed-tools`: pre-approves read-only git commands and plugin hook scripts (removes permission prompts)
- Standardised `argument-hint` and `$ARGUMENTS` passing
- Rewrote descriptions for trigger accuracy (when to fire / when not to / including Korean trigger phrases)
- Removed the dead `**Model**: claude-opus-4-8` line from the body (for a skill model, only the frontmatter field is valid)

**Agents**
- `model: opus` alias (recommended by the docs) + `effort:` + `color:`. Dropped the procedure of editing 7 files on a model bump. The commit trailer is the model-agnostic `Co-Authored-By: Claude <noreply@anthropic.com>`
- Spawn rule stated explicitly: when installed as a plugin, `subagent_type` uses the `front-harness:<agent>` namespace

**Other**
- `plugin.json`: non-standard `knowledge` key → moved to `metadata` (removes the `claude plugin validate` warning), added `displayName`/`keywords`, 0.3.0
- `git-commit`: guard against staging `plan.md` and `.front-harness-cache/`
- `refactor-scan`: runs per slice (≤5 files) + verifies after each slice

### v0.2.0 (2026-07-10)

**Hook wiring repair (previously the hooks were not actually running)**

- `hooks.json`: `$(dirname "$0")` → `${CLAUDE_PLUGIN_ROOT}/hooks/...` (bug where the hook script path was not resolved)
- `pre/post-tool-use.sh`: parse the hook payload from stdin JSON `.tool_input.file_path` (the former `$CLAUDE_TOOL_INPUT` env is the fallback)
- `post-tool-use.sh`: relative-path infinite loop guard, PID-based temp files, `eslint --max-warnings=0`
- `rtk-wrap.sh`: fixed the bug where `npx` was lost in rtk mode (local binary resolution is kept)
- `session-start.sh`: fixed the bug where cache cleanup deleted `rtk-session.flag` every 60 minutes
- `detect-repo.sh`: fixed prefix false positives (`my-app-api` was matched as `my-app`)
- `knowledge-has-content.sh`: BSD grep compatibility + reflects the actual knowledge tree
- `install.sh`: removed the overwrite on settings.json parse failure (loss of the entire settings) + `.bak` backup

**Install method switched — symlinks → proper plugin registration**

- With the symlink method only skills were activated and hooks/agents were not loaded → switched to a 2-step install with `/plugin marketplace add` + `/plugin install`
- Rewrote `install.sh`: removed symlink creation, cleans up old-version links automatically (only after confirming plugin registration — prevents all skills from dying when run before registration), and only handles the settings deny rules + rtk detection + registration guidance
- Added `name`/`owner` fields to `marketplace.json`, `plugin.json` v0.2.0

**Agent structure**

- 7 → 6: merged `api-integrator` into `developer` (removes the loss of context on write handoff = a cause of duplicate code, and also resolves the ordering defect so that API code is written before test-runner)
- Added YAML frontmatter to all agents (`name`/`description`/`model: claude-opus-4-8`/`tools` scoping) — the former `**Model**:` notation in the body was not read by the harness, so the pin was ineffective

**Context diet**

- `#failure-patterns` distilled from 40 entries → 6 (removed duplicates of the reviewer gates/ESLint). Reviewer extract 9.4KB → within budget (8KB)
- Replaced the GC rule from line-count based → byte based (3072B)
- Aligned the tag table with the actual behaviour of extract-constraints.sh

### v0.1.0 (2026-05-27)

**Initial setup**

- Plugin skeleton (`.claude-plugin/`, `agents/`, `skills/`, `hooks/`, `CLAUDE.md`, `constraints.md`)
- Ported 7 agents + 17 skills + 7 hooks (English, token-minimised)
- Pinned all agent models to `claude-opus-4-7`

**Repo context**

- Seeded 21 failure-patterns in `constraints.md`
- New `hooks/detect-repo.sh`: cwd → repo matching
- New skills to register/look up/add entries in the repo registry

**User-Driven Git policy**

- Changed `git-branch` / `git-pr` so they do not run automatically
- Removed the automatic `git-branch → git-commit → git-pr` chain from the workflow chain → `git-commit → [DONE — await user git ops]`
- `/git-branch` first lists existing branches and selects a base (main/stage/production, etc.) → asks for the name → prints the command
- `/git-pr` only generates the body + URL and does not run `gh`
- Removed the `git-issue` skill — on 3 consecutive failures it only reports the context to the user (creating an issue is the user's call)

**codex-review removed**

- Removed the `codex-review` skill — the parallel `[reviewer || codex-review]` gate → simplified to a single `reviewer` gate. All 4 reference sites cleaned up
