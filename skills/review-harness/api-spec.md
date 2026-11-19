If triggered, ask once in user's language:
> "Do you have an API spec? (Swagger/OpenAPI URL, GraphQL schema, a `.md`/`.yaml` file, or paste the endpoint)"

| Response | Action |
|----------|--------|
| URL or file | Record in `plan.md → Inputs.API`; fetch on demand in `developer` only |
| Endpoint/query pasted | Record as-is in `plan.md → Inputs.API` |
| None | Ask: "What request/response shape do you expect?" — record described shape |

**Pasted Contract (any intent, trigger or not)**: a `## Contract` block from the producer repo's run is always the spec — record it as-is in `plan.md → Inputs.API` and ask nothing more.

**Token budget:**
- Pass API spec only to `developer` — never to others (reviewer sees resulting code, not the spec)
- If URL provided, `developer` fetches only relevant endpoint(s) on demand
