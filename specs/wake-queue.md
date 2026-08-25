# Spec: wake queue

## PURPOSE

Autonomous wakes are how she works unattended: a booking record, a transient timer, a session with
its own agenda, and a chain that keeps going. This spec owns booking, cancellation, restoration,
tidying, and the discipline that keeps one queue from becoming a storm. Her autonomy is not in scope
for reduction here — every rule below makes the queue **visible and bounded**, never smaller.

## CONTRACT

### The wake queue is a module

1. There MUST be exactly one module that touches the wakes directory and the systemd user manager
   for wake units. It exposes `list()`, `book()`, `cancel()`, `restore()`, and `tidy()`.
2. No other code may read the wakes directory, mint a unit name, call `systemd-run` for a wake, or
   stop a wake timer. Every booker goes through `book()`.
3. `list()` MUST enumerate the records and join timers onto them, never the reverse. See
   [self-awareness.md](self-awareness.md) rules 1 to 4.
3a. A transient timer whose SERVICE is active or activating is a wake firing right now — it
   retired its own record first thing (rule 19) — and `list()` MUST skip it exactly as tidy and
   restore do (rules 31 and 36), never report it as a timer with no booking record. The running
   session is already visible in the session registry. On 2026-08-10 every fired event wake spent
   up to `WAKE_EVENT_LOCK_WAIT` at the run lock with its record correctly retired, and the state
   block rendered each of them as an orphan: three to six "timers with no booking record" stood
   in front of her all evening, every one of them a wake mid-fire that nothing had lost.

### Booking

4. The record MUST be written before the timer is booked. A crash between the two leaves a record
   the reconciler honours; the other order leaves a timer nothing remembers.
5. A booking that fails to arm its timer MUST roll its record back.
6. Booking MUST hold the single booking lock for the whole check-then-act sequence. Several sessions
   book at once, and two wakes finishing in the same second each found no pending floor and each
   booked one.
   - **Every operation that writes the queue takes that lock**, not booking alone: cancel, restore
     and tidy all mutate records and systemd units. A cancellation racing a restore re-arms the
     record the cancellation is about to delete, leaving an armed timer with no booking record —
     which tidy will not purge, because it has never fired — and it fires a wake that was called
     off.
   - The lock's own **exit status is the answer**. A `flock -w` whose timeout is discarded runs the
     entire check-then-act unlocked, which is the one thing this rule forbids. An operation that
     could not take the lock MUST report that and change nothing.
7. Unit names MUST be minted by the module's own collision-avoiding namer. No caller may build a
   unit name inline.
8. Every booking MUST be made as a **delay**, never by passing a calendar specification through to
   systemd. A bare calendar specification makes a timer that returns every day while the record
   covers only the next firing.
9. Every booking MUST snap to a moment no pending booking already holds. Two wakes cannot run at
   once, so two bookings on one second are one wake and one deferral.
10. A near-duplicate booking MUST NOT be stacked: a scheduled booking with the same reason firing
    within the coalescing window of a pending one is not added. Event wakes coalesce only against a
    byte-identical reason — two different events are two wakes, while the same event re-booked by
    its own deferral is one. The comparison MUST be made against the reason **as the record holds
    it**: the store squashes newlines and tabs, so a raw multi-line reason — every builder's task
    description — can never equal its own stored copy, and an event re-booked by its own deferral
    stacks a fresh wake every time.
10a. A record MUST be written atomically — a temp file and a rename, never a truncate in place.
    Readers hold no lock and a zero-length record does not exist as far as any of them is
    concerned, so an in-place write makes the booking vanish from the state block, the spacing
    search and the coalescing test for as long as it takes.
10b. **The turn-cluster fold.** A booker MAY declare, on the one door, that its bookings of one
    class arriving close together are one nag, not several: `--cluster <seconds>` names the
    window, `--cluster-item <text>` names the one caught item this booking carries, and the class
    is the `--cap-prefix` already on the call (a cluster with no class prefix is refused at
    booking time). When a pending booking of the same booker, kind and class was **booked** within
    the window, the new booking is not made at all: the item is FOLDED onto the pending record —
    the reason grows a short list carrying every caught item — and the pending wake's fire moment
    is NEVER moved. Three turns finishing inside one minute each fired an audit, each audit booked
    its own wake, and three timers nagged her to check the same shelf (2026-08-07 12:12); the fold
    is the repair for defect (b) of that entry, and it sits ABOVE the slot allocator: a folded
    booking never reaches the cap, the spacing search or a timer of its own, rather than reaching
    them and landing on a different second.
    - The whole find-then-fold runs under the booking lock (rule 6). Three audits in separate
      processes in the same second must produce exactly one wake; an unlocked read-then-write
      race is three.
    - The fold's anchor is the pending record's own booked-at, which the rewrite MUST preserve —
      resetting it to the fold's moment would slide the window forward with every catch and chain
      a quiet afternoon into one ever-growing wake.
    - The merged reason is what the fired session will actually read, so the fold MUST re-arm the
      timer with it (the fired wake's agenda travels in the unit's argv, not the record) at the
      SAME fire moment, record first, rollback on a failed re-arm exactly as rules 4 and 5 demand
      — and a fold whose re-arm fails books separately rather than losing the item. Each folded
      item is cut through the one-trim rule (the DATA section: `utf8_trim`, never a bare byte
      cut) at its own bound, so every item's opening clause stays legible however many the
      cluster catches. Every fold lands on the durable ledger under its own action (`folded`).
    - A class whose fire moment is a PROMISE — the auditor's deferred wakes fire at the moment
      she named — MUST pin the fold: `--cluster-pin-fire` additionally requires the pending
      booking's fire moment to fall within the window of the new booking's own, or the fold does
      not happen and the booking proceeds alone. A promised moment is never traded for tidiness;
      when in doubt, book separately.
11. Every wake unit MUST be booked with the collect option, so a failed unit does not leak into the
    user manager.
12. Every wake unit MUST carry a runtime ceiling. The in-process stall watchdog cannot by
    construction reap a session that keeps emitting output; the unit-level ceiling is the backstop.
12a. Every wake unit MUST be booked at background CPU priority — a CPU weight and a niceness,
    configurable (`BACKGROUND_CPU_WEIGHT`, `BACKGROUND_NICE`) — so a wake never competes at par
    for the processor with a turn somebody is standing there waiting on. Nobody is waiting on a
    wake; that is the whole difference between the two. Priority is the ONLY thing lowered:
    nothing may pause, kill, defer or mute a running wake because a turn arrived — an idle
    machine still gives a wake everything it has.
