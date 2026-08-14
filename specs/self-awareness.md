# Spec: self-awareness

## PURPOSE

The state block is how she knows what she is running, what is scheduled, what finished while she was
not looking, and which login is answering. This spec makes the block accurate and makes a false
negative arithmetically impossible to write. It replaces guesswork with counts: the fix for "nothing
running, nothing scheduled" is not a filter that catches the sentence after the fact, it is placing
the facts in front of her so the sentence cannot be written.

The design constraint that shapes everything here: **no mechanism judges a written reply after the
fact and decides it was wrong.** Conduct forbids post-hoc muting, and it is right to. So every rule
below is a fact placed before her, never a gate placed behind her.

## CONTRACT

### Records are the authority

1. The pending-wake list MUST be built by enumerating the durable booking records, and MUST join
   live timers onto them. It MUST NOT be built by enumerating timers.
2. A record with no live timer MUST render as its own distinct line, saying that it is recorded and
   not armed. It is a booking whose timer died with a user manager, and it is exactly the case the
   restore pass exists to heal.
3. A timer with no record MUST render as its own distinct line. It is either a booking whose record
   was lost or a unit from another instance, and both are worth seeing. The **permanent** wake units
   are excluded by name: the standing random-interval timer and the login reconciler are fixtures of
   the installation, have never had a booking record, and are not missing one. Reporting one as "a
   timer with no booking record" puts a wake nobody booked in front of her. A transient timer whose
   **service is active** is excluded too ([wake-queue.md](wake-queue.md) rule 3a): that is a wake
   firing right now, whose record was retired the moment it fired — reported as an orphan it put
   three to six phantom timers in the block for as long as the evening's wakes queued at the run
   lock (2026-08-10).
4. `crab status` MUST warn when a record has no timer.

### Totals before samples

5. Every capped list MUST lead with its total: "Pending wakes: 25 total, 5 nearest shown". A list of
   five bullets with an unstated total of twenty-five is a false report.
6. This applies to every list in the block: wakes, live sessions, running jobs, interrupted traces,
   recently finished sessions.
7. When a list is empty, the block MUST say the count is zero in words that read as a measurement,
   not as a claim about the world.

### Provenance

8. A booking record MUST carry, at minimum: fire epoch, kind, reason, booked-at epoch, and
   **booked-by**.
9. Booked-by MUST name the subsystem that booked it. Eight hands book wakes in her name: the promise
   auditor (`promise-audit`), the promise checker (`promise-check`), the job runner (`job-runner`),
   the self-change watcher
   (`notice-selfchange`), the new-file watcher (`notice-newfiles`), the watcher's canary (`canary`),
   the nightly claudism review (`claudism-review`),
   and the chain floor (`wake-chain-floor`). Two more identities reach a record without being
   subsystems: `outage-retry`, when a wake that failed before the model ran re-books itself and
   cannot name its original booker, and `herself`, the default when nobody says.
10. **The prompt MUST name every identity the queue can stamp**, by the word the record will carry,
    and a test MUST enumerate them from the source rather than from a list written down here. Until
    it does, "nothing scheduled by me" is defensible under her own model of authorship, because
    nothing has told her that anything else books wakes as her — and a roster that names four of
    eight is the same failure with a smaller hole.
11. The state block MUST render provenance for each pending wake it shows.

### The since-last-reply delta

12. The block MUST carry a delta anchored to **the finish of the last session that reached him**, not
    to a fixed window. A fixed thirty-minute window is filled entirely by desk turns during a fast
    exchange, and the wake that fired between them is pushed out of the list.
    - A session reached him when it DELIVERED: a desk turn, a phone turn, or a wake that got past
      the delivery gates. A session that delivered nothing — silent, muted, suppressed by quiet
      hours, killed, or failed before the model ran — MUST NOT set the anchor. Anchored to the last
      session of ANY kind, the delta cannot report a wake at all: a wake is a session, so it sets
      the anchor itself, is then measured against its own finishing time, and counts as nothing.
    - Whether a session delivered MUST be readable from the journal it already writes. A session
      that delivered nothing writes its outcome as a parenthesised note; a session that spoke writes
      the words.
    - With no delivering session on record, the anchor MUST fall back to the same thirty-minute
      window the recently-finished list uses, stated rather than assumed.
