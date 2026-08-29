# Spec: test harness

## PURPOSE

One sandbox that every test runs in, four gates that keep a test from reaching the live instance, and
a statement of what the suite owes. The rule this spec exists to enforce: **a test that can reach the
live instance is not a test.** Three of the four gates were built; the fourth was open, and it fired
during the very investigation that produced these specs.

## CONTRACT

### One sandbox

1. There MUST be exactly one sandbox helper, and it MUST be the only way a test sources the library
   or invokes the entry script.
2. The helper MUST pin every knob that can reach live state: the config path, the state prefix, the
   wakes directory, the jobs directory, the memory directory, the account state file, the day
   journal directory, the state home, the data home, the recorder pid file, and the prefix-choice
   log (rule 13b).
3. The helper MUST stub every desktop tool from **one list**, in one place: the notifier, the
   synthesiser, the audio player, the window manager control, the markdown renderer, the media
   tools, the transcriber, and the CLI itself.
4. The helper MUST start from a clean environment rather than inheriting the developer's, on the
   model of the existing watcher test.
5. The helper MUST create its own temporary root and remove it on exit, including on failure.
6. A test MUST NOT set an environment variable that papers over a defect in the code. If the code
   should unset a variable, the test asserts that it does — it does not strip the variable itself.
7. There MUST be one assertion idiom. A suite in two idioms cannot be read at a glance, and the
   counter style and the fail-fast style disagree about what a partial regression looks like.
8. There MUST be a runner that executes the whole suite and reports one summary. Today there is no
   runner, no build file, and no continuous integration.

### The four gates

