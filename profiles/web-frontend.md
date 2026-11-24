# Profile: web-frontend

> **Stack profile**: rules for React / Next.js / TypeScript web frontends (Tailwind, Zustand, TanStack Query, Socket.IO). They are part of the agent's instructions whenever the profile is passed.
> Loaded via `bash hooks/extract-constraints.sh <agent-name> web-frontend`, which appends the sections below for that agent as a `## Profile — web-frontend` block. Never inline the full file. Text above the first `## #tag` heading is never extracted.
> Only rules that depend on the repo's state, set a FAIL threshold, or name a trap no test catches belong here; general React and TypeScript knowledge does not.
>
> | Section tag | Target agents |
> |-------------|---------------|
> | `#code-rules` | developer, refactor-architect |
> | `#review` | reviewer; developer (as its review checklist) |

## #code-rules

- **Tailwind**: check the repo's Tailwind major version before writing classes or config (v3: `tailwind.config.*` is the spec; v4: `@theme` in CSS + `@source` for libs)

## #review

Static review gates — FAIL if any:

**React performance**
- Inline object/function literal as prop without `useMemo`/`useCallback`, or `React.memo` absent on a pure component with stable props re-rendered from parent — only on a measured or obviously hot path (list item in a large list, per-frame/animation callback, high-frequency input); elsewhere not a FAIL
- `useMemo`/`useCallback` wrapping primitive or trivially cheap expression

**Code conventions**
- Manual Content-Type on Axios FormData → FAIL (boundary breaks)
- Raw hex/rgba color in production code when the app already imports design-system tokens → FAIL `[design]` (use the token)

**State management**
- Whole-store Zustand subscription, or an inline object selector creating a new ref each render (without `shallow`), on a hot path → FAIL `[state-mgmt]`
- `persist` middleware schema change without version bump → FAIL `[state-mgmt]`
- Server state (API response data) kept in a Zustand store when the repo uses TanStack Query for server state → FAIL `[state-mgmt]` (exception: `setQueryData` pre-cache)
- Untyped socket event (not in the repo's shared socket event-type file) → FAIL `[correctness]`
