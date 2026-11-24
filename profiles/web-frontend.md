# Profile: web-frontend

> **Stack profile**: rules for React / Next.js / TypeScript web frontends (Tailwind, Zustand, TanStack Query, Socket.IO). They are part of the agent's instructions whenever the profile is passed.
> Loaded via `bash hooks/extract-constraints.sh <agent-name> web-frontend`, which appends the sections below for that agent as a `## Profile — web-frontend` block. Never inline the full file. Text above the first `## #tag` heading is never extracted.
>
> | Section tag | Target agents |
> |-------------|---------------|
> | `#code-rules` | developer, refactor-architect |
> | `#implementation` | developer |
> | `#review` | reviewer; developer (as its review checklist) |
> | `#detection` | refactor-architect |

## #code-rules

- No `any`. Explicit TS types required
- No inline styles. Tailwind classes or CSS modules only

## #implementation

- **TypeScript required** — explicit types, no `any`

### Framework Priority

1. Vitest (Next.js 14+)
2. Jest + RTL
3. Playwright (E2E)

### Implementation Rules

- Functional components only
- Extract logic into custom hooks (`use` prefix)
- try/catch + error boundaries

### File Structure

```
components/[Name]/
├── index.tsx
├── [Name].tsx
└── [Name].test.tsx

hooks/
└── use[Name].ts
```

### TypeScript Checklist

- [ ] Props types defined
- [ ] API response types defined
- [ ] No `any`

### API Integration — Rules

- All HTTP through the repo's internal axios wrapper / service layer — never bare `fetch`/`axios` from components
- Auth state via the repo's existing auth hook — never create a duplicate polling hook
- FormData: never set Content-Type manually (boundary breaks). DELETE with body: `{ data }` config option, not `params`
- Check the repo's query-hook directory (e.g. `hooks/queries/`) for an existing matching feature hook before writing a new one

### TanStack Query

- Query keys as `*_KEYS` constants in `hooks/queries/<feature>.ts`; mutations colocated in the same file
- Explicit response/error types per query/mutation. Invalidate specific keys over blanket `invalidateQueries()`
- Default staleTime per app convention

```typescript
// hooks/queries/order.ts
export const ORDER_KEYS = {
  all: ['order'] as const,
  list: (userId: number) => [...ORDER_KEYS.all, 'list', userId] as const,
}

export function useOrderListQuery(userId: number) {
  return useQuery({
    queryKey: ORDER_KEYS.list(userId),
    queryFn: () => api.orders.list(userId),
    staleTime: 30 * 60 * 1000,  // per app convention
  })
}
```

- Raw fetch hooks only where neighbor files already use the legacy pattern
- Server Actions only for reactivity-free form submits AND when the repo's `.claude/CLAUDE.md` confirms they're in use
- No new HTTP libraries — standardized on axios + TanStack Query

### Socket.IO

- Module-level singleton, namespaced — never create connection inside component render
- Events typed in the repo's shared socket event-type file (exhaustive union). Adding an untyped event is a FAIL
- Echo-prevention guard for sync flows that re-emit on state change
- Disconnect/reconnect handling per app pattern — check neighbor before adding a new namespace

### Framework Rules

- **`'use client'`** on every component using hooks/browser APIs; heavy 3D/LiveKit and other browser-only imports via `dynamic({ssr:false})`
- **Zustand**: selector-only subscriptions. No whole-store object subscriptions. Version `persist` on schema change
- **Tailwind**: check the repo's Tailwind major version before writing classes or config (v3: `tailwind.config.*` is the spec; v4: `@theme` in CSS + `@source` for libs)

## #review

React performance — FAIL if any:
- `useEffect` missing dep or unstable ref causing infinite loop
- Inline object/function literal as prop without `useMemo`/`useCallback`, or `React.memo` absent on a pure component with stable props re-rendered from parent — only on a measured or obviously hot path (list item in a large list, per-frame/animation callback, high-frequency input); elsewhere not a FAIL
- `useMemo`/`useCallback` wrapping primitive or trivially cheap expression
- Sync blocking op (sort/filter/heavy compute on large array) in render path without memo

Review scope:
- TypeScript correctness (no `any`, optional-chain guards, null safety)
- React/Next.js correctness (`'use client'` boundary, `dynamic({ssr:false})` for browser-only)
- React performance (useEffect deps, memo placement, stable refs)

Static review gates — FAIL if any:

**Code conventions**
- Manual Content-Type on Axios FormData → FAIL (boundary breaks)
- Raw hex/rgba color in production code when the app already imports design-system tokens → FAIL `[design]` (use the token)

**React / Next**
- Missing `'use client'` on component using hooks/browser APIs → FAIL `[correctness]`
- `useEffect` that adds a subscription/timer/listener without returning a cleanup → FAIL `[performance]`
- Array index as `key` on a list that can reorder, insert, or delete → FAIL `[performance]` (use a stable id)

**State management**
- Whole-store Zustand subscription on hot path → FAIL `[state-mgmt]`
- Inline object selector creating new ref each render (without `shallow`) → FAIL `[state-mgmt]`
- `persist` middleware schema change without version bump → FAIL `[state-mgmt]`
- Server state (API response data) kept in a Zustand store when the repo uses TanStack Query for server state → FAIL `[state-mgmt]` (exception: `setQueryData` pre-cache)
- Untyped socket event (not in the repo's shared socket event-type file) → FAIL `[correctness]`
- Duplicate auth/polling hook created when one already exists → FAIL `[scope]` (reuse existing)

**Accessibility**
- Icon-only button without an accessible name (`aria-label` or visible text) → FAIL `[correctness]`
- Clickable element that cannot be operated by keyboard (e.g. `onClick` on a non-interactive element with no key handler, role and `tabIndex`) → FAIL `[correctness]`

## #detection

Categorize:
   - Duplicate UI → component extraction candidate (check the design system first — maybe the primitive belongs there)
   - Duplicate logic → custom hook candidate
   - Duplicate state shape → Zustand slice candidate

Detection targets:
- Same JSX structure in 3+ places
- Same state pattern (loading/error/data) repeated → candidate for `useAsyncData` hook
- Inline styles or class strings repeated → candidate for component + Tailwind utility class
- Same Zustand slice shape duplicated → store consolidation
- Same Socket.IO event handling boilerplate → custom hook wrapper