9. **Touch.** A test MUST NOT write to any live path. Every directory it writes is under its own
   temporary root.
   - The proof is a photograph of live state before and after, and anything that moved fails the
     test. A path may be excluded from that photograph only when a LIVE INSTANCE writes it on its
     own schedule while the suite runs, AND the code-under-test side of that path is held
     somewhere the exclusion cannot blind — a sandbox pin plus a test that reads back through the
     pin, so a regression that ignored the pin still goes red. Today's list, each entry named
     individually in the harness with the writer that moves it:
     - the phone server's seen-file and its webpush store, which a phone polling from outside
       the house moves every few seconds;
     - the live prefix-choice log, to which every live run that loads the library appends its
       rule-13b line (the sandbox pins `DESKCRAB_PREFIX_LOG`, and the isolation test greps the
       pinned log);
     - the live game-state directory (`<live prefix>-game`), which the resident game session's
       engine rewrites about every two seconds for as long as it plays — hours — pausing only
       for the length of its model calls (the sandbox pins `DESKCRAB_GAME_STATE_DIR`,
       `OPENRSC_STATE_DIR` and `DESKCRAB_OPENRSC_STATE_DIR`, and the game suites read their
       fixtures and actions back through the pin);
     - the live metrics directory, to which the token ledger appends one record per live model
       attempt — every live hand's calls land there for as long as the machine is awake
       (`DESKCRAB_METRICS_DIR` is pinned, and the metrics suite reads through the pin);
     - the live chess games directory, selfplay directory, and reflex store
       (`reflex.db` with its sqlite `-journal`/`-wal`/`-shm` siblings), which the resident
       chess bridge and any running bench write move by move and game by game, plus the chess
       directory's own mtime line — sqlite mints and collects the journal beside the store,
       moving the directory with it, and with the store excluded the children can no longer
       testify for the parent (the chess code resolves its home through the pinned `HOME`/XDG
       homes and `DESKCRAB_CHESS_DIR`, the chess suites read their games and reflex rows back
       through those pins, and every FILE under the chess directory beyond these stays
       photographed);
     - the live wake queue's `ledger.log` only — one line per live booking, firing and tidy;
       the booking RECORDS stay photographed, because a booking landing in the live directory
       is precisely the quarry;
     - the self-change watcher's own cycle files (`notice-self.heartbeat`, `.pending`, `.log`,
       `.snap`, `.judged`, `.reported`), which its path unit rewrites on every trigger for as
       long as anything writes the watched directories;
     - the live jobs directory's own mtime line (every sidecar update is a rename inside it)
       and the stream triplet — `<id>.log`, `<id>.json`, `<id>.lock` — of each builder whose
       sidecar says `running` with a live pid, enumerated once when the sandbox is built: a
       sandboxed test cannot start a REAL builder (the dispatch gates refuse a scratch jobs
       directory and `systemd-run` is stubbed), so a builder streaming out there is never the
       test's doing. Files of finished or foreign-dead jobs stay photographed;
     - and the debug logs of the sessions that were already awake when the sandbox was built,
       which each live session appends to for as long as it runs.
     A pattern, a directory swept wholesale without a named writer, or an exclusion added to
     quieten a failure is forbidden: the accusation is the point, and everything else that moves
     is either the code under test writing where it should not or another hand writing at the
     same moment.
   - The debug-log exclusion is a list of exact paths, enumerated ONCE when the sandbox is built
     and dropped identically from both photographs — a path dropped from only one side would read
     as a deletion. It is never a name pattern: a debug log that APPEARS while the test runs is
     still photographed — one that settles is accused as the hardcoded-path shape this gate exists
     to catch, and one still growing at the second look below is a live session's, excused there
     and named.
   - A path that APPEARED counts as much as one that changed. The photograph dropped new paths
     beside the live prefix until 2026-08-08, on the reasoning that a new file there might belong to
     somebody else — and a state file re-hardcoded to a live path, the defect the harness's own
     sweep existed for, creates a file rather than editing one. The gate was blind to the shape it
     was written to catch.
   - The photograph is the harness's ONLY hand on live state: it reads, compares, and accuses. It
     MUST NOT delete, rewrite, or "restore" a live path, however sure it is of the author. A new
     file under the live prefix is ambiguous by construction — the live phone server mints reply
     clips under that prefix on its own schedule, whenever somebody is talking to it — and on
     2026-08-11 a sweep here that removed new `deskcrab-remote-*.opus` files as presumed leaks
     deleted three clips the live server had synthesised and not yet served: the spoken reply cut
     out mid-sentence on the phone, with a replay control pointing at a file this suite had
     destroyed. A real leak surfaces through the diff and is cleaned by a hand that read it; a
     stray clip is collected by the live instance's own hourly sweep. Held by
     `tests/test_sandbox_live_clips.sh`.
   - The photograph can prove THAT a live path moved, never WHOSE hand moved it — and a live
     evening is busy: the game harness rewrites its `/tmp` state every two seconds for hours, the
     selfplay bench keeps the live games directory moving, a live session appends its logs. On
     2026-08-28/29 that traffic handed the LEAK verdict, exit 2, to every run of every suite,
     whatever its assertions found — and a genuine red inside a verdict that fires on every run is
     a red dressed as the weather. So an accusation gets a SECOND LOOK before it becomes a
     verdict: when the before and after photographs differ, the harness waits a settle interval
     (`DESKCRAB_SANDBOX_SETTLE` seconds, default five — longer than the fastest known live
     writer's cadence) and photographs a third time, then excuses a disputed path only on
     causally clean foreign evidence. And because a live writer's quiet stretch can outlast any
     single settle interval — the game engine and the bench movers go silent for the length of a
     model call, which is how one acceptance run on 2026-08-29 accused a path settled that its
     immediate retry excused still-moving — the second look is held open as a VIGIL: while
     anything is still accused, the harness keeps waiting one settle interval and photographing
     again, up to `DESKCRAB_SANDBOX_VIGIL` seconds in total (default sixty), and ends the vigil
     the moment nothing is left accused. A clean run never sleeps at all; only a run already in
     dispute pays, and a path still silent when the vigil runs out has had the whole window to
     show a foreign hand. Three kinds of evidence. STILL MOVING: the path changed again between
     the second photograph and any later one — the test was finished, its at-exit hooks run and
     its assertions counted, so this cannot be its writing. HOT BEFORE: the path's mtime in the
     before photograph sits within the settle interval of the moment that photograph was taken —
     the test had not run yet, and the bench's burst writers, quiet longer than any settle
     interval mid-model-call, are exactly this shape. TRANSIENT UNIT: a `-<moment>-<pid>` stamped
     unit in the units or timers photograph, the shape `systemd-run` mints for wakes, jobs and
     the watchers — inside the sandbox the user manager is unreachable by construction (no
     session bus, a pinned runtime directory, stubbed tools), so no test can put one in the REAL
     manager, while the self-change watcher's two-minute defer cycle mints and collects them
     under whichever test spans it; a persistent unit's change stays accused. Excused paths are
     NAMED, one line each, because a silent exclusion is how gates go blind. Motion evidence
     flows one level between a directory and its direct children — a directory's mtime IS a
     function of them — so a settled game file under a hot or still-moving live games directory
     is that live writer's earlier stroke, excused with it; a settled SIBLING (the planted-leak
     shape) never is. Everything else that moved during the run and then fell quiet stays
     accused, exactly as this rule demands — including a concurrent hand's one-shot cold write,
     which the harness cannot tell from a leak and does not pretend to. A background FILE writer
     leaked by the code under test would excuse itself here; the witness logs and the persistent
     units hold that shape, and the excused list prints either way so a reader sees what was
     forgiven. A LEAK verdict
     never drowns a failing assertion: the counted failures keep their FAIL lines and their exit
     status, a leak beside them is reported beside them, and the runner quotes the first FAIL next
     to the leak notice rather than replacing it. Held by `tests/test_sandbox.sh` — the mechanics
     against crafted photographs, then a planted red and a planted leak each proven under a
     live-shaped churn writer — and by `tests/test_state_prefix_isolation.sh`, whose own
     photograph pair takes the same second look.
