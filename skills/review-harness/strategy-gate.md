**Strategy check** — at most once per run, only on a path that writes `plan.md`. It advises and never blocks. Skip it on a resumed run whose injected `run state` line shows `strategy`.

1. Read the strategy file (the path `strategy-file.sh` prints) and the first 8 lines of `run-stats.sh --repo <work-tree name> --since 30`.
2. Judge in one or two sentences: does the request move the `Goal` or `Metrics` more than the open hypotheses (`[trying]`, `[untested]`) or the obvious next step would? Does it hit a `Non-goals` or `Kill criteria` line?
3. Best move → write the plan's `## Why` line naming the goal or metric it moves, and ask nothing.
4. Otherwise → say so in one line with one concrete higher-leverage alternative, then ask once with `AskUserQuestion`: `Proceed as asked` | `Do the alternative`. Either answer goes ahead; never ask again in this run. `Proceed as asked` → the `## Why` line also notes the declined suggestion in one line. `Do the alternative` → the run re-enters the Request Gate at step 2 with the alternative as the request; do not re-run this check on it, the outcome is `suggested-followed`.
5. Right after `run-state.sh start`, record the outcome: `run-state.sh strategy aligned` (step 3), `suggested-followed` or `suggested-declined` (step 4).
6. After the run, if the work settled a hypothesis or produced a decision, propose one `/strategy update <what>` line for the user to run. Never edit the strategy file yourself; it changes only on the user's yes, through `/strategy`.
