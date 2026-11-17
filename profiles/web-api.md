# Profile: web-api

> **Stack profile**: rules for HTTP / realtime API servers (e.g. NestJS, Express, Fastify, FastAPI) and their data layer (e.g. Prisma, TypeORM, Mongoose, SQL migrations). Every gate comes from a real bug fix. They are part of the agent's instructions whenever the profile is passed.
> Loaded via `bash hooks/extract-constraints.sh <agent-name> web-api`, which appends the sections below for that agent as a `## Profile — web-api` block. Never inline the full file. Text above the first `## #tag` heading is never extracted.
>
> | Section tag | Target agents |
> |-------------|---------------|
> | `#implementation` | developer |
> | `#review` | reviewer |

## #implementation

- **Errors**: client errors map to 4xx (not found 404, not owner 403/404, invalid input 400, duplicate 409); error bodies carry a fixed message, never `err.message`, ORM error details or subprocess output
- **Validation**: validate every route/query param and request body (parse pipe or schema); bound skip/offset (`>= 0`) and limit (max); validate arrays, nested objects and dates explicitly
- **Write after read**: upsert, an atomic conditional update or a transaction for read-then-write on the same key; pass the transaction client/session to every call inside it
- **Promises**: await, return or `.catch` every promise in handlers, crons and listeners; no `async` callback in `forEach`
- **Access**: scope every lookup of a user-owned record by its owner, and every query on a soft-delete model by the deleted filter
- **Contracts**: change routes, socket events and response fields additively; when a break is intended, list every consumer in the plan's `## Contract`

## #review

Static review gates — FAIL if any:

**Errors and validation**
- Not-found, ownership or invalid-input branch in a request path throws a 500-class exception or a bare `Error` (instead of a 4xx such as `NotFoundException` / `HTTPException(404)`) → FAIL `[correctness]`
- Route/query param used as a number, ObjectId or UUID without a parse pipe (`ParseIntPipe`, `ParseUUIDPipe`), schema validator or validity check (`isValidObjectId`) → FAIL `[correctness]`
- Request schema gap (class-validator DTO, Pydantic, zod): array checked only by `@IsNotEmpty`; skip/offset without `@Min(0)`; limit without `@Max`; nested object without `@ValidateNested` + `@Type`; Date without `@Type(() => Date)`; `@IsOptional` while the API docs say `required: true` → FAIL `[correctness]`
- Error response that interpolates `err.message`, an ORM error `code`/`meta`, subprocess stderr, ids of records the caller does not own, or a configured allowlist → FAIL `[security]`
- Global exception filter / error middleware that logs or alerts without writing a response (the request hangs until the proxy times out) → FAIL `[correctness]` — a filter that delegates (`next(err)`, `super.catch`) passes

**Data integrity**
- Read-then-create/save on the same key without upsert, an atomic conditional update, a transaction or unique-violation handling that returns 409 → FAIL `[correctness]` — unless the path is single-writer by construction (seed, migration, one-off script)
- Transaction callback (`$transaction(async (tx) => …)`, `session.withTransaction`, `queryRunner`) whose body calls data-access code that does not receive the transaction client/session → FAIL `[correctness]`
- Promise in a handler, cron or event/socket listener that is not awaited, returned, or `void`-ed with a `.catch`; `async` callback passed to `forEach` → FAIL `[correctness]` (an unhandled rejection can stop the process)
- skip/limit pagination ordered only by a non-unique field (e.g. `createdAt`) with no unique tiebreaker → FAIL `[correctness]`

**Access**
- Lookup or write by a client-supplied id on a user-owned model without an owner predicate or explicit ownership check; new query on a soft-delete model without the deleted filter → FAIL `[security]` — unless a visible guard limits the route to admins or the record is public by design; the soft-delete half passes with an ORM-level global filter or for a restore/audit query
- User input in `$where`, or in `$regex` / `new RegExp` without escaping → FAIL `[security]`
- Authorization decided from the `Host`, `Origin` or `X-Forwarded-For` header → FAIL `[security]`
- CORS `origin: true` / `'*'` (HTTP or Socket.IO server) together with credentials; cookie `sameSite: 'none'` without `secure: true` → FAIL `[security]`

**Contract**
- Renamed or removed route, socket event or response field (incl. a case-style change or a field dropped from an ORM `select`), or a response field made optional/nullable, without keeping the old shape → FAIL `[contract]` — if the break is intended, the plan's `## Contract` or the PR description lists every consumer and this gate passes

**Realtime and ops**
- Socket gateway that targets a user through an in-process map of sockets or an in-memory timer that targets a user's socket instead of an adapter-backed room; `server.emit` to all sockets for user-scoped data → FAIL `[correctness]` (breaks with more than one instance)
- Migration that drops a column/table in the same migration that introduces its replacement (generated or not); hand-written or hand-edited DDL (`ADD VALUE`, `CREATE INDEX`) lacking `IF NOT EXISTS` where the engine supports it → FAIL `[ops]`
- Bootstrap or module-load `throw`, or unguarded `JSON.parse(process.env.X)`, for an env var used by one optional feature (the whole server fails to start) → FAIL `[ops]`
