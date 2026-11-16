#!/bin/bash
# Next.js catalog: each product row gains an add-to-cart button backed by the Zustand cart store.
set -eu
. "$(cd "$(dirname "$0")/../.." && pwd)/lib.sh"
D="${1:-}"; bench_init "$D"; cd "$D"
mkdir -p src/components src/stores src/lib src/types

# --- before ---------------------------------------------------------------------------
cat > package.json <<'EOF'
{
  "name": "shop-web",
  "private": true,
  "scripts": { "dev": "next dev", "build": "next build", "test": "vitest run" },
  "dependencies": { "next": "14.2.5", "react": "18.3.1", "react-dom": "18.3.1", "zustand": "4.5.4" },
  "devDependencies": { "@types/react": "18.3.3", "typescript": "5.5.4", "vitest": "2.0.5" }
}
EOF
cat > tsconfig.json <<'EOF'
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
cat > src/types/product.ts <<'EOF'
export interface Product {
  id: string
  name: string
  priceCents: number
  inStock: boolean
}
EOF
cat > src/lib/format.ts <<'EOF'
const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })

export function formatPrice(cents: number): string {
  return currency.format(cents / 100)
}
EOF
cat > src/stores/useCartStore.ts <<'EOF'
import { create } from 'zustand'

export interface CartItem {
  productId: string
  quantity: number
}

interface CartState {
  items: CartItem[]
  addItem: (productId: string) => void
  removeItem: (productId: string) => void
  clear: () => void
}

export const useCartStore = create<CartState>()((set) => ({
  items: [],
  addItem: (productId) =>
    set((state) => {
      const existing = state.items.find((item) => item.productId === productId)
      if (!existing) return { items: [...state.items, { productId, quantity: 1 }] }
      return {
        items: state.items.map((item) =>
          item.productId === productId ? { ...item, quantity: item.quantity + 1 } : item,
        ),
      }
    }),
  removeItem: (productId) =>
    set((state) => ({ items: state.items.filter((item) => item.productId !== productId) })),
  clear: () => set({ items: [] }),
}))
EOF
cat > src/components/CartBadge.tsx <<'EOF'
'use client'

import { useCartStore } from '@/stores/useCartStore'

export function CartBadge() {
  const count = useCartStore((state) => state.items.reduce((sum, item) => sum + item.quantity, 0))

  return (
    <span aria-label={`${count} items in cart`} className="rounded-full bg-black px-2 text-xs text-white">
      {count}
    </span>
  )
}
EOF
cat > src/components/ProductList.tsx <<'EOF'
'use client'

import type { Product } from '@/types/product'
import { ProductRow } from './ProductRow'

interface ProductListProps {
  products: Product[]
}

export function ProductList({ products }: ProductListProps) {
  if (products.length === 0) {
    return <p className="py-8 text-center text-gray-500">No products match your filters.</p>
  }

  return (
    <ul className="divide-y">
      {products.map((product) => (
        <ProductRow key={product.id} product={product} />
      ))}
    </ul>
  )
}
EOF
cat > src/components/ProductRow.tsx <<'EOF'
'use client'

import { memo } from 'react'
import { formatPrice } from '@/lib/format'
import type { Product } from '@/types/product'

interface ProductRowProps {
  product: Product
}

export const ProductRow = memo(function ProductRow({ product }: ProductRowProps) {
  return (
    <li className="flex items-center justify-between py-3">
      <span className="font-medium">{product.name}</span>
      <span className="tabular-nums">{formatPrice(product.priceCents)}</span>
    </li>
  )
})
EOF
bench_base .

# --- after ----------------------------------------------------------------------------
cat > src/components/ProductRow.tsx <<'EOF'
'use client'

import { memo } from 'react'
import { formatPrice } from '@/lib/format'
import { useCartStore } from '@/stores/useCartStore'
import type { Product } from '@/types/product'

interface ProductRowProps {
  product: Product
}

export const ProductRow = memo(function ProductRow({ product }: ProductRowProps) {
  const { items, addItem } = useCartStore()
  const quantityInCart = items.find((item) => item.productId === product.id)?.quantity ?? 0

  const handleAdd = (): void => {
    addItem(product.id)
  }

  return (
    <li className="flex items-center justify-between gap-4 py-3">
      <span className="font-medium">{product.name}</span>
      <span className="ml-auto tabular-nums">{formatPrice(product.priceCents)}</span>
      <button
        type="button"
        onClick={handleAdd}
        disabled={!product.inStock}
        className="rounded border px-3 py-1 text-sm disabled:opacity-50"
      >
        {quantityInCart > 0 ? `In cart (${quantityInCart})` : 'Add to cart'}
      </button>
    </li>
  )
})
EOF
bench_done .
