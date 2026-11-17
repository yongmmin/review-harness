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
# `git pull` is not covered although it can create a merge commit. A dry run, abort, `--show-current-patch` or plain
# rebase passes only when the git command after the subcommand holds nothing but plain word characters and
# redirects: a quote, backtick, `\`, `$`, `#`, glob, brace or `( )` in it (`-m "a b" --dry-run`, `rebase "$B"`,
# `rebase @{u}`) counts as a write (fails closed), and so does a quoted mention like `echo "git rebase main"`. The value of an option that takes one (also
# by a unique prefix like `--mess`), anything after `--` or `--end-of-options`, and a negated `--no-<opt>` never count as a dry-run or abort.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)
HAS_JQ=1; command -v jq >/dev/null 2>&1 || HAS_JQ=0
# Without jq the raw JSON is matched: good enough to tell whether to warn.
if [ "$HAS_JQ" = 1 ]; then CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null); else CMD=$INPUT; fi

Q="'"; SEP="[;&|)\`$Q\"]"
GIT="(^|[^[:alnum:]_./-])([^[:space:];&|()\`$Q\"]*/)?git"
# Global options before the subcommand; the ones that take a separate value consume it (quoted or not).
OPT="([[:space:]]+(-[Cc]|--(git-dir|work-tree|namespace|config-env))[[:space:]]+(\"[^\"]*\"|$Q[^$Q]*$Q|[^[:space:]]+)|[[:space:]]+-[^[:space:]]+)*"
# Redirects (`2>&1`, `&>`, `>|`) stay inside the hit: arguments may follow them.
SUB="[[:space:]]+(commit|merge|cherry-pick|revert|am|rebase)(([[:space:]]|[<>]&|&>|>[|]|[<>])([^;&|)\`$Q\"]|[<>]&|&>|>[|])*|$SEP|\$)"
# A leading space gives every hit its boundary character, so a hit's text cannot also occur earlier unmatched.
CMD=$(printf '%s\n' "$CMD" | sed 's/^/ /')
HITS=$(printf '%s\n' "$CMD" | grep -oE "$GIT$OPT$SUB") || exit 0

set -f   # word-split the hit below without glob expansion
# given <opt...>: one of these options is in $args and none of them is negated. git accepts `--no-<opt>` and
# any unique prefix of it, and the last one wins, so any negation counts as a write (fails closed).
given() {
  local m a hit=1
  for m in "$@"; do
    case " $args " in *" $m "*) hit=0 ;; esac
    for a in $args; do case "$a" in --no-?*) case "--no-${m#--}" in "$a"*) return 1 ;; esac ;; esac; done
  done
  return $hit
}
WRITES=0; REST=$CMD; NL='
'
UNSAFE='*[!A-Za-z0-9_./=:,@^~%+<>&|[:space:]-]*'   # any character outside plain words and redirects
while IFS= read -r hit; do
  # Hits come in order and never overlap: consume the command up to this one to see what follows it.
  REST=${REST#*"$hit"}; next=${REST:0:1}
  tail=$(printf '%s\n' "$hit" | sed -E "s#^$GIT$OPT[[:space:]]+##")
  # `git rebase;` — the hit took the separator itself; a space may follow, a word may not (`git rebase;git commit`).
  case "$tail" in *[[:space:]]*) ;; *[\;\&\|\)]) tail=${tail%?}; [ "$next" = " " ] && next="" ;; esac
  # A dry run or abort passes only when the whole git command was read literally: it must end at a command
  # separator, and contain only plain word characters and redirects. Anything else (quotes, `\`, `$`, `#`,
  # globs, braces, `( )`) can hide or add words: `-m "x" --no-dry-run`, `"--continue"`, `$X`, `# --dry-run`.
  case "$next" in ""|";"|"&"|"|"|")"|"$NL") ;; *) WRITES=1; continue ;; esac
  case "$tail" in $UNSAFE) WRITES=1; continue ;; esac
  # Drop redirects with their target: `> --dry-run` names a file, not an option.
  # A digit is an fd number only as a whole word before `<`/`>` (`-m5>x` passes `-m5`); `&>` takes none.
  tail=$(printf '%s\n' "$tail" | sed -E 's/(((^|[[:space:]])[0-9]+)?[<>]+[&|]?|&>>?)[[:space:]]*[^[:space:]<>&]*/ /g')
  # shellcheck disable=SC2086
  set -- $tail
  sub=$(printf '%s' "${1:-}" | tr -cd 'a-z-'); shift
  # Options that take a separate value, per subcommand (`git <sub> -h`, git 2.54): VS short letters, VL long names.
  case "$sub" in
    commit) VS=FmcCtU; VL="--file --author --date --message --reedit-message --reuse-message --squash --fixup --trailer --template --cleanup --unified --inter-hunk-context --pathspec-from-file" ;;
    merge) VS=smXF; VL="--cleanup --strategy --strategy-option --message --file --into-name" ;;
    am) VS=Cp; VL="--quoted-cr --whitespace --directory --exclude --include --patch-format --resolvemsg" ;;
    rebase) VS=CxsX; VL="--onto --trailer --whitespace --exec --strategy --strategy-option" ;;
    *) VS=mX; VL="--cleanup --mainline --strategy --strategy-option" ;;   # cherry-pick, revert
  esac
  args=""; skip=0
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in --|--end-of-options) break ;; esac   # pathspecs and revisions follow, never options
    case "$a" in
      --show-current-patch=*) a=--show-current-patch ;;
      --*=*) ;;
      # The value of an option that takes one is data (`--trailer --dry-run`); git also takes a unique prefix (`--mess`).
      --?*) for v in $VL; do case "$v" in "$a"*) skip=1 ;; esac; done; [ "$skip" = 1 ] && continue ;;
      # Bundled short options (`-am`): the first value letter takes the rest of the word, or the next word if last.
      -?*) pre=${a%%["$VS"]*}; if [ "${#pre}" -eq $(( ${#a} - 1 )) ]; then skip=1; continue; fi ;;
    esac
    args="$args $a"
  done
  case "$sub" in
    commit) given --dry-run || WRITES=1 ;;
    # git takes a unique prefix (`--cont`) for `--continue`.
    rebase) for a in $args; do case "$a" in --c?*) case --continue in "$a"*) WRITES=1 ;; esac ;; esac; done ;;
    am) given --abort --quit --skip --show-current-patch || WRITES=1 ;;
    *) given --abort --quit --skip || WRITES=1 ;;
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