13. A scratch instance's config path and state prefix MUST travel into the unit, so its wakes fire
    back into the scratch state.
13a. A booking MAY carry an **effort override** — `crab wake-at --effort <level>` — naming the
    reasoning effort the fired session runs at, for a booker that already knows how hard its wake
    will need to think. (The chess bridge's move wakes were the first such booker; the resident
    mover — [chessweb.md](chessweb.md) rule 16 — has since taken chess moves off the queue
    entirely, and the promise checker's unkept-commitment wake — rule 43b, booked at low — is
    the standing hand the mechanism was kept ready for.)
    The override is the record's sixth field and the fired unit's sixth argument, so it survives
    exactly what the record survives: restore re-arms with it, tidy's re-book keeps it, and the
    blocked-lock deferral re-books with it intact. The level MUST be one of the CLI's effort names
    (low, medium, high) — anything else is refused at booking time, not carried into a claude
    invocation that will refuse it later with nobody watching. Absent, the wake runs at
    `WAKE_EFFORT` from config, exactly as before the field existed.

### Argument arity

14. `crab wake-at <when> [kind] [reason]` MUST normalise its arguments on write: if the third
    argument is not a recognised kind, it is the **reason**, and the kind defaults to scheduled.
15. `crab wake <kind> <reason> <unit>` MUST normalise on read, the same way, so a record already on
    disk with its agenda in the kind field recovers that agenda instead of being blanked.
16. A wake whose kind was blanked MUST NEVER be dropped. Every re-booking path — the blocked-lock
    deferral, the post-outage retry, the failure re-book — MUST work for a wake with no kind.
17. A wake that loses the serialisation lock MUST be deferred, never destroyed. Today the record is
    retired before the code decides whether to re-book.

### Running a wake

18. Only one wake runs at a time, guarded by a lock held for the life of the process.
19. A fired wake MUST retire its own record first thing, before any early exit.
20. An active interaction MUST NOT defer the session. The session runs; the output decision is made
    at the end. Deferring the session meant a wake during any conversation did no reading, no want
    work, and no dated thought, and reached the user as an indistinguishable silence.
21. A wake blocked by the lock MUST be re-armed with its kind, reason and effort override intact,
    at a spaced slot.
21a. An EVENT wake blocked past its lock wait MUST be re-armed on a short escalating backoff —
    `WAKE_EVENT_DEFER_DELAY` (default 30s), doubling per consecutive deferral of the same kind and
    reason, capped at `WAKE_EVENT_DEFER_MAX` (default 120s) — never at the scheduled deferral
    delay. An event wake has somebody or something waiting on the other end of it, and the flat
    quarter-hour push-back, written for shelf work nobody is waiting on, is a starvation sentence
    there: a chess move wake blocked by one long session came back fifteen minutes later to a
    board an opponent had been sitting at the whole time (2026-08-10) — while the config had
    promised a seconds-scale retry since the day `WAKE_EVENT_DEFER_DELAY` was written, from a
    variable the re-book site never read. The backoff count is ephemeral state under
    `$STATE_PREFIX`, keyed by the kind and the reason as the record holds them, and cleared the
    moment a wake with that identity takes the lock: contention is a property of the running
    instance, and the reboot that clears the lock clears the count that measured it.
