# Shell hooks, scripts and tests

Standing rules for this plugin's shell scripts, hooks and tests, each taken from a past review failure in this repo.

## Gate design

- Allow a command on a "safe" flag only after reading the whole command literally with the real parser's rules (prefixes, `--no-<opt>`); otherwise treat it as a write - a guard that read part of the command let writes through.
- A scripted gate hard-FAILs only what its pattern proves; note the rest and count hits on a real repo first - a syntactic superset of a judgement rule FAILed correct code.
- Gate scripts share one change source (base branch argument or file list) - a no-argument mode that read only the uncommitted diff saw a committed branch as empty and reported "0 match".
- Every deny names a step that makes the retry pass; probe deny → documented next step → retry - a time-based deny pointed at a choice that wrote nothing the gate reads, so the agent reached for the bypass.

## Script contract

- Normalize paths typed by an LLM or user (`./`, absolute, backticks, commas, empty) and exit 2 when none is left - rules written for git-normalized paths silently matched nothing.
- A read-only fact script exits 2 with one stderr line when an internal step fails (unreadable file, temp file not creatable) - exit 0 read as "no findings".

## Git

- Pass `--no-renames` to `git diff --name-only` where old paths matter, and test a `git mv` - rename detection hid the old path.

## Locale and bytes

- Never put a byte cut (`${v:0:N}`, `cut -c` under `LC_ALL=C` or an unset locale) or other invalid UTF-8 upstream of a `while read` loop: export `LC_ALL=C` for the whole script or strip the partial tail (`iconv -c`), and test a multibyte line as the last record under a UTF-8 locale on Linux - bash 4+ swallowed the newline after a split character, dropping the last record and merging the next past its checks, while bash 3.2 and `LC_ALL=C` hid it.

## Scale

- No per-character loop over a line of unbounded length; split into short runs or cap it, and probe with a 1 MB one-line file - the loop hung.
- Feed path lists on stdin, never env or argv; dedupe before forking and cut the line before printing; probe with 3,000 untracked files on Linux and one line holding 1,000 links - Linux refuses an env string over 128 KB and output grew hits x line length.

## Output

- Keep raw any command whose output a gate or reviewer judges; probe with a 500+ line diff - a truncating or compacting filter hid what was judged.

## Tests

- A false-positive fix strips only the measured noise context and keeps one positive test per term the plan names - the fix deleted a planned term.
- Assert message text without the checkout and temp paths, and run the suite once from a copy under a 140+ byte path - a byte-length cap failed from a git worktree or long home folder.

## Metrics

- Split before/after metrics at the change's merge time and state n and confounders - a split by line order mixed the two periods.
