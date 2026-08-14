# Spec: accounts

## PURPOSE

The accounts are one flat numbered list, and the only job here is "pick the next available
account". Whenever the account in hand refuses over a usage or session limit, the run moves to the
next account that is worth trying, and the record of that move is durable and visible. This spec
owns the list, the selection, refusal detection, the one watched runner every path uses, and the
requirement that a swap is never invisible. The failure it exists to prevent is not "we ran out" —
it is ten minutes of silence with nothing on screen explaining it.

## CONTRACT

### The list

1. The accounts are a FLAT ordered list, numbered 1 to N, all equal: account 1 is `$HOME/.claude`,
   accounts 2..N are the `CLAUDE_FALLBACK_CONFIG_DIR` entries in configured order. The variable
   name is historical and stays for back-compat; the semantics are one flat list with no special
   member. The configured value is separated by whitespace or colons.
2. Duplicate directories MUST be dropped, so a list that names the same login twice does not pay
   two refusals for it.
3. Every account is addressed by its NUMBER, and every run site MUST set `CLAUDE_CONFIG_DIR` to
   the selected account's directory EXPLICITLY — account 1 included. "No override" is not an
   account name: the variable is exported into a Claude Code session's Bash-tool environment and
   forwarded to children, so any rule shaped as "absent means X" reads a leftover as a decision. A
   three-account list once behaved as two exactly that way.

### The state

4. The state is a persistent CURRENT account (which one answers now) plus a per-account COOLDOWN
   (until when a refused account is not worth another CLI boot). Both live in one small state
   file; deleting the file means account 1 answers and nothing is cooling.
4a. A walk MUST make at least one attempt, whatever the configuration and the state hold. The
    selection MUST yield at least account 1 even when nothing is configured and the state file is
    missing or stale, and a walk handed an empty list anyway MUST fall through to exactly one
    attempt on the account the selection answers with — never to zero. Zero attempts is a failure
    mode, not a degenerate success: a run that never invoked the CLI completes with an **empty
    stream**, and an empty stream reads as clean everywhere downstream — the refusal detector
    finds no refusal, the failed-stream judgement finds no error event — so the session exits 0
    having done nothing and said nothing about it. The 2026-08-11 hunt for exactly that silence
    established that the list cannot in fact go empty as coded (account 1 is a constant, and with
    every account cooling the soonest to expire is still offered), so this rule pins a guarantee
    that was real but unstated, and the fall-through stands guard against any future edit to the
    selection.
5. Each record carries the account's directory as well as its number, and readers resolve by the
   directory — so editing the configured list renumbers cleanly instead of pointing at the wrong
   account. A recorded directory the configuration no longer names is ignored.
6. The state MUST be durable, MUST be overridable per instance, and every reader and writer —
   shell or Python, session or detached child — MUST use the same file, so concurrent runs see
   each other's refusals and skip an account already known dry instead of each paying its own
   doomed CLI boot.

### The selection

7. A run uses the current account when it is not in cooldown. On a limit refusal, the refused
   account's cooldown is set and the current advances to the next account NOT in cooldown,
   wrapping past the end of the list. The new current stays current until IT refuses in its turn:
   no switch-back, and no probing an account inside its cooldown. An account whose cooldown has
   lapsed becomes selectable again, but is only reached when a refusal walks the selection onto
   it.
