---
name: register-repo
description: Register the current repo in the review-harness repo registry (repos.md) — scans its manifests, proposes the registry block (stack, layout, path alias, test_cmd, check_cmd), asks up to 3 questions and appends the block only after the user confirms. Use for "register this repo" (any language), or when /review-harness offers it for an unregistered repo.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/hooks/*)
---

# Skill: register-repo

**Trigger**: `/register-repo`, or the register offer in `/review-harness` (Active Repo Gate)
**Purpose**: Turn a repo into a registry block with one confirmed, append-only write — no hand-written `repos.md`.

## Injected Context (at load — do not re-run)

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD" 2>/dev/null || true
K="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/knowledge"
# The first file detect-repo.sh reads (the first org repos.md, else the flat one); with no registry at all, the only org folder.
# Globs run in bash: zsh aborts an unmatched glob with "no matches found".
T=$(K="$K" bash -c 'ls "$K"/*/repos.md' 2>/dev/null | head -n 1)
[ -z "$T" ] && [ ! -f "$K/repos.md" ] && [ "$(K="$K" bash -c 'ls -d "$K"/*/' 2>/dev/null | wc -l | tr -d ' ')" = 1 ] \
  && T="$(K="$K" bash -c 'ls -d "$K"/*/' | sed 's#/*$##')/repos.md"
T="${T:-$K/repos.md}"
echo "registry file: $T"
# On failure, rerun for the reason so a success never mixes stderr into the block.
B=$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/scan-repo.sh" "$PWD" 2>/dev/null) \
  || B="scan unavailable: $(bash "${CLAUDE_PLUGIN_ROOT}/hooks/scan-repo.sh" "$PWD" 2>&1 >/dev/null)"
N=$(printf '%s\n' "$B" | sed -n '1s/^### //p')
C=$(grep -cxF "### $N" "$T" 2>/dev/null)
echo "existing headings named '$N' in registry file: ${C:-0}"
echo "--- proposed block (scan-repo.sh) ---"
printf '%s\n' "${B:-scan unavailable}"
```

## Org Overlay

```!
bash "${CLAUDE_PLUGIN_ROOT}/hooks/org-overlay.sh" skills register-repo 2>/dev/null || true
```

Anything printed above is organisation-specific and is part of this skill; where it conflicts with the generic rules below, it wins. Nothing printed means no overlay is installed — follow the generic rules alone.

Questions, option labels and report text are written in English. Present them in the user's language.

---

## Workflow

1. **Already registered** — the injected Active Repo block has a `- name:` line → show that block and the `registry file` path, say the repo is already registered (edit that file by hand to change it), and stop. No update flow
2. **No scan** — `scan unavailable` → report it with the reason printed after it and stop
3. **Ask** — one `AskUserQuestion` call, at most 3 questions. The proposed block holds facts read from files: never add stack entries, commands or paths it does not contain
   - Role: `What does this repo do, in one line?` Options: a one-line guess from the `stack` line | `Leave it out`. A typed answer replaces the guess
   - Commands: show the proposed `test_cmd` / `check_cmd` (or "none"). Options: `Keep as proposed` | `Drop check_cmd`. A typed answer replaces either command
   - Team rules: `Up to 3 rules agents must follow in this repo?` Options: `None`. Typed rules (max 3) go into the `special` line
4. **Build the final block** — the proposed block with: `role` = the answer (line removed for `Leave it out`); commands as answered (a dropped command loses its line); team rules appended to `special` as `; `-separated text (create the line when missing). Keep `local_path` unchanged — it is what matches the repo. Keep the `### <name>` heading unless the injected `existing headings named` count is 1 or more (detect-repo.sh prints the first block of a name): then use `<parent folder>-<name>`. Every typed value (role, team rules, edited commands) is collapsed to one line (newlines → spaces) and must not start with `### ` or `- **`, so it cannot open a new block or key
5. **Confirm** — show the final block and the `registry file` path, then ask with `AskUserQuestion`: `Write this block to <registry file>?` Options: `Write it` | `Cancel`. `Cancel` → stop, nothing written
6. **Write (only after `Write it`)** — append, never overwrite, never use the Write tool on an existing registry. Run exactly this shape (the closing `EOF` must start the line):

```bash
mkdir -p "<registry dir>" && cat >> "<registry file>" <<'EOF'

<final block>
EOF
```

7. **Verify** — `bash "${CLAUDE_PLUGIN_ROOT}/hooks/detect-repo.sh" "$PWD"` must print `- name: <name>`. If it does not, show its output and stop; do not append a second time
8. **Report** — `Registered <name> in <registry file>.` When called from `/review-harness`, continue that request using the verified block as the Active Repo

## Constraints

- Write nothing before step 5's `Write it`; write nothing inside the repo
- One append per run, to the injected `registry file` only
- A repo that is already registered is never re-registered or edited by this skill
