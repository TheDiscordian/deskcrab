# Engineering history

This file is the memory of how the system got its rules: the dated incidents, the measurements, and
the reasoning behind decisions that look arbitrary from the outside. It is not the contract.

**The contract lives in [`specs/`](../specs/README.md).** A spec dictates behaviour; the code and the
tests conform to it. If this file and a spec disagree about what the system does, the spec is right
and this file is a record of what someone believed on a particular day.

Read it when you are about to remove something odd-looking, or when a fix has a shape you cannot
explain. Almost every strange mechanism here is a scar. Entries are grouped by subsystem and dated
where the original journal gave a date.

---

## Prompt and context

### 2026-08-29 — she accepted an invitation without joining it

A phone turn answered a present-tense invitation to play RuneScape with an enthusiastic yes, but
ran no tools and left the game unstarted. The next turn, after the user challenged the mismatch,
did invoke the player and verify the session. This was not a transport or game-engine failure: the
standing frame said that a pure question only asks for an answer, while its action rule covered
imperatives and explicit requests. An invitation phrased as a question fell cleanly through that
gap.

The frame now keeps the choice intact but makes acceptance consequential: she may say no, but if
she says yes to a safe present-tense activity she can perform, she starts or joins it and verifies
that it is underway before replying. The OpenRSC drawer also names the idempotent play command, so
an accepted game invitation does not spend a turn discovering the launcher before acting.

### The prompt used to have no per-path shape

There was one prompt for every path, so a shelf-check wake paid the same prompt as a spoken turn.
The rebuild put in ONE assembler with four profiles (`--profile turn|wake|job|classify`), one layer
order, a byte budget per layer, and the user's own message delivered as the CLI's positional prompt
rather than buried in the middle of the system prompt.

Two layers are never cut and report `over` instead of trimming: **L2**, which another spec mandates
verbatim, and **L5** `WHERE THINGS ARE`, where a trim is a drawer she cannot open. **L4 sizes
conduct first and gives the shelf what is left**, because a want is chosen and a rule is owed. **L1
fits the persona sheet by whole markdown sections** and names the ones it left behind.

Contract: [`specs/prompt-assembly.md`](../specs/prompt-assembly.md).

### 2026-08-07 — every path booted the same desktop

Measured: 40,229 tokens of harness before a word of hers, on every path including one-question
classifiers.

**`--tools` without `--strict-mcp-config` is a trap that nearly triples the context.** It removes
`ToolSearch`, so every deferred MCP schema is inlined instead — 116,735 tokens measured. That is why
the flags are built in one function (`claude_profile_flags`) and never spelled out at a call site.

`--bare` cannot be used on any path: it refuses OAuth, and the whole account chain is OAuth.

Measured end to end on 2026-08-07, sonnet, her real prompt shapes:

| Path | Tokens |
|---|---|
| turn | 22,374 |
| wake | 20,899 |
| classify | 200 |

Skills are one flag away (`CLAUDE_SKILLS=1`, about 6,700 tokens). The one skill she used was
`/screenshot`, and L1 carries the `grim` line instead. Full method and matrix:
[`tools/context-probe-results.md`](../tools/context-probe-results.md) — every number is
CLI-version-specific and must be re-measured after an upgrade.

### The coding agent's memory was arriving in her prompt

`claude` reads `$HOME/.claude/projects/<cwd-slug>/memory/MEMORY.md` straight into the system prompt
of any session started in that directory, and `PROJECT_DIR` is the user's own coding project. So
every desk turn, phone turn, and wake arrived carrying his coding agent's topic-hub index and
standing instructions addressed to a different assistant entirely. Her memory is the vector store;
that one is his.

The fix is the env prefix `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` on every invocation that is HERS —
`claude_generate`, `_wake_claude_run`, `claude_classify`, `lib/promise-audit`, and `memory.py`'s
`run_claude`. Verified against claude 2.1.224: the gate reads the environment variable ahead of the
`autoMemoryEnabled` setting, so it is a per-invocation answer.

Deliberately per-invocation, never exported and never a settings.json key:

- a settings key would blind the user's own coding sessions in the same directory;
- an export would reach `lib/job-runner`, whose detached builder works inside a project and is
  exactly the session that SHOULD arrive knowing the project's rules.

A classifier goes further and runs from `claude_sterile_cwd`, a directory with nothing in it:
auto-memory is only half of what a cwd costs, and the other half is the project's own `CLAUDE.md`,
which the CLI discovers from the directory it is standing in.

---

## Wakes: the queue

### Transient timers do not survive a reboot

A transient timer lives only inside the running user manager — a reboot or logout erases it with no
trace, silently breaking any promise the assistant made itself for later.

So `wake-at` writes a booking record to `~/.local/share/deskcrab/wakes/<unit>.wake` *before* booking
the timer. That order is on purpose: a crash between the two leaves a record the reconciler honours,
not an unremembered timer. The unit id is passed into the fired wake so it retires its own record
first thing — before any early exit, or restore would resurrect a wake that already ran.

### 2026-08-07 — a cancelled backlog came back verbatim

A backlog called off with `systemctl stop` reappeared verbatim an hour later. Stopping just the
timer leaves the record, and restore brings it back. `crab wake-cancel <unit>` — or `--all` for the
whole queue — is the only real cancellation.

### Calendar specs made accidental daily repeats

Every booking is now made as a *delay* rather than by passing the spec through to systemd. A bare
calendar spec like `09:45` used to make a transient timer that came back every morning while the
record covered only the next firing — so the repetition was accidental, invisible to the reconciler,
and left ghost timers `crab status` could not explain. A wake-at is one-shot, and now it is one-shot
in systemd too.

### The report read systemd instead of the records

`wake_list` enumerates the RECORDS and joins the timers onto them, never the reverse. The report
used to read systemd, which is how **25 bookings rendered as "(none scheduled)"**.

Readers tolerate the older three-field records, filling the missing fields with "unknown" rather
than shifting the ones that are there.

### Arity: an agenda in the kind column

Arity is normalised on write **and** on read. If the kind slot holds anything but `scheduled` /
`event` it is the reason, so a record whose agenda ended up in the kind column recovers it instead of
being blanked, and a wake with no kind is deferred rather than dropped.

### 2026-08-07 — the convoy at 12:09:15

Only one wake runs at a time, so a wake that finds the wake lock held pushes itself back — and that
push-back used to be a **flat 15 minutes**. Three wakes blocked inside the same minute therefore
re-armed to the same *second*, one took the lock, and the other two were blocked again and marched
on together. `crab status` showed three timers at 12:09:15 with sequential ids (132082/132083/132084)
and it was read as a scheduling loop. It was a convoy with no spacing.

**Every** booking now asks `wake_free_slot` for a moment no pending booking already holds
(`WAKE_DEFER_DELAY` 900 s base, stepped by `WAKE_SLOT_SPREAD` 180 s): the blocked-wake retry in
`crab wake`, the 30-minute retry after an API-level stream failure, and `crab wake-at` itself.

Spacing the *retries* alone was measurably not enough: within a minute of that fix, two concurrent
sessions booking different wakes had rebuilt the collision from the front, both landing on 13:05:54.
A nudge of a few minutes costs a promise to herself nothing; landing on another wake's second costs
it a quarter of an hour.

### Six wakes for one promise

`crab wake-at` refuses to stack near-duplicate timers: a scheduled-kind booking with the same reason
firing within `WAKE_COALESCE_WINDOW` (default 15 min) of a pending one is not added
(`wake_pending_equivalent`). Six sessions each promising "come back in 45min" used to produce six
wakes minutes apart, each re-announcing the same progress.

Coalescing covers **event** wakes too, but only against a byte-identical reason — two different
events are two wakes, while the same event re-booked by its own deferral is one.

### RuntimeMaxSec was being ignored

Transient units are booked `--collect` with `-p TimeoutStartSec=$WAKE_RUNTIME_MAX` (7200 s) — **not**
`RuntimeMaxSec`, which systemd ignores on the `Type=oneshot` service `systemd-run` creates and has
been logging as ignored for as long as the ceiling existed. The standing units in `systemd/` were
fixed the same way.

### The floor booking, and how one wake ended the chain

`ensure_next_wake` runs at the end of every autonomous wake: if no *scheduled-kind* wake is pending —
judged from the durable booking records, not from `systemctl` — it books one (`ENSURE_WAKE_DELAY`,
default 45 min).

Only a wake that will come back to the wants counts. An event wake is pending for its event, and the
old any-`deskcrab-wake-*`-timer check let one unrelated long-dated booking suppress every floor
booking and end the chain. Wants only advance when something wakes her to advance them, so a wake
that forgets to schedule its follow-up silently ends the chain — the intent stays in the wants file
with nothing ever returning to it.