13. The delta MUST report, since that anchor: wakes fired, jobs dispatched, jobs that ended badly,
    wakes booked and by whom, and net queue changes. Wakes fired and jobs that ended badly are
    counted by the moment they ENDED, matching the anchor — a wake that began before her last reply
    and worked for half an hour afterwards is the whole of what happened while she was away.
14. **Queue changes MUST be logged to a durable ledger, and the block MUST read it.** A bulk restore
    means a cancellation was undone or the machine rebooted, and today that output goes to
    `/dev/null`. It must become a line she reads.
15. The delta MUST be rendered under a heading that says it covers the time since her last reply,
    not a heading that says "right now".

### The account line

16. The block MUST carry the account state: which login answers next, and why the default last
    moved. `crab status` leads with this; the prompt MUST NOT be the only place it is missing.
17. When the chain was walked during this turn, the block MUST say so, with the from-account and the
    to-account.
18. The turn's session outcome MUST record which account answered.

### The arithmetic negative-claims rule

19. The block MUST state the rule as arithmetic, in the block itself, next to the counts:

    > You may not say nothing is running or nothing is scheduled unless both counts read zero. If
    > they do not, say the number.

20. This rule MUST NOT be phrased as an instruction to go and check. Checking costs time, competes
    with the standing speed rule, and loses. The counts are already in front of her; the rule is a
    comparison, not an errand.
21. No guard, filter, or post-hoc check may be added that inspects a written reply for a false
    negative and mutes or rewrites it. That is forbidden by conduct and is not the fix.

### The four prompt contradictions

22. **"Run them rather than guessing" against "speed is critical, avoid slow tools".** Resolution:
    the block carries the counts, so no command is needed to answer what is running or scheduled.
    The prompt MUST say that reading the block is free and is the answer, and MUST reserve
    "run a command" for questions the block does not cover.
23. **The transcript-beats-commands rule, emitted last and unscoped.** Resolution: scope it to
    words. The transcript is authoritative for what was said and promised. For what is running,
    scheduled, or dispatched, the state block is authoritative and the transcript is not.
24. **Conduct forbids proof-of-work and forbids saying long numbers aloud, which makes a wake
    unnameable.** Resolution: carve out an exception so a wake is nameable without reciting an
    identifier. A wake is named by its clock time and its reason — "the 5:34 one, about the job that
    finished". Unit identifiers and digit timestamps stay out of speech and go to the display
    channel. A count and a clock time are not long numbers.
25. **The persona sheet forbids the vocabulary the block uses.** Resolution: the block and the
    persona sheet MUST use the same words. Fix the block's vocabulary or the sheet's prohibition,
    but they may not disagree.
26. **The prompt points at a heading the block does not emit.** Resolution: every heading named in
    the prompt MUST be emitted verbatim by the block. A test MUST assert that each named heading
    appears in the block's output.

### Two audiences

27. `self_state_report` bare is the dashboard: every live session, every job including finished and
    failed ones, every pending wake, twelve hours of finished sessions in full.
28. `self_state_report --prompt` is the near view: live sessions, jobs running now, pending wakes
    inside the horizon with a total, the interrupted section only when it has something in it,
    recently finished with the delta anchor, the account line, and the arithmetic rule.
29. The near view MUST NOT print history under a heading that reads as live work.
30. Anything the near view omits MUST be named as one command away, with the command.

### The tiredness line

36. The block MUST close with one line summarising the unread pile since the last sleep: a 0–100
    score, its word — **rested**, **warm**, **heavy**, or **overfull** — and the counts behind it.
    The inputs are file facts and nothing else: turns journaled since the last-slept marker and
    their bytes, detached jobs whose sidecar says they ended since the marker, claudism flags
    raised since the marker, and hours elapsed since it. No model is called and no transcript
    content is read — the score is arithmetic on counts, sizes and the clock, so the same files
    always say the same number. `crab tired` prints the same measurement with its parts, one
    command away.
