```markdown
# Plan: [task name]

## Goal
[what and why]

## Why
[one line: the strategy goal or metric this moves, or `no strategy file`]

## Done When
- [observable outcome] — check: [test name, command, or manual step]

## Out of Scope
- [what this change leaves untouched]

## Intent
[feature / bugfix / refactor / review]

## Inputs
- Design: [reference URL or none]
- API: [spec, endpoint, or none]
- Web guidance: [guide ids, none, or unavailable]

## Affected Files
- path/to/file.tsx - [change]
Risk tier: [first line of `risk-tier.sh --paths <these files>`]

## Bug (bugfix only)
- Symptom: [observed vs expected]
- Repro: [failing test id, or command + its key output line]
- Cause: [file:line — why it fails]
- Regression test: [test file + name, or "none — <why none is possible>"]

## Design Check
- Reuse: [component/hook/util to reuse, or "none — new primitive justified because X"]
- Responsibility: [how logic splits across files]
- Risk: [conflict with existing pattern, or "none"]
- Callers/Consumers: [each changed export / route / event → files that use it, or "none — new"]
- Pattern: [one neighbouring file to imitate]
- Tests: [existing test files covering the area; new tests to add]

## Contract (only when another repo may use what changes)
- Producer: [this repo]
- Consumers: [repo → files from find-consumers.sh, or "none — <reason>"]
- Compatibility: [additive | breaking]
- Deploy order: [e.g. producer first; for breaking: consumers updated first, or both together]

## Only When Relevant (omit lines that do not apply)
- Migration: [rollback path; what happens to existing data]
- Dependency upgrade: [breaking changelog items that touch this repo]
- Performance: [how it is measured; target value]

## Execution Steps
- Step 1: [agent] - [task]
- Step 2: [agent] - [task]
- (more than 6 Affected Files) Task 1: [file group] — tests: [that task's test files or command]

## Branch
[feat|fix|ui|refactor]/[task-name]

## Commit Units
- [type]: [description]
```

**Design Check rules**:
- Required for `feature`, `bugfix`, `refactor`. Omit for `review`
- Max 1 line per bullet. No prose
- If `Reuse` says "new primitive", justification must be one concrete reason — not vague "for flexibility"
- `Reuse` is filled at plan time by the main session — no agent does it for you. Before writing the plan, search the repo and the shared packages it depends on for an existing component/hook/util that covers the request, and use project knowledge
- `Reuse` must never be empty: name what is reused, or write "none — new primitive justified because X". `reviewer` FAILs a plan whose `Reuse` line is empty
- `Callers/Consumers`, `Pattern`, `Tests` are also filled by the main session before approval, from grep (not memory). `Callers/Consumers` names every file that uses each changed exported symbol, route or event; a file the change will leave alone gets `no change needed: <reason>` — `reviewer` FAILs a listed file that is neither changed nor marked
- More than 6 Affected Files → `Execution Steps` become ordered `Task N` lines (file group + that task's tests); `developer` runs each task's tests before the next
- `developer` reads `plan.md` as the canonical Design Check. The Reuse line is the single source of truth
- Caught design mistakes BEFORE implementation. Read by user during approval and re-read by `reviewer` during design check

**Done When / Out of Scope rules**: required for `feature`, `bugfix`, `refactor`; omit for `review`. `Done When` lists 2–5 observable outcomes (behavior a user, caller or test sees — not "code written"), each with its check: a test name, a command, or a manual step. `Out of Scope` is 1–2 lines naming what the change must not touch. `reviewer` checks both.

**Contract rules**: write `## Contract` only when the change adds, changes or removes a route, socket event or request/response field another repo may use. `breaking` = renamed, removed, type changed, a response field made optional/nullable, a new required request field, or an existing optional request field made required (a request field made optional is not breaking). For `breaking`, run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/find-consumers.sh" <term...>` from the repo root with every renamed, removed, retyped, now-optional or now-required field, route and event; it greps the other registered repos — list the hits per repo under `Consumers`. A consumer repo this run does not change gets its follow-up named in `Out of Scope`. `reviewer` FAILs a breaking contract with no consumers listed. The producer run goes first; the consumer repo's run takes this block as its `Inputs.API` (Completion).

**Only When Relevant**: write a line only when the change has that part (a schema or data migration, a dependency version bump, a performance goal); otherwise omit the section. No new intent for these.

`plan.md` is a working artifact: write it to `<state dir>/plan.md`, never to the consumer repo. Every time you write or update it, tell the user its full absolute path in one line.

Ask: `Please review <absolute path of plan.md>. Approve it and I will execute.`
