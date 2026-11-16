#!/bin/bash
# detect-test-cmd.sh [dir]
# Prints the test command for the repo at <dir> (default: $PWD), or nothing when none is found (exit 0).
# First match wins:
#   1. the registered repo's `test_cmd` (detect-repo.sh)
#   2. package.json scripts.test (not npm's "no test specified" placeholder) → pnpm/yarn/npm test by lockfile
#      (bun.lock / bun.lockb → bun run test)
#   3. vitest.config.* → npx vitest run;  jest.config.* → npx jest;  bun.lock / bun.lockb → bun test
#   4. pytest.ini, pyproject.toml / setup.cfg / tox.ini mentioning pytest, conftest.py → python -m pytest
#   5. go.mod → go test ./...    6. Cargo.toml → cargo test

D="${1:-$PWD}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exists() { [ -e "$1" ]; }   # first expansion of a glob exists

REG=$(bash "$HOOK_DIR/detect-repo.sh" "$D" 2>/dev/null | sed -n 's/^- test_cmd:[[:space:]]*//p' | head -n 1 \
  | sed -e 's/[[:space:]]*$//' -e 's/^`\(.*\)`$/\1/')
[ -n "$REG" ] && { printf '%s\n' "$REG"; exit 0; }

if [ -f "$D/package.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    T=$(jq -r '.scripts.test // empty' "$D/package.json" 2>/dev/null)
  else
    T=$(grep -E '"test"[[:space:]]*:[[:space:]]*"' "$D/package.json" | head -n 1)
  fi
  case "$T" in
    ""|*"no test specified"*) ;;
    *)
      if [ -f "$D/pnpm-lock.yaml" ]; then echo "pnpm test"
      elif [ -f "$D/bun.lock" ] || [ -f "$D/bun.lockb" ]; then echo "bun run test"   # `bun test` would skip scripts.test
      elif [ -f "$D/yarn.lock" ]; then echo "yarn test"
      else echo "npm test"; fi
      exit 0 ;;
  esac
fi

if exists "$D"/vitest.config.*; then echo "npx vitest run"; exit 0; fi
if exists "$D"/jest.config.*; then echo "npx jest"; exit 0; fi
if [ -f "$D/bun.lock" ] || [ -f "$D/bun.lockb" ]; then echo "bun test"; exit 0; fi
if [ -f "$D/pytest.ini" ] || [ -f "$D/tox.ini" ] || [ -f "$D/conftest.py" ] \
  || grep -qs pytest "$D/pyproject.toml" || grep -qsF '[tool:pytest]' "$D/setup.cfg"; then
  echo "python -m pytest"; exit 0
fi
[ -f "$D/go.mod" ] && { echo "go test ./..."; exit 0; }
[ -f "$D/Cargo.toml" ] && { echo "cargo test"; exit 0; }
exit 0
