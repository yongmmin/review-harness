#!/bin/bash
# bench/lib.sh — sourced by bench/cases/*/setup.sh.
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
