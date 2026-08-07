# Spec: nightly

## PURPOSE

Four scheduled processes that keep her from rotting: sleep, which ingests the day into long-term
memory; tidy, which maintains the shelves; the self-change watcher, which tells her when a hand that
was not hers changed the files that constitute her; and the canary, which proves the watcher is
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
    live session's claim names it, or it is the memory database and one of her sessions ran
    recently.
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

## DATA

| Path | Owner | Role |
|---|---|---|
| `~/.local/share/deskcrab/last-slept` | sleep | epoch, timestamp, records added |
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
| `MAJ-32` | Ingest tail-clamps its input against a journal several times the cap, so the day's earliest material is never ingested. |
| `MIN-30` | A stray file duplicates the engineering namespace: unreachable by every reader, and inside the watcher's glob. |
| `MIN-31` | The tidy prompt asks for a dated prose line in a machine-written record, where the journal reader skips it and the ingest drops it. Tidy's own record never survives. |
| `MIN-32` | The canary reports the path unit disabled and only revives it in-session, so it will not come back after a reboot. |

## TESTS

**Existing:** `tests/test_notice_selfchange.sh` — 37 assertions in the most hermetic sandbox in the
suite, and the model for every other test.

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
