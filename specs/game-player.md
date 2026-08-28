# game-player — learned rules are the primary play path

## PURPOSE

Deliberate play can write verified actions down as prose — triggers like "tutorial cooking
instruction needed" in `learned-actions.json` — and
prose is not runnable: every sitting re-read the notes and spent a reasoning turn re-deciding what
the notes already knew. This layer makes the learned knowledge executable. A durable table of
trigger+action rules, written by the deliberate hand at the moment a play verifies, is evaluated
against the live bridge snapshot **before any model reasoning**; when a rule matches, its action
goes through the bridge mechanically, and the model is consulted only when no executable rule
applies or a rule needs refinement. The playing loop becomes: rules first, reasoning as fallback —
the same shape the chess reflex layer already proved.

This is the deliberate-play channel of specs/game-reflex.md, not a second reflex engine: the
engine machinery is literally `lib/game_reflex.py`'s — the same priority competition, cooldowns,
debounce, one receipted action in flight, pacing caps, stale/logged-out protection and hold
override, invoked with this layer's own trigger and action vocabulary plugged in. What
game-reflex forbids its rule table (starting conversations) this channel owns, because an action
file written by the player's own hand or harness is exactly what rule 5 there means by the
deliberate-play channel.

## CONTRACT

### Files and places

1. The durable table is `$DESKCRAB_GAME_DIR/learned-rules.json`; the current objective is
   `$DESKCRAB_GAME_DIR/objective` (one line, empty or absent meaning none). The engine's own
   counters live in `$DESKCRAB_GAME_STATE_DIR/player-engine-state.json` and its decisions in
   `$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl` — separate files from the reflex engine's,
   because the two engines are tuned and audited independently. The exchange files
   (`state.json`, `action.json`, `receipt.json`, `hold`) are game-reflex rule 1's, shared:
   there is ONE bridge and one action slot. Every write is atomic per game-reflex rule 2.

2. The implementation is `lib/game_player.py`, stdlib only, invoked as
   `python3 …/game_player.py <command>`; it imports `lib/game_reflex.py` and calls its
   `evaluate` — the reuse is structural, not a copy. No model call is ever made anywhere in this
   module; that is what makes rules-first honest.

### The rule table

3. `learned-rules.json` holds `defaults` (`stale_ms` 2000, `min_action_interval_ms` 600,
   `max_actions_per_min` 20, `inflight_timeout_ms` 3000), `rules`, and `unfinished`. Each rule:
   `name` (unique, lowercase-dash), `enabled`, `priority` (higher wins), `cooldown_ms`,
   `hold_ticks`, `once_per_objective` (optional, default false), `note` (optional provenance —
   when and how the play verified), `trigger` (named conditions, all must hold), `action`
   (`type` plus parameters). Unknown keys, triggers, actions and out-of-range values are refused
   loudly at load and by every mutating command — a rule that cannot be evaluated must not sit
   in the table looking armed.

4. The trigger vocabulary is closed and every condition is answerable from the bridge snapshot
   or this layer's own durable objective — nothing here triggers on a screenshot or a guess:
   - `objective_is` (string): the objective file's line equals it exactly. A rule carrying
     `objective_is` can never fire while no objective is set.
   - `npc_visible` (int): the snapshot's `npcs` list holds that type id.
   - `object_visible` (int): the snapshot's `objects` list holds that type id.
   - `bound_visible` (int): the snapshot's `bounds` list holds that type id.
   - `message_contains` (string, non-empty, single-line): some message in the snapshot's
     `messages` contains it, case-insensitively.
   - `near_tile` (`{"x":…,"z":…,"radius":…}`): Chebyshev distance from the player's tile is at
     most `radius` (0 ≤ radius ≤ 50). Evaluation applies an effective floor of 2: a stored
     radius below 2 evaluates as 2, and rule 17's lint refuses to author one. The trigger names
     the vicinity; rule 7a's verification owns the exact destination.
   - `inventory_has` / `inventory_lacks` (int): an item of that id is / is not in the inventory.

