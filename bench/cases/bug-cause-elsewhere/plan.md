# Plan: Cart badge does not update after "Add to cart"

## Goal
The header cart badge shows the new count as soon as a product is added.

## Done When
- After `addItem`, the badge shows the new quantity without a reload — check: `src/components/CartBadge/CartBadge.test.tsx` "updates after addItem"
- Existing cart tests still pass — check: `npm test`

## Out of Scope
- Cart persistence across reloads

## Intent
bugfix

## Inputs
- Design: none
- API: none

## Affected Files
- src/store/cart.ts - `addItem` returns a new `items` array (and a new item object when the quantity changes)
- src/components/CartBadge/CartBadge.test.tsx - new regression test

## Bug (bugfix only)
- Symptom: after "Add to cart" the header badge keeps the old count until the page is reloaded; expected the new count at once
- Repro: `npx vitest run src/components/CartBadge` → `CartBadge > updates after addItem: expected '0' to be '1'`
- Cause: src/store/cart.ts:24-28 — `addItem` mutates the existing item / pushes into the existing `items` array and returns the same array reference, so every selector that returns `items` (CartBadge, CartDrawer) sees no change and does not re-render
- Regression test: src/components/CartBadge/CartBadge.test.tsx — "updates after addItem"

## Design Check
- Reuse: existing `useCartStore`; no new store or hook
- Responsibility: the store owns immutable updates; components keep plain selectors
- Risk: none
- Callers/Consumers: `useCartStore` items → src/components/CartBadge/CartBadge.tsx, src/components/CartDrawer/CartDrawer.tsx (no change needed: they re-render once the reference changes)
- Pattern: `removeItem` in src/store/cart.ts (returns a new array)
- Tests: src/store/cart.test.ts (existing); new src/components/CartBadge/CartBadge.test.tsx

## Execution Steps
- Step 1: developer - regression test RED, then fix `addItem`
- Step 2: test-runner
- Step 3: reviewer

## Branch
fix/cart-badge-stale-count
