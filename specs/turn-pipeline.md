# Spec: turn pipeline

## PURPOSE

One interactive turn, from the moment the user speaks or types to the moment the reply has been
spoken, shown, recorded, and journaled. This spec owns the ordering of that pipeline and the
guarantees a turn makes to the person waiting for it. It covers the desk path and the phone path,
which share every stage except capture and delivery.

## CONTRACT

### Capture

1. `crab start` MUST stop any speech already playing before it opens the microphone.
2. `crab stop` MUST wait for the transcriber to settle before killing it, and MUST bound that wait.
   A transcriber that never settles MUST NOT hold the turn open indefinitely.
3. The captured text MUST pass through the overlap collapser and the configured transcription
   fixes, in that order, before anything else sees it.
4. An empty capture MUST end the turn with a notification and no session, no conversation write,
   and no model call.
4a. The desk capture notifications — the listening notice, its dismissal, and the empty-capture
    notice — MUST name the desktop icon by its theme name (`-i beatrice`), never by a file path.
    The mark itself is deployed state, not repo content: the exported face installs as `beatrice`
    under the user hicolor theme (the PNG sizes and the scalable SVG, then the icon cache), which
    is what makes the bare name resolvable for the notifier, GTK, and any `.desktop` `Icon=` line
    alike — and a name, unlike a path burned into the call, survives the source tree moving.
5. The overlap collapser MUST NOT remove a phrase the user genuinely repeated. When it cannot tell
   a repeat from an overlap, it MUST keep both copies. Answering a question that was not asked is
   worse than answering one twice.
6. Any argument that is not a subcommand is a text query. A leading dash MUST be rejected as a
   mistyped flag and MUST NEVER reach the spoken channel. `help` and its variants MUST print usage
   and MUST NEVER become a turn.
6a. A named maintenance command MUST have its own dispatch case and MUST NEVER fall through to
    the catch-all: the catch-all is the spoken channel, so a command name reaching it becomes a
    conversational turn — at 23:43 on 2026-08-25 an autonomous hand ran `crab shelf-check`
    intending the nightly shelf-line check, and what ran instead was a three-second desktop turn
    whose user text was "shelf-check". `crab shelf-check` MUST execute `lib/shelf-check`
    ([nightly.md](nightly.md) rules 21a-21b) directly: no model call, no session, no conversation
    write, no live-turn record, and no speech or notification path may start. The same
    never-a-turn holds for the usage paths: `crab` with no arguments MUST print usage and exit
    without a turn — an `exit` welded onto the usage `echo` as one more argument (2026-08-25)
    printed the usage and then ran an EMPTY desktop turn behind it.
7. The recorder pid file MUST be overridable per instance, so a scratch instance never reads the
   live desk's recording state.

### Turn ordering

8. A turn MUST register a session before it builds a prompt, and MUST record its origin device.
9. The user's words MUST be written to the conversation before generation starts, so a turn that
   dies mid-reply still leaves the question on the record.
10. The turn MUST publish an in-flight record (`live-turn`) naming the device and the user's text at
    turn start, and MUST close that record at turn end with the spoken reply.
11. The speech streamer MUST be started before the model runs, so speech begins when she starts
    talking rather than when she stops.
12. Generation MUST run under the account chain (see [account-fallback.md](account-fallback.md)) and
    MUST be bounded by a watchdog on every path. A desk or phone turn has someone waiting; an
    unbounded run is a defect, not a slow answer.
13. The stream log MUST be truncated exactly once per turn, at the start. Every retry APPENDS.
    Truncating for a retry strands the reader that is already tailing the file.
14. A "Thinking" style notification MUST be dismissed on every exit path, including the refusal
    path, the empty-reply path, and the watchdog-reap path.

### Delivery

15. A reply MUST be spoken, shown, appended to the conversation, and journaled — in that order of
    guarantee, not of timing. Speech may begin before the reply is complete; the conversation write
    happens once, after the reply text exists.

**Delivery order.** Turns run concurrently — one process per push-to-talk — so until rule 15a
existed a reply was delivered whenever its own generation happened to finish, and the order of his
conversation was decided by which question was cheaper to answer. Measured 2026-08-10 from the day
journal and the metrics log: his 12:31:15 message took 149 seconds to answer and his 12:31:46 one
took 69, so the answer to the SECOND reached him at 12:32:39 and the answer to the first at
12:33:31 — a quotation-marks theory arriving 105 seconds after he had said, in those words, that it
was not about quotation marks. He read it as her answer to what he had just said, because that is
what it looked like, and two minutes later he took her offline. A reply landing in a newer message's
slot is the loudest statement this machine can make that it was not listening.

15a. Every interactive turn MUST take a place in one delivery queue at turn start, in arrival order,
     on the desk and the phone alike. He is one person having one conversation and which handset he
     reached for does not change the order he said things in. The place is taken before the prompt
     is built and released when the reply has been delivered — or by the session's exit trap, so a
     turn killed anywhere cannot hold a place the next reply queues behind. On the phone the place
     — and with it rule 15c's supersede pass — MUST be taken BEFORE the remote serialisation lock
     ([phone.md](phone.md) rule 2) is waited on, never inside it: the seat is the moment the
     message arrived, and a message parked at the lock has still arrived. Taken inside the lock, a
     phone pushback queues behind the very turn it closes and cannot supersede it until that turn
     has fully delivered, and a desk turn arriving after the pushback takes an earlier seat than
     the message that beat it here. The wait chains this opens stay bounded: every waiter gives up
     after `TURN_ORDER_WAIT` and delivers out of order, saying so (rule 15b).
15b. A reply MUST NOT be delivered while an earlier turn is still owed its delivery. The wait is
     bounded by `TURN_ORDER_WAIT`; past the bound the reply goes out and the session outcome says
     it went out of order. A reply held forever is the failure this rule exists to prevent, not an
     acceptable price for preventing it.
