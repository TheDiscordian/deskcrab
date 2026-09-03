# Spec: model backends — one assistant, two engines

## PURPOSE

Every model knob in the system used to name a Claude model, and every launch site assumed the
Claude CLI. This spec makes the engine follow the model name: a Claude-family name runs the Claude
CLI walk exactly as it always has, and an OpenAI-family name (GPT-5.6-Sol at the time of writing)
runs the Codex CLI on the user's logged-in ChatGPT subscription. The assistant is the same being
on either engine — the assembled prompt is what carries her, so the prompt reaches either engine
whole, as that engine's base instructions. The user chooses the engine the same way he has always
chosen anything here: by writing a model name into a knob. No knob is engine-specific; every path
that has a model and an effort knob (turn, wake, dispute, job, chess, the classifiers) accepts
either family.

Codex differs from the Claude CLI in three ways the design has to absorb. Its JSON output is a
different event vocabulary, so a translator rewrites it line by line into the event shapes every
existing reader already consumes — the streamer, the extractor, the token ledger, the self-change
declaration, the refusal detectors — rather than teaching seven readers a second language. It has
one login rather than a numbered account list, so a limit does not walk: it records a cooldown and
falls back to the Claude walk. And it emits nothing between items while it thinks, where the stall
watchdog expects a trickle, so the translator carries a heartbeat.

## CONTRACT

### Routing

1. `model_backend <model>` decides the engine from the model string alone: `codex:*`, `gpt-*`,
   `o` followed by a digit, and `sol` (alone or hyphenated) answer `codex`; everything else
   answers `claude`. An unknown name is a Claude name — the pre-existing behaviour is the default.
2. `codex_model_resolve <model>` maps the knob's spelling to the slug Codex is given: a `codex:`
   prefix is stripped, and `sol` resolves to `CODEX_MODEL_SOL` (default `gpt-5.6-sol`). Every
   codex launch goes through it.
3. Every launch site consults the router; none hardcodes an engine. The sites: the interactive
   turn (`claude_generate`), the wake chain (`wake_claude_run_chain`), the dispute escalation
   (through the turn), the detached builder (`lib/job-runner`), the chess mover and self-play
   (`lib/chess_mover.py`), the classifier (`claude_classify`), and the game player and its
   background rule author ([game-player.md](game-player.md) rule 20). A Claude name on any of
   them MUST take exactly the path it took before this spec existed.
4. Effort passes through unchanged: `low|medium|high|xhigh|max` mean the same word on both
   engines, and Codex additionally accepts `ultra`. On the codex side the value is handed to
   `model_reasoning_effort`. When a codex run falls back to the Claude walk (rule 12),
   `claude_effort_clamp` maps `ultra` to `max` — the Claude CLI would refuse the word.

### The subscription

5. The codex engine MUST run on the logged-in ChatGPT subscription: auth comes from `CODEX_HOME`
   (default `~/.codex`), and `OPENAI_API_KEY` is stripped from the child environment so a stray
   key in the user's session can never silently move her onto metered API billing.
5a. The configured `CODEX_BIN` and `CODEX_HOME` MUST be exported by the shared config layer
   (`lib/common.sh`, right where their defaults are resolved) so every detached child inherits
   the conf's answer: a job's builder session and everything that builder launches, a self-play
   or benchmark driver, and the chess mover's codex subprocess. A child that reads only its
   environment must find the configured engine and login — never the stock `codex` on PATH and
   `~/.codex` by the accident of an unexported shell variable, which is how a conf pointing at
   a dedicated second binary and login home silently authenticates the wrong account.
6. Her sessions load none of the user's own Codex configuration: `--ignore-user-config` keeps his
   `config.toml` (MCP servers, plugins, hooks, trust grants) out of every run — the codex
   counterpart of the empty MCP config — while auth still reads `CODEX_HOME`. Everything a run
   needs is on its own argv.

### The prompt

7. The assembled prompt (`build_system_prompt`) reaches a codex turn or wake WHOLE, as the
   session's base instructions: written to `${STATE_PREFIX}-codex-instructions-<pid>.md` and named
   with `model_instructions_file`. Nothing on the way may truncate or reorder it. This replaces
   Codex's own identity text deliberately — the persona is not to be fought, which is the same
   decision the patched Claude harness made.
