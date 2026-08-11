# Spec: detached jobs

## PURPOSE

A job is work that must outlive the turn that asked for it. It runs as its own headless session owned
by systemd, not by the conversation, so the user can keep talking while it builds. This spec owns
dispatch, the state sidecar, the blocked-versus-failed distinction, and the single channel a job has
back to her.

## CONTRACT

### Dispatch

1. Background work MUST be a detached job, never a subagent. A subagent dies with its turn, and
   while it lives it holds the turn open so the user cannot speak.
1a. A task whose whitespace-stripped form is empty, or is exactly `null`, `None`, or `undefined`,
   MUST be refused before any sidecar or unit exists. Those strings are what a broken command
   substitution says, never what work sounds like: on 2026-08-11 a re-dispatch loop read `.task`
   out of sidecars whose field is `.description`, jq answered the literal word `null` three times,
   and three real builders woke with no brief and burned tokens investigating their own emptiness.
   The refusal MUST say the task looks like a broken substitution, not a brief, and MUST name the
   real field.
2. A job MUST be dispatched to the user manager with the collect option and its own unit name, with
   a fallback to a detached session when no user manager is running.
2a. A job unit MUST be dispatched at background CPU priority — the same weight and niceness the
   wake queue books with ([wake-queue.md](wake-queue.md) rule 12a, `BACKGROUND_CPU_WEIGHT`,
   `BACKGROUND_NICE`). A builder chewing a compile beside a spoken turn is the measured case: the
   phone server alone burned 49 CPU-minutes in a 46-minute window on 2026-08-09 while turns ran
   beside wakes and builders. Priority only — a job is never paused or killed for a turn.
3. Dispatch MUST return immediately. The turn that asked MUST NOT wait on it.
4. A job MUST receive every instance redirect explicitly: config path, state prefix, jobs directory,
   wakes directory, memory directory, account default file, and the current login. A user unit gets
   a bare environment, and a scratch instance's jobs must stay in the scratch instance.
5. A job MUST be dispatched with the login the chain currently prefers, and MUST walk the chain
   itself from there.
6. A job MUST be silent by contract: no speech, no notifications, no windows.
7. A job's only channel back to her is one event wake on completion, carrying the outcome as its
   reason.
7a. `crab job requeue <id>` MUST re-dispatch a recorded job from its own sidecar: the description
   and the workdir come off the record, so neither a human nor a session ever retypes a field name
   — the failure mode of rule 1a cannot arise. To make that possible, dispatch MUST record the
   workdir in the sidecar. A missing sidecar, a description rule 1a would refuse, or a sidecar with
   no recorded workdir (one written before the field existed) MUST be an error, never a dispatch.
   Requeue goes through the same preflight as any other dispatch: the block marker still holds it,
   and the redispatch is a new job with its own id.
7b. `crab job --record <id>` dispatches a builder AGAINST an engineering record
   ([engineering-records.md](engineering-records.md)). An id the records drawer does not know MUST
   be refused before any sidecar or unit exists; a known one is recorded in the sidecar as
   `record`. Requeue and the automatic block retry carry the record along off the sidecar, so a
   re-dispatched brief keeps the obligation its original carried.

### State

8. There MUST be exactly one field name for a job's state, one writer of it, and one lock. The
   schema field is `state`, and every writer uses it. A second field name means the sidecar keeps
   saying "running" and the next report reaps the job as died.
9. The state values are: `running`, `finished`, `failed`, `stopped`, `blocked`, `died`. Every value
   MUST be documented where the schema is documented.
10. Writes to the sidecar MUST be atomic, so a concurrent reader or reaper never sees a half-written
    file.
11. Any read-modify-write of the sidecar MUST hold the job's lock. The stop path currently races the
    worker's own termination trap.
12. `report` MUST reap a hard-killed worker: a sidecar still claiming to run, whose unit is inactive
    and whose recorded process is gone, is rewritten as died.

### Blocked versus failed

13. A run that exited non-zero having produced only the CLI's own refusal is `blocked`, not
    `failed`. No work was attempted and the log holds nothing to verify.
14. `blocked` MUST be judged on the **final attempt's own bytes**, so an earlier refusal kept as
    history cannot masquerade as the last attempt's outcome. `blocked` means the whole chain was
    tried.