This is a floor, not a schedule: a wake that booked its own follow-up is left alone. `ensure_next_wake`
also runs `wake_restore` first, so a booking whose timer died with a past user manager is healed at
every wake exit and not only at login, and then `wake_tidy`.

### "Already fired" is the load-bearing safety rule of tidy

`wake_tidy` purges transient timers that have **already fired** and have no booking record — a
one-shot unit stays loaded after firing, and a bare calendar spec even re-arms for tomorrow with its
record long retired.

`LastTriggerUSec` empty means never fired, and a never-fired record-less timer is a pending wake
whose record some other hand removed, not a ghost. Killing it would cancel a wake nobody asked to
cancel. A unit whose `.service` is active is skipped everywhere, because that is a wake firing right
now which cleared its own record first thing.

### A wake during a conversation used to do nothing at all

An active interaction (recording, speech, someone on the mic) does **not** defer the session. It used
to, which meant a wake during any conversation did no reading, no want work, and no dated thought,
and reached the user as an indistinguishable silent wake.

The session now runs regardless; the `user_busy` re-check in `run_claude_wake`'s speak decision
suppresses output — speech, display, phone — and journals what it swallowed via `session_outcome`.

`user_busy` means the USER is mid-something (recording, a meeting on the mic), never that another of
her own sessions is speaking. That test used to live there and is exactly how a wake beside a desk
reply lost its whole output; overlapping voices are handled by regrouping and the speech mutex
instead. It also reads `$PIDFILE` (`DESKCRAB_PIDFILE` or `/tmp/deskcrab.pid`), overridable so a
scratch instance is not told the user is busy by the live desk's recording.

### One module owns the queue

`lib/wake-queue.sh`, sourced by `common.sh`: `wake_list` / `wake_book` / `wake_cancel` /
`wake_restore` / `wake_tidy`. Nothing outside it reads `$WAKES_DIR`, mints a unit name, or calls
`systemd-run` for a wake.

Six subsystems book wakes in her name — `promise-audit`, `job-runner`, `notice-selfchange`,
`notice-newfiles`, `canary` and `wake-chain-floor` — and each stamps its own `booked_by`. Two more
identities reach a record without being subsystems: `outage-retry`, when a wake that failed before
the model ran re-books itself, and `herself`, the default when nobody says. Six hands and eight
names: specs/wake-queue.md rule 41 requires any prose that enumerates them to name the whole set,
and this paragraph said four of each. The name on the record is `canary`, not
`canary-selfchange` — that is the unit's name, not the booker's. The promise auditor's cap is
counted from the records under the booking lock and **drains** the excess as well as gating new
bookings.

Every booking, cancellation, restoration, collapse and purge is appended to `wakes/ledger.log`, which
the state block reads. `wake_restore`'s output is no longer sent to `/dev/null`.

A run whose `WAKES_DIR` is not the live one does not arm anything at all — the fourth test-harness
gate, matching `job-runner`'s existing jobs-dir guard. The record is written, no unit is created, and
a harness that has stubbed `systemd-run` opts in with `DESKCRAB_ALLOW_SCRATCH_BOOKING=1`.

### 2026-08-27 — an appointment to be spontaneous is still an appointment

The evening before, a single 23:20 wake stood on the queue with a reason telling her to develop a
want at that hour. The user's correction: spontaneity cannot be booked, and one firing cannot make
wants develop — her own time has to arise from idleness, not appointed wants. The standing
reason-less return (the chain floor, the background timer) became the mechanism instead of a new
alarm: at fire time it measures genuine idleness mechanically — conversation recency, delivery-queue
tickets, the microphone, running builders — and only a quiet house runs the choosing session, on
sol at medium. Activity defers the return through the queue's own door, with conversation RESETTING
the quiet window rather than merely postponing the wake, and the floor's delay carries a jitter so
recurring opportunities never harden into a clock ritual. The choosing agenda is an open field —
continue, discover, practise, make, observe, speak, or do nothing, with doing nothing named as a
real choice — and it prescribes no shelf title, because the earlier work-order agenda ("pick at
most ONE want") was itself a small appointment. Repairs and owed engineering stay with the night's
builders. The deliberate exception to rule 20 (an active interaction never defers a session) is
carved for exactly this one wake class: its whole premise is the idleness, so a deferral loses no
reading and no dated thought. Contract: rules 40a-40f.

Contract: [`specs/wake-queue.md`](../specs/wake-queue.md).

---

## Wakes: speech and silence

### Regrouping replaced the echo window

The answer to "another of me is already speaking" is not a queue and not a mute. It is what a person
does with two things to say at once: they stop, fold both into one sentence, and say that.

So every voice publishes what it is saying while it says it, and every session that starts while that
record is live gets `regroup_context` spliced into its prompt: the other reply VERBATIM, plus
instructions to compose ONE reply covering both, never to queue the second thought for later, never
to default to silence, never to restate. Silence stays available for genuinely having nothing to add.

- The desk streamer rewrites `${STATE_PREFIX}-live-speech` on each utterance and clears it at the
  result event; `speak_once` writes it inside the speech mutex; the phone paths write it with an
  estimated end time, because handed-off audio has no pid to watch.
- Header line is `epoch \t device \t pid \t until`; text follows from line 2.
- Staleness is liveness, not just age. A speaker killed mid-word (`crab shutup`) leaves a record
  whose pid is dead, and a session never regroups against its own turn's voice (pid == `$$` or
  `_TTS_STREAMER_PID`).
- **The record is a NOTICE, never a gate.** Nothing reads it to decide whether a reply may be spoken,
  only to decide what the next reply should SAY.

Two consequences elsewhere: `user_busy` no longer counts another of her own voices as the user being
busy (that test, `speech_busy`, is what made the second thing never get said at all — it is now a
diagnostic probe wired to nothing), and the speech mutex stays, doing only what it should: keeping
two voices off the speakers at the same instant, dropping nothing.

A wake beside an interactive turn gets **evidence, not a mute**. Every desk/phone turn records its
exchange in `${STATE_PREFIX}-live-turn`, and a wake whose prompt is built within
`WAKE_TURN_CONTEXT_WINDOW` (default 300 s) of that record has the exchange spliced in
(`wake_concurrent_turn_context`) with instructions to REGROUP. That block used to say "say nothing"
by default; silence-as-default is the design that was rejected.

This replaced the echo window (`wake_in_echo_window` / `WAKE_MUTE_AFTER_TURN`), which muted the
wake's spoken reply wholesale. The user rejected suppression — the wake decides for itself, with the
facts.

### 2026-08-07 — the post-hoc overlap mute was removed

The **nothing-new check** (`wake_says_nothing_new`) was a post-hoc mute that compared a wake's reply
against recent assistant messages and swallowed it on 60 % or more word overlap. It was removed on
the user's instruction (conduct rule "no gate on my own tongue").

The principle stated at the time: no mechanism judges a written reply after the fact and decides it
is not worth voicing; silence is chosen while writing or not at all.

> **This no longer describes the code as shipped.** The same commit that removed the overlap mute
> introduced a narrow replacement, `wake_reply_is_filler`, which mutes a reply whose entire content
> is an announcement of silence ("Nothing to say.", "No message."). It is deliberately narrow and
> falls through to speech on any ambiguity, but it is still a post-hoc gate — now authorized in the
> contract as [`specs/wake-queue.md`](../specs/wake-queue.md) rule 29a.
> [`specs/speech-output.md`](../specs/speech-output.md) records `MAJ-3` — called once, after the
> reply exists, while the streamer has been speaking for minutes — and `MAJ-4`, the single-clause
> match, closed 2026-08-10 (below). See [`tests/test_wake_filler.sh`](../tests/test_wake_filler.sh).

### 2026-08-10 — the announcement of silence learned to bring an excuse

"No message — the other session already said its piece." — spoken aloud at the desk, from an
autonomous wake, more than once. The single-clause filler gate knew "No message." and let the
two-clause form through on the excuse: the justification clause was outside every pattern, so the
whole line reached the synthesiser. The user called it what it is — meta-narration where silence
was asked for; a wake with nothing to say must produce NO spoken output, never a sentence
explaining that there is nothing to say.

Three moves, one shape (`specs/wake-queue.md` rule 29a):

- `wake_reply_is_filler` now matches the no-op core with a **silence-justification clause** on
  either side — the other session already said/covered/answered it, nothing has changed, he already
  heard it — and the justification standing alone as the whole reply. The clause families are
  anchored whole, with closed object sets, so a justification-shaped opening followed by real
  content ("The other session said the tests were green, but they are not") still speaks. The muted
  words still ride the journal line, as they always have.
- The wake agenda and all three concurrent-session blocks (`wake_concurrent_turn_context`, both
  branches, and `_regroup_block`) now state the empty reply as the **default** when another session
  already covered it or nothing has changed, and name the reason-bearing form as the failure — the
  gate is the backstop, the prompt is the instruction.