8. `CODEX_PROMPT_MODE=preface` is the escape hatch: if instructions replacement misbehaves on some
   future Codex version, the assembled prompt is instead prepended to the user text under a one-
   line frame. The default is `instructions`.

### The run

9. Codex turns and wakes sit under the same stall watchdog and wall clock as their Claude
   counterparts. They carry no DeskCrab-specific read-only mount or write gate. Codex's sandbox
   and approvals are off (`--dangerously-bypass-approvals-and-sandbox`) for these trusted live
   sessions, while `CODEX_HOME` remains the selected profile's normal CLI state. The chess-table
   calls (the mover and table chat, [chessweb.md](chessweb.md) rule 24f) are a separate trust
   boundary: they carry an unauthenticated sitter's text and therefore use Codex's ordinary
   `--sandbox read-only` mode.
10. A codex run reads stdin from `/dev/null` (an open stdin is an invitation Codex accepts), runs
    with `-C` at the same cwd its Claude counterpart uses, and `--skip-git-repo-check` (the
    project directory is not a repository).
11. The stream translator (`lib/codex-stream`) turns Codex's `--json` events into the established
    vocabulary, appended to the same `DEBUGLOG`:
    * one `system`/`init` line when the run begins — the ledger's attempt marker;
    * each `agent_message` becomes a completed `assistant` text event (spoken by the streamer as
      it lands — codex exec has no partial deltas, so speech is per message, the wake path's
      long-standing behaviour);
    * each `command_execution` becomes an `assistant` `tool_use` Bash event carrying the command,
      and each `file_change` a `tool_use` Write event per path — the shapes `stream_written_files`
      and the work trace already read;
    * `turn.completed` becomes a `result` event whose usage maps cached input to `cache_read`,
      cache writes to `cache_creation`, and input net of cache to `input_tokens`;
    * a failure becomes a `result` with `is_error` AND the raw codex line passes through, so the
      refusal detector reads codex's own words;
    * a `deskcrab_note` heartbeat lands at least every 60 seconds while the run is quiet, so the
      watchdog's mtime test never reaps a model that is merely thinking;
    * any line the translator does not recognise passes through verbatim. It never drops a line.
11a. Turns and wakes take the STREAMING road first (`lib/codex-app-stream`): the same binary's
    app-server protocol emits per-token `item/agentMessage/delta` notifications, and the driver
    emits them as the partial-message vocabulary the Claude path already speaks —
    `message_start`, `content_block_start`, `content_block_delta` text deltas, then the completed
    `assistant` event whose close-out voices only what the deltas did not — so speech begins
    while the reply is still being written, on either engine. The assembled prompt rides as
    `thread/start`'s `baseInstructions` (rule 7's file is still written and named, for the
    driver to read); approvals are `never` and any server request is answered with an error at
    once, because a driver that sits on a request is a turn that hangs; the user's own MCP and
    plugin tables are overridden empty on the spawn argv, since
    app-server has no `--ignore-user-config`. Exit 75 — the protocol refused BEFORE any turn
    began — is the only shape that falls through to the exec pipeline of rule 11, and only when
    `CODEX_STREAM_MODE` is `auto` (the default; `app` and `exec` pin one road for tests and
    triage). A turn that started and died is a failed run, never a fallback: falling back after
    real reply text would spend the subscription twice for one question. Rule 12a's structured
    server-capacity failure before any reply text is the exception: tool calls are work, but they
    are not an answer, and the caller owns a retry on the same Codex model. Jobs and classifiers
    stay on the exec pipeline — nobody is waiting on their voice.

### Limits and fallback

12. Codex has one login, so a limit never walks accounts — it falls back to the Claude engine.
    `codex_stream_refusal` judges an attempt's slice the same structural way the Claude detector
    does: codex-owned error text matching `CODEX_LIMIT_RE` AND no genuine output in the slice. On
    a refusal the turn and wake paths record the cooldown, announce the swap in the stream, and
    run the ordinary Claude walk at `CODEX_FALLBACK_MODEL` (default: the loop's own
    `CLAUDE_MODEL`) with the path's own effort clamped per rule 4. A codex run that produced
    genuine reply text NEVER falls back — text may already be on the speakers. The dispute
    machinery's ordinary-model re-run (account-fallback.md rule 10a) is under the same rule: when
    the loop's own model is itself a codex name, that re-run lands on the Claude walk at the
    fallback model, never back on the engine that refused.
