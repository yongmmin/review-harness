#!/bin/bash
# Monorepo (apps/api NestJS + apps/web Next.js): the user response shows a nickname when one is set.
set -eu
. "$(cd "$(dirname "$0")/../.." && pwd)/lib.sh"
D="${1:-}"; bench_init "$D"; cd "$D"
bench_nest apps/api
mkdir -p apps/api/src/users apps/api/src/comments apps/web/src/components apps/web/src/types apps/web/src/lib

# --- before ---------------------------------------------------------------------------
cat > package.json <<'EOF'
{
  "name": "monorepo",
  "private": true,
  "workspaces": ["apps/*"]
}
EOF
cat > apps/web/package.json <<'EOF'
{
  "name": "web",
  "private": true,
  "scripts": { "dev": "next dev", "build": "next build" },
  "dependencies": { "axios": "1.7.2", "next": "14.2.5", "react": "18.3.1", "react-dom": "18.3.1" },
  "devDependencies": { "@types/react": "18.3.3", "typescript": "5.5.4" }
}
EOF
cat > apps/web/tsconfig.json <<'EOF'
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
cat > apps/api/prisma/schema.prisma <<'EOF'
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

generator client {
  provider = "prisma-client-js"
}

model User {
  id        Int       @id @default(autoincrement())
  email     String    @unique
  firstName String
  lastName  String
  nickname  String?
  avatarUrl String?
  comments  Comment[]
}

model Comment {
  id        Int      @id @default(autoincrement())
  postId    Int
  authorId  Int
  author    User     @relation(fields: [authorId], references: [id])
  body      String
  createdAt DateTime @default(now())

  @@index([postId, createdAt])
}
EOF
cat > apps/api/src/users/user-response.dto.ts <<'EOF'
export class UserResponseDto {
  id!: number
  fullName!: string
  avatarUrl!: string | null
}
EOF
cat > apps/api/src/users/users.service.ts <<'EOF'
import { Injectable, NotFoundException } from '@nestjs/common'
import { User } from '@prisma/client'
import { PrismaService } from '../prisma/prisma.service'
import { UserResponseDto } from './user-response.dto'

@Injectable()
export class UsersService {
  constructor(private readonly prisma: PrismaService) {}

  async getProfile(id: number): Promise<UserResponseDto> {
    const user = await this.prisma.user.findUnique({ where: { id } })
    if (!user) {
      throw new NotFoundException('User not found')
    }
    return this.toResponse(user)
  }

  toResponse(user: User): UserResponseDto {
    return {
      id: user.id,
      fullName: `${user.firstName} ${user.lastName}`,
      avatarUrl: user.avatarUrl,
    }
  }
}
EOF
cat > apps/api/src/users/users.controller.ts <<'EOF'
import { Controller, Get, UseGuards } from '@nestjs/common'
import { AuthUser, CurrentUser } from '../auth/current-user.decorator'
import { JwtAuthGuard } from '../auth/jwt-auth.guard'
import { UserResponseDto } from './user-response.dto'
import { UsersService } from './users.service'

@Controller('users')
@UseGuards(JwtAuthGuard)
export class UsersController {
  constructor(private readonly users: UsersService) {}

  @Get('me')
  me(@CurrentUser() user: AuthUser): Promise<UserResponseDto> {
    return this.users.getProfile(user.id)
  }
}
EOF
cat > apps/api/src/comments/comment-response.dto.ts <<'EOF'
import { UserResponseDto } from '../users/user-response.dto'

export class CommentResponseDto {
  id!: number
  body!: string
  createdAt!: Date
  author!: UserResponseDto
}
EOF
cat > apps/api/src/comments/comments.service.ts <<'EOF'
import { Injectable } from '@nestjs/common'
import { PrismaService } from '../prisma/prisma.service'
import { UsersService } from '../users/users.service'
import { CommentResponseDto } from './comment-response.dto'

const COMMENTS_PAGE_SIZE = 50

