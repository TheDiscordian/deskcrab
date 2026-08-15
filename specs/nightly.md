# Spec: nightly

## PURPOSE

Four scheduled processes that keep her from rotting: sleep, which ingests the day into long-term
memory and then holds the day's spoken sentences up against her own banned-phrase list; tidy, which
maintains the shelves; the self-change watcher, which tells her when a hand that was not hers
changed the files that constitute her; and the canary, which proves the watcher is
still alive. This spec owns their schedules, their guarantees, and the rule that a scheduled process
which fails silently is worse than one that does not exist.

## CONTRACT

### General

1. Every scheduled process MUST be defined by a unit file **in the repository**. A process that
   exists only as an installed unit has no test, no review path, and is lost on any reinstall.
2. Every scheduled process MUST be persistent across a machine being off, so a missed night is
   caught up at boot rather than skipped.
3. Every scheduled process MUST leave a durable record of when it last succeeded.
4. Every rot check MUST have a caller. A stamp nobody reads is a wish, not a habit.
5. A rot condition MUST surface where she will see it: `crab status` and the state block.
6. Every scheduled process that writes files she is watched for MUST declare its writes, or it
   reports its own hand to her as an intruder's.

6a. Deployment is by symlink — every unit and every phase invokes the deployed path
    (`~/.local/lib/deskcrab`, a directory symlink into the checkout's `lib/`) — so every script
    that locates the checkout from its own path MUST resolve that path through `readlink -f`
    before taking `dirname`. A `cd ..` from the symlink's logical path walks into `~/.local/lib`,
    not out of the checkout, and the script sources a `lib/common.sh` that does not exist; both
    post-stamp nightly phases ran exactly that way in production — dead, and the night stamping
    green over them — until 2026-08-11. The suite MUST invoke at least one script through a
    symlinked directory and assert it sources the library and runs.

### Sleep — the nightly ingest

7. Sleep runs the ingest and then stamps the last-slept record.
8. A failed ingest MUST NOT stamp. The stamp means the night happened.
9. "Nothing new since the last cursor" still counts as a night. There was nothing to learn and she
   did look.
10. The exit status that matters is the ingest's own, never a pipeline's last stage.
11. Sleep MUST NOT touch the shelves. It is separate from tidy on purpose.
12. Ingest MUST NOT tail-clamp its input. See [memory-recall.md](memory-recall.md) rule 29.
13. Sleep MUST run its model call under the account chain.
14. The rot threshold is two nights. Past it, the status command reports rot and exits non-zero, and
    something MUST read that.

14a. The stamp records coverage beside yield. Yield alone can hide a truncated night — "added=8"
    reads the same whether the ingest weighed the whole day or died after its first pass — so the
    stamp's third line carries, beside `added=`, whatever the night's log states of its own size:
    `chunks=` and `chars=` from the ingest header, and `passes=` from the header's pass count,
    counted from the per-pass lines where the header predates stating it. All on ONE
    space-separated line, so every reader of the third line keeps working and a legacy added-only
    stamp still reads fine. Coverage is evidence, never a gate: a field the log does not state is
    omitted, not invented, and a log with no header at all still stamps and still counts as slept
    (rule 9) — the stamp MUST NOT be stricter than the night it records.

14b. A phase that cannot start MUST NOT look like a phase with nothing to do. Each post-stamp
    phase — the claudism review, the promise sweep, the backlog drain — owes the night log at
    least one line opening with its own name (`claudism-scan:`, `promise-check:`,
    `backlog-drain:`); sleep watches each phase's stretch of the log, and when a phase exits
    leaving no such line there, sleep MUST say so loudly — `PHASE SILENT`, naming the phase and
    its exit status — in the night log itself as well as on stderr. A phase's non-zero exit is
    likewise named in the log, not on stderr alone, where only the journal would carry it. The
    complaint is evidence, never a gate: the stamp and the night's exit stay the ingest's own
    (rules 8 and 10) — a night is not unmade by a phase that could not speak, it is only never
    silent about one.

### Tidy — shelf maintenance

15. Tidy is the one process that moves lines between the wants shelf, conduct, and the engineering
    threads, and that deletes orphaned want documents. **It MUST be in the repository**, with its
    prompt under version control and a test that exercises it.
16. Tidy MUST NOT touch the memory store.
17. Tidy MUST declare its writes before it makes them.
18. Anything tidy writes MUST be reachable from the index block. See
    [prompt-assembly.md](prompt-assembly.md) rule 23.
19. Tidy MUST NOT be asked to write prose into a machine-written record. Its own dated summary needs
    a destination that a reader will actually read; a prose line appended to the journal is skipped
    by the journal reader and dropped by the ingest, so tidy's own record never survives.
20. Tidy MUST NOT create a second namespace beside an existing one. A stray file with the same name
    as a directory is unreachable by every reader and still trips the watcher.
21. Tidy MUST run its model call under the account chain.

### The self-change watcher

22. The watcher is driven by a path unit using the kernel's own change notification. No polling
    daemon.
23. The watcher MUST seed silently on first run, so an existing tree never fires.
24. The watcher MUST settle a burst of changes into one wake.
25. Her own writes MUST NEVER wake her. A change is dropped when a write declaration covers it, or a
    live session's claim names it, or its mtime falls inside one of her own run windows (rule 25b),
    or it is the memory database and one of her sessions ran recently.

25a. The watched drawers exclude `.git` internals. Several of them are git repositories of their
    own — conduct is, and any personal directory in the extra watch set may be — and there the
    commits are the record while the plumbing that records them (`refs/heads/*`, `logs/HEAD`,
    `COMMIT_EDITMSG`, the index, the object store) is noise: a change of substance always shows in
    the working tree beside it. The snapshot MUST NOT descend into `.git`, exactly as the code
    repository's internals are invisible by construction through `git ls-files`. Without this, a
    conduct commit made by her own hand at 00:37 woke her at 00:50 about its refs and logs
    (2026-08-11).
25b. The run window. A creation or modification whose mtime falls inside the run window of one of
    her own sessions — start to end, widened by a small grace either side (90 seconds by default,
    `NOTICE_SELF_RUNWIN_GRACE`) — is her own hand and MUST stay quiet with no declaration at all.
    The windows come from the live registrations (a session still running extends to now) and from
    the finished-sessions log, including its reaped lines; the ledger records when a session ran
    and never which paths its tools touched, so the window match alone is the rule. Two costs are
    accepted by name: an outside edit made while she happens to be awake is silenced, and a file
    arriving with an old mtime that lands inside some past window is silenced too — both judged
    cheaper than the class this closes, a session writing its own drawers right up to its final
    second and being reported to herself as an intruder (four times on 2026-08-14 alone, wants and
    Library both). A deletion is NEVER excused by a run window — rule 28's discipline holds.
    Detached builder jobs are not sessions and get no window from this rule; a job's writes are
    excused only by the declarations the job runner makes.
26. Write declarations come in two tiers. A **strong** declaration means the path was in a provable
    write position and excuses anything, including a subtree. A **weak** declaration means the path
    merely appeared in a command she ran, and excuses exact paths only, never a deletion.
27. A declaration counts if it was alive at any point since judgement last ran, not merely at this
    instant. The difference covers the whole interval, and the interval can outlast a declaration's
    window.
28. A deletion is never excused by a fuzzy claim match. A deleted want must always surface unless the
    deleter declared it.
29. Whatever survives is written to a report and handed to an ordinary event wake, which brings its
    own quiet-hours and single-wake discipline.
30. The watcher MUST NOT speak, and the wake's agenda MUST offer awareness, never an instruction.
31. Each judgement MUST archive the stream it read and append one line naming the strong and weak
    sets it produced. Both are evidence only: nothing reads them but her, after an alarm, and
    neither may alter a declaration. **The forensics must never become the bug.**

### The canary

32. The canary proves the whole path: change notification, then the path unit, then the service,
    then the emitter's own code. Proving that a unit file exists is not proving the watcher works.
33. The emitter MUST stamp a heartbeat before any early exit, and the canary waits for that number
    to move.
34. The sentinel MUST be invisible to the emitter's own snapshot, so the directory change fires the
    unit, the emitter finds nothing of substance, and no report or wake is produced.
35. **The poke MUST repeat** inside the wait window. A path unit does not queue: a change arriving
    while its service is still running is lost, and the unit re-arms only once that service goes
    inactive. A single-poke design called a healthy watcher dead within a minute of the emitter
    merely being busy.
36. There are three outcomes and only one is an alarm. An inactive path unit is started and she is
    told it had stopped — whatever changed during the gap was never judged. An already-busy emitter
    is inconclusive, never an alarm. A heartbeat that will not move fires an event wake naming what
    is unguarded.
37. When the canary finds the path unit disabled rather than merely stopped, starting it in-session
    is not the fix — it will not come back after a reboot. The canary MUST say so in terms that name
    the durable repair.
38. One line per check MUST land in the canary log.

### The claudism review — part of sleep

39. After a night that happened — ingest succeeded, stamp written — sleep runs the claudism review
    over the day that just ended. It reads the day's journal and nothing else. It MUST NOT run
    inside a live turn, and it MUST NOT gate, mute, or rewrite anything she says or has said:
    detection and review after the fact, only. The standing rule of
    [speech-output.md](speech-output.md) outranks this whole feature — the moment the review grows
    a hand on the speech path, it is the mechanism that rule forbids, and it is deleted.
40. The phrase list is hers: personal state beside the shelves, never in this repository. Each
    entry carries the reason the phrase is borrowed, so the list reads as prose and not as a regex
    blob. No list means no review, silently, one log line — an empty habit is not an error.
41. The review reads only the SPOKEN half of each reply — the text above the display delimiter,
    split the anchored, whitespace-tolerant way of [speech-output.md](speech-output.md) rules 3
    and 4 — and never the user's words, the display half, or a job's entry. A job's journal entry
    is a builder's log, not her voice.
42. Every hit is quoted as its whole sentence with its turn's timestamp, beside a proposed rewrite
    in her own voice. The rewrite is the point: step back and say it the right way — a
    habit-breaking exercise, never a censor. The rewrite call runs under the account chain (rule
    13 applies); a night when every login refuses still writes the report, hits included, with the
    rewrites marked missing. Detection MUST never depend on the model.
43. A per-phrase count accumulates night over night, so the number can be watched going down.
    Re-running a night replaces that night's counts; it never doubles them.
44. The review MUST surface. It books a morning event wake naming the report — on a night with
    hits, on a clean night, and on a scan that failed. A review she never hears about is
    surveillance, not an exercise; the wake's agenda offers awareness, never an instruction.
45. The review declares its writes (rule 6), books through the queue's one door under its own
    identity (`claudism-review` — [wake-queue.md](wake-queue.md) rule 41), and its failure MUST
    NOT unstamp or fail the night: the stamp and the exit stay the ingest's own (rules 8 and 10).
46. The list speaks in functions, not only in strings. An entry MAY declare the rhetorical move
    it performs (`- function:`, a short slug; several entries may share one) and what a true
    correction looks like (`- fix: delete` where the cure is striking the decoration, `- fix:
    resay` where only a different sentence will do; unset, an entry with `replace:` lines
    defaults to delete and any other to resay). The review MUST aggregate by function and MUST
    report each function's uses per thousand spoken words, tonight beside its recent nights,
    because the habit under watch is the move and not the wording: a banned member's share
    moving to a sibling word is the same habit in a new coat, not a cure. An untagged entry
    stands as its own function.
47. A mention is not a use. A hit whose matched words are quoted, inside a code span, or in a
    sentence that is about the list itself — naming an entry, a ban, a flag, a pattern, a
    rewrite, the review — MUST be classed a mention: never scored as a use, never handed to the
    rewrite call, counted and quoted separately under its own per-thousand-words rate. Talking
    about the drift instead of not drifting is its own failure mode and MUST stay visible;
    dropping mentions silently would hide it, and scoring them would inflate every count the
    moment she discusses her own review.
48. The substitution watch. The report MUST place a function's members side by side across the
    recent nights and say plainly when the family's total holds while its members churn — a
    member gone quiet beside a sibling that rose is the habit changing words, not dying. A
    proposed rewrite that still fires any pattern of the same function is a miss, not a pass:
    the report MUST mark it substituted and MUST NOT present it as the fix. The rewrite
    instruction is function-aware — for a `fix: delete` entry the proposal is the sentence with
    the decoration struck (the entry's own `replace:` lines where they cover it, the matched
    span struck where they do not and rule 50 allows it), and the model is asked only where the
    fix is a different sentence.
49. The night corroborates the live mirror. For each flag-log record of a live rewrite
    ([speech-output.md](speech-output.md) rule 45), the review MUST check whether the same
    turn's final reply still fires the same function, and name it in the report when it does: a
    hold answered with a synonym went out as the same move in new words, and only the night can
    see both halves. This is the corroboration `MIN-34` is owed, in its first piece.
50. A mechanical deletion may only strike what comes away clean. Where no `replace:` line covers
    a `fix: delete` hit, the bare span MAY be struck only if every uncovered match is a single
    `-ly` adverb; any other span — an adjective its noun is sitting on, a match with the verb
    inside it — MUST route to the model as a resay instead. A correction that leaves an
    ungrammatical sentence teaches nothing and discredits the entry it came from: the review of
    2026-08-08 offered "Intermittent is the kind of hard" and "what was surfaced, what with it"
    as the lines she should have said.

### The promise sweep — part of sleep

The promise checker's live pass ([turn-pipeline.md](turn-pipeline.md) rules 32a-32d) is
deliberately cheap: a pattern pre-check gates the model, so a commitment phrased outside the
patterns is never judged, and a wake the checker booked may itself have come to nothing. The
night is where the day's promises are settled honestly, from the whole record at once.

51. After a night that happened — ingest succeeded, stamp written — and BEFORE the backlog
    drain, sleep runs the promise
    sweep (`lib/promise-check sweep`) over the day that just ended: the day's journal, every
    channel's replies with the outcome and work trace each session left, beside the day's
    promise ledger. One model call, the checker's own model and fallback, under the account
    chain (rule 13 applies). Every channel's outcome carries its turn's own tool trace — the
    desk and phone rows exactly as the wake's ([turn-pipeline.md](turn-pipeline.md) rule 32e)
    — so a completed-work claim that slipped the live pre-check is refuted here from the day's
    own record, or shown done by it: a claim whose day carries no matching trace surfaces as a
    miss, and one whose trace names the work is dropped.
52. The sweep surfaces only genuine end-of-day misses. A commitment fulfilled later in the day
    — promised at noon, visibly done by a later session's record — is reconciled and dropped,
    whether or not the live checker caught it; a commitment never caught during the day and
    never performed is a miss exactly as a caught one is. The journal is the sweep's whole
    evidence, so it errs toward surfacing: a fulfilment the record cannot show is a miss the
    morning can dismiss in a sentence, where a miss the night dropped is a promise that died
    twice. Erring toward surfacing has one hard exception, shared with the live judge
    ([turn-pipeline.md](turn-pipeline.md) rule 32b): a NEGATIVE commitment — one to refrain
    from acting ("I'm leaving X alone", "I won't touch Y", "nothing further from me on Z")
    — is never a miss, however empty the day's record stands on it. Absence of action is
    the keeping of it, so an abstention has no fulfilment the record could ever show; the
    sweep's judge classifies each commitment's polarity before fulfilment and drops the
    negative unjudged.
53. Every miss lands as a sweep record on the durable ledger, and the day's misses are
    surfaced together as ONE morning event wake through the queue's one door, in the checker's
    own identity (`promise-check`), quoting the missed promises. A clean day books nothing —
    the sweep is a debt collector, not an exercise, and its run-trace line is its record. The
    sweep's failure MUST NOT unstamp or fail the night: the stamp and the exit stay the
    ingest's own (rules 8 and 10), exactly as the claudism review's failure must not.
53a. The sweep owes the night log its closing line. Every path out of the sweep — no journal, no
    replies, no verdict, clean, or misses booked — prints one line in the checker's own name
    (`promise-check: sweep <day>: …`) to stdout beside the run-trace record of rule 53, so the
    night log shows the sweep reached its own end and rule 14b's detector can tell a sweep that
    ran from one that never started. The guards ahead of the mode dispatch (no CLI, no python)
    still exit silently on purpose: a sweep that cannot start is exactly what rule 14b flags.

### The backlog drain — part of sleep, and the night's owed-work sweep

The engineering threads accumulate faster than waking hours spend them, and the stretch between
sleep's stamp and the morning is machine time nobody is using. The drain turns that idle stretch
into builders: the night's owed work — the queued backlog the daytime dispatch policy shelved
([jobs.md](jobs.md) rules 30-34), open threads, the promises the sweep found genuinely missed,
the work already sitting on the wake queue's books — becomes dispatched jobs, round after
round, for hours, until a wall-clock cutoff — and then the night finishes normally, so the
assistant ends it idle and available. Sleeping is an ACTIVE activity, the user's own design
(2026-08-11 00:26 and 09:40): a night that only reads the day and then sits idle is not the sleep
that was asked for, and promised work must stop waiting for a live turn to personally remember it.

54. After a night that happened — ingest succeeded, stamp written — and AFTER the promise sweep,
    as the night's last phase, sleep runs the backlog drain (`lib/backlog-drain run`) over the
    open owed work. The sweep runs first on purpose: its reconciled end-of-day misses are part of
    the drain's material (rule 58b), and the drain is the phase that holds the night open until
    the cutoff, so everything else finishes before it starts. Its
    failure MUST NOT unstamp or fail the night: the stamp and the exit stay the ingest's own
    (rules 8 and 10), exactly as the review's and the sweep's must not.
55. The drain dispatches only through the job door (`crab job`), never around it, so every builder
    it starts carries the whole jobs contract — sidecar, live log, completion wake, the
    blocked-versus-failed distinction, the null-brief guard. The drain itself MUST NOT speak, book
    wakes, or open windows; its record is its ledger and the night's log.
56. Dispatch stops at a hard wall-clock cutoff (`BACKLOG_DRAIN_CUTOFF`, default 06:00 local, the
    user's named line): no NEW dispatch at or past it, ever; builders already in flight are left
    to finish. The cutoff MUST be re-checked immediately before every dispatch, not only at a
    round's start — a selection call can take minutes, and a dispatch a minute past the line is a
    dispatch past the line. The default gives the 03:10 night nearly three hours of builders —
    sleeping through the night is doing, not idling — and ends well clear of the morning, so she
    meets it idle and available. (The first cut defaulted to 04:00, fifty minutes after the
    timer: an active night that was structurally a nap. The second defaulted to 08:00 and ran
    builders into the morning; 06:00 is the user's stated hard line.) A drain
    that begins when the next cutoff is further away than the window cap
    (`BACKLOG_DRAIN_WINDOW_MAX`, default six hours) MUST NOT dispatch at all — a missed night
    caught up at noon (rule 2) still sleeps, but it does not fill the daylight with builders.
56a. The queued backlog goes first. Each round, before any selection call, the drain dispatches
    the records the daytime policy shelved ([jobs.md](jobs.md) rule 30) — oldest first, through
    `crab job dispatch <id>`, never around the door — against the same cap and the same cutoff.
    Queued briefs are already-written work: they cost no model call and no judgement, so they
    spend the night's slots before the selector is asked to invent anything. The queue is the
    drain's FIRST material, and it drains even when no engineering threads exist at all: missing
    selection material switches off the selector, never the queue, and such a queue-only night
    ends when the queue is dry and nothing of the night's is still in flight. The drain sets
    `DESKCRAB_JOB_NIGHT=1` on every job-door call it makes, which is how the door knows the
    night window is open (jobs.md rule 31); nothing else ever sets it. A queued dispatch the
    door refuses for any reason but the block marker is skipped for the rest of the night and
    named in the night log — never retried in a loop — and the block marker ends dispatch for
    the night exactly as rule 60 says, because the wall in front of one builder stands in front
    of them all. The dry run of rule 61 names each queued brief it would have dispatched and
    starts none. The state machine is the dedupe: a dispatched record leaves `queued`, so the
    ledger of rule 59 tracks only the selector's picks.
57. Concurrent jobs are capped (`BACKLOG_DRAIN_CAP`, default 2), counting EVERY job standing
    `dispatched` or `running` and not only the drain's own: a builder between the dispatch call
    and its worker's first write already holds a slot and an account, so a count blind to
    `dispatched` overshot the cap in exactly the window where one round's dispatches had not yet
    spoken as the next round counted. The cap protects the machine and the accounts, not the
    feature. A full slate is waited out, never overridden. Two is the user's standing overnight ceiling — eight
    builders at once burned through two logins inside an hour (2026-08-11 00:51), and he asked
    for two at a time, queued, never parallel swarms while she sleeps.
58. Selection is judgement — one model call per round, under the account chain (rule 13 applies) —
    and a thread is dispatched only when it is genuinely actionable engineering work: never a note
    or an incident record with no work left in it, never work the threads record as done, never a
    duplicate of a running, queued, or recently finished job (a queued brief dispatches tonight on
    its own — selecting its subject again buys the same work twice), never a thread already on the
    drain's ledger,
    never a decision that is the user's to make, and never a thread that names a hand already on
    it. When nothing qualifies and nothing the drain dispatched tonight is still running, the
    drain ends; it MUST NOT poll an empty backlog to the cutoff.
58a. The material the selector reads — the thread log, the open list, the index, the job list — is
    bounded by bytes, and every one of those cuts MUST fall on a character boundary, through
    `utf8_head`, the document-shaped counterpart of the one shared trim
    ([wake-queue.md](wake-queue.md) DATA): a bare `head -c` on prose people wrote splits whatever
    multibyte character straddles the budget, and the lone lead byte it leaves lands in the
    selector's prompt and the night's stream log as invalid UTF-8 — the same defect that made grep
    read the entire wake ledger as binary. The partial character is dropped whole, characters
    clear of the boundary are content and survive, and the prompt handed to the selector MUST be
    valid UTF-8 whatever lands on any of the four budgets.
58b. The drain's material is the whole owed-work shelf, not the threads alone. Beside the thread
    log, the open list and the index, the selector MUST be handed, each as its own labelled and
    bounded section: the promise sweep's genuine end-of-day misses from the recent nights (the
    `type: sweep` records of the durable ledger — the honest pass's verdicts, never the live
    checker's raw catches, which run heavily false), and the wake queue's pending bookings (fire
    time, booker, reason — the reasons are where owed work waits for a live turn, and a live
    turn cannot commit to the repository at all, so builder-shaped work parked on a wake is work
    the night should hand to a builder that can). A pick from any source lands on the same
    ledger under its own key and dedupes the same way. The judgement of rule 58 extends over the
    new material unchanged, with one line drawn hard: dispatch ONLY what needs no conversation —
    never work that waits on the user's decision or his voice in the room, and never a wake
    whose reason is speaking, awareness, reflection, chess, or a reminder rather than buildable
    work. A section that cannot be read is presented as unreadable and named in the night log,
    never silently omitted — the selector must know it is judging from less than the whole
    shelf.
59. Every dispatch lands on a durable ledger — night, thread key, job id, title — and the ledger is
    read back into every later round and every later night, so the drain never re-dispatches a
    thread on its own initiative. The ledger is the drain's one write and MUST be declared
    (rule 6).
60. A brief MUST be self-contained: the builder arrives knowing only the brief's text, so it names
    the working directory by absolute path, the thread it came from, the concrete work, and the
    verification owed before reporting done — a brief that only waits on or watches other work is
    the job that "finished" having done nothing. A brief that fails validation (empty,
    null-shaped, too thin to act on) is skipped and logged, never dispatched; a refusal from the
    job door's block marker ends dispatch for the night, because the wall in front of one builder
    stands in front of them all.
61. `DESKCRAB_NO_DISPATCH` MUST dry-run the whole phase — real material, real selection,
    would-dispatch lines, nothing started and no ledger written — so the selection can be watched
    in daylight without spending a builder.

The same engine is runnable by hand: `lib/claudism-corpus` scores an archived conversation
directory (the rotation's transcript format — [turn-pipeline.md](turn-pipeline.md) DATA) against
the list, bucketed by date, uses and mentions apart, per function per thousand spoken words — so
a claim about the habit's history is a measurement, not an impression. It is wired to no timer
and writes nothing: a reader run by hand, assistant halves only, spoken halves only.

## DATA

| Path | Owner | Role |
|---|---|---|
| `~/.local/share/deskcrab/last-slept` | sleep | epoch, timestamp, then yield and coverage on one line: added, chunks, chars, passes (rule 14a) |
| `~/.local/share/deskcrab/sleep/<date>.log` | sleep | the night's ingest output |
| `~/.local/share/deskcrab/wants.md`, `wants/` | tidy | the shelf and its bodies |
| `~/.local/share/deskcrab/conduct/` | tidy | conduct and its per-rule files |
| `~/.local/share/deskcrab/engineering/` | tidy | open threads and their index |
| `~/.local/state/deskcrab/notice-self.snapshot` | the watcher | the tree as last judged |
| `~/.local/state/deskcrab/notice-self.suppress` | write declarations | strong and weak records |
| `~/.local/state/deskcrab/notice-self.declared.log` | the watcher | one line per harvest |
| `~/.local/state/deskcrab/streams/<epoch>-<pid>.jsonl` | the watcher | archived stream, evidence only |
| `~/.local/state/deskcrab/notice-self.heartbeat` | the emitter | the number the canary watches |
| `~/.local/state/deskcrab/canary-self.log` | the canary | one line per check |
| `~/.local/share/deskcrab/claudisms.md` | her, by hand | the phrase list: what is borrowed, and why |
| `~/.local/share/deskcrab/claudisms/<date>.md` | the claudism review | the night's report: hits, rewrites, counts |
| `~/.local/share/deskcrab/claudisms/counts.tsv` | the claudism review | one line per night and phrase, uses only |
| `~/.local/share/deskcrab/claudisms/functions.tsv` | the claudism review | one line per night and function: uses, mentions, spoken words |
| `~/.local/share/deskcrab/promise-ledger.jsonl` | the promise checker; the sweep appends its records (rule 53) | live catches and end-of-day misses ([turn-pipeline.md](turn-pipeline.md) DATA); the drain reads the sweep records back as owed-work material (rule 58b) |
| `~/.local/share/deskcrab/backlog-drain/dispatched.tsv` | the backlog drain | one line per dispatched pick: night, key, job id, title (rule 59) — threads, swept promises and wake-parked work alike |

Units in the repository: the wake timer and service, the wake restore service, the sleep timer and
service, the self-change path and service, the transcription path and service, the canary timer and
service, the phone server service. **The tidy timer and service are missing and must be added.**

## INTERACTIONS

**Nightly processes may call:** the memory store, the wake queue's `book()`, the write-declaration
helper, the account chain.

**Nightly processes may be called by:** their timers and path units, and by hand for testing.

**Nightly processes must never:** speak, open a window, or write to the conversation. Their output
reaches her through an event wake or through a record she reads.

## VERIFIED-CORRECT RULES

- **A failed ingest does not stamp.** The stamp is a claim that the night happened, and it must be
  true.
- **The exit status is the ingest's own.** Taking a pipeline's final status made a failed night
  stamp as slept.
- **Sleep and tidy are separate on purpose.** Tidy touches memory not at all.
- **The watcher seeds silently on first run**, so an existing backlog never fires.
- **The two-tier declaration model is correct**, including that a weak declaration never excuses a
  deletion.
- **A declaration counts if it was alive at any point since judgement last ran.**
- **The memory database is excused when one of her sessions ran recently**, because sqlite plumbing
  touches that file on nearly every prompt build and every opener of the store is her own code —
  deletions still excepted.
- **The forensics are evidence and cannot alter a declaration**, and the test asserts exactly that.
- **The canary's repeating poke.** A path unit does not queue.
- **The canary's sentinel is invisible to the emitter's snapshot.**
- **Three outcomes, one alarm.** An already-busy emitter is inconclusive, never a failure.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `MAJ-23` | The tidy units are not in the repository. The one nightly process that moves lines between the shelf, conduct and the engineering threads, and deletes orphaned want documents, lives as an embedded command string with no test and no review path. |
| `MAJ-24` | The engineering threads are maintained nightly and named in no prompt path. |
| `MAJ-25` | The rot check has no caller. The stamp is write-only, so a stalled ingest surfaces nowhere. |
| `MAJ-32` | Ingest tail-clamped its input against a journal several times the cap, so the day's earliest material was never ingested. Closed 2026-08-11: the ingest now windows on whole chunk boundaries and runs the distiller once per window, reporting each pass ([memory-recall.md](memory-recall.md) rule 29). |
| `MIN-30` | A stray file duplicates the engineering namespace: unreachable by every reader, and inside the watcher's glob. |
| `MIN-31` | The tidy prompt asks for a dated prose line in a machine-written record, where the journal reader skips it and the ingest drops it. Tidy's own record never survives. |
| `MIN-32` | The canary reports the path unit disabled and only revives it in-session, so it will not come back after a reboot. |
| `MIN-34` | Two claudism detectors, unreconciled. The turn-close capture ([turn-pipeline.md](turn-pipeline.md) rules 30-32) writes a day flag log; the review judges from the journal directly (rule 39) and does not read it. The log is no longer unread — the recent-catches block ([prompt-assembly.md](prompt-assembly.md) rule 35) surfaces it at the start of a turn, and the pre-speech mirror ([speech-output.md](speech-output.md) rule 45) appends its fires and outcomes to it — so retiring it is off the table. The first piece of the corroboration is in — the review reads the day's flag log and names a live rewrite whose turn still fires the same function (rule 49). Still owed: the rest of it — telling a line she already re-said mid-turn from one that went out as drafted, deduped by sentence and pattern. Two detectors with no reconciliation will drift. |

## TESTS

**Existing:** `tests/test_notice_selfchange.sh` — 50 assertions in the most hermetic sandbox in the
suite, and the model for every other test; among them, `.git` internals under a watched drawer and
under an extra watch directory fire nothing (rule 25a), and the run window both ways (rule 25b): a
write whose mtime sits inside her own window — a live registration, a finished session's log line,
a reaped `?`-duration line, or the grace just past the end — stays quiet, while the same write with
no session running still fires exactly one wake, and a deletion inside a live window still surfaces. `tests/test_claudism_scan.sh` — the review reads the
spoken half only and never a job's entry; counts replace, never double; a missing list is a silent
skip; the wake is booked through the door in the review's own name; a dead model still writes the
report with the rewrites marked missing. `tests/test_promise_check.sh` — rules 51-53: the sweep
hands the model the day's replies with their outcomes and the live ledger, surfaces a genuine miss
as a ledger record and one morning wake in the checker's name, and books nothing on a clean day.
`tests/test_backlog_drain.sh` — rules 54-61: the daylight window guard; the cap counted from every
dispatched-or-running job; validation skips null-shaped briefs, thin briefs, and threads already on
the ledger; a
NOTHING verdict with nothing of tonight's running ends the drain early; a blocked job door ends it
for the night; the cutoff stops dispatch; the owed-work material (rule 58b) — the sweep's ledger
misses and the pending wake reasons reach the selector as labelled sections, the live checker's
raw catches do not, and an unreadable ledger is presented as unreadable, never silently omitted;
the sweep runs before the drain inside `sleep-nightly run`; and a drain that cannot even parse its
cutoff never unstamps the night (exercised through `sleep-nightly run`).
`tests/test_backlog_drain_queue.sh` — rules 56 and 56a: the queued backlog dispatched oldest first
through `crab job dispatch` before any selection, under the cap, with `DESKCRAB_JOB_NIGHT` set on
every door call; a builder still standing `dispatched` holds its cap slot; a night with no
engineering threads at all still drains the queue, spends no selection call, and ends when the
queue is dry; the cutoff re-checked before each dispatch so nothing new starts past it; a
refused queued brief skipped for the night while a blocked door ends it; and the dry run naming
its would-dispatches without starting anything.
`tests/test_backlog_drain_utf8.sh` — rule 58a: with an em-dash straddling every one of the four
byte budgets at once, the prompt the selector receives is valid UTF-8, plain grep — no `-a` —
still reads it, each split character is dropped whole at its boundary, an em-dash clear of the
boundary survives intact, and the budgets themselves still hold.
`tests/test_sleep_stamp_coverage.sh` — rule 14a: the header parsed to chunks, chars and passes;
the pass-count fallback where the header predates stating it; a field the log never states is
omitted; a log with no header still stamps and still counts as slept; and the status command
renders a widened and a legacy added-only stamp alike.
`tests/test_symlink_deploy.sh` — rule 6a: the deployed shape rebuilt as a directory symlink into
the checkout's `lib/`; the nightly phases and the promise auditor invoked through it source the
library and answer, the sweep runs through it to its own closing line (rule 53a), and a whole
night run through the symlink stamps with every phase speaking for itself — no phase sourcing a
`lib/common.sh` that does not exist, no unbound variable, no `PHASE SILENT` complaint.
`tests/test_sleep_phase_silence.sh` — rules 14b and 53a: a chatty night carries no complaint; a
phase that exits zero saying nothing is named `PHASE SILENT` in the night log itself; a phase
that dies leaving only noise in another voice draws both complaints, did-not-finish landing in
the log file too; a phase that fails after speaking draws only did-not-finish — and every such
night still stamps and still exits with the ingest's zero.

**To be written:**

- `tests/test_sleep_nightly.sh` — a failed ingest does not stamp; a night with nothing new does; the
  status command reports rot past the threshold; something reads that status.
- `tests/test_tidy.sh` — once the units are in the repository: tidy declares its writes, touches no
  memory, leaves its own dated record somewhere a reader reads, and never creates a second
  namespace.
- `tests/test_canary.sh` — the repeating poke; the three outcomes; a disabled path unit produces the
  durable-repair message, not a silent in-session start.
- `tests/test_units.sh` — every scheduled process named in this spec has a unit file in the
  repository, is persistent, and its command resolves.
