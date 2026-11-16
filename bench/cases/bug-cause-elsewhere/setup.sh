#!/bin/bash
# Next.js app + Zustand cart: bug fix (plan.md ## Bug) for a header cart badge that does not update after
# "Add to cart". The change edits the badge and adds a regression test that passes.
set -eu
. "$(cd "$(dirname "$0")/../.." && pwd)/lib.sh"
D="${1:-}"; bench_init "$D"; cd "$D"
bench_next .
mkdir -p src/store src/types src/components/CartBadge src/components/CartDrawer src/components/AddToCartButton

# --- before ---------------------------------------------------------------------------
cat > src/types/product.ts <<'EOF'
export interface Product {
  id: string
  name: string
  priceCents: number
}
EOF
cat > src/store/cart.ts <<'EOF'
import { create } from 'zustand'
import type { Product } from '@/types/product'

export interface CartItem {
  productId: string
  name: string
  priceCents: number
  quantity: number
}

interface CartState {
  items: CartItem[]
  addItem: (product: Product, quantity?: number) => void
  removeItem: (productId: string) => void
  clear: () => void
}

export const useCartStore = create<CartState>()((set) => ({
  items: [],
  addItem: (product, quantity = 1) =>
    set((state) => {
      const existing = state.items.find((item) => item.productId === product.id)
      if (existing) {
        existing.quantity += quantity
      } else {
        state.items.push({ productId: product.id, name: product.name, priceCents: product.priceCents, quantity })
      }
      return { items: state.items }
    }),
  removeItem: (productId) => set((state) => ({ items: state.items.filter((item) => item.productId !== productId) })),
  clear: () => set({ items: [] }),
}))

export function cartTotalCents(items: CartItem[]): number {
  return items.reduce((sum, item) => sum + item.priceCents * item.quantity, 0)
}
EOF
cat > src/store/cart.test.ts <<'EOF'
import { beforeEach, describe, expect, it } from 'vitest'
import { cartTotalCents, useCartStore } from './cart'

const MUG = { id: 'p1', name: 'Mug', priceCents: 1200 }
const TEA = { id: 'p2', name: 'Tea', priceCents: 650 }

describe('cart store', () => {
  beforeEach(() => useCartStore.getState().clear())

  it('adds a new product as one line', () => {
    useCartStore.getState().addItem(MUG)
    expect(useCartStore.getState().items).toEqual([{ productId: 'p1', name: 'Mug', priceCents: 1200, quantity: 1 }])
  })

  it('raises the quantity of a product already in the cart', () => {
    useCartStore.getState().addItem(MUG)
    useCartStore.getState().addItem(MUG, 2)
    expect(useCartStore.getState().items[0].quantity).toBe(3)
  })

  it('totals price times quantity', () => {
    useCartStore.getState().addItem(MUG, 2)
    useCartStore.getState().addItem(TEA)
    expect(cartTotalCents(useCartStore.getState().items)).toBe(3050)
  })
})
EOF
cat > src/components/CartBadge/index.tsx <<'EOF'
export { CartBadge } from './CartBadge'
EOF
cat > src/components/CartBadge/CartBadge.tsx <<'EOF'
'use client'

import { useCartStore } from '@/store/cart'

export function CartBadge() {
  const items = useCartStore((state) => state.items)
  const count = items.reduce((sum, item) => sum + item.quantity, 0)

  return (
    <span aria-label="Items in cart" className="rounded-full bg-gray-900 px-2 text-xs text-white">
      {count}
    </span>
  )
}
EOF
cat > src/components/CartDrawer/index.tsx <<'EOF'
export { CartDrawer } from './CartDrawer'
EOF
cat > src/components/CartDrawer/CartDrawer.tsx <<'EOF'
'use client'

import { cartTotalCents, useCartStore } from '@/store/cart'

const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })

export function CartDrawer() {
  const items = useCartStore((state) => state.items)
  const removeItem = useCartStore((state) => state.removeItem)

  if (items.length === 0) {
    return <p className="p-4 text-sm text-gray-500">Your cart is empty.</p>
  }
  return (
    <aside className="p-4">
      <ul className="divide-y">
        {items.map((item) => (
          <li key={item.productId} className="flex items-center justify-between py-2 text-sm">
            <span>
              {item.name} × {item.quantity}
            </span>
            <button type="button" onClick={() => removeItem(item.productId)} className="text-red-600">
              Remove
            </button>
          </li>
        ))}
      </ul>
      <p className="mt-3 text-right font-medium">{currency.format(cartTotalCents(items) / 100)}</p>
    </aside>
  )
}
EOF
cat > src/components/AddToCartButton/index.tsx <<'EOF'
export { AddToCartButton } from './AddToCartButton'
EOF
cat > src/components/AddToCartButton/AddToCartButton.tsx <<'EOF'
'use client'

import { useCartStore } from '@/store/cart'
import type { Product } from '@/types/product'

interface AddToCartButtonProps {
  product: Product
}

export function AddToCartButton({ product }: AddToCartButtonProps) {
  const addItem = useCartStore((state) => state.addItem)

  return (
    <button type="button" onClick={() => addItem(product)} className="rounded bg-gray-900 px-4 py-2 text-white">
      Add to cart
    </button>
  )
}
EOF
bench_base .

# --- after ----------------------------------------------------------------------------
cat > src/components/CartBadge/CartBadge.tsx <<'EOF'
'use client'

import { useCartStore } from '@/store/cart'

export function CartBadge() {
  // Select the derived count, so the badge re-renders whenever the total quantity changes.
  const count = useCartStore((state) => state.items.reduce((sum, item) => sum + item.quantity, 0))

  return (
    <span aria-label="Items in cart" className="rounded-full bg-gray-900 px-2 text-xs text-white">
      {count}
    </span>
  )
}
EOF
cat > src/components/CartBadge/CartBadge.test.tsx <<'EOF'
import { act, render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it } from 'vitest'
import { useCartStore } from '@/store/cart'
import { CartBadge } from './CartBadge'

const MUG = { id: 'p1', name: 'Mug', priceCents: 1200 }

describe('CartBadge', () => {
  beforeEach(() => useCartStore.getState().clear())

  it('updates after addItem', () => {
    render(<CartBadge />)
    expect(screen.getByLabelText('Items in cart').textContent).toBe('0')
    act(() => useCartStore.getState().addItem(MUG))
    expect(screen.getByLabelText('Items in cart').textContent).toBe('1')
  })
})
EOF
bench_done .
