# Spec: account fallback

## PURPOSE

A chain of logins, tried in order, whenever the account in hand refuses over a usage or session
limit. This spec owns the moving default, refusal detection, the one watched runner every path uses,
and the requirement that a swap is never invisible. The failure it exists to prevent is not "we ran
out" — it is ten minutes of silence with nothing on screen explaining it.

## CONTRACT

### The chain

1. The chain is the primary login followed by the configured fallbacks, in order. The configured
   value is separated by whitespace or colons.
2. The primary login is **the absence of the configuration variable**, never whatever the
   environment happens to hold. Every run site MUST set the variable for a fallback and **unset** it
   for the primary. Setting it only when non-empty means a session started under a fallback silently
   re-runs the account that just refused, and the true primary is never tried.
3. A walk MUST return the whole chain, rotated to start at the current default.
4. A walk MUST ride each refusal to the next login and fail only when every login has refused.
5. Resolved directories SHOULD be de-duplicated, so a chain that names the same login twice does not
   pay two refusals for it.

### The moving default

6. Which login runs first is a **position, not a timer**. Each limit refusal moves the default to
   the next account in the chain, wrapping past the end back to the primary, and it stays there
   until that account refuses in its turn.
7. Nothing reverts on age. There are no per-account expiry stamps.
8. The default MUST be durable, MUST be overridable per instance, and deleting the file MUST lead
   with the primary again.
9. The file MUST record when and why the default last moved.
10. **Every move MUST also be appended to a durable account log.** Overwriting the default file is
    the only record today, so the history of a chain walking itself dry is unrecoverable.
11. `crab status` MUST lead with the current default and why it last moved. The state block MUST
    carry the same line. See [self-awareness.md](self-awareness.md) rules 16 to 18.

### Detecting a refusal

12. A refusal MUST be recognised only by the CLI's own synthetic marker plus a limit signature, and
    only for a stream with **no genuine model output**. An authentication or network failure would
    fail every other login too and MUST surface as itself.
12a. A limit refusal that arrives MID-RUN is a **cut**: the attempt's slice holds genuine model
    output, and then the CLI's own limit-signature text — a synthetic assistant message, an error
    result, or its own stderr — with no genuine text block after it. A cut MUST be treated exactly
    as a refusal by every account walk: the default moves off the account that was cut, and the
    same prompt re-runs on the next login **at once** — no path waits for a reset while another
    account has credit. However much work it did first, a run the limit cut off never delivered.
    (2026-08-11, 00:17: a wake nine tool calls deep was cut; the synthetic "You've hit your
    session limit · resets 1:30am" was extracted as the reply, journalled as her own words,
    surfaced in her voice — and nothing retried, because the genuine tool calls before the cut
    made rule 12 read the stream as a run that happened.)
12b. A cut MUST be recognised only by CLI-owned text, exactly as rule 15 demands for the refusal.
    The success-shaped result event repeats the final genuine text block verbatim, so only an
    `is_error` result's text may be read for the cut — a genuine reply that quotes a limit phrase
    must not read as a cut off the back of its own echo in the result event.
12c. When the whole chain ends refused or cut, the run is a FAILED run with the session limit named
    as its cause: journalled like a model-unreachable outage, never stored, spoken, displayed, or
    committed as assistant output — and a wake re-books itself through the same outage-retry path,
    so the agenda survives to the reset (wake-queue.md rules 23 and 41).
12d. The CLI has been observed (2.1.219, 2026-08-11) to end a cut stream with a final result line
    carrying `is_error` and NO `type` field at all. Every judgement MUST read that line as the
    error result it is.
13. One signature MUST be shared between the retry decision and the blocked-job judgement, so the
    two cannot drift.
14. **Each attempt MUST be judged on its own bytes.** The runner records the log offset at the start
    of each attempt and judges only what follows it. Judging the whole accumulated log means that
    once one account has left a refusal there, any later failure with no output — a network error, a
    crash, a watchdog reap — matches, is misread as another refusal, and moves the durable default
    onto an account that never refused.