12a. A server-capacity failure is NOT a subscription refusal. A structured app-server error whose
    `codexErrorInfo` is `serverOverloaded` is authoritative; the provider's corresponding
    "selected model is at capacity" message is the fallback recognition for the exec transport,
    which does not promise the structured field. When that failure lands before any genuine reply
    text — including after tool calls — a turn or wake MUST wait
    `CODEX_CAPACITY_RETRY_DELAY` seconds, then append a retry of the same request on the same Codex
    model, binary, and login to the same stream. It MUST retry at most `CODEX_CAPACITY_RETRIES`
    additional times and MUST NOT send a capacity retry through the Claude account walk. It MUST
    NOT write the limit cooldown, describe the event as exhausted credits, or allow the provider's
    message into speech, display, conversation, or assistant reply text. Exhausting those retries
    produces no assistant reply; a wake follows its ordinary outage/re-book path. The next
    independent run therefore tries Codex normally. When genuine
    reply text preceded the failure, no second model runs: the genuine text stands and the
    provider error is discarded, so already-streamed speech is never duplicated.
13. A refusal records a cooldown in `codex-state` (in the deskcrab data dir). When the refusal
    text itself quotes a reset time — the wording seen in the wild is
    `try again at Sep 6th, 2026 10:28 PM`: ordinal day, US month-day-year, 12-hour clock, local
    time — that quoted moment IS the cooldown. The recorder parses the FULL refusal text it was
    handed, before its own comment clamp shortens anything, and tolerates the clause appearing
    more than once. The parse is conservative: a clause that does not clearly match, a time not
    in the future, or a time more than a week out is a bad read, not a booking, and each falls
    back to the flat `CODEX_LIMIT_COOLDOWN` window (default 1800 seconds) — the pre-existing
    behaviour, unchanged, which also covers a refusal that quotes no time at all. The state line
    is `blocked-until`, the expiry epoch, the refusal text (one line, at most 200 characters),
    then a trailing marker: `reported` when the epoch is the provider's own answer, `estimated`
    when it is our flat-window guess — so no reader mistakes a guess for a measurement. The
    marker trails on purpose: every existing reader splits the line on TAB and consults only the
    first two fields. While the cooldown stands, `codex_available` answers no
    and every path goes straight to its fallback rather than paying a doomed boot. The cooldown
    MUST be visible in `crab status` beside the account line. Wherever that expiry is RENDERED —
    the status line, the state block, the reason a codex path gives for standing down — a bare
    clock time is only honest for a time later today; a reported expiry can stand days out, so
    any other date MUST be shown with it.
14. A builder job on a codex model that is refused is BLOCKED, never downgraded (specs/jobs.md
    rule 5a holds across engines): the runner records the refusal and the block machinery holds
    and re-dispatches exactly as it does when every Claude account refuses. A genuine failure
    (non-limit) stays a failure, on either engine.
15. The chess mover on a codex model from its own ENVIRONMENT CHAIN tries codex first and,
    refused or cooling, falls through to its own Claude account walk unchanged — a game in
    flight must not stall on a dry engine. A ROUTED model — a real-game job carrying the
    bridge's per-speed offer ([chessweb.md](chessweb.md) rule 16b) — preserves exact model
    identity instead: a routed codex model that refuses, is cooling, or cannot run yields no
    attempt and no substitute of any kind (zero Claude calls); the move stays unplayed and the
    failure is visible through the mover's alert and stall machinery. Same-model Claude
    account rotation preserves identity and stays. Self-play is stricter still
    (chess-selfplay.md rule 15): the selected configuration or nothing.
16. The classifier path routes by the same rule: a codex-named classifier model runs one
    `codex exec` in the sterile cwd and prints the
    answer text; refused or failed, it returns non-zero exactly as a failed Claude classify does.

### The ledger

17. Every codex attempt lands in the token ledger as its own record, model named, usage taken from
    the translated `result` event. The engines share one ledger; `crab metrics` needs no second
    door.