15c. A message from him that is **pushback at the detector's STRONG class** (`dispute_detect`,
     [dispute-turn.md](dispute-turn.md) rules 6-6b) SUPERSEDES every turn still in flight behind it. STRONG
     only: the dispute frame may ride on a softer signal, where a false positive costs a stronger
     turn, but a superseded reply is silently never spoken — so nothing that could be a benign
     message ("no worries", "run it one more time") may ever close one. A superseded reply answers a question he has
     since closed, and it MUST NOT be spoken, shown, or synthesised, and MUST NOT be announced as
     though it were a reply. The turn MAY raise one notification saying that a reply was held —
     nothing here happens silently — provided it carries none of the held words. It MUST be appended
     to the conversation marked as a reply she wrote and did not say, and it MUST be journaled in
     full with an outcome naming the message that closed it. This is the regroup bargain made at
     delivery instead of at drafting: one voice, one reply, and the reply that stands is the one
     answering what he last said. The words are never lost — the next turn's prompt reads them as
     something withheld and may carry them forward if they still stand.
15d. Nothing waits on a superseded turn. Waiting for a reply that will never be spoken would delay
     a live answer behind a dead theory, which is how ordering becomes a latency regression instead
     of a fix.
15e. A superseded turn's VOICE MUST be stopped at the moment it is superseded, not when it
     finishes. The streamer speaks sentence by sentence as the model writes, so a turn that only
     learns at delivery time that its moment has passed may already have said the whole thing —
     which would leave rule 15c holding the transcript and nothing else, and it was never the
     transcript he heard. The pushback message is him talking over her, and `crab start` has always
     stopped speech the moment he does (rule 1); this is that same policy aimed at the one voice
     his message closed. It MUST be aimed by the pid in the ticket — the streamer is a child of the
     turn's shell — and MUST NOT be a process-wide kill of speech, which would cut off a turn
     nobody rejected. The superseded turn also MUST NOT run the never-silent guarantee, which would
     read the empty receipt as a broken speech path and say the whole held reply aloud. Being
     superseded also means not delivered, so the out-of-band work that judges what he was TOLD —
     the promise audit, the promise checker, the claudism capture — does not run for it; the memory
     judge does, because a memory that shaped the reply shaped it whether or not it was spoken.