8. Cooldown length follows the refusal kind: a rolling session limit cools for
   `ACCOUNT_COOLDOWN_SESSION` (default five hours, the window the CLI's own refusal names); a
   usage-credits or otherwise hard stop — credit balance, extra usage, a weekly cap, a login that
   needs a human — cools for `ACCOUNT_COOLDOWN_CREDITS` (default twenty-four hours). Both are
   knobs. An unrecognised refusal wording takes the short cooldown: too eager costs one refused
   boot hours later and corrects itself; too patient benches an account that came back at lunch.
9. The selection is NEVER empty. When every account is in cooldown, the one whose cooldown ends
   soonest is offered, alone. A run always has an account to try.
10. A walk returns every selectable account, in list order rotated to start at the current, and
    rides each refusal to the next entry — recording each refusal as it goes — failing only when
    every offered account has refused.
11. Every move of the current MUST be recorded: the state file says where the selection stands and
    why it last moved; the append-only account log says what it has been through. `crab status`
    and the state block MUST lead with which account answers next, by number, and why the state
    last moved. See [self-awareness.md](self-awareness.md) rules 16 to 18.

### Detecting a refusal

12. A refusal MUST be recognised only by the CLI's own synthetic marker plus a limit signature, and
    only for a stream with **no genuine model output**. An authentication or network failure would
    fail every other login too and MUST surface as itself.
12a. A limit refusal that arrives MID-RUN is a **cut**: the attempt's slice holds genuine model
    output, and then the CLI's own limit-signature text — a synthetic assistant message, an error
    result, or its own stderr — with no genuine text block after it. A cut MUST be treated exactly
    as a refusal by every account walk: the account that was cut cools and the current moves off
    it, and the same prompt re-runs on the next account **at once** — no path waits for a reset
    while another account has credit. However much work it did first, a run the limit cut off
    never delivered. (2026-08-11, 00:17: a wake nine tool calls deep was cut; the synthetic
    "You've hit your session limit · resets 1:30am" was extracted as the reply, journalled as her
    own words, surfaced in her voice — and nothing retried, because the genuine tool calls before
    the cut made rule 12 read the stream as a run that happened.)
12b. A cut MUST be recognised only by CLI-owned text, exactly as rule 15 demands for the refusal.
    The success-shaped result event repeats the final genuine text block verbatim, so only an
    `is_error` result's text may be read for the cut — a genuine reply that quotes a limit phrase
    must not read as a cut off the back of its own echo in the result event.
12c. When the whole walk ends refused or cut, the run is a FAILED run with the session limit named
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
    crash, a watchdog reap — matches, is misread as another refusal, and cools an account that
    never refused.
15. A refusal MUST NEVER be recognised by pattern-matching reply text. A genuine reply that quotes a
    limit phrase must not be gagged as an outage.
16. A refusal MUST be dropped from the extracted reply whenever a genuine reply follows it in the
    same log. An error-only stream still reports itself.

### One watched runner

17. There MUST be exactly one function that invokes the CLI, and every path MUST use it: the desk
    turn, the phone turn, the wake, the job, the summariser, the judge, the ingest, the promise
    audit, and the promise checker.
18. The runner MUST take a stall timeout and a whole-walk wall-clock deadline. A turn with someone
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
    an unattended wake. The notification names both accounts by number: "account 1 is over its
    limit — switching to account 2". Numbers are how accounts are named everywhere a human or she
    reads — the status line says "account 2 answers next".
26. The marker MUST NOT itself match the limit signature, or a marker quoting a refusal makes a later
    network error read as one more refusal.
27. Any long-lived "thinking" notification MUST be dismissed on every exit path.

### Children

28. Every detached child MUST inherit the current login, explicitly, and the state file path when
    the instance overrides it. A child that fires at the ambient login and fails quietly is a
    silent hole in the walk.
29. Every out-of-band model call — the promise audit, the promise checker and its sweep, the
    memory store's ingest and judge, the summariser, the chess mover — MUST select from the same
    flat list by the same rule. The two Python walkers (the memory store, the chess mover) read
    the shared state and skip cooling accounts, and are read-only: recording a refusal is the
    shell paths' job.
30. The summariser MUST capture standard error, so a refusal that arrives only there cannot break the
    walk.
31. A refusal MUST NEVER be committed as a summary. See [turn-pipeline.md](turn-pipeline.md) rule 27.

## DATA

| Path | Format |
|---|---|
| `~/.local/share/deskcrab/account-state` | one `current` line: `current \t number \t dir \t epoch \t why`; one `cooldown` line per cooling account: `cooldown \t number \t dir \t until-epoch \t kind`; override per instance via `ACCOUNT_STATE_FILE` |
| `~/.local/share/deskcrab/account-log` | append-only: epoch, from number, to number, reason, session kind |
| the stream log | carries the swap marker lines |

## INTERACTIONS

**The selection may be called by:** every path that invokes the CLI.

**The selection may call:** nothing but the CLI, the notification helper, and its own record files.

**The selection must never:** speak a refusal, write a refusal to the conversation, or synthesise a
refusal to audio.

## VERIFIED-CORRECT RULES

- **The whole walk is always offered, rotated to the current account.** A run rides refusals to
  whichever account answers and fails only when everything offered refused. In the steady state
  the current is an account that answered and the first boot succeeds.
- **A refusal is detected only for a stream with no genuine model output.** Authentication and
  network failures must surface as themselves.
- **One signature, shared with the blocked-job judgement.** The two judgements cannot drift.
- **Each retry appends to the same stream log and never truncates it**, because the speech streamer
  is mid-tail on that file.
- **The streamer is told nothing about the walk.** Riding a count against a predicted account list
  was wrong whenever the two drifted.
- **A refusal is never voiced, on any path.**
- **The job runner's per-attempt byte slicing is the correct pattern**, and `blocked` on the final
  attempt means everything offered was tried.
- **The phone's refusal handling is clean end to end** and is the model for the other paths.
- **Every account is addressed explicitly.** The predecessor design named one account "the absence
  of the variable", and the walk lost an account whenever the environment arrived holding a
  leftover override.

## KNOWN DEFECTS

| Id | What implementation must fix |
|---|---|
| `H3` | The account-swap stall as a whole: a 680-second turn with nothing spoken and no error. Closed by the watched runner (rules 17 to 23). |
| `H3` / `RC-3` | The post-outage retry arrives with no agenda, and a kind-less wake is never retried. |
| `H3` / `RC-6` | Out-of-band children have no account list and no login, and fail quietly. **2026-08-11 audit (branch `bin-audit-harness-routing`):** the surviving instances were found and closed — `crab memory` exec'd `lib/memory.py` carrying only the `MEMORY_*` knobs, so the nightly ingest ran stock `claude` with the walk collapsed to one login; `lib/sleep-nightly` sourced nothing, so its direct `claudism-scan` rewrite pass did the same; and `detach_turn_child`'s `setsid` fallback dropped `CLAUDE_BIN` and the selected login. All three now export the harness (`CLAUDE_BIN`), the configured list, the shared limit signature, the shared state file, and the account the selection answers with, explicitly (rule 3). **Still open (gap 4):** the mid-turn claudism mirror (`_claudism_mirror_call`) runs on the ambient login rather than the selected one — right harness, wrong account; single-shot and fail-safe, so it merely goes inert after a move rather than erroring. |
| `MAJ-10` | A refusal can be committed as the conversation summary, dropping the folded blocks permanently. Closed 2026-08-08: the summariser runs as an event stream and is judged by `claude_stream_refusal` like every other path, so a refusal is recognised structurally and a summary that merely talks about limits is a summary. |

## TESTS

**Existing:** `tests/test_limit_fallback.sh` — the flat list parsed from the configuration; the
current advancing one position per refusal; cooldown-skip; the wrap; every-account-cooling
offering the soonest to expire; the numbered messages; the walk on the turn, wake, and job paths;
the TTS streamer riding through refusals; extract-response on a combined refusal+reply log. Holds
the mid-run cut cases (rule 12a: the cut detector against the observed 2.1.219 stream shape, its
disjointness from the plain refusal, the rule-15 echo trap, the wake and turn walks riding a cut
to the next account, and the job-runner finishing a cut build on a later account). Also holds rule
4a: with nothing configured and no state record the selection still yields account 1, and a wake
walk handed a forcibly emptied list still makes exactly one attempt, on the account the selection
answers with, with the fall-through named in its own stream. Also holds the 2026-08-11 model-limit
wording ("You've reached your Fable 5 limit. Run /usage-credits…"), which matched nothing in the
signature and let two builder jobs die as ordinary failures with no rotation: the exact observed
line is judged a refusal, matches the blocked-job signature, and rides the wake walk to the next
account, cooling the account it dried up and moving the current — and on the job path, a builder
refused with it finishes on the next account with `--model` unchanged on every attempt
([jobs.md](jobs.md) rule 5a). And the sweep: no emitted account string names a "primary" or a
"fallback".
`tests/test_wake_limit_cut.sh` — the wake path end to end in the sandbox: a walk that ends cut
journals a failed run naming the session limit, writes nothing to the conversation, and re-books
through the outage-retry path; a walk with credit left delivers the later account's reply and
re-books nothing.
`tests/test_convo_compaction.sh` — the summariser's own judgement, at both exit codes: a summary
whose text is full of the signature's words is committed and folds its blocks away and cools
nobody, while a stream carrying the CLI's synthetic refusal and no genuine output skips the
compaction, keeps every turn, and records the refusal.
`tests/test_memory.py` — the turn-end judge walks the list: a refused account moves to the next and
the judgement lands, an entirely dry list skips the judgement and names it in the judge log, and a
failure that is not a refusal spends no second account.
`tests/test_job_block.sh` — a detached child inherits the state and the signature, not only the
login, so it can walk past an account that went dry between dispatch and run.
`tests/test_turn_watchdog.sh` — the interactive walk is bounded, and a swap is announced: marked
in the stream log on every path, notified on a turn, silent on a wake.

**Required additions:**

- `tests/test_nightly_harness_routing.sh` (TODO) — `crab memory ingest` and `lib/sleep-nightly`'s
  `claudism-scan` child both run under `CLAUDE_BIN` (her harness, not stock `claude`) selecting
  from the shared flat state, and `detach_turn_child`'s `setsid` fallback forwards `CLAUDE_BIN`,
  the selected login, and the state file path. The 2026-08-11 fix is currently covered indirectly
  by `test_no_project_memory`, `test_limit_fallback`, `test_sleep_*`, `test_claudism_scan` and
  `test_memory` (all green); this names the dedicated regression the export sites still owe.