@Injectable()
export class CommentsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly users: UsersService,
  ) {}

  async listForPost(postId: number): Promise<CommentResponseDto[]> {
    const comments = await this.prisma.comment.findMany({
      where: { postId },
      include: { author: true },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
      take: COMMENTS_PAGE_SIZE,
    })
    return comments.map((comment) => ({
      id: comment.id,
      body: comment.body,
      createdAt: comment.createdAt,
      author: this.users.toResponse(comment.author),
    }))
  }
}
EOF
cat > apps/web/src/lib/http.ts <<'EOF'
import axios from 'axios'

export const http = axios.create({
  baseURL: process.env.NEXT_PUBLIC_API_URL,
  withCredentials: true,
})
EOF
cat > apps/web/src/types/user.ts <<'EOF'
export interface User {
  id: number
  fullName: string
  avatarUrl: string | null
}
EOF
cat > apps/web/src/types/comment.ts <<'EOF'
export interface CommentAuthor {
  id: number
  fullName: string
  avatarUrl: string | null
}

export interface Comment {
  id: number
  body: string
  createdAt: string
  author: CommentAuthor
}
EOF
cat > apps/web/src/components/ProfileHeader.tsx <<'EOF'
'use client'

import type { User } from '@/types/user'

interface ProfileHeaderProps {
  user: User
}

export function ProfileHeader({ user }: ProfileHeaderProps) {
  return (
    <header className="flex items-center gap-3">
      {user.avatarUrl && <img src={user.avatarUrl} alt="" className="h-10 w-10 rounded-full" />}
      <h1 className="text-lg font-semibold">{user.fullName}</h1>
    </header>
  )
}
EOF
cat > apps/web/src/components/CommentItem.tsx <<'EOF'
'use client'

import type { Comment } from '@/types/comment'

interface CommentItemProps {
  comment: Comment
}

export function CommentItem({ comment }: CommentItemProps) {
  return (
    <li className="py-2">
      <p className="text-sm font-medium">{comment.author.fullName}</p>
      <p className="text-sm">{comment.body}</p>
      <time dateTime={comment.createdAt} className="text-xs text-gray-500">
        {new Date(comment.createdAt).toLocaleString()}
      </time>
    </li>
  )
}
EOF
bench_base .

# --- after ----------------------------------------------------------------------------
cat > apps/api/src/users/user-response.dto.ts <<'EOF'
export class UserResponseDto {
  id!: number
  displayName!: string
  avatarUrl!: string | null
}
EOF
cat > apps/api/src/users/users.service.ts <<'EOF'
import { Injectable, NotFoundException } from '@nestjs/common'
import { User } from '@prisma/client'
import { PrismaService } from '../prisma/prisma.service'
import { UserResponseDto } from './user-response.dto'

@Injectable()
export class UsersService {
  constructor(private readonly prisma: PrismaService) {}

  async getProfile(id: number): Promise<UserResponseDto> {
    const user = await this.prisma.user.findUnique({ where: { id } })
    if (!user) {
      throw new NotFoundException('User not found')
    }
    return this.toResponse(user)
  }

  toResponse(user: User): UserResponseDto {
    return {
      id: user.id,
      displayName: user.nickname?.trim() || `${user.firstName} ${user.lastName}`,
      avatarUrl: user.avatarUrl,
    }
  }
}
EOF
cat > apps/web/src/types/user.ts <<'EOF'
export interface User {
  id: number
  displayName: string
  avatarUrl: string | null
}
EOF
cat > apps/web/src/lib/initials.ts <<'EOF'
const MAX_INITIALS = 2

export function initials(name: string): string {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, MAX_INITIALS)
    .map((part) => part[0].toUpperCase())
    .join('')
}
EOF
cat > apps/web/src/components/ProfileHeader.tsx <<'EOF'
'use client'

import { initials } from '@/lib/initials'
import type { User } from '@/types/user'

interface ProfileHeaderProps {
  user: User
}

export function ProfileHeader({ user }: ProfileHeaderProps) {
  return (
    <header className="flex items-center gap-3">
      {user.avatarUrl ? (
        <img src={user.avatarUrl} alt="" className="h-10 w-10 rounded-full" />
      ) : (
        <span aria-hidden="true" className="flex h-10 w-10 items-center justify-center rounded-full bg-gray-200">
          {initials(user.displayName)}
        </span>
      )}
      <h1 className="text-lg font-semibold">{user.displayName}</h1>
    </header>
  )
}
EOF
bench_done .
