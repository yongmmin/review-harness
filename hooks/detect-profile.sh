#!/bin/bash
# detect-profile.sh [path...]
# Prints the stack profiles that apply to a change, comma-separated (e.g. `web-frontend`), or an empty line.
# Feed the output to `extract-constraints.sh <agent> "<output>"`.
#   Paths: the arguments (relative to $PWD); with none, the current git changes (diff vs HEAD + untracked;
#   all tracked files when there is no HEAD).
#   A path that no frontend file-name rule matches (e.g. a `.ts` hook, an `api/` route) also counts by the dependencies of its NEAREST manifest
#   (package.json / pyproject.toml / requirements*.txt, walking up to the git root) — right in a monorepo,
#   and a changed manifest counts by its own dependencies.
#   No paths at all (clean tree): the manifest at the repo root.
# Only names with an existing profiles/<name>.md are printed, so a profile starts applying when its file lands.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
FE=0; API=0; SEEN="|"

# classify <path> — file-name rules; returns 1 unless a frontend rule matched. An API-name match (e.g. a
# Next.js `app/api/` route) still goes on to the manifest, so a React package keeps its frontend rules.
classify() {
  case "$1" in
    *.controller.*|*.sql|routes/*|*/routes/*|api/*|*/api/*|migrations/*|*/migrations/*|migration/*|*/migration/*) API=1 ;;
  esac
  case "$1" in *.tsx|*.jsx|*.vue|*.svelte|*.css|*.scss|*.sass|*.less) FE=1; return 0 ;; esac
  return 1
}

has_manifest() {
  local f
  [ -f "$1/package.json" ] || [ -f "$1/pyproject.toml" ] && return 0
  for f in "$1"/requirements*.txt; do [ -f "$f" ] && return 0; done
  return 1
}

# manifest_signals <dir> — dependency signals of the manifests in <dir>; each dir is read once
manifest_signals() {
  local d="$1" deps f
  case "$SEEN" in *"|$d|"*) return ;; esac
  SEEN="$SEEN$d|"
  if [ -f "$d/package.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      deps=$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]' "$d/package.json" 2>/dev/null)
    else
      # shortcut: grep sees every "name": key, not only dependencies; jq is normally present.
      deps=$(grep -oE '"[@A-Za-z0-9/._-]+"[[:space:]]*:' "$d/package.json" | sed -E 's/^"([^"]+)".*/\1/')
    fi
    printf '%s\n' "$deps" | grep -qxE 'react|next|vue|svelte' && FE=1
    printf '%s\n' "$deps" | grep -qxE '@nestjs/core|express|fastify|koa' && API=1
  fi
  for f in "$d/pyproject.toml" "$d"/requirements*.txt; do
    [ -f "$f" ] && grep -qiwE 'fastapi|django|flask' "$f" && API=1
  done
}

# nearest_manifest <path> — walk up from the path's directory, stopping at the git root
nearest_manifest() {
  local d
  case "$1" in /*) d="$1" ;; *) d="$BASE/$1" ;; esac
  d="${d%/*}"
  while [ -n "$d" ]; do
    has_manifest "$d" && { manifest_signals "$d"; return; }
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
  while IFS= read -r p; do classify "$p" || nearest_manifest "$p"; done <<EOF
$PATHS
EOF
else
  manifest_signals "$ROOT"
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
