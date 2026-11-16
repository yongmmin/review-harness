# Planted-bug benchmark

Measures whether the reviewer reports a known bug as a FAIL, and how many other FAIL findings it adds, with the
rules of three plugin revisions. Each case is a tiny git repo whose uncommitted change holds exactly one planted
bug in otherwise reasonable code (a reviewer may still raise a minor real issue elsewhere; those count as extra findings).

## Cases

| Case | Planted bug | Expected rule |
|------|-------------|---------------|
| `fe-effect-cleanup` | `useEffect` starts an interval and a listener with no cleanup | web-frontend: effect without cleanup |
| `fe-zustand-whole-store` | memoised list row subscribes to the whole Zustand store | web-frontend: whole-store subscription |
| `api-notfound-500` | missing record throws `InternalServerErrorException` | web-api: not-found as 500 |
| `api-unawaited` | audit-log write in a request path is not awaited | web-api: floating promise |
| `api-no-owner` | note read/update by client id with no owner predicate | web-api: owner predicate |
| `x-removed-field` | response field renamed; a web consumer in the same repo still reads the old name | web-common / web-api: contract |

`cases/<id>/expect.txt`: line 1 = expected rule, line 2 = `|`-separated lowercase keywords a correct finding
contains, line 3 = the file the bug is in (`|` separates acceptable files).

## Arms

| Arm | Revision | Rules given to the reviewer |
|-----|----------|-----------------------------|
| `pre-split` | `9c81361` | reviewer agent + generic constraints (frontend gates lived in the agent file) |
| `pre-stage4` | `53dd721` | reviewer agent + constraints + profiles chosen by that revision's `detect-profile.sh` (web-frontend only) |
| `current` | `HEAD` | same as `pre-stage4` with HEAD's files (web-frontend, web-api, web-common) |

`prompt.sh` unpacks the revision with `git archive` into a temp dir under `$TMPDIR` and runs its own scripts with
an empty `REVIEW_HARNESS_HOME`, so no organisation overlay reaches the prompt. The prompt never comes from an
installed agent definition, so an arm is the same text on every machine.

## Run

```bash
export TMPDIR=<scratch dir>/w          # any path whose names do not start with `bench` or name a case
RES=<scratch dir>/r; mkdir -p "$TMPDIR" "$RES"
FX=$(mktemp -d "$TMPDIR/review.XXXXXX")                         # opaque fixture dir, one per case
bash bench/cases/<id>/setup.sh "$FX"                            # fixture repo, base + uncommitted change
bash bench/prompt.sh <arm> "$FX" > "$RES/<id>.<arm>.prompt.md"
# spawn a general-purpose agent on the production reviewer model and give it that prompt: paste its content,
# or copy it to an opaque name (e.g. q07.md) in a directory holding nothing else and give that path.
# Never a path that names the case or arm. Save its reply to "$RES/<id>.<arm>.out.md"
bash bench/score.sh bench/cases/<id>/expect.txt "$RES/<id>.<arm>.out.md"   # caught|missed extra=N
```

The reviewer must not learn the answer from anything it can see: the fixture path is opaque, the fixture's git
author, commit message and reflog are neutral, `expect.txt` stays in this repo, and prompts and outputs (whose
names carry the case id) live in `$RES`, outside the fixture dir. Keep a `<id>` → `$FX` note in `$RES` if needed.

