#!/bin/bash
# NestJS + Prisma: the invoices module gains GET /invoices/:id.
set -eu
. "$(cd "$(dirname "$0")/../.." && pwd)/lib.sh"
D="${1:-}"; bench_init "$D"; cd "$D"
bench_nest .
mkdir -p src/invoices

# --- before ---------------------------------------------------------------------------
cat > prisma/schema.prisma <<'EOF'
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

generator client {
  provider = "prisma-client-js"
}

enum InvoiceStatus {
  DRAFT
  SENT
  PAID
}

model Invoice {
  id          Int           @id @default(autoincrement())
  ownerId     Int
  number      String        @unique
  amountCents Int
  status      InvoiceStatus @default(DRAFT)
  issuedAt    DateTime      @default(now())
  dueAt       DateTime

  @@index([ownerId, issuedAt])
}
EOF
cat > src/invoices/invoice-response.dto.ts <<'EOF'
import { InvoiceStatus } from '@prisma/client'

export class InvoiceResponseDto {
  id!: number
  number!: string
  amountCents!: number
  status!: InvoiceStatus
  issuedAt!: Date
  dueAt!: Date
}
EOF
cat > src/invoices/invoices.module.ts <<'EOF'
import { Module } from '@nestjs/common'
import { PrismaService } from '../prisma/prisma.service'
import { InvoicesController } from './invoices.controller'
import { InvoicesService } from './invoices.service'

@Module({
  controllers: [InvoicesController],
  providers: [InvoicesService, PrismaService],
})
export class InvoicesModule {}
EOF
cat > src/invoices/invoices.controller.ts <<'EOF'
import { Controller, Get, UseGuards } from '@nestjs/common'
import { AuthUser, CurrentUser } from '../auth/current-user.decorator'
import { JwtAuthGuard } from '../auth/jwt-auth.guard'
import { InvoiceResponseDto } from './invoice-response.dto'
import { InvoicesService } from './invoices.service'

@Controller('invoices')
@UseGuards(JwtAuthGuard)
export class InvoicesController {
  constructor(private readonly invoices: InvoicesService) {}

  @Get()
  list(@CurrentUser() user: AuthUser): Promise<InvoiceResponseDto[]> {
    return this.invoices.listForOwner(user.id)
  }
}
EOF
cat > src/invoices/invoices.service.ts <<'EOF'
import { Injectable } from '@nestjs/common'
import { Invoice } from '@prisma/client'
import { PrismaService } from '../prisma/prisma.service'
import { InvoiceResponseDto } from './invoice-response.dto'

@Injectable()
export class InvoicesService {
  constructor(private readonly prisma: PrismaService) {}

  async listForOwner(ownerId: number): Promise<InvoiceResponseDto[]> {
    const invoices = await this.prisma.invoice.findMany({
      where: { ownerId },
      orderBy: [{ issuedAt: 'desc' }, { id: 'desc' }],
    })
    return invoices.map((invoice) => this.toResponse(invoice))
  }

  private toResponse(invoice: Invoice): InvoiceResponseDto {
    return {
      id: invoice.id,
      number: invoice.number,
      amountCents: invoice.amountCents,
      status: invoice.status,
      issuedAt: invoice.issuedAt,
      dueAt: invoice.dueAt,
    }
  }
}
EOF
bench_base .

# --- after ----------------------------------------------------------------------------
cat > src/invoices/invoices.controller.ts <<'EOF'
import { Controller, Get, Param, ParseIntPipe, UseGuards } from '@nestjs/common'
import { AuthUser, CurrentUser } from '../auth/current-user.decorator'
import { JwtAuthGuard } from '../auth/jwt-auth.guard'
import { InvoiceResponseDto } from './invoice-response.dto'
import { InvoicesService } from './invoices.service'

@Controller('invoices')
@UseGuards(JwtAuthGuard)
export class InvoicesController {
  constructor(private readonly invoices: InvoicesService) {}

  @Get()
  list(@CurrentUser() user: AuthUser): Promise<InvoiceResponseDto[]> {
    return this.invoices.listForOwner(user.id)
  }

  @Get(':id')
  findOne(
    @CurrentUser() user: AuthUser,
    @Param('id', ParseIntPipe) id: number,
  ): Promise<InvoiceResponseDto> {
    return this.invoices.findOneForOwner(user.id, id)
  }
}
EOF
cat > src/invoices/invoices.service.ts <<'EOF'
import { Injectable, InternalServerErrorException } from '@nestjs/common'
import { Invoice } from '@prisma/client'
import { PrismaService } from '../prisma/prisma.service'
import { InvoiceResponseDto } from './invoice-response.dto'

@Injectable()
export class InvoicesService {
  constructor(private readonly prisma: PrismaService) {}

  async listForOwner(ownerId: number): Promise<InvoiceResponseDto[]> {
    const invoices = await this.prisma.invoice.findMany({
      where: { ownerId },
      orderBy: [{ issuedAt: 'desc' }, { id: 'desc' }],
    })
    return invoices.map((invoice) => this.toResponse(invoice))
  }

  async findOneForOwner(ownerId: number, id: number): Promise<InvoiceResponseDto> {
    const invoice = await this.prisma.invoice.findFirst({ where: { id, ownerId } })
    if (!invoice) {
      throw new InternalServerErrorException('Invoice not found')
    }
    return this.toResponse(invoice)
  }

  private toResponse(invoice: Invoice): InvoiceResponseDto {
    return {
      id: invoice.id,
      number: invoice.number,
      amountCents: invoice.amountCents,
      status: invoice.status,
      issuedAt: invoice.issuedAt,
      dueAt: invoice.dueAt,
    }
  }
}
EOF
bench_done .
