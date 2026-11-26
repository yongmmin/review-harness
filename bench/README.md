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
| `goal-not-wired` | plan: a status filter on the orders page. The diff adds the hook and the select with passing tests; the page never uses them | reviewer goal gate: `[goal]` (Done When unmet, export with no caller) |
| `bug-cause-elsewhere` | plan `## Bug`: the `Cause` is a store action that mutates and returns the same array. The diff patches the symptom component instead (its regression test passes); other subscribers stay stale | reviewer bugfix gate: `[scope]` / `[correctness]` against `Cause` |
| `contract-caller-missed` | plan `Callers/Consumers` lists 3 callers of a function whose signature grows an optional argument; the diff updates 2, the third is neither changed nor marked | reviewer contract gate: `[contract]` |

`cases/<id>/expect.txt`: line 1 = expected rule, line 2 = `|`-separated lowercase keywords a correct finding
contains, line 3 = the file the bug is in (`|` separates acceptable files), optional line 4 = `|`-separated
categories the matching finding should carry (`score.sh` then adds `category=match|other`).

### Plan-based cases

The last three cases are built so that the diff alone looks fine: what is wrong is only visible against the plan
(`Done When`, `## Bug → Cause`, `Callers/Consumers`). They are the cases a reviewer is likely to miss without the
plan gates and without the plan. Each ships `plan.md` and a `handoff.md` (the developer's handoff lines, e.g.
`test_status`, `red:`). Given the case dir as a third argument, `prompt.sh` copies `plan.md` to `<fixture>.plan.md`
(as opaque as the fixture path) and appends `## Handoff` with `- plan_path: <that file>` and the handoff lines, the
way `/review-harness` passes them. Without the case dir the prompt has no plan, which is the "no plan context" cell.

## Arms

| Arm | Revision | Rules given to the reviewer |
|-----|----------|-----------------------------|
| `pre-split` | `9c81361` | reviewer agent + generic constraints (frontend gates lived in the agent file) |
| `pre-stage4` | `53dd721` | reviewer agent + constraints + profiles chosen by that revision's `detect-profile.sh` (web-frontend only) |
| `current` | `HEAD` | same as `pre-stage4` with HEAD's files (web-frontend, web-api, web-common) |

Cells for the plan-based cases: `pre-stage4` with the case dir (a plan, but the rules from before the goal,
bugfix and contract gates; its plan gate reads only `Reuse`), `current` without the case dir (the rules, no plan),
`current` with the case dir. The difference between the first and the last isolates the rules; between the second
and the last, the plan context.

`prompt.sh` unpacks the revision with `git archive` into a temp dir under `$TMPDIR` and runs its own scripts with
an empty `REVIEW_HARNESS_HOME`, so no organisation overlay reaches the prompt. The prompt never comes from an
installed agent definition, so an arm is the same text on every machine.

## Run

