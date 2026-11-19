# Sourced by static-gates.sh, risk-tier.sh and review-context.sh. The caller sets ME (its name) and usage(), then runs
# `collect_change [base]`, which collects the current change:
#   With base: everything since the merge base of <base> and HEAD (commits, staged, unstaged) plus untracked files.
#   Without: staged, unstaged and untracked against HEAD; with no HEAD, every tracked or untracked file is added.
# Afterwards: cwd is the repo root, FROM is the diff base, GIT_INDEX_FILE is a temporary copy of the index ($IDX) with
# untracked files added intent-to-add (the real index is never written), `g` runs git with unquoted paths, and
# `gitfail <cmd>` exits 2. $IDX and $IDX.{lock,names,diff,err} are removed on exit.

# git's stderr is kept in $IDX.err and shown only on failure (add -N with nothing untracked is chatty).
gitfail() { cat "$IDX.err" >&2 2>/dev/null; echo "$ME: git $1 failed (see the git error above)" >&2; exit 2; }
g() { git -c core.quotePath=false "$@"; }

collect_change() {
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "$ME: not a git repository" >&2; exit 2; }
  cd "$ROOT" || exit 2
  if [ -n "${1:-}" ]; then
    FROM=$(git merge-base "$1" HEAD 2>/dev/null) || usage "no merge base with HEAD: $1"
  elif git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    FROM=HEAD
  else
    FROM=$(git hash-object -t tree /dev/null)   # the empty tree: every tracked file is added
  fi
  # One diff covers untracked files too: they are added intent-to-add in a copy of the index.
  IDX=$(mktemp "${TMPDIR:-/tmp}/$ME.XXXXXX") || exit 2
  trap 'rm -f "$IDX" "$IDX.lock" "$IDX.names" "$IDX.diff" "$IDX.err"' EXIT
  local real_idx; real_idx=$(git rev-parse --git-path index)
  # touch -r keeps the index mtime, which git's racy-entry check compares with each entry (a same-second, same-size
  # edit); cp onto the mktemp file keeps its 0600 mode (cp -p would copy the real index's mode). An empty file is not
  # a valid index.
  if [ -f "$real_idx" ]; then cp "$real_idx" "$IDX" && touch -r "$real_idx" "$IDX"; else rm -f "$IDX"; fi
  export GIT_INDEX_FILE="$IDX"
  # git ≥ 2.34 refuses an untracked path outside a sparse-checkout cone unless --sparse is given (older git has
  # neither the check nor the option). Option names in `-h` are never translated.
  local sparse=(); git add -h 2>&1 | grep -qE -- '--(\[no-\])?sparse' && sparse=(--sparse)
  # entries ending in `/` are nested repos or worktrees
  g ls-files -z --others --exclude-standard | while IFS= read -r -d '' f; do
    case "$f" in */) ;; *) printf '%s\0' "$f" ;; esac
  done | git --literal-pathspecs add -N ${sparse[@]+"${sparse[@]}"} --pathspec-from-file=- --pathspec-file-nul 2> "$IDX.err" \
    || gitfail "add -N"
}
