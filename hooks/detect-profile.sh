#!/bin/bash
# detect-profile.sh [path...]
# Prints the stack profiles that apply to a change, comma-separated (e.g. `web-frontend`), or an empty line.
# Feed the output to `extract-constraints.sh <agent> "<output>"`.
#   Paths: the arguments (relative to $PWD); with none, the current git changes (diff vs HEAD + untracked;
#   all tracked files when there is no HEAD).
#   A path that no frontend file-name rule matches (e.g. a `.ts` hook, an `api/` route) also counts by the dependencies of its NEAREST manifest
#   (package.json / pyproject.toml / requirements*.txt, walking up to the git root) — right in a monorepo,
#   and a changed manifest counts by its own dependencies. An `api/` or `routes/` path under a frontend-only
#   manifest is client code and adds no web-api, except Next.js server routes (`app/api/`, `pages/api/`);
#   `*.sql`, migrations, `*.controller.*` and `src/server/` always add it.
#   No paths at all (clean tree): the manifest at the repo root.
# Only names with an existing profiles/<name>.md are printed, so a profile starts applying when its file lands.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
FE=0; API=0; KIND=none; CACHE="|"

# classify <path> — file-name rules, then the NEAREST manifest. A frontend file name decides on its own unless
# it also matches an API name (e.g. `src/routes/Home.tsx`). API names: name_api=2 (`*.controller.*`, `*.sql`,
# migrations, `src/server/`) always adds web-api; name_api=1 (`api/`, `routes/`) adds it unless the nearest manifest
# is frontend-only (a client `src/api/` folder) — Next.js server routes (`app/api/`, `pages/api/`) still count.
classify() {
  local p="$1" name_api=0 fe_ext=0
  case "$p" in
    *.controller.*|*.sql|migrations/*|*/migrations/*|migration/*|*/migration/*|src/server/*|*/src/server/*) name_api=2 ;;
    routes/*|*/routes/*|api/*|*/api/*) name_api=1 ;;
  esac
  case "$p" in *.tsx|*.jsx|*.vue|*.svelte|*.css|*.scss|*.sass|*.less) fe_ext=1; FE=1 ;; esac
  [ "$fe_ext" = 1 ] && [ "$name_api" = 0 ] && return
  nearest_kind "$p"
  [ "$fe_ext" = 0 ] && count_kind
  [ "$name_api" = 0 ] && return
  if [ "$name_api" = 1 ] && [ "$KIND" = fe ]; then
    case "$p" in app/api/*|*/app/api/*|pages/api/*|*/pages/api/*) API=1 ;; esac
  else
    API=1
  fi
}

has_manifest() {
  local f
  [ -f "$1/package.json" ] || [ -f "$1/pyproject.toml" ] && return 0
  for f in "$1"/requirements*.txt; do [ -f "$f" ] && return 0; done
  return 1
}

# manifest_kind <dir> — KIND = dependency signals of the manifests in <dir>: fe, api, fe+api or - (neither).
# Each dir is read once (CACHE holds |dir=kind| entries; bash 3.2 has no associative arrays).
manifest_kind() {
  local d="$1" deps f fe=0 api=0
  case "$CACHE" in *"|$d="*) KIND=${CACHE#*"|$d="}; KIND=${KIND%%|*}; return ;; esac
  if [ -f "$d/package.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      deps=$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]' "$d/package.json" 2>/dev/null)
    else
      # shortcut: grep sees every "name": key, not only dependencies; jq is normally present.
      deps=$(grep -oE '"[@A-Za-z0-9/._-]+"[[:space:]]*:' "$d/package.json" | sed -E 's/^"([^"]+)".*/\1/')
    fi
    printf '%s\n' "$deps" | grep -qxE 'react|next|vue|svelte' && fe=1
    printf '%s\n' "$deps" | grep -qxE '@nestjs/core|express|fastify|koa' && api=1
  fi
  for f in "$d/pyproject.toml" "$d"/requirements*.txt; do
    [ -f "$f" ] && grep -qiwE 'fastapi|django|flask' "$f" && api=1
  done
  case "$fe$api" in 10) KIND=fe ;; 01) KIND=api ;; 11) KIND=fe+api ;; *) KIND=- ;; esac
  CACHE="$CACHE$d=$KIND|"
}

count_kind() {
  case "$KIND" in fe|fe+api) FE=1 ;; esac
  case "$KIND" in api|fe+api) API=1 ;; esac
}

# nearest_kind <path> — KIND of the nearest manifest, walking up from the path's directory to the git root;
# none when there is no manifest
nearest_kind() {
  local d
  KIND=none
  case "$1" in /*) d="$1" ;; *) d="$BASE/$1" ;; esac
  d="${d%/*}"
  while [ -n "$d" ]; do
    has_manifest "$d" && { manifest_kind "$d"; return; }
    [ "$d" = "$ROOT" ] && return
    d="${d%/*}"
  done
}

if [ $# -gt 0 ]; then
  BASE=$(pwd -P); PATHS=$(printf '%s\n' "$@")
else
  # git -C root: every listed path is relative to the repo root. quotePath=false: non-ASCII names stay unquoted.
  BASE="$ROOT"
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    PATHS=$({ git -c core.quotePath=false -C "$ROOT" diff --name-only HEAD
              git -c core.quotePath=false -C "$ROOT" ls-files --others --exclude-standard; } 2>/dev/null)
  else
    PATHS=$({ git -c core.quotePath=false -C "$ROOT" ls-files
              git -c core.quotePath=false -C "$ROOT" ls-files --others --exclude-standard; } 2>/dev/null)
  fi
fi

if [ -n "$PATHS" ]; then
  while IFS= read -r p; do classify "$p"; done <<EOF
$PATHS
EOF
else
  manifest_kind "$ROOT"; count_kind
fi

NAMES=""
[ "$FE" = 1 ] && NAMES="web-frontend"
[ "$API" = 1 ] && NAMES="$NAMES web-api"
[ "$FE" = 1 ] && [ "$API" = 1 ] && NAMES="$NAMES web-common"

OUT=""
for n in $NAMES; do
  [ -f "$PLUGIN_DIR/profiles/$n.md" ] && OUT="${OUT:+$OUT,}$n"
done
printf '%s\n' "$OUT"
