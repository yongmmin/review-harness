---
name: git-pr
description: Generate a PR title, body, copy-pasteable `gh pr create` command and prefilled GitHub compare URL from the current branch ("PR 만들어줘", "PR 본문"). Never pushes or runs gh — the user submits.
argument-hint: "[base-branch]"
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/state-dir.sh *) Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh *) Bash(git log *) Bash(git diff *) Bash(git branch *) Bash(git remote *) Bash(git rev-parse *) Bash(git status *)
---

# Skill: git-pr

**Trigger**: user-invoked only — `/git-pr [base]` or natural language like "PR 본문 만들어줘", "PR 날릴 준비해줘"
**Purpose**: Produce a reviewable PR title and body for the user to copy/paste. **Plugin does NOT push, does NOT call `gh pr create`** — user runs it themselves.

---

## Policy

- Plugin never runs `git push` / `gh pr create` / `gh pr edit`
- Plugin generates title + body + a copy-pasteable command AND a prefilled GitHub compare URL
- User reviews, copies, runs the command (or opens the URL in browser)

---

## Injected Context (at load — do not re-run)

```!
echo "head:   $(git branch --show-current 2>/dev/null)"
echo "remote: $(git remote get-url origin 2>/dev/null || echo none)"
echo "upstream: $(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo 'not pushed')"
echo "integration branches: $(git branch --format='%(refname:short)' 2>/dev/null | grep -Ex 'main|master|develop|development|stage|staging|production|prod|release' | tr '\n' ' ')"
BASE="$ARGUMENTS"; [ -z "$BASE" ] && BASE=main; git rev-parse --verify -q "$BASE" >/dev/null 2>&1 || BASE=main
echo "--- commits $BASE..HEAD ---"; git log "$BASE"..HEAD --format='%h %s' 2>/dev/null | head -40 || true
echo "--- changed files $BASE...HEAD ---"; git diff "$BASE"...HEAD --name-only 2>/dev/null | head -80 || true
```

Requested base (may be empty → `main`): `$ARGUMENTS`

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills git-pr 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

## Workflow

1. Confirm current branch and base from the injected block. Ask only if the base is ambiguous (2+ integration branches and none given):
   - "어느 base로 PR을 만들까요? (기본: `main`)"
   - If the user picks a base different from the one used in the injection, re-run only `git log`/`git diff --name-only` for that base via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" git ...`
2. Remote URL → prefilled compare URL (from injection). Read-only, never modifies remote
3. Commit list → body sourcing (from injection)
4. Changed files → "Changed areas" (from injection)
5. Generate title (≤ 70 chars) + body
6. Print: title, body, copy-pasteable `gh pr create` command, prefilled GitHub compare URL

---

## Title Rules

- ≤ 70 chars
- Conventional commit-ish prefix preferred (`feat:`, `fix:`, `refactor:`, `ui:`) but not enforced
- No trailing period

---

## Body Template

```markdown
## Summary
- <bullet 1>
- <bullet 2>
- <bullet 3>

## Changed Areas
- `path/to/area1/` — <one-liner>
- `path/to/area2/` — <one-liner>

## Test Plan
- [ ] <step>
- [ ] <step>

## Related
- Issue: #N (omit if none)
- Plan: `plan.md` (if applicable — read it from the plugin state dir, `$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/state-dir.sh")/plan.md`; do not link the path in the PR)
```

Rules:
- Summary: 2-4 bullets max, focus on WHY, not WHAT
- Changed Areas: top-level directories or modules, not every file
- Test Plan: actionable checkboxes
- Related: omit empty fields

---

## Output Format

```
## PR Ready

### Title
feat: add user-login-form with React Hook Form

### Body
<full markdown body>

### Command to run (copy-paste)
gh pr create \
  --base main \
  --head feat/user-login-form \
  --title "feat: add user-login-form with React Hook Form" \
  --body-file -  <<'EOF'
<body>
EOF

### Prefilled URL (browser fallback)
https://github.com/<owner>/<repo>/compare/main...feat/user-login-form?expand=1&title=<encoded>&body=<encoded>

### Reminders
- Push the branch first if you haven't: `git push -u origin feat/user-login-form`
- Confirm base branch is correct before submitting
```

---

## Constraints

- **Never push** — `git push` is the user's action
- **Never run `gh pr create` / `gh pr edit`** — output the command only
- **Never modify remote in any way**
- Read-only git inspection allowed (`git log`, `git diff`, `git remote get-url`, `git rev-parse`)
- Any inspection beyond the injected block goes through `bash "${CLAUDE_PLUGIN_ROOT}/hooks/rtk-wrap.sh" git ...` when rtk mode is on
- If branch not yet pushed, the prefilled URL is still emitted — user pushes then opens it
- If origin remote is missing or non-GitHub, omit prefilled URL and only print the `gh pr create` command
