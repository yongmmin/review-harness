#!/bin/bash
# NestJS + Prisma: orders gain POST /orders/:id/cancel, which also writes an audit log entry.
set -eu
. "$(cd "$(dirname "$0")/../.." && pwd)/lib.sh"
D="${1:-}"; bench_init "$D"; cd "$D"
bench_nest .
mkdir -p src/orders src/audit

# --- before ---------------------------------------------------------------------------
cat > prisma/schema.prisma <<'EOF'
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

generator client {
  provider = "prisma-client-js"
}

enum OrderStatus {
  PENDING
  SHIPPED
  CANCELLED
}

model Order {
  id         Int         @id @default(autoincrement())
  ownerId    Int
  totalCents Int
  status     OrderStatus @default(PENDING)
  createdAt  DateTime    @default(now())
}

model AuditLog {
  id        Int      @id @default(autoincrement())
  actorId   Int
  action    String
  targetId  Int
  createdAt DateTime @default(now())
}
EOF
cat > src/audit/audit-log.service.ts <<'EOF'
import { Injectable } from '@nestjs/common'
import { PrismaService } from '../prisma/prisma.service'

export interface AuditEntry {
  actorId: number
  action: string
  targetId: number
}

@Injectable()
export class AuditLogService {
  constructor(private readonly prisma: PrismaService) {}

  async record(entry: AuditEntry): Promise<void> {
    await this.prisma.auditLog.create({ data: entry })
  }
}
EOF
cat > src/orders/create-order.dto.ts <<'EOF'
import { IsInt, Min } from 'class-validator'

export class CreateOrderDto {
  @IsInt()
  @Min(1)
  totalCents!: number
}
EOF
cat > src/orders/order-response.dto.ts <<'EOF'
import { OrderStatus } from '@prisma/client'

export class OrderResponseDto {
  id!: number
  totalCents!: number
  status!: OrderStatus
  createdAt!: Date
}
EOF
cat > src/orders/orders.module.ts <<'EOF'
import { Module } from '@nestjs/common'
import { AuditLogService } from '../audit/audit-log.service'
import { PrismaService } from '../prisma/prisma.service'
import { OrdersController } from './orders.controller'
import { OrdersService } from './orders.service'

@Module({
  controllers: [OrdersController],
  providers: [OrdersService, AuditLogService, PrismaService],
})
export class OrdersModule {}
EOF
cat > src/orders/orders.controller.ts <<'EOF'
import { Body, Controller, Post, UseGuards } from '@nestjs/common'
import { AuthUser, CurrentUser } from '../auth/current-user.decorator'
import { JwtAuthGuard } from '../auth/jwt-auth.guard'
import { CreateOrderDto } from './create-order.dto'
import { OrderResponseDto } from './order-response.dto'
import { OrdersService } from './orders.service'

@Controller('orders')
@UseGuards(JwtAuthGuard)
export class OrdersController {
  constructor(private readonly orders: OrdersService) {}

  @Post()
  create(@CurrentUser() user: AuthUser, @Body() dto: CreateOrderDto): Promise<OrderResponseDto> {
    return this.orders.create(user.id, dto)
  }
}
EOF
cat > src/orders/orders.service.ts <<'EOF'
import { Injectable } from '@nestjs/common'
import { Order } from '@prisma/client'
import { AuditLogService } from '../audit/audit-log.service'
import { PrismaService } from '../prisma/prisma.service'
import { CreateOrderDto } from './create-order.dto'
import { OrderResponseDto } from './order-response.dto'

@Injectable()
export class OrdersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auditLog: AuditLogService,
  ) {}

  async create(ownerId: number, dto: CreateOrderDto): Promise<OrderResponseDto> {
    const order = await this.prisma.order.create({ data: { ownerId, totalCents: dto.totalCents } })
    await this.auditLog.record({ actorId: ownerId, action: 'order.created', targetId: order.id })
    return this.toResponse(order)
  }

  private toResponse(order: Order): OrderResponseDto {
    return { id: order.id, totalCents: order.totalCents, status: order.status, createdAt: order.createdAt }
  }
}
EOF
bench_base .

# --- after ----------------------------------------------------------------------------
cat > src/orders/orders.controller.ts <<'EOF'
import { Body, Controller, HttpCode, Param, ParseIntPipe, Post, UseGuards } from '@nestjs/common'
import { AuthUser, CurrentUser } from '../auth/current-user.decorator'
import { JwtAuthGuard } from '../auth/jwt-auth.guard'
import { CreateOrderDto } from './create-order.dto'
import { OrderResponseDto } from './order-response.dto'
import { OrdersService } from './orders.service'

@Controller('orders')
@UseGuards(JwtAuthGuard)
export class OrdersController {
  constructor(private readonly orders: OrdersService) {}

  @Post()
  create(@CurrentUser() user: AuthUser, @Body() dto: CreateOrderDto): Promise<OrderResponseDto> {
    return this.orders.create(user.id, dto)
  }

  @Post(':id/cancel')
  @HttpCode(200)
  cancel(@CurrentUser() user: AuthUser, @Param('id', ParseIntPipe) id: number): Promise<OrderResponseDto> {
    return this.orders.cancel(user.id, id)
  }
}
EOF
cat > src/orders/orders.service.ts <<'EOF'
import { ConflictException, Injectable, NotFoundException } from '@nestjs/common'
import { Order, OrderStatus } from '@prisma/client'
import { AuditLogService } from '../audit/audit-log.service'
import { PrismaService } from '../prisma/prisma.service'
import { CreateOrderDto } from './create-order.dto'
import { OrderResponseDto } from './order-response.dto'

@Injectable()
export class OrdersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly auditLog: AuditLogService,
  ) {}

  async create(ownerId: number, dto: CreateOrderDto): Promise<OrderResponseDto> {
    const order = await this.prisma.order.create({ data: { ownerId, totalCents: dto.totalCents } })
    await this.auditLog.record({ actorId: ownerId, action: 'order.created', targetId: order.id })
    return this.toResponse(order)
  }

  async cancel(ownerId: number, id: number): Promise<OrderResponseDto> {
    const order = await this.prisma.order.findFirst({ where: { id, ownerId } })
    if (!order) {
      throw new NotFoundException('Order not found')
    }

    const { count } = await this.prisma.order.updateMany({
      where: { id, ownerId, status: OrderStatus.PENDING },
      data: { status: OrderStatus.CANCELLED },
    })
    if (count === 0) {
      throw new ConflictException('Only pending orders can be cancelled')
    }

    this.auditLog.record({ actorId: ownerId, action: 'order.cancelled', targetId: id })
    return this.toResponse({ ...order, status: OrderStatus.CANCELLED })
  }

  private toResponse(order: Order): OrderResponseDto {
    return { id: order.id, totalCents: order.totalCents, status: order.status, createdAt: order.createdAt }
  }
}
EOF
bench_done .