- `tests/test_wake_filler.sh` holds all of it: the two-clause corpus, the justification-alone
  corpus, the real-content counter-corpus, the exact reported sentence through the real wake path,
  the silent exit (an empty reply delivers nothing and journals as silence), and the prompt
  wording in the agenda and all three blocks.

### An API failure was spoken aloud in her own voice

A failed CLI run is not a reply. API-level failures (session limit, auth, network) arrive *shaped
like one*: a synthetic assistant message (`"model":"<synthetic>"`, `is_api_error_message`) plus an
`is_error` result whose text is the error, which `extract_response` cannot tell from real speech. One
night the desk spoke "You've hit your session limit" aloud and the sentence landed in the
conversation as the assistant's own words.

`wake_stream_failed` detects a stream holding an error and no genuine model output. `run_claude_wake`
then journals the failure (with the CLI exit code and error text), appends nothing to the
conversation, skips the promise audit and all speech/display, and re-books a kinded wake 30 min out
so an event's agenda survives the outage.

A wake that produced no output at all is journaled too — an empty reply on a clean exit is silence,
not a crash (only a non-zero exit journals `(wake produced no output)`), so "(no summary recorded)"
no longer hides a death.

### 2026-08-06 — the silence marker was spoken aloud

The old `(quiet)` prefix convention was retired because `extract_response` joins every assistant text
block: mid-turn narration buried the marker behind it, the prefix match failed, and the whole private
note was spoken aloud verbatim — "quiet checked wants slash sheet-music dot md".

> **Reversed the next day.** On 2026-08-07 the user reinstated `(quiet)` as the ONE authorized
> silence format: a wake with something worth leaving but not worth voicing writes
> `(quiet) <thoughts>`, and the thoughts are SHOWN to him as a `(quiet) …` bubble, never spoken.
> Hiding it is forbidden. The wake prompt in `crab` authors the marker and the gate in
> `run_claude_wake` handles it; `spoken_part` strips it so no path can voice it, and a stray
> square-bracket spelling is normalised to the same thing.
>
> [`specs/wake-queue.md`](../specs/wake-queue.md) and
> [`specs/speech-output.md`](../specs/speech-output.md) still say "Silence is an empty reply, never a
> marker. No prompt authors a silence marker." **The specs are behind the code here.** Reconcile
> them before writing anything that depends on either statement.

### Silence is a speech decision, not a work record

`wake_work_trace` parses the stream's tool calls mechanically — files written via Write/Edit and
shell redirections, `crab job` dispatches, command count — and the silent journal line becomes
`(silent — wrote …; dispatched N jobs; ran M commands)`. A wake that truly ran no tools journals
`(silent — ran no tools, touched nothing)`.

### 2026-08-07 — two ways a wake reached him as "she answered me with nothing"

**(1) The conversation was appended before the gates ran.** `run_claude_wake` appended its reply to
the conversation the instant the reply existed — *before* any suppression gate — and the phone
follows the conversation file (`serve.py` `/watch`). So a wake muted for quiet hours, for the user
being mid-interaction, or for having nothing sayable still posted its monologue into his chat as a
bubble he had not asked for and could not answer. "Suppressed" meant suppressed on the speakers only.

The append (marker + `convo_append_assistant` + `compact_convo`) now happens at the very END of the
delivery section, past every gate, immediately before the voice. A wake that is not delivered leaves
the conversation exactly as it found it, and its words survive in the session journal
(`session_outcome`), which is where a wake nobody heard has always belonged.

**(2) The stream log was one shared file.** A desk turn starting mid-wake truncated the wake's output
— one archived stream from that hour is 18 bytes, nothing but the terminator. A wake starting
mid-desk-turn wiped the DESK's reply before `extract_response` read it, and he got dead air for a
question he had asked out loud. Whichever read the file second read BOTH streams: four times in
twenty minutes the wake journal records the desk turn's reply verbatim as its own. `DEBUGLOG` is now
one file per session.

**Downstream of both, emptiness is now inert everywhere rather than described:**

- `extract-response` prints nothing at all for an empty stream (not a blank line) and no longer leads
  with a blank line when the spoken half is empty;
- `serve.py`'s `read_turns` drops blocks with no text and no display, so the `/watch` cursor counts
  only what the page will draw;
- the client skips empty turns in both the seed and `renderRemote`, removes an empty reply bubble
  instead of printing `(no reply)` into it, and appends a stream error *beside* a reply that already
  arrived rather than overwriting it.

A turn HE asked for is the one case where nothing is not an answer: the desk journals and notifies
(never speaks — an error read aloud in her own voice is how "You've hit your session limit" once
reached his ears as her words) and `crab remote` returns an `error` field instead of an empty
`spoken`.

---

## Speech, display, and the never-silent guarantee

TTS streams in parallel with generation — speech starts before the full response is ready. The
display delimiter is `---DISPLAY---` on its own line, and the streamer strips markdown (bold, code)
before speaking.

Contract: [`specs/speech-output.md`](../specs/speech-output.md). Its standing rule is the one to
carry forward: **nothing in this subsystem may swallow, clip, budget, or gate her speech.** A filter
that decides her words are not worth voicing has been built twice and removed twice.

---

## The conversation store

### Concurrent writers

Every writer of the conversation file — desktop turn, remote turn, autonomous wake, compaction,
rotation — goes through `convo_append` and the `$CONVOLOCK` flock. More than one client can be
mid-turn at once, and an append landing inside compaction's summarize-and-swap would otherwise
vanish.

### Block headers carry the local time

`User [2026-08-07 12:01]: …` / `Assistant [2026-08-07 12:03]: …`, because a flat transcript reads the
same whether a thing was said thirty seconds or six hours ago, and "you said that a minute ago" then
has nothing to check itself against.

- `convo_append_user` / `convo_append_assistant` are the only two writers, so the stamp cannot be
  applied on one path and forgotten on another. Nothing else may append a block.
- Every READER matches the stamp as **optional** (`CONVO_USER_RE` / `CONVO_ASSISTANT_RE` /
  `CONVO_BLOCK_RE`, usable as `grep -E` and as an awk dynamic regex; the same shape in `serve.py`'s
  `BLOCK_HDR` and in `crab-debug`). Every conversation already on disk and every archive is
  unstamped, and a pattern that silently stops matching those loses turns without ever erroring.
- Compaction must therefore fold the identical excerpt whether or not the file is stamped.
- The condensed half keeps a clock of its own: `convo_time_range` reads the span out of the excerpt
  being folded away and the summariser is told to open with it — and to say the span is unknown
  rather than invent one for an unstamped excerpt — or the summary would date everything from the
  last hour and nothing before it.
- On the phone the stamp is metadata, not speech: it rides beside the bubble as `time`, never inside
  its text.

Contract: [`specs/turn-pipeline.md`](../specs/turn-pipeline.md).

---

## Self-awareness: the state block

### Two halves, and they fail differently

A **live registry** under `$SESSIONS_DIR` answers "who is running right now"; an append-only
**journal** at `$SESSIONS_LOG` answers "what finished while I was not looking". Both halves are
needed. The registry alone still lets a session conclude "no work is in progress" moments after an
earlier session finished the work and exited, which is the exact failure it was built to stop.

Registry entries carry the pid *and* its `/proc` start time, so a recycled pid cannot keep a dead
session looking alive. A session killed with SIGKILL never runs its trap, so `session_reap` journals
it as interrupted rather than letting it vanish. Sessions record their own one-line outcome with
`session_outcome`; for a silent wake that line is the only trace it ever leaves, which is why the
silent path fills it from `wake_work_trace` rather than from the reply.

### Two audiences, two reports

`self_state_report` bare is the `crab status` dashboard: every live session, every job including
finished and failed ones, every pending **record**, twelve hours of finished sessions in full.

`--prompt` is the CURRENT STATE OF YOURSELF block, and it is the near view only — live sessions, jobs
*running now*, pending wakes inside `WAKES_HORIZON_HOURS` (12) capped at `WAKES_SHOW` (5) with a
`+N further out` count, the interrupted section only when there is something in it, and
`Recently finished` reaching back `SESSIONS_RECENT_MINUTES` (30) at `SESSIONS_RECENT_SHOW` (4)
entries trimmed to one line each.

**History under a heading that says "right now" reads as live work.** A build that died at 02:06 sat
in the block all day beside four running jobs, and twelve hours of full turn text cost more of the
block than everything live put together (6415 chars → 1808).

### The recent window is measured to the END of a session

The journal's first field is the start, so a plain cut on it drops a forty-minute wake that finished
five minutes ago — the longest work of the half hour, and the entry most worth having.
`session_history --recent` therefore adds the duration back on (gawk `mktime`, with the string
compare as the fallback for an unparseable stamp). The twelve-hour dashboard view keeps the cheap
string compare, where the distinction buys nothing.