`setup.sh` refuses a non-empty directory; use a fresh one per case. One fixture can serve all arms because the
reviewer is told not to edit files. Read every output by hand; `score.sh`'s `caught` / `extra=N` are a first pass
and `extra` is a lower bound (an extra finding that names the bug's file and a keyword counts as the match).

## Results

### Run 1 (before the method fixes)

This run predates the fixes above, so its detection numbers may be inflated: the fixture path named the case
(e.g. `.../fx/api-unawaited`) and was written into every prompt, and `api-no-owner` held a second, unintended bug
(`@IsOptional()` on non-nullable columns let `null` through). The table is kept as recorded.

Model: Fable (production reviewer model) · Date: 2026-11-16 · Plugin HEAD: `4c6d507` · One run per cell · Empty home (no org overlay)

| Case | pre-split | pre-stage4 | current |
|------|-----------|------------|---------|
| `fe-effect-cleanup` | caught, 0 | — | caught, 0 |
| `fe-zustand-whole-store` | caught, 0 | — | caught, 0 |
| `api-notfound-500` | — | caught, 1 | caught, 0 |
| `api-unawaited` | — | caught, 1 | caught, 0 |
| `api-no-owner` | — | caught, 2 | caught, 1 |
| `x-removed-field` | — | caught, 0 | caught, 1 |

Cell: `caught` / `missed`, extra FAIL findings counted by reading each output (`score.sh` counts an extra finding that names the bug's file and a keyword as matching, so it undercounts).

What the extra findings were:
- `pre-stage4`, all three API cases: "no test added for the new branch" (3 times). `current` raised it 0 times.
- `api-no-owner`, both arms: `@IsOptional()` lets `null` through to a non-nullable column (a real bug, and one of the mined patterns).
- `x-removed-field`, `current`: the rename itself, under the contract gate (`fullName` dropped without keeping the old shape). This is the gate working as written, not noise.

Reading:
- **Detection: no difference.** Every arm caught every planted bug (possibly inflated, see above), so these cases are too easy for this model to show what the rules add. The split (stage 2) did not lose any frontend catch.
- **Noise: fewer extra findings in `current`** (0 "missing test" FAILs against 3 in `pre-stage4`). The arms are whole revisions, not just the `web-api` profile, so this does not isolate the profile; whether a missing-test finding is noise is a judgement. One run per cell, so this may be chance.
- `pre-split` filed the Zustand finding under `react-perf` because its Output Format allowed only four categories while its own gate said `[state-mgmt]`; `current` used `state-mgmt`.

### Run 2 (clean method)

Model: Fable (production reviewer model) · Date: 2026-11-16 · Plugin HEAD: `4c6d507` · One run per cell · Empty home (no org overlay) · Opaque fixture dirs · 12 cells spawned in parallel · Each agent was given the path of an opaquely named prompt file (`qNN.md`) and wrote its own output file (`aNN.md`); the transcripts show each read only its own prompt and its fixture

| Case | pre-split | pre-stage4 | current |
|------|-----------|------------|---------|
| `fe-effect-cleanup` | caught, 0 | — | caught, 0 |
| `fe-zustand-whole-store` | caught, 0 | — | caught, 0 |
| `api-notfound-500` | — | caught, 0 | caught, 0 |
| `api-unawaited` | — | caught, 0 | caught, 0 |
| `api-no-owner` | — | caught, 1 | caught, 0 |
| `x-removed-field` | — | caught, 0 | caught, 1 |

Extra findings (read by hand):
- `api-no-owner`, `pre-stage4`: the check-then-update pair can raise Prisma P2025 → 500 if the row is deleted in between (a real, minor issue).
- `x-removed-field`, `current`: the API-side rename itself, under the contract gate. Same as run 1.

Reading (both runs):
- **Detection: 12 of 12 in both runs, with and without the leak.** These cases are too easy for this model to show what the rules add; they only show nothing was lost. The stage-2 split lost no frontend catch.
- **The run-1 "missing test" findings did not recur** (0 in run 2), so the noise difference in run 1 was chance or an effect of the method change between runs; the two cannot be separated.
- **One consistent difference:** with `web-common`/`web-api` loaded, the reviewer also flags the API-side rename that breaks consumers (2 of 2 runs), not only the stale consumer. That is the contract gate (mined from 12 cross-repo breaks) doing what it says.

Next: subtler cases (a bug the model misses without the rule) and three runs per cell before drawing conclusions about detection.
