# Profile: web-api

> **Stack profile**: rules for HTTP / realtime API servers (e.g. NestJS, Express, Fastify, FastAPI) and their data layer (e.g. Prisma, TypeORM, Mongoose, SQL migrations). Every gate comes from a real bug fix. They are part of the agent's instructions whenever the profile is passed.
> Loaded via `bash hooks/extract-constraints.sh <agent-name> web-api`, which appends the sections below for that agent as a `## Profile — web-api` block. Never inline the full file. Text above the first `## #tag` heading is never extracted.
>
> | Section tag | Target agents |
> |-------------|---------------|
> | `#review` | reviewer; developer (as its review checklist) |

## #review

Static review gates — FAIL if any:

**Errors**
- Global exception filter / error middleware that logs or alerts without writing a response (the request hangs until the proxy times out) → FAIL `[correctness]` — a filter that delegates (`next(err)`, `super.catch`) passes

**Data integrity**
- Read-then-create/save on the same key without upsert, an atomic conditional update, a transaction or unique-violation handling that returns 409 → FAIL `[correctness]` — unless the path is single-writer by construction (seed, migration, one-off script)
- Transaction callback (`$transaction(async (tx) => …)`, `session.withTransaction`, `queryRunner`) whose body calls data-access code that does not receive the transaction client/session → FAIL `[correctness]`
- skip/limit pagination ordered only by a non-unique field (e.g. `createdAt`) with no unique tiebreaker → FAIL `[correctness]`

**Access**
- Lookup or write by a client-supplied id on a user-owned model without an owner predicate or explicit ownership check; new query on a soft-delete model without the deleted filter → FAIL `[security]` — unless a visible guard limits the route to admins or the record is public by design; the soft-delete half passes with an ORM-level global filter or for a restore/audit query

**Contract**
- Renamed or removed route, socket event or response field (incl. a case-style change or a field dropped from an ORM `select`), or a response field made optional/nullable, without keeping the old shape → FAIL `[contract]` — if the break is intended, the plan's `## Contract` or the PR description lists every consumer and this gate passes

**Realtime and ops**
- Socket gateway that targets a user through an in-process map of sockets or an in-memory timer that targets a user's socket instead of an adapter-backed room; `server.emit` to all sockets for user-scoped data → FAIL `[correctness]` (breaks with more than one instance)
- Migration that drops a column/table in the same migration that introduces its replacement (generated or not); hand-written or hand-edited DDL (`ADD VALUE`, `CREATE INDEX`) lacking `IF NOT EXISTS` where the engine supports it → FAIL `[ops]`
- Bootstrap or module-load `throw`, or unguarded `JSON.parse(process.env.X)`, for an env var used by one optional feature (the whole server fails to start) → FAIL `[ops]`
