#!/bin/bash
# NestJS + Prisma: notes gain GET /notes/:id and PATCH /notes/:id.
set -eu
. "$(cd "$(dirname "$0")/../.." && pwd)/lib.sh"
D="${1:-}"; bench_init "$D"; cd "$D"
bench_nest .
mkdir -p src/notes

# --- before ---------------------------------------------------------------------------
cat > prisma/schema.prisma <<'EOF'
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

generator client {
  provider = "prisma-client-js"
}

model Note {
  id        Int      @id @default(autoincrement())
  ownerId   Int
  title     String
  body      String
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@index([ownerId, updatedAt])
}
EOF
cat > src/notes/create-note.dto.ts <<'EOF'
import { IsString, MaxLength } from 'class-validator'

export class CreateNoteDto {
  @IsString()
  @MaxLength(200)
  title!: string

  @IsString()
  @MaxLength(20000)
  body!: string
}
EOF
cat > src/notes/note-response.dto.ts <<'EOF'
export class NoteResponseDto {
  id!: number
  title!: string
  body!: string
  updatedAt!: Date
}
EOF
cat > src/notes/notes.module.ts <<'EOF'
import { Module } from '@nestjs/common'
import { PrismaService } from '../prisma/prisma.service'
import { NotesController } from './notes.controller'
import { NotesService } from './notes.service'

@Module({
  controllers: [NotesController],
  providers: [NotesService, PrismaService],
})
export class NotesModule {}
EOF
cat > src/notes/notes.controller.ts <<'EOF'
import { Body, Controller, Get, Post, UseGuards } from '@nestjs/common'
import { AuthUser, CurrentUser } from '../auth/current-user.decorator'
import { JwtAuthGuard } from '../auth/jwt-auth.guard'
import { CreateNoteDto } from './create-note.dto'
import { NoteResponseDto } from './note-response.dto'
import { NotesService } from './notes.service'

@Controller('notes')
@UseGuards(JwtAuthGuard)
export class NotesController {
  constructor(private readonly notes: NotesService) {}

  @Get()
  list(@CurrentUser() user: AuthUser): Promise<NoteResponseDto[]> {
    return this.notes.listForOwner(user.id)
  }

  @Post()
  create(@CurrentUser() user: AuthUser, @Body() dto: CreateNoteDto): Promise<NoteResponseDto> {
    return this.notes.create(user.id, dto)
  }
}
EOF
cat > src/notes/notes.service.ts <<'EOF'
import { Injectable } from '@nestjs/common'
import { Note } from '@prisma/client'
import { PrismaService } from '../prisma/prisma.service'
import { CreateNoteDto } from './create-note.dto'
import { NoteResponseDto } from './note-response.dto'

@Injectable()
export class NotesService {
  constructor(private readonly prisma: PrismaService) {}

  async listForOwner(ownerId: number): Promise<NoteResponseDto[]> {
    const notes = await this.prisma.note.findMany({
      where: { ownerId },
      orderBy: [{ updatedAt: 'desc' }, { id: 'desc' }],
    })
    return notes.map((note) => this.toResponse(note))
  }

  async create(ownerId: number, dto: CreateNoteDto): Promise<NoteResponseDto> {
    const note = await this.prisma.note.create({ data: { ownerId, title: dto.title, body: dto.body } })
    return this.toResponse(note)
  }

  private toResponse(note: Note): NoteResponseDto {
    return { id: note.id, title: note.title, body: note.body, updatedAt: note.updatedAt }
  }
}
EOF
bench_base .

# --- after ----------------------------------------------------------------------------
cat > src/notes/update-note.dto.ts <<'EOF'
import { IsString, MaxLength, ValidateIf } from 'class-validator'

export class UpdateNoteDto {
  @ValidateIf((_, value) => value !== undefined)
  @IsString()
  @MaxLength(200)
  title?: string

  @ValidateIf((_, value) => value !== undefined)
  @IsString()
  @MaxLength(20000)
  body?: string
}
EOF
cat > src/notes/notes.controller.ts <<'EOF'
import { Body, Controller, Get, Param, ParseIntPipe, Patch, Post, UseGuards } from '@nestjs/common'
import { AuthUser, CurrentUser } from '../auth/current-user.decorator'
import { JwtAuthGuard } from '../auth/jwt-auth.guard'
import { CreateNoteDto } from './create-note.dto'
import { NoteResponseDto } from './note-response.dto'
import { NotesService } from './notes.service'
import { UpdateNoteDto } from './update-note.dto'

@Controller('notes')
@UseGuards(JwtAuthGuard)
export class NotesController {
  constructor(private readonly notes: NotesService) {}

  @Get()
  list(@CurrentUser() user: AuthUser): Promise<NoteResponseDto[]> {
    return this.notes.listForOwner(user.id)
  }

  @Post()
  create(@CurrentUser() user: AuthUser, @Body() dto: CreateNoteDto): Promise<NoteResponseDto> {
    return this.notes.create(user.id, dto)
  }

  @Get(':id')
  findOne(@Param('id', ParseIntPipe) id: number): Promise<NoteResponseDto> {
    return this.notes.findOne(id)
  }

  @Patch(':id')
  update(@Param('id', ParseIntPipe) id: number, @Body() dto: UpdateNoteDto): Promise<NoteResponseDto> {
    return this.notes.update(id, dto)
  }
}
EOF
cat > src/notes/notes.service.ts <<'EOF'
import { Injectable, NotFoundException } from '@nestjs/common'
import { Note } from '@prisma/client'
import { PrismaService } from '../prisma/prisma.service'
import { CreateNoteDto } from './create-note.dto'
import { NoteResponseDto } from './note-response.dto'
import { UpdateNoteDto } from './update-note.dto'

@Injectable()
export class NotesService {
  constructor(private readonly prisma: PrismaService) {}

  async listForOwner(ownerId: number): Promise<NoteResponseDto[]> {
    const notes = await this.prisma.note.findMany({
      where: { ownerId },
      orderBy: [{ updatedAt: 'desc' }, { id: 'desc' }],
    })
    return notes.map((note) => this.toResponse(note))
  }

  async create(ownerId: number, dto: CreateNoteDto): Promise<NoteResponseDto> {
    const note = await this.prisma.note.create({ data: { ownerId, title: dto.title, body: dto.body } })
    return this.toResponse(note)
  }

  async findOne(id: number): Promise<NoteResponseDto> {
    return this.toResponse(await this.getOrThrow(id))
  }

  async update(id: number, dto: UpdateNoteDto): Promise<NoteResponseDto> {
    await this.getOrThrow(id)
    const note = await this.prisma.note.update({
      where: { id },
      data: { title: dto.title, body: dto.body },
    })
    return this.toResponse(note)
  }

  private async getOrThrow(id: number): Promise<Note> {
    const note = await this.prisma.note.findUnique({ where: { id } })
    if (!note) {
      throw new NotFoundException('Note not found')
    }
    return note
  }

  private toResponse(note: Note): NoteResponseDto {
    return { id: note.id, title: note.title, body: note.body, updatedAt: note.updatedAt }
  }
}
EOF
bench_done .
