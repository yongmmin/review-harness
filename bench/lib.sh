#!/bin/bash
# bench/lib.sh — sourced by bench/cases/*/setup.sh and bench/cases-dev/*/setup.sh.
# A fixture is a throwaway git repo: the "before" files form the base commit, the "after" files are left as an
# uncommitted change. The base is recorded with commit-tree + update-ref (never `git commit`), with a fixed
# identity and date so every fixture has the same base id on every machine. Nothing in the git metadata names the
# benchmark or the case: the reviewer must not learn the answer from the fixture.

# bench_init <dir> — new git repo at <dir> on branch main; refuses a non-empty <dir>
bench_init() {
  [ -n "${1:-}" ] || { echo "usage: setup.sh <dir>" >&2; exit 2; }
  if [ -n "$(ls -A "$1" 2>/dev/null)" ]; then
    echo "setup: $1 exists and is not empty" >&2; exit 2
  fi
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" symbolic-ref HEAD refs/heads/main
}

# bench_base <dir> — record every file now in <dir> as the base commit
bench_base() {
  local tree commit
  git -C "$1" add -A
  tree=$(git -C "$1" write-tree)
  commit=$(GIT_AUTHOR_NAME='Sam Lee' GIT_AUTHOR_EMAIL=sam.lee@example.com GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' \
    GIT_COMMITTER_NAME='Sam Lee' GIT_COMMITTER_EMAIL=sam.lee@example.com GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
    git -C "$1" commit-tree "$tree" -m 'Initial commit')
  git -C "$1" update-ref -m 'initial import' refs/heads/main "$commit"
}

# bench_nest <dir> — NestJS + Prisma skeleton shared by the API fixtures: manifest, Prisma service, auth guard and
# @CurrentUser() decorator. The case writes prisma/schema.prisma and its modules.
bench_nest() {
  mkdir -p "$1/src/prisma" "$1/src/auth" "$1/prisma"
  cat > "$1/package.json" <<'EOF'
{
  "name": "api",
  "private": true,
  "scripts": { "build": "nest build", "start": "nest start", "test": "jest" },
  "dependencies": {
    "@nestjs/common": "10.3.10",
    "@nestjs/core": "10.3.10",
    "@nestjs/passport": "10.0.3",
    "@prisma/client": "5.17.0",
    "class-transformer": "0.5.1",
    "class-validator": "0.14.1",
    "passport": "0.7.0",
    "passport-jwt": "4.0.1",
    "reflect-metadata": "0.2.2",
    "rxjs": "7.8.1"
  },
  "devDependencies": { "@nestjs/cli": "10.4.2", "jest": "29.7.0", "prisma": "5.17.0", "typescript": "5.5.4" }
}
EOF
  cat > "$1/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "module": "commonjs",
    "target": "ES2021",
    "strict": true,
    "emitDecoratorMetadata": true,
    "experimentalDecorators": true,
    "outDir": "./dist"
  }
}
EOF
  cat > "$1/src/prisma/prisma.service.ts" <<'EOF'
import { Injectable, OnModuleInit } from '@nestjs/common'
import { PrismaClient } from '@prisma/client'

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit {
  async onModuleInit(): Promise<void> {
    await this.$connect()
  }
}
EOF
  cat > "$1/src/auth/jwt-auth.guard.ts" <<'EOF'
import { Injectable } from '@nestjs/common'
import { AuthGuard } from '@nestjs/passport'

@Injectable()
export class JwtAuthGuard extends AuthGuard('jwt') {}
EOF
  cat > "$1/src/auth/current-user.decorator.ts" <<'EOF'
import { createParamDecorator, ExecutionContext } from '@nestjs/common'

export interface AuthUser {
  id: number
  email: string
  role: 'USER' | 'ADMIN'
}

export const CurrentUser = createParamDecorator((_: unknown, ctx: ExecutionContext): AuthUser => {
  return ctx.switchToHttp().getRequest<{ user: AuthUser }>().user
})
EOF
}

