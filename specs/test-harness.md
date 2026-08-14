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
   journal directory, the state home, the data home, and the recorder pid file.
3. The helper MUST stub every desktop tool from **one list**, in one place: the notifier, the
   synthesiser, the audio player, the window manager control, the markdown renderer, the media
   tools, the transcriber, and the CLI itself.
3a. The helper MUST pin the cocoon. The run functions wrap the CLI in a bubblewrap mount namespace
   (`cocoon_wrap_build`), and namespaces do not nest on this machine: from inside a cocooned
   session — hers, whenever she runs the suite herself — the inner `bwrap` dies before it can exec
   ("setting up uid map: Read-only file system"), the stub CLI is never invoked, and the suite
   convicts the code of a defect it does not have. Measured 2026-08-11 on one tree:
   `tests/test_prompt_profiles.sh` reported 81 passed 4 failed from inside a wrap and 85 passed 0
   failed outside it — a verdict that depends on where the suite was invoked is not a verdict. So
   the sandbox points `COCOON_BWRAP` at a pass-through wrap (`tests/lib/cocoon-passthru`) that
   strips the mount flags and execs the wrapped command. No isolation is lost: the CLI behind the
   wrap is already the spend-gate stub. The wall itself stays proven by `tests/test_cocoon_wrap.sh`,
   the ONE file that opts back into the real bubblewrap, and that file MUST skip — say so and exit
   77 — where a namespace cannot be built, rather than fail.
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
     own schedule while the suite runs — today the phone server's seen-file and its webpush store,
     which a phone polling from outside the house moves every few seconds, and the debug logs of
     the sessions that were already awake when the sandbox was built, which each live session
     appends to for as long as it runs. Each exclusion is named individually, in the harness, with
     the writer that moves it. A pattern, a directory swept wholesale, or an exclusion added to
     quieten a failure is forbidden: the accusation is the point, and everything else that moves
     is either the code under test writing where it should not or another hand writing at the
     same moment.
   - The debug-log exclusion is a list of exact paths, enumerated ONCE when the sandbox is built
     and dropped identically from both photographs — a path dropped from only one side would read
     as a deletion. It is never a name pattern: a debug log that APPEARS while the test runs still
     fails it, because a live path minted during the run is the hardcoded-path shape this gate
     exists to catch.
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
10. **Spend.** A test MUST NOT start a real model session. The stub must be asserted as the **first**
    check of any test that dispatches work, so a configuration that overwrites the CLI path is caught
    before the money is spent.
11. **Interrupt.** A test MUST NOT play audio, raise a notification, or open a window.
12. **Speak and schedule.** A test MUST NOT book a real wake, dispatch a real job, or send a real
    push. The booking path MUST refuse to reach the user manager when the wakes directory is not the
    live one, unless an explicit override is set. The job runner already implements exactly this
    guard on its own side; the booking side MUST get the same guard, in the same shape.
13. Every gate MUST be enforced by the code, not only by the test. A gate that lives in the test is a
    gate that the next test forgets.

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
19. Every test file MUST be executable and MUST carry the runner line it is invoked with.
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
| `tests/lib/cocoon-passthru` | the sandbox's pass-through cocoon wrap (rule 3a) |
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
  model session fails.
- `tests/run.sh --list` — every test file is executable, is listed, and either sources the sandbox
  helper or is one of the named exceptions. The roll call also runs before the suite does, so a file
  that skips the helper stops the run rather than passing quietly inside it. Four files predate the
  helper (`test_debug_view`, `test_limit_fallback`, `test_phone_client`, `test_prompt_cases`); each
  pins its own scratch root and stubs the same tools, and what they are missing is the exit-time leak
  check. They are named in `UNSANDBOXED` in the runner, the list can only shrink, and until it is
  empty rule 1 is held by that list rather than by the code.