5. The action vocabulary is closed: `talk-npc` (`npc`: the type id; the server index is resolved
   from the snapshot at fire time — nearest matching NPC — and both ride the action file exactly
   as game-reflex rule 6 defines, so the bridge's despawn/mismatch re-checks still protect the
   click), `walk` (absolute `x`/`z`, **unclamped** — deliberate travel crosses the map, and
   the game's own pathing already decides reachability; the 15-tile clamp is a reflex-channel
   rule about panic moves, not a bridge property; optional `arrive`, 0–10 defaulting to 1, the
   Chebyshev tolerance rule 7a's verification accepts as arrival), `interact-object` (`obj`: the object type id,
   optional `cmd` 1 or 2 defaulting to 1 — the nearest matching entry in the snapshot's
   `objects` list is resolved at fire time and its tile rides the action file, so the bridge's
   unloaded/swapped re-checks protect the act; this is how a door-less fishing spot is fished
   and a gate is opened), `interact-bound` (`obj` and optional `cmd`, resolved the same way
   from the snapshot's `bounds` list, tile and wall direction riding the file — this is how a
   door is opened), and `click-entity` (`kind`: `npc`, `object`, or `bound`; `entity`: its type id;
   optional `button` 1, 2, or 3 defaulting to 1). At fire time the nearest matching snapshot entry
   is compiled to stable game identity — NPC server index and type, or object/bound type and world
   placement — while screen coordinates are deliberately absent. The bridge re-matches that
   identity and resolves the entity's latest rendered point immediately before moving and clicking,
   so a moving NPC cannot leave a screenshot coordinate behind), and `click-inventory` (`item`:
   the item id; optional `button` 1, 2, or 3 defaulting to 1). The compiled inventory action carries
   only that item identity. The bridge finds its current slot, opens the inventory tab, and resolves
   the slot centre immediately before clicking; a missing item is refused instead of allowing a
   remembered slot to target its replacement. Everything the bridge refuses stays refused;
   nothing in this layer can log in, spend, trade or message a player, and screen-space clicks
   that do not name a rendered game entity or current inventory item remain structurally outside the vocabulary — an action
   that cannot be expressed here belongs in `unfinished`, not approximated.

6. `unfinished` is the honesty ledger of migration: entries (`name`, `note`) for learned plays
   whose trigger or action cannot yet be grounded in rules 4–5 — camera-dependent screen
   presses, scenery the bridge does not expose. They are listed by `rules`, never evaluated,
   and never silently promoted; graduating one requires the vocabulary to grow by spec change.

### Evaluation

7. `step` is one rules-first evaluation: read the snapshot, evaluate the table through
   `game_reflex.evaluate` with this layer's trigger and compile functions, emit at most one
   action into the shared `action.json` slot, await the receipt (up to
   `inflight_timeout_ms`), and report one line on stdout: `<verdict> key=value…`. Verdicts and
   exit codes:
   - `fired` (exit 0): a rule fired and the receipt came back `done` — fields `rule`, `id`,
     `type`, `status`, `objective` — and, for a walk, rule 7a's verification confirmed arrival.
   - `fired` with a non-`done` status, or no receipt inside the window (exit 2): the action was
     emitted but did not execute; the model should look before retrying.

7a. **A receipt is dispatch, not completion.** The bridge answers `done` when the click is
   delivered, while the body may still be walking. A fired `walk` is verified against the TARGET's coordinates,
   never the receipt alone: after `done`, evaluation follows the snapshot until the position
   stops changing (or a hard timeout), and the verdict status is `done` only when the settled
   tile is within the action's `arrive` tolerance of the target; otherwise it is
   `walk-short x=… z=…` (exit 2), naming where the body actually stopped. A
   `once_per_objective` mark is spent only on a VERIFIED `done` — a refused, short or
   unreceipted firing leaves the rule live for the objective.
   - `no-snapshot`, `stale`, `logged-out`, `same-tick`, `slot-busy` (exit 3): nothing to
     evaluate against — an unconsumed `action.json` (`slot-busy`) is never overwritten.
   - `no-rule-matched` (exit 4): the fallback signal — **only this verdict licenses model
     reasoning about the next action**. Fields include `cooldown_holds`, so a temporarily
     suppressed rule is visible to the falling-back mind.
   - `held` (exit 5): the manual override is on; nobody plays, model included.
   - `player-message` (exit 6): an incoming local or private message must be answered through
     rule 7b before ordinary play continues.
   - `system-message` (exit 7): rule 7c's idle movement warning is pending; the player must walk
     to a different tile before any non-walk action continues.
   `step --max N` repeats while rules fire cleanly (at most N actions), then reports the
   stopping verdict; the exit code is 0 if anything fired.

