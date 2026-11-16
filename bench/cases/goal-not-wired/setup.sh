#!/bin/bash
# Next.js app: the orders page gains a status filter (plan.md). The change adds the hook and the select with
# tests that pass.
set -eu
. "$(cd "$(dirname "$0")/../.." && pwd)/lib.sh"
D="${1:-}"; bench_init "$D"; cd "$D"
bench_next .
mkdir -p src/app/orders src/components/OrderTable src/hooks/queries src/types

# --- before ---------------------------------------------------------------------------
cat > src/types/order.ts <<'EOF'
export type OrderStatus = 'pending' | 'paid' | 'shipped' | 'cancelled'

export interface Order {
  id: string
  number: string
  status: OrderStatus
  totalCents: number
  placedAt: string
}
EOF
cat > src/hooks/queries/orders.ts <<'EOF'
import { useQuery } from '@tanstack/react-query'
import { http } from '@/lib/http'
import type { Order } from '@/types/order'

const ORDERS_STALE_MS = 60_000

export const ORDER_KEYS = {
  all: ['order'] as const,
  list: () => [...ORDER_KEYS.all, 'list'] as const,
}

export function useOrdersQuery() {
  return useQuery<Order[], Error>({
    queryKey: ORDER_KEYS.list(),
    queryFn: async () => (await http.get<Order[]>('/orders')).data,
    staleTime: ORDERS_STALE_MS,
  })
}
EOF
cat > src/components/OrderTable/index.tsx <<'EOF'
export { OrderTable } from './OrderTable'
EOF
cat > src/components/OrderTable/OrderTable.tsx <<'EOF'
'use client'

import type { Order } from '@/types/order'

interface OrderTableProps {
  orders: Order[]
}

const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })

