# OpenRSC hourly self-review

## Purpose

The hourly reviewer is the playing assistant examining and improving her own player.
It complements the fast player and event-driven reflex author with a deliberate check of
objective progress, training efficiency, and the correctness of the whole gameplay stack.

## Contract

1. `deskcrab-openrsc-review.timer` runs once an hour, with persistent catch-up after downtime.
   Its oneshot service and a nonblocking process lock prevent overlapping reviews. A review
   has a 50-minute total deadline, including waiting for the existing author's lock.
2. `lib/openrsc-review` reads the assistant's ordinary config. The reviewer uses only
   `gpt-6-astra` with `model_reasoning_effort=high` through the configured `CODEX_BIN` and
   `CODEX_HOME` ChatGPT login. It strips API-key credentials, ignores the coding agent's
   user config and project instructions, and never falls back to a different model or effort.
   The fast player's and reflex author's model settings are independent and unchanged.
3. Every invocation reads the same persona selection as game-player rule 18 and starts a
   fresh review conversation. A missing persona fails visibly instead of silently reviewing
   as somebody else. The prior successful report and before/after evidence carry continuity.
4. The prompt requires three grounded assessments: progress against the current objective's
   authoritative measure; whether the method is probably the most efficient available for
   the current skill, levels, supplies, and objective; and whether reflexes and their supporting
   code actually produce the intended state changes. Compare measured XP and activity history
   with the previous review. Check this server's mechanics and include travel, supplies, banking,
   failure, fatigue, and recovery costs when comparing methods. State uncertainty when samples
   are short, stale, offline, or incomparable; do not present theoretical XP as measured XP.
5. The reviewer may implement, test, and deploy improvements to rules, harness, player code,
   client integration, prompts, method, plan, and objective. It may replace a completed or
   unsuitable objective while preserving explicit user constraints and the larger intent.
   A review that discovers a fix must perform the authorised work instead of merely advising
   the user to poke the player. Use ordinary objective/progress/plan/steering and rule mutation
   doors, preserve current state, and verify the running result. Read repository instructions
   and change the relevant spec before code. Commit only its own source changes; never publish
   unrelated ancestry, private data, or push to an upstream it does not own.
6. The reviewer suspends the author's path watcher, lets an existing author finish by waiting
   on `author.lock`, and holds that lock throughout its pass. This prevents repeated path
   activations against a busy lock. On exit it restores the watcher and drains queued outcomes
   only if the player control unit still authorises the sitting. The normal player and
   survival reflexes continue. Use atomic rule mutation doors and re-read live state before
   changing a plan, so concurrently completed work is respected. Coordinate deployment using
   the player/harness's supported controls and steer the continuing player after a material
   change. Never leave the character logged in without survival guards. Do not bypass the
   game's mechanics, edit server/save data, reopen a closed sitting, alter other projects,
   send chat/notifications, or produce audio. An offline review can fix grounded defects but
   does not start a sitting or claim live verification.
7. Each attempt saves its prompt, raw stream, stderr, before/after snapshots, result, and
   status below `OPENRSC_REVIEW_DIR` (default the player's `reviews/` directory). `latest.json`
   shows waiting, running, completed, or failed; `last-success.json` advances only when the CLI
   succeeds, emits a completed turn without an error, and returns all three assessments,
   changes, verification, and next-review observations. Partial work and failures remain visible.
   The translated stream is recorded in the ordinary token ledger as `openrsc-review`.
8. The review entrypoint, paths, CLI, and deadline are overridable for the standard sandbox.
   Tests cover real launcher routing, persona and evidence, author exclusion, duplicate runs,
   failed/partial CLI output, deadline cleanup, and preservation of the last successful report.

## Operations

Install the service and timer from `systemd/` into the user manager. Enable the timer only
when hourly reviews are authorised. `systemctl --user start deskcrab-openrsc-review.service`
runs a pass immediately. `lib/openrsc-review status` reads the saved status without a model call.
Stopping the timer prevents future reviews; stopping its service also interrupts the current pass.