7b. Incoming player chat interrupts ordinary rule selection. Every structured snapshot message
   with `incoming: true` and channel `local` or `private` is copied into the existing
   `player-engine-state.json`, keyed by its bridge message id. Repeated snapshots cannot duplicate
   it, and it remains pending after it scrolls out of the snapshot. Before rules are evaluated,
   `step` reports the oldest pending message as
   `player-message id=… channel=… sender=… text=…` and exits 6, which licenses the Sol player
   to consider the message immediately. Player information is part of play: the player may change
   the current plan when the message supplies help, identifies a problem, or requests
   coordination.

   `reply MESSAGE_ID TEXT` answers through the same shared action slot and receipt path as every
   other deliberate action. A local incoming message compiles to `chat-local`; a private incoming
   message compiles to `chat-private` with the original sender as target. The bridge receipt proves
   dispatch; only the matching outgoing message echo in a later snapshot proves server acceptance
   and marks the message handled. A refusal, a server error, or an unconfirmed dispatch leaves it
   pending. Handling one message also
   handles older pending messages from the same sender and channel, allowing one concise response
   to cover a burst without producing stale replies. While an incoming message is pending, the
   autonomous player's direct movement, interaction, and screen-input doors exit 6 and point to
   `play reply`; inspection remains available. This is enforced only for the model player's
   inherited `BETTY_OPENRSC_AUTONOMOUS=1` environment, so mechanical login and manual controls are
   not caught behind chat state. The model therefore cannot acknowledge the verdict and continue
   clicking without answering. There is no chat daemon, side queue, or second controller:
   observation, priority, action, receipt, logging, and durable state all stay in this player
   action system.

7c. System messages remain structured in the bridge snapshot even though they are not player
   speech. The blue idle warning is detected by its stable meaning — standing here/still for a
   number of minutes and an instruction to move — so minor wording changes do not hide it. The
   warning is copied into `pending_system_messages` in the existing player engine state and
   `step` reports it as `system-message id=… channel=… action=move-required text=…` with exit 7
   before player messages and ordinary rules. While it is pending, the autonomous harness permits
   a receipted `walk` and refuses every other action door. A later snapshot on a different player
   tile is the only completion proof; it clears the warning and records `system-message-handled`.
   Repeated snapshots cannot duplicate it. Other system messages remain available in snapshot
   context without all becoming interrupts: the latest non-player game text rides the
   `no-rule-matched` verdict and the resident runner heartbeat, so Sol sees feedback such as a
   missing requirement without another subsystem or another model turn.

7d. State-based waiting is part of this ACTIONS player, not a shell delay. `wait-until CONDITION`
   observes the same atomically replaced `state.json` as rule evaluation and blocks on filesystem
   change notifications until a snapshot newer than the one seen at invocation satisfies the
   named condition. This prevents an action receipt followed immediately by `not_walking` from
   accepting the pre-action snapshot. Conditions are
   `logged_in`, `logged_out`, `walking`, `not_walking`, `in_combat`, `out_of_combat`,
   `talking_to_npc`, and `not_talking_to_npc`; dashes are accepted in place of underscores.
   When `not_talking_to_npc` begins in a false gap, it must observe dialogue become true and then
   false; a pre-reply false snapshot cannot masquerade as the end of the conversation.
   Success reports `condition-met` with the condition and snapshot tick. A wait has a 15-second
   default and a caller-selected ceiling no greater than 60 seconds; expiry reports the latest
   observed state as `condition-timeout` and exits 2, so a missing transition can never block the
   player permanently. It consumes no action slot, creates no second game-state path, uses no
   model call, and performs no timed polling.

8. The discipline inside evaluation is game-reflex rules 10–11 verbatim, because it is the same
   code: descending priority for one game slot, losers logged as `conflict-loss`, per-rule
   `cooldown_ms` with `cooldown-hold` logged once per blocked episode, `hold_ticks` debounce,
   one action in flight until receipt or timeout, `min_action_interval_ms` and
   `max_actions_per_min` pacing, stale and logged-out snapshots firing nothing, a logged-out
   snapshot resetting streaks, no tick acted on twice, and the `hold` flag honoured at both
   ends (game-reflex rule 15 — the same flag file; `hold`/`resume` here and in `betty-game`
   move the same override). Pacing counters are per-engine (each engine paces its own hand);
   the action slot is shared and guarded by `slot-busy`.