10. **Spend.** A test MUST NOT start a real model session — on EITHER engine. The stub must be
    asserted as the **first** check of any test that dispatches work, so a configuration that
    overwrites the CLI path is caught before the money is spent. The codex CLI is stubbed from the
    same one list and pinned the same way (`CODEX_BIN`), because the night judge defaults to a
    codex name ([nightly.md](nightly.md) rule 14c) and an unstubbed `codex` on the PATH is the
    live ChatGPT subscription; the sandbox also pins `DESKCRAB_CODEX_STATE` into its own root, so
    a stub's refusal can never bench the LIVE codex login for every real session.
11. **Interrupt.** A test MUST NOT play audio, raise a notification, or open a window.
12. **Speak and schedule.** A test MUST NOT book a real wake, dispatch a real job, or send a real
    push. The booking path MUST refuse to reach the user manager when the wakes directory is not the
    live one, unless an explicit override is set. The job runner already implements exactly this
    guard on its own side; the booking side MUST get the same guard, in the same shape.
13. Every gate MUST be enforced by the code, not only by the test. A gate that lives in the test is a
    gate that the next test forgets.
13a. **Isolation is the default; the live prefix is claimed, never inherited.** The library resolves
    its own real path — `readlink -f` on `${BASH_SOURCE[0]}` *before* any `dirname`, because a
    symlinked deploy directory otherwise walks to the wrong root — and compares that with what the
    installed symlink `~/.local/lib/deskcrab` resolves to. Only a run whose resolved library
    directory IS the installed one may default to the live state prefix (`/tmp/deskcrab`). Every
    other run — a /tmp checkout, a scratch worktree, a harness that forgot the override — defaults
    to a stable prefix of its own, derived from the resolved library path:
    `${TMPDIR:-/tmp}/deskcrab-<first 8 hex of sha256 of that path>`. Stable, so a scratch instance
    sees its own state across runs; derived from the path, so two scratch checkouts never share a
    conversation; under `$TMPDIR`, so a run inside a sandbox lands inside that sandbox. An explicit
    `DESKCRAB_STATE_PREFIX` wins over both, exactly as before. The resolved choice is re-exported
    as `DESKCRAB_STATE_PREFIX`, so every child a run spawns inherits the answer instead of
    re-deciding it from a default of its own. This is rule 13 applied to the fourth gate: before
    it, isolation was opt-in through the override, and a copy of the code run from anywhere on the
    machine was born holding the live conversation, its locks, and its mouth.
13b. **No silent choice.** Every run that loads the library appends one line — timestamp, pid,
    entry script, the prefix chosen, and which of the three reasons chose it (`canonical` /
    `isolated` / `explicit`) — to `${STATE_PREFIX}-prefix.log`, overridable as
    `DESKCRAB_PREFIX_LOG`, which the sandbox pins (rule 2) so a canonical-install-shaped layout
    under test records its choice without writing beside the live instance. The record is a
    witness, never a gate: a run that cannot write the line still runs.

### Test quality

14. A test MUST assert **absence** as well as presence. A presence-only assertion cannot fail on a
    duplicate, and duplicates are two of the headline bugs.
15. A test MUST drive the **real topology**. A test that writes a plain file where production writes
    a symlink is testing a shape that does not exist.
16. A test MUST measure from the boundary that matters. Speech is counted from a trace written
    outside the streamer, never from the pipeline's own receipt or logs.
17. A test that loads a module under test MUST load the real module, not a re-implementation, or a
    green run is a statement about the test.