Thirty minutes is deliberate and was the user's own correction to "remove it entirely" — the block
should match what she actually remembers of the conversation.

### News that nobody heard is news that is still owed

The one piece of history that survives into the prompt is a job that ended badly **since the last
turn**. `jobs_report --live` passes `--failed-since` to `lib/job-status`, which reports it as
`ENDED SINCE YOUR LAST TURN` and no more than three at once. The `${STATE_PREFIX}-jobs-surfaced`
stamp is what makes that once, and a missing stamp means "first render, nothing was missed" rather
than "dump the back catalogue".

The prompt copy renders with `--defer`, so the stamp lands in
`${STATE_PREFIX}-jobs-surfaced.pending-$$` and is only promoted by `jobs_news_delivered` at the three
delivery points. Stamping it on every render let a wake that ended in silence consume news the next
audible session then never saw.

### Every list leads with its total

`Pending wakes (next 12h): 25 total, 5 shown` — because five bullets with an unstated total of
twenty-five is a false report. An empty list states zero as a measurement rather than as a claim
about the world. A record with no live timer renders as its own line saying so, and a timer with no
record likewise. Each wake shows who booked it, and the injected block names the four autonomous
bookers, so "nothing scheduled by me" stops being defensible.

The negative claim is stated as arithmetic beside the counts — you may not say nothing is running or
nothing is scheduled unless both counts read zero — never as a check to go and run, and never as a
filter over a written reply. That is forbidden by conduct and is not the fix.

The block also carries a **since-your-last-reply** line anchored to the previous session's *finish*
rather than a fixed window a fast exchange fills entirely (wakes fired, wakes booked and by whom,
jobs dispatched, jobs that ended badly, queue changes from the ledger, whether the account chain
walked), and the **account line** — `account_state_line`, shared verbatim with `crab status`, which
used to be the only place it existed.

### Claims are advisory on purpose

`crab claim "<what>"` / `crab unclaim`, shown as `holding:` under each live session in `crab status`.
The registry *reports*, it does not *claim* — knowing another session is alive is not the same as
knowing it has the same file open.

A real lock held by a session that dies mid-edit wedges every later one, and a hand that cannot start
is worse than two hands that can see each other. `crab claim` prints every other live session's claim
and shouts `CONFLICT` when a significant token is shared. The claim is a sidecar `<pid>.claim` beside
the registration, so it is cleaned up by both `session_finish` and `session_reap`.

### Mid-turn checkpoints

The registry and journal only speak at session boundaries, so a turn cut off mid-work (network drop,
SIGKILL) used to leave edits on disk with no explanation.

`crab checkpoint "<intent / files / done / next>"` records *during* the turn in an append-only sidecar
`<pid>.ckpt` — each line one `O_APPEND` write, so a hard kill leaves every earlier line intact. A
clean finish deletes the sidecar; `session_reap` moves a killed session's checkpoints to
`${STATE_PREFIX}-interrupted/`, where `crab status` raises them under "Interrupted mid-work" until the
next hand picks the work up and clears the trace with `crab resolve <name>` (auto-pruned after
`CKPT_KEEP_DAYS`, default 7).

**Any loop over `$SESSIONS_DIR` must skip `*.claim` and `*.ckpt`.**

Contract: [`specs/self-awareness.md`](../specs/self-awareness.md).

---

## Detached jobs

`crab job [-C <dir>] "<description>"` / `crab jobs` / `crab job log <id>` / `crab job requeue <id>`
— work that must survive the end of the turn that launched it. Requeue re-dispatches a recorded job
from its own sidecar (description and workdir come off the record), added 2026-08-11 after a
re-dispatch loop typed `.task` where the sidecar's field is `.description` and dispatched three
builders on jq's literal answer "null".

A subagent dies with its turn, and while it runs it holds the turn open so the user cannot
push-to-talk. Both wrong, so background work is never a subagent. A job is dispatched via
`systemd-run --user --collect --unit=deskcrab-job-<id>` (setsid fallback when there is no user
manager) and runs `lib/job-runner` → headless `claude -p` with `JOB_MODEL`/`JOB_EFFORT` (default
fable/high — unattended builds, nobody waiting).

Output goes to `$JOBS_DIR/<id>.log`; state lives in a JSON sidecar kept by `lib/job-status`
(running/finished/failed/stopped/died/blocked — `report` reaps a SIGKILLed worker by unit-activity
plus pid-start-time, so nothing claims "running" forever).

### A job that never began is `blocked`, not `failed`

When the run exits non-zero having produced only the CLI's own refusal (`job_output_blocked` — out of
credits, usage limit, balance too low), no work was attempted and the log holds nothing to verify. So
the runner records `$JOBS_DIR/blocked` (`<epoch>\t<reason>`) and the completion wake says plainly
that the task is still undone, rather than sending the next wake to audit an empty log.

While that marker is younger than `JOB_BLOCK_RETRY` (default 1800 s) `job_start` refuses to dispatch
— the standing "dispatch a builder the turn you notice the work" policy otherwise fires builder after
builder into the same wall, one wasted wake per corpse. The marker expires on its own (nothing here
can see an account refill), so the first dispatch after the window *is* the retry probe; `crab job -f`
forces past it.

**A real build failure must never match the signature.** Misreading one as "never ran" would hide a
broken builder.

Jobs are **silent by contract**: no TTS, no notifications, no windows. On finish the worker fires one
event wake (only if `WANTS_FILE` is set) so the assistant hears the result and reads the log. The
running/finished list is spliced into the state block, so a later turn can report on work it neither
started nor waited for.

### 2026-08-26 — a builder settled its own ask on a narrowed substitute

The record `the-chess-table-maintains-a-second-conversation` asked for the chess table as a thin
client of the phone's VISIBLE conversation interface — the same conversation log UI. What was
delivered was shared audio plumbing: a clip-queue module both pages load. Real, tested, deployed —
and not the ask. The record was then SETTLED on it as "shared-primitive parity", by the same hands
that had built it, and the narrowing read as delivery until a hand went looking. The fix is the
completion review: a builder session (the runner exports `DESKCRAB_ENG_ROLE=builder`) is refused
`crab eng settle`; its completion claim goes through `crab eng review` into a `review` state the
prompt renders as live-and-unjudged; the completion wake of a submitted job IS the review, booked at
`JOB_REVIEW_EFFORT` (default medium), told to recover the original ask from the record's opening
entry and inspect the artefact itself; and `crab eng reject` preserves the missing requirements
verbatim onto a redispatched brief while `crab eng accept` settles with the verdict on `settled_by`.
Engineering-records rules 16–16d, jobs rules 29a–29b.

Contract: [`specs/jobs.md`](../specs/jobs.md).

---

## The phone and the server

### The phone is only a microphone, a speaker, and a screen

`crab serve` (HTTP front end) + `crab remote <text>` (one turn in, JSON out). The CLI, prompt, tools,
and conversation never leave this machine.

Uploaded clips go through **batch** `whisper-cli`, not `whisper-stream`: the clip is already
complete, so batch is both simpler and faster. Serving requires `SERVE_SECRET` and binds loopback;
exposing it (Tailscale, for the TLS a browser mic demands) is a separate, deliberate step.

`serve.py` is stdlib-only on purpose — no pip, no virtualenv to go stale. It must start on an offline
laptop.

### 2026-08-07 — the first exchange of every new conversation was never delivered

The phone follows the conversation by long-polling `/watch` with a cursor that is a POSITION in the
turn list — and compaction and archival rewrite that list, so a position alone lies across a rewrite.

The old handling snapped an over-long cursor down to the new total and waited, which silently
consumed every turn that rode in with the rewrite. Worst was the archive case: after 15 quiet minutes
the next exchange starts a fresh file, and the FIRST exchange of every new conversation landed behind
the snapped cursor, never delivered. On 2026-08-07 he refreshed the page three seconds after an
archive, and most of that day's dozen manual refreshes sit right after a rewrite in the serve log.

Every `/watch` and `/context` response now carries `gen`, the identity of this incarnation of the file
(hashed from the summary plus the first surviving turn, so appends never move it and every compaction
or archive does). A poll whose gen no longer matches is answered immediately with `reset: true` and
the whole current list, and the client redraws from a fresh `/context` exactly as a manual refresh
would — deferred while its own turn is in flight, since the redraw would wipe the exchange being
spoken. A shrink that regrows past the cursor before the next poll is caught the same way; by count
alone it would have been delivered as a slice of the wrong turns.

The client also guards each poll with a 45 s abort (the 25 s-or-less poll answer is the heartbeat; TCP
alone sits on a dead tailnet link for minutes) and retries with exponential backoff (1 s doubling to a
30 s cap, snapped back on success). A page too old to send `gen` keeps the snap behaviour.

