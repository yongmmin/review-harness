#!/bin/bash
# Next.js shop: prices are shown in the cart's / order's own currency instead of always USD (plan.md).
# formatPrice gains a currency argument; the change updates two of its callers.
set -eu
. "$(cd "$(dirname "$0")/../.." && pwd)/lib.sh"
D="${1:-}"; bench_init "$D"; cd "$D"
bench_next .
mkdir -p src/types src/components/CartSummary src/components/OrderRow

# --- before ---------------------------------------------------------------------------
cat > src/types/money.ts <<'EOF'
export type CurrencyCode = 'USD' | 'EUR' | 'GBP'
EOF
cat > src/types/order.ts <<'EOF'
import type { CurrencyCode } from './money'

export interface OrderLine {
  sku: string
  name: string
  quantity: number
  totalCents: number
}

export interface Order {
  id: string
  number: string
  currency: CurrencyCode
  lines: OrderLine[]
  totalCents: number
  placedAt: string
}
EOF
cat > src/types/cart.ts <<'EOF'
import type { CurrencyCode } from './money'

export interface Cart {
  id: string
  currency: CurrencyCode
  itemCount: number
  subtotalCents: number
  shippingCents: number
  totalCents: number
}
EOF
cat > src/lib/formatPrice.ts <<'EOF'
const formatter = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })

export function formatPrice(cents: number): string {
  return formatter.format(cents / 100)
}
EOF
cat > src/lib/formatPrice.test.ts <<'EOF'
import { describe, expect, it } from 'vitest'
import { formatPrice } from './formatPrice'

describe('formatPrice', () => {
  it('formats cents as dollars', () => {
    expect(formatPrice(123456)).toBe('$1,234.56')
  })

  it('formats zero', () => {
    expect(formatPrice(0)).toBe('$0.00')
  })
})
EOF
cat > src/lib/receipt.ts <<'EOF'
import { formatPrice } from './formatPrice'
import type { Order } from '@/types/order'

// Plain-text receipt used by "Copy receipt" and the order confirmation email body.
export function buildReceiptText(order: Order): string {
  const lines = order.lines.map((line) => `${line.quantity} × ${line.name}  ${formatPrice(line.totalCents)}`)
  return [`Order ${order.number}`, ...lines, `Total  ${formatPrice(order.totalCents)}`].join('\n')
}
EOF
cat > src/components/CartSummary/index.tsx <<'EOF'
export { CartSummary } from './CartSummary'
EOF
cat > src/components/CartSummary/CartSummary.tsx <<'EOF'
'use client'

import { formatPrice } from '@/lib/formatPrice'
import type { Cart } from '@/types/cart'

interface CartSummaryProps {
  cart: Cart
}

export function CartSummary({ cart }: CartSummaryProps) {
  return (
    <dl className="grid grid-cols-2 gap-y-1 text-sm">
      <dt>Subtotal ({cart.itemCount} items)</dt>
      <dd className="text-right">{formatPrice(cart.subtotalCents)}</dd>
      <dt>Shipping</dt>
      <dd className="text-right">{formatPrice(cart.shippingCents)}</dd>
      <dt className="font-medium">Total</dt>
      <dd className="text-right font-medium">{formatPrice(cart.totalCents)}</dd>
    </dl>
  )
}
EOF
cat > src/components/OrderRow/index.tsx <<'EOF'
export { OrderRow } from './OrderRow'
EOF
cat > src/components/OrderRow/OrderRow.tsx <<'EOF'
'use client'

import { formatPrice } from '@/lib/formatPrice'
import type { Order } from '@/types/order'

interface OrderRowProps {
  order: Order
}

export function OrderRow({ order }: OrderRowProps) {
  return (
    <tr className="border-t text-sm">
      <td className="py-2">{order.number}</td>
      <td className="py-2">{new Date(order.placedAt).toLocaleDateString()}</td>
      <td className="py-2 text-right">{formatPrice(order.totalCents)}</td>
    </tr>
  )
}
EOF
bench_base .

# --- after ----------------------------------------------------------------------------
cat > src/lib/formatPrice.ts <<'EOF'
import type { CurrencyCode } from '@/types/money'

const formatters = new Map<CurrencyCode, Intl.NumberFormat>()

function formatterFor(currency: CurrencyCode): Intl.NumberFormat {
  let formatter = formatters.get(currency)
  if (!formatter) {
    formatter = new Intl.NumberFormat('en-US', { style: 'currency', currency })
    formatters.set(currency, formatter)
  }
  return formatter
}

export function formatPrice(cents: number, currency: CurrencyCode = 'USD'): string {
  return formatterFor(currency).format(cents / 100)
}
EOF
cat > src/lib/formatPrice.test.ts <<'EOF'
import { describe, expect, it } from 'vitest'
import { formatPrice } from './formatPrice'

describe('formatPrice', () => {
  it('formats cents as dollars by default', () => {
    expect(formatPrice(123456)).toBe('$1,234.56')
  })

  it('formats zero', () => {
    expect(formatPrice(0)).toBe('$0.00')
  })

  it('formats in the given currency', () => {
    expect(formatPrice(123456, 'EUR')).toBe('€1,234.56')
    expect(formatPrice(999, 'GBP')).toBe('£9.99')
  })
})
EOF
cat > src/components/CartSummary/CartSummary.tsx <<'EOF'
'use client'

import { formatPrice } from '@/lib/formatPrice'
import type { Cart } from '@/types/cart'

interface CartSummaryProps {
  cart: Cart
}

export function CartSummary({ cart }: CartSummaryProps) {
  return (
    <dl className="grid grid-cols-2 gap-y-1 text-sm">
      <dt>Subtotal ({cart.itemCount} items)</dt>
      <dd className="text-right">{formatPrice(cart.subtotalCents, cart.currency)}</dd>
      <dt>Shipping</dt>
      <dd className="text-right">{formatPrice(cart.shippingCents, cart.currency)}</dd>
      <dt className="font-medium">Total</dt>
      <dd className="text-right font-medium">{formatPrice(cart.totalCents, cart.currency)}</dd>
    </dl>
  )
}
EOF
cat > src/components/OrderRow/OrderRow.tsx <<'EOF'
'use client'

import { formatPrice } from '@/lib/formatPrice'
import type { Order } from '@/types/order'

interface OrderRowProps {
  order: Order
}

export function OrderRow({ order }: OrderRowProps) {
  return (
    <tr className="border-t text-sm">
      <td className="py-2">{order.number}</td>
      <td className="py-2">{new Date(order.placedAt).toLocaleDateString()}</td>
      <td className="py-2 text-right">{formatPrice(order.totalCents, order.currency)}</td>
    </tr>
  )
}
EOF
bench_done .
