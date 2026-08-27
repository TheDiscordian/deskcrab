# Spec: chess self-play

## PURPOSE

Self-play is how her chess learns between real games: two mover instances play each other overnight
and every finished game feeds the pattern store, exactly as a real game does. It is also the only
part of her chess that can spend without a person at the board, and on the night of 2026-08-15 it
did: a job-built driver inherited `DESKCRAB_CHESS_MOVER_MODEL` — the user's knob for REAL games,
set to the dearest model — and made roughly 1,590 model calls between midnight and five, draining
the per-account allowance of that model on every login. The refusals cooled whole accounts
(cooldowns are model-blind), healthy capacity was benched with them, the morning's wakes squeezed
onto fewer logins and burned those out too, and when the user spoke at 09:52 the turn died on
"every login is over its limit" — while the model his conversations actually use sat idle and
willing on the same accounts. This spec exists so the grind can never again outspend the person it
is for: self-play gets its own model knob and a hard nightly budget, both enforced where the moves
are actually made.

## CONTRACT

### What self-play is

1. A self-play game is a game in the betty-chess store whose id begins `selfplay-` and whose
   opponent is recorded as `selfplay`. Every rule in this spec binds those games and ONLY those
   games: a game against a person — browser, CLI, anything with a human on the other side — is
   untouched by everything below.

### The model

2. A model call answering a self-play position uses `$DESKCRAB_CHESS_SELFPLAY_MODEL`, default
   `sonnet`. It MUST NOT read `$DESKCRAB_CHESS_MOVER_MODEL` or `$CLAUDE_MODEL`: those are the
   user's knobs for games that matter, and inheriting one is exactly how the 2026-08-15 grind ran
   all night on the dearest model in the house.
