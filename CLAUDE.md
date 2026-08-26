# DeskCrab

A push-to-talk desktop assistant for Linux, powered by the Claude Code CLI. The assistant is named
"Crab" by default; `ASSISTANT_NAME` in the config renames it.

**Start here:** [`specs/README.md`](specs/README.md) is the contract. This file is orientation.

## Repo rules

- **Never `git add -A`.** Several sessions run at once and edit the same files; `-A` in one hand
  stages whatever the other has open. Stage explicitly: `git add -- <paths>`.
- **Never `git commit --amend`** on a branch anyone else is on. Add a new commit.
- **Commit messages are prose**, in the style of the existing log: what changed and why it had to.
- **No personal data in any committed file** — no names, locations, usernames or server names, in
  code, docs, or commit messages. Write "the user". This repo is public.
- **A behaviour change starts with a spec change**, in the same branch, before the code.
- **Speed is the top priority.** Someone is waiting for a spoken reply.
- **The core system prompt stays generic.** Personal content belongs in the user's `CUSTOM_PROMPT`
  file, which is not in this repo.

## Project structure

| Path | What it is |
|---|---|
| `crab` | entry point: subcommands, or any other text as a query |
| `crab-debug` | live stream viewer |
| `lib/common.sh` | the library: prompt, generation, conversation, delivery, sessions |
| `lib/wake-queue.sh` | the only module that touches the wakes directory and wake units |
| `lib/nightly-judge` | the night judge's one walk: every sleep judgment call, both engines, no fallback |
| `lib/tts-streamer` | speaks the stream sentence by sentence as it is written |
| `lib/sentence_stream.py` | the sentence chunker and replay registry both voices share (desk streamer, phone server) |
| `lib/browser_voice_queue.js` | the browser clip queue both pages load (phone voice, chess table clips): one playback discipline, policy stays on the page |
| `lib/extract-response` | pulls the reply out of a finished stream log |
| `lib/codex-stream` | translates `codex exec --json` events into the stream vocabulary every reader here consumes |
| `lib/transcript-dedup` | collapses whisper-stream's overlapping-window repeats |
| `lib/serve.py` | stdlib HTTP front end for the phone (`crab serve`) |
| `lib/webapp/` | the phone client: one page, a manifest, a service worker |
| `lib/webpush.py` | Web Push: RFC 8291 crypto, RFC 8292 VAPID, subscription store |
| `lib/midturn-mail` | PostToolUse hook: hands a running turn the messages queued behind it, between two tool calls |
| `lib/gen-cert` | self-signed TLS material for the server |
| `lib/memory.py` | vector store (`crab memory`): sqlite-vec plus local ollama |
| `lib/eng` | the record spine: engineering records (`crab eng`) and wants (`crab want`), threads with state, the prompt block, the job hook's date test |
| `lib/tiredness` | the unread-pile score (`crab tired`): file facts in, one number and word out |
| `lib/token_ledger.py` | the durable token ledger (`crab metrics`): one record per CLI attempt, parsed from the stream it wrote |
| `lib/job-runner` | detached builder, owned by systemd rather than by the turn |
| `lib/job-status` | JSON state sidecars for detached jobs |
| `lib/job-collect` | after a run: the branch, commits, tests and verdict, onto the sidecar |
| `lib/job-log-stream` | turns a builder's live stream into the human job log as it is written |
| `lib/promise-audit` | did the reply state a want that is not on the shelf? |
| `lib/promise-check` | did the reply promise an action the turn's tool record never performed? |
| `lib/chore-scan` | the one detector of work handed to the user: the delivery chore gate and the record ending gate both read it |
| `lib/notice-newfiles` | emitter: files landing in a watched directory become a wake |
| `lib/notice-selfchange` | emitter: another hand changed the files that constitute her |
| `lib/canary-selfchange` | proves that watcher is still being triggered at all |
| `lib/shelf-check` | the nightly shelf-line measure: an over-long wants line is named, never rewritten |
| `lib/sleep-nightly` | the nightly memory ingest, and its rot check |
| `lib/claudism-scan` | the nightly claudism review: one journal day in, a report with rewrites and counts out |
| `lib/claudism-corpus` | the same scoring run by hand over an archived transcript directory, bucketed by date |
| `lib/day-journal` | the durable per-day record of every finished turn |
| `lib/empty-mcp.json` | the empty MCP config her sessions run against |
| `systemd/` | user units: wake, restore, sleep, canary, watchers, server |
| `specs/` | the contract |
| `docs/` | engineering history |
| `tests/` | the suite; `tests/lib/sandbox.sh` is the only way in |
| `tools/` | the CLI context probe and its measured results |
| `*.example` | configuration templates |

