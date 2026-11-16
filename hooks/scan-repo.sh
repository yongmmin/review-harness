#!/bin/bash
# scan-repo.sh [dir]
# Prints a proposed repos.md registry block for the repo containing <dir> (default: $PWD). Reads files only,
# never writes; same files in → same block out. Used by the register-repo skill.
#   ### <repo root basename>
#   - **local_path**: `<repo root>`   (git root as reached from <dir>, symlinks kept, so it matches detect-repo.sh)
#   - **role**: TODO
#   - **stack**:      package.json deps (with major version), python packages, go version, rust
#   - **layout**:     `src/` or `app/`
#   - **path_alias**: tsconfig.json compilerOptions.paths (needs jq)
#   - **test_cmd**:   detect-test-cmd.sh
#   - **check_cmd**:  `ruff check .` (ruff config) or `go vet ./...` (go.mod); none for TS (post-tool-use runs tsc/eslint)
#   - **special**:    workspaces: <patterns> (package.json workspaces / pnpm-workspace.yaml)
# Lines with nothing found are left out.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="${1:-$PWD}"
[ -d "$D" ] || { echo "scan-repo: not a directory: $D" >&2; exit 1; }
R=$(cd "$D/$(git -C "$D" rev-parse --show-cdup 2>/dev/null)" && pwd) || exit 1
HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
join() { paste -sd, - | sed 's/,/, /g'; }

STACK=""
add() { STACK="${STACK:+$STACK, }$1"; }

if [ -f "$R/package.json" ]; then
  if [ "$HAS_JQ" = 1 ]; then
    DEPS=$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | to_entries[] | "\(.key) \(.value)"' "$R/package.json" 2>/dev/null)
  else
    # shortcut: grep sees every "name": "value" pair, not only dependencies; jq is normally present.
    DEPS=$(grep -oE '"[@A-Za-z0-9/._-]+"[[:space:]]*:[[:space:]]*"[^"]*"' "$R/package.json" | sed -E 's/^"([^"]+)"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1 \2/')
  fi
  for n in next react vue svelte @nestjs/core express fastify typescript tailwindcss zustand @tanstack/react-query prisma; do
    v=$(printf '%s\n' "$DEPS" | awk -v n="$n" '$1 == n { print $2; exit }')
    [ -z "$v" ] && continue
    major=$(printf '%s' "$v" | sed -nE 's/^[^0-9]*([0-9]+).*/\1/p')
    add "$n${major:+ $major}"
  done
fi

PYF=()
for f in "$R/pyproject.toml" "$R"/requirements*.txt; do [ -f "$f" ] && PYF+=("$f"); done
if [ ${#PYF[@]} -gt 0 ]; then
  add python
  for n in fastapi django flask sqlalchemy pydantic; do
    grep -qiw "$n" "${PYF[@]}" && add "$n"
  done
fi
if [ -f "$R/go.mod" ]; then
  gv=$(sed -n 's/^go[[:space:]][[:space:]]*\([0-9.]*\).*/\1/p' "$R/go.mod" | head -n 1)
  add "go${gv:+ $gv}"
fi
[ -f "$R/Cargo.toml" ] && add rust

LAYOUT=""
if [ -d "$R/src" ]; then LAYOUT="src/"; elif [ -d "$R/app" ]; then LAYOUT="app/"; fi

ALIAS=""
if [ "$HAS_JQ" = 1 ] && [ -f "$R/tsconfig.json" ]; then
  # Whole-line // comments are common in tsconfig.json and break jq; anything more exotic just skips the line.
  ALIAS=$(sed 's#^[[:space:]]*//.*##' "$R/tsconfig.json" \
    | jq -r 'def clean: tostring | gsub("[\n\r`]"; "");
        .compilerOptions.paths // {} | to_entries
        | map(select((.value | type) == "array" and (.value | length) > 0 and .value[0] != null)
              | "`\(.key | clean)` → `\(.value[0] | clean)`") | join(", ")' 2>/dev/null)
fi

TEST=$(bash "$HOOK_DIR/detect-test-cmd.sh" "$R" 2>/dev/null)

CHECK=""
if [ -f "$R/ruff.toml" ] || [ -f "$R/.ruff.toml" ] || grep -qs '^\[tool\.ruff' "$R/pyproject.toml"; then
  CHECK="ruff check ."
elif [ -f "$R/go.mod" ]; then
  CHECK="go vet ./..."
fi

WS=""
if [ -f "$R/pnpm-workspace.yaml" ]; then
  # shortcut: block-style `packages:` list only; an inline [a, b] list is not read.
  WS=$(awk '/^packages:/ { f = 1; next } f && /^[^[:space:]-]/ { f = 0 }
    f && /^[[:space:]]*-/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); gsub(/["\047]/, ""); print }' \
    "$R/pnpm-workspace.yaml" | join)
elif [ "$HAS_JQ" = 1 ] && [ -f "$R/package.json" ]; then
  WS=$(jq -r '.workspaces | if type == "array" then .[] elif type == "object" then (.packages // [])[] else empty end' \
    "$R/package.json" 2>/dev/null | join)
fi

# Every value is file-derived: newlines/CRs become spaces so no value can start a new registry line or block.
one() { printf '%s' "$1" | tr '\n\r' '  '; }
line() { [ -n "$2" ] && printf -- '- **%s**: %s\n' "$1" "$(one "$2")"; }
printf '### %s\n' "$(one "$(basename "$R")")"
# A backtick would end the `…` span detect-repo.sh reads, so it is stripped. The stripped path is not the
# repo root, so detect-repo.sh does not match the repo (register-repo's verify step then stops).
line local_path "\`$(printf '%s' "$R" | tr -d '`')\`"
line role TODO
line stack "$STACK"
line layout "${LAYOUT:+\`$LAYOUT\`}"
line path_alias "$ALIAS"
line test_cmd "${TEST:+\`$TEST\`}"
line check_cmd "${CHECK:+\`$CHECK\`}"
line special "${WS:+workspaces: $WS}"
exit 0
