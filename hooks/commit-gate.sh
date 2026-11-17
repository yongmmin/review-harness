#!/bin/bash
# commit-gate.sh — PreToolUse(Bash) backstop for the review gate.
# Denies commands that write git history — `git commit`, `merge`, `cherry-pick`, `revert`, `am` (their
# `--abort` / `--quit` / `--skip` pass, as do `commit --dry-run` and `am --show-current-patch`) and
# `rebase --continue` — while a review-harness run is active and `run-state.sh check` fails. Catches `/abs/path/git`, global options before the subcommand (`-C <dir>`,
# `-c k=v`, `--git-dir <dir>`, …) and commands inside `&&` / `;` / `|` chains, `$( )` and quoted strings.
# Read-only commands (log, diff, show, status, stash list, …) always pass. It only sees Claude's Bash calls:
# commits the user types in their own terminal are never affected.
# No state file, or no active run → silent pass. Active run idle for >24h → advice only. No jq → advice that
# the gate is inactive.
# Known limits: matches the command text, so `git -C <other repo> commit` is checked against the session cwd,
# a quoted mention (`echo "git commit"`) is treated as a commit, commits made through a script are not seen, and
# `git pull` is not covered although it can create a merge commit, and an option after a quoted argument
# (`-m "a b" --dry-run`) is not seen, so that dry run is treated as a commit (fails closed).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)
HAS_JQ=1; command -v jq >/dev/null 2>&1 || HAS_JQ=0
# Without jq the raw JSON is matched: good enough to tell whether to warn.
if [ "$HAS_JQ" = 1 ]; then CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null); else CMD=$INPUT; fi

Q="'"; SEP="[;&|)\`$Q\"]"
GIT="(^|[^[:alnum:]_./-])([^[:space:];&|()\`$Q\"]*/)?git"
# Global options before the subcommand; the ones that take a separate value consume it (quoted or not).
OPT="([[:space:]]+(-[Cc]|--(git-dir|work-tree|namespace|config-env))[[:space:]]+(\"[^\"]*\"|$Q[^$Q]*$Q|[^[:space:]]+)|[[:space:]]+-[^[:space:]]+)*"
SUB="[[:space:]]+(commit|merge|cherry-pick|revert|am|rebase)([[:space:]][^;&|)\`$Q\"]*|$SEP|\$)"
HITS=$(printf '%s\n' "$CMD" | grep -oE "$GIT$OPT$SUB") || exit 0

set -f   # word-split the hit below without glob expansion
WRITES=0
while IFS= read -r hit; do
  # shellcheck disable=SC2046
  # Quoted text (a commit message) and the value after a message/file flag are data, not options:
  # `commit -m "fix --dry-run bug"` and `commit -m --dry-run` must still count as commits.
  set -- $(printf '%s\n' "$hit" | sed -E "s#^$GIT$OPT[[:space:]]+##; s/\"[^\"]*\"/ _q_ /g; s/'[^']*'/ _q_ /g")
  sub=$(printf '%s' "${1:-}" | tr -cd 'a-z-'); shift
  args=""; skip=0
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in -m|-F|-C|-c|--message|--file|--reuse-message|--reedit-message|--template|-t) skip=1; continue ;; esac
    args="$args $a"
  done
  # shellcheck disable=SC2086
  set -- $args
  case "$sub" in
    commit) case " $* " in *" --dry-run "*) ;; *) WRITES=1 ;; esac ;;
    rebase) case " $* " in *" --continue "*) WRITES=1 ;; esac ;;
    am) case " $* " in *" --abort "*|*" --quit "*|*" --skip "*|*" --show-current-patch "*|*" --show-current-patch="*) ;; *) WRITES=1 ;; esac ;;
    *) case " $* " in *" --abort "*|*" --quit "*|*" --skip "*) ;; *) WRITES=1 ;; esac ;;
  esac
done <<EOF
$HITS
EOF
[ "$WRITES" = 1 ] || exit 0

if [ "$HAS_JQ" = 0 ]; then
  M="review-harness commit gate inactive: jq is not installed, so this git history write was not checked against the review gate. Install jq, or make sure run-state.sh check passes before committing."
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$M" "$M"
  exit 0
fi

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -d "$CWD" ] || CWD="$PWD"
OUT=$(cd "$CWD" && bash "$HERE/run-state.sh" check --active-only 2>&1); RC=$?

case "$RC" in
  1) jq -n --arg r "COMMIT BLOCKED by the review-harness review gate — $OUT If the user explicitly says to commit anyway, record that with: bash \"$HERE/run-state.sh\" override \"<reason>\" and retry. Do not bypass this gate by committing another way." \
       '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
  4) jq -n --arg r "$OUT" '{systemMessage:$r, hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}' ;;
esac
exit 0
