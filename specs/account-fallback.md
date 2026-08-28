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

7. A run uses the current account when it is not in cooldown for the run's model. On a limit
   refusal, the refused account's cooldown is set (rules 8 and 8a) and the current advances to
   the next account NOT in cooldown **for the refusing walk's model**, wrapping past the end of
   the list. The new current stays current until IT refuses in its turn: no switch-back, and no
   probing an account inside a cooldown that covers the walk's model. An account whose cooldown
   has lapsed becomes selectable again, but is only reached when a refusal walks the selection
   onto it. There is still exactly ONE current pointer, shared by every model: a walk whose
   model a cooldown does not cover simply filters that cooldown out when it reads the state, so
   a fable refusal that routes the current onto a fable-alive, opus-dead account costs an opus
   walk nothing — its own filter skips it (rule 10).
8. Cooldown length follows the refusal kind: a rolling session limit cools for
   `ACCOUNT_COOLDOWN_SESSION` (default five hours, the window the CLI's own refusal names); a
   usage-credits or otherwise hard stop — credit balance, extra usage, a weekly cap, a login that
   needs a human — cools for `ACCOUNT_COOLDOWN_CREDITS` (default twenty-four hours). Both are
   knobs. An unrecognised refusal wording takes the short cooldown: too eager costs one refused
   boot hours later and corrects itself; too patient benches an account that came back at lunch.
8a. Cooldown SCOPE is a second, orthogonal classification of the same refusal text: every
    cooldown record carries a scope — `all`, or one model family. A refusal that NAMES a model
    ("reached your Fable 5 limit", "out of usage credits. Run /usage-credits to keep using
    Fable 5", "Opus weekly limit reached") cools that account FOR THAT MODEL FAMILY ONLY, with
    the family normalised from the wording — model-name presence WINS, even when the wording
    also matches a weekly or usage phrase, because a limit the CLI attributes to one model is
    that model's allowance whatever clock it runs on. Only a wording naming NO model ("hit
    your session limit", "session limit reached", "5-hour limit", "usage limit reached", a
    model-less weekly cap, a login that needs a human, a generic "out of usage credits") cools
    the account for ALL models. The text this classification reads MUST be the CLI's whole
    owning refusal line, never the limit signature's matched substring: the signature's
    leftmost alternative can land ahead of the model name in the same line — in "You're out of
    usage credits. Run /usage-credits to keep using Fable 5" the match is "out of usage
    credits" — and a scope read off the match alone carried no model name, classified as
    `all`, and benched the account for every model for twenty-four hours, re-creating the
    incident this rule exists to prevent. The distinction exists because the
    premium model is a PER-ACCOUNT allowance cut before the account's other capacity: on
    2026-08-15 an overnight selfplay burn drained every account's premium pool, the model-blind
    cooldowns benched the same accounts' perfectly healthy ordinary capacity, the surviving
    accounts absorbed every walk and hit genuine session limits, and by morning a conversation
    turn died over "every login is over its limit" while the ordinary model worked fine on all
    three. One model's drought MUST NEVER bench another model's healthy capacity. A record
    without the scope field reads as `all` (back-compat; every pre-scope record was).
8b. An account may cool under several scopes at once — a 24-hour model-scoped credits stop and a
    5-hour account-wide session limit are both real, and neither may shorten the other. Records
    are kept per account AND scope; for a given model, an account is selectable only when every
    covering record (scope `all` or the model's family) has lapsed.
9. The selection is NEVER empty. When every account is in cooldown for the walk's model, the one
   whose covering cooldowns end soonest is offered, alone. A run always has an account to try.
10. A walk KNOWS ITS MODEL, and returns every account selectable for it — skipping only
    cooldowns scoped `all` or that model's family — in list order rotated to start at the
    current, and rides each refusal to the next entry — recording each refusal, with the walk's
    model, as it goes — failing only when every offered account has refused. Every walk site
    passes its model: the desk turn and the phone turn (the generation model, dispute-raised
    when it was), the wake, the job runner, the summariser, the promise audit and the promise
    checker, the night-work classify (its primary model), and the two Python walkers (the
    memory store's ingest and judge, the chess mover) — same shared state file, same filter
    rule. A selection asked with NO model (the status line, the child-login seed) treats every
    unexpired cooldown as blocking, whatever its scope: the conservative pre-scope read, for
    callers that are not about to boot any particular model.
10a. **A conversation turn MUST NEVER die because the premium model is dry while the ordinary
    one works.** When the dispute machinery raised the turn's model above `CLAUDE_MODEL`
    ([dispute-turn.md](dispute-turn.md) rule 7) and the walk exhausts with every offered account refusing at
    the dispute model, the turn re-runs the walk ONCE at `CLAUDE_MODEL` / `CLAUDE_EFFORT`, with
    the dispute frame still in the prompt. The swap is announced like any other: a marker in the
    stream names it ("dispute at the ordinary model — the premium one is dry everywhere") and
    the desk notification says the same. The fallback fires at most once per turn, only when the
    dispute model actually differs from `CLAUDE_MODEL`, only when the whole walk was refused —
    never on a genuine answer, an ordinary failure, or a walk the wall clock abandoned. The
    turn's wall-clock deadline is asked again immediately before the fallback walk boots: a
    deadline that lapsed while the raised walk was refusing SKIPS the fallback — the turn
    reports the outage it measured rather than booting a walk it has no time to hear. It is a
    TURN rule and nothing else's: a builder job's model is never downgraded
    ([jobs.md](jobs.md) rule 5a stands, pinning test and all).
11. Every move of the current MUST be recorded: the state file says where the selection stands and
    why it last moved (naming the model family when the cooldown is scoped to one); the
    append-only account log says what it has been through. `crab status` and the state block MUST
    lead with which account answers next, by number, and why the state last moved. See
    [self-awareness.md](self-awareness.md) rules 16 to 18. The account log's session-kind column
    MUST name the real path that recorded the refusal: a detached builder writes `job`, the
    night-work classify writes `night-work` — never a defaulted "session", which is how
    the 2026-08-15 morning's builder refusals hid among the interactive ones.

### Detecting a refusal

12. A refusal MUST be recognised only by the CLI's own synthetic marker plus a limit signature, and
    only for a stream with **no genuine model output**. A network failure would fail every other
    login too and MUST surface as itself. A PER-ACCOUNT authentication death is not that: a login
    is per-account by definition — "Not logged in" has carried this argument since 2026-08-07, and
    "Failed to authenticate: OAuth session expired and could not be refreshed" joined the signature
    on 2026-08-24. On 2026-08-20 the walk read that OAuth line as an outage that would follow it to
    every login, broke without rotating, and the extractor's error-only fallback delivered the
    CLI's words as her written reply on the phone and committed them as the conversation summary,
    while the other logins answered fine the whole time. An auth-dead account rotates exactly like
    a limit refusal: it cools, the current moves, and a walk that exhausts every login is a failed
    run (rule 12c) — never a reply.
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
    flat list by the same rule, passing its own model (rule 10). The two Python walkers (the
    memory store, the chess mover) read the shared state and skip accounts cooling for their
    model — a record scoped to another family does not bench them, and a record without the
    scope field reads as `all` (rule 8a) — and are read-only: recording a refusal is the
    shell paths' job. The model-family roster itself has ONE spelling: `CLAUDE_MODEL_FAMILIES`
    in the shell library, exported to every child as `DESKCRAB_MODEL_FAMILIES`. The Python
    walkers MUST prefer that variable and keep their baked copy only as a last resort for a
    walker started outside the shell paths (the chessweb service) — three hand-maintained
    spellings of the same list is how one of them silently stops recognising a family the
    others learned. Both MUST tilde- and variable-expand every account directory — the
    configured list's entries AND the state file's — before it is matched or handed out:
    systemd's `EnvironmentFile` hands values through unexpanded where every shell path expanded
    them on the way in, and an unexpanded `$HOME/...` handed to `CLAUDE_CONFIG_DIR` names an
    empty login that answers "Not logged in" while the real account sits logged in — and would
    break the state-file match too, wedging the walk onto a dead login (2026-08-11, the chess
    mover; [chessweb.md](chessweb.md) rule 16e carries the incident).
30. The summariser MUST capture standard error on both engines. Sol is attempted once; a capacity
    refusal records the codex cooldown and the Claude outage walk composes continuity without ever
    persisting the refusal text.
31. A refusal MUST NEVER be committed as a summary. See [turn-pipeline.md](turn-pipeline.md) rule 27.

## DATA

| Path | Format |
|---|---|
| `~/.local/share/deskcrab/account-state` | one `current` line: `current \t number \t dir \t epoch \t why`; one `cooldown` line per cooling account and scope: `cooldown \t number \t dir \t until-epoch \t kind \t scope` — scope is `all` or a model family, and a line without the field reads as `all` (rule 8a); override per instance via `ACCOUNT_STATE_FILE` |
| `~/.local/share/deskcrab/account-log` | append-only: epoch, from number, to number, reason, session kind (the real path's own name — rule 11) |
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
- **A refusal is detected only for a stream with no genuine model output.** Network failures must
  surface as themselves; a per-account authentication death (a login that needs a human, an OAuth
  session that could not be refreshed) rotates like any refusal (rule 12).
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
"fallback". Holds the 2026-08-15 model-scope rules too: the scope cases are driven through the
pipeline's own composition — the wording goes into a captured stream, `claude_stream_refusal`
judges it, and whatever THAT printed is what the scope read gets, because a hand-fed full line
once green-washed a detector that was printing only the signature's matched substring; a
model-naming refusal writes a scoped cooldown that leaves the same account selectable for a walk
at another family — including the verbatim credits-with-model line, whose signature match lands
ahead of the model name, ridden through the wake chain to a fable-scoped cooldown that a
following opus walk never pays for — while a model-less session-limit wording blocks every
family, and a model named inside a weekly or session wording wins the scope (kind untouched);
the incident's ping-pong pinned end to end — a
premium-model refusal moves the current, and the ordinary-model wake that follows answers on its
FIRST boot, paying zero extra; a model-less selection still treats every cooldown as blocking;
per-scope records stack without shortening each other; an old-format record without the scope
field parses as `all`; the walk's own wholly-refused record (`WAKE_CHAIN_ALL_LIMITED`) is set by
an every-attempt-refused walk and NOT by a mixed one whose last attempt died on the network; the
dispute fallback (rule 10a) fires exactly once, only when every
offered account refused at the raised model, never on a genuine answer, never on the job
path, and never past the turn's wall clock — a deadline that lapsed during the raised walk
skips the fallback with the skip named in the stream; the family roster reaches
`claude_model_family` from `CLAUDE_MODEL_FAMILIES` and both Python walkers from
`DESKCRAB_MODEL_FAMILIES`, with their baked list standing only when the environment carries
nothing; and the rebook delay (wake-queue.md rule 23a) honours the soonest expiry covering the
wake's model.
`tests/test_wake_limit_cut.sh` — the wake path end to end in the sandbox: a walk that ends cut
journals a failed run naming the session limit, writes nothing to the conversation, and re-books
through the outage-retry path; a walk with credit left delivers the later account's reply and
re-books nothing; and a mixed walk — a cut, then a network death on the next login — re-books on
the ordinary outage slot, never the drought's cooldown-keyed wait.
`tests/test_convo_compaction.sh` — the summariser uses Sol for continuity, records a Sol capacity
refusal, and falls through without persisting provider text; on the Claude path, a summary whose
text contains the signature's words is still committed as genuine output, while a synthetic
refusal skips compaction, keeps every turn, and records the refusal.
`tests/test_memory.py` — the turn-end judge walks the list: a refused account moves to the next and
the judgement lands, an entirely dry list skips the judgement and names it in the judge log, and a
failure that is not a refusal spends no second account.
`tests/test_job_block.sh` — a detached child inherits the state and the signature, not only the
login, so it can walk past an account that went dry between dispatch and run.
`tests/test_turn_watchdog.sh` — the interactive walk is bounded, and a swap is announced: marked
in the stream log on every path, notified on a turn, silent on a wake.
`tests/test_nightly_harness_routing.sh` — the three out-of-band export sites of the 2026-08-11
audit, offline, each child a stub that photographs its environment: `crab memory` hands
`lib/memory.py` the harness (`CLAUDE_BIN`), the configured list, the one shared limit signature,
and the shared state file path, and re-seeds `CLAUDE_CONFIG_DIR` to the account the selection
answers with rather than the environment's leftover; `lib/sleep-nightly` seeds its direct
children — the `claudism-scan` rewrite pass stands in — the same way; and `detach_turn_child`
names the selected login explicitly in its systemd-run argv and forwards the whole set through
its `setsid` fallback — on both branches, account 1 included, with nothing configured and no
state on disk (rule 3).