15. A real build failure MUST NEVER match the blocked signature. Misreading one as "never ran" hides
    a broken builder.
    - The judgement MUST read the stream's **events**, never its raw bytes, and MUST consider only
      text the CLI itself produced: a result event, a synthetic (api-error) assistant message, or a
      line that is not JSON at all. A stream carries every byte of every tool result, so a raw
      signature match says "blocked" for a builder that merely READ a file containing the wording —
      and one such file is `lib/common.sh`, which holds the signature's own patterns. The
      consequence is not local: a false block rotates the durable account default and holds every
      further dispatch for the retry window.
    - A slice containing genuine model output is NEVER blocked, whatever words passed through it. A
      run that produced output is a run that happened.
15a. A limit that cuts a build off MID-RUN (account-fallback.md rule 12a: genuine output, then the
    CLI's own limit text with nothing genuine after it) MUST ride the walk to the next account
    exactly as a refusal does, so an interrupted build finishes at once on a login with credit.
    A FINAL attempt that ends cut stays `failed`, never `blocked` — work was attempted and the log
    holds it — and four builders died exactly this way on the night of 2026-08-11, each one
    journalled "failed (exit 1)" with the session-limit line standing as its closing words.
16. While the block marker is younger than the retry window, dispatch MUST refuse. The standing
    policy of dispatching a builder the moment work is noticed otherwise fires builder after builder
    into the same wall.
17. The marker MUST expire on its own, so the first dispatch after the window is the retry probe.
    There MUST be a force flag for a deliberate retry inside the window.
18. The completion wake for a blocked job MUST say plainly that the task is still undone, rather
    than sending the next wake to audit an empty log.
18a. A blocked job's brief MUST NOT wait on the user noticing it. When a job lands blocked, the
    runner arms one transient timer for the retry window plus a margin — past the marker's own
    expiry — and when it fires, the recorded brief is re-dispatched in the recorded workdir,
    through the same preflight as any dispatch, at the login the chain prefers **at fire time**.
    The login that refused is deliberately not forwarded into the timer's unit: the whole point
    of firing after the window is that the chain has since moved.
18b. The retry is exactly one per brief, never a loop. The re-dispatch stamps `retry_of` on the
    new sidecar and `retry` on the origin's; the fire side refuses any sidecar whose `retry` is
    already spent, and the runner never arms a timer for a job that itself carries `retry_of`.
    A retry that blocks too is announced and left, exactly as every blocked job was before this
    rule existed.
18c. Only a job that never began is re-fired. The fire side requires state `blocked` exactly: a
    `failed` job ran, its log holds real work to read, and re-dispatching it would repeat that
    work on the strength of nobody having looked yet.
18d. A job older than `JOB_RETRY_MAX_AGE` when the timer fires is abandoned rather than
    re-fired, and the abandonment is written to both the sidecar and the job's log. A brief
    that has sat blocked for hours describes a tree the user may since have changed by hand.
18e. The retry MUST NOT arm and MUST NOT fire from a scratch jobs directory — the same guard
    the completion wake stands behind — and its fire-time dispatch honours
    `DESKCRAB_NO_DISPATCH` like any other.
18f. The re-dispatched job MUST appear in `crab jobs` as its own entry naming the job it came
    from.

### Context

19. A job MUST arrive knowing the project it is working in. That is the one place the persona
    separation of [prompt-assembly.md](prompt-assembly.md) does not apply, and it is deliberate.
20. Project context MUST be a **named excerpt under a byte cap**, not a whole project instruction
    file loaded by default. See prompt-assembly rule 15.
21. The suppression of project auto-memory MUST stay per invocation. It MUST NEVER be exported, or
    it reaches the builder — the one session that should have the project's rules.
22. A job's output MUST be visible to the live viewer. See [debug-view.md](debug-view.md). Its
    stream log MUST NOT be reaped by the turn-side sweep of stale session logs: a turn is over in
    seconds, so three quiet hours means a dead session, while a builder can spend longer than that
    inside one command without writing a byte. Unlinking a running builder's stream empties the
    attempt slice, blinds the blocked judgement, and leaves a blocked run with nothing to record. A
    job's stream is reaped when the JOB has ended, by the side that can ask.

### Reporting

23. Running and finished jobs MUST appear in the state block. A later turn must be able to report on
    work it neither started nor waited for.
24. A job that ended badly since the last turn is surfaced once, capped, stamped. The stamp MUST NOT
    be written by a session whose output is suppressed, and a pending stamp left by a renderer that
    has since exited MUST be swept without spending it. See
    [self-awareness.md](self-awareness.md) rules 31 and 32.
25. `crab jobs` MUST list running, finished, and failed jobs. `crab job log <id>` MUST show a job's
    output.
26. The human log MUST fill as the builder writes, never only at completion. It used to be
    assembled from the stream after each attempt ended, so `crab job log` on a running or stopped
    job read as empty, and "the job produced nothing" was the natural — and wrong — reading of work
    that was half done. The worker pipes the builder's live stream through a filter into the log
    (behind a tee that keeps the raw stream byte-identical for the viewer and the per-attempt
    refusal slices), so a running job shows its partial report and a stopped one keeps whatever it
    had said. `crab job log <id>` on a running job whose log is still empty MUST say so explicitly
    rather than print nothing, and an id with no sidecar MUST be an error — never dispatched as a
    job whose task begins with the word `log`, the trap `job stop` fell into once.

### The engineering-record hook

27. A job dispatched with `--record <id>` (rule 7b) MUST NOT be marked `finished` unless the
    record's `last_touched` is newer than the job's dispatch time (`started_epoch`) — the builder
    updated the record it came from, and there is no other way to that date, because state moves
    only through `crab eng` and every `touch` bumps it. The comparison is asked of the tool
    (`eng touched-since`), never re-implemented in the runner.
28. A clean build whose record was never touched ends `failed`, with a clear reason NAMING the
    record — in the log, in the sidecar summary, and in the completion wake's reason — so the next
    reader knows the work may be real and the record is what is owed. A run that failed on its own
    stays `failed` for its own reason; a `blocked` run never began, so no record was owed. A record
    the drawer no longer holds fails the same way: an untouchable record cannot pass.
29. The builder MUST be told, in its system prompt, which record it was dispatched against and
    that touching it is a condition of success. This pairs with the standing rule that a builder
    verifies with a real grep or test before claiming done: the record entry is where the
    verification is written down, dated, on the thread the work came from.

## DATA

| Path | Format |
|---|---|
| `~/.local/share/deskcrab/jobs/<id>.json` | `{id, description, workdir, record, started, started_epoch, unit, state, pid, pidstart, finished, finished_epoch, exit, retry, retry_of}` — `workdir` is where the builder ran, recorded so `requeue` never has to ask (rule 7a); sidecars older than the field simply lack it. `record` is the engineering record the job was dispatched against (rules 7b, 27–29), absent when none was. `retry` is the spent automatic retry of a blocked job (the new job's id, `fired`, or `abandoned`) and `retry_of` names the blocked job a retry came from (rules 18b, 18f) |
| `~/.local/share/deskcrab/jobs/<id>.log` | the builder's report, written live as the stream produces it (rule 26) |
| `~/.local/share/deskcrab/jobs/blocked` | `<epoch> \t <reason>`, last block wins |
| `~/.local/share/deskcrab/jobs/<id>.lock` | guards read-modify-write of the sidecar |
| systemd unit `deskcrab-job-<id>` | the worker, collected on exit |
| systemd unit `deskcrab-job-retry-<id>` | the one-shot timer that re-dispatches a blocked job's brief once the hold expires (rule 18a) |

## The lifecycle

```mermaid
flowchart TD
  J0["crab job, optional workdir, optional force"] --> G{"task empty, or a substitution<br/>artifact: null / None / undefined?"}
  R0["crab job requeue &lt;id&gt;"] --> R1["description + workdir<br/>read from the sidecar"]
  R1 --> G
  G -->|yes| Gr["refuse: a broken command<br/>substitution, not a brief"]
  G -->|no| J1{"block marker<br/>younger than the retry window?"}
  J1 -->|yes, and no -f| J1b["refuse: the last one never began"]
  J1 -->|no| J2["sidecar: state=running"]
  J2 --> J3["systemd-run --collect --unit=deskcrab-job-&lt;id&gt;"]
  J3 --> J4["declare the workdir and the jobs dir<br/>as her own hand"]
  J4 --> J5["job profile prompt:<br/>task + index + named project excerpt"]
  J5 --> J6["walk the account chain<br/>judging each attempt on its own bytes"]
  J6 --> O{"outcome"}
  O --> Oa["finished"]
  O --> Ob["failed — a real build failure"]
  O --> Oc["blocked — the final attempt was a refusal"]
  O --> Od["stopped — termination trap"]
  Oa & Ob & Oc & Od --> J8["sidecar + day journal"]
  J8 --> J9["one event wake carrying the outcome"]
  Oc --> RT["one transient retry timer,<br/>JOB_BLOCK_RETRY + margin (rule 18a)"]
  RT -->|"still blocked, retry unspent,<br/>younger than JOB_RETRY_MAX_AGE"| R1
  X["hard kill, no trap"] --> R["report reaps it:<br/>unit inactive + process gone = died"]
```

## INTERACTIONS

**A job may call:** the account chain, the wake queue's `book()` (for its completion wake), the job
status writer, the day journal, the write-declaration helper.

**A job may be called by:** a turn, a wake, or the user through `crab job`.

**A job must never:** speak, notify, open a window, write to the conversation, or hold any lock the
dispatching turn holds.

## VERIFIED-CORRECT RULES

- **Liveness is the process id plus its start time.** A recycled process id cannot keep a dead job
  looking alive. This is why a hard-killed worker can be reaped as died rather than claiming to run
  forever.
- **Each attempt is judged on its own slice of the log.** The runner records the byte offset at the
  start of every attempt and judges only the bytes after it. This is the pattern the streaming paths
  still owe; see [account-fallback.md](account-fallback.md).
- **Blocked is not failed, and the distinction is load-bearing.** A builder that exits in seconds
  having written nothing but a refusal did not fail to build; it never began. Treating the two the
  same either hides a broken builder or burns a wake auditing an empty log.
- **The block marker expires on its own.** Nothing here can see an account refill, so the first
  dispatch after the window is the retry probe.
- **The runner refuses to book an event wake from a scratch jobs directory.** That guard is correct
  and is the model for the same guard on the booking side.
- **Jobs keep project auto-memory on purpose.** A builder works inside a project and should arrive
  knowing its rules. The suppression is per invocation everywhere else so that this stays true.
- **A job is dispatched with the collect option**, so a failed unit does not leak into the user
  manager. The wake queue owes the same.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `MAJ-11` | The stop path writes `status=stopped` where the schema field is `state`, so the sidecar keeps saying running and the next report reaps it as died — the exact confusion the trap exists to prevent. The same path is an unlocked read-modify-write racing the trap. |
| `MAJ-12` | A failed job's one-time news can be consumed by a wake that ends silently. |
| `MAJ-17` | Job output bypasses the live viewer entirely: the log is written outside every glob and the run is not in the stream format at all. |
| `MAJ-28` | A repo job starts on 54 KB of project context in front of a 1.2 KB task. |
| `MIN-4` | The documented state list omits `blocked`, which the runner writes and the reporter renders. |
| `H3` / `RC-2` | A job dispatched from a turn already on a fallback account re-runs the account that just refused, because the primary slot inherits whatever the environment holds. |

## TESTS

**Existing:** `tests/test_job_block.sh` (blocked-versus-failed, the retry window, the force flag,
the substitution-artifact refusal of rule 1a, and requeue reading description and workdir off the
sidecar — rule 7a);
`tests/test_job_livelog.sh` (rule 26: the log fills while the builder runs, a stopped job keeps its
partial output, the pipeline preserves the CLI's exit code, and the empty-but-running and unknown-id
answers of `crab job log`);
`tests/test_job_block_retry.sh` (rules 18a–18f: the runner arms the one retry timer for a blocked
job and never for a failed, scratch, or already-retried one; the fire side re-dispatches once from
the sidecar, naming its origin, and refuses a spent, stale, failed, scratch, artifact-brief, or
workdir-less record);
`tests/test_job_record.sh` (rules 7b and 27–29: dispatch refuses an unknown record and records a
known one; a clean build with an untouched record ends failed naming it; a builder that touches
its record finishes; a job with no record is untouched by the hook; requeue carries the record).

**To be written:**

- `tests/test_job_state.sh` — every state transition writes the `state` field; the stop path and the
  termination trap race is exercised under the lock; a hard-killed worker is reaped as died and not
  before.
- `tests/test_job_dispatch.sh` — every instance redirect and the current login reach the worker;
  the unit carries the collect option; dispatch returns without waiting.
- `tests/test_job_context.sh` — the job profile carries the task, the index, and a capped named
  excerpt, and never a whole project instruction file.
- `tests/test_job_block.sh` — extend to pin the account default file and use a scratch jobs
  directory throughout. See [test-harness.md](test-harness.md).