### The server unit

A hand-started `crab serve` is a child of whatever shell launched it and dies with it — which is the
whole failure `systemd/deskcrab-serve.service` exists to prevent.

- The unit must set `PATH` itself. User units get a bare PATH, and the server shells out to `claude`,
  `ffmpeg`, `whisper-cli`, `piper` in `~/.local/bin`.
- `StartLimitIntervalSec=0` must stay. With the default rate limit a burst of failed binds (stray
  manual server on the port, boot race) leaves the unit *failed and not retrying*, which is the exact
  silence it exists to prevent.
- `KillMode=mixed` must stay — SIGTERM to the main python only. The default control-group mode kills
  the in-flight claude directly, drain or no drain.
- `TimeoutStopSec=660` gives room for the drain before systemd SIGKILLs.

Restarts are drained, never dropped: serve.py traps SIGTERM, refuses to *start* new turns (503 — the
client re-POSTs the same turn id with backoff, landing the turn on the fresh server) while still
serving re-attaches, waits for in-flight turns to finish (capped just past the 600 s turn timeout)
plus a short linger so attached tails flush the done event, then exits. `/health` gains a `draining`
field beside `busy`.

### Wake audio routing

A wake speaks wherever the user's attention is. Every interactive turn records its origin device in
`~/.local/share/deskcrab/last-origin` — durable on purpose, because "he last spoke from the phone"
survives a reboot and /tmp does not — and `serve.py` touches `${STATE_PREFIX}-phone-seen` on every
authenticated `/watch` poll. That is the same channel that would deliver the audio, so freshness means
delivery will actually happen.

When the last turn came from the phone AND that beacon is fresh (`PHONE_SEEN_WINDOW`, default 40 s),
`wake_speak_to_phone` synthesizes the reply to opus and writes a `${STATE_PREFIX}-wake-audio` pointer.
The `/watch` long-poll returns it early under its own `wakeseen` cursor (`/context` seeds the cursor so
a freshly loaded page never replays old audio) and the client plays it through the ordinary voice
queue. Anything short of both conditions falls back to `speak_once` at the desk.

### Web Push

`crab notify <text>` is the one channel that reaches the phone with the page CLOSED.

The page's bell button subscribes (permission prompt is gesture-gated; the page re-posts its
subscription on every load, so `/push/subscribe` must stay idempotent by endpoint). `crab notify`
encrypts per RFC 8291 (aes128gcm) and POSTs to each stored endpoint with a VAPID JWT, reporting
per-subscription results and pruning 404/410 on the spot.

Crypto lives in `lib/webpush.py`, verified against the RFC 8291 §5 test vector
(`python3 lib/webpush.py selftest`). It needs `cryptography`, which serve.py imports OPTIONALLY like
`markdown` — without it the `/push/*` routes answer 501 and nothing else is affected, so serve.py
stays stdlib-only.

VAPID keys and subscriptions live under `~/.local/share/deskcrab/webpush/`. The keypair is generated
once and never rotated; rotation orphans every subscription.

Contract: [`specs/phone.md`](../specs/phone.md).

---

## The chess bridge

### 2026-08-28 — the probe-based verdict rejected, and one call ate a won game's clock

The user rejected the settled 2026-08-27 benchmark the night after its review was accepted, on
two grounds that were both true: fable — the model his own knob points every real game at —
received only counted probe calls, never a full game, and the matrix sampled five of the
supported model-and-effort pairs rather than all of them. A verdict built on probes for the
model real games actually use cannot choose a model per clock; the corrective rule is
chess-selfplay.md rule 20 (the full matrix, complete games only, probes never selection
evidence), and the per-speed model table it feeds is `chess_effort.SPEED_MODELS`
(chessweb.md rule 16b) — which, for a routed speed, deliberately outranks the global
mover-model knob, because the second directive of that night was that a global model
selection must not survive a control merely because it predates the measurement. The same
evening produced the budget rule's motivating death: browser-047, a won 10+0 position with
98.5 seconds on her clock, one model call run to the fixed 90-second ceiling, the flag down
nine seconds after the timeout with no move ever returned. Rule 16g is the answer — the
per-attempt ceiling derived from the live remaining clock, and a no-model fallback move
played from the prompt's own arithmetic when the budget is spent, recorded loudly as the
model's failure to answer, never as a success.

### 2026-08-27 — the benchmark played, and the clock picked the pairs

The self-play benchmark the mechanism commit (5aa7754) was built for ran to completion the same
night: 24 games across 1+0 through 15+10, five haiku/sonnet configurations, colours rotated, real
clocks, plus counted probe calls for fable. The finding that decided everything was the in-game
latency tail, not the win column: sonnet `low` is steady (median 3.1s, p90 3.7s), sonnet `medium`
holds the same median but hides a p90 of ~15s, and sonnet `high` runs a 15.8s median with a 64s
p90 in real games — against a 3.1s bare-call probe, which is what an idle account and a tiny
prompt price, not what a game pays. Every decisive result but one checkmate was a flag: the
`medium` sharp tail bled out against +1s and +2s increments (2+1, 3+2, genuine zero-clock deaths
over 50-73 plies), `high` flagged four of six rapid games, and haiku never answered a game
position under 18s at any effort and flagged every timed game it played. So `SPEED_PAIRS` landed
its measured values — bullet `low`/`low`, blitz `low`/`low`, rapid `low`/`medium` — untimed games
keeping the user's adjudicated uniform pair, and the per-speed model knobs staying unset:
sonnet is the mover everywhere, and fable, playable at ~3.9s, stays out of reach of the grind on
2026-08-15's lesson alone. The full tables are docs/chess-bench-2026-08-27.md. The one checkmate
(game 024, `medium`/`high` surviving 15+10 to mate `low`/`low`) is the standing note that high
effort plays better chess than the standard clocks let it prove.

### 2026-08-26 — the effort dial's parity A/B, rejected

The 2026-08-15 lowering of the effort pair to `low`/`medium` ran nine days as one undifferentiated
block — `chess_effort` read its knobs at import, and the bridge is a resident daemon, so whichever
pair was live at daemon start froze for every game until restart — and proved unadjudicatable: 36%
before, 38% after, with similar-game retrieval and two prompt changes inside the same window, which
measured the fortnight, not the dial. The fix that shipped (3a1e4f2) interleaved the two pairs by
game-id parity — odd games at `medium`/`high`, even at `low`/`medium`, a trailing `arm=` token on
the effort metrics row so the ledger could split the games by arm instead of by date window. The
user rejected the experiment outright: no arms, no parity, one uniform pair for every game — and
the pair he reaffirmed at 14:26 that day is the lowered `low`/`medium`: the permanent cleanup was
the removal of the alternation, never of the lowering. The first rollback (2496838) was dispatched
from a brief that misread the rejection as a return to the 2026-08-10 `medium`/`high` values and
restored them as the source defaults against that live instruction, minutes after it; the live
daemon stayed correct only because a runtime drop-in pinned `low`/`medium` over the defaults, and
the correction landed the same afternoon. The pre-experiment
`DESKCRAB_CHESS_EFFORT_QUIET`/`_SHARP` knobs stand, defaulting `low`/`medium`, so a
re-adjudication stays a config line, not an edit. Effort rows written while the A/B was live still
carry the `arm=` token;
it is historical residue and readers ignore it. If a per-game experiment ever comes back, it comes
back as a design the user has agreed to, never as a default.

Contract: [`specs/chessweb.md`](../specs/chessweb.md), rules 16b and 17.

### 2026-08-10, that evening — two hands on one board, and the doubles that were neither

The evening the resident mover went live, three symptoms looked like one bug: two of her sessions
choosing the same move and the loser told "illegal move"; two chessweb wakes apparently booked for
the same minute, game and position; and three to six live timers with no booking record. The
ledger, the turn-metrics log and the day journal say they were three separate things — and only
the first was in the chess path at all. The cocoon guard, under suspicion all evening because it
was sealing her tools at the same moment, appears in none of the three mechanisms. And there is
no move queue anywhere in this — none existed, none was added.

**The same move from two hands.** A post-move wake session read its board, found the position
hers — the user had answered while the wake stood in line — and played by hand, racing the
resident mover answering the same position in-process. The race is survivable by design and the
guards held: at 22:51:50 the metrics show `move-played … ply 17 g6 cli` and, one second later,
`mover-stale … ply 17 now ply 18` — the mover's own answer discarded by the rule-16d photograph
guard. Nothing was ever double-played, tonight or anywhere in the log. Earlier the race ran the
other way: the mover landed Nf3 at ply 14 (22:42:07) and a wake session's identical Nf3, seconds
behind, was refused — as `illegal move: Nf3`, because `parse_move` answers the board in front of
it, and on that board the knight had already moved. The loser of a race deserves the truth: it is
a **turn conflict**. `betty-chess move` now says so whenever a move fails while the side to move
is not hers — naming the side and player whose move it actually is, and, when the refused text is
exactly the last move on the board, that another hand already played it and at which ply
(chessweb.md rule 15, `raise_turn_conflict` in `lib/chess_cli.py`, cases in `tests/test_chess.sh`).
Text that is not chess-shaped keeps its own reading error: "turn conflict" over a typo would send
her hunting a race that never was.