15f. **Cut-and-consolidate: an ordinary new utterance CUTS the turn in flight — queueing is the
     backstop, never the design.** His correction, recorded 2026-08-07 13:23: interrupt design is
     cut-and-consolidate, never queueing — the serialise-and-queue build that preceded it was
     killed for exactly that. When a message of his arrives, on either device, while an
     interactive turn still holds a live ticket, and the message is not rule 15c's STRONG
     pushback (which keeps its harder close: the theory is dead, and nothing of it is folded
     forward), the arriving turn MUST close the in-flight turn at the moment its own seat is
     taken:
     - the in-flight turn's VOICE is stopped at once, by the pid in its ticket, never
       process-wide (rule 15e's discipline). The catch-all's `stop_tts` has always taken the
       box's synthesiser at a new query, killing whatever was already handed over; the cut is
       what kills the STREAMER too, so it cannot reopen a synthesiser for every sentence the
       un-aborted run would have kept writing — the superseded reply talking on after the
       interruption, measured in `tests/test_turn_interrupt.sh`'s red run;
     - the in-flight turn's MODEL RUN is aborted rather than allowed to finish and speak: its own
       watchdog reads the cut marker within a beat and reaps the CLI, and the account walk boots
       no further attempt for a cut turn;
     - the arriving turn composes ONE reply from the consolidated context: the cut turn's input
       (already on the conversation by rule 9, and quoted whole in the interrupt layer —
       [prompt-assembly.md](prompt-assembly.md) rule 36c), whatever partial reply the aborted run
       had already produced — snapshotted from its stream log at the moment of the cut, through
       the one extractor's partial mode, which is built on the shared chunker registry and never
       a second parser — and the new utterance. One run, one reply, one audio stream.
     A cut turn delivers NOTHING anywhere: no speech — and the never-silent guarantee MUST NOT
     read the cut's silence as a broken speech path — no window, no conversation block, and not
     even rule 15c's held block, because the fold IS the record: the surviving reply carries the
     words forward, the journal keeps the part-written text in full, and the cut turn's outcome
     names the message that cut it. No notification either — nothing was lost and the
     interruption was his own act; the surviving reply is the receipt. The out-of-band judges
     follow rule 15e's split: the memory judge runs, the three that judge what he was TOLD do
     not. Nothing waits on a cut ticket, and a cut turn stops waiting the moment it is cut (rule
     15d's discipline, both directions). `TURN_INTERRUPT=0` switches the cut off and restores the
     pure delivery queue — the backstop `tests/test_turn_order.sh`'s ordering cases pin — and
     with the queue off entirely (`TURN_ORDER_WAIT=0`) no tickets exist, so nothing can be cut.

16. A turn that produced no text MUST report itself: a notification and a session outcome line. It
    MUST NEVER be silent in the way a wake is silent. Answering a question with nothing is a
    failure and is recorded as one.
16a. A session that ends before delivering MUST say so in the day journal, and MUST hand over
     whatever reply exists. A killed turn never reaches any of its own branches, so its reply and
     its outcome are both empty and the journal writes `"reply": ""` with no outcome — the same row
     a turn whose model produced nothing writes, and the same row a turn nobody ever answered
     writes. Three different failures, one indistinguishable record, and no way to tell from the
     day afterwards that anything went missing. Measured 2026-08-10: the 12:33:04 turn was the one
     that found the right answer to the bug he was reporting and committed the fix; its shell was
     killed at 12:35:35, its CLI finished writing that answer into the stream log ten seconds
     later, and the journal row for it says `"reply": ""`. So the exit trap MUST read the turn's
     own stream log on its way out and journal what it finds — with an outcome saying plainly that
     it was recovered and never delivered — and when there is nothing to find, MUST say THAT rather
     than leaving the row blank. The empty reply with no explanation is not a state this pipeline
     may reach.
     - The record MUST claim only what it can support. "Delivered" and "heard" are different
       questions: the streamer speaks while the model is still writing, so a turn killed at the end
       may genuinely have said most of its reply aloud and still delivered nothing anywhere else.
       The outcome states the delivery facts it owns (nothing shown, nothing added to the
       conversation) and reports the speakers from the streamer's own receipt — including saying
       that no receipt was left, which is an honest answer where "it was never spoken" would be a
       guess. A record that overclaims is the failure this rule was written against wearing better
       clothes.
16b. **One emptiness test, above every sink.** There MUST be exactly one implementation of the
     test that decides a finished reply has nothing to deliver — `reply_delivery_split` in
     `lib/common.sh` — and every delivery path (desk, phone, wake) MUST branch on it exactly once,
     above every sink that path owns: the speakers and the synthesised clip, the display window,
     the conversation file the phone follows, and the notification. A sink added below the branch
     inherits the gate; a sink testing emptiness for itself, its own way, is the hole this rule
     closes — the wake path knew three shapes of empty while the desk and the phone knew one.
     Empty means: no text at all, whitespace only, or the quiet marker — either spelling — with
     nothing behind it and no display half. An empty interactive reply takes rule 16's no-text
     branch, notified and journalled, never delivered anywhere; an empty wake completes invisibly
     ([wake-queue.md](wake-queue.md) rule 24), its words kept by the journal alone.
     The split is also where the quiet marker is decided, once for every path: a reply whose
     spoken half OPENS with the marker delivers as the shown "(quiet) …" bubble — voiced nowhere,
     its thought passed through the replace table ([speech-output.md](speech-output.md) rule 54),
     the square-bracket spelling normalised — and such a reply's voiced half is empty by
     definition, so the never-silent guarantee cannot fire on it and no path may synthesise the
     thought ([speech-output.md](speech-output.md) rule 57 holds the live half). Before this rule
     the wake path alone knew the marker: a desk reply opening "(quiet)" was streamed to the
     speakers marker-first, a phone turn synthesised the held thought into a clip, and a
     marker-only reply reached the chat as a bare "(quiet)" bubble.
16c. **A delivered reply may not leave him a chore.** Nothing delivery puts on his screen may hand
     the user a command line to run: work a reply assigns him is work this machine can dispatch,
     so the chore becomes a detached job and the displayed text names the job instead. The origin
     (2026-08-25, thread `my-output-can-end-in-a-chore-for-him-and-a-recor`): a night session
     ended its work as two command lines for the user, one of them — "Also unset:
     TIDY_CLAIMS_ROOTS" — a statement of fact phrased so it READ as an instruction, and he woke
     to a chore his own machine could have run. The gate is ONE implementation
     (`chore_gate_pass`, run inside rule 16b's split so every delivery path inherits it), and it
     scans ONLY the display half — the channel where a command line renders as a thing to copy.
     The voiced half is never touched (speech-output's standing rule: nothing gates her speech,
     and the desk has often already spoken it), and a quiet bubble is a held thought, not an
     assignment. A displayed block that ASSIGNS the user command-shaped work — a second-person
     obligation with a command beside it ("you'll need to run `x`"), an imperative command line
     ("Run: …", "Also unset: TIDY_CLAIMS_ROOTS" — judged on how it reads, because how it reads is
     the harm), or a run-this lead-in over a fenced or indented command block — is dispatched
     ONCE per reply through the job door (`crab job`'s own policy whole: queued while he is awake
     and a shelf stands, the block marker honoured), the chore lines riding as the brief, and
     every matched block is replaced by one line naming the job id. Ordinary quoted commands,
     narration ("I ran `git diff --check`", "the suite runs via `bash tests/…`"), names
     ("`crab eng list` is the way in") and statements of fact are NEVER touched: the detector
     (`lib/chore-scan`, one implementation, shared with
     [engineering-records.md](engineering-records.md) rule 15) requires the assignment, not the
     command, and is deliberately narrow — what it misses is the record gate's and the night's
     business, never a reason to widen it into a filter on her words. The gate FAILS OPEN: a
     missing or crashing scanner, and a dispatch the door refuses, cost the conversion and never
     the delivery — the reply goes out as written and the trace log says why. Nothing here may
     warn instead of dispatching, leave the user instructions about the gate, or hold a reply.
17. A turn whose every account refused over a usage limit MUST NOT speak the refusal, MUST NOT
    append it to the conversation, and MUST surface it through the notification, the session
    outcome, and the phone's `error` field.
18. A CLI error text MUST NEVER be voiced in her own voice on any path.
19. The display window MUST open as soon as the display half is known, and MUST NOT wait for speech
    to finish.
20. Out-of-band work (memory judge, promise audit, promise checker, claudism capture) MUST run
    after the user has their answer, MUST be detached, and MUST NOT hold any lock the turn held.
21. Every detached child MUST inherit the full set of instance redirects: config path, state prefix,
    memory directory, jobs directory, wakes directory, account state file, and the current
    login. A child that inherits some of them writes into the live instance from a scratch one.
22. The session's exit trap MUST journal the turn even when the turn was killed. A session killed
    without its trap MUST be reaped and journaled as interrupted, never allowed to vanish.

### Conversation store

23. `convo_append_user` and `convo_append_assistant` MUST be the only writers of a conversation
    block, and every block MUST carry the local time it was written.
24. Every reader MUST treat the timestamp as optional. Existing files and archives are unstamped,
    and a pattern that silently stops matching them loses turns without erroring.
25. Every writer, rotation, and compaction MUST hold the conversation lock.
26. Compaction MUST NOT hold the lock across the summarising model call.
27. Compaction MUST NEVER commit a summary that is a refusal. The limit signature MUST be applied to
    the committed text, not only to the retry decision. A refusal that lands in the summary destroys
    the folded blocks permanently. The same holds for the CLI's own error text in any wording the
    signature does not know: the summariser's extraction runs with `DESKCRAB_DROP_SYNTHETIC=1`
    ([speech-output.md](speech-output.md) rule 7a), so an error-only stream folds nothing rather
    than committing the CLI's words — on 2026-08-20 an OAuth auth failure the signature did not
    then know was committed as the summary the phone renders.
28. The summariser MUST use the speaking-tier Sol model first because the resulting text is
    conversation continuity, not background classification. A failed or cooling Sol login falls
    through to the configured Claude outage model and account walk; provider errors and capacity
    text never enter the saved summary. Both engines MUST capture stderr, and a Sol capacity
    refusal MUST record the codex cooldown before fallback.
29. Rotation MUST archive on inactivity, and the archived pair (transcript and summary) MUST move
    together.

### Turn-close capture

The listening half of the nightly claudism review ([nightly.md](nightly.md)): a cheap phrase-list
pass over what was just said, so the night has a day's flag log to judge. Detection only, by
design and by rule — the review exists to break a habit, never to gate a tongue.

30. Every path that delivers a reply (desk, phone, wake) MUST hand the response to the claudism
    capture at the same out-of-band moment as the promise audit: detached, after the user has
    their answer, never on the hot path. The capture MUST NOT edit, hold, delay, or veto any part
    of the turn, MUST scan only the spoken half of the reply, and MUST stay silent — no
    notification, no wake, no mid-conversation surfacing. Its only output is the flag log and its
    own one-line run trace.
31. A flag record MUST carry enough to find the turn again: the session's start epoch and pid
    (the day journal's identity), the journal kind, the sentence as spoken, and the pattern that
    matched — and, so the night can score the move rather than the string, the entry's function
    where the list declares one and whether the words were used or merely mentioned (quoted, in
    a code span, or talked about — [nightly.md](nightly.md) rule 47). A mention is still a
    record: the capture drops nothing, it classifies. The flag log is append-only, dated like
    the journal, and flocked like it. Its
    readers: the recent-catches block ([prompt-assembly.md](prompt-assembly.md) rule 35) surfaces
    it at the start of a turn, and the pre-speech mirror ([speech-output.md](speech-output.md)
    rule 45) appends its live fires and outcomes beside the capture's records. The nightly review
    still judges from the journal directly; [nightly.md](nightly.md) `MIN-34` tracks the
    corroboration owed.
32. A missing phrase list is not an error: the capture simply does not fire. A capture that
    cannot parse the list, or that crashes, MUST exit quietly without touching the turn — its
    run-trace line is the only place that failure shows.

### The promise checker

Her replies claim, in the first person, concrete actions — "I am wiring it now", "I've written
it to the log", "I will restart it and tell you when it is in" — and the turn ends with the
action never taken. The promise audit catches the promise with no booking behind it; this
catches the claim with no work behind it, and it can, because the turn's own stream log
records every tool call that actually happened. External and automatic on purpose: she has
proven she cannot be trusted to audit her own follow-through, so the verdict comes from a
cheap model reading the evidence, never from her. And because the live check is deliberately
cheap and gated, the nightly sleep pass sweeps the whole day behind it
([nightly.md](nightly.md) rules 51-53): the checker is the fast hand, the night is the honest
ledger.

32a. Every candidate reply — the desk, the phone, and the autonomous wake alike; every
     channel she speaks on — MUST run the checker's presence pre-check before any part of the
     reply is spoken, shown, streamed to the phone, or committed to conversation history. The pre-check
     is a pattern match for the shape of a first-person commitment (`promise_precheck` in
     `lib/common.sh`, one shared function): it costs a grep and MUST NOT call any model. Most
     replies carry no commitment, and for them the whole feature is that grep and one
     run-trace line — no child spawned, no stream copied, no model invoked. A reply the
     pre-check flags is handed synchronously to `lib/promise-check inspect` with the response,
     a private snapshot of the turn's stream log, and the turn identity. A clean verdict lets
     the candidate continue. An UNKEPT verdict, a missing verdict, or an unavailable checker
     MUST hold the candidate back.
32aa. A held candidate goes through another tool-capable pass on the same turn model. That
      pass receives the user's request, the unsent candidate, and the checker's verdict. It
      MUST perform or durably dispatch every safe, authorised action needed to make the claim
      true, using `crab wake-now` when an immediate background wake is the right handoff and
      `crab job steer <id> <correction>` when the claim concerns an active builder, then
      write a complete replacement reply supported by the resulting record. It MUST NOT replace
      current action with an invented later `wake-at`. When
      the action cannot be performed within the user's authority or the available tools, the
      replacement states what is actually true and does not repeat the claim. The replacement
      is inspected again against the combined record. This repair is bounded by
      `CLAIM_GUARD_REPAIRS` (default 2); if no candidate
      passes, delivery uses a truthful non-action response and none of the unsupported drafts.
      `CLAIM_GUARD` defaults to the `PROMISE_CHECK` setting, so the existing master switch
      governs both halves unless the pre-delivery half is explicitly configured on its own.
      The detached `turn` check remains as a record and nightly backstop after delivery, but it
      MUST NOT be the first time a candidate action claim is checked.
32b. The checker asks a cheap verifier — `PROMISE_CHECK_MODEL`, default `sonnet` (the conf
     convention of `MEMORY_JUDGE_MODEL`), with `PROMISE_CHECK_FALLBACK_MODEL` (default
     `haiku`) standing in when the verifier answers with nothing parseable — to extract every
     first-person commitment to a concrete action from the reply and judge each against the
     tool calls the stream actually records. Three shapes are in scope: the present
     commitment ("I am wiring it now"), the immediate future ("I'll restart it"), and the
     claim of completed work ("I've written it to the log") — the completed claim is
     precisely the lie this checker exists for, and unlike the audit it holds the record that
     can refute it. A statement about future conversation, an offer still awaiting an answer,
     and a bare want are not commitments. Neither is a claim of understanding — "I worked out
     why", "I realised", "the cause is" — which reports a finding and owes no work: the checker
     read "I worked out X" as "I did the work X" and accused a diagnosis of being an unkept
     chore (2026-08-11 09:42). And polarity comes before judgement: a NEGATIVE commitment —
     one whose content is a commitment to REFRAIN from acting ("I'm leaving X alone", "I
     won't touch Y", "nothing further from me on Z") — MUST never be ruled UNKEPT, by the
     live judge or by the sweep. Absence of action IS the keeping of it: an empty tool
     record is exactly what a kept abstention looks like, and by construction no record can
     ever back it — the checker read "I'm leaving the game alone entirely now" as an unkept
     chore and booked a chase wake against a promise no tool call could ever keep
     (2026-08-15 00:52). The judge's instructions MUST have it classify each commitment's
     polarity first and short-circuit the negative to KEPT without consulting the records at
     all. The record the judge holds is wider than the turn's
     own calls ([wake-queue.md](wake-queue.md) rule 43b): she runs several hands at once and
     the announced work is often performed by a parallel session or a dispatched builder, so
     the judge is handed the other sessions' recent tool records and the jobs ledger's recent
     dispatches beside the turn's own, each as a labelled section — and, because the right
     question is always whether the thing exists rather than whether this turn ran a tool, two
     more labelled sections: the files the reply names, statted from the disk itself (an
     artefact that exists, with a modification time consistent with the claim, is the record
     that keeps a completed-work claim — whoever's hand wrote it), and the wake queue's pending
     bookings (a future commitment whose work a pending wake's reason already names is kept by
     the schedule, whenever the schedule was written). In pre-delivery `inspect` mode the checker
     also receives the user's request, and timing is part of the match: when the request calls for
     current action or reports a defect in active work, a later wake time Beatrice invented does
     not keep the claim. Direct work, an immediate job, or `crab wake-now` does. A later
     `wake-at` keeps it when the user named that time or the work genuinely depends on a later
     condition. A `wake-now` call never keeps a claim that a running builder was corrected: it
     starts a different assistant wake. Only a matching `job steer` record keeps the claim that
     the correction was queued for that builder, and its delivery receipt is required to claim
     that the builder received it. Post-delivery checks keep deliberate future commitments
     exactly as before.
     Anything in any of them
     that plausibly performed, embodies, or durably schedules the commitment makes it KEPT. A
     commitment nothing anywhere
     performed is UNKEPT; a call that durably scheduled the work counts as performing it —
     a `crab wake-at` or `crab job` naming that work is a kept promise, not an excuse — and
     four cheap backed short-circuits (a job dispatched in the turn's window; a chess-move
     announcement the mover's record shows played; a chess claim the game's own record backs;
     a named path fresh on disk) spare the model call entirely. The last two are the artefact
     standard reaching where it had not. A claim ABOUT a chess game — a move announced or
     described, a capture counted, a statement of board state — is not a promise at all: it
     owes truth, not work, and its witness is the game's own move list under the chess state
     dir, never the announcing turn's tool stream, which is empty by construction when the
     mover played the move (eight flags of this family between 2026-08-15 and 2026-08-25,
     every one false). The checker MUST read the game files as an artefact source exactly as
     it reads the jobs ledger: a sentence a recent game backs — its named moves present in
     the move list, its counted captures among her side's captures, or plain board-state talk
     beside a game her side has moved in within `PROMISE_CHECK_GAME_SLACK` (default 300s) of
     the claim — is stripped and the remainder re-faces the pattern gate, and the recent
     games' move lists stand beside the judged evidence as the sixth labelled record
     (candidates within `PROMISE_CHECK_GAME_WINDOW`, default 21600s). And a PATH-SHAPED token
     in the reply — a bare relative path in prose included (`Library/chess-notes.md`, flagged
     2026-08-20 with the file on disk one minute old) — MUST be resolved against the obvious
     roots (the turn's own workdir `PROJECT_DIR`, `$HOME`, and the data dir): a resolved
     artefact whose mtime sits at or after the claim's own timestamp minus
     `PROMISE_CHECK_PATH_SLACK` (default 300s) keeps its claim unjudged the same way. Neither
     source loosens the checker: a claimed move absent from every recent game's move list and
     a named path nowhere fresh on disk are judged exactly as before, and an unreadable games
     dir, game file, or path degrades to today's judgement with the fall-through named on the
     run trace — never a crash, and never a silent acquittal.
32c. Every UNKEPT verdict MUST land in two places: one JSON line appended to the durable
     ledger — timestamp, the promise quoted exactly, why the record shows nothing did it, the
     turn's journal identity, and what became of the wake — and one event wake through the
     queue's one door, minutes out (`PROMISE_CHECK_WAKE_DELAY`, default 3m — the point is to
     catch her while the context is still warm), booked at effort **low** through the
     rule-13a override, so the fired session runs at the wake path's own model — opus — at
     low effort: cheap enough to fire freely, strong enough to actually do the thing. Its
     reason opens with the unkept-commitment prefix and quotes the promise verbatim
     ([wake-queue.md](wake-queue.md) rule 43b). Two bounds keep an accusation from becoming a
     storm: a promise the auditor's deferred wake already covers from this same turn is
     ledgered as covered and not booked twice, and one verbatim promise may earn at most
     `PROMISE_CHECK_REBOOK_MAX` (default 2) wakes a day — past that the ledger line still
     lands and the night sweep takes it.
32d. The evidence is the stream log, and its absence is not a verdict: a checker handed no
     readable log judges nothing, and its run trace says so — an accusation needs the record.
     A log that exists and holds zero tool calls IS the record: a turn that ran no tools kept
     no promise of action itself, and only the wider window's records (rule 32b) can keep it
     for her. Gathering that wider record is allowed to fail; the failure MUST land on the
     run trace and the judgement falls back to the turn's own record alone — the strict
     pre-widening behaviour, never a silent skip and never a silent acquittal. Model failure
     is never quiet either — a refusal walks the account
     chain like every out-of-band call ([account-fallback.md](account-fallback.md) rule 29),
     an answer with no parseable verdict falls to the fallback model on the same login, and a
     run that gets nothing from either ends with the failure named on the trace. A missing or
     broken checker costs the check, never the turn: every failure path exits quietly with a
     trace line, and nothing here may hold, edit, or veto a reply.
32e. The night's evidence is the journal, so every DELIVERED reply's session outcome MUST
     carry a compact record of what the turn's own hands did — the desk and the phone exactly
     as the wake's silent outcome always has (`wake_work_trace`: files written, jobs
     dispatched, commands run — or the explicit "ran no tools, touched nothing", which is a
     record, not an absence). The live checker's stream snapshot dies with the turn, and a
     completed-work claim that slips its pattern pre-check leaves nothing else behind: the
     nightly sweep ([nightly.md](nightly.md) rules 51-53) judges the morning after from the
     journal alone, and without a trace on the desk and phone rows a "Done — X" said on those
     channels was unfalsifiable the next day. The trace rides between the asked and replied
     halves on purpose: the outcome line is capped, the full reply already rides the journal's
     own reply field, so the cap may clip the reply's echo and never the evidence.

### Turn metrics

Somebody is waiting for a spoken reply, and "where did the time go" must be answerable from a
file rather than re-instrumented every time the question comes up.

33. Every interactive path stamps where its time went — capture released and transcribed, queue
    entered and won, prompt built, generation started and ended, first tool call, first audio —
    one line per stage, appended to a dated metrics log. The stamps are evidence, never control
    flow: a stamp that cannot be written costs nothing but itself, holds no lock the turn holds,
    and no stage may wait on one. Nothing on any prompt path reads this file; it is a
    measurement, read by hand (`tools/turn-latency-report`). `TURN_METRICS=0` switches the
    whole thing off.

## DATA

| Path | Owner | Format |
|---|---|---|
| `${STATE_PREFIX}-whisper.txt` | capture | raw transcriber output, deleted after read |
| `${DESKCRAB_PIDFILE:-${STATE_PREFIX}.pid}` | capture | recorder pid |
| `${STATE_PREFIX}-convo.txt` | conversation store | `User [YYYY-MM-DD HH:MM]: …` / `Assistant […]: …` blocks |
| `${STATE_PREFIX}-convo-summary.txt` | compaction | condensed prose, opens with its time span |
| `${STATE_PREFIX}-convo.lock` | all writers | flock |
| `${STATE_PREFIX}-debug-<pid>.log` | the turn | stream-json, one file per session |
| `${STATE_PREFIX}-debug.log` | `claim_debuglog` | symlink to the newest session log |
| `${STATE_PREFIX}-live-turn` | turn | `epoch \t device \t status \t user text \t reply` |
| `${STATE_PREFIX}-turn-order/<seq>.ticket` | `turn_order_take` (rule 15a) | `pid \t proc-start \t epoch \t device \t stream-log \t user text (flattened, bounded)`; zero-padded seq, so glob order is arrival order; readers of the first four fields tolerate the short pre-15f form |
| `${STATE_PREFIX}-turn-order/<seq>.superseded` | `turn_order_take` (rule 15c) | `superseding-seq \t the message that closed it` |
| `${STATE_PREFIX}-turn-order/<seq>.cut` | `turn_order_take` (rule 15f) | `cutting-seq \t the new utterance (flattened, bounded)`; read by the cut turn's watchdog, its delivery gates, and the guarantee's belt |
| `${STATE_PREFIX}-turn-order/next` | `turn_order_take` | the monotonic ticket counter |
| `${STATE_PREFIX}-turn-order.lock` | every queue operation | flock, on fd 6 — never 9, which is the conversation lock in one hand and the wake lock in another |
| `~/.local/share/deskcrab/sessions/<pid>` | session registry | `kind \t pid \t started \t epoch \t proc-start` |
| `~/.local/share/deskcrab/sessions/<pid>.claim` | `crab claim` | one line, advisory |
| `~/.local/share/deskcrab/sessions/<pid>.ckpt` | `crab checkpoint` | append-only, one line per checkpoint |
| `${STATE_PREFIX}-sessions.log` | `session_finish`, `session_reap` | append-only journal |
| `~/.local/share/deskcrab/journal/<date>.jsonl` | `day_journal_append` | one JSON object per finished turn |
| `~/.local/share/deskcrab/claudisms.md` | the nightly review (see [nightly.md](nightly.md)) | phrase list: a `## heading` per claudism with a `- pattern:` line carrying the trigger in a backtick span; a list with no `- pattern:` lines is read as one trigger per bullet/heading, from its first span; entries MAY add `- function:`, `- fix:` and `- live:` lines ([nightly.md](nightly.md) rule 46, [speech-output.md](speech-output.md) rule 50) |
| `~/.local/share/deskcrab/claudism-flags/<date>.jsonl` | `lib/claudism-capture` | one JSON object per flagged sentence |
| `${STATE_PREFIX}-claudism-capture.log` | `lib/claudism-capture` | one line per run: ran-and-found-nothing versus never-ran |
| `~/.local/share/deskcrab/promise-ledger.jsonl` | `lib/promise-check` | one JSON line per UNKEPT commitment (rule 32c), plus the sweep's identified records and their later resolutions ([nightly.md](nightly.md) rules 53, 53f) |
| `${STATE_PREFIX}-promise-check.log` | `fire_promise_check`, `lib/promise-check` | one line per run: the pre-check's verdict, the model's verdicts, or why nothing was judged |
| `${STATE_PREFIX}-chore-gate.log` | `chore_gate_pass` (rule 16c) | one line per scanned display half: clean, fired with the job id, or why the conversion failed open |
| `${STATE_PREFIX}-promise-evidence-*` | `fire_promise_check` (rule 32a) | the turn's stream log, snapshotted for the detached checker, removed by it |
| `~/.local/share/deskcrab/last-origin` | `record_origin` | `desk` or `phone`, durable |
| `~/.local/share/deskcrab/metrics/<date>.log` | `turn_metric` (rule 33) | `epoch.ms \t pid \t kind \t stage \t detail` |
| `voice-claude-archive/` | rotation | archived transcript and summary pairs |

## The pipeline

```mermaid
flowchart TD
  A["push to talk → capture"] --> B["release → settle poll, bounded"]
  B --> C["collapse overlaps, apply fixes"]
  C --> D{"anything captured?"}
  D -->|no| D1["notify, end — no session, no model call"]
  D -->|yes| E["rotate the conversation if idle"]
  E --> F["register the session, record the origin"]
  F --> G["publish the in-flight record"]
  G --> H["append the user block"]
  H --> I["claim this session's stream log<br/>start the speech streamer"]
  I --> J["assemble the turn profile"]
  J --> K["walk the account chain<br/>under the watched runner"]
  K -->|swap| K1["marker in the log + notification"] --> K
  K --> L["terminator, declare our own writes"]
  L --> M["extract the reply"]
  I -.tails the same log.-> S["streamer speaks sentence by sentence"]
  M --> N{"outcome"}
  N -->|every account refused| N1["not spoken, not conversed<br/>notify, journal, error field"]
  N -->|nothing to deliver — empty, whitespace,<br/>or a bare quiet marker (rule 16b)| N2["notify, journal — a question answered<br/>with nothing is a failure"]
  N -->|reply| O["append the assistant block<br/>close the in-flight record<br/>compact, record the outcome"]
  O --> P["open the display window"]
  P --> Q["wait for the streamer, bounded<br/>then the never-silent guarantee"]
  Q --> R["out of band: memory judge, promise audit,<br/>claudism capture, promise checker"]
  N1 & N2 & R --> Z["exit trap: session finish → journal"]
  X["killed without the trap"] --> Y["reaped and journaled as interrupted"]
```

## INTERACTIONS

**The turn pipeline may call:** prompt assembly, the account chain, the speech streamer, the display
window spawner, the conversation store, the memory recall block, the memory judge, the promise
audit, the promise checker, the session registry, the day journal, the self-change write
declaration.

**The turn pipeline may be called by:** the push-to-talk binding (`crab start` / `crab stop`), the
catch-all text query, `crab remote` (phone), and the phone server.

**It must not be called by:** the wake path. A wake has its own delivery rules
(see [wake-queue.md](wake-queue.md)) and shares only generation and the conversation store.

## VERIFIED-CORRECT RULES

- **A reply enters the conversation only if it was delivered.** The append happens at the end of the
  delivery section, past every gate. A session whose output was suppressed leaves the conversation
  exactly as it found it, and its words survive in the session journal. The phone follows the
  conversation file, so an append before the gates posts a monologue into the user's chat that he
  did not ask for and cannot answer.
- **One stream log per session, with a symlink for "whatever is talking now".** A shared log meant a
  desk turn starting mid-wake truncated the wake's output, a wake starting mid-turn wiped the desk's
  reply before it was read, and whichever read second read both streams as one.
- **No process-wide kill of "any prior streamer" when a turn starts.** That existed only because the
  log was shared. With a log per session it silences another turn's reply mid-sentence.
- **Conversation stamps are read with the stamp optional, using bracket character classes, not
  backslash escapes.** The pattern is handed to awk as a dynamic regex as well as to grep. Escaped
  brackets are stripped back by awk and the stamp group silently stops matching, which makes
  compaction fold the whole conversation in one pass instead of the oldest half.
- **Compaction takes the lock twice and drops the oldest lines on the second pass**, rather than
  swapping in a file captured before the model call. Appends only ever go to the end, so those first
  lines are still the block that was summarised, and turns that landed meanwhile survive.
- **The registry and the journal are both needed and they fail differently.** The registry alone
  lets a session conclude no work is in progress moments after an earlier session finished the work
  and exited.
- **Registry entries carry the pid and its process start time**, so a recycled pid cannot keep a
  dead session looking alive.
- **Regrouping is evidence, not a mute.** A session that starts while another of her voices has the
  floor is shown what is being said and asked to fold both into one reply. Nothing reads that record
  to decide whether a reply may be spoken.
- **"The user is busy" means the user, never another of her own sessions.** That test used to count
  her own voice, and it is exactly how a wake beside a desk reply lost its whole output.
- **The delivery queue is ordered, and supersession is the only thing that lets a turn skip the
  wait.** Ordering alone would have made 2026-08-10 worse, not better: the good reply was ready at
  12:32:39 and the stale one not until 12:33:36, so a strict queue would have delayed the answer he
  needed by another minute to preserve the order of one he had already thrown away. The two rules
  only work as a pair — earlier replies go first, and a reply he has already rejected is not an
  earlier reply, it is one that is never going out.
- **The delivery queue lives under `$STATE_PREFIX`, so a reboot empties it.** A ticket that outlived
  its process would be an earlier turn every later reply waits on, and the wait bound would become
  the floor on every answer.
- **The ticket carries the process start time as well as the pid.** A recycled pid keeps a dead
  turn looking like one still owed an answer, exactly as it does in the session registry.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `H3` / `RC-1` | The interactive and phone generation path has no stall watchdog while the wake path does. The desk turn's only bound sits downstream of an unbounded loop. |
| `H3` / `RC-4` | Nothing the turn writes records that the chain was walked. The session outcome records only what was asked and replied. |
| `MAJ-10` | Compaction can overwrite the summary with a refusal and drop the folded blocks permanently. The limit signature is never applied to a zero-exit run. |
| `MAJ-31` | The conversation block is bounded in turn count only, never in bytes. Archives have been measured at 29,936 bytes. |
| `MIN-2` | The recorder pid file is read by the library but defined only in the entry script, so anything else sourcing the library gets an unset variable. |
| `MIN-13` | The no-reply branch never waits for the streamer or verifies the receipt, orphaning the streamer and leaving stale receipt files a recycled pid can misread as this turn's evidence. |
| `MIN-17` | The overlap collapser can swallow a genuinely repeated phrase; it tolerates a quarter of the words mismatching and caps its hypothesis at thirty words. |
| Recommendation §4.2 | The "Thinking" notification is dismissed only after generation returns, so a stalled turn leaves it stuck on screen. |
| Recommendation §4.6 | Detached children do not inherit the current login, so they always fire at the ambient account and fail quietly. |
| Rule 15b, speech half | Ordering covers DELIVERY — the conversation, the journal, the window, the notification, the phone's audio. It does not cover the desk streamer, which speaks as the model writes, so two ordinary questions can still be answered aloud in the order they finished rather than the order they were asked. The case that mattered is closed by rule 15e: a rejected theory is silenced the instant he rejects it, and whatever was already out of her mouth was said before his message existed. Two ordinary answers heard out of order are both still wanted, which is why this is a defect and not a fire. Closing it means holding a non-head turn's streamer until it reaches the head — `claim_debuglog` split from `start_tts_streamer`, the streamer started late, safe only because it tails from the top of the file. |
| Rule 15f, phone playback half | A cut phone turn is closed above every delivery sink, its run aborted, so nothing NEW of it is synthesised — but a clip already handed to the handset keeps playing, and the phone's live sentence-stream voice ([phone.md](phone.md) rule 17) does not read the cut marker mid-clip. Closing it means a stop signal on the watch channel the client honours at once, aimed by the cut turn's identity. |

## TESTS

**Existing:** `tests/test_convo_compaction.sh`, `tests/test_convo_stamps.sh`,
`tests/test_regroup.sh`, `tests/test_silent_wake.sh`, `tests/test_turn_reinforce.sh`,
`tests/test_no_project_memory.sh`.

`tests/test_turn_order.sh` — rules 15a-15e: a slow first turn and a fast second one deliver in
arrival order; a pushback message supersedes the turn in flight behind it, whose reply is written
to the transcript marked unsaid, journalled in full, and never spoken; nothing waits on a
superseded ticket; a ticket whose process is gone is swept rather than waited on; the bound expires
and the outcome says so; `TURN_ORDER_WAIT=0` restores the old behaviour exactly. The suite runs
with `TURN_INTERRUPT=0`: it pins the BACKSTOP — under the shipped default an ordinary second
utterance cuts the first turn instead of queueing behind it (rule 15f), which is
`tests/test_turn_interrupt.sh`'s subject.

`tests/test_turn_interrupt.sh` — rule 15f: a second utterance mid-flight silences the in-flight
reply at the interrupt point (nothing past the cut is voiced — the streamer reopens no
synthesiser for what the un-aborted run would have kept writing) and aborts its run, so exactly
one model run completes; the surviving turn's prompt carries the cut turn's input, its
part-written reply, and the interrupt frame; the cut turn delivers nothing — no conversation
block and no held block, its outcome naming the cutting message and keeping the part-written
words — the queue is left empty and no third run happens; `TURN_INTERRUPT=0` restores the pure
queue, STRONG pushback still supersedes rather than cuts, and neither a cut turn nor anything
behind a cut ticket waits.

`tests/test_undelivered_reply.sh` — rule 16a: a turn killed mid-generation whose stream log holds a
finished reply journals that reply with the undelivered outcome; killed with nothing in the log, it
journals the interrupted outcome; a turn that delivered normally is untouched; the empty-reply,
no-outcome row of 2026-08-10 is unreachable.

`tests/test_promise_check.sh` — rules 32a-32d and [nightly.md](nightly.md) rules 51-53: a reply
with a commitment whose work is absent lands on the ledger and books the opus-low wake with the
promise quoted verbatim; a commitment the tool record shows performed books nothing; a reply with
no commitment never reaches the model (the pre-check's gate is proven from the CLI witness log); a
missing stream snapshot judges nothing; the auditor's deferred wake and the per-promise rebook
bound each stop a duplicate booking; the sweep hands the model the whole day and its reconciling
evidence — the day's named files statted from disk and the resident player's game outcomes riding
as labelled sections ([nightly.md](nightly.md) rule 52a) — surfaces an end-of-day miss as an
identified ledger record ([nightly.md](nightly.md) rules 53, 53f) and one morning wake, and a
clean day books nothing. Rule 32e by observation: a real desk turn and a real phone turn each journal an
outcome carrying the turn's own tool trace (or the explicit no-tools record), and the sweep is
handed a desk claim's refuting trace and a desk claim's fulfilling trace alike — the traceless
claim surfaces, the traced one is dropped.

`tests/test_empty_delivery.sh` — rule 16b on the desk and phone paths, and
[speech-output.md](speech-output.md) rule 57: a marker-only reply reaches no speaker, no window,
no conversation block and no phone payload half, and is journalled as the no-text failure; a
"(quiet) thought" desk reply is a bubble — marker normalised, never voiced, the guarantee silent;
the same phone reply completes with the bubble as its spoken text, no clip and no error; a plain
reply delivers exactly as before.

`tests/test_chore_gate.sh` — rule 16c and [engineering-records.md](engineering-records.md) rules
15–15c: a display half assigning the user a command — the clear "you'll need to run" shape, the
run-this lead-in over a fenced command, and the ambiguous "Also unset: TIDY_CLAIMS_ROOTS" line —
dispatches exactly one job whose brief carries the chore lines, and the forbidden instruction is
absent from the display half, the conversation form, and a real desk turn's display window;
benign mentions (first- and third-person narration, a named command, a statement of fact) pass
byte-identical with nothing dispatched; two chore blocks in one reply are one job; the spoken
half is untouched; a refused dispatch fails open with the reply as written and the trace naming
why; and `CHORE_GATE=0` switches the gate off whole.

**To be written:**

- `tests/test_capture.sh` — the whole input half, with the transcriber and the recorder stubbed:
  the settle poll and its bound, the fixes, the empty-capture exit, the leading-dash rejection, the
  repeated-phrase case for the overlap collapser.
- `tests/test_turn_delivery.sh` — the three delivery branches (reply, no reply, every account
  refused), each asserting what was spoken, what entered the conversation, what was journaled, and
  that the notification was dismissed.
- `tests/test_convo_compaction.sh` — extend with a refusal-shaped summariser reply and assert the
  summary is unchanged and the blocks survive (`MAJ-10`), and with a byte cap case (`MAJ-31`).
- `tests/test_child_env.sh` — every detached child inherits every instance redirect and the current
  login.