## DATA

| Source | Used by | Notes |
|---|---|---|
| `CODEX_BIN` | every codex launch | default `codex` on PATH, else `~/.local/bin/codex`; exported to every detached child (rule 5a) |
| `CODEX_HOME` | auth, the wrap's writable set | default `~/.codex`; never copied, never symlinked; exported to every detached child (rule 5a) |
| `CODEX_MODEL_SOL` | `codex_model_resolve` | default `gpt-5.6-sol` |
| `CODEX_LIMIT_RE` | `codex_stream_refusal` | liberal on purpose: only codex-owned error text is ever tested |
| `CODEX_CAPACITY_RE` | `codex_stream_capacity` and the speech streamer | fallback recognition when structured `serverOverloaded` metadata is unavailable |
| `CODEX_CAPACITY_RETRIES` | turn/wake capacity retry | additional same-Codex attempts, default 2 |
| `CODEX_CAPACITY_RETRY_DELAY` | turn/wake capacity retry | seconds before each retry, default 1 |
| `CODEX_LIMIT_COOLDOWN` | `codex_limit_record` | seconds, default 1800 — the fallback window when the refusal quotes no usable reset time (rule 13) |
| `CODEX_FALLBACK_MODEL` | turn/wake fallback (rule 12) | default `$CLAUDE_MODEL` |
| `CODEX_PROMPT_MODE` | the run functions | `instructions` (default) or `preface` (rule 8) |
| `CODEX_STREAM_MODE` | `_codex_stream_run` | `auto` (default) / `app` / `exec` — which road a turn or wake takes (rule 11a) |
| `CODEX_APP_HANDSHAKE_TIMEOUT` | `lib/codex-app-stream` | seconds before an unanswered handshake reads as protocol-unavailable, default 30 |
| `codex-state` (data dir) | `codex_available`, `crab status` | the cooldown record — rule 13's four-field line |
| `${STATE_PREFIX}-codex-instructions-<pid>.md` | rule 7 | the assembled prompt, per run |

## INTERACTIONS

**The router is consulted by:** `claude_generate`, `wake_claude_run_chain`, `lib/job-runner`,
`lib/chess_mover.py`, `claude_classify` — and nothing else decides engines. Conversation
compaction invokes `claude_classify` with Sol first, then uses the ordinary Claude outage walk if
that one codex attempt fails.
**The translator is run by:** the codex run functions only, outside the wrap, reading the wrapped
CLI's stdout.
**The account-fallback machinery** (specs/account-fallback.md) is untouched: codex is not an
account on the list, and `claude_limit_record` never hears about a codex refusal.

## TESTS

`tests/test_model_backends.sh` — the router's answer for both families and the aliases; the
translator fed canned codex event streams (answer, commands, file changes, a failure, a limit)
asserting the exact claude-shaped lines out and that unknown lines pass through; the refusal
detector on a limit slice, a genuine-output slice, and a plain failure; the turn and wake
fallback walking to the stub Claude CLI after a stub codex refusal, with the cooldown recorded
and visible; the builder blocked, never downgraded; effort clamp on fallback; the wrap argv
carrying `CODEX_HOME` writable; the instructions file written whole; the streaming road (rule
11a) against a stub app-server — the partial-message vocabulary in the stream with the deltas'
text extracted whole, the completed assistant behind them, usage on the result; a broken
app-server falling through to the exec pipeline with the note on the record, in auto mode only;
`CODEX_STREAM_MODE=exec` pinning the old road; and the exact structured `serverOverloaded` event
after a tool call, proving both turn and wake retry the same Codex model, never enter the Claude
walk, write no Codex limit cooldown, and extract only the successful retry's answer.

`tests/test_limit_expiry.sh` — rule 13's expiry, both recorders (`lib/common.sh` and
`lib/memory.py`): the wild refusal sentence parses to the provider's own epoch and records it
with the `reported` marker; a refusal quoting no time, a quoted time in the past, one beyond the
week cap, and a clause truncated mid-time each fall back to the flat window with the `estimated`
marker; the clause appearing twice still parses; and the four-field line still reads through
`codex_limit_until` and `codex_cooling_until` — honoured while it stands, ignored once expired.
