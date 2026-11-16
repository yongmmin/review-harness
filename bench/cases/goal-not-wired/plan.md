# Plan: Order status filter

## Goal
Let users narrow the orders page to one status.

## Done When
- On /orders, choosing a status in the filter lists only the orders with that status — check: `src/app/orders/page.test.tsx` "filters orders by status"
- With "All statuses" selected, every order is listed — check: `src/app/orders/page.test.tsx` "lists every order by default"

## Out of Scope
- Keeping the selected status in the URL

## Intent
feature

## Inputs
- Design: none
- API: none — client-side filter over the existing `GET /orders` list

## Affected Files
- src/hooks/useOrderStatusFilter.ts - new: selected status + filtered list
- src/hooks/useOrderStatusFilter.test.ts - new
- src/components/OrderStatusFilter/ - new: status select (index.tsx, OrderStatusFilter.tsx, OrderStatusFilter.test.tsx)
- src/app/orders/page.tsx - render OrderStatusFilter above OrderTable and pass the filtered list to OrderTable
- src/app/orders/page.test.tsx - add the two Done When tests

## Design Check
- Reuse: `OrderTable` and `useOrdersQuery` unchanged; native `<select>` with the existing form classes
- Responsibility: hook owns the filter state and the filtered list; the select is presentational; the page composes them
- Risk: none
- Callers/Consumers: none — new
- Pattern: src/components/OrderTable/OrderTable.tsx
- Tests: src/app/orders/page.test.tsx (extend); new hook and component tests

## Execution Steps
- Step 1: developer - hook and select with tests, then use them in the orders page
- Step 2: test-runner
- Step 3: reviewer

## Branch
feat/order-status-filter