15. A refusal MUST NEVER be recognised by pattern-matching reply text. A genuine reply that quotes a
    limit phrase must not be gagged as an outage.
16. A refusal MUST be dropped from the extracted reply whenever a genuine reply follows it in the
    same log. An error-only stream still reports itself.

### One watched runner

17. There MUST be exactly one function that invokes the CLI, and every path MUST use it: the desk
    turn, the phone turn, the wake, the job, the summariser, the judge, the ingest, the promise
    audit, and the promise checker.
18. The runner MUST take a stall timeout and a whole-chain wall-clock deadline. A turn with someone
    waiting gets a short stall timeout; an unattended wake gets a longer one and no wall clock.
19. **Liveness MUST be two signs, not one:** new bytes in the stream log, or CPU burned across the
    process tree. The log gets nothing during a single long tool call, so log freshness alone kills
    genuine work; a hung network call sits at almost no CPU, so CPU alone misses a real hang.
20. The wall clock is the backstop the stall test cannot be, because a session that keeps emitting
    output is never silent.
21. The runner's poll granularity is also the delay between the CLI finishing and the caller
    noticing. It MUST be fine enough that a finished turn is not held.
22. The stream log is truncated once per turn by the caller. Every attempt inside the runner
    APPENDS.
23. The runner MUST leave the child's exit status and, if it was reaped, the reason, where the caller
    can read them.

### Announcing a swap

24. Every swap MUST write a marker line into the stream log, so the viewer and the extractor can see
    it and she can say what happened.
25. Every swap MUST raise a desktop notification for a turn somebody is waiting on, and MUST NOT for
    an unattended wake.
26. The marker MUST NOT itself match the limit signature, or a marker quoting a refusal makes a later
    network error read as one more refusal.
27. Any long-lived "thinking" notification MUST be dismissed on every exit path.

### Children

28. Every detached child MUST inherit the current login. A child that fires at the ambient login and
    fails quietly is a silent hole in the chain.
29. Every out-of-band model call — the promise audit, the promise checker and its sweep, the
    memory store's ingest and judge, the summariser — MUST route through the chain, or at minimum
    honour the current default.
30. The summariser MUST capture standard error, so a refusal that arrives only there cannot break the
    walk.
31. A refusal MUST NEVER be committed as a summary. See [turn-pipeline.md](turn-pipeline.md) rule 27.

## DATA

| Path | Format |
|---|---|
| `~/.local/share/deskcrab/account-default` | `token \t epoch \t why it moved`; override per instance |
| `~/.local/share/deskcrab/account-log` | append-only: epoch, from, to, reason, session kind |
| the stream log | carries the swap marker lines |

The primary is the token `-`, which no directory can collide with. Every other token is a
configuration directory path.

## INTERACTIONS

**The chain may be called by:** every path that invokes the CLI.

**The chain may call:** nothing but the CLI, the notification helper, and its own record files.

**The chain must never:** speak a refusal, write a refusal to the conversation, or synthesise a
refusal to audio.

## VERIFIED-CORRECT RULES

- **The default is a position that moves, never a timer.** The previous design stamped each account
  dry with a thirty-minute expiry, which handed the chain back to a dry primary every half hour — a
  full boot and refusal in front of a reply whose refusal had already said when it resets — and,
  with every account stamped, made each builder walk the chain from the top.
- **The whole chain is always returned, rotated to the default.** A run rides refusals to whichever
  login answers and fails only when all of them refused. In the steady state the default is an
  account that answered and the first boot succeeds.
- **A refusal is detected only for a stream with no genuine model output.** Authentication and
  network failures must surface as themselves.
- **One signature, shared with the blocked-job judgement.** The two judgements cannot drift.
- **Each retry appends to the same stream log and never truncates it**, because the speech streamer
  is mid-tail on that file.
- **The streamer is told nothing about the chain.** Riding a count against a predicted account list
  was wrong whenever the two drifted.
