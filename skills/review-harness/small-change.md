```
main session implements -> test-runner -> reviewer
-> git-commit -> [DONE — report ready, await user git ops]
```

The main session makes the edit itself; spawning `developer` costs more than the change. `reviewer` stays the quality gate, and the org overlay's gates (if installed) apply as usual. If the change grows past the conditions above while you work, stop and switch to the Feature path.

This path skips `plan.md` and the approval wait (Request Gate 6): say in one line what you are about to change and one `Done when: <observable outcome> — check: <test, command, or manual step>` line, then make the edit. Put that `Done when:` line in the `reviewer` prompt.

It also has no test baseline: a test that already failed before the edit counts as a failure and blocks the commit. Tell the user which tests fail and that they may predate the edit; only the user can choose an override (`run-state.sh override <reason>`).
