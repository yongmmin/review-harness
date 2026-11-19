# Profile: web-common

> **Stack profile**: rules for a change that touches both frontend and API code (selected together with `web-frontend` and `web-api`). Every gate comes from a real bug fix. They are part of the agent's instructions whenever the profile is passed.
> Loaded via `bash hooks/extract-constraints.sh <agent-name> web-common`, which appends the sections below for that agent as a `## Profile — web-common` block. Never inline the full file. Text above the first `## #tag` heading is never extracted.
>
> | Section tag | Target agents |
> |-------------|---------------|
> | `#review` | reviewer; developer (as its review checklist) |

## #review

Static review gates (frontend + API in one change) — FAIL if any:

**Contract**
- Consumer of a route, event or field renamed, removed or made nullable in the same change set is not updated → FAIL `[contract]`
- Frontend request adds a custom header or `withCredentials` that the API's CORS config (allowed headers, credentials) does not allow → FAIL `[contract]`
- Frontend branches on an exact status code for an endpoint whose status mapping changes in the same diff → FAIL `[contract]`

**Config**
- Env URL that has a host but no scheme (`api.example.com/v1` instead of `https://api.example.com/v1`), or a key added or renamed in this diff that is missing from another environment block or file → FAIL `[ops]`
