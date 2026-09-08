# OpenRSC periodic self-review

## Purpose

The periodic reviewer is the playing assistant examining and improving her own player.
It complements the fast player and event-driven reflex author with a deliberate check of
objective progress, training efficiency, and the correctness of the whole gameplay stack.

## Contract

1. The player control unit starts `deskcrab-openrsc-review-watch.service` as part of gameplay.
   This mechanical watcher arms the 45-minute timer only while the control unit is active with no stop/restart pending,
   the sitting is open and before its deadline, and the client has a fresh logged-in snapshot
   (at most ten seconds old). It stops the timer and any review when those conditions cease.
   The watcher stops with the player control unit; it has no independent startup registration.
   UTC calendar expressions cover all 32 daily slots at a uniform interval. The timer is never
   enabled globally and has no persistent catch-up. Its ordering follows the gameplay services,
   with explicit shutdown cleanup instead of the default ordering before `timers.target`. Starting a review or timer cannot start play.
   Both scheduled and direct review launches check eligibility before creating artifacts or
   touching the author, recheck after waiting for the author and immediately before the model,
   and check once per second to cancel a running model when play ends.
   Missing, malformed, ended, expired, stale, or logged-out state fails closed. An existing
   review is not interrupted or overlapped at the next slot.
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
   For leaderboard competition, optimise the method within the committed skill until its
   concrete rank/rival milestone is verified complete. Level-ups and periodic reviews do not
   release that commitment, even when another skill offers a cheaper total level. A change of
   target before completion requires a user redirect or a documented blocker that prevents
   progress; supplies, recovery, and prerequisites remain part of the same target. Sitting
   expiry pauses the commitment. Previous reports cannot override this current policy.
   Inventory efficiency follows [game-loadout.md](game-loadout.md): audit every retained item's
   current purpose, excess food/equipment, missing tools, and actual batch capacity. Old combat
   reserves and old plan wording are not current risk evidence. Repair the inventory and any
   recurring rules that recreate the waste, and verify the resulting item counts.
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
   send chat/notifications, or produce audio. Reviews perform no offline work and cannot
   start a sitting. Interrupted work remains recorded for the next eligible pass.
7. Each attempt saves its prompt, raw stream, stderr, before/after snapshots, result, and
   status below `OPENRSC_REVIEW_DIR` (default the player's `reviews/` directory). `latest.json`
   shows waiting, running, completed, cancelled, or failed; `last-success.json` advances only when the CLI
   succeeds, emits a completed turn without an error, and returns all three assessments,
   changes, verification, and next-review observations. Partial work and failures remain visible.
   The translated stream is recorded in the ordinary token ledger as `openrsc-review`.
   The service's `ExecStopPost` recovers the author watcher after an unexpected process death,
   marks an unfinished attempt failed, and never interferes with a live review or stopped sitting.
8. The review entrypoint, paths, CLI, and deadline are overridable for the standard sandbox.
   Tests cover real launcher routing, persona and evidence, author exclusion, duplicate runs,
   failed/partial CLI output, deadline cleanup, and preservation of the last successful report.

## Operations

Install the review service, watcher service, timer, and player-control drop-in from `systemd/`
into the user manager, then reload it. The control unit starts the watcher automatically.
Keep the timer disabled; the watcher alone starts and stops it according to actual gameplay.
For an already-running sitting, start the watcher once after installation.
`systemctl --user start deskcrab-openrsc-review.service` requests an immediate pass only during
eligible play. `lib/openrsc-review status` reads the saved status without a model call.
Stopping the watcher stops its timer and any review; stopping gameplay stops all three.
