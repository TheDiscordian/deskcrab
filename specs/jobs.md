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
2. A job MUST be dispatched to the user manager with the collect option and its own unit name, with
   a fallback to a detached session when no user manager is running.
3. Dispatch MUST return immediately. The turn that asked MUST NOT wait on it.
4. A job MUST receive every instance redirect explicitly: config path, state prefix, jobs directory,
   wakes directory, memory directory, account default file, and the current login. A user unit gets
   a bare environment, and a scratch instance's jobs must stay in the scratch instance.
5. A job MUST be dispatched with the login the chain currently prefers, and MUST walk the chain
   itself from there.
6. A job MUST be silent by contract: no speech, no notifications, no windows.
7. A job's only channel back to her is one event wake on completion, carrying the outcome as its
   reason.

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
16. While the block marker is younger than the retry window, dispatch MUST refuse. The standing
    policy of dispatching a builder the moment work is noticed otherwise fires builder after builder
    into the same wall.
17. The marker MUST expire on its own, so the first dispatch after the window is the retry probe.
    There MUST be a force flag for a deliberate retry inside the window.
18. The completion wake for a blocked job MUST say plainly that the task is still undone, rather
    than sending the next wake to audit an empty log.

### Context

19. A job MUST arrive knowing the project it is working in. That is the one place the persona
    separation of [prompt-assembly.md](prompt-assembly.md) does not apply, and it is deliberate.
20. Project context MUST be a **named excerpt under a byte cap**, not a whole project instruction
    file loaded by default. See prompt-assembly rule 15.
21. The suppression of project auto-memory MUST stay per invocation. It MUST NEVER be exported, or
    it reaches the builder — the one session that should have the project's rules.
22. A job's output MUST be visible to the live viewer. See [debug-view.md](debug-view.md).

### Reporting

23. Running and finished jobs MUST appear in the state block. A later turn must be able to report on
    work it neither started nor waited for.
24. A job that ended badly since the last turn is surfaced once, capped, stamped. The stamp MUST NOT
    be written by a session whose output is suppressed, and a pending stamp left by a renderer that
    has since exited MUST be swept without spending it. See
    [self-awareness.md](self-awareness.md) rules 31 and 32.
25. `crab jobs` MUST list running, finished, and failed jobs. `crab job log <id>` MUST show a job's
    output.

## DATA

| Path | Format |
|---|---|
| `~/.local/share/deskcrab/jobs/<id>.json` | `{id, description, started, started_epoch, unit, state, pid, pidstart, finished, finished_epoch, exit}` |
| `~/.local/share/deskcrab/jobs/<id>.log` | the worker's raw output |
| `~/.local/share/deskcrab/jobs/blocked` | `<epoch> \t <reason>`, last block wins |
| `~/.local/share/deskcrab/jobs/<id>.lock` | guards read-modify-write of the sidecar |
| systemd unit `deskcrab-job-<id>` | the worker, collected on exit |

## The lifecycle

```mermaid
flowchart TD
  J0["crab job, optional workdir, optional force"] --> J1{"block marker<br/>younger than the retry window?"}
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

**Existing:** `tests/test_job_block.sh` (blocked-versus-failed, the retry window, the force flag).

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