```bash
export TMPDIR=<scratch dir>/w          # any path whose names do not start with `bench` or name a case
RES=<scratch dir>/r; mkdir -p "$TMPDIR" "$RES"
FX=$(mktemp -d "$TMPDIR/review.XXXXXX")                         # opaque fixture dir, one per case
bash bench/cases/<id>/setup.sh "$FX"                            # fixture repo, base + uncommitted change
bash bench/prompt.sh <arm> "$FX" > "$RES/<id>.<arm>.prompt.md"   # plan-based cell: add bench/cases/<id> as a 3rd arg
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

**Three runs per cell** for every new result: spawn the same prompt three times (three fresh agents, three output
files `<id>.<arm>.<n>.out.md`) and report the cell as `caught k/3`, extra findings summed over the three. One run
per cell (runs 1 and 2 below) cannot separate an effect from chance.

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

Model: Fable (production reviewer model) · Date: 2026-11-16 · Plugin HEAD: `4c6d507` · One run per cell · Empty home (no org overlay) · Opaque fixture dirs · 12 cells spawned in parallel · Each agent was given the path of an opaquely named prompt file (`qNN.md`) and wrote its own output file (`aNN.md`); the transcripts show each read only its own prompt and its fixture. Deviations from the recipe: the prompt directory also held the other cells' prompts and outputs and a copy of the plugin files, and the case-to-fixture map sat one level up; no agent listed or read them. One agent ran `ls` on the plugin's state directory, which returned nothing

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

### Run 3 (plan-based cases)

Model: Fable (production reviewer model) · Date: 2026-11-17 · Plugin HEAD: `a7ab0e8` · **One run per cell** (below the three this README asks for — read it as a first look) · Empty home · Opaque fixture dirs and prompt names; for the no-plan cells the plan files were moved out of the fixtures' parent folder

| Case | pre-stage4 + plan | current + plan | current, no plan |
|------|-------------------|----------------|------------------|
| `goal-not-wired` | caught, `[correctness]` | caught, `[goal]` | caught, `[design]` (+ 1 extra) |
| `bug-cause-elsewhere` | caught, `[correctness]` + `[scope]` | caught, `[correctness]` + `[scope]` + `[goal]` | caught, `[correctness]` |
| `contract-caller-missed` | caught, `[correctness]` | caught, `[contract]` | caught, `[correctness]` |

Extra findings: every finding in the plan cells was about the planted problem. The no-plan `goal-not-wired` cell added a second FAIL issue, `[correctness]`: once wired, a filter with no matches would show "No orders yet." — a real edge case, but not the planted problem.

Reading:
- **Detection: 9 of 9.** These cases are also within this model's reach from the diff alone.
- **What the plan and the new gates change is the footing of the FAIL, not detection.** With the plan, the reviewer cites Done When / Callers and uses the intended category 3 of 3 (`current`) against 1 of 3 (`pre-stage4`). Without the plan, the unwired-feature FAIL rests on a design judgement ("no production caller"), and the review offers "or drop the files from this change" as an equal fix; in its reply outside the review block, that reviewer added that the verdict would flip to PASS if the wiring were deliberately a later change — a FAIL a developer could argue away.
- The larger effect — whether the plan makes the developer wire it in the first place — needs the developer-side bench below.

### Run 4 (after thinning the reviewer rules)

Model: Fable (production reviewer model) · Date: 2026-11-24 · Plugin HEAD: `4c6a187` · **Three runs per cell** · Empty home · Opaque fixture dirs (one per run) and prompt names · `current` arm only; the plan-based cases with their plan

This run checks one thing: did cutting the rule text lose a catch? Between run 3 and this revision `agents/reviewer.md` went from 10.5 to 8.0 KB, `constraints.md` from 4.6 to 2.5 KB and the three profiles from 13.6 to 6.5 KB. The rules named for three of the cases are gone from the profiles: effect without cleanup, not-found as 500, floating promise.

| Case | caught | Rule still in the profile | FAIL category (3 runs) |
|------|--------|---------------------------|------------------------|
| `fe-effect-cleanup` | 3/3 | removed | `[correctness]` ×3 |
| `fe-zustand-whole-store` | 3/3 | kept | `[state-mgmt]` ×3 |
| `api-notfound-500` | 3/3 | removed | `[correctness]` ×3 |
| `api-unawaited` | 3/3 | removed | `[correctness]` ×3 |
| `api-no-owner` | 3/3 | kept | `[security]` ×3 |
| `x-removed-field` | 3/3 | kept | `[contract]` ×3 (run 1 also `[correctness]` for the stale consumer) |
| `goal-not-wired` | 3/3 | plan gate | `[goal]` ×3 |
| `bug-cause-elsewhere` | 3/3 | plan gate | `[correctness]` + `[scope]` ×3 |
| `contract-caller-missed` | 3/3 | plan gate | `[contract]` ×3 |

Reading:
- **Detection: 27 of 27.** Nothing was lost, including the three cases whose rule was deleted. As in runs 1–3 this shows no loss; it cannot show a gain.
- **Footing kept:** the plan-based cases carry the intended category 9 of 9.
- **Extra findings:** every `patch` issue was about the planted problem (two issues where it has two sites: read and write without an owner predicate; the rename and its stale consumer). `score.sh` counted one extra finding (`bug-cause-elsewhere`, run 2); read by hand it is the planted problem's `[scope]` half. Other observations came as `defer` notes (15 over 27 runs, e.g. no test for the new path, a read-then-update race), which never make a FAIL.
- Each run took about 75K tokens and 15–30 seconds.

Departures from the recipe: `prompt.sh` writes its temp home as `rh-bench.*`, so the `ledger:` path in every prompt held the word `bench`; it was replaced with a neutral path before the agents ran. The reviewer file's evidence scripts could not run in most cells (`CLAUDE_PLUGIN_ROOT` is unset in a bare prompt), so the reviews rest on the diff and files; one agent reported running `static-gates.sh` and `repo-rules.sh`, which it can only have found in an installed copy of the plugin. Nine outputs (run 1 of each case) were read by hand; the other eighteen were scored by `score.sh` plus an extraction of categories and routes.

## Developer-side bench

The cases above measure only the reviewer. A developer-side case measures the whole loop: `claude -p` gets an issue
text in a throwaway fixture and works it end to end; hidden tests it never sees decide whether it solved it. No
model is called by the scripts' tests (`tests/run.sh` puts a stub `claude` on `PATH`).

### Cases

`cases-dev/<id>/`: `setup.sh` builds the fixture at its base commit (no uncommitted change; `bench_node` in `lib.sh`
is a zero-dependency Node 20 skeleton, so no install or network), `task.md` is the issue text, `accept/*.test.js`
are the hidden tests, `solution.patch` / `trap.patch` are a correct answer and a plausible wrong one (`git apply` on a
fresh fixture), and `trap.md` says which plan line should prevent the trap. The fixture, its git metadata, its path
and `task.md` never contain the case id, `bench`, `accept`, `solution` or `trap`.

| Case | Task | Trap |
|------|------|------|
| `dev-unwired` | a status filter on `GET /orders`, with paging and a 400 for an unknown status | validation, filter and a unit test, but the route's query allowlist still rejects `status`: every real request is a 400 |

### Arms

| Arm | What runs |
|-----|-----------|
| `plain` | `claude -p "<task.md>"`, no plugin |
| `harness` | `claude -p "/review-harness:review-harness <task.md>" --plugin-dir <copy>`, the copy being a `git archive HEAD` copy of the plugin's runtime files only (`.claude-plugin`, `agents`, `hooks`, `skills`, `profiles`, `constraints.md`) |

### Run

```bash
export TMPDIR=<scratch dir>/w        # a neutral path: dev-run.sh refuses one naming the benchmark or the case
bash bench/dev-run.sh <plain|harness> bench/cases-dev/<id> <results>/<opaque name>
```

Needs `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) in the environment: the run uses its own
`CLAUDE_CONFIG_DIR`, so a normal login is not visible to it.

Every call is `--model opus --output-format json --permission-mode bypassPermissions --disallowedTools
AskUserQuestion --max-budget-usd <budget left>`. A reply whose last 400 characters hold a `?` or an approval cue
(`approve`, `approval`, `confirm`, `go ahead`, `shall I`, `should I`, `let me know`, as whole words in any case) gets
a user-proxy answer through `--resume` ("Approved. Go ahead.", then "use your best judgement"), at most 4 replies.
`total_cost_usd` of a resumed call is the session's running total, so the budget left is the budget minus the
latest value.

| Variable | Default | Meaning |
|----------|---------|---------|
| `DEV_BENCH_BUDGET_USD` | `15` | cost cap over all calls; reached → `aborted: "cost"` |
| `DEV_BENCH_TIME_S` | `2700` | wall-time cap; the call's process group is killed → `aborted: "time"` |
| `DEV_BENCH_BARE` | unset | `1` → `--bare` instead of `--setting-sources project --strict-mcp-config` |

Isolation: the fixture, `CLAUDE_CONFIG_DIR` and `REVIEW_HARNESS_HOME` live in one temp dir removed after the run,
`REVIEW_HARNESS_RTK=off`, a neutral git identity, and the harness arm starts with `register-declined` so it does not
offer `/register-repo`. `claude` is taken from `PATH`. The out-dir gets `work/` (the finished fixture),
`driver/NN.json` (each call's output), `transcripts/`, and for the harness `runs.jsonl` and `plan.md`; `run.json`
holds `arm`, `case`, `plugin_rev`, `wall_s`, `user_replies`, `aborted`, `calls`. `<results>/map.tsv` maps the
opaque name to the case and arm.

### Score

```bash
bash bench/dev-score.sh bench/cases-dev/<id> <results>/<opaque name>    # one JSON line
```

The shell needs Node 20+: without it, or when the hidden tests report 0 tests, the script exits 2 with one stderr
line instead of printing a score.

Base test files changed (deleted, or lines removed) count as `tests_touched` and are put back before the tests run.
Then `accept` (`pass/tests` of the hidden tests, copied to `test/accept/`), `regressions` (failing base tests),
`cost_usd` (the largest `total_cost_usd` of the calls, which is the session's running total), tokens (the last
call's `modelUsage`, subagents included) and `turns` (driver outputs), `wall_s`, `user_replies`, `aborted`, the harness run log
(`attempts`, `verdicts`, `end`, `override`) and plan (`plan_callers`, `plan_done_when`, `plan_bug`), `test_runs`
(test commands in the transcripts) and `contaminated` (a transcript names this repo or the case's hidden files).
**Solved** = every hidden test passes, no regression, not aborted, a harness run not ended at `limit` or
`abandoned`, not contaminated.

### Spike

Answered by Run 1:
- `/review-harness:review-harness` runs under `-p` with `--plugin-dir`: the run log, the plan and a reviewer PASS
  were written.
- `total_cost_usd` includes subagents: the harness call's `modelUsage` lists the reviewer's model next to the main
  one, and the per-model costs add up to `total_cost_usd`. The top-level `usage` holds the main loop of that call
  only.
- `total_cost_usd` and `modelUsage` of a `--resume` call are running totals of the session; `usage` and `num_turns`
  are that call's own.
- With `AskUserQuestion` disallowed the harness asks for plan approval in plain text, often with no `?`.

Still open: does `--bare` keep `--plugin-dir` hooks; does `--max-budget-usd` count subagents and earlier calls of a
resumed session; whether anything calls `npx`.

### Results

#### Run 1 (2026-11-26, plugin rev `86e88d3`, Opus, `dev-unwired`, 3 runs per arm)

| Run | Result | Cost | Wall time | Replies |
|-----|--------|------|-----------|---------|
| plain ×3 | all solved (hidden tests 4/4, trap avoided) | $0.20–0.22 | 26–35 s | 0–1 |
| harness #1 | solved (reviewer PASS on the first review, 4/4) | $1.63 (main model $1.25, reviewer model $0.39) | 287 s | 2 |
| harness #2, #3 | **void**: stopped at plan approval, hidden tests 2/4 (the base state) | $0.35–0.36 | 45–51 s | 0 |

- Harness #2 and #3 are void because of the driver, not the harness: their plan messages ended "Approve the plan
  and I'll start." and "Please review the plan. Approve it and I will execute.", and the driver then answered only a
  `?`. It answers approval cues now.
- As first recorded, the costs read $0.20–0.41 (plain) and $3.47 (harness #1): the driver and the scorer added up
  the calls' `total_cost_usd`, which on a resumed call is already the running total. The table holds the re-scored
  values; the one harness run that finished cost about 8× and took about 9× a plain run.
- The first scoring pass printed `accept: "0/0"` for every run, because that shell had no Node 20. The scorer exits
  2 in that case now.
- **The case is too easy.** Plain Opus avoided the allowlist trap 3 times out of 3, so `dev-unwired` cannot show what
  the harness adds. A harder case, or the "A/B on real tasks" protocol below, is needed before any solve-rate claim.
- n = 1 valid harness run: no solve-rate or cost claim follows from this run. Next: rerun the harness arm 2–3 times
  with the fixed driver.

## A/B on real tasks

To compare plugin revisions on real work rather than planted bugs:

1. **Pick 15–20 tasks** from one repo's merged history: bug fixes and small features, each one PR or commit with
   its own tests and an issue or PR text that states the problem without the solution. Skip pure refactors,
   dependency bumps and changes without tests.
2. **Prepare each task**: a worktree at the commit's parent; the commit's test files are set aside as hidden
   acceptance tests (not in the worktree); the task prompt is the original issue text, unedited except for links
   that give the fix away.
3. **Arms**: plain Claude Code (plugin disabled), the current harness, the harness at a candidate revision (a
   branch checked out in the plugin folder; a new session per arm, since a session keeps the agent definitions it
   started with). Same model in every arm, and each arm's own `REVIEW_HARNESS_HOME` with the same content (empty, or the same org
   overlay and knowledge).
4. **Three runs per task per arm**, each in a fresh worktree and a fresh session; the order of arms shuffled.
5. **Measure** per run: hidden acceptance tests passing (all / some / none), new regressions (tests that passed at
   the base and fail after), attempts and reviewer FAILs, tokens, wall time, and whether the run needed a user
   override or stopped at the limit.
6. **Read `runs.jsonl` alongside**: point each harness arm at its own `REVIEW_HARNESS_HOME`, then
   `REVIEW_HARNESS_HOME=<arm home> bash hooks/run-stats.sh` gives attempts, FAIL rate, overrides and limit hits per
   arm (plain Claude Code writes no run log; take its attempts from the transcript). A run that ends `abandoned` or
   `limit` counts as not done whatever the tests say.
7. **Report** a table per arm (tasks solved k/n with hidden tests, regressions, median attempts, median tokens,
   median wall time) and the per-task cells, so one large task cannot hide behind a mean. With 15–20 tasks × 3
   runs, treat differences of one or two tasks as noise.