18. A test for a bug MUST be red before the fix and green after. A test written after the fix, which
    was never run against the broken code, proves nothing.
19. Every test file MUST be executable and MUST carry the runner line it is invoked with. The bit
    is COMMITTED, never merely local: a tracked `tests/test_*.sh` whose index mode is 100644 is the
    fault, whatever the working tree says. Nothing in the run needs the bit — the runner invokes
    every test as `bash "$f"` — which is exactly how forty-three of them accumulated without it,
    with new ones arriving the same night old ones were swept: the only thing that cared was
    `run.sh --list`'s executability check, and a check that exits 1 for weeks on the unfiltered
    roll call is not a signal. Resolved 2026-08-24, on the record that measured it: the bit and
    the check stand together. Every tracked test carries the bit, `run.sh --list` exits non-zero
    when any file it lists is missing it on disk, and `tests/test_exec_bits.sh` fails the ordinary
    full run when any tracked `tests/test_*.sh` is committed 100644 — so the fault is caught in
    the offending builder's own suite run, at creation, not read off a roll call nobody consults.
    A mass mode fix is one mode-only commit, staged by explicit path, zero insertions and zero
    deletions.
    Resolved AGAIN 2026-08-29, after `tests/test_wake_idle_return.sh` landed 100644 three days
    into the rule's life: both checks above run after the fact, naming a fault some commit has
    already created, and nothing obliged that commit's author to run the full suite between the
    add and the commit. So the gate stands at the one door every new test must walk while its
    author still holds the pen — rule 18 obliges the author to RUN the new test, and running it
    is now what enforces the bit. Phase 1 of `tests/lib/sandbox.sh` MUST refuse, before it
    builds anything, a test file that is not executable on disk, or that the repository holding
    it carries staged or committed mode 100644 (the chmod-after-add shape, which the disk no
    longer shows). The refusal names the file, the offending mode, and the one-chmod fix, and
    exits non-zero, so the creation run that proves a test red proves its mode too. A test file
    outside any repository is judged on its disk bit alone.
20. A test framework invocation MUST NOT fail silently. An interpreter re-execution inside a test
    framework's own process swallows the traceback and produces a bare non-zero exit with no output.

### Coverage owed

21. Each spec's TESTS section names the files that enforce it. Every contract statement MUST be
    reachable from at least one named test. Where a statement is not yet covered, the spec says which
    test will cover it.
22. The following subsystems have no test at all today and MUST get one:
    - the entire input half: start, stop, the transcriber invocation, the recorder lifecycle, the
      record-to-turn handoff;
    - the pronunciation-rewrite knob;
    - the display channel end to end;
    - Web Push;
    - the server's transport, static routes, certificate generation, and authentication with a
      **wrong** secret;
    - the phone's input routes;
    - the day journal, the nightly sleep, the promise audit, the overlap collapser, the canary, and
      the new-files emitter;
    - twelve entry-script subcommands, including status, claim, checkpoint, resolve, notify, serve,
      journal, memory, restore, cancel, and help;
    - ~~quiet hours, which is set to empty in every scratch configuration that mentions it~~ —
      covered by `tests/test_quiet_hours.sh`, which sets a window around the hour it runs in;
    - wake scheduling: the random interval, the floor's choice of moment, and every unit file;
    - the restore loop, which is the heart of the headline self-awareness bug;
    - memory ingest through the real distiller;
    - viewer rendering beyond plain text;
    - the job runner beyond blocking and fallback.

## DATA

| Path | Role |
|---|---|
| `tests/lib/sandbox.sh` | the one sandbox helper (to be written) |
| `tests/lib/stubs/` | the one stub list, one file per stubbed tool (to be written) |
| `tests/run.sh` | the suite runner (to be written) |
| `tests/prompt-cases/` | fixtures for the intent-case acceptance criteria (to be written) |
| `tests/conftest.py` | selects the correct interpreter up front, so the framework cannot re-execute silently (to be written) |

## INTERACTIONS

**The harness may call:** nothing outside its own temporary root, except read-only reads of the
repository under test.

**The harness may be called by:** every test.

**The harness must never:** read or write the live state directories, the live configuration, the
live account state, or the user manager.

## VERIFIED-CORRECT RULES

These are the things the current suite gets right. Carry them into the new harness.

- **Mocks sit at the right boundary.** Audio is always stubbed at the synthesiser and the player, and
  the utterance count comes from a trace written outside the streamer, never from the pipeline's own
  receipt or logs.
