```
reproduce -> plan.md (## Bug) -> user approval
-> test-runner (baseline) -> developer (regression test RED, then fix) -> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops] -> save-knowledge?
```

Run state: `start bugfix reproduce baseline developer test-runner reviewer git-commit`.

- **Reproduce first**: run the failing test, or a command that shows the failure (request, script, CLI), and record it in `Repro`. Then trace it to `Cause` (`file:line` + why). If neither reproduces it, stop and ask the user for the exact symptom and environment (input, logs, version). Never fix by guess
- **Fix of at most 2 files**: skip the approval wait, but show the user the `Cause` and `Regression test` lines before `developer` starts. The plan is still written
- **"Why" only**: if the user asked why but not for a fix, stop after `Cause`, report the `## Bug` lines and ask whether to fix (`run-state.sh done` if not)
- If `developer` reports the regression test passing before the fix, the `Cause` is wrong: run `run-state.sh attempt` (stop and report at `LIMIT REACHED`), then redo reproduce — run state still shows `reproduce` done; redo it anyway
- Pass the developer's `red:` line to `reviewer`
