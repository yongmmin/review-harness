```text
MAX_ATTEMPTS = 3   # one shared counter in run-state.json; the script increments it

run implementation agent
run test-runner when applicable
run reviewer

every failed attempt (tests or reviewer FAIL):
  append one line to `## Attempts` in plan.md (no plan: <state dir>/attempts.md):
    N. hypothesis → change → result   # what the attempt assumed, what it changed, which test/issue failed

if tests fail:
  run-state.sh attempt
  retry with only the failing error context

if reviewer returns FAIL:
  (run-state.sh verdict FAIL already counted the attempt)
  act on each issue's route:
    replan -> update plan.md for it and get the user's re-approval before the retry
              (Small change: no plan — ask the user, or switch to the Feature path)
    patch  -> retry with only the patch / replan issues as the fix list
    defer  -> never retried; keep for the final report

if the implementer reports `wrong: <issue id> — <evidence>` in blockers (no code change in that reply):
  stop and show the user the issue and the evidence; the user decides: patch it, or commit anyway (run-state.sh override)

if the script prints "LIMIT REACHED" (exit 2):
  record a repeatable failure pattern if appropriate (append to the `ledger:` path from extract-constraints.sh,
    in the entry format and scope of agents/reviewer.md → Ledger; a new file starts with `## #failure-patterns`)
  stop and report full failure context — including the remaining reviewer fix list — to user
  if the same test or issue failed in every attempt, ask the user whether the plan is wrong:
    Replan -> revise plan.md, re-approval, then run-state.sh abandon and start a new run
              (Small change: no plan — ask the user, or switch to the Feature path)
    Stop   -> end here
  user decides whether to file a GitHub issue manually (plugin does not auto-create issues)
```

Test failures and reviewer FAILs count against the same `MAX_ATTEMPTS`.

Every retry runs `test-runner` again before `reviewer`, on the Small change path too: the tests record holds only for the work tree it was taken on.

Retry context must contain only:
- failing command
- failing file/test identifier
- shortest useful error excerpt, or the reviewer's `patch` / `replan` issues
- the Attempts lines so far, so the retry does not repeat an idea that already failed; on the second failure of the same test or issue the developer gives `root cause:` before editing
- bugfix: the first developer run's `red:` line — carry it through every retry so a re-spawned developer's handoff, and the `reviewer` prompt, never drop it

Never resend full previous transcript.
