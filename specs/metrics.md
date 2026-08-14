# Spec: token-usage metrics

## PURPOSE

Where do her tokens go? Every CLI run already streams events that carry exact usage — input,
output, cache creation, cache reads, cost — and until now every one of those numbers died with
the stream file it arrived in. This spec owns the durable token ledger: one compact record per
CLI attempt, written by parsing artifacts the system already produces, and the two views over it
(`crab metrics` and the phone server's metrics page).

The binding constraint is that the tracking is LIGHTWEIGHT. Counting tokens must never spend
tokens: the whole path is pure parsing of files that already exist, and a ledger that cannot be
written costs the run that hosted it nothing.

This spec is about TOKENS. The per-stage timing log (`$METRICS_DIR/<date>.log`,
[turn-pipeline.md](turn-pipeline.md) rule 33) is a different record and is untouched here; the
two share a directory and nothing else.

## CONTRACT

### The ledger

1. The ledger lives under the metrics directory (`$METRICS_DIR`, default
   `~/.local/share/deskcrab/metrics/`), as one JSONL file per local day: `tokens-YYYY-MM-DD.jsonl`.
   The day is the record's own timestamp's day, so a run recorded just after midnight lands in the
   new day's file.
2. One record is one ATTEMPT — one CLI boot against one account. A run whose account walk made
   several attempts appends several records, each carrying `attempt` (1-based) and `attempts`
   (the walk's total), so a chain that walked itself dry is legible in the ledger as the separate
   refusals it was.
3. Every record MUST carry: `ts` (epoch), `kind` (the session kind), `model`, `effort`, `account`
   (the login's short name, `primary` for the primary), `account_n` (the login's 1-based position
   in the CONFIGURED chain — primary first, fallbacks in configured order — never its position in
   the rotated walk), `input`, `output`, `cache_create`, `cache_read`, `status`, and `src`
   (`live`, `stream-archive`, or `transcript`). When the stream carried them it also records
   `cost` (the CLI's own `total_cost_usd` share), `duration` (seconds), `sid` (the CLI session
   id), and `pid`.
4. The session kinds are: `turn` (desk), `phone`, `wake`, `job`, `summariser`, `memory-judge`,
   `ingest`, `chess`, `promise-audit`, `promise-check`, `claudism-mirror`, `claudism-scan`. A
   backfilled record whose kind cannot be told from its artifact carries the best approximation
   and `approx: true` — never a guess dressed as knowledge.
5. **NO MODEL CALL, ANYWHERE IN THE TRACKING PATH.** The ledger writer parses; it never asks. A
   change that makes any part of recording, backfill, reporting, or the metrics page invoke the
   CLI is wrong whatever it buys.
6. The ledger write is best-effort and silent: a malformed stream, a missing directory, a full
   disk, or a crashed parser MUST NOT change the exit status, output, or behaviour of the run
   that hosts it. The recorder always exits 0 on the `record` path.
7. Concurrent appends MUST NOT interleave: records are written whole, under an exclusive lock on
   the day file, because turns, wakes, and detached children finish together all day long.

### What gets parsed

8. Usage comes from the stream the run just wrote. The result event's totals win when present —
   its `modelUsage` split is preferred (one record per model), its `usage` object next. A result
   line with no usage (the caller's own terminator) is not a result.
9. When no usable result event exists in the attempt's slice (a cut, a crash, a reap), usage
   falls back to the assistant events, deduplicated by message id — the CLI repeats one message's
   usage across streamed deltas — summing across distinct messages, and the record carries
   `approx: true` (the message-level snapshot undercounts output).
10. Synthetic events carry no real usage and MUST NOT be summed: an assistant event flagged
    `is_api_error_message` or whose model is `<synthetic>` is the CLI talking, not the model.
11. A refused attempt is still recorded — the boot happened and the refusal is the fact the
    ledger exists to keep — tagged `status: refused`, with whatever usage its slice genuinely
    held (usually none). The statuses are: `ok`, `refused` (the CLI's own limit refusal, no
    genuine output), `cut` (genuine output, then the limit's error result), `error` (an error
    result that is not a limit), and they are judged from the CLI's own events exactly as
    [account-fallback.md](account-fallback.md) rules 12–12d demand — never by pattern-matching
    reply text. The type-less `is_error` result line the CLI has been observed to emit (rule 12d
    there) reads as the error result it is.
12. Attempts are found structurally: each CLI boot opens its stream slice with a
    `system`/`init` event, and the account-swap marker notes
    ([account-fallback.md](account-fallback.md) rule 24) name the accounts either side of each
    boundary. A stream with no init events at all is one attempt. When the markers cannot name
    an attempt's account, the caller's hint (the account the walk started on) covers a
    single-attempt stream, and an unknown stays `null` rather than becoming a guess.

### Who records

13. Every CLI invocation path appends to the ledger at the end of its run, from the stream it
    just wrote, before that stream is pruned or deleted: the desk turn and phone turn (one hook,
    in the shared generation walk), the wake chain, the detached job, the conversation
    summariser, the claudism mirror and the nightly claudism-scan rewrite pass, the promise
    audit, the promise checker, the memory judge, the memory ingest distiller, and the chess
    mover. A new invocation path added without a ledger hook is incomplete.
14. Paths that truncate a per-attempt scratch stream (the summariser, the promise audit, the
    promise checker) record each attempt inside their walk, before the truncation, or the
    refused attempts vanish.
15. The Python callers that used to run the CLI in plain text mode (the memory judge, the
    ingest distiller — and through them the claudism-scan rewrite pass — and the chess mover)
    ask for `--output-format json` so the run's own result object carries usage, and read their
    answer from its `result` field. A stdout that does not parse as that object (a stub, an
    older CLI) is treated as the whole answer exactly as before, and no record is written —
    degrading to the old behaviour is the fail-safe direction, in both the answer path and the
    ledger path.
16. `TOKEN_LEDGER=0` switches recording off. The default is on.

### Backfill

17. `crab metrics backfill` is a one-shot, approximate ingest of the surviving artifacts, so
    history starts at "what still exists" rather than empty: the archived stream logs
    (`~/.local/state/deskcrab/streams/`, which ARE pruned — the ledger is the durable copy) and
    her own CLI transcript directories (the `projects/` slug of her project dir, the sterile
    classify cwd, and the chess mover's cwd, under every configured login's config dir).
    Transcript records are summed from assistant events deduplicated by request id, one record
    per model per session file, `src: transcript`, `approx: true`.
18. Backfill MUST NOT ingest transcripts that are not hers. A builder job runs in an arbitrary
    workdir whose transcripts are indistinguishable from the user's own coding sessions there,
    so job history comes only from surviving archived streams.
19. Backfill is idempotent. A source file already ingested (same path, size, and mtime, held in
    the backfill state file) is skipped, and a stream whose session id already has live ledger
    records is skipped, so re-running backfill — or backfilling after live recording has begun —
    never double-counts.

### Views

20. `crab metrics [YYYY-MM-DD]` prints the day's totals (default today): input, output, cache
    creation, cache read, cost where known, and run counts — broken down by session kind and by
    model. It reads the ledger and nothing else.
21. The metrics page rides the EXISTING phone server: same process, same port, same
    authentication as every other route ([phone.md](phone.md)) — no new unit, no new listener.
    `GET /metrics` serves the page; `GET /metrics/data?days=N` serves the aggregate. Both are
    behind `_authed` like everything except `/health`.
22. `/metrics/data` returns hour buckets — each keyed by date, hour, kind, model, effort,
    account, and status, carrying summed tokens, cost, duration, and count — so months of ledger
    stay a few thousand rows and every filter the page offers is a client-side re-sum. The
    server never ships raw records to the phone.
23. The page is fully self-contained: inline CSS and JS, no CDN, no external fetch, no
    dependency beyond `/metrics/data` on the same origin. It filters by day, hour, model,
    effort, and session kind, and shows input/output/cache breakdowns and totals.

## DATA

| Path | Format |
|---|---|
| `$METRICS_DIR/tokens-YYYY-MM-DD.jsonl` | one JSON object per line, one line per attempt (rule 3) |
| `$METRICS_DIR/backfill-state.json` | `{source path: {size, mtime}}`, backfill's own memory |
| `$METRICS_DIR/<date>.log` | NOT this spec's — the per-stage timing log, turn-pipeline rule 33 |

## INTERACTIONS

**The recorder may be called by:** every CLI invocation path (rule 13), `crab metrics`, and
`serve.py`'s two metrics routes.

**The recorder may call:** the filesystem. Nothing else — no CLI, no network, no notification.

**The recorder must never:** alter the hosting run's outcome, invoke a model, or write outside
the metrics directory.

## VERIFIED-CORRECT RULES

- **The result event's totals beat the assistant events' sums.** Measured on a live wake stream:
  the deduplicated assistant events reproduce input and cache numbers exactly but undercount
  output by an order of magnitude (their usage is a start-of-message snapshot), while the result
  event carries the true totals and the per-model split.
- **Attempt slicing by init events matches the walks' own byte-offset slicing.** The runner
  judges each attempt on its own bytes (account-fallback rule 14); the ledger reads the same
  boundaries structurally, so the two accounts of one walk cannot drift.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| — | none recorded yet |

## TESTS

- `tests/test_token_ledger.sh` — the parser against captured stream shapes: a clean run's result
  totals; a multi-attempt walk split on init events with accounts read off the swap markers; a
  synthetic refusal recorded as `refused` with no usage; a mid-run cut falling back to deduped
  assistant sums with `approx`; the type-less `is_error` result line; the caller's terminator
  ignored; malformed lines skipped without harm; per-day file naming; the locked append;
  `report`'s aggregation arithmetic; backfill over an archive directory and a transcript
  directory, twice, with identical totals; the recorder exiting 0 on garbage.
- `tests/test_metrics_serve.sh` — the routes on a real server over a real socket: unauthenticated
  `/metrics` and `/metrics/data` are 404, authenticated they serve the page and correct hour
  buckets, and the buckets re-sum to the seeded ledger's totals.