37. The line MUST cost nothing when it fails. An unreadable marker, a missing directory or a broken
    scorer means the block assembles without the line — never a broken block. A missing marker is
    not zero: it means no sleep is on record, and the line says the pile is measured over
    everything on record rather than claiming freshness.
38. The scorer MUST NOT write anything anywhere. It reads the sleep marker; it never stamps it —
    sleeping belongs to the nightly pipeline ([nightly.md](nightly.md)) and nothing here touches
    it. The thresholds live in the scorer, and their reasoning in the engineering note
    (`engineering/tiredness-score.md`); re-tuning them is a scorer change, never a sleep change.

### The block is how she sees, not how she speaks

33. The block's vocabulary is her **senses, never her mouth**. The prompt MUST carry that rule, in
    the layer nearest generation — the turn frame, where an instruction about how to say a thing
    sits beside the thing being answered. She speaks a plan as a person does ("I'll come back to the
    arrangement at one"), not as an operations report ("a scheduled wake is booked"). The block's
    words — wake, session, job, timer, unit — and its bookkeeping — which subsystem booked a thing,
    what owns it, unit names — are spoken ONLY when they answer what was actually asked.
34. This is a fact placed before her while she writes, never a filter behind her. Nothing may
    inspect a written reply for the block's vocabulary and mute, rewrite or grade it; rule 21 and
    [wake-queue.md](wake-queue.md) rule 29 forbid exactly that, and they are not weakened here.
35. Every rendered pending wake MUST lead with its **reason** and trail its machinery:
    `13:00 — Kassandra bar 14: write the blind prediction (booked by you)`. The kind is queue
    vocabulary and answers nothing; leading with it puts the one part of the row she can actually
    say last. A booking with no reason says what a reason-less booking of that kind is, rather than
    printing the kind and stopping. Provenance still appears on every row (rule 11), and a record
    whose booker is `herself` renders as **you** — she is the reader.

## DATA

| Path | Read or written | Format |
|---|---|---|
| `~/.local/share/deskcrab/sessions/<pid>` | read | live registry entry |
| `~/.local/share/deskcrab/sessions/<pid>.claim` | read | advisory claim |
| `~/.local/share/deskcrab/sessions/<pid>.ckpt` | read | append-only checkpoints |
| `${STATE_PREFIX}-sessions.log` | read | append-only session journal |
| `${STATE_PREFIX}-interrupted/` | read | checkpoints moved from killed sessions |
| `~/.local/share/deskcrab/wakes/<unit>.wake` | read | `fire \t kind \t reason \t booked_at \t booked_by` |
| `~/.local/share/deskcrab/wakes/ledger.log` | read and written | append-only queue-change ledger |
| `~/.local/share/deskcrab/jobs/<id>.json` | read | job state sidecar |
| `~/.local/share/deskcrab/account-default` | read | `token \t epoch \t why it moved` |
| `~/.local/share/deskcrab/last-slept` | read | epoch, timestamp, records added — written by sleep, never here |
| `~/.local/share/deskcrab/journal/*.jsonl` | read | one finished turn per line, epoch first; counted, never quoted |
| `~/.local/share/deskcrab/claudism-flags/*.jsonl` | read | one flag per line, epoch first; counted, never quoted |
| `~/.local/share/deskcrab/account-log` | read and written | append-only record of every default move |
| `${STATE_PREFIX}-jobs-surfaced` | written | the once-stamp for failed-job news |
| systemd user timers | read | joined onto the records, never the primary source |

## INTERACTIONS

**Self-awareness may call:** the session registry and reaper, the job status reporter, the wake
queue's list operation, the account selection's current reader, the tiredness scorer
(`lib/tiredness`).

**Self-awareness may be called by:** `crab status`, prompt assembly (as layer L2), and nothing else.

**Self-awareness must never:** book a wake, cancel a wake, stop a job, or write any state other than
its own ledger and stamps. Reading the state must not change it — with two exceptions, rules 31
and 32.

31. The one-time surfacing stamp for a job that ended badly MUST be written only when the block is
    actually delivered to a session that will be heard. A silent wake MUST NOT consume that news.
32. A pending stamp whose process is gone MUST be swept. Only a registered session has a finish to
    drop its own; a renderer of the block that never registered one — `crab status`, or anything
    else building the near view outside a turn — leaves a stamp nothing will ever clear. Sweeping is
    not spending: the durable stamp is untouched, so the news stays owed.

## VERIFIED-CORRECT RULES

- **The registry and the journal are both required.** The registry answers who is running now; the
  journal answers what finished while she was not looking. The registry alone lets a session
  conclude no work is in progress moments after an earlier session finished the work and exited.
- **A registry entry carries the pid and its process start time.** A recycled pid cannot keep a dead
  session looking alive.
- **A session killed without running its trap is journaled as interrupted, not dropped.**
- **The recently-finished window is measured to the moment a session ended, not the moment it
  began.** A plain cut on the start field drops a forty-minute wake that finished five minutes ago —
  the longest work of the half hour and the entry most worth having. The duration is added back on
  for the near view; the twelve-hour dashboard keeps the cheaper comparison, where the distinction
  buys nothing.
- **Thirty minutes of recent history is deliberate**, and was the user's own correction to removing
  it entirely. The block should match what she actually remembers of the conversation.
- **The near view exists because history under a heading that says "right now" reads as live work.**
  A build that died at 02:06 sat in the block all day beside four running jobs, and twelve hours of
  full turn text cost more of the block than everything live put together.
- **A job that ended badly since the last turn is the one piece of history that survives into the
  prompt**, capped at three, stamped so it surfaces once. A missing stamp means "first render,
  nothing was missed", not "dump the back catalogue".
- **Claims are advisory on purpose.** A real lock held by a session that dies mid-edit wedges every
  later one. A hand that cannot start is worse than two hands that can see each other.
- **Any loop over the sessions directory skips the claim and checkpoint sidecars.**

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `H2` | The whole failure: a false "nothing running, nothing scheduled" with twenty-five bookings on disk. Five linked causes, all below. |
| `C4` | The pending-wake list reads systemd and consults the records only to decorate a row it already found. No code path enumerates the records. Twenty-five records rendered as "(none scheduled)". |
| `C7` | Cancelled wakes resurrect, and the restore pass throws its own output into `/dev/null`, so the resurrection is invisible. |
| `MAJ-12` | A failed job's one-time news can be consumed by a wake that ends silently, because the stamp is written on every render. |
| `MIN-3` | The prompt names a heading the block does not emit. |
| `H3` / `RC-4` | No account line anywhere she reads. |
| Recommendation §3 | No total on capped lists, no provenance on records, no since-last-reply delta, no queue-change ledger, and no naming of the autonomous bookers. |

## TESTS

**Existing:** `tests/test_wake_queue.sh` asserts what the block may say, driving state through a
scratch wakes directory. It never exercises the divergence between records and timers.

**To be written:**

- `tests/test_self_state.sh` — drive a scratch instance to a known state and assert the whole block:
  every count leads its list; a record with no timer renders as such; a timer with no record renders
  as such; provenance appears; the account line appears; the arithmetic rule appears; every heading
  the prompt names is emitted verbatim.
- `tests/test_self_state.sh` — the divergence case explicitly: N records, M armed timers, N greater
  than M, and assert the block says N.
- `tests/test_state_delta.sh` — the since-last-reply delta anchored to a session finish, including a
  fast exchange that would fill a fixed thirty-minute window, and a bulk restore that must appear as
  a queue-change line.
- `tests/test_jobs_surfaced.sh` — a silent wake must not consume the failed-job news; the next
  audible session must still see it.
- `tests/test_tiredness.sh` — drive a scratch pile through the scorer: a fresh marker scores
  rested, a fabricated heavy day scores mid-range, a missing marker says so rather than saying
  zero, and a broken input costs the line and nothing else.