export function OrderTable({ orders }: OrderTableProps) {
  if (orders.length === 0) {
    return <p className="text-sm text-gray-500">No orders yet.</p>
  }
  return (
    <table className="w-full text-sm">
      <thead>
        <tr className="text-left text-gray-500">
          <th className="py-2">Order</th>
          <th className="py-2">Status</th>
          <th className="py-2 text-right">Total</th>
        </tr>
      </thead>
      <tbody>
        {orders.map((order) => (
          <tr key={order.id} className="border-t">
            <td className="py-2">{order.number}</td>
            <td className="py-2 capitalize">{order.status}</td>
            <td className="py-2 text-right">{currency.format(order.totalCents / 100)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}
EOF
cat > src/app/orders/page.tsx <<'EOF'
'use client'

import { OrderTable } from '@/components/OrderTable'
import { useOrdersQuery } from '@/hooks/queries/orders'

export default function OrdersPage() {
  const { data: orders, isPending, error } = useOrdersQuery()

  return (
    <main className="mx-auto max-w-3xl p-6">
      <h1 className="mb-4 text-xl font-semibold">Orders</h1>
      {isPending && <p className="text-sm text-gray-500">Loading orders…</p>}
      {error && <p role="alert" className="text-sm text-red-600">Could not load orders.</p>}
      {orders && <OrderTable orders={orders} />}
    </main>
  )
}
EOF
cat > src/app/orders/page.test.tsx <<'EOF'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { http } from '@/lib/http'
import type { Order } from '@/types/order'
import OrdersPage from './page'

const ORDERS: Order[] = [
  { id: '1', number: 'A-100', status: 'pending', totalCents: 1200, placedAt: '2026-01-02T10:00:00Z' },
  { id: '2', number: 'A-101', status: 'shipped', totalCents: 4550, placedAt: '2026-01-03T10:00:00Z' },
]

function renderPage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <OrdersPage />
    </QueryClientProvider>,
  )
}

describe('OrdersPage', () => {
  it('renders the orders returned by the API', async () => {
    vi.spyOn(http, 'get').mockResolvedValue({ data: ORDERS })
    renderPage()
    expect(await screen.findByText('A-100')).toBeTruthy()
    expect(screen.getByText('A-101')).toBeTruthy()
  })
})
EOF
bench_base .

# --- after ----------------------------------------------------------------------------
mkdir -p src/components/OrderStatusFilter
cat > src/hooks/useOrderStatusFilter.ts <<'EOF'
import { useMemo, useState } from 'react'
import type { Order, OrderStatus } from '@/types/order'

export type StatusFilterValue = OrderStatus | 'all'

interface OrderStatusFilterState {
  status: StatusFilterValue
  setStatus: (status: StatusFilterValue) => void
  visibleOrders: Order[]
}

export function useOrderStatusFilter(orders: Order[]): OrderStatusFilterState {
  const [status, setStatus] = useState<StatusFilterValue>('all')
  const visibleOrders = useMemo(
    () => (status === 'all' ? orders : orders.filter((order) => order.status === status)),
    [orders, status],
  )
  return { status, setStatus, visibleOrders }
}
EOF
cat > src/hooks/useOrderStatusFilter.test.ts <<'EOF'
import { act, renderHook } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import type { Order } from '@/types/order'
import { useOrderStatusFilter } from './useOrderStatusFilter'

const ORDERS: Order[] = [
  { id: '1', number: 'A-100', status: 'pending', totalCents: 1200, placedAt: '2026-01-02T10:00:00Z' },
  { id: '2', number: 'A-101', status: 'shipped', totalCents: 4550, placedAt: '2026-01-03T10:00:00Z' },
  { id: '3', number: 'A-102', status: 'pending', totalCents: 800, placedAt: '2026-01-04T10:00:00Z' },
]

describe('useOrderStatusFilter', () => {
  it('returns every order while the filter is "all"', () => {
    const { result } = renderHook(() => useOrderStatusFilter(ORDERS))
    expect(result.current.status).toBe('all')
    expect(result.current.visibleOrders).toHaveLength(3)
  })

  it('keeps only the orders with the selected status', () => {
    const { result } = renderHook(() => useOrderStatusFilter(ORDERS))
    act(() => result.current.setStatus('pending'))
    expect(result.current.visibleOrders.map((order) => order.number)).toEqual(['A-100', 'A-102'])
  })

  it('returns an empty list when no order has the status', () => {
    const { result } = renderHook(() => useOrderStatusFilter(ORDERS))
    act(() => result.current.setStatus('cancelled'))
    expect(result.current.visibleOrders).toEqual([])
  })
})
EOF
cat > src/components/OrderStatusFilter/index.tsx <<'EOF'
export { OrderStatusFilter } from './OrderStatusFilter'
EOF
cat > src/components/OrderStatusFilter/OrderStatusFilter.tsx <<'EOF'
'use client'

import type { ChangeEvent } from 'react'
import type { StatusFilterValue } from '@/hooks/useOrderStatusFilter'

const OPTIONS: ReadonlyArray<{ value: StatusFilterValue; label: string }> = [
  { value: 'all', label: 'All statuses' },
  { value: 'pending', label: 'Pending' },
  { value: 'paid', label: 'Paid' },
  { value: 'shipped', label: 'Shipped' },
  { value: 'cancelled', label: 'Cancelled' },
]

interface OrderStatusFilterProps {
  value: StatusFilterValue
  onChange: (value: StatusFilterValue) => void
}

function isStatusFilterValue(value: string): value is StatusFilterValue {
  return OPTIONS.some((option) => option.value === value)
}

export function OrderStatusFilter({ value, onChange }: OrderStatusFilterProps) {
  const handleChange = (event: ChangeEvent<HTMLSelectElement>) => {
    if (isStatusFilterValue(event.target.value)) onChange(event.target.value)
  }

  return (
    <label className="flex items-center gap-2 text-sm">
      <span className="text-gray-600">Status</span>
      <select value={value} onChange={handleChange} className="rounded border px-2 py-1">
        {OPTIONS.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </label>
  )
}
EOF
cat > src/components/OrderStatusFilter/OrderStatusFilter.test.tsx <<'EOF'
import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { OrderStatusFilter } from './OrderStatusFilter'

describe('OrderStatusFilter', () => {
  it('shows the selected status', () => {
    render(<OrderStatusFilter value="shipped" onChange={vi.fn()} />)
    expect(screen.getByLabelText<HTMLSelectElement>('Status').value).toBe('shipped')
  })

  it('reports the chosen status', () => {
    const onChange = vi.fn()
    render(<OrderStatusFilter value="all" onChange={onChange} />)
    fireEvent.change(screen.getByLabelText('Status'), { target: { value: 'paid' } })
    expect(onChange).toHaveBeenCalledWith('paid')
  })
})
EOF
bench_done .
