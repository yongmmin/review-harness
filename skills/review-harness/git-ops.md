| Operation | Plugin behavior |
|-----------|-----------------|
| **Branch create** | User invokes `/git-branch` or asks naturally. Plugin: (1) **lists existing branches** via `git branch -a` (read-only), (2) asks user which **base branch** to fork from via `AskUserQuestion` (main / stage / production / etc.), (3) asks for the new branch name, (4) prints `git checkout -b <name>` (or `origin/<base>` variant). **Never executes.** |
| **Commit** | Auto-chained after reviewer PASS (current behavior) — produces Conventional Commit |
| **Push** | **Never auto-pushes.** User pushes themselves |
| **PR create** | User invokes `/git-pr` or asks naturally. Plugin generates title + body + copy-pasteable `gh pr create` command + prefilled GitHub compare URL. **Never executes `gh`.** |

### Trigger phrases (any language)

| User says | Plugin action |
|-----------|---------------|
| "create a branch" / `/git-branch` | Run `git-branch` skill (ask name, print command) |
| "create a PR" / "write the PR body" / "get the PR ready" / `/git-pr` | Run `git-pr` skill (generate body + URL) |
| "push it" | Refuse politely — push is the user's action. Plugin can show the suggested command but does not run it |
