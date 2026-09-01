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
   with O_APPEND. Concurrent movers serialize the count-and-append reservation on that file,
   so exactly one attempt can claim the final available slot and no worker can spend past the
   cap. Reflex moves cost nothing and are never counted: the budget bounds spend, not play.
   An explicitly attended `--live-session` has no call ceiling: it keeps appending every attempt
   to the same audit log, but the count never refuses a call. This mode is for a live operator
   session only; unattended invocations retain the nightly ceiling.
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
    `browser-*` games, never books a wake, never notifies, never speaks. A timed benchmark's clock
    balances stand during this harness pause: after each hot wait the driver restarts the current
    turn timestamp before it can judge or offer the benchmark position again.
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

14. A benchmark is driven by THIS driver (rule 7), in `--bench <plan.json>` mode. The games
    budget (rule 6), hot window (rule 11), silent operation, and audit log all bind it. An
    unattended benchmark also obeys the nightly move budget (rules 4-5, 9). Its
    `nightly_move_budget` is pinned in the benchmark plan and overrides each worker's inherited
    environment, so parallel unattended workers cannot silently enforce different ceilings.
    An attended benchmark uses `--live-session`; every worker then records every call without a
    ceiling, irrespective of the plan's unattended budget.
15. **Per-side configuration.** The plan names configurations — `{model, quiet, sharp}` — and
    each scheduled game assigns one per colour. The effort still comes from the rule-16b
    classifier per move, read against the SIDE'S OWN pair (`quiet` when no alarm fired, `sharp`
    otherwise), so a configuration is measured playing the way a real game would think. The
    side's model rides the job: the mover honours a self-play job's `model` field ONLY when it
    is listed in `$DESKCRAB_CHESS_SELFPLAY_MODELS` (default `haiku sonnet`); any unlisted name
    falls back loudly to rule 2's default. A codex-family name is refused like any other
    unlisted name, and its LISTING must be explicit (amended 2026-08-29, on the user's
    2026-08-28 acceptance criterion that the matrix cross model family, Sol included): the one
    codex login is the user's conversation engine, and putting it into a grind is the same
    deliberate per-run operator act as raising the budget knobs (rule 14), never a default. An
    honoured codex self-play job plays through the codex login ALONE — its attempt list is the
    codex call and nothing else, never the Claude-account fallback walk a real game gets
    ([model-backends.md](model-backends.md) rule 15) — because a benchmark cell that silently
    substituted engines would measure nothing, and because the fallback would let a grind spend
    Claude allowance under a codex flag. Every attempt is budget-counted exactly as rule 4
    demands. A subscription-limit refusal or unavailable login cancels the benchmark worker
    immediately and leaves the game resumable; neither is converted into a flag or selection
    evidence. A transient server-capacity interruption also leaves the game resumable and does
    not eliminate the configuration. These cases are detected before the wall clock is judged,
    while an actual slow model answer remains bound by rule 17's clock. Real games feel
    none of this: their model comes from rule 16b's own knobs ([chessweb.md](chessweb.md)),
    never from this allowlist.
16. **The schedule.** The plan lists games with an id (`selfplay-bench*-NNN` — inside rule 1's
    prefix, so every guard keys on it), a time control from the standard set, and the two
    configurations. Each matchup appears an even number of times with colours swapped, so
    colour never confounds the comparison. One driver plays the plan in order, one game at a
    time. Independent driver workers may run in parallel only when each is assigned an
    explicit, disjoint `--bench-game` id; every assigned id is also protected by a non-blocking
    process lock, so an accidental duplicate worker refuses instead of touching the same game.
    Parallel batches are kept small enough that shared-account contention does not become the
    reason a configuration loses on time. A game already finished on disk is skipped, so the
    plan file plus the game files ARE
    the resumable state — a killed chunk resumes mid-game from the store, and re-running a
    finished plan replays nothing.