## The contract — specs/

Read the spec before changing the subsystem. [`specs/README.md`](specs/README.md) carries how specs
work here, the defect identifiers, the data-flow graph, and the lock table.

| Spec | Covers |
|---|---|
| [turn-pipeline](specs/turn-pipeline.md) | one turn: capture, ordering, delivery, the conversation store |
| [prompt-assembly](specs/prompt-assembly.md) | one assembler, four profiles, layer order, budgets, intent cases |
| [self-awareness](specs/self-awareness.md) | the state block: totals, provenance, the arithmetic rule |
| [wake-queue](specs/wake-queue.md) | booking, records, restore, tidy, the roster of autonomous bookers |
| [jobs](specs/jobs.md) | detached builders: dispatch, sidecars, blocked versus failed |
| [speech-output](specs/speech-output.md) | extraction, display split, the streamer, the mutex, never-silent |
| [debug-view](specs/debug-view.md) | which logs the viewer follows, and what it may never drop |
| [phone](specs/phone.md) | the server and the PWA: turns, the watch cursor, voice, auth, push |
| [memory-recall](specs/memory-recall.md) | query composition, retrieval, the recall block, reinforcement |
| [engineering-records](specs/engineering-records.md) | threads with state: the record format, `crab eng`, the prompt block, the job hook |
| [wants](specs/wants.md) | the wants drawer: want records over the record spine, the shelf, `crab want`, migration |
| [account-fallback](specs/account-fallback.md) | the flat numbered account list, selection and cooldowns, refusal detection |
| [model-backends](specs/model-backends.md) | the engine follows the model name: Claude names take the account walk, codex names run the ChatGPT login, limits fall back |
| [metrics](specs/metrics.md) | the token ledger: per-attempt records, backfill, `crab metrics`, the phone metrics page |
| [nightly](specs/nightly.md) | sleep, tidy, the self-change watcher, and its canary |
| [test-harness](specs/test-harness.md) | the one sandbox, four isolation gates, the coverage owed |

## Everything else

- [`docs/history.md`](docs/history.md) — the dated incidents and rejected designs behind the rules.
  Read it before deleting something odd-looking. Memory, not contract: where it and a spec disagree,
  the spec wins.
- [`tools/context-probe-results.md`](tools/context-probe-results.md) — measured context cost per CLI
  flag combination, and CLI-version-specific. Re-measure after an upgrade.

## Live integration

**Config**, neither file in this repo: `~/.config/deskcrab/deskcrab.conf` (path overridable with
`DESKCRAB_CONF`) and the persona sheet `CUSTOM_PROMPT` points at.

**Deployment is by symlink.** `~/.local/bin/crab`, `~/.local/bin/crab-debug` and
`~/.local/lib/deskcrab` point at this checkout, so an edit here is live immediately — never edit the
`~/.local/bin` copies. `claude` must be on `PATH` or in `~/.local/bin`.

**systemd user units** live in `systemd/` and install by copying to `~/.config/systemd/user/`. They
ship disabled: enabling one changes how the machine behaves towards its user, which is their call.

**State.** `$STATE_PREFIX-*` (default `/tmp/deskcrab-*`) is ephemeral: conversation, stream logs,
locks, live records. `~/.local/share/deskcrab/` is durable: wakes, jobs, journal, memory, archive,
account state, webpush. `~/.local/state/deskcrab/` holds watcher logs and archived streams.

**Scratch instance.** Every path that could reach the live instance is overridable, and the test
sandbox pins all of them: `DESKCRAB_CONF`, `DESKCRAB_STATE_PREFIX`, `DESKCRAB_PIDFILE`,
`DESKCRAB_MEMORY_DIR`, `WAKES_DIR`, `JOBS_DIR`, `DAY_JOURNAL_DIR`, `ACCOUNT_STATE_FILE`, the XDG
homes. Two gates refuse the user manager when the wakes or jobs directory is not the live one;
`DESKCRAB_ALLOW_SCRATCH_BOOKING=1` is the opt-in for a harness that has stubbed `systemd-run`. Every
detached child must inherit the whole set.