9. `once_per_objective`: a rule so marked fires once per (rule, objective) pair; the mark lives
   in `player-engine-state.json`, so it survives a player restart, and clears when the
   objective changes. This is what makes "talk to the instructor for this lesson" a rule
   instead of a loop: cooldowns pace, the mark concludes.

10. Every decision is an event line in `player-decisions.jsonl` — fired actions with the
    snapshot values read, conflict losses, cooldown holds, receipts, refusals (an action whose
    compilation fails, e.g. `talk-npc` with no such NPC visible, is logged `refused` and the
    next rule gets the slot), hold/stale/logged-out transitions. `log` tails it.

### Learning

11. Rules are created durably by the player's own hand at the moment a play verifies:
    `learn <name> --priority N [--cooldown-ms N] [--hold-ticks N] [--once-per-objective]
    [--disabled] [--note TEXT] --trigger k=v… --action TYPE [--param k=v…]` validates through
    rule 3's gate and persists. A learned rule arrives **enabled** — unlike game-reflex rule
    14's shipped defaults, learning is already the player's own explicit act on a verified
    moment, which is the arming criterion. `unfinished <name> <note…>` records what could not
    be compiled. `objective [NAME|--clear]` sets or clears the durable objective;
    `enable`/`disable`/`set`/`remove`/`rules` mirror `betty-game`'s. `init` writes an empty
    valid table if none exists, never overwrites.

### The entrypoint

12. The playing harness invokes this layer first: `orsc-headless.sh play [args…]` in the game
    checkout runs `step` (default `--max 8`) against the deployed
    `~/.local/lib/deskcrab/game_player.py` (`DESKCRAB_GAME_PLAYER` overrides, which is how the
    test sandbox pins its own copy), and passes any other subcommand through, so the sitting
    has one door for stepping, state-based waiting, learning and objectives. The direct harness
    door `orsc-headless.sh wait-until CONDITION [SECONDS]` delegates to that same module.
    The playing policy the sittings read
    makes rules-first mandatory: reasoning about the next action is licensed only by rule 7's
    `no-rule-matched` (exit 4), and a newly verified play must become an executable rule — but
    authoring it is the BACKGROUND hand's job (rule 16), never the playing hand's: the player
    leaves a `note` in the outcome queue and keeps moving. While rule 15's resident runner is
    live, `step` defers to it instead of evaluating — one engine-state writer at a time — and
    reports the runner's own latest verdict with the same exit mapping, so exit 4 keeps its
    meaning as the one licence to reason.

13. The harness is itself versioned bytes, and its processes outlive their launcher. The
    entrypoint and its helpers are committed in the game checkout's repository
    (`Core-Framework/headless/`) and deployed into the live tree as symlinks beside their
    unversioned runtime state (`vendor/`, `run/`, `shots/`) — the same shape as the committed
    launcher — so the door a green test proves is the door the repository carries. And every
    long-lived process the harness starts (Xvfb, the client, the reflex engine, the viewer)
    starts as its own transient systemd user unit (`orsc-<name>.service`), a sibling of the
    launching process, never a `setsid` child of it: a child, however detached from its
    terminal, still dies with the launching service's cgroup. Where no user manager is
    reachable the harness refuses to start rather than pretend durability;
    `ORSC_HEADLESS_DETACH=setsid` is the explicit sandbox opt-down.