# bench_next <dir> — Next.js + Vitest skeleton shared by the plan-based frontend fixtures: manifest, tsconfig
# (`@/*` → `src/*`), vitest config and the axios wrapper. The case writes its own src/ files.
bench_next() {
  mkdir -p "$1/src/lib"
  cat > "$1/package.json" <<'EOF'
{
  "name": "web",
  "private": true,
  "scripts": { "dev": "next dev", "build": "next build", "test": "vitest run" },
  "dependencies": {
    "@tanstack/react-query": "5.51.1",
    "axios": "1.7.2",
    "next": "14.2.5",
    "react": "18.3.1",
    "react-dom": "18.3.1",
    "zustand": "4.5.4"
  },
  "devDependencies": {
    "@testing-library/react": "16.0.0",
    "@types/react": "18.3.3",
    "@vitejs/plugin-react": "4.3.1",
    "jsdom": "24.1.1",
    "typescript": "5.5.4",
    "vitest": "2.0.5"
  }
}
EOF
  cat > "$1/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "strict": true,
    "jsx": "preserve",
    "module": "esnext",
    "moduleResolution": "bundler",
    "baseUrl": ".",
    "paths": { "@/*": ["./src/*"] }
  }
}
EOF
  cat > "$1/vitest.config.ts" <<'EOF'
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  plugins: [react()],
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  test: { environment: 'jsdom' },
})
EOF
  cat > "$1/src/lib/http.ts" <<'EOF'
import axios from 'axios'

export const http = axios.create({
  baseURL: process.env.NEXT_PUBLIC_API_URL,
  withCredentials: true,
})
EOF
}

# bench_done <dir> — mark files added by the change as intent-to-add, so `git diff` shows them
bench_done() {
  git -C "$1" add -N -A
}

# bench_node <dir> — zero-dependency Node 20 HTTP skeleton (CommonJS, `node --test`) for the developer-side cases:
# route table with a per-route query allowlist, JSON errors `{error, message}`, and test helpers. The case writes
# src/app.js, its routes and its tests, then calls bench_base with no uncommitted change.
bench_node() {
  mkdir -p "$1/src/http" "$1/test"
  cat > "$1/package.json" <<'EOF'
{
  "name": "shop",
  "private": true,
  "scripts": { "test": "node --test" }
}
EOF
  cat > "$1/src/http/errors.js" <<'EOF'
'use strict'

class HttpError extends Error {
  constructor(status, code, message) {
    super(message)
    this.status = status
    this.code = code
  }
}

module.exports = { HttpError }
EOF
  cat > "$1/src/http/query.js" <<'EOF'
'use strict'
const { HttpError } = require('./errors')

// Rejects any query parameter the route does not list.
function checkQuery(allowed, searchParams) {
  for (const key of searchParams.keys()) {
    if (!allowed.includes(key)) {
      throw new HttpError(400, 'invalid_query', `unknown query parameter: ${key}`)
    }
  }
}

module.exports = { checkQuery }
EOF
  cat > "$1/src/http/server.js" <<'EOF'
'use strict'
const http = require('node:http')
const { HttpError } = require('./errors')
const { checkQuery } = require('./query')

function matchPath(pattern, pathname) {
  const want = pattern.split('/').filter(Boolean)
  const got = pathname.split('/').filter(Boolean)
  if (want.length !== got.length) return null
  const params = {}
  for (let i = 0; i < want.length; i++) {
    if (want[i].startsWith(':')) params[want[i].slice(1)] = decodeURIComponent(got[i])
    else if (want[i] !== got[i]) return null
  }
  return params
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = ''
    req.on('data', (chunk) => { data += chunk })
    req.on('error', reject)
    req.on('end', () => {
      if (!data) return resolve(undefined)
      try {
        resolve(JSON.parse(data))
      } catch {
        reject(new HttpError(400, 'invalid_body', 'body must be JSON'))
      }
    })
  })
}

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(JSON.stringify(body))
}

// routes: [{ method, path ('/orders/:id'), query: [allowed keys], handler(ctx) → { status, body } }]
function createServer(routes) {
  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost')
      for (const route of routes) {
        if (route.method !== req.method) continue
        const params = matchPath(route.path, url.pathname)
        if (!params) continue
        checkQuery(route.query || [], url.searchParams)
        const body = await readBody(req)
        const result = await route.handler({ params, query: Object.fromEntries(url.searchParams), body })
        return send(res, result.status, result.body)
      }
      throw new HttpError(404, 'not_found', `no route for ${req.method} ${url.pathname}`)
    } catch (err) {
      if (err instanceof HttpError) return send(res, err.status, { error: err.code, message: err.message })
      send(res, 500, { error: 'internal', message: 'internal error' })
    }
  })
}

module.exports = { createServer, HttpError }
EOF
  cat > "$1/test/helpers.js" <<'EOF'
'use strict'

function start(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      resolve({
        url: `http://127.0.0.1:${port}`,
        close: () => new Promise((done) => {
          server.closeAllConnections()
          server.close(done)
        }),
      })
    })
  })
}

async function getJson(url) {
  const res = await fetch(url)
  return { status: res.status, body: await res.json() }
}

module.exports = { start, getJson }
EOF
}