**The "double-booked" wakes.** No move was ever booked twice. Every repeated ledger line was ONE
wake bouncing: a post-move wake fires one second after booking, waits up to 90s at the run lock,
defers on the event backoff and re-books itself — `booked`, same reason, roughly every 92 seconds,
for as long as sessions held the lock. With a move landing every ~20 seconds and each wake that
finally wins the lock costing a minutes-long session, the queue held several bouncing wakes per
game at once, tidy kept `spread`ing them on and off each other's seconds (three times in twenty
seconds at 22:49), and the wake for one browser-005 move finally ran at 22:55 — ten minutes after
the move and six after that game had ended in checkmate — announcing a san that was stale by
half a game. The fix is one line of prose, not queue machinery: the post-move reason is now **one
fixed sentence per game** — it names the game and `betty-chess show <id>`, never the move or
whose turn — so rule 10's byte-identical event coalescing folds the next move's booking and every
deferral re-book into whatever post-move wake already stands for that game. At most one pending
per game, enforced by the queue's own existing rule (chessweb.md rule 7). The board she is
pointed at is the only copy of the position that cannot be stale. The serve loads its source once
(the 2026-08-08 lesson), so the new reason begins at the service's next restart; deliberately not
restarted under a live game — the CLI-side fixes were live at once.

**The "orphan" timers.** Not one of them was an orphan. A fired wake retires its record first
thing (rule 19), and its one-shot timer lingers as a husk until `--collect` reaps the pair at
service exit — so a wake queueing at the run lock is, for up to ninety seconds per bounce plus
the whole session when it wins, a live timer with no booking record BY DESIGN. tidy and restore
have always skipped a unit whose service is active; `wake_list` did not, reported exactly that
state as `orphan`, and the block put "three to six timers nobody booked" in front of her all
evening — one per chess wake in flight. `wake_list` now skips a record-less unit whose service is
active or activating (wake-queue.md rule 3a, self-awareness.md rule 3); a record-less timer whose
service is dead reads `orphan` exactly as before, and a never-fired one is still never purged.
Verified against the live manager mid-storm: five wake services in flight with retired records,
nine pending bookings, zero phantoms in the block.

### 2026-08-10 — the move that waited in line behind the conversation

Her chess moves used to be wakes: the bridge booked an event wake per user move, the wake queue
ran it through the single-session lane, and the session rebuilt her entire prompt — state block,
memory retrieval, conduct — to pick one chess move. Every part of that machinery was built for
work nobody is waiting on, and chess is the one thing in the system where somebody is *sitting
there*: each time the user talked to her on the phone, their own conversation pushed her chess
reply further back. Measured cost, 2–5 minutes per move; the user asked repeatedly for it to be
fixed, and the earlier patches (event-lane priority, effort overrides, an always-low pin) only
shaved the queue — they never removed it.

The redesign removed it. The bridge now owns a resident mover (`lib/chess_mover.py`,
specs/chessweb.md rule 16): reflex memory answers known positions with no model call at all, and
an unknown position costs exactly one minimal `claude -p` — FEN, legal moves, history, the
similarity note, ~200 tokens of context in the measured no-tools shape — posted back under the
hub's own lock after re-reading the store, so a stale answer is discarded by the same photograph
logic as `--expect-ply`. There is no queue anywhere in the path: one slot, newest position wins,
an in-flight call for a superseded board is killed. The wake queue keeps only the end-of-game
announcement, which is the one chess event nobody is waiting on. First live move after the
rewrite: a book reply in 4 milliseconds; first reasoned move, seconds. The general lesson got
learned twice on this machine (the phone server answers turns itself rather than booking them):
a queue built for patience must never carry anything a person is waiting on.

Contract: [`specs/chessweb.md`](../specs/chessweb.md), rules 7, 12, 16, 16b and 17.

### 2026-08-09 — the bridge vanished mid-game, and the traceback was innocent

Mid-game, the browser player's connection dropped and nothing was listening on 8181 afterwards; the
serve log ended in `ConnectionResetError: [Errno 104] Connection reset by peer`, and the obvious
reading was a crash. The archaeology said otherwise. Every reset traceback in that log came out of
`process_request_thread` — `ThreadingHTTPServer` contains those to the one connection that raised
them — and a phone roaming between the LAN and its tailnet address had been printing them all
evening while the game played on. Replaying the same barrage against that exact code (hard resets,
`SO_LINGER` 0, at mid-request, mid-upgrade, and under a poll-thread broadcast) confirmed the
process survives every one. The log's true last words were a normal `wake booked`, then silence:
the bridge was running as a background child of a session, and a session's exit reaps its
children. The listener died of process management, not of a packet.

The same replay against the old code did reproduce the bug that made the outage feel like data
loss: a reconnecting seat was seated and told Player and OpponentJoined, and then nothing — a blank
board over a game sitting intact on disk, where the only visible "fix", New Game, is exactly the
click that starts a fresh game once the stored one has ended. Three changes came out of the night,
each pinned by a wire-level test in `tests/test_chessweb.sh`: a seat Join now syncs the live game
at once (rule 3); connection-family errors log one line instead of a stack trace, with a guard on
the accept loop for anything that ever escapes a handler (rule 14); and
`systemd/deskbetty-chessweb.service` (`Restart=always`, `RestartSec=2`) owns the process, because
rule 10 already made restarts lossless — the suite SIGKILLs the bridge mid-game, restarts it, and
plays on in the same game.

Contract: [`specs/chessweb.md`](../specs/chessweb.md), rules 3, 10 and 14.

## The OpenRSC player

### 2026-08-29 — XP/hour existed only for the current clock

The player could report XP per action and XP/hour for its selected activity, and the event-driven
author could refine reflexes from outcomes, but neither side retained the bridge between them.
Changing activity erased the measured baseline; changing a reflex left no explicit before/after
performance boundary; and starting a new skill did not point the author at structurally similar
reflexes already learned elsewhere. The user therefore still had to ask for a reflex explicitly,
even while current-rate data and reusable rules both existed on disk.

Activity measurements are now iterations. Switching, restarting, clearing, or changing a relevant
executable reflex closes one durable record with its rule fingerprint and begins the next from live
cumulative XP. Reflex mutations retain their exact before/after form and the preceding activity
sample. New activities queue an immediate reuse review, while productive activities queue a bounded
three-minute performance checkpoint; the background author compares only samples at least a minute
old with positive XP. This deliberately is not an XP threshold trigger: safety, conversation,
inventory limits, wanted loot, and acknowledged commitments remain higher-order constraints, and a
rate change is acted on only when grounded outcomes identify a causal correction.

Contract: [`specs/game-player.md`](../specs/game-player.md), rules 1, 7, 11 and 16.

## Long-term memory

`crab memory`, `lib/memory.py`: a sqlite-vec store at `~/.local/share/deskcrab/memory/memory.db`
(override the directory with `DESKCRAB_MEMORY_DIR`) holding `directive` records (the user's standing
rules — never decayed, only superseded by a newer directive) and `note` records (the assistant's own
soft memory), embedded 768-dim by `nomic-embed-text` on the local ollama daemon
(`search_document:` / `search_query:` prefixes per nomic's convention).

The sqlite-vec extension ships in a PyPI wheel, so it lives in a uv venv at
`~/.local/share/deskcrab/venv`; `memory.py` re-execs itself into that venv when run under a bare
python.

### Two pools, two floors

Retrieval is two pools with different floors, queried separately so the assistant's own notes can
never crowd the user's rules out:

- **notes** — top-8 above cosine 0.35, ranked by the reinforcement score
  `cosine × confidence × decay(last use, 90-day half-life) × (1 + log(1+use_count) × 0.15, capped)`;
- **directives** — everything above the deliberately looser 0.28 floor (cap 10, raw cosine, never
  decayed or boosted);
- every pinned record rides along regardless.

The recall block is capped at about 800 tokens; notes drop first, and the header says TRUNCATED when
it happens. The block is written in the assistant's own first-person voice — headers "What I hold
to:" / "What I know from my own time:", never "things he has told you".

### Reinforcement is written on use, never on retrieval

`crab memory reinforce <id>...` is written only when a record was genuinely USED in a turn; retrieval
itself bumps only `last_seen`.

The turn-end judge closes that loop: `recall-block --ids-out` leaves a per-turn sidecar naming the
records that actually reached the prompt (truncated-away notes excluded), and after the reply is
delivered every turn path — desktop, phone, wake — fires `fire_memory_judge` (detached, same shape as
the promise audit), which runs `memory.py judge-turn`. `MEMORY_JUDGE_MODEL` (default opus — judging
use is taste, same tier as the sift) decides which injected records genuinely influenced the turn, and
only those are reinforced.

**The judge is shown the turn's WORK, not only its words** (`--actions`, fed the same
`wake_work_trace` the journal uses), because a wake's entire output is often tool calls. The first six
live judgements all came back `used=NONE`, and the wordless case never even reached the judge — the
sidecar was deleted on the "no reply" branch, so a directive obeyed for ten silent minutes scored
exactly as much as one nobody read.

