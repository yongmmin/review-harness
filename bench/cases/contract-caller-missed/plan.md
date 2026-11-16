# Plan: Prices in the cart's and order's currency

## Goal
Carts and orders already carry a `currency`; show their prices in it instead of always in USD.

## Done When
- `formatPrice` formats in a given currency and stays USD by default — check: `src/lib/formatPrice.test.ts` "formats in the given currency"
- The cart summary and the order list show EUR / GBP amounts for EUR / GBP carts and orders — check: manual, open a EUR cart and the orders page

## Out of Scope
- Currency conversion and locale-specific number formats

## Intent
feature

## Inputs
- Design: none
- API: none — `currency` is already in the cart and order responses

## Affected Files
- src/lib/formatPrice.ts - optional `currency` argument, one cached formatter per currency
- src/lib/formatPrice.test.ts - currency cases
- callers of `formatPrice` (below) - pass the cart's / order's currency

## Design Check
- Reuse: existing `formatPrice` and `CurrencyCode`; no new formatting helper
- Responsibility: `formatPrice` formats; callers pick the currency from their data
- Risk: none
- Callers/Consumers: `formatPrice` → src/components/CartSummary/CartSummary.tsx, src/components/OrderRow/OrderRow.tsx, src/lib/receipt.ts
- Pattern: src/lib/formatPrice.ts
- Tests: src/lib/formatPrice.test.ts (extend)

## Execution Steps
- Step 1: developer - `formatPrice` + tests, then update every caller
- Step 2: test-runner
- Step 3: reviewer

## Branch
feat/price-currency
