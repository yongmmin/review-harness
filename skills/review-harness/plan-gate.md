```markdown
# Plan: [task name]

## Goal
[what and why]

## Done When
- [observable outcome] — check: [test name, command, or manual step]

## Out of Scope
- [what this change leaves untouched]

## Intent
[feature / bugfix / refactor]

## Inputs
- Design: [reference URL or none]
- API: [spec, endpoint, or none]

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
- Callers/Consumers: [each changed export / route / event → files that use it, or "none — new"]
- Repo rules: [docs from repo-rules.sh <Affected Files> this change follows (file → section), or "none found"]
- Responsibility: [how logic splits across files] (optional)
- Risk: [conflict with an existing pattern] (optional)
- Pattern: [one neighbouring file to imitate] (optional)
- Tests: [existing test files covering the area; new tests to add] (optional)

## Contract (only when another repo may use what changes)
- Producer: [this repo]
- Consumers: [repo → files from find-consumers.sh, or "none — <reason>"]
- Compatibility: [additive | breaking]
- Deploy order: [e.g. producer first; for breaking: consumers updated first, or both together]

## Execution Steps
- (more than 6 Affected Files) Task 1: [file group] — tests: [that task's test files or command]

## Branch
[feat|fix|ui|refactor]/[task-name]
```

**Done When / Out of Scope**: `Done When` lists 2–5 observable outcomes (behavior a user, caller or test sees — not "code written"), each with its check: a test name, a command, or a manual step. `Out of Scope` is 1–2 lines naming what the change must not touch. `reviewer` checks both.

**Design Check** is filled by the main session before approval, from the repo and not from memory; `developer` follows it and `reviewer` judges against it:
- `Reuse` must never be empty: search the repo and the shared packages it depends on for an existing component/hook/util that covers the request, then name what is reused, or write "none — new primitive justified because X" with one concrete reason. `reviewer` FAILs a plan whose `Reuse` line is empty
- `Callers/Consumers` comes from grep: it names every file that uses each changed exported symbol, route or event; a file the change will leave alone gets `no change needed: <reason>` — `reviewer` FAILs a listed file that is neither changed nor marked
- `Repo rules` comes from the output of the plugin's `hooks/repo-rules.sh <Affected Files>` (the docs the change must follow)
- The lines marked optional are written only when they change what the developer does; omit the others
- More than 6 Affected Files → `Execution Steps` become ordered `Task N` lines (file group + that task's tests); `developer` runs each task's tests before the next
- A schema or data migration, a dependency upgrade or a performance goal: say in `Done When` how it is checked (rollback path, breaking changelog items, the measured target)

**Contract rules**: write `## Contract` only when the change adds, changes or removes a route, socket event or request/response field another repo may use. `breaking` = renamed, removed, type changed, a response field made optional/nullable, a new required request field, or an existing optional request field made required (a request field made optional is not breaking). For `breaking`, run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/find-consumers.sh" <term...>` from the repo root with every renamed, removed, retyped, now-optional or now-required field, route and event; it greps the other registered repos — list the hits per repo under `Consumers`. A consumer repo this run does not change gets its follow-up named in `Out of Scope`. `reviewer` FAILs a breaking contract with no consumers listed. The producer run goes first; the consumer repo's run takes this block as its `Inputs.API` (Completion).

`plan.md` is a working artifact: write it to `<state dir>/plan.md`, never to the consumer repo. Every time you write or update it, tell the user its full absolute path in one line.

Ask: `Please review <absolute path of plan.md>. Approve it and I will execute.`
