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
13. Sleep MUST run its model calls under the account chain wherever they run the Claude engine. A
    codex-named call has one login and no chain: it honours and records the codex cooldown instead
    ([model-backends.md](model-backends.md) rules 12-13), and never walks accounts codex does not
    have.
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
    phase — the claudism review, the promise sweep, the twin-merge pass, the night's work — owes
    the night log at least one line opening with its own name (`claudism-scan:`, `promise-check:`,
    `eng-merge:`, `night-work:`); sleep watches each phase's stretch of the log, and when a phase exits
    leaving no such line there, sleep MUST say so loudly — `PHASE SILENT`, naming the phase and
    its exit status — in the night log itself as well as on stderr. A phase's non-zero exit is
    likewise named in the log, not on stderr alone, where only the journal would carry it. The
    complaint is evidence, never a gate: the stamp and the night's exit stay the ingest's own
    (rules 8 and 10) — a night is not unmade by a phase that could not speak, it is only never
    silent about one.

### The night's judge — every sleep judgment is one mind's

14c. The night is dream-shaped on purpose — form long-term memory from the day's material, then
    reconcile and deduplicate the records and the owed work, then spend the idle hours on at most
    two concurrent builders until the cutoff — and every JUDGMENT inside that shape is made by ONE
    judge. Every retention call (what the day's material earns as a record), every deduplication
    call (which two records are one complaint), every reconciliation call (which promises
    genuinely died), and every work-selection call (what the night buys) runs on the night-judge
    model at its own reasoning effort, routed to its engine by the model name alone
    ([model-backends.md](model-backends.md)). The shell-side walk is ONE implementation,
    `lib/nightly-judge`, sourced by every judging phase; nothing on the sleep path re-implements
    it, and the ingest's python side mirrors the same routing rather than inventing a second
    engine rule. (The user's correction of 2026-08-25, the record
    `sleep-should-be-orchestrated-and-judged-by-sol-h`.)
14c-i. ONE judge means ONE knob. `NIGHT_JUDGE_MODEL`/`NIGHT_JUDGE_EFFORT` — `gpt-5.6-sol` at
    `high` by default — is what every role above resolves from, and moving the night's judge MUST
    be that one pair changed in one place. The four role pairs
    (`MEMORY_INGEST_MODEL`/`MEMORY_INGEST_EFFORT`, `ENG_MERGE_MODEL`/`ENG_MERGE_EFFORT`,
    `PROMISE_SWEEP_MODEL`/`PROMISE_SWEEP_EFFORT`, `NIGHT_WORK_MODEL`/`NIGHT_WORK_EFFORT`) remain,
    each overriding the shared pair for its own role, and each MUST take its DEFAULT from the
    shared pair rather than naming a model itself. A role that repeats the literal is the defect
    this rule exists to prevent: the policy was already "one judge", but it was written as four
    independent literals across two languages and named in no config, so on 2026-09-02 — the
    judge's account out of credits, every knob the config knew about already moved — the night
    still could not run. She could not sleep, and the switch that was supposed to move her looked
    complete. The shared pair is exported, so the ingest's python side reads the same value the
    shell phases do.
14d. Sonnet summarises; it never judges. The summariser tier's only place in the night is
    producing summaries handed TO the judge — the ingest's stage 1
    ([memory-recall.md](memory-recall.md) rules 27 and 29a) — and a summariser-tier model MUST
    NOT decide what survives, what merges, what died, or what work runs. Opus holds no sleep
    judgment role either: the 2026-08-06 phase-2 line ("what is a duplicate … Opus, always") is
    superseded on this path by the 2026-08-25 ruling, and rule 53c carries the new default. The
    claudism review's rewrite call is not a judgment role — nothing survives or runs on its
    answer (rules 39 and 42) — and the post-turn reinforcement judge (`MEMORY_JUDGE_MODEL`) is
    a live-turn role, not a sleep one; neither moves under this section.
14e. No cheaper model may judge in the judge's place. A judgment the judge cannot make tonight —
    the codex engine cooling, a refusal, an unparseable answer — is NOT made: the pair stands,
    the day is not swept, the round selects nothing, and the walk says so in its own name on the
    night log. A model fallback on a sleep judgment call is exactly the substitution this
    section forbids (`NIGHT_WORK_FALLBACK_MODEL` is retired; the sweep no longer borrows the
    live checker's model pair). The ingest's judge failing fails the ingest itself, so a night
    that could not judge is never stamped as a night that happened (rule 8). A codex-named
    judge has one login: a refusal records the cooldown and ends the walk
    ([model-backends.md](model-backends.md) rules 12-13), falling back to no one; a
    Claude-named judge override still walks the flat account list (rule 13) on its one model,
    at the classify profile's own default effort — the effort knob binds on the codex engine,
    where the mandated judge lives.

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

21a. The shelf-line check. Before tidy's model job is dispatched, the tidy unit runs the machine
    check `lib/shelf-check` over the wants shelf. A shelf entry is ONE line — the discipline the
    shelf's own header claimed when the record behind this rule was written (2026-08-07: "a
    shelf line is a line, the history lives in `wants/<slug>.md`"; the header has since been
    rebuilt after a clobber, but the claim is the shelf's design and this rule holds it): the
    line is the title and at most a short status clause, and the history lives in the want's
    own `wants/<slug>.md` document. The
    check measures every entry line (selected by the one shelf reader's pattern,
    [prompt-assembly.md](prompt-assembly.md) rule 20) against the shelf-line budget:
    `WANTS_SHELF_LINE_BUDGET`, default 500 bytes — the number this spec states as the
    operationalisation of "a line", sized so a title with a status clause passes (the live
    shelf's longest honest line measured 305 bytes on 2026-08-16) and a line carrying its
    nightly findings does not (the 2026-08-07 shelf averaged 2.6 KB per line exactly that way).
    The check REPORTS and NEVER rewrites: deciding which sentences are topic and which are
    history is her judgement, never a machine's, so the check MUST NOT edit, move, or reorder a
    byte of the shelf or of any want document. An entry over the budget is named with its title,
    its measured size in bytes, the budget, and the `wants/<slug>.md` document its history
    belongs in — the document the line itself points at, or the plain statement that the line
    names none.
21b. The check's finding is never silent, and never a gate. A check that found over-budget
    entries prints them in its own name (`shelf-check:`) to its caller's log, writes
    `${STATE_PREFIX}-shelf-overruns.txt` — the same shape as the assembler's rule 36/40a
    records ([prompt-assembly.md](prompt-assembly.md)) — and exits non-zero; the state block
    renders the record while it stands, which puts the fact in `crab status` and in every
    speaking prompt until a later check finds the shelf clean and removes it. A clean shelf, a
    missing shelf, or an unset `WANTS_FILE` prints one line, removes the record, and exits
    zero. The check's exit status MUST NOT block the tidy job behind it — moving the flagged
    history into the want's document is exactly the judgement work tidy's own brief names, and
    a shelf that needs tidying is the last reason to skip the tidy. By hand the same check is
    `crab shelf-check` — its own dispatch case, never the catch-all's speech
    ([turn-pipeline.md](turn-pipeline.md) rule 6a).

21c. The undestinated-claims check. Beside the shelf-line check, the tidy unit runs the machine
    check `lib/tidy-claims run` over the day just ended — the journal day before the night the
    tidy runs in, her voice only: rows whose kind is not `job` (a builder's entry is a log, not
    her speech — rule 41's own line), the display half stripped the anchored way of
    [speech-output.md](speech-output.md) rules 3 and 4. The check looks for the sentences that
    vouch their own durability and cannot point at anything. A sentence is a candidate when all
    three hold at once: it reports a thing as put into writing (written down, wrote down,
    written up, jotted down, noted down, set down, filed, on the record); it vouches the thing
    is therefore SAFE ("where it will hold", "so it survives the night", "so it can't crawl
    back out", "so it binds", "pinned"); and it names no destination — none of want, Library,
    conduct, record, thread, moments, shelf, commit, memory, spec, or list anywhere in the
    sentence. For each candidate the check then looks for the artefact that could be the thing
    claimed: a file under its roots — the state dir and this repository's tree by default;
    `TIDY_CLAIMS_ROOTS` replaces the set, and the personal drawers live data adds are never
    named in this repository — touched inside the claim's own window (the claiming turn,
    widened by `TIDY_CLAIMS_LEAD` before and `TIDY_CLAIMS_SLACK` after, defaults 600 and 120
    seconds), whose text shares a PHRASE — a consecutive word pair, never a lone word — with
    the claim's own paragraph. The pair test and the paragraph scope are both measured, not
    taste: single shared words cleared the known-false claim of rule 21d with a neighbouring
    record's machinery vocabulary, and whole-turn scope cleared it again with the vocabulary
    of the OTHER subject the same turn discussed. Machine plumbing — the journal, the jobs and
    wakes ledgers, databases, logs, metrics, caches — is never an artefact: the claim is that
    SHE wrote a thing down, and only something a reader reads can hold that. A claim with an
    artefact behind it is cleared, the artefact named; only the claims with nothing behind
    them are findings.
21d. Why the vouch, why the night, and what this check may never become. The measured fortnight
    (2026-08-25, the 42nd mark of the why-i-believe-myself audit): 259 durability claims in
    the spoken halves, of which NINE vouch the thing is therefore safe, and only FOUR of those
    name no drawer — and one of the four was provably false at the moment of speaking
    (2026-08-15 01:55, "Taken, and written down where it will hold", while that night's tidy
    grepped conduct/ for the rule and found nothing newer than four days old, then made the
    missing file itself). The fault is a LATENCY, not an absence: the artefact exists by
    morning exactly because the night went and made it, so no audit reading a later day's disk
    can ever see the gap — only a check run on the night, over the day just ending, against
    that day's own mtimes. Hence this check lives in the nightly tidy and nowhere else, and a
    replay over old days OVERCOUNTS by design (notes since consumed, mtimes since moved) —
    replay is calibration, never a verdict on a past day. And the check MUST NOT become a
    claudism-style pattern: a bare regex on "written down" fires on 259 sentences to catch 9 —
    the seventh-net mistake the want has refused six times — so the narrowing is the vouch,
    the destination-absent test and the same-day artefact lookup, never a wider phrase list,
    and the expected steady-state load is about four sentences a FORTNIGHT. A night that
    reports dozens is a broken check, not a broken journal. Findings are never silent and
    never a gate (rule 21b's bargain): they print in the check's own name (`tidy-claims:`),
    land in the day's report under the data dir, and are filed — as the 03:25 tidy of
    2026-08-15 filed by hand — as ONE open engineering record for the day, through `crab eng`
    and only through it ([engineering-records.md](engineering-records.md) rule 4), created
    once: a re-run of the same day names the standing record and never files twice, and a
    clean day files nothing at all. The check's own writes are the report and that record,
    both declared where declaration is owed (rule 6; `lib/eng` declares its own), and its
    exit status MUST NOT block the tidy job behind it.

21e. How the check's knobs resolve, and why the unit carries no `EnvironmentFile`. Every knob
    the check reads (`TIDY_CLAIMS_ROOTS`, `TIDY_CLAIMS_DIR`, `TIDY_CLAIMS_LEAD`,
    `TIDY_CLAIMS_SLACK`, `DAY_JOURNAL_DIR`) resolves environment first, conf second, shipped
    default last. The tidy unit sources nothing on the check's execution path, so an
    environment-only read left the conf's `TIDY_CLAIMS_ROOTS` invisible to the one run that
    matters — the nightly one — and the personal drawers the conf names went unscanned every
    night the setting stood (found 2026-08-25). The conf read lives in the SCRIPT, not the
    unit: when a knob is absent from the environment, `lib/tidy-claims` asks a bash that
    sources `common.sh` — and through it the live conf, with every conf convention including
    `$HOME` expansion — from the script's own realpath-resolved directory (rule 6a: the
    deployed path is a symlink, and an unresolved dirname can name a directory with no
    `common.sh` in it). An explicit environment variable MUST still win over the conf, and a
    missing, broken or slow `common.sh` MUST degrade silently to the shipped defaults — the
    check never raises over configuration. The unit MUST NOT gain an `EnvironmentFile`:
    `common.sh` does not blanket-export conf values, and most conf values lean on `$HOME`,
    which systemd's parser would import unexpanded for every neighbour the file carries.

### The self-change watcher

22. The watcher is driven by a path unit using the kernel's own change notification. No polling
    daemon.
23. The watcher MUST seed silently on first run, so an existing tree never fires.
24. The watcher MUST settle a burst of changes into one wake.

24a. One pending re-check, never a chain per trigger. The settle is a single named unit, so a burst
    leaves ONE re-check armed however many triggers arrive; a trigger that finds it armed is already
    covered by it and leaves. Minting a unit per trigger instead does not merely waste units: each
    chain re-defers on its own counter, so a busy minute leaves dozens alive at once — 82 on
    2026-09-01 — every one of them landing at the same moment to run the whole tree scan and
    attribution walk in parallel, on a laptop, over the same changes.
24b. Judgement is single-threaded. Between reading the tree and advancing the snapshot the watcher
    does the entire attribution walk, and two runs inside that window read the SAME change set and
    each book their own wake — rule 24's one wake per burst broken by concurrency rather than by
    counting, which is how one change woke her twice on 2026-08-28 20:30:00 and again twice on
    2026-08-30. A run that finds another judging MUST NOT judge beside it: it books the one re-check
    and leaves. Where it cannot book, it waits for the lock and then re-reads the tree against the
    snapshot the other run advanced, so what it judges is only what is genuinely still new.
25. Her own writes MUST NEVER wake her. A change is dropped when a write declaration covers it, or a
    live session's claim names it, or its mtime falls inside one of her own run windows (rule 25b),
    or it lands under a detached job's workdir inside that job's window (rule 25c), or it is a
    plumbing path only her own machinery writes (rule 25d), or it is the memory database and one of
    her sessions ran recently.

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
    Detached builder jobs are not sessions and get no window from this rule; their claim is
    rule 25c's.
25c. The job window. A detached builder job she dispatched is her own hand at one remove. The
    watcher reads the jobs ledger it already sits beside — each sidecar's workdir, dispatch time,
    state, finish time, and collection time — and a creation or modification whose path lies
    under a job's workdir and whose mtime falls inside that job's window is that job's write and
    MUST stay quiet. The window follows the state, because only the state says whether the hand
    could still be moving. `dispatched` and `running` claim from dispatch to now, capped at a
    ceiling past dispatch (24 hours by default, `NOTICE_SELF_JOBWIN_CEILING`): the longest run
    the ledger has ever recorded is 3.2 hours, so a day cuts no real builder short, while a
    sidecar orphaned in `running` by a crashed runner stops claiming a tree after a day instead
    of for ever — a byte from inside the ceiling is still the orphan's own, a byte after it
    reports. `finished` claims from dispatch until its recorded finish plus a short collection
    grace (600 seconds by default, `NOTICE_SELF_JOBWIN_GRACE`): collection runs in the runner's
    own process moments after the finish is written, so ten minutes covers a loaded machine and
    the collector's own hand in the tree, and nothing more. It is NOT true of this ledger that
    collection closes every claim — 45 sidecars measured 2026-08-24 predate the collector, sit
    in `finished` with no collection time at all, and will never collect, because the
    collector's terminal state is `collected`, not `finished`; while `finished` ran open-ended,
    each claimed its workdir for ever, every write in the deskcrab tree was attributed to the
    oldest of them, thirteen days dead, and the report called it "running" (05:49, 2026-08-24).
    A collected job's claim still ends at collection, no grace; `failed`, `stopped` and `died`
    still close at their recorded finish. When several windows cover one byte — two jobs
    sharing a workdir — the MOST RECENTLY STARTED job wins the attribution, never the first
    found in ledger order, so a live job always outranks a stale one over the same tree. The
    wording follows the state wherever a claim is named: a job MUST NOT be described as running
    unless its state is `dispatched` or `running` — the quiet line and the report quote the
    state they matched. The claim is per job-window, not per event: every save the
    job makes, for the job's whole life, is the one claim, so repeated saves to one file never
    re-fire per mtime (two alarms four minutes apart from one builder, five in one night,
    2026-08-22 through 2026-08-24). A change the job has already committed is claimed exactly as
    a mid-edit one — a clean commit naming the file is not evidence of an outside hand (919b167
    was flagged so). Several jobs each claim their own workdir independently and
    simultaneously; a byte from before dispatch or after a window's close belongs to nobody and
    fires. A deletion is NEVER excused by a job window — rule 28's discipline holds — and a
    claimed path that surfaces anyway, in the log or in a report, MUST name the claiming job id,
    so the claim over a tree is traceable rather than invisible. The accepted cost mirrors
    rule 25b's: an outside edit inside a job's window is silenced, judged
    cheaper than the class this closes — eleven-plus false alarms in three nights, every one an
    authorised builder's own brief-named work.
25d. The plumbing list. The day journal drawer and the wakes ledger are written by exactly one
    hand each — the journaller and the wake machinery — so a creation or modification there
    never reports, by path, unconditionally: no declaration, session window, or job is involved
    (`journal/2026-08-23.jsonl` was reported at 03:26 although the journaller is the only writer
    on the machine). A deletion there still surfaces — a vanished day of the journal is exactly
    the kind of news rule 28 exists for.
25e. The private shadow diff. `deskcrab.conf` is not git-tracked, so an outside edit to the file
    that sets her model, effort, voice and accounts woke her with "no diff available" and nothing
    else (2026-08-28 10:15, and again blind at 12:31 — the record
    `the-watcher-cannot-diff-the-file-that-configures`). For every watched constituent that is a
    TEXT file no git repository tracks — the live conf, the persona sheet, anything
    `SELF_WATCH_EXTRA` names outside a repo, an untracked file inside the code repo — the watcher
    keeps a persistent private shadow copy under the data dir
    (`~/.local/share/deskcrab/self-shadows/<absolute path>`, override
    `NOTICE_SELF_SHADOW_DIR`), and the report renders a unified diff from the shadow when such a
    file surfaces. The shadow is refreshed ONLY after the report has landed at its final name, so
    a burst of edits between reports shows the whole distance travelled, and a report that could
    not be written leaves the old shadow — and the unshown distance — intact for the next
    attempt; a change judged her own advances the shadow at judgement, with no report, so her own
    hand is never billed to the next outside diff. Bounded and explicit, never silently partial:
    a file over the cap (`NOTICE_SELF_SHADOW_MAX`, default 1 MiB) is named too large with its
    size, and never copied; a binary file is named binary; an unreadable one unreadable; a file
    already gone again says so; a deletion names the retained shadow — kept, never dropped, so
    the last-seen content stays recoverable — and never inlines it; a diff past
    `NOTICE_SELF_SHADOW_DIFF_LINES` (default 400) is cut with the cut named. The conf holds
    secrets (`SERVE_SECRET`), so the shadow tree is 0700, its copies and every report 0600, and a
    diff reaches the report file and nowhere else — never the wake text, the log, stdout, or a
    notification. Git-tracked files in the code repo keep their git diffs exactly as before, and
    a file tracked by a git repository of its own (a conduct file) keeps its commits as the
    record and gets no shadow. The manual baselines the 2026-08-28 stopgap left under
    `self-baselines/` are incorporated, never silently discarded: the first shadow of a conf-dir
    file with a same-named manual baseline seeds FROM the baseline, so the first report after
    this rule lands still diffs from the last state a hand recorded.
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
40a. An entry whose pattern will not compile is skipped, so that pattern never ran and the
    night's silence is not evidence about it. The report MUST NOT call such a night clean: with
    any entry broken, a no-catch headline says nothing was caught among the entries that ran and
    counts the entries that did not compile, and on a night with hits or mentions the
    broken-entry count stands immediately before the headline — the reader is never handed a
    verdict and then corrected. The per-entry warning naming each broken entry and its error
    remains, and a night with no broken entries reads exactly as before. The morning wake's
    agenda (rule 44) takes the same branch as the report's headline, from the same signal: with
    any entry broken the agenda MUST NOT say a clean night — it says plainly that entries never
    compiled and did not run, counting and naming them — and the clean wording is kept only for
    the genuinely clean night, no catches and no broken entries. The sentence read at half nine
    may never contradict the report sitting beside it.
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
    moment she discusses her own review. The test is ONE implementation — `classify_use` in
    `lib/claudism-mirror`, the library half the capture keeps line-identical, the corpus
    reader imports, and this review loads — and since 2026-08-24 the live mirror asks it at
    fire time as well ([speech-output.md](speech-output.md) rules 45 and 50): a live mention
    is skipped, never held, and still lands in the flag log as `use=mention`, so nothing this
    review counts is lost to the skip.
48. The substitution watch. The report MUST place a function's members side by side across the
    recent nights and say plainly when the family's total holds while its members churn — a
    member gone quiet beside a sibling that rose is the habit changing words, not dying. The
    verdict on the total is COMPUTED, never a fixed tail: tonight's family total is measured
    against the prior nightly average, and the note may say the total holds only when the two
    agree within one occurrence or a quarter of the prior average, whichever is larger — an
    integer total against a fractional average never lands exactly, and the notes of
    2026-08-20..23 that printed "holds" over a family down by half or more are the fault this
    band closes. Outside the band the note MUST state the direction and the size of the move
    instead — a total materially down is the family going quieter while its residue changes
    words, a weaker claim than substitution; a total up is the move growing even as it changes
    words — and MUST NOT print a premise it did not measure. Churn at a family total of one is
    arithmetic, not evidence: no note below a total of two tonight. A member first counted
    tonight MUST NOT stand as the risen side — an entry has counts only from the night it was
    created, so an empty history is absence of measurement, not absence of the habit. A
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

51. After a night that happened — ingest succeeded, stamp written — and BEFORE the night's
    work, sleep runs the promise
    sweep (`lib/promise-check sweep`) over the day that just ended: the day's journal, every
    channel's replies with the outcome and work trace each session left, beside the day's
    promise ledger. One model call, and it is the night judge's (rules 14c-14e):
    `PROMISE_SWEEP_MODEL` at `PROMISE_SWEEP_EFFORT`, default `gpt-5.6-sol` at `high`, with no
    fallback model — never the live checker's model pair, which stays a live-turn role
    (`PROMISE_CHECK_MODEL`/`PROMISE_CHECK_FALLBACK_MODEL`, untouched). Rule 13 applies as
    written on either engine. Every channel's outcome carries its turn's own tool trace — the
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
52a. The sweep's judge reads more than the day's own turns, because the day's work is wider
    than its speech. Three further records ride the sweep's prompt as their own labelled
    sections, all gathered mechanically and model-free: every path-shaped token the day's
    replies name, statted from the disk itself — exists, with its modification time, or NOT
    found — because a dated artefact whose mtime is consistent with the claim is the claim's
    own witness, whoever's hand wrote it and however compressed the speaking turn's outcome
    line reads; and the resident game player's outcome record for the swept day (the outcome
    stream `outcome-queue.jsonl` under the game dir, `~/.local/share/deskcrab/game`, override
    `DESKCRAB_GAME_DIR`), digested and bounded, because the resident player works outside
    every speaking turn by design — its acts land on the game's own record and on no journal
    row, so a commitment about the game is judged against that record, never against the
    turns' silence; and the day's commits across her repositories
    ([turn-pipeline.md](turn-pipeline.md) rule 32bb), because a day's code work exists as
    commits and the mtime record cannot see them. The 2026-08-28 sweep called fifty commitments missing and direct
    verification found forty-five fulfilled in exactly these records (the record
    `the-end-of-day-promise-sweep-calls-existing-arte`): a blank instrument was promoted into
    a fact about the world. Either section failing to gather is presented AS unreadable and
    named on the run trace, never silently omitted — and neither section loosens rule 52: a
    claim no artefact, game record, or journal trace backs surfaces exactly as before.
53. Every miss lands as a sweep record on the durable ledger — each row carrying the run's
    durable identity beside its content: `sweep_time`, one timestamp the run stamps once
    before its first append and repeats verbatim on every row however the wall clock ticks
    between them, and `item`, the miss's 1-based ordinal within the run — and the day's misses
    are surfaced together as ONE morning event wake through the queue's one door, in the
    checker's own identity (`promise-check`), quoting the missed promises numbered by their
    `item` and naming rule 53f's resolution door beside them. A clean day books nothing —
    the sweep is a debt collector, not an exercise, and its run-trace line is its record. The
    sweep's failure MUST NOT unstamp or fail the night: the stamp and the exit stay the
    ingest's own (rules 8 and 10), exactly as the claudism review's failure must not.
53a. The sweep owes the night log its closing line. Every path out of the sweep — no journal, no
    replies, no verdict, clean, or misses booked — prints one line in the checker's own name
    (`promise-check: sweep <day>: …`) to stdout beside the run-trace record of rule 53, so the
    night log shows the sweep reached its own end and rule 14b's detector can tell a sweep that
    ran from one that never started. The guards ahead of the mode dispatch (no CLI, no python)
    still exit silently on purpose: a sweep that cannot start is exactly what rule 14b flags.
53f. A sweep record is debt, and debt has a settlement shape. A later `type: sweep-resolution`
    row on the same ledger — `day`, `sweep_time` and `item` naming exactly one sweep row, a
    `decision` of `fulfilled`, `struck` or `booked`, and the `evidence` in a sentence —
    resolves that row durably: the night's work MUST NOT redispatch a resolved miss (rule
    58b), whatever the miss's age. Before this rule the drain read every recent raw
    `type: sweep` row forever, so reconciled debt stayed eligible for redispatch until it aged
    out (the record `the-end-of-day-promise-sweep-calls-existing-arte`).
    `lib/promise_ledger.py` is the ONE reader of this identity — the grouping of raw sweep
    rows into runs and the matching of resolutions against them live there and nowhere else. A
    stamped run matches its `sweep_time` exactly, never by nearness, and a resolution carrying
    any decision outside the three named above settles nothing. A sweep row from before the
    identity landed (no `sweep_time`, no `item`) is identified by
    its run — same day, write times within moments of each other, in ledger order — and by
    its ordinal within that run, the resolution's `sweep_time` matched to the run's first
    write within slack: the fifty reconciliation rows of 2026-08-29 name `03:23:05` while the
    run's later rows landed at `03:23:06`, and they MUST resolve.
    `lib/promise-check resolve <day> <item> <decision> <evidence>` is the writing door: it
    finds the day's newest sweep run on the ledger, refuses an item the run never surfaced,
    and appends the resolution row. Resolution is per item and evidence-bearing, never a
    blanket: a decision settles the one row it names, and an unresolved miss stays owed
    however many of its neighbours resolved.

### The twin-merge pass — part of sleep, before the night's work

The drawer accumulates the same complaint written on different nights. The memory store has had a
merge-identical-ideas discipline from the start ([memory-recall.md](memory-recall.md) rules 28, 39,
51); the engineering records had none, and the night's-work "dedupe" (rules 56a and 59) is only the
state machine refusing to dispatch one record twice — nothing ever read two records and noticed
they are the same complaint. After a fortnight of the drain running blind over 60+ open threads,
near-twins are a certainty, not a risk (the record
`merge-twin-threads-before-the-drain-picks-work-r`, 2026-08-23).

53b. After the promise sweep and BEFORE the night's work, sleep runs the twin-merge pass
    (`lib/eng-merge run`) over the LIVE open records — the same drawer rule 58c hands the
    selector, and only its `state: open` records: a settled or dead record is already out of the
    drain's sight and is never scored. The pass normalises each record (title and body, the entry
    headings stripped) and embeds it through the memory store's own embedder
    (`MEMORY_EMBED_URL` / `MEMORY_EMBED_MODEL`), scores every open pair by cosine, and hands
    pairs at or above the candidate threshold (`ENG_MERGE_THRESHOLD`, default 0.80) to a
    judgement call, highest first, bounded by `ENG_MERGE_MAX_JUDGED` (default 8) — and a bound
    that bites is announced with the count it dropped, never silent (rule 58a's discipline). The
    threshold is a CANDIDATE GATE, measured, and deliberately NOT a merge line: measured
    2026-08-24 over the live drawer (56 open records, 1540 pairs), known-distinct same-area pairs
    score up to 0.8784 — one of them a record whose own title declares it distinct from its
    neighbour — while true twins were observed at 0.8548 and 0.8630. The distinct-pair ceiling
    sits ABOVE the twin floor, so no embedding threshold can decide a merge; every candidate goes
    to judgement. 0.80 is that distribution's p98, ~0.05 under the lowest observed twin. An
    embedder that does not answer scores nothing, says so, and ends the pass — never a guessed
    score.
53c. The judgement is deciding what is a duplicate, which is taste, and taste on the sleep path
    is the night judge's (rules 14c-14e): `ENG_MERGE_MODEL` at `ENG_MERGE_EFFORT`, default
    `gpt-5.6-sol` at `high` — the 2026-08-25 ruling supersedes the 2026-08-06 phase-2 line
    (design-memory-store.md, 22:49: "what is a duplicate … Opus, always") on this path — under
    rule 13's engine discipline, with NO model fallback — a pair the model never answers is
    skipped, never guessed at by a cheaper model. The rule the judge enforces, encoded in its prompt:
    same-COMPLAINT merges only, never same-AREA — two records about chess are not a merge; two
    records about the same collapse are. The verdict carries the judge's own confidence in its
    leading tokens — `MERGE CERTAIN` (the two records state one complaint and no reading
    separates them), `MERGE LIKELY` (probably one complaint, but a reading exists in which they
    are distinct), or `DISTINCT` — and a person's ruling on the pair outranks the judge's: the
    prompt tells it that a record stating it is distinct from the other, or that a previous fold
    between them was wrong, is answered DISTINCT. Every non-answer is conservative: a refusal, an
    unparseable verdict, and DISTINCT all mean both records stand — and so does a verdict line
    that carries BOTH tokens: on the first live run (2026-08-24) the judge twice changed its mind
    mid-line ("MERGE — no, wait: DISTINCT — …"), and a leading-token parse proposed the two folds
    the judge's own sentence retracts. A MERGE is accepted only when its line never says
    DISTINCT.
53d. The nightly pass FOLDS what the judge is certain about and proposes the rest: sleep runs
    `lib/eng-merge run --apply`, and under `--apply` only a verdict at or above the fold gate is
    folded. The gate is `ENG_MERGE_FOLD_CONFIDENCE` (environment or `deskcrab.conf`; it lives in
    `lib/eng-merge`'s knob block), default `certain` and deliberately conservative: only
    `MERGE CERTAIN` folds. `MERGE LIKELY`, and a bare `MERGE` that states no confidence — a
    judge that ignored the asked-for form — stay dry-run proposals on the night log exactly as
    before: winner, loser, score, confidence and the judge's reason named, for a hand to fold or
    discard. An unrecognised gate value reads as `certain`, never wider, and `run` without
    `--apply` stays the pure dry run — proposals only, nothing written — for running the pass by
    hand. An applied fold goes through `crab eng` and only through it
    ([engineering-records.md](engineering-records.md) rule 4), never a hand edit of a record
    file: the WINNER is the record with the earlier `opened` — which it keeps by construction,
    since the tool never rewrites `opened` — the loser's whole body is appended to the winner as
    one dated entry (`eng touch`) whose note names the fold, the loser, the score and the judge's
    confidence, and the loser is killed with `settled_by` pointing at the winner's id
    (`eng kill`). No body is ever lost: a fold appends, never truncates or rewrites the winner's
    entries, and the dead loser keeps its own body whole. A pair whose records are no longer both
    open by the time the fold reaches them is skipped, with a line. A WRONGLY-FOLDED thread is
    recovered through `crab eng` alone, because nothing was destroyed: `crab eng show <loser>`
    reads the grave whole, `crab eng new <title> --body … --opened <its original opened>` reopens
    the complaint as its own open record (the dead file keeps its name; the tool suffixes the new
    id), and the reopened body MUST state that the fold was wrong and what separates the pair —
    that written ruling is what rule 53c's judge reads on the next pass, so the same wrong fold
    is not made again — with a `crab eng touch` on the winner recording the reversal.
53e. This pass and the dispatch dedupe MUST NOT be confused for each other: rule 56a's state
    machine and rule 59's ledger stop the same RECORD being bought twice; this pass is the one
    thing that reads two records and notices they are the same complaint written twice. Its
    failure never unstamps or fails the night (rules 8 and 10, the same bargain as every phase),
    and it owes the night log a line in its own name (rule 14b, `eng-merge:`).

### The night's work — part of sleep, and the night's owed-work sweep

The engineering threads accumulate faster than waking hours spend them, and the stretch between
sleep's stamp and the morning is machine time nobody is using. The night's work turns that idle stretch
into builders: the night's owed work — the queued backlog the daytime dispatch policy shelved
([jobs.md](jobs.md) rules 30-34), the LIVE open engineering records (rule 58c — the records
drawer `crab eng` keeps, never the frozen pre-records archive), the promises the sweep found genuinely missed,
the work already sitting on the wake queue's books — becomes dispatched jobs, round after
round, for hours, until a wall-clock cutoff — and then the night finishes normally, so the
assistant ends it idle and available. Sleeping is an ACTIVE activity, the user's own design
(2026-08-11 00:26 and 09:40): a night that only reads the day and then sits idle is not the sleep
that was asked for, and promised work must stop waiting for a live turn to personally remember it.

54. After a night that happened — ingest succeeded, stamp written — and AFTER the promise sweep,
    as the night's last phase, sleep runs the night's work (`lib/night-work run`) over the
    open owed work. The sweep runs first on purpose: its reconciled end-of-day misses are part of
    the night's material (rule 58b), and the night's work is the phase that holds the night open until
    the cutoff, so everything else finishes before it starts. Its
    failure MUST NOT unstamp or fail the night: the stamp and the exit stay the ingest's own
    (rules 8 and 10), exactly as the review's and the sweep's must not.
55. The night's work dispatches only through the job door (`crab job`), never around it, so every builder
    it starts carries the whole jobs contract — sidecar, live log, completion wake, the
    blocked-versus-failed distinction, the null-brief guard. The night's work itself MUST NOT speak, book
    wakes, or open windows; its record is its ledger and the night's log.
56. Dispatch stops at a hard wall-clock cutoff (`NIGHT_WORK_CUTOFF`, default 06:00 local, the
    user's named line): no NEW dispatch at or past it, ever; builders already in flight are left
    to finish. The cutoff MUST be re-checked immediately before every dispatch, not only at a
    round's start — a selection call can take minutes, and a dispatch a minute past the line is a
    dispatch past the line. The default gives the 03:10 night nearly three hours of builders —
    sleeping through the night is doing, not idling — and ends well clear of the morning, so she
    meets it idle and available. (The first cut defaulted to 04:00, fifty minutes after the
    timer: an active night that was structurally a nap. The second defaulted to 08:00 and ran
    builders into the morning; 06:00 is the user's stated hard line.) A run
    that begins when the next cutoff is further away than the window cap
    (`NIGHT_WORK_WINDOW_MAX`, default six hours) MUST NOT dispatch at all — a missed night
    caught up at noon (rule 2) still sleeps, but it does not fill the daylight with builders.
56a. The queued backlog goes first. Each round, before any selection call, the night's work dispatches
    the records the daytime policy shelved ([jobs.md](jobs.md) rule 30) — oldest first, through
    `crab job dispatch <id>`, never around the door — against the same cap and the same cutoff.
    Queued briefs are already-written work: they cost no model call and no judgement, so they
    spend the night's slots before the selector is asked to invent anything. The queue is the
    night's FIRST material, and it is taken up even when no engineering threads exist at all: missing
    selection material switches off the selector, never the queue, and such a queue-only night
    ends when the queue is dry and nothing of the night's is still in flight. The night's work sets
    `DESKCRAB_JOB_NIGHT=1` on every job-door call it makes, which is how the door knows the
    night window is open (jobs.md rule 31); nothing else ever sets it. A queued dispatch the
    door refuses for any reason but the block marker is skipped for the rest of the night and
    named in the night log — never retried in a loop — and the block marker ends dispatch for
    the night exactly as rule 60 says, because the wall in front of one builder stands in front
    of them all. The dry run of rule 61 names each queued brief it would have dispatched and
    starts none. The state machine is the dedupe — of DISPATCH: a
    dispatched record leaves `queued`, so the ledger of rule 59 tracks only the selector's picks.
    Two records that ARE the same complaint are a different problem, and the twin-merge pass
    (rule 53e) is what notices those.
57. Concurrent jobs are capped (`NIGHT_WORK_CAP`, default 2), counting EVERY job standing
    `dispatched` or `running` and not only the night's own: a builder between the dispatch call
    and its worker's first write already holds a slot and an account, so a count blind to
    `dispatched` overshot the cap in exactly the window where one round's dispatches had not yet
    spoken as the next round counted. The cap protects the machine and the accounts, not the
    feature. A full slate is waited out, never overridden. Two is the user's standing overnight ceiling — eight
    builders at once burned through two logins inside an hour (2026-08-11 00:51), and he asked
    for two at a time, queued, never parallel swarms while she sleeps.
58. Selection is judgement — one call per round to the night judge (rules 14c-14e:
    `NIGHT_WORK_MODEL` at `NIGHT_WORK_EFFORT`, default `gpt-5.6-sol` at `high`, no fallback
    model, rule 13's engine discipline) —
    and a thread is dispatched only when it is genuinely actionable engineering work: never a note
    or an incident record with no work left in it, never work the threads record as done, never a
    duplicate of a running, queued, or recently finished job (a queued brief dispatches tonight on
    its own — selecting its subject again buys the same work twice), never a thread already on the
    night's ledger,
    never a decision that is the user's to make, and never a thread that names a hand already on
    it. When nothing qualifies and nothing the night's work dispatched tonight is still running, the
    night's work ends; it MUST NOT poll an empty backlog to the cutoff.
58a. The material the selector reads — each open record, the overflow list of records whose
    bodies did not fit, the job list — is
    bounded by bytes, and every one of those cuts MUST fall on a character boundary, through
    `utf8_head`, the document-shaped counterpart of the one shared trim
    ([wake-queue.md](wake-queue.md) DATA): a bare `head -c` on prose people wrote splits whatever
    multibyte character straddles the budget, and the lone lead byte it leaves lands in the
    selector's prompt and the night's stream log as invalid UTF-8 — the same defect that made grep
    read the entire wake ledger as binary. The partial character is dropped whole, characters
    clear of the boundary are content and survive, and the prompt handed to the selector MUST be
    valid UTF-8 whatever lands on any of its budgets. And a cut that actually happens is
    announced: a section that outgrew its budget MUST be named on the night log at the moment it
    is bounded — which section, its true size in bytes, and the budget it was cut to — because
    the bound itself is design, but a trim nobody can see is silent truncation, the thing the
    standing rule forbids everywhere ([prompt-assembly.md](prompt-assembly.md) rule 36 is the
    same rule at the prompt's own scale; there nothing is ever cut, here the cut is the design
    and the announcement is what keeps it honest). A section inside its budget passes without a
    word, and a section whose file is missing is an empty section, not an over-run.
58b. The night's material is the whole owed-work shelf, not the threads alone. Beside the thread
    log, the open list and the index, the selector MUST be handed, each as its own labelled and
    bounded section: the promise sweep's genuine end-of-day misses from the recent nights (the
    `type: sweep` records of the durable ledger — the honest pass's verdicts, never the live
    checker's raw catches, which run heavily false — and among them only the UNRESOLVED: a
    sweep row a `sweep-resolution` row has answered, fulfilled, struck, or booked alike (rule
    53f), is settled debt and MUST NOT ride the shelf, while the count of resolved rows so
    excluded is stated in the section itself, never silently dropped — rule 58a's discipline
    at the row's scale), and the wake queue's pending bookings (fire
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
58c. The thread material is the LIVE open engineering records and nothing else: the records
    drawer `crab eng` keeps (`~/.local/share/deskcrab/engineering/records/`, override
    `NIGHT_WORK_RECORDS_DIR`, default `$NIGHT_WORK_THREADS_DIR/records`), filtered to
    `state: open` and ordered newest-touched first — the order `crab eng list --state open`
    already produces. Each open record rides whole — front matter and body, so the selector
    reads the state field with its own eyes — under a per-record budget and a total budget
    (rule 58a applies to both, cuts announced); a record past the total is never silently
    dropped: it rides its `eng list` one-liner in a labelled overflow section, still live,
    still selectable. The frozen pre-records archive (`engineering.md`, `OPEN.md`, `INDEX.md`
    — read-only history, frozen at the records migration) MUST NOT reach the selector at all:
    everything in it is closed by construction, nothing can ever mark it done, and shopping
    from it bought already-finished work on four separate nights (2026-08-15 to 08-17, the
    record `the-nightly-drain-shops-from-the-frozen-archive`) before this rule. Closed means
    closed — not "demoted to background", which still trusts the model to obey a negative
    instruction; the archive's text simply never enters the prompt. An archive item a hand
    judges still owed is migrated to a live record (`crab eng new` or `crab eng migrate`),
    never re-fed to the drain. A records directory that does not exist switches selection off
    (the queue still runs, rule 56a); a directory that exists but cannot be read, or holds no
    open record, is presented to the selector as exactly that, in rule 58b's own words.
59. Every dispatch lands on a durable ledger — night, thread key, job id, title — and the ledger is
    read back into every later round and every later night, so the night's work never re-dispatches a
    thread on its own initiative. The ledger is the night's one write and MUST be declared
    (rule 6). A ledger still standing under the mechanism's former name is moved to the new
    path once, at the next run's start, declared on the night log — the record of what past
    nights dispatched is what keeps this rule honest across the rename.
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
| `${STATE_PREFIX}-shelf-overruns.txt` | the shelf-line check | rules 21a/21b: written when entries stand over the budget, removed by a clean check, rendered by the state block |
| `~/.local/share/deskcrab/tidy-claims/<date>.md` | the undestinated-claims check | rules 21c/21d: the day's vouched, undestinated, unbacked claims — one report per checked day with findings, none for a clean day; the day's engineering record is filed beside it through `crab eng` |
| `~/.local/share/deskcrab/conduct/` | tidy | conduct and its per-rule files |
| `~/.local/share/deskcrab/engineering/` | tidy | the pre-records archive and its index — closed to the night's selector (rule 58c) |
| `~/.local/share/deskcrab/engineering/records/` | `crab eng` ([engineering-records.md](engineering-records.md)) | the live thread records; the night's work reads the `state: open` ones back as its thread material (rule 58c) |
| `~/.local/state/deskcrab/notice-self.snapshot` | the watcher | the tree as last judged |
| `~/.local/state/deskcrab/notice-self.suppress` | write declarations | strong and weak records |
| `~/.local/state/deskcrab/notice-self.declared.log` | the watcher | one line per harvest |
| `~/.local/state/deskcrab/streams/<epoch>-<pid>.jsonl` | the watcher | archived stream, evidence only |
| `~/.local/state/deskcrab/notice-self.heartbeat` | the emitter | the number the canary watches |
| `~/.local/share/deskcrab/self-shadows/` | the watcher | rule 25e: private (0700 tree, 0600 copies) shadows of the non-git text constituents, mirrored by absolute path; refreshed only after a report lands, or at judgement for her own quiet writes |
| `~/.local/share/deskcrab/self-baselines/` | her, by hand | the 2026-08-28 manual stopgap copies; rule 25e seeds a conf-dir file's first shadow from its same-named baseline, and the drawer stays as history |
| `~/.local/state/deskcrab/canary-self.log` | the canary | one line per check |
| `~/.local/share/deskcrab/claudisms.md` | her, by hand | the phrase list: what is borrowed, and why |
| `~/.local/share/deskcrab/claudisms/<date>.md` | the claudism review | the night's report: hits, rewrites, counts |
| `~/.local/share/deskcrab/claudisms/counts.tsv` | the claudism review | one line per night and phrase, uses only |
| `~/.local/share/deskcrab/claudisms/functions.tsv` | the claudism review | one line per night and function: uses, mentions, spoken words |
| `~/.local/share/deskcrab/promise-ledger.jsonl` | the promise checker; the sweep appends its records (rule 53) and any hand appends resolutions through the resolve door (rule 53f) | live catches, end-of-day misses and their resolutions ([turn-pipeline.md](turn-pipeline.md) DATA); the night's work reads the unresolved sweep records back as owed-work material (rules 53f, 58b), through `lib/promise_ledger.py` alone |
| `~/.local/share/deskcrab/night-work/dispatched.tsv` | the night's work | one line per dispatched pick: night, key, job id, title (rule 59) — threads, swept promises and wake-parked work alike |

Units in the repository: the wake timer and service, the wake restore service, the sleep timer and
service, the tidy timer and service (the shelf-line check and the undestinated-claims check run as
the service's `ExecStartPre`, never gating the job — rules 21a/21b and 21c/21d), the self-change
path and service, the transcription path
and service, the canary timer and service, the phone server service. The tidy prompt still lives
as the unit's embedded command string (`MAJ-23`); `tests/test_tidy.sh` is still owed.

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
| `MAJ-23` | The tidy units are in the repository now, but the prompt of the one nightly process that moves lines between the shelf, conduct and the engineering threads, and deletes orphaned want documents, still lives as an embedded command string in the service file, and `tests/test_tidy.sh` does not exist. The shelf-line check (rules 21a/21b) is tested; the tidy job itself is not. |
| `MAJ-24` | The engineering threads are maintained nightly and named in no prompt path. |
| `MAJ-25` | The rot check has no caller. The stamp is write-only, so a stalled ingest surfaces nowhere. |
| `MAJ-32` | Ingest tail-clamped its input against a journal several times the cap, so the day's earliest material was never ingested. Closed 2026-08-11: the ingest now windows on whole chunk boundaries and runs the distiller once per window, reporting each pass ([memory-recall.md](memory-recall.md) rule 29). |
| `MIN-30` | A stray file duplicates the engineering namespace: unreachable by every reader, and inside the watcher's glob. |
| `MIN-31` | The tidy prompt asks for a dated prose line in a machine-written record, where the journal reader skips it and the ingest drops it. Tidy's own record never survives. |
| `MIN-32` | The canary reports the path unit disabled and only revives it in-session, so it will not come back after a reboot. |
| `MIN-34` | Two claudism detectors, unreconciled. The turn-close capture ([turn-pipeline.md](turn-pipeline.md) rules 30-32) writes a day flag log; the review judges from the journal directly (rule 39) and does not read it. The log is no longer unread — the recent-catches block ([prompt-assembly.md](prompt-assembly.md) rule 35) surfaces it at the start of a turn, and the pre-speech mirror ([speech-output.md](speech-output.md) rule 45) appends its fires and outcomes to it — so retiring it is off the table. The first piece of the corroboration is in — the review reads the day's flag log and names a live rewrite whose turn still fires the same function (rule 49). Still owed: the rest of it — telling a line she already re-said mid-turn from one that went out as drafted, deduped by sentence and pattern. Two detectors with no reconciliation will drift. |

## TESTS

**Existing:** `tests/test_notice_selfchange.sh` — 100 assertions in the most hermetic sandbox in the
suite, and the model for every other test; among them, `.git` internals under a watched drawer and
under an extra watch directory fire nothing (rule 25a), and the run window both ways (rule 25b): a
write whose mtime sits inside her own window — a live registration, a finished session's log line,
a reaped `?`-duration line, or the grace just past the end — stays quiet, while the same write with
no session running still fires exactly one wake, and a deletion inside a live window still surfaces;
and the shadow diffs (rule 25e) end to end: a one-line outside edit to the non-git conf reports its
own unified hunk, seeded from the manual baseline so the pre-shadow drift shows too, with the shadow
tree 0700, the copies and the report 0600, and not a byte of diff in the wake text, the log, or on
stdout; a report that cannot land keeps the old shadow, logs the failure, and the next report shows
the whole distance across both edits; a quiet write of her own advances the shadow with no report; a
deletion names the retained shadow and keeps it; an over-cap file is named too large and never
copied; a binary file and an unreadable one are each named for what they are, the prior shadow
retained; and the settle's two singletons (rules 24a, 24b): the tail of a burst books the one named
re-check and no stamped per-trigger unit, a trigger arriving while that re-check is armed books
nothing at all, and a run that finds the judgement lock held folds into the re-check and wakes
nobody, while the same change is judged in full the moment the lock is free.
`tests/test_notice_jobclaim.sh` — rules 25c and 25d both ways, against a fabricated jobs ledger and
a scratch tree: a running job's save, three successive saves, a committed change, and two concurrent
jobs' writes all stay quiet with the job id on the quiet line; a deletion under a live claim still
fires with the job named in the report; collection reopens reporting at once; an unclaimed path and
a pre-dispatch mtime still fire; journal writes stay quiet with and without a job while a journal
deletion fires; and the bounded windows: a finished-uncollected job sharing a workdir with a live
one loses the attribution to the more recently started, a finished-uncollected job past its grace
suppresses nothing while one inside the grace still claims its last bytes without ever being called
running, a `running` sidecar older than the ceiling claims no new byte but keeps the ones from
inside it, and no report calls the orphan running. `tests/test_claudism_scan.sh` — the review reads the
spoken half only and never a job's entry; counts replace, never double; a missing list is a silent
skip; the wake is booked through the door in the review's own name; a dead model still writes the
report with the rewrites marked missing. `tests/test_claudism_report_broken.sh` — rule 40a: a
night with a broken list entry and no catches is never called clean — the headline counts the
entries that would not compile, singular and plural; on a caught night the broken fact stands
before the verdict, not as a correction after it; and an all-compiling list with no catches keeps
its clean-night headline with no warning attached. `tests/test_claudism_agenda_clean.sh` — rule
40a's morning half: with one uncompilable entry and no catches the wake's agenda never says a
clean night and names the entry that never ran; a caught night's agenda carries the same fact;
and an all-compiling no-catch night keeps its clean agenda word for word.
`tests/test_promise_check.sh` — rules 51-53c: the sweep
hands the model the day's replies with their outcomes and the live ledger, surfaces a genuine miss
as a ledger record and one morning wake in the checker's name, and books nothing on a clean day;
the widened evidence (rule 52a) — the day's named files statted from disk, an existing artefact
with its modification time and a claimed one shown NOT found alike, and the resident player's
game outcomes at their own timestamps — reaches the judge as labelled sections, with an absent
game record presented as an empty section rather than omitted; every sweep row lands carrying
`sweep_time` and `item` (rule 53), the misses ride the morning wake numbered with the resolve
door named beside them; and the resolve door itself (rule 53f) appends a resolution row bearing
the run's own `sweep_time` while refusing an item the run never surfaced and a decision outside
the three.
`tests/test_night_work.sh` — rules 54-61: the daylight window guard; the cap counted from every
dispatched-or-running job; the live shelf (rule 58c) — a record standing `state: open` under the
records drawer reaches the selector's prompt whole, front matter and body, newest-touched first,
while a settled record and the frozen pre-records archive never enter the prompt at all;
validation skips null-shaped briefs, thin briefs, and threads already on
the ledger; a
NOTHING verdict with nothing of tonight's running ends the night's work early; a blocked job door ends it
for the night; the cutoff stops dispatch; the owed-work material (rule 58b) — the sweep's ledger
misses and the pending wake reasons reach the selector as labelled sections, the live checker's
raw catches do not, and an unreadable ledger is presented as unreadable, never silently omitted;
the sweep runs before the night's work inside `sleep-nightly run`; a resolved sweep row —
explicit `sweep_time`/`item` identity and the legacy shape resolved by run-and-ordinal across a
ledger clock tick alike (rule 53f) — never reaches the selector while the unresolved neighbour
still does and the count of excluded resolved rows is stated in the section; and a run that
cannot even parse its
cutoff never unstamps the night (exercised through `sleep-nightly run`).
`tests/test_night_work_queue.sh` — rules 56 and 56a: the queued backlog dispatched oldest first
through `crab job dispatch` before any selection, under the cap, with `DESKCRAB_JOB_NIGHT` set on
every door call; a builder still standing `dispatched` holds its cap slot; a night with no
engineering threads at all still takes up the queue, spends no selection call, and ends when the
queue is dry; the cutoff re-checked before each dispatch so nothing new starts past it; a
refused queued brief skipped for the night while a blocked door ends it; and the dry run naming
its would-dispatches without starting anything.
`tests/test_night_work_utf8.sh` — rule 58a over rule 58c's material: with an em-dash straddling
the per-record budget and the job-list budget at once, the prompt the selector receives is valid
UTF-8, plain grep — no `-a` — still reads it, each split character is dropped whole at its
boundary, an em-dash clear of the boundary survives intact, and the budgets themselves still
hold; each outgrown section is named on the night log with its true size and its budget; the
total record budget clips oldest-touched first, announced, with the clipped record riding the
overflow list rather than vanishing; and a night whose material fits its budgets announces
nothing.
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

`tests/test_record_merge_pass.sh` — rules 53b-53e, against the real local embedder (a mocked one
cannot prove semantic scoring): a true twin pair scores above every same-area-but-distinct pair
and above the candidate threshold, while a settled record — however similar its text — is never
scored, never judged; the judge is the deciding gate, not the score (a same-area pair handed to
it and answered DISTINCT is never proposed); the judgement prompt carries the same-complaint-
never-same-area rule, the confidence form, and the person's-ruling-outranks-yours line, and runs
on the phase-2 model with no fallback; the judged bound announces what it dropped; `run` without
`--apply` leaves the records directory byte-identical whatever the confidence; an unanswerable
judge and an unreachable embedder both end the pass conservatively, folding nothing, exiting
zero; `--apply` on fixtures folds a `MERGE CERTAIN` through `crab eng` alone — the earlier-opened
winner keeps its `opened`, carries both bodies whole under a fold entry that names the loser, the
score and the confidence and rides the tool's own dated heading, the loser dies pointing at the
winner's id and keeps its own body — while `MERGE LIKELY` and a bare confidence-less `MERGE`
stay proposals under the default gate, the records byte-identical, and
`ENG_MERGE_FOLD_CONFIDENCE=likely` widens the gate to fold a LIKELY; a second `--apply` finds
nothing left to propose; and the wiring: sleep runs the pass after the promise sweep, before the
night's work, WITH `--apply` (rule 53d), and the pass speaks through the deployed symlink (rule
6a) even with no records drawer at all.
`tests/test_sleep_sol_judgment.sh` — rules 14c-14e, the effective nightly call graph against a
stub codex and a stub claude, no real model spent: the night-work selector, the promise sweep's
judge, and the eng-merge judge (against a scratch HTTP embedder) each reach `codex exec` at the
default `gpt-5.6-sol` with `model_reasoning_effort=high` on the argv, with not one claude call
beside them; a codex refusal on the selector ends selection with the cooldown recorded in the
scratch codex state and NO fallback model consulted (rule 14e); the shared walk's Claude branch
still walks the flat list on a Claude-named override, model on the argv; the ingest's two-stage
boundary (rule 14d) end to end through `crab memory ingest --dry-run` — the summariser (stub
claude, `--model` the summary model) receives the raw day while the judge's codex stdin carries
the summariser's summary and NOT the raw material's marker, the would-add candidates are the
JUDGE's answer, and a candidate array smuggled into the summariser's summary text never lands;
the default cutoff prints as 06:00 through the daylight guard and the default cap still counts
two — the routine's shape unmoved under the model change.
`tests/test_tidy_undestinated_claims.sh` — rules 21c/21d, against a fixture day and a fixture
drawer: the one sentence that vouches durability, names no drawer, and has nothing on disk behind
it is the day's ONE finding — quoted in the check's own name, written to the day's report, filed
as one open engineering record through `crab eng` with its time and channel, and never filed
twice by a re-run; while everything the narrowing exists for stays quiet — a claim that names its
drawer, the same claim with its artefact touched inside the turn's window and sharing the
paragraph's phrases (the clearing artefact named), a builder's `kind: job` entry carrying the
same words, a firing sentence below the display delimiter, and a plain unvouched "wrote it down";
a clean day is one line, exit zero, nothing filed; a day with no journal is a quiet nothing; and
`scan` replays days without writing a byte.
`tests/test_tidy_claims_conf_roots.sh` — rule 21e, against a scratch conf and a scratch data
home: with the environment empty the check's roots, report dir, lead and slack all come from the
conf, a root written with `$HOME` in the conf arriving expanded; an explicit environment variable
beats the conf for the roots, and the pinned `DAY_JOURNAL_DIR` beats the conf's journal line while
unsetting it hands the journal to the conf; a missing conf, a conf with a syntax error, and a
non-numeric lead all degrade to the shipped defaults without an exception; and the same conf
resolution holds when the script is reached through a symlink whose own directory holds no
`common.sh` — the realpath step of rule 6a is what finds the library.
`tests/test_shelf_check.sh` — rules 21a/21b: a synthetic over-long shelf line is flagged with its
measured size, the budget, and the `wants/<slug>.md` document its line points at; a line naming
no document is flagged as exactly that; a genuinely one-line shelf is silent — one line, exit
zero, no record; the record stands under `${STATE_PREFIX}-shelf-overruns.txt`, renders in the
state block and the assembled prompt, and a later clean check removes it; the budget answers
`WANTS_SHELF_LINE_BUDGET`; and the shelf file is byte-identical before and after every check —
the check reports and never rewrites.

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