Measured on the 04:57 wake of 2026-08-07: reply-only judging credited `[19]`; the same turn judged on
its trace alone credited `[4, 13, 19]`. So the gate is no evidence of *either* kind, not no words. Ids
the judge names that were not injected are discarded, surfaced-but-ignored records get nothing and
keep decaying, an error-shaped wake reply is never judged, and `MEMORY_JUDGE=0` switches the judge
off. One line per judgement lands in `${STATE_PREFIX}-memory-judge.log`.

The ingest pass also runs confidence decay: an active note neither retrieved nor used in 90 days loses
0.1 confidence per pass and retires below 0.3. Directives never decay.

### 2026-08-07 — every prompt build fell back to the pinned tier for a day

**What the prompt will take and what the EMBEDDER will take are different numbers, and the small one
governs the query.** nomic-embed-text's trained context is 2048 tokens and ollama refuses anything
longer with HTTP 400 `the input length exceeds the context length` rather than truncating.

So `recall_query` composes under `RECALL_QUERY_CHARS` (4800), itself under `EMBED_CHAR_CAP` — which is
now *derived* (`EMBED_TOKEN_LIMIT` 2048 × `EMBED_CHARS_PER_TOKEN` 2.5 = 5120) rather than picked, at a
chars-per-token estimated LOW on purpose so the ceiling is wrong in the safe direction.

Re-measured 2026-08-07 against ollama 0.21.0 with her own want documents as the input, because the
ceiling is a property of the TEXT as much as of the model: **7,000 chars embedded, 8,000 refused.**

> Unexplained and deliberately not built on: the same probe with repeated filler
> (`"word " × 40,000`, 200,000 chars) embedded fine at every size tried. Prose refuses where the
> arithmetic says it should, and prose is what this file embeds.

Unclamped it composed 19,471 chars on 2026-08-07 and every prompt build fell back to the pinned tier
for a day, with `crab memory search "<short thing>"` looking perfectly healthy the whole time because
a short query fits.

### And length was only half of it — the other half is what the query is ABOUT

That first fix shortened the query and left its SUBJECT wrong: every prompt build, interactive turns
included, asked the store about her wants shelf while the user was talking about his own business.
Memories have nothing to do with wants unless a want is actively being pursued.

Composition now forks on what the session IS (`SESSION_KIND`, the same thing the rest of `lib/` goes
by; `common.sh` passes `--wake` on that, and a non-empty reason implies it):

- **In conversation** (`conversation_query`) the subject is the conversation: the last user block
  first and holding `RECALL_USER_SHARE` (0.7) of the budget, her own immediately preceding reply
  behind it as context, headers stripped, the `---DISPLAY---` channel dropped (it is markdown for a
  window, not words about the subject), inter-block `[Autonomous wake — …]` markers dropped — and **no
  wants at all**. Block headers are matched with the stamp OPTIONAL (`CONVO_HDR_RE`), or every archive
  and every pre-stamp transcript would compose an empty query and look exactly like a quiet
  conversation.
- **On a wake** (`wake_query`) the subject is the agenda: the reason, plus the ONE want being worked
  if it can be named. `want_focus` takes the want the reason names, else the single most recently
  written want document if it was written inside `WANT_RECENT_SECS` (6 h), contributing that want's
  shelf topic (`WANTS_BULLET_CHARS`, 240) plus its most recent DATED section only (`want_progress`,
  `WANT_PROGRESS_CHARS` 1500).

Not the whole document, and the reason is measured rather than aesthetic: these documents grow by
APPENDING today's log, and `embed()` clamps from the FRONT, so a whole-document query is silently a
first-N-chars query over the OLDEST material. On `wants/sleeping-every-night.md` (24,399 chars) the
clamp kept the founding day and dropped all six of that day's dated sections, every one of them the
work in hand.

A reason with no want to attach to stands alone rather than being padded with twelve unrelated shelf
topics; only when nothing is identifiable does the shelf stand in.

### Degradation must never be as quiet as working

Truncation is never silent any more: `_clip` records every bite, and `recall_query` writes one line
naming what was cut to `${STATE_PREFIX}-memory-recall.log`. The outage was not a crash — it was a
degradation as quiet as working.

Two mechanical backstops under that: `embed()` clamps every text to `EMBED_CHAR_CAP` and retries a
length refusal at half the length (`EMBED_SHRINK_TRIES`) instead of raising, and it raises
`EmbedRejected` carrying the daemon's **response body** — urllib's own message is the generic
"HTTP Error 400: Bad Request", which is exactly how a length limit passed for a dead embedder.

### The dedup thresholds are measured, not designed

`crab memory ingest` distils new day-journal turns and transcription files (byte-offset/size cursor in
`ingest-cursor.json`) through a cheap claude session (`MEMORY_INGEST_MODEL`, default sonnet) into
candidate records, then dedups:

- a same-kind exact (normalized) text match bumps `last_seen`;
- a same-kind match at cosine ≥ 0.92 with different text supersedes (newer wins; the old record stays
  readable, flipped to `superseded` and excluded from retrieval);
- anything below just adds.

Both cuts are deliberately NOT the design doc's (0.92 dup / 0.75 supersede): a one-word factual change
("seven"→"nine") embeds at 0.947, so a threshold dup would keep the stale fact active; and
related-but-distinct rules land 0.75–0.90, so a 0.75 auto-supersede ate two real directives on first
live ingest.

`memory dump` is the readable-text view of the whole store. `MEMORY_STORE=1` splices the recall block
into every prompt build; the block is fail-safe — empty store adds nothing, embedder down degrades to
pinned records with a loud warning, never a broken prompt.

### 2026-08-07 — a test reinforced the live store

Both memory shell tests run a scratch instance, so **every `DESKCRAB_*` redirect must be forwarded by
`detach_turn_child`** or the detached judge writes to the real store. `DESKCRAB_MEMORY_DIR` was
missing until 2026-08-07, and `tests/test_turn_reinforce.sh` reinforced record #1 of the LIVE memory
db twice while presenting as a plain test failure.

Contract: [`specs/memory-recall.md`](../specs/memory-recall.md).

---

## The account chain

`CLAUDE_FALLBACK_CONFIG_DIR` is a **chain** of `claude` logins — other Claude Code config directories,
i.e. other subscriptions — that every run path walks when the account in hand refuses over a
usage/session limit.

The value is whitespace- or colon-separated and tried left to right (`claude_fallback_dirs` parses it;
one entry behaves exactly as a single fallback always did), because a second subscription runs out the
same way the first one did, and a run that gave up at the end of a two-account chain is no more
finished than one that gave up at the end of a one-account chain.

### A refusal arrives shaped like a reply

Synthetic assistant message plus `is_error` result, or one line of plain text in `-p` mode.
`claude_run_limited` recognises it via the shared `CLAUDE_LIMIT_RE` signature (the same regex
`job_output_blocked` uses, so the two judgements cannot drift) and only for a stream with no genuine
model output — limit refusals only, since an auth/network failure would fail every other login too and
must surface as itself.

A refusal is recognised only by the CLI's synthetic marker, never by pattern-matching reply text: a
genuine reply that QUOTES a limit phrase must not be gagged as an outage. `extract-response` drops the
refusals whenever a genuine reply follows them in the log; an error-only stream still reports itself.

### Every retry APPENDS to the same stream log, never truncates

The TTS streamer is mid-tail on that file, and it is told nothing about the chain. Counting rides
against a configured or predicted account list was wrong whenever the two drifted: dry accounts
skipped mid-turn muted the FINAL refusal into unexplained silence, which `tts_verify_spoken` then
"repaired" by replaying it late.

Instead every synthetic limit refusal is **held** off the speakers and every limit-flavoured error
result is ridden through — and **a refusal is NEVER voiced**, not even when the whole chain is spent.
An outage read aloud in her voice is how "You've hit your session limit" once landed in the
conversation as her own words.

A wholly-refused turn is recognised by the caller (`claude_run_limited` right after the walk): the
desk turn keeps the refusal out of the conversation and off the speakers and notifies instead; the
phone turn returns it in the `error` field as text; the streamer writes the held words to the speech
log for the record.