- **A refusal is never voiced, on any path.**
- **The job runner's per-attempt byte slicing is the correct pattern**, and `blocked` on the final
  attempt means the whole chain was tried. The streaming paths still owe this.
- **The phone's refusal handling is clean end to end** and is the model for the other paths.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `H3` | The account-swap stall as a whole: a 680-second turn with nothing spoken and no error. |
| `H3` / `RC-1` | No stall watchdog on the interactive and phone chain, and no bound on the loop that walks it. A measured fallback run of ten minutes forty-five seconds. |
| `H3` / `RC-2` | The chain silently loses an account, because the primary slot inherits whatever the environment holds. A three-account chain becomes two distinct logins. |
| `H3` / `RC-3` | The post-outage retry arrives with no agenda, and a kind-less wake is never retried. |
| `H3` / `RC-4` | Nothing she can read records any of it: no account line, refusals held off the speakers and written only to the speech log, dropped by the extractor, absent from the session outcome. |
| `H3` / `RC-5` | The streaming paths judge the whole accumulated log rather than the attempt's own bytes, so a later failure with no output is misread as a refusal and moves the default onto an innocent account. |
| `H3` / `RC-6` | Out-of-band children have no chain and no login, and fail quietly. |
| `MAJ-10` | A refusal can be committed as the conversation summary, dropping the folded blocks permanently. Closed 2026-08-08: the summariser runs as an event stream and is judged by `claude_stream_refusal` like every other path, so a refusal is recognised structurally and a summary that merely talks about limits is a summary. |
| Recommendation §4.2 | A swap is invisible: no marker, no notification, and a stuck thinking notification. |
| Recommendation §4.3 | The test suite strips the variable the shipping code fails to strip. |

## TESTS

**Existing:** `tests/test_limit_fallback.sh` — 61 assertions plus the mid-run cut cases (rule 12a:
the cut detector against the observed 2.1.219 stream shape, its disjointness from the plain
refusal, the rule-15 echo trap, the wake and turn walks riding a cut to the next login, and the
job-runner finishing a cut build on the fallback), green, and green partly because the
harness removes an environment variable the code should remove itself.
`tests/test_wake_limit_cut.sh` — the wake path end to end in the sandbox: a chain that ends cut
journals a failed run naming the session limit, writes nothing to the conversation, and re-books
through the outage-retry path; a chain with credit left delivers the fallback's reply and re-books
nothing.
`tests/test_convo_compaction.sh` — the summariser's own judgement, at both exit codes: a summary
whose text is full of the signature's words is committed and folds its blocks away and stamps nobody
dry, while a stream carrying the CLI's synthetic refusal and no genuine output skips the compaction,
keeps every turn, and moves the durable default.
`tests/test_memory.py` — the turn-end judge walks the chain: a refused login moves to the next and
the judgement lands, an entirely dry chain skips the judgement and names it in the judge log, and a
failure that is not a refusal spends no second login.
`tests/test_job_block.sh` — a detached child inherits the chain and the signature, not only the
login, so it can walk past an account that went dry between dispatch and run.

**Required changes and additions:**

- `tests/test_limit_fallback.sh` — **delete the environment stripping**, preset the variable to a
  dry fallback, and assert the stub records a call to the primary. That case is red today.
- `tests/test_limit_fallback.sh` — a network-shaped failure after an earlier refusal must not be
  recorded as a limit, and must not move the default.
- `tests/test_watched_runner.sh` — a child that emits nothing and burns no CPU is reaped at the stall
  timeout; a child that emits nothing but burns CPU is not; a child that keeps emitting past the wall
  clock is reaped; the caller sees the status and the reason.
- `tests/test_account_ledger.sh` — every move appends to the account log; the state block and
  `crab status` both show the current default and why it moved; a turn that walked the chain says so.
- `tests/test_swap_announce.sh` — a swap writes a marker to the stream log, notifies on a turn, does
  not notify on a wake, and the marker does not match the limit signature.
- `tests/test_child_env.sh` — every detached child inherits the current login.