- **The composition test loads the real memory module and calls the real composer**, so a green run
  is a statement about shipped code.
- **The watcher test's clean-environment sandbox is the correct model** for every other test.
- **The job-block test asserts as its first check that the stub builder ran.** That is a scar from
  the day a configuration overwrote the CLI path and every run started a live session. Keep the
  ordering.
- **Two tests drive the real server over a real socket.** That is what caught the cursor bug end to
  end.
- **The filler test measures whether something was spoken from the speaker side.**
- **The wake-queue test stubs the user manager** on the stated principle that a test which can start
  a real wake is not a test. That principle is right; it is simply not enforced anywhere but in that
  one file.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `MAJ-33` | One test rewrites the live account default and copies a sidecar into the live jobs directory. It pins neither the account default file nor the config path, despite a comment claiming it does. The fix had been applied to one copy of a duplicated helper and not the other. |
| `MAJ-34` | Tests book real transient wake units into the live user manager. Verified: an armed timer pointing at a temporary checkout, and two failed units, one pointing at a deleted one. |
| `MAJ-35` | The viewer's tests cannot see any of its six worst defects: a plain file where production writes a symlink, presence-only assertions, and a truncation case that shrinks the file, which is the only shape the current guard handles. |
| `MAJ-20`, `MAJ-21` | The memory module ignores the isolation knobs, and one test writes into the live diagnostic log. A poisoned diagnostic channel produced a confident wrong diagnosis during the audit — that is the cost, not the untidiness. |
| Audit §3 | Three green tests are blind: the fallback test is green because the harness removes the variable the code fails to remove; the doubling test never combines the two conditions the live bug needs; the queue test never exercises the record-versus-timer divergence. |
| `MIN-33` | Eight of nineteen shell tests are not executable despite carrying an interpreter line; a stray benchmark directory is untracked and not ignored; the framework invocation exits non-zero with no output at all. |

## TESTS

The harness tests itself:

- `tests/test_sandbox.sh` — the helper pins every knob in the list; a test that tries to write a
  live path fails; a test that tries to book a real wake fails; a test that tries to start a real
  model session fails; the photograph's named exclusions drop exactly the listed paths and
  nothing beside them (a lookalike name, a finished job's log, a booking record all stay in);
  the running-builder enumeration takes a live pid on a `running` sidecar and nothing less; the
  leak check's second look excuses only what kept moving after the run (and its one-level
  directory relatives), names it, and keeps a settled red accused — proven against crafted
  photographs and then live, under a churn writer, where a planted assertion failure exits 1
  with its FAIL line and a planted leak still exits 2 through the whole vigil, while a burst
  writer whose next stroke misses the first settle window is still excused by a later round.
- `tests/test_state_prefix_isolation.sh` — rules 13a-13b: a copy of the repo run with no override
  derives its own stable prefix, never the live one, and creates nothing under the live prefix; a
  canonical-install-shaped layout still resolves the live prefix; an explicit
  `DESKCRAB_STATE_PREFIX` beats both; the choice, and the reason it was made, are recorded. Its
  own photograph pair takes the harness's second look, so a concurrent live writer no longer
  flips its no-touch assertions.
- `tests/test_exec_bits.sh` — rule 19's committed half: the tracked roll call from the index is
  non-empty and includes this file itself, no tracked `tests/test_*.sh` is committed mode 100644,
  and every one carries the bit on disk. Scope is deliberately the TRACKED list, so an untracked
  draft in `tests/` fails nobody's run but its author's `--list`. Each offender is named with the
  one-chmod fix. The same file holds rule 19's door: a deliberately non-executable fixture driven
  through a fresh phase 1 is refused with the one-chmod fix and its body never runs; a fixture
  staged 100644 whose bit arrived only after the add is refused for its staged mode; and the same
  fixture carrying the bit walks through to its own run.
- `tests/run.sh --list` — every test file is executable, is listed, and either sources the sandbox
  helper or is one of the named exceptions. The roll call also runs before the suite does, so a file
  that skips the helper stops the run rather than passing quietly inside it. Four files predate the
  helper (`test_debug_view`, `test_limit_fallback`, `test_phone_client`, `test_prompt_cases`); each
  pins its own scratch root and stubs the same tools, and what they are missing is the exit-time leak
  check. They are named in `UNSANDBOXED` in the runner, the list can only shrink, and until it is
  empty rule 1 is held by that list rather than by the code.