14. Playing is one ordinary installed command. `betty-openrsc` is committed in the game
    checkout's repository (`Core-Framework/headless/betty-openrsc`), deployed into the live
    tree as a symlink beside the harness (rule 13's shape), and installed on PATH — the same
    ordinariness as the chess doors. Its doors:
    - `play` brings the whole stack up from stopped state, in order: Xvfb and the client
      (`orsc-headless.sh start`), a mechanical login from the stored credentials file when the
      snapshot says logged out (login is plumbing, never play), the reflex engine
      (`engine start`), and the player itself — a real GPT Sol model (`codex exec --model
      gpt-5.6-sol -c model_reasoning_effort=low`, both pins visible in the committed bytes) running as its own transient user
      unit `orsc-player.service` with `Restart=always` and `StartLimitIntervalSec=0`: a player
      that exits, normally or killed, is restarted by the service manager, never by a watching
      shell, and restarts are never rate-limited away. Layers already up are left alone, so
      `play` is also the resume door.
    - `status`, `log` and `stop` are the matching operational doors; `stop player` stops the
      player alone, bare `stop` tears the whole stack down (the game server is not this
      command's to stop). `login` is the mechanical login alone, and `player-start` starts the
      supervised player unit alone when the stack is already up.
    - The Sol player is her own continuing play, not a subordinate agent or another personality.
      `steer <instruction>` is her ordinary self-direction door for redirecting that play whenever
      she notices it is wrong, stalled or looping, as well as when the user asks for a correction.
      It atomically records the newest direction in the durable player home and restarts only
      `orsc-player.service`, resuming the same Sol thread with that direction placed prominently
      in its compact continuation prompt. The client, bridge, reflex engine, resident runner,
      author, and spectator remain running. If the player unit is down, `steer` raises the normal
      stack instead. Steering is durable ground truth across later player-process boundaries; a
      repeated direction never means undoing completed progress to reenact it. Noticing a bad
      course is itself sufficient reason to steer; narrating distress about the course is not a
      substitute for changing it.
    - The player's durable base prompt (`prompt.md`), its latest steering direction
      (`steering.md`), its handoff file (`handoff.md`), the
      exact composed prompt of the latest start (`run-prompt.txt`) and its log (`player.log`)
      live in the durable player home (`BETTY_OPENRSC_HOME`, a directory in the user's own
      files). Nothing of the player — prompt, handoff or log — lives under `/tmp`.
    - The first player start composes its effective prompt from ground truth discovered at that
      moment (`run-player`, the unit's exec target): the live display read from the harness's
      `run/display` (never hard-coded), the bridge state dir, the durable objective, a fresh
      snapshot summary, the decision log's tail, and the handoff file's contents as they are NOW.
      The Codex thread id is captured durably in the player home. A normal process boundary or
      service restart resumes that same Sol thread with a compact current-state continuation,
      instead of opening a new conversation that re-reads the standing instructions and audits
      the stack. If the saved thread cannot be resumed, its id is cleared and the next supervised
      start makes a newly composed player. `prompt` prints exactly what a new player would receive
      — the audit door the tests pin.
    - The handoff is an emergency checkpoint, not a per-action journal. The player overwrites it
      when the objective or plan changes, before or during a dialogue/UI sequence that the bridge
      cannot reconstruct, after a meaningful batch of verified actions, and immediately before a
      deliberate exit. Ordinary receipted actions rely on the durable objective, snapshot, and
      decision log. A resumed thread continues directly; a new thread derives current state from
      those facts and the latest checkpoint without rechecking healthy stack layers.
    - `play` also raises rule 15's resident runner (`orsc-runner.service`, through the
      harness's `runner` door) and rule 16's background author (`orsc-author.service`,
      `run-author`), so the standing stack has five runtime processes: client, reflex engine,
      rules runner, author, and player. Mechanical login is the setup step between client and
      engine startup.
    - The playing loop the prompt demands is rule 12's:
      learned rules fire from the resident runner with no model anywhere near them; the
      model's whole job is the GAP — when `play` hands back exit 4, make ONE quick decision,
      act through the bridge doors, verify against the snapshot, `play note` the outcome for
      the background author, and keep moving. Acting never waits on authoring; minutes of
      deliberation while the body stands still is the exact failure this shape exists to
      prevent. A single bridge action, an engine reflex, a login, or any builder job is
      not playing; playing is that loop, continued for the whole run.
    - Arbitrary timed waits and screenshot loops are structurally forbidden in the Sol player's
      shell commands.
      The player starts with the `openrsc-player` Codex profile and its trusted `PreToolUse`
      hook; a shell command that executes `sleep` or a language-runtime sleep is denied before
      execution, as is a command containing more than one game screenshot. Waiting for the game
      is expressed only through this ACTIONS system's `wait-until`, receipts, snapshot changes,
      runner verdicts, and state-triggered rules. A single screenshot remains available for
      genuine visual inspection. The hook does not apply to the runner, bridge, client, or
      background author.
    - The sandbox drives all of it through env doors: `BETTY_OPENRSC_HOME`,
      `BETTY_OPENRSC_HEADLESS`, `BETTY_OPENRSC_CODEX`, `BETTY_OPENRSC_MODEL`,
      `BETTY_OPENRSC_UNIT`, `BETTY_OPENRSC_AUTHOR_MODEL`, `BETTY_OPENRSC_AUTHOR_UNIT`.

### The resident runner, the outcome queue, and the test gate

15. `run` is the resident rules engine: the same one-step evaluation as rule 7, in a loop, as
    its own long-lived process (`orsc-runner.service` beside the reflex engine), so a matching
    rule fires within a poll interval of its trigger becoming true — never waiting on a model
    turn. Each iteration re-reads the objective, reloads the table when
    `learned-rules.json`'s mtime moves (an invalid table is refused loudly and the last valid
    one kept), evaluates, verifies per rule 7a, and writes a heartbeat —
    `$DESKCRAB_GAME_STATE_DIR/player-runner.json`: pid, ts, latest verdict and detail — every
    pass. A fresh heartbeat (pid alive, ts within 30 s, covering an in-progress walk verification)
    is how rule 12's `step` knows to defer:
    two writers of the engine state would race, so while the runner is live it is the ONLY
    evaluator. The hold flag, stale, logged-out and slot-busy protections all hold inside the
    loop exactly as in `step`.

16. Authoring happens in parallel with play, never instead of it. Every fired action's outcome
    — rule, action, receipt status, rule 7a's intended target versus settled tile, the
    snapshot brief — is appended to the durable outcome queue,
    `$DESKCRAB_GAME_DIR/outcome-queue.jsonl`; the runner also records a `gap` when no rule
    matches and a changed actionable state signature remains unchanged for at least 750 ms
    (objective, position, inventory, game messages, and visible entity types/objects, excluding
    tick churn and NPC wandering). Movement therefore produces one gap after the body settles,
    not one gap for every crossed tile. `note <text…>` is the playing
    hand's one-line door for lessons the queue cannot see (it stamps the current position,
    objective and inventory alongside the text). The queue is the inbox of the background
    author — an event-driven supervised worker (`run-author` under `orsc-author.path` and
    `orsc-author.service`) that starts when the queue changes, processes only bytes after its
    durable cursor, and then exits; there is no sleep or polling loop. It runs on Sol at low
    effort under the same no-sleep command hook as the playing hand, reads new outcomes, writes
    and refines rules through the rule 11 doors, maintains rule
    17's cases, and never touches the bridge, the screen, or the reflex engine: every action
    that CAN become a reflex SHOULD become one, but rule creation must never block the body.

17. Rules are deterministic trigger-to-action data, so they are tested like data.
    `$DESKCRAB_GAME_DIR/learned-rule-tests.json` holds replay cases — `name`, `objective`,
    a captured `snapshot`, and `expect` (the rule name that must win the slot, or `none`) —
    and `test` replays every case against the live table with rule 7's own trigger and
    compile functions (cooldowns, marks and pacing excluded: cases are pure), plus a lint
    pass (including a `near_tile` radius below rule 4's floor). `test add <name> --expect R
    --snapshot F [--objective O]`, `test remove`, `test list` maintain the cases. The gate:
    every table-mutating door — `learn`, `enable`, `disable`, `set`, `remove` — runs the full
    suite against the WOULD-BE table first and refuses the write on any failure, so a broken
    rule is caught before it is armed, and a new rule that would steal an existing case's
    trigger state is caught the moment it is proposed.

## KNOWN LIMITS

- The trigger vocabulary sees what the snapshot carries (game-reflex rule 3). Doors and scenery
  are visible through `bounds` and `objects`; exact quest state and dialogue choices remain
  invisible, and plays that need them wait in `unfinished` for
  the bridge to grow, by spec change there and here.
- `message_contains` reads the snapshot's short message tail; a message that scrolled out
  between polls is missed. Rules should trigger on state where possible and messages only for
  moments.
- The objective is one line set by the deliberate hand; nothing advances it mechanically. A
  stale objective can suppress rules (never fire wrong ones — `once_per_objective` marks and
  triggers still gate) until the next reasoning turn corrects it.
- Two engines share one action slot by design (one bridge, one body). `slot-busy` refusal is
  the guard; a reflex-engine daemon and a player stepping at the same moment contend politely
  but the reflex engine's emission is not priority-merged with this table's — the reflex
  engine's own rules stay the faster hand.