21b. An event wake waiting for the run lock — or deferred by it and due straight back — MUST
    stand in an urgent lane: it registers a claim (a marker under `$STATE_PREFIX` carrying the
    moment the claim expires), and a NON-event wake that reaches the lock while an unexpired
    claim stands MUST yield — defer itself under rule 21 without contending — so the event wake
    takes the lock the moment the holder releases it instead of racing the whole queue for the
    next turn. Priority decides only who takes the lock NEXT: nothing may pause, kill, defer or
    mute the wake that already holds it (rule 12a's discipline holds here too). An expired or
    unreadable claim is ignored and removed, never obeyed, and event wakes never yield to their
    own lane — two event wakes settle it at the lock, as they always have.
22. The wake agenda MUST be delivered as the session's user message. See
    [prompt-assembly.md](prompt-assembly.md) rule 12.
23. When the stream held an error and no genuine model output — or the run was cut off mid-flight
    by a usage or session limit with nothing genuine after the refusal, on every account the chain
    could offer (account-fallback.md rules 12a and 12c) — the wake MUST journal the failure with
    the exit code and error text, naming the session limit as the cause when it was one, append
    nothing to the conversation, skip the audit and all output, and re-book a kinded wake so the
    agenda survives the outage. The refusal text is a failure record, never a reply.
23a. A wake whose walk ended WHOLLY REFUSED over limits MUST NOT re-book into the drought it
    just measured: every account it could offer is now cooling for its model, so a re-book on
    the plain outage slot fires straight back into the same refusals — the 2026-08-15 morning
    logged refusal/re-book pairs eight seconds apart, 136 wakes before nine, a 2↔3 ping-pong
    that burned CLI boots and genuine session capacity on walks that could not succeed. The
    re-book delay is the SOONEST cooldown expiry covering the wake's model
    (account-fallback.md rules 8a, 8b: per account, the latest covering record; across
    accounts, the earliest of those), plus a small jitter so a stack of refused wakes does not
    land on the same second, bounded by `WAKE_REBOOK_MAX` (default six hours) so a state file
    claiming next week never parks the agenda that long. Only a walk the limits refused
    outright earns this wait: every other outage — network, crash, stall reap, rule 24a's
    launcher death — keeps the free half-hour slot, because nothing measured says when IT
    clears. WHOLLY REFUSED is judged from the walk's OWN per-attempt outcomes — every attempt
    a limit refusal or cut — never by re-grepping the whole accumulated log: an earlier
    account's refusal plus a later account's silent network death wears the same whole-log
    shape (limit text standing, no genuine output), and judged that way a mixed walk was sent
    into the long cooldown-keyed wait for a drought it never measured.
24. A wake that produced no output on a clean exit MUST be journaled as silence, not as a crash.
24a. A wake whose CLI exited **non-zero** with no genuine model output is rule 23's outage in
    different clothes, and MUST be treated the same way: journal the failure and re-book the kinded
    wake so the agenda survives. Rule 23 cannot catch it, because its judgement reads the CLI's own
    error events — and this launcher died before the CLI could write any: bubblewrap unable to
    build the cocoon (it cannot nest inside another namespace), the cocoon-refused note, a loader
    crash, a stall reap. The stream then holds no `is_error` event at all, only the launcher's own
    complaint in plain text. The journal line MUST therefore carry the exit code **and the
    launcher's last words** from the stream — its non-event lines and deskcrab's own notes, never
    the session-registration note — because "claude exit 1" alone sends whoever reads it digging
    through archived streams for a reason the log already held. Until 2026-08-11 this shape kept
    its journal line and silently lost its agenda: reported as a death, never retried, which for a
    wake with a purpose is the same loss the outage re-book exists to prevent.
25. Every wake MUST journal what it did, from its own tool activity, not from its reply. A silent
    reply is a speech decision, not a work record.

### Delivery gates

26. The wake's words enter the conversation only if they were delivered. The append happens past
    every gate, immediately before the voice.
27. Quiet hours and the user-busy check suppress **the speakers, the screen, the notification and
    the bubble** — every channel, not the voice alone. It is stated here once and implemented once,
    and every other statement of it defers to this rule. A window is quieter than a voice and it is
    not nothing: it takes focus, it lights a dark room, and a night of them is a desk covered in
    windows by morning.
    - What is suppressed is the DELIVERY, never the work. By the time either gate is reached the
      wake has finished, journalled what it did, and fired the audit and the memory judge.
    - A wake the night held MUST say so in its journal line, in those words. Journalled as ordinary
      silence, the held words read to the next session — and to the since-your-last-reply anchor,
      which reads the same journal — as an hour in which she had nothing to say.
27a. A wake's output that has **no spoken half** — a `(quiet)` bubble, a display section on its own
     — MUST be held while the conversation is HOT, and MUST come back through the queue once the
     heat has passed. Hot is measurable and is one number: the last message from him is younger
     than `CONVO_HOT_WINDOW`, read from the origin record that every desk and phone turn stamps at
     the moment a message arrives.
     - **Why this is not rule 27 over again.** The user-busy gate asks the sound card a question —
       is the microphone open, is a voice on the speakers *at this instant* — and between two
       messages of an argument the honest answer to both is no. 2026-08-10, 12:32:12: a quiet chess
       note ("Lost browser-006 — mated by a promoted pawn while my knights admired themselves")
       landed in the conversation between "stop assuming I'm wrong" at 12:31:46 and "I'm reporting
       a genuine bug" at 12:33:04. Every gate was working and every gate said the room was quiet,
       because for four seconds it was. A lull between two messages of a fight is not a quiet room,
       and an aside arriving in one reads as her attention being somewhere else.
     - **Why this is not rule 29 either, and the boundary is the whole design.** Nothing here reads
       what the reply SAYS. It reads the clock, and it reads one decision she already made while
       writing: that these words were not worth opening her mouth for. A wake that chose to speak
       has something it judges worth saying out loud and that choice stands whatever the clock
       says — rule 29 is untouched. What is held is a note, and a note keeps.
     - **Held, never dropped — at hold time.** The words go back through the queue's one door as
       an event wake `WAKE_HOT_RETRY` out — comfortably past the hot window, so the retry is not a
       second interruption — with the held words in the reason, so she meets them again in a quiet
       minute and decides afresh with the conversation in front of her. What the comeback then
       faces at fire time is rule 27b's staleness gate, which may retire a note the intervening
       conversation has already covered — journalled and ledgered, never silently. The booking is
       capped
       (`WAKE_HOT_HOLD_CAP`, scoped to the held-reason prefix): a stack of held asides all landing
       on the first quiet minute is the same storm one delay later. The comeback is a booking like
       any other and the cap can refuse it, so the hold MUST read the booking's answer BEFORE the
       journal line is written: a line promising a comeback may only be written when a comeback
       wake actually stands (booked now, or an equivalent one already pending), and a refused hold
       MUST be journalled as refused — the note surviving in that journal line only — never as a
       promise the queue never accepted. A display-only hold MUST carry the built display content
       itself in the reason (clipped to the reason's budget), never a placeholder naming it: the
       comeback wake's reason is the only place the held words survive, and a placeholder holds
       nothing.
     - **Said in those words in the journal**, exactly as the night's hold and the busy hold are,
       and for the same reason — a wake the heat held is not a wake that had nothing to say, and
       the next session and the since-your-last-reply anchor both read that line.
27b. A held note's comeback MUST be judged for **relevance** before it is delivered, not only for
     heat. The hold judged one thing — is the conversation busy — and nothing ever compared the
     note to what was said while it waited: on 2026-08-15 the user was told live at 00:48 that the
     chess game was won, and a held note announced that same win as fresh news at 01:19, three
     more stale notes queued behind it. A note is a claim about a moment, and the moment can pass
     while the note stands in the queue.
     - **The stamp arms the gate.** `wake_hold_for_heat` MUST stamp the held reason with the
       moment the holding session BEGAN (`held at YYYY-MM-DD HH:MM`, human and speakable, parsed
       back out by one expression) — the session's start and not the hold itself, because the
       exchange that makes a note stale can land while the note's own session is still mid-flight,
       and a window opening at the hold would exclude the very exchange that covered it. The stamp
       rides the REASON because the reason is the only part of a booking that survives deferrals,
       outage retries and restore verbatim; a record field would be re-minted as "now" by every
       re-book and the window would silently shrink to nothing. The gate keys on the stamp, never
       on the booker: any autonomous booking whose reason carries the stamp gets the same
       judgement, whoever wrote it.
     - **At fire time**, after the wake lock is taken (so the record judged against is as fresh as
       it can be) and before the wake session exists, the gate gathers what has actually been said
       between them since the stamp — from the day journal, the durable record: his words from
       interactive turns (a wake's "user" slot holds its agenda, not him), her replies only where
       they were DELIVERED, judged by the journal's own convention that a parenthesised outcome
       reached nobody — which is also what keeps the holding wake's own journal line, the note
       riding its outcome, from reading as the note having been said. One bounded question goes to
       a cheap judge (`WAKE_STALE_MODEL`, default `claude-fable-5`, cut off at
       `WAKE_STALE_TIMEOUT` seconds, the classifier invocation shape): has this already been said
       to him, or has it been overtaken by later events? The answer is one line, `SAY` or `DROP`,
       with the reason on it.
     - **When nothing has been said since the stamp, the judge MUST NOT be called.** Nothing can
       have gone stale, and the model call is the gate's whole cost.
     - **On DROP the note is discarded silently to him and loudly to the record**: nothing spoken,
       nothing notified, nothing shown, nothing appended to the conversation — and the drop with
       its reason lands on the sessions log and the day journal (a parenthesised outcome carrying
       the note's words), on the durable wake ledger under its own action (`dropped-stale`), and
       on the gate's own trace log. A note that vanishes with no account of itself is the
       empty-reply hole wearing a new face.
     - **The gate fails OPEN, and only a positive verdict drops.** A judge that refuses, times
       out, errors, or answers unparseably delivers the note and logs the failure plainly; an
       unparseable stamp delivers unjudged; `WAKE_STALE_GATE=0` disables the gate whole. The gate
       may only ever remove speech, never add or alter it — a lost real note is the worse failure,
       and staleness is the only ground on which silence may win.
     - **The boundary with rule 29 holds.** Rule 29 forbids judging a reply the wake WROTE and
       deciding it is not worth voicing; nothing here reads a fresh reply. The gate reads a note
       from a past session being replayed as news, and judges its freshness against the record of
       what has been said since — never its worth. It exists on the user's instruction, the night
       of the incident.
27c. A wake whose delivery moment finds an interactive turn IN FLIGHT is held WHOLE — the spoken
     half included — and comes back through the queue exactly as rule 27a's hold does. In flight
     is mechanical, read from the delivery queue's own tickets
     ([turn-pipeline.md](turn-pipeline.md) rule 15a): a desk or phone turn takes its ticket before
     the prompt is built and releases it when the reply has been delivered, judged alive by pid
     and process start time, so "in flight" means exactly "he asked something and the answer has
     not landed yet". A wake's words arriving inside that window land in the answer's slot, and a
     reply landing in another message's slot is the loudest statement this machine can make that
     it was not listening (the 2026-08-10 ordering incident, [turn-pipeline.md](turn-pipeline.md)
     rule 15a). The regroup context shown to the wake at prompt time changes what the words SAY,
     never the slot they land in — that is this rule's job.
     - The boundary with rule 29 holds: nothing reads the reply. The gate reads the pipeline's own
       state — tickets and pids — and decides WHEN, never WHETHER. The words go back through the
       queue's one door with the held stamp, so rule 27b judges the comeback for staleness and a
       wake that chose to speak is spoken in the first quiet minute unless the record proves the
       exchange already covered it. Rule 20 holds too: the session ran, the work is journalled,
       the audit and the judges fired — only the delivery moves.
     - Held, never dropped, on rule 27a's own terms: the same booking (the hot-hold identity, the
       held-reason prefix, the stamp, the cap), the same read-the-booking-answer-first
       discipline. The journal line says in those words that a turn was in flight, and a hold the
       cap refused is journalled as refused — the words surviving on that line only, never as a
       promise the queue never accepted.
     - The gate is off when the delivery queue is off (`TURN_ORDER_WAIT=0` books no tickets and
       leaves nothing to read), and `WAKE_FLIGHT_HOLD=0` switches it off alone. A ticket whose
       process is gone is not a turn — the same recycled-pid discipline the queue itself keeps.
28. A wake that regrouped against a live turn MUST carry the other reply forward as one reply, never
    restate it, never queue its own thought for later, and never default to silence. Rule 27c is
    not that queueing: the choice it forbids is the WRITER'S — a reply that answers "later" instead
    of folding — while 27c holds a folded reply's delivery for the seconds the other turn is still
    owed its slot, and hands the words straight back through the queue.
29. No mechanism may judge a wake's written reply after the fact and decide it is not worth voicing.
    Silence is chosen while writing or not at all.
29a. The one standing exception, on the user's instruction (2026-08-07, reaffirmed 2026-08-10): a
     spoken reply whose ENTIRE content is the announcement that there is nothing to say is muted
     whole, on every channel. That includes the announcement wearing a reason — "No message — the
     other session already said its piece", "Nothing to add; nothing has changed" — and the reason
     standing alone as the whole reply ("The other session already covered it."). This is not a
     judgement of worth, which rule 29 forbids: the reply names ITSELF contentless, and voicing it
     is the exact interruption the silence existed to prevent, wearing the words of the thing that
     was supposed to prevent it.
     - The gate MUST stay narrow: an optional no-op core, an optional silence-justification clause
       (the other session already said/covered/answered it; nothing changed; he already heard it),
       and nothing else, matched whole and anchored. A reply carrying real content alongside the
       announcement ("Nothing to report on the build, but two tests fail") MUST fall through to
       speech — muting one real reply is a worse failure than voicing one stray no-op.
     - The announcement in the FIRST person is the same announcement (2026-08-15, five wakes in
       ninety seconds, two of them aloud: "I've said my piece on that game twice already tonight",
       "I've said everything I have about that game tonight", "I've nothing further on that game
       tonight"). The gate MUST match the first-person already-said core ("said my piece", "said
       everything I have", with repeat counts), the repeat-count clause standing as the
       justification ("Fifth time round on the same game tonight"), and — only on cores that
       reference her own prior speech (said-my-piece; nothing further/more/else/new) — a short
       topic phrase ("on that game", "about it"). The topic phrase is NEVER allowed on the plain
       nothing-to-say core: "Nothing to say about the backup" is a fact about the backup and MUST
       still speak.
     - A reply whose entire text is a PLACEHOLDER naming the absence of a message — "*(no message
       text)*", "(no message)", "no reply", the CLI's bare "undefined" — is not an announcement to
       be weighed but the absence itself, stringified (2026-08-15, 01:07: the literal words "no
       message text" were synthesised and spoken at the desk). It MUST terminate the delivery
       exactly as a genuinely empty reply does: nothing spoken, nothing notified, nothing shown,
       no bubble; the placeholder survives only on the journal line.
     - The muted words are never lost: they ride the wake's journal line (rule 25's), which is where
       a wake nobody heard has always belonged.
     - The gate is the backstop, never the instruction. The wake prompt MUST name the silent exit —
       ZERO message text, an empty reply — as the required ending when there is nothing to say, MUST
       state it as the DEFAULT when another session already covered it or nothing has changed, and
       MUST name the announcement shapes (reason-bearing form included) as forbidden.

### Restore and tidy

30. `restore()` MUST rebuild still-future timers at their original moment and fire overdue ones
    once, promptly, staggered.
31. `restore()` MUST log every restoration to the durable ledger. Its output MUST NOT go to
    `/dev/null`. A bulk restore means a cancellation was undone or the machine rebooted, and that is
    a fact she has to be able to read.
    - A re-arm that FAILS MUST roll the record back to the moment it held, ledger the failure, and
      say so. A pass that armed nothing MUST NOT end on the sentence that says every booking has its
      timer.
    - `restore()` MUST skip a unit whose **service** is active, exactly as tidy does (rule 36). A
      one-shot timer goes inactive the instant it fires, so a timer-only check reads a wake that is
      running right now as an overdue booking and re-arms it underneath itself.
32. Overdue collapsing MUST cover event wakes as well as scheduled ones, so a queue of identical
    overdue promises does not come back in full.
33. `cancel()` MUST be the only real cancellation, and MUST clear the record as well as stopping the
    timer. Stopping a timer alone leaves a record that restore brings back.
34. There MUST be a way to cancel the whole queue in one command.
35. `tidy()` MUST purge only transient timers that have **demonstrably fired** and have no booking
    record.
36. `tidy()` MUST skip any unit whose service is active. That is a wake firing right now, which
    cleared its own record first thing.
37. `tidy()` MUST collapse bookings that are the same promise, and re-book any that share a second.
38. `ensure_next_wake` MUST run at the end of every wake: restore, then tidy, then book a floor wake
    if no scheduled-kind booking is pending, judged from the records and never from systemd.
39. The floor is a floor, not a schedule. A wake that booked its own follow-up is left alone.
40. Only a wake that will come back to the wants counts towards the floor. An event wake is pending
    for its event, and counting it lets one unrelated long-dated booking suppress every floor
    booking and end the chain.

### The autonomous bookers

41. The promise auditor (`promise-audit`), the promise checker (`promise-check`), the job runner
    (`job-runner`), the self-change watcher
    (`notice-selfchange`), the new-file watcher (`notice-newfiles`), the watcher's canary
    (`canary`), the nightly claudism review (`claudism-review`) and the chain floor
    (`wake-chain-floor`) all book wakes in her name. Each MUST pass its own
    identity as `booked_by`. Three further identities reach a record without being subsystems:
    `outage-retry`, when a wake that failed before the model ran — or was cut off mid-run by a
    limit the whole chain shared (account-fallback.md rule 12a) — re-books itself and cannot name
    its original booker, `hot-hold`, when a wake's own output was held for a hot conversation or
    for a turn in flight and books itself back past the moment (rules 27a and 27c), and `herself`,
    the default when nobody says. Any prose that enumerates the bookers — here, in the other specs, or in the prompt
    — MUST name the whole set, and it is eight hands and eleven names, not four of either.
42. Each MUST route through `book()`, and therefore through the coalescing, spacing, and locking
    rules.
43. The promise auditor MUST use the shared shelf reader. An auditor handed an empty list and told
    the list is complete flags everything.
43a. The auditor books two classes of follow-up, and each opens with its own reason prefix (both
    constants in `lib/common.sh`): the unsaved-want wake, and the **deferred-promise** wake — her
    reply committed to doing a piece of work later and the turn ended with nothing on the queue.
    On 2026-08-09 she told the user a builder would be sent "just before one", booked nothing, and
    the promise died with the turn; the conduct rule ("schedule the wake in that same turn")
    already existed, so the missing piece was a hand, not another sentence. A deferred-promise
    wake MUST fire at the moment she stated when it parses (the plain forms: a clock time, "in an
    hour", "tonight"), and twenty minutes out when she gave none or the parse fails. A stated
    clock time that resolves more than half a day away is a moment already slipped past, and takes
    the twenty-minute floor too. Its reason MUST brief her on what she promised, when she said it,
    and that the audit caught it because nothing was booked — never the wants-shelf wording. The
    wake path MUST skip its own audit for BOTH prefixes, or each follow-up audits itself into an
    endless chain. And the auditor MUST NOT book the deferred wake when a record booked by her own
    hand already stands from the same turn: the catcher exists for the promise with no body, not
    to accuse the kept one.
    Both classes book through the turn-cluster fold (rule 10b), each against its own prefix,
    under `PROMISE_CLUSTER_WINDOW` (seconds, default 300 — a turn-cluster is minutes wide, the
    overlap of a desk turn and a wake or two, never an afternoon): three want-sentences caught
    inside one window become ONE wake whose reason lists all three, not three wakes each nagging
    her to check the same shelf. The deferred class MUST pin the fold on the fire moment
    (`--cluster-pin-fire`) — a promise fires when she said it would, and folds only with a
    promise due within the same window — and the fold changes nothing else about the class: the
    kept-promise silence and the two separately scoped caps (rule 44) stand exactly as written,
    with the fold tried first, so fewer bookings ever reach them.
43b. The promise checker (`lib/promise-check`, [turn-pipeline.md](turn-pipeline.md) rules 32a-32d)
    books a third class beside the auditor's two: the **unkept-commitment** wake — her reply
    claimed a concrete action in the first person and nothing in the turn's evidence shows it
    performed or durably scheduled. The turn's evidence is wider than the turn's own hands, by
    design: she runs several sessions at once and the work a reply announces is often performed
    by a dispatched builder or a parallel session minutes later, so a judge shown only the
    announcing turn's record manufactures false accusations (twenty in one night, 2026-08-10/11,
    every adjudicated one false). The live judge MUST therefore be handed, as separately
    labelled records: the turn's own tool record, the tool records other sessions' and builders'
    stream logs hold from the last `PROMISE_CHECK_EVIDENCE_WINDOW` (default 30) minutes, the
    jobs ledger's dispatches and finishes from that same window, the files the reply itself
    names as they stand on disk (existence and mtime, statted mechanically — the artefact
    refutes the accusation whatever hand and whatever hour wrote it, which a session window
    never can), the recent chess games' own records (id, her side, and the move list as it
    stands — a claim describing the game owes truth, not work, and the game file is its
    witness), and the wake queue's pending bookings (a future commitment whose work a pending
    wake's reason already names is kept by the schedule, whenever it was booked — the checker
    once accused a sentence that merely reported a wake booked four hours earlier) — and a
    commitment ANYTHING in
    that wider evidence plausibly performed, embodies, or durably schedules counts as KEPT,
    exactly as the night sweep has
    always ruled a promise fulfilled by a later session's record. A claim of understanding —
    "I worked out why", "the cause is" — is a finding, not a commitment, and MUST NOT be
    judged at all. A NEGATIVE commitment — one to refrain from acting ("I'm leaving X
    alone", "I won't touch Y", "nothing further from me on Z") — MUST never be flagged
    UNKEPT: absence of action is the keeping of it, an empty record is exactly what a kept
    abstention looks like, and by construction no record can ever back it (a chase wake was
    booked against "I'm leaving the game alone entirely now", 2026-08-15 00:52); the judge
    rules on each commitment's polarity first and short-circuits the negative to KEPT
    without consulting the records. Each pasted record MUST be
    bounded (bounded per call and per file, with any clip marked — never a raw byte cut, per
    the DATA section's one-trim rule). The three disk-truth sections (named files, game
    records, pending wakes) fail soft: an unreadable one is presented to the judge as
    unreadable and named on
    the check log, without unwinding the rest of the widening. Four backed short-circuits spare the model entirely: a
    `crab job` dispatched during the turn or within `PROMISE_CHECK_JOB_BACKED_WINDOW` (default
    15 minutes) before it backs every action-claim by definition; a reply whose only
    commitment is announcing a chess move that the mover's own play record shows played around
    the turn is the mover's work landing as designed; a chess claim the game's own record
    backs — its named moves present in the move list, its counted captures among her side's
    captures, or plain board-state talk beside a game her side has moved in within
    `PROMISE_CHECK_GAME_SLACK` (default 300s) of the claim, candidates drawn from games
    updated within `PROMISE_CHECK_GAME_WINDOW` (default 21600s) — is a truth-claim its
    artefact already witnesses, KEPT unjudged with the backing game named on the check log;
    and a path-shaped token, a bare relative path in prose included, resolved against the
    turn's own workdir, `$HOME`, and the data dir to an artefact whose mtime sits at or after
    the claim's timestamp minus `PROMISE_CHECK_PATH_SLACK` (default 300s) is a completed-work
    claim the disk itself keeps ([turn-pipeline.md](turn-pipeline.md) rule 32b). In each of
    the last two the backed sentences are stripped and the remainder re-faces the pattern
    gate, so a reply that also promises other work is still judged in full; an unreadable
    games dir, game file, or path falls through to the judge with the failure named on the
    check log — never a crash, and never a silent acquittal. Evidence gathering that fails MUST fall
    back to judging on the turn's own record alone — the pre-widening behaviour, an accusation
    rather than a silence — and MUST name the failure on the check log: the widening may make
    the checker fairer, never quietly absent. Its reason MUST open with the unkept-commitment prefix (a
    constant in `lib/common.sh` beside the auditor's two), MUST quote the promise exactly and
    instruct her to do the work now or book it deliberately, and MUST fire minutes out, never
    hours — the point is to catch her while the context is still warm. It MUST be booked with
    the effort override **low** (rule 13a), so the fired session runs at the wake path's own
    model — opus — at low effort: enough hands to do one named piece of work, cheap enough to
    fire for every catch. The checker fires on every channel, wakes included, so its own
    follow-up is not exempt from the evidence test — a wake that claims again and again does
    nothing is caught again — and the chain is bounded instead of exempted: the wake path MUST
    skip the promise AUDIT for this prefix exactly as for the auditor's two (the agenda quotes
    the promise, and an audited quote books deferred wakes forever), the class may book at most
    `PROMISE_CHECK_REBOOK_MAX` chase wakes a day — counted from the ledger's own booking lines
    for the day, NEVER keyed on the promise's wording: a chase that re-claims in different words
    is the same chain wearing a fresh key, and a bound on verbatim text never catches it — past
    which the ledger line lands and the night sweep takes it, and the class carries its own scoped cap (rule 44), so unkept
    commitments neither fill nor drain the auditor's classes. The checker's sweep
    ([nightly.md](nightly.md) rules 51-53) books through the same door under the same identity:
    one morning event wake naming the day's genuine misses, none on a clean day.
44. Any cap on the number of pending wakes a booker may hold MUST be counted from the records under
    the booking lock, and MUST **drain** as well as gate. A cap that only gates new bookings lets a
    queue five times its own size stand for hours. The drain MUST let go of the **furthest-out**
    bookings and keep the nearest: draining from the near end cancels the work about to happen and
    keeps hours of stale promises, which is the inversion of what a cap is for. A cap MAY be scoped
    to a reason prefix — `--cap-prefix` on the one door — so one booker holds separately-capped
    classes of follow-up; a scoped cap counts and drains only its own class. The auditor's two
    classes MUST be capped separately, so a night of want-flags cannot starve caught promises of
    their bookings, nor the reverse.

## DATA

| Path | Format |
|---|---|
| `~/.local/share/deskcrab/wakes/<unit>.wake` | `fire \t kind \t reason \t booked_at \t booked_by [\t effort]` |
| `~/.local/share/deskcrab/wakes/ledger.log` | append-only: epoch, action, unit, kind, reason, actor |
| `${STATE_PREFIX}-wake.lock` | one wake at a time, held for the life of the process |
| `${STATE_PREFIX}-wake-book.lock` | the booking queue, held across check-then-act |
| `${STATE_PREFIX}-wake-urgent` | the urgent lane's claim: the epoch until which an event wake is waiting for the run lock or due back for it (rule 21b) |
| `${STATE_PREFIX}-wake-defer-<key>` | consecutive blocked-lock deferrals of one kind-and-reason; cleared when that wake takes the lock (rule 21a) |
| `${STATE_PREFIX}-stale-check.log` | the staleness gate's trace (rule 27b): one line per decision — skipped, said, dropped, or judge failure |
| `${STATE_PREFIX}-stale-judge-<pid>.log` | the staleness judge's own stream, ledgered for tokens and removed by the gate |
| transient units `deskcrab-wake-<epoch>-<pid>[.timer]` | systemd user manager; the record's shadow |
| `systemd/deskcrab-wake.timer` | the random background interval |
| `systemd/deskcrab-wake-restore.service` | restore at login |

Record fields are tab separated with a fixed order. A reader MUST tolerate a record with only the
first three fields — every record already on disk has that shape — and MUST fill the missing fields
with "unknown" rather than shifting the ones it has. The sixth field, the effort override, is
optional and empty on every record booked without one; a reader treats absent and empty alike.

The ledger MUST stay valid UTF-8, every line, whole. Its reason column is bounded at 200
characters, and the bound MUST fall on a character boundary, never a byte one: a byte cut
(`head -c`) splits a multibyte character, and one stray continuation byte on one line makes grep
classify the ENTIRE file as binary — every query on every record answers nothing and exits 0,
which reads as bookings that never happened. Found live on 2026-08-11: a split em-dash on a single
hot-hold line hid all 958 records at once, in the exact file read to adjudicate promise flags. A
trim that may have cut into a multibyte character MUST drop the partial character rather than
write its leading bytes. There MUST be exactly ONE implementation of that trim — `utf8_trim` in
lib/common.sh — and every bounded cut of a one-line text field goes through it: this ledger's
reason, the sessions log outcome, checkpoints, the account log reason, the held-note words, the
stream last-words tail, notification bodies. A byte-bounded cut of MULTI-LINE material — a
document handed whole into a prompt, where the flatten a one-line field wants would destroy the
structure the reader needs — takes the identical repair through `utf8_head` beside it, the
document-shaped counterpart with the newlines kept; the night-work selection material
([nightly.md](nightly.md) rule 58a) is its callers. The incident above was fixed here first and
found five more unguarded copies of the same byte cut the same night, and four more in the night's
document cuts the same week; a private copy of the pipeline is how the next one appears.

## The lifecycle

```mermaid
flowchart TD
  B1["crab wake-at WHEN KIND REASON"] --> B2["normalise arity<br/>kind not recognised = it is the reason"]
  B2 --> B3["take the booking lock"]
  B3 --> B4{"equivalent booking<br/>already pending?"}
  B4 -->|yes| B5["not booked — say which one covers it"]
  B4 -->|no| B6["snap to a free slot"]
  B6 --> B7["write the record<br/>fire, kind, reason, booked_at, booked_by"]
  B7 --> B8["book the transient timer<br/>--collect + TimeoutStartSec"]
  B8 -->|failed| B9["roll the record back"]
  B8 -->|armed| B10["ledger: booked"]
  T1["background timer<br/>3h + jitter"] --> W
  B10 --> W["crab wake KIND REASON UNIT"]
  W --> W1["retire this booking's record<br/>before any early exit"]
  W1 --> W2["take the wake lock<br/>event: wait, in the urgent lane<br/>other kinds: yield to an unexpired claim"]
  W2 -->|lost| W3["re-book with kind, reason, effort intact<br/>event: escalating seconds — else a spaced slot"]
  W2 -->|held| W4["assemble the wake profile<br/>agenda is the user message"]
  W4 --> W5["generate under the account chain"]
  W5 --> G1{"stream error,<br/>no model output?"}
  G1 -->|yes| G1a["journal the failure<br/>re-book kinded, 30 min"]
  G1 -->|no| G2{"anything to deliver?"}
  G2 -->|no| G2a["journal the work trace<br/>silence, not a crash"]
  G2 -->|yes| G3{"quiet hours, a turn in flight,<br/>or user busy?"}
  G3 -->|yes, a turn in flight| G3b["hold whole: journal, re-book the words<br/>through the queue (rule 27c)"]
  G3 -->|yes, otherwise| G3a["suppress speech<br/>journal what was swallowed"]
  G3 -->|no| G4["append to the conversation<br/>then speak, then show"]
  G1a & G2a & G3a & G4 --> E["ensure_next_wake"]
  E --> E1["restore — ledger every restoration"]
  E1 --> E2["tidy — only demonstrably fired, record-less timers"]
  E2 --> E3["book the floor if no scheduled booking is pending"]
```

## INTERACTIONS

**The wake queue may call:** prompt assembly (wake profile), the account chain, speech output, the
display window spawner, the conversation store, the session registry, the day journal, the memory
recall block and judge.

**The wake queue may be called by:** `crab wake`, `crab wake-at`, `crab wake-cancel`,
`crab wake-restore`, `crab wake-tidy`, the promise auditor, the job runner, the self-change watcher,
the canary, and the login restore unit.

**The wake queue must never be called by:** the state block, which reads the queue and must not
change it.

## VERIFIED-CORRECT RULES

- **Record before timer, with rollback.** A crash between the two leaves a record the reconciler
  honours rather than a timer nothing remembers. If the timer cannot be armed, the record is
  removed, so a failed booking does not become a phantom promise.
- **A timer that has never fired and has no booking record is a pending wake whose record was lost,
  never a ghost.** The janitor only purges timers that have demonstrably fired. Killing a
  never-fired record-less timer cancels a wake nobody asked to cancel. Emptiness in the last-trigger
  field means never fired, and that is the load-bearing safety rule of the whole tidy pass.
- **A unit whose service is active is skipped everywhere.** That is a wake firing right now, and it
  has already cleared its own record.
- **One booker at a time, for the whole check-then-act.** Two wakes finishing in the same second
  each found no pending floor and each booked one.
- **Every booking asks for a free slot, not just the retries.** Spacing the retries alone was
  measurably not enough: within a minute of that fix, two concurrent sessions booking different
  wakes had rebuilt the collision from the front. A nudge of a few minutes costs a promise to
  herself nothing; landing on another wake's second costs it a quarter of an hour.
- **A deferred wake keeps the kind and reason it started with**, so an event wake pushed back past a
  recording still arrives knowing why.
- **The fired wake retires its own record first thing**, before any early exit, or restore
  resurrects a wake that already ran.
- **A busy user is a reason to hold the tongue, not the mind.** The session runs regardless; the
  output decision is made at the end.
- **Silence is an empty reply; `(quiet)` is the one authorized held-thought form.** (Corrected
  2026-08-07: the earlier "never a marker" statement predated the user reinstating the marker.) A
  wake with nothing to say writes nothing. A wake with a thought worth leaving but not voicing
  opens with `(quiet)` — the reply is SHOWN as a "(quiet) …" bubble in the conversation, never
  spoken, even when it has no display section. A bare marker with no thought is plain silence.
  The square-bracket spelling is normalised, and no path may voice the marker.
- **The floor counts only scheduled-kind bookings, judged from the records.** Counting any wake
  timer let one unrelated long-dated booking end the chain.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `C4` | Nothing enumerates the records. `list()` does not exist; the report reads systemd. |
| `C5` | `wake-at` accepts arbitrary text as the kind and `wake` then discards it, destroying the agenda. Such a record never coalesces, never satisfies the floor, and is dropped rather than deferred if it loses the lock. |
| `C7` | Restore re-books every surviving record, event wakes are never collapsed, and the restore output goes to `/dev/null`. Twenty-two cancelled reasons came back verbatim. |
| `MAJ-13` | Transient wake units are booked without the collect option, leaking failed units into the live user manager. |
| `MAJ-14` | Only the random background timer has a runtime ceiling. Every self-scheduled wake, deferral, retry, floor booking and job-completion wake runs with only an in-process watchdog. |
| `MAJ-15` | The promise-wake cap gates new bookings only, never drains, counts systemd descriptions rather than records, and takes no lock. Observed at five to six times its own value. |
| `MIN-5` | A kind-less wake that loses the lock is destroyed, not deferred: the record is cleared before the re-book decision. |
| `MIN-6` | `wake-at` mints unit names inline instead of using the collision-avoiding namer. A collision truncates the earlier booking silently. |
| `MAJ-34` | Bookings are not gated on the wakes directory being the live one, so a test books a real transient unit into the live user manager. See [test-harness.md](test-harness.md). |
| Recommendation §3 | Records carry no provenance and no booked-at, so "scheduled by me" is unanswerable. |

## TESTS

**Existing:** `tests/test_wake_queue.sh` (spacing, coalescing, tidy semantics, with systemd stubbed),
`tests/test_silent_wake.sh` (the delivery gates), `tests/test_regroup.sh` (a whole wake beside a live
voice), `tests/test_wake_filler.sh` (measured from the speaker side), `tests/test_wake_reinforce.sh`,
`tests/test_wake_lock_priority.sh` (rules 21a and 21b: the event backoff — short, escalating, capped,
reset by a taken lock — and the urgent lane's yield, expiry and event-exemption),
`tests/test_promise_deferred.sh` (rules 43a and the scoped cap of 44: a reply that commits to later
work books the alarm, an already-done reply books nothing, a kept promise is left alone, and neither
audit class counts or drains the other's bookings),
`tests/test_promise_cluster.sh` (rule 10b and 43a's fold: three verdicts caught inside one window
— sequentially and as three concurrent processes — are ONE pending wake whose reason lists all
three items with the first booking's fire moment and booked-at untouched, three verdicts spread
past the window are three wakes, a deferred fold happens only when the promised moments fall
within one window of each other and never moves the pending one, a cluster without a class prefix
is refused, the fold lands on the ledger as `folded`, and a folded item is cut through `utf8_trim`
so the reason stays whole UTF-8),
`tests/test_promise_check.sh` (rule 43b: the unkept-commitment wake is an event wake in the
checker's own name, effort low on the record, prefix on the reason and the promise quoted verbatim;
the audit skips the prefix; the rebook bound and the auditor's deferred wake each stop a duplicate
booking; the widened evidence — a job dispatched in the turn's window and a mover-played chess
announcement each short-circuit the model, another session's record and the jobs ledger reach the
judge as labelled sections, an empty window still flags, and a gathering failure falls back to the
own-record judgement with the failure on the trace),
`tests/test_wake_hot_hold.sh` (rule 27a: a quiet bubble into a hot conversation reaches no bubble,
no notifier and no conversation and books itself back with its words in the reason; the same wake
into a cold one is delivered; a SPOKEN wake is delivered hot, which is where rule 29's boundary
sits; `CONVO_HOT_WINDOW=0` restores the old behaviour; the cap bounds the held queue, a hold the
cap refused is journalled as refused rather than as a comeback, and a display-only hold's comeback
carries the built content itself, not a placeholder),
`tests/test_wake_flight_hold.sh` (rule 27c: a SPOKEN wake fired while a desk turn holds a live
delivery-queue ticket reaches no speaker, no notifier, no window and no conversation, journals
that a turn was in flight, and books its words back through the queue under the hot-hold identity
with the held stamp on the reason; the same wake with the ticket's process dead — or the ticket
released — delivers in full, which is what makes the hold mean something; `WAKE_FLIGHT_HOLD=0`
restores the old behaviour exactly),
`tests/test_wake_stale_note.sh` (rule 27b: the hold stamps the comeback's reason with a parseable
held-at moment; a stamped note whose substance the intervening exchange already covered is
DROPPED — nothing spoken, shown, notified or appended, the drop on the journal, the wake ledger
and the trace, the note and the exchange both proven to have reached the judge; a note about
something never mentioned since is SAID and delivered; no turns since the stamp means the judge
is never invoked; a judge that fails delivers the note and logs the failure; an unstamped reason
never arms the gate),
`tests/test_wake_ledger_utf8.sh` (the ledger's UTF-8 guarantee: a reason whose em-dash straddles
the 200-character trim boundary lands as valid UTF-8 with the partial character dropped whole,
plain grep — no `-a` — still finds the record, an em-dash short of the boundary survives intact,
and the 200 limit itself still holds),
`tests/test_utf8_trim.sh` (the one shared trim behind every bounded field: a character straddling
the byte budget is dropped whole, the result is valid UTF-8, a file built from such trims stays
text to a plain grep, characters clear of the boundary survive, newlines and tabs flatten to
spaces, and the budget itself still holds),
`tests/test_wake_no_model.sh` (rule 24a beside 23 and 24, and account-fallback rule 4a's wake half:
with no account variable set anywhere the wake still invokes the CLI exactly once; a CLI that dies
writing nothing is journaled with its exit code and its agenda is re-booked; the launcher's own
last words — a bwrap complaint in the stream — reach the journal line; a clean silent wake books
no failure retry).

**To be written:**

- `tests/test_wake_restore.sh` — the resurrection loop at the heart of the headline bug: a cancelled
  queue must stay cancelled; an overdue queue must collapse; every restoration must appear in the
  ledger.
- `tests/test_wake_arity.sh` — a booking whose third argument is prose recovers its agenda on write
  and on read; a kind-less wake is deferred, re-booked, and satisfies the floor.
- `tests/test_wake_queue.sh` — extend with the record-versus-timer divergence, provenance round-trip,
  the collect option, the runtime ceiling, and a three-field legacy record.
- `tests/test_quiet_hours.sh` — **written.** A wake inside quiet hours reaches no speaker, no
  renderer, no notifier and no conversation, and says in its journal line that the night held it;
  the same wake outside quiet hours is heard and shown, which is what makes the silence mean
  something. The window arithmetic is covered at unit level, wrap included.
- `tests/test_wake_bookers.sh` — each autonomous booker routes through `book()` and
  stamps its own identity.