17. **The clock is real.** A benchmark game is created WITH its scheduled time control, charged
    by the same `chess_cli.clock_move` as every other recording path, flags judged by
    `compute_state`. The clock runs on wall time — mover queueing, retries and failures
    included — because latency is the very thing being weighed against the control: a
    configuration too slow for its clock SHOULD flag, and that flag is a result, not a defect.
    The clock is also the ONLY ceiling (the user's 2026-08-31 ruling, chessweb.md rule 16g): a
    model attempt runs until it answers or the flag falls, never cut at a fixed per-call
    limit, and no move is ever manufactured for a side whose model failed to answer — the
    driver waits for a timed move as long as the side on move has clock (plus recording
    grace), and a spent clock is the game's genuine, recorded clock loss.
    The wall clock binds only UNDER A LIVE DRIVER: the pause between driver invocations
    belongs to the harness, never to the side on move. A driver picking up an unfinished,
    unledgered game therefore restarts its turn clock before judging state — balances stand,
    exactly chessweb.md rule 22g's treatment of an undo — so a flag can only fall from wall
    time some invocation actually spent playing (queueing, retries and failures still
    included). A game already on the run's ledger is settled evidence: the pickup restart
    skips it, so nothing recorded can reopen. (Named 2026-08-31: two games of the 20260828
    matrix were recorded as flags off 2- and 15-hour driver pauses their sides never played —
    a pause charged as think time is an artifact, not a result.)
18. **Openings vary by book, results stay honest.** For the first plies of a benchmark game
    (`$DESKCRAB_CHESS_BENCH_BOOK_PLIES`, default 6) the driver plays a uniformly random legal
    book move when the book offers one, instead of reflex-or-model — so a batch samples
    openings rather than replaying the store's one favourite line into itself. This is the one
    sanctioned deviation from rule 10, benchmark games only; every move is still validated
    against the store as it stands and written through `chess_cli.save_game`. Past those plies
    the normal path resumes: reflex first, the mover otherwise.
19. **The record.** Each benchmark game carries a `bench` object — the control, each side's
    configuration, and one row per move `[ply, side, source, effort, seconds]` (source `book`,
    `reflex`, or `model`; the `fallback` source is retired — a manufactured move is
    unauthorized, and it survives only in records written before the 2026-08-31 ruling, every
    one of which rule 20b names invalid) — written
    with the game as it plays, so nothing about the run needs reconstructing from logs. A
    finished game appends one JSON line to the run's ledger
    (`$DESKCRAB_CHESS_DIR/selfplay/bench-<run>.jsonl`), exactly once across resumes, and the
    line carries the whole verdict a selection needs: the result, the termination state and
    description, the flagged side if any, the FINAL remaining clock of both sides, per-side
    move counts split by source (fallback moves included), per-side model-call latency
    summaries, and per-side counted model ATTEMPTS mined from rule 4's counter files — so
    retries and failed rounds are on the ledger, not only in night logs. Probe
    mode (`--bench-probe`) measures bare per-call latency for the plan's probe configurations
    over fixed positions — each call a self-play mover call, budget-counted, allowlist-bound —
    and appends `probe` lines to the same ledger; it exists so a model too dear to grind (the
    real-game model among them) can still have its latency measured for a few counted calls.
    A probe is never selection evidence: a route is chosen from complete games alone
    (rule 20), and 2026-08-28 — a verdict built on probes for the model real games actually
    use, rejected by the user — is why this sentence exists.
    `--bench-report` renders the ledger and game records into the results table — per control:
    each configuration's score, flags, failures, and latency split by source — and recommends
    nothing by itself: choosing is the reader's job.
20. **The corrective matrix.** `--bench-init-matrix` writes a full-matrix plan: every supported live mover
    model (`sonnet`, `haiku`, `opus`, `fable` — the Claude families the account walk serves)
    at every chess effort (`low`, `medium`, `high`, `xhigh`), each as a
    uniform configuration (quiet == sharp == the effort, so a cell measures exactly one
    model-and-effort level playing whole games), against ONE common reference configuration
    (`sonnet-low`, the measured steadiest), colours rotated within every cell, across every
    concrete standard timed control, fastest first. The reference's own cell is its mirror
    game. The matrix crosses model FAMILY as well as effort (amended 2026-08-29, on the
    user's 2026-08-28 acceptance criterion): the codex-family candidates ride the same
    matrix, each at ITS OWN effort list, uniform cells against the same reference, with rule
    15's explicit listing and codex-only attempt list binding every call — a codex
    candidate's benchmark move comes from its own exact model through the one codex login or
    it does not come at all, never a Claude fallback and never a substituted model. The
    candidates and their effort lists (amended 2026-08-31, on the user's ruling that the
    ChatGPT subscription's other models were omitted from the matrix) are exactly what the
    authenticated codex catalogue supports: `sol` — the login's conversation model, resolved
    per [model-backends.md](model-backends.md) rule 2 — at the shared four; and the remaining
    benchmarkable subscription models by exact slug, never an alias: `gpt-5.6-terra` and
    `gpt-5.6-luna` at the same four,
    while `gpt-5.3-codex-spark` is permanently excluded from every self-play and benchmark
    call. An effort outside a model's own list is not a cell at all — scheduling one would
    benchmark a call the catalogue refuses.
    The uniform matrix is the family and clock gate. A routed winner is not selected while an
    eligible adaptive pair remains untested. Each clock-safe model climbs this ordered
    quiet/sharp ladder, starting at the longest control:
    `low/medium`, `medium/medium`, `medium/high`, `high/high`, `high/xhigh`, then
    `xhigh/xhigh`. The quiet effort never exceeds the sharp effort. XHigh is the absolute
    chess ceiling; Max and Ultra are neither scheduled nor accepted by a benchmark worker.
    Each pair is a distinct configuration and plays two colour-swapped games against the
    same reference. A pair must reliably finish a longer control before its shorter-control
    games are scheduled. A clock failure eliminates that pair and every later pair for the
    same model at that control and all shorter controls; a clean pass advances the model one
    rung. The controls retain independent winners: passing 15+10 does not imply passing 10+0.
    Selection remains open until every eligible model has either completed the ladder or been
    eliminated by the clock rule. `gpt-5.3-codex-spark` is excluded from every benchmark
    call. Every clock-safe configuration for one model, including its uniform `low`/`low`
    baseline, remains a contender until it has played a colour-swapped direct round against
    every other clock-safe configuration for that model at that control. Common-reference
    results do not substitute for these same-model games: two draws against the reference do
    not prove a configuration weaker than one that beat the reference. A common-reference game
    counts as a direct game only when its exact two configurations are the contenders being
    compared. A tied direct round receives rule 20a's one colour-swapped top-up round before
    the reliability, latency-tail, and cost tie-breaks may resolve it.
    Once these rounds leave one resolved clock-safe configuration per model and control,
    those finalists play a colour-swapped round against every other finalist at that control.
    This direct round is required even when the common-reference scores are not tied: it
    settles ambiguous cross-model results instead of inferring them through the reference.
    A finalist that fails either clock is eliminated; among the finishers, direct score is
    the first strength comparison, followed by the common-reference score and the existing
    reliability, latency-tail, and cost tie-breaks.
    A control is COMPLETE only when every required ladder cell has valid colour-swapped
    evidence, every surviving same-model comparison is resolved, and every surviving
    cross-model finalist comparison is resolved. An invalid or missing game is explicitly
    `NOT RUN — REPLACEMENT OWED` unless separate valid evidence has already eliminated that
    exact configuration; pruning it merely as outside the candidate scope cannot satisfy this
    completion gate. A report that still lists one of these obligations is INCOMPLETE,
    regardless of whether every older matrix row has been played or pruned.
    `--bench-extend-matrix <plan>` appends
    whatever matrix cells an existing plan is missing — grouped at the end of their control's
    block so play order stays fastest-first, colours still rotated, ids continuing the plan's
    numbering, existing games untouched — so a matrix widened after play began extends the
    SAME resumable plan (rule 16) instead of restarting it; a second run appends nothing. Selection discipline, for the reader the report serves: a cell RELIABLY FINISHES a
    control only when its games complete without flags, stalls, fallback rescues, retry
    storms, or account-limit deaths — those are failures to finish, never noise; among
    reliable finishers the strongest measured result wins, tie-broken by head-to-head where
    played, then fewer failure events, then the lower latency tail, then the cheaper pair
    (lower effort, then cheaper model). A cell interrupted by server capacity is RESUMED,
    never excluded; a subscription-limit refusal cancels its worker and is resumed only after
    allowance is available — the plan file plus the game files are the resumable state, exactly rule
    16. Untimed play is outside this timed elimination benchmark and keeps its uniform
    default pair (chessweb.md rule 16b). A verdict may differ between two controls carrying
    the same speed label, so exact-control winners land in `chess_effort.CONTROL_PAIRS` and
    `chess_effort.CONTROL_MODELS`; broader fallbacks land in `SPEED_PAIRS` and
    `SPEED_MODELS`. The run's report in `docs/` records the full matrix, exclusions,
    uncertainty statements, and raw ledger locations.
20a. **Longest-clock-first elimination.** Controls are judged longest clock first. A pair that fails a longer
    control for CLOCK reasons — a flag, a retry storm or account-limit death that burned the
    clock away, or otherwise proving too slow to finish — is eliminated from every shorter
    control without playing those games: less clock can only fail harder. The same monotone
    arithmetic runs along the EFFORT axis within one model: a higher effort of the same model
    thinks strictly longer per call, so when a lower effort of a model fails a control for
    clock reasons, every higher effort of that model is eliminated there and below without
    play — recorded as an inference, named as such. A non-clock failure (a stall with time
    still in hand — every attempt failing while the clock stands) still poisons its own cell
    under rule 20's reliability discipline but eliminates nothing downward. A game is also unnecessary when no outcome of it can change any routed
    class's selection: a pair already measured-unreliable at the class's other control, a
    mirror game whose points are arithmetically pinned, a cell already carrying a
    disqualifying event its second colour cannot cure. Every such game is PRUNED — a
    deliberate operator act like the append, never the driver's own idea: the spec keeps its
    place in the plan and gains `pruned: <reason>`; the driver skips a pruned spec, never
    creating, resuming, or recording it (a mid-flight game file a prune strands stays on
    disk as evidence); the analysis subtracts pruned games from the schedule, so a cell
    whose remaining games are all pruned is settled by elimination, never "incomplete", and
    every prune is printed with its reason so nothing vanishes silently. Pruning a game
    already on the run's ledger is refused — recorded play is evidence, and elimination
    never deletes evidence. Pruning a replacement spec (rule 17) cancels the artifact slot
    it owed, stated reason and all. Top-ups are owed only where a selection is genuinely
    ambiguous among reliable finishers — a reliable cell within the close margin of its
    control's reliable winner, decided at completion — and only ONE round each: a cell
    already carrying its top-up games is owed nothing further (the appender refuses a
    re-top, and a verdict that waited on a margin that never widens would wait forever);
    the former one-failure-event-in-two-games top-up is retired, because an event-carrying
    cell is eliminated already and more games cannot change any selection. Where a control or speed class has NO reliable
    finisher, the route is still chosen from the measured evidence rather than by feel:
    among complete cells — fewest flags per game, then fewest event games per game, then
    the higher score rate, then the lower latency tail, then the cheaper pair — with the
    failure record stated beside the applied verdict wherever it lands. Such a verdict claims
    exactly what was measured and no more: while any cell of a control stays unmeasured under
    the corrected regime, the report says no MEASURED configuration finishes it, names the
    unmeasured cells, and never claims that no configuration can — a benchmark that did not
    play a cell cannot speak for it. The same honesty binds every shipped restatement of a
    verdict, not just the report: no routing comment or UI message may turn a measured result
    into a claim about unmeasured configurations. Either way, a
    pair is ELIGIBLE for a speed-class verdict only with a colour-rotated pair of valid
    games at each of the class's controls — rule 16's even-colours discipline applied to
    the evidence, not just the schedule; a pair short of that floor is named as
    uncertainty, never routed.
20b. **Regime invalidation** (adopted 2026-08-31, the user's ruling that retired the fixed
    per-call ceiling and the manufactured fallback move). A benchmark game recorded under the
    retired regime is INVALID EVIDENCE when either side's record carries a fallback move, or
    when its outcome was created by the retired ceiling or by a driver stall of undetermined
    cause — invalid for strength AND for reliability, because a game contaminated by a move
    nobody chose, or by a cut nobody ordered, proves neither. A clean game of the retired
    regime — every move book, reflex, or the model's own, every call completed within bounds
    at least as tight as rule 17 now allows — remains valid: a pass under harsher constraints
    is a pass. Invalid games stay on the ledger untouched (recorded play is never deleted);
    the analysis excludes them by their own recorded move sources, names every exclusion with
    its reason, and the evidence a selection still requires is re-played under the corrected
    rule 17 as replacement specs appended to the same resumable plan.

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
(a self-play job's `model` is honoured within the allowlist, refused loudly outside it —
codex-family names included unless the operator lists them explicitly, an honoured codex job
building the codex call ALONE with the job's own model resolved onto the argv, no
Claude-account attempts, none at all while the login cools; a bench plan plays with real
clocks and per-side pairs, rotates colours, resumes without replaying, appends its ledger
exactly once per game; a benchmark game whose clock has run out is a recorded flag, no model
call; probe lines carry per-call seconds; the report renders per-control tables); the matrix
plan (every matrix model × effort present exactly once as a uniform pair — the codex
candidate at its own effort list — every timed control covered with colours split evenly
against the reference, the reference mirrored; the extend mode appends exactly the missing
cells grouped with their control, exactly once, existing games untouched) and the extended
ledger line (final remaining clock, per-side attempts mined from the counter, fallback move
counts).