Covered paths: `claude_generate` (desk + phone, via `_generate_claude_run`), `run_claude_wake` (via
`wake_claude_run_chain`, so every account's run is under the same stall watchdog), `lib/job-runner`
(judges blocked/`BLOCKED` on the final attempt's byte-slice of the log, so an earlier refusal kept as
history cannot masquerade as the last one's outcome — `blocked` now means the whole chain was tried),
and `compact_convo` (gated on exit code, so a refusal line can never overwrite the summary).

### The moving default: a position, never a timer

Which login runs FIRST is a position. Each limit refusal moves the default to the NEXT account in the
chain (`claude_limit_record`, durable at `~/.local/share/deskcrab/account-default` — override with
`ACCOUNT_DEFAULT_FILE`; delete the file to lead with the primary again), wrapping past the end back to
the primary, and it stays there until the account in hand refuses in its turn. Nothing reverts on age.

This replaced per-account dry stamps with a 30-min TTL, which quietly handed the chain back to a dry
primary every half hour — a full CLI boot plus refusal in front of a reply whose refusal had already
said "resets 5pm" — and, with every account stamped, made each builder walk the whole chain from the
top.

`claude_accounts` always returns the WHOLE chain rotated to start at the default, so a run rides
refusals to whichever login answers and fails only when all of them refused. In the steady state the
default is an account that answered and the first boot succeeds. `crab status` leads with the current
default and why it last moved.

Contract: [`specs/account-fallback.md`](../specs/account-fallback.md).

---

## Watchers and forensics

### Event wakes

`crab wake event "<reason>"` wakes the assistant *about something*, and the reason becomes that
session's agenda instead of the wants file.

Emitters live in `lib/` and are driven by systemd `.path` units, which watch with the kernel's own
inotify — no polling daemon, no `inotify-tools`. `lib/notice-newfiles` is the first one (a transcript
lands → wake about it); it seeds silently on first run so an existing backlog never fires, and defers
while a Parley recording is still writing.

Event units are shipped but **not** enabled by default. Enabling one changes how the machine behaves
towards its user, which is their call.

### Watcher liveness: the canary

A watcher only ever speaks when something is wrong, so a watcher that has stopped being triggered at
all — `.path` unit stopped or disabled, emitter unable to exec, an inotify limit hit — produces the
same quiet as a world where nobody touched her. That is the reading nobody checks.

`lib/canary-selfchange` (daily, `systemd/deskcrab-canary-selfchange.timer`) poses the question the
silence cannot: `notice-selfchange` stamps `notice-self.heartbeat` before any early exit, and the
canary creates and removes a sentinel inside a watched directory and waits for that number to move —
proving kernel inotify → `.path` unit → `.service` → the script's own code, not merely that a unit
file exists.

The sentinel is a dotfile and not `*.md`, so the emitter's snapshot never contains it: the directory
change fires the unit, the emitter finds nothing of substance, and no report or wake is produced.

**The poke must repeat** (every 5 s inside the wait window). A `.path` unit does not queue, so a change
arriving while its service is still running is lost and the unit re-arms only once that service goes
inactive. A single-poke build was measured calling a healthy watcher dead 45 s after the emitter had
merely been busy a moment before.

Three outcomes, only one an alarm:

- an inactive `.path` unit is *started* and she is woken that it had stopped — whatever changed during
  the gap was never judged;
- an already-busy emitter service is inconclusive, never an alarm;
- a heartbeat that will not move fires an event wake naming what is unguarded.

`--no-wake` tests it by hand, `CANARY_TIMEOUT` (default 45 s) bounds the wait, and one line per check
lands in `~/.local/state/deskcrab/canary-self.log`.

### 2026-08-07 07:46 — cause undetermined, twice

Attribution is a parser reading `$DEBUGLOG`, and `$DEBUGLOG` used to be ONE shared file that the next
turn to start overwrote — so by the time a false alarm reached her, the stream that would explain it
was gone.

Twice the diagnosis had to stop at "cause undetermined". On 2026-08-07 07:46, `wants.md` was modified
inside her own wake at 07:44:10, with that turn's harvest declaring `wants/the-library.md` strong and
the `wants` directory weak but never the shelf file, and `claude` long exited before the harvest ran
so no flush race explains it.

So each harvest now copies the finished stream to
`~/.local/state/deskcrab/streams/<epoch>-<pid>.jsonl` (newest `NOTICE_STREAM_KEEP`, default 20, kept)
and appends one line to `notice-self.declared.log` naming the strong and weak sets it produced.

Both are pure evidence — nothing reads them but her, after an alarm — and neither can alter a
declaration. The test asserts exactly that, so **the forensics can never become the bug**. The question
they answer is the one the suppression file alone cannot: whether the stream never named the file, or
named it and the record was lost.

Contract: [`specs/nightly.md`](../specs/nightly.md).

---

## Sleep

`lib/sleep-nightly` runs the nightly memory ingest at 03:10 by `systemd/deskcrab-sleep.timer`, with
`Persistent=true` so a night the machine was off is caught up at boot. It stamps
`~/.local/share/deskcrab/last-slept`, and `sleep-nightly status` exits 1 when the last sleep is 48 h
old or more.

A failed ingest does not stamp — the stamp is a claim that the night happened, and it must be true.
Sleep is separate from the personal tidy timer, which never touches memory.

---

## The debug view

`crab-debug` follows every per-session stream log — desk/wake `$STATE_PREFIX-debug-<pid>.log`, phone
`/tmp/deskcrab-turn-<uuid>.log`, serverless `$STATE_PREFIX-remote-<pid>.log` — **keyed by inode, not
path**, so a symlink claim never replays the previous session.

- pre-launch logs are seeded at EOF (launch shows a short "Last heard" snapshot, never a stale replay);
- **user messages render too**, tailed from the conversation file's stamped `User […]:` blocks — the
  prompt reaches the CLI as argv, so no stream log ever carries it;
- headers are per-session (`── desk · <pid> ──` / `── wake · <pid> ──` / `── phone · <id> ──`, kind
  from the session registry);
- whole JSON lines only (a partial line is held for its newline);
- an unlinked log is drained before close;
- non-JSON stderr lines print as `! …`;
- idle streams release their fd after `DESKCRAB_DEBUG_IDLE_SECS` (120 s) and are watched by size;
- `DESKCRAB_STATE_PREFIX` is honoured, so a scratch instance can be watched.

**Known gap:** detached job / judge / summariser output bypasses the viewer entirely (`job-runner`
logs plain text outside every glob). Closing it needs a writer-side change.

Contract: [`specs/debug-view.md`](../specs/debug-view.md).

---

## The promise audit

`lib/promise-audit` — every path that produces a reply (desktop turn, phone turn, autonomous wake)
fires it via `fire_promise_audit` after the reply is delivered, detached with `setsid` and fds 8/9
closed so it cannot keep the remote or wake lock alive. `PROMISE_AUDIT=0` opts out.

It asks a cheap model whether the reply states a want not in the wants file, and if so fires an event
wake carrying the sentence back. A wake turn is audited as `--wake <agenda>` — no faked user line —
and the audit's own follow-up wake is recognised by its reason opening with
`PROMISE_AUDIT_REASON_PREFIX` and is never re-audited, or the chain would never end. One line per
audit lands in `${STATE_PREFIX}-promise-audit.log`.

---

## Working in this repo

### Several sessions edit the same files at once

`git add -A` in one hand stages whatever the other has open, so its work lands under the wrong commit
message. This happened **twice in twenty minutes on `lib/common.sh`**. Stage explicitly:
`git add -- <paths>`.

### 2026-08-07 — `crab help` started sixteen desktop turns

`crab help` used to fall into the catch-all and be asked of her as a message. Sixteen times in one
day a script or a hand reaching for usage started a whole desktop turn where she was told "help" with
no context. Usage is printed, never spoken to — and a leading dash is a mistyped flag, not speech.

### 2026-08-08 — a landed feature the phone never saw: `serve.py` deploys on restart, not on commit

`crab play` answered "Handed to the phone" and the page showed nothing at all — no transport, no
error. The whole handed-media path (the pointer, the `/media/` route with ranges, the transport on
the page) was committed and correct; it had simply landed three hours after `deskcrab-serve.service`
last started. Deployment by symlink makes the shell live at the next invocation, but `serve.py` is a
long-lived process that reads its source once. Worse, the page IS read from disk per request, so a
phone refresh delivered the new client against the old server: the client asked `/watch` with
`playseen` and the server had no such channel to answer on. **After changing `lib/serve.py`, restart
the unit** (`systemctl --user restart deskcrab-serve.service`) — and remember the half-deployed
state looks like a client bug, because the client is the only part that updated.