3. The binding lives in the mover itself (`lib/chess_mover.py`), keyed off the job it was handed
   (rule 1's test), never in the driver's environment. A driver — the repo's, or a copy written by
   some future hand into a data directory — cannot opt back into the mover knob for self-play,
   because the code that builds the invocation no longer consults it for these games.

### The nightly budget

4. Self-play model calls are budgeted per NIGHT, not per calendar day. The night's key is the
   calendar date of (now − 12 h), so the night of day D runs noon D to noon D+1 and a session
   crossing midnight stays on the same night's key — a chain started before midnight cannot draw
   a second budget at 00:00. At most `$DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES` (default 150)
   calls per night, counted at the mover's choke point — one appended line per attempt in
   `$DESKCRAB_CHESS_DIR/selfplay/model-calls-YYYYMMDD.log` (YYYYMMDD the night key), written
   with O_APPEND so concurrent movers count truly. Reflex moves cost nothing and are never
   counted: the budget bounds spend, not play.
5. A self-play position arriving at the mover after the budget is spent is refused WITHOUT booting
   the CLI: the position resolves `failed` with a cause naming the budget and the count, loudly,
   through the mover's normal failure channels. This is the backstop that binds whatever loop is
   driving — including one the repo has never seen.
6. New self-play games are budgeted per night as well (rule 4's window): at most
   `$DESKCRAB_CHESS_SELFPLAY_NIGHTLY_GAMES` (default 4) games created per night, enforced in
   the driver before it creates one.

### The driver

7. `lib/chess_selfplay.py` is the one sanctioned self-play loop. A hand that wants a grind runs it;
   writing a second driver instead of extending this one is the 2026-08-15 failure again. The
   benchmark (rules 14-19) is a mode of THIS driver for exactly that reason.
8. The driver runs one bounded chunk per invocation (`--budget` seconds, default 360) and exits
   before the chunk budget so its caller never has to kill it. `--deadline HH:MM` (default 07:00)
   is the morning wall: no new work starts past it. A start more than 1 h past the deadline
   counts as an evening start aimed at tomorrow's wall ONLY when that wall is within 12 h;
   further out it is a daytime start, and the driver refuses it — status `daytime`, a non-zero
   exit, and a message naming `--day`, the explicit flag for a deliberate daytime chunk — so a
   manual mid-day invocation can never loop until the next morning. The night path — evening
   and small-hours starts — is unchanged.
9. The driver checks the nightly move budget in its own loop, BEFORE submitting a position, and
   stops cleanly when it is spent — status `budget-spent`, nothing else booked, no reliance on
   rule 5's refusal. Rule 5 is the backstop; this is the manners.
10. The driver plays through the SAME path a real game uses: reflex first, the mover otherwise, the
    answer validated against the store as it stands and written through `chess_cli.save_game`, so
    the pattern store is fed by the same choke point that feeds it for real games.
11. The driver MUST refuse to contend with a person: while any live browser game's file has moved
    inside the hot window (15 minutes) it makes no model call and creates no game. It never touches
    `browser-*` games, never books a wake, never notifies, never speaks.
12. Games the driver plays are kept moving by rule, not by patience: rules-legal draws (threefold,
    fifty-move) are claimed, and a hard ply cap (240) agrees a draw rather than shuffle forever.
13. The driver ends every chunk with one machine-readable `STATUS {...}` line naming why it
    stopped (`budget` — the chunk's seconds, `budget-spent` — rule 9, `games-cap` — rule 6,
    `deadline`, `daytime` — rule 8's refusal, `failing`, `bench-done` — rule 16's plan is
    complete) and what it did (moves this chunk, games finished, games total; in benchmark
    mode also plan games finished / planned).

### The benchmark

Adopted 2026-08-27, on the user's ask: batches of self-play across the standard time controls,
different model-and-effort configurations on each side, colours rotated, so the pairing a real
game should think at can be chosen per control from measured games rather than by feel — while
the finished games feed the pattern store exactly as every self-play game does.

14. A benchmark is driven by THIS driver (rule 7), in `--bench <plan.json>` mode. Every rule
    above binds it unchanged: the nightly move budget (rules 4-5, 9) counts every benchmark
    model call, the games budget (rule 6) counts every benchmark game, the hot window (rule 11)
    pauses it, and it books nothing, notifies nobody, and never speaks. A benchmark at real
    scale is run by deliberately raising the budget knobs for that run — an operator's explicit
    config line, never a new default.
15. **Per-side configuration.** The plan names configurations — `{model, quiet, sharp}` — and
    each scheduled game assigns one per colour. The effort still comes from the rule-16b
    classifier per move, read against the SIDE'S OWN pair (`quiet` when no alarm fired, `sharp`
    otherwise), so a configuration is measured playing the way a real game would think. The
    side's model rides the job: the mover honours a self-play job's `model` field ONLY when it
    names a Claude-family model listed in `$DESKCRAB_CHESS_SELFPLAY_MODELS` (default
    `haiku sonnet`); a codex-family name is refused unconditionally — the one codex login is
    the user's conversation engine, and a grind must never be able to drain it — and any other
    unlisted name falls back loudly to rule 2's default. Real games feel none of this: their
    model comes from rule 16b's own knobs ([chessweb.md](chessweb.md)), never from this
    allowlist.
16. **The schedule.** The plan lists games with an id (`selfplay-bench*-NNN` — inside rule 1's
    prefix, so every guard keys on it), a time control from the standard set, and the two
    configurations. Each matchup appears an even number of times with colours swapped, so
    colour never confounds the comparison. The driver plays the plan in order, one game at a
    time; a game already finished on disk is skipped, so the plan file plus the game files ARE
    the resumable state — a killed chunk resumes mid-game from the store, and re-running a
    finished plan replays nothing.
17. **The clock is real.** A benchmark game is created WITH its scheduled time control, charged
    by the same `chess_cli.clock_move` as every other recording path, flags judged by
    `compute_state`. The clock runs on wall time — mover queueing, retries and failures
    included — because latency is the very thing being weighed against the control: a
    configuration too slow for its clock SHOULD flag, and that flag is a result, not a defect.
18. **Openings vary by book, results stay honest.** For the first plies of a benchmark game
    (`$DESKCRAB_CHESS_BENCH_BOOK_PLIES`, default 6) the driver plays a uniformly random legal
    book move when the book offers one, instead of reflex-or-model — so a batch samples
    openings rather than replaying the store's one favourite line into itself. This is the one
    sanctioned deviation from rule 10, benchmark games only; every move is still validated
    against the store as it stands and written through `chess_cli.save_game`. Past those plies
    the normal path resumes: reflex first, the mover otherwise.
19. **The record.** Each benchmark game carries a `bench` object — the control, each side's
    configuration, and one row per move `[ply, side, source, effort, seconds]` (source `book`,
    `reflex`, or `model`) — written with the game as it plays, so nothing about the run needs
    reconstructing from logs. A finished game appends one JSON line to the run's ledger
    (`$DESKCRAB_CHESS_DIR/selfplay/bench-<run>.jsonl`), exactly once across resumes. Probe
    mode (`--bench-probe`) measures bare per-call latency for the plan's probe configurations
    over fixed positions — each call a self-play mover call, budget-counted, allowlist-bound —
    and appends `probe` lines to the same ledger; it exists so a model too dear to grind (the
    real-game model among them) can still have its latency measured for a few counted calls.
    `--bench-report` renders the ledger and game records into the results table — per control:
    each configuration's score, flags, failures, and latency split by source — and recommends
    nothing by itself: choosing is the reader's job.

## DATA

| Path | What it is |
|---|---|
| `$DESKCRAB_CHESS_DIR/games/selfplay-*.json` | the games, ordinary betty-chess records (benchmark games carry a `bench` object, rule 19) |
| `$DESKCRAB_CHESS_DIR/selfplay/model-calls-YYYYMMDD.log` | rule 4's counter: one line per self-play model attempt; YYYYMMDD is the night key, the date of (now − 12 h) |
| `$DESKCRAB_CHESS_DIR/selfplay/night-YYYYMMDD.log` | the driver's own narrative log, same night key |
| `$DESKCRAB_CHESS_DIR/selfplay/bench-<run>.json` | a benchmark plan (rule 16): configurations, probe list, scheduled games |
| `$DESKCRAB_CHESS_DIR/selfplay/bench-<run>.jsonl` | the run's ledger (rule 19): one line per finished game, one per probe call |

## INTERACTIONS

**The driver may call:** `chess_cli` (store, metrics), `chess_reflex`, `chess_effort`,
`chess_similar`, and the mover. Nothing else.

**The driver must never:** touch a `browser-*` game, book a wake, dispatch a job, notify, or
speak. Its output is game files, its two logs, and the STATUS line.

**The mover's part** (rules 2–5, and rule 15's job-model allowlist) is owned by
`lib/chess_mover.py` and rides every driver; [chessweb.md](chessweb.md) rule 16b defers to this
spec for self-play games.

## TESTS

**Existing:** `tests/test_chess_selfplay.sh` — the model knob (a self-play job builds a `sonnet`
invocation by default, honours `$DESKCRAB_CHESS_SELFPLAY_MODEL`, and ignores
`$DESKCRAB_CHESS_MOVER_MODEL`; a real-game job still follows the mover knob); the budget binding in
the driver (a chunk stops at `budget-spent` with the counter at the cap and not a call past it);
the mover backstop (a self-play position past the cap is refused without the stub being called,
while a real-game position on the same mover still answers); the games cap (a night at its games
cap creates nothing and says `games-cap`); the night key (23:30 and 00:30 across one midnight
share a key — no fresh budget at 00:00 — and an afternoon belongs to the coming night); and the
daytime guard (a mid-day start refuses with status `daytime` naming `--day`, runs with the flag,
and evening, small-hours, and just-past-the-wall starts keep their old walls); the benchmark
(a self-play job's `model` is honoured within the allowlist, refused loudly outside it and for
every codex-family name; a bench plan plays with real clocks and per-side pairs, rotates
colours, resumes without replaying, appends its ledger exactly once per game; a benchmark game
whose clock has run out is a recorded flag, no model call; probe lines carry per-call seconds;
the report renders per-control tables).
