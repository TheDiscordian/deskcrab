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
   `$DESKCRAB_GAME_DIR/objective`, its chosen method is `$DESKCRAB_GAME_DIR/plan`, and the
   immediate activity is `$DESKCRAB_GAME_DIR/activity` (each one line, empty or absent meaning
   none). The objective is the longer-lived goal (for example `cooking-level-10`); the plan is
   the currently chosen way to achieve it, including meaningful destination and method constraints
   (for example `Use the Al Kharid bank-and-range loop; do not substitute Lumbridge's distant-bank
   range`); the activity is what the player is doing now (for example `travelling`, `banking`, or
   `cooking`). The plan remains binding across ordinary turns, process restarts, route trouble, and
   activity changes. Proximity or convenience cannot silently replace it. A genuinely new
   objective clears the old plan so a stale method never leaks into a different goal.
   The bridge snapshot's `quest_points` and `quests` are the server-authored quest journal;
   each named quest carries its numeric stage and `completed`, `started`, or `not_started`
   status. `quests [TEXT]` reads or searches it. Before selecting a quest objective, the player
   reads this journal instead of guessing from inventory, memory, prior prose, or a screenshot.
   `objective` compares punctuation-insensitive quest names and common objective wrappers and
   refuses a quest whose authoritative stage is already completed.
   `$DESKCRAB_GAME_DIR/activity-stats.json` is the selected activity's measured clock: its start
   time, per-skill cumulative-XP baselines, latest observed XP values, and the most recent positive
   XP delta. Selecting a different activity or `activity --restart` resets that baseline; selecting
   the already-current activity does not accidentally erase it, and clearing activity removes it.
   The resident runner compares the bridge's structured `skills` XP every pass, so an XP-bearing
   game action becomes a grounded `+N/action` delta and cumulative gain divided by elapsed activity
   time becomes XP/hour. Only skills with positive gain are reported. No screen counter, level
   estimate, or model inference is involved. The client briefly publishes zero-filled skill
   arrays during login; that placeholder is never a baseline. Measurement waits until at least
   one real positive base level exists, and pre-v2 baselines without that readiness proof are
   re-established from the first ready snapshot.

   Performance is durable across revisions rather than visible only for the current clock.
   `$DESKCRAB_GAME_DIR/activity-history.jsonl` holds every completed activity iteration: activity,
   objective, start/end/reason, elapsed time, positive per-skill gain and XP/hour, and the compact
   executable reflex set and fingerprint that governed it. Activity switch, explicit restart,
   clear, or an executable reflex change relevant to the selected activity closes the current
   iteration before starting the next one from the same grounded XP snapshot. A prose-only note
   edit and a rule scoped away from the current objective/activity do not reset the clock.
   `$DESKCRAB_GAME_DIR/reflex-history.jsonl` records every created, changed, enabled, disabled, or
   removed reflex with its exact before/after body and the activity performance immediately before
   a relevant executable change. `activity --history [NAME]` reports recent iterations and the
   best comparable rate; `rules --history [--rule NAME]` reports the revision trail. An iteration
   under 60 seconds or without positive XP is preserved as evidence but cannot become the
   performance benchmark.

   The engine's own counters live in `$DESKCRAB_GAME_STATE_DIR/player-engine-state.json` and its decisions in
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
   - `activity_is` (string): the activity file's line equals it exactly. Use it to keep a useful
     reflex armed for its own mode without letting it interrupt another immediate task. This is
     opt-in: a rule without `activity_is` remains activity-agnostic.
   - `npc_visible` (int): the snapshot's `npcs` list holds that type id.
   - `object_visible` (int): the snapshot's `objects` list holds that type id.
   - `bound_visible` (int): the snapshot's `bounds` list holds that type id.
   - `entity_visible` (`{"collection":…,"field":…,"value":…}`): a structured
     `players`, `npcs`, `objects`, `bounds`, or `ground_items` entry has the exact `name`, `id`,
     or `sidx` value (string names compare case-insensitively). This is the generic semantic
     selector from which the player can author identity-based behaviours the original table did
     not happen to ship with.
   - `ground_item_visible` (int): the snapshot's `ground_items` list holds that item id.
   - `shop_item_visible` / `bank_item_visible` (int): the respective open interface's item list
     holds that item id.
   - `message_contains` (string, non-empty, single-line): some message in the snapshot's
     `messages` contains it, case-insensitively.
   - `near_tile` (`{"x":…,"z":…,"radius":…}`): Chebyshev distance from the player's tile is at
     most `radius` (0 ≤ radius ≤ 50). Evaluation applies an effective floor of 2: a stored
     radius below 2 evaluates as 2, and rule 17's lint refuses to author one. The trigger names
     the vicinity; rule 7a's verification owns the exact destination.
   - `inventory_has` / `inventory_lacks` (int): an item of that id is / is not in the inventory.
   - `inventory_slots_below` / `inventory_slots_at_least` (int, 0–30): the number of occupied
     inventory slots is respectively below / at least the threshold. Acquisition rules use
     `inventory_slots_below: 30` so a full bag mechanically stops them instead of letting the
     player notice the problem and continue the same loop.
   - `in_combat` / `out_of_combat` (literal `true`): the snapshot's combat state has the named
     polarity. These conditions are mutually exclusive in live state and let global pickup or
     travel rules stay mechanically quiet during a fight.

5. The action vocabulary is closed: `talk-npc` (`npc`: the type id; the server index is resolved
   from the snapshot at fire time — nearest matching NPC by real walking steps, independently of
   input list order — and both ride the action file exactly
   as game-reflex rule 6 defines, so the bridge's despawn/mismatch re-checks still protect the
   click), `interact-npc` (`npc`: the type id; optional `cmd` 1 or 2 defaulting to 1; optional
   `within` 0–10 caps the current Chebyshev tile distance and rides the action file for one final
   dispatch-time recheck), which
   resolves the same stable NPC identity and performs its definition-backed menu command without
   any pointer or context-menu reconstruction. Repeating reflexes use `within` so a wandering
   target cannot drag the player across the area; deliberate one-off NPC commands may still
   approach their chosen visible target. Every NPC action records the selected target's snapshot
   tile in its decision event, and the bridge refuses it if a strictly nearer equivalent exists by
   dispatch time. `cast-npc` (`spell`: the spell id; `npc`: the NPC type id; optional `within`
   0–10; optional 0/1 `stationary`, `require_clear_shot`, and
   `require_melee_unreachable`) resolves the same nearest stable NPC identity but only when the structured spellbook says
   the spell is ready and its target kind is `npc/player`. Spell, NPC identity, and any locality
   or terrain guards ride the action for the client's final live level/rune/identity recheck.
   Guarded target selection applies every requested relation to one NPC, not independent matches.
   `stationary: 1` omits the client approach walk and is refused beyond the four-tile Magic range;
   the completion verifier additionally fails the action if the player's tile changes. After dispatch the
   rule retains control until a required rune changes, Magic XP changes, or explicit spell feedback
   arrives; a fizzle/cooldown/refusal is not successful completion. Repeating Magic reflexes use an
   honest activity scope and may require a local cap, stationary casting, a live clear shot, and
   terrain melee unreachability so training cannot become an unbounded chase or continue after
   its topology changes. `walk` (absolute `x`/`z`, **unclamped** — deliberate travel crosses the map, and
   the game's own pathing already decides reachability; the 15-tile clamp is a reflex-channel
   rule about panic moves, not a bridge property; optional `arrive`, 0–10 defaulting to 1, the
   Chebyshev tolerance rule 7a's verification accepts as arrival; the resident route may add the
   internal bridge parameters `route_step` and `max_path`, which cannot be authored into learned
   rules), `approach-entity` (`collection`, `field`, `value`, and `within` 1–10) resolves the
   nearest matching structured entity at every firing and compiles to an ordinary receipted walk
   toward that entity's current tile. No coordinate is stored in the learned rule. Together with
   `entity_visible`, this is the declarative extension point for player-authored semantic actions:
   the behaviour receives its own meaningful rule name, activity/objective scope, priority,
   cooldown, and replay tests while the primitive remains grounded and code-free. A moving player
   can therefore be approached by a learned behaviour, and future structured-state games can
   expose their own entity collections without admitting shell commands or remembered pixels.
   OpenRSC additionally exposes `follow-player` (`name`, `within` 1–10): it resolves the player's
   current server identity from structured state and emits the game's native Follow action, never
   a menu or remembered pointer coordinate.
   `retreat` (optional `distance`
   1–10, default 5, and fallback direction `dx`/`dz`; while fighting, the bridge prefers away from
   the identified opponent and tries alternate directions and nearer tiles until its collision
   map finds one reachable ordinary walk), `interact-object` (`obj`: the object type id,
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
   remembered slot to target its replacement), `click-shop` and `click-bank` (`item`: the item id;
   optional `button` 1, 2, or 3 defaulting to 1). The compiled action again carries only item
   identity. The bridge refuses a closed interface or missing item; otherwise it exposes the
   current page or scroll row containing the item and resolves that live slot immediately before
   clicking), and `take-ground` (`item`: the item id; optional `within` 0–10 caps its current
   Chebyshev distance). The
   shortest reachable matching `ground_items` entry is compiled to item id and current world tile;
   a visually closer unreachable pile cannot displace a farther reachable one. The bridge re-matches
   both and rechecks the live collision path immediately before sending the game's own walk-and-take
   action. It refuses `ground-item-unreachable` without dispatch; when snapshot topology proves one
   loaded openable boundary connects the separated components, the more specific result is
   `ground-item-needs-door`. Wanted-loot
   reflexes deliberately omit `within`: visibility licenses a collision-path check, not a fabricated
   entity walk.
   `within` is only for a rule whose intended behaviour is explicitly local, never an implicit
   safety restriction on an ordinary desire. Everything the bridge refuses stays refused;
   nothing in this layer can log in, spend, trade or message a player, and screen-space clicks
   that do not name a rendered game entity or current inventory, shop, or bank item remain structurally outside the vocabulary — an action
   that cannot be expressed here belongs in `unfinished`, not approximated.

6. `unfinished` is the honesty ledger of migration: entries (`name`, `note`) for learned plays
   whose trigger or action cannot yet be grounded in rules 4–5 — camera-dependent screen
   presses, scenery the bridge does not expose. They are listed by `rules`, never evaluated,
   and never silently promoted; graduating one requires the vocabulary to grow by spec change.

### Evaluation

7. `step` is one rules-first evaluation: read the snapshot, update the selected activity's XP
   measurements, evaluate the table through
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
   `retreat` is verified against `in_combat`, not its dispatch receipt or an invented client
   timer. OpenRSC permits escape only after the opponent's third hit, a server counter the client
   is not sent. A still-fighting attempt becomes `retreat-locked` or `retreat-unconfirmed`
   (exit 2), remains eligible, and retries on later runner passes; only a snapshot with
   `in_combat: false` is `done`.
   `take-ground` is likewise a commitment, not a dispatch receipt. Evaluation retains control
   while the bridge walks to the targeted item; `done` requires the matching ground entry at that
   exact tile to decrease and the same item id's inventory quantity to increase. A vanished pile
   without inventory gain is `take-missed`, and a settled body with the pile still present is
   `take-short`. Routine activity cannot fire midway through this verification and cancel the
   approach. The direct `take ITEM-ID` door uses this same verifier and publishes a short-lived
   in-progress record so the resident runner also stays out of its way.
   A direct take attempted during combat emits nothing and reports
   `take-needs-retreat ... next=retreat`; retreat is the action that can make
   the pickup legal, and the wanted pile remains visible for the next pass.
   A direct take with no collision path likewise emits nothing: it reports `take-needs-door` with
   the proven boundary identity and semantic next action when one door connects the components,
   otherwise `take-unreachable`. Neither result enters the verifier's long walk timeout.
   Direct bridge actions are causally armed from the fresh pre-dispatch snapshot. A later
   `wait-until action_done` accepts only a newer grounded consequence attributable to that action:
   inventory or XP deltas, new game/quest/inventory feedback, a relevant interface transition, or
   settled movement for a movement action. It reports the evidence and labels known refusal
   feedback `result=failed`; the receipt alone is never completion. The one-step
   `orsc-headless.sh use ITEM-ID object OBJECT-ID [SECONDS]` door uses this verifier after resolving
   and dispatching both live identities atomically, so inventory-pane timing cannot separate item
   selection from the object use. For that action specifically, the selected input changing or XP
   is required for success; explicit server failure may end it unsuccessfully. A pane/menu
   transition or a furnace's early “smelt together” line is ignored rather than accepted before
   the resulting bar exists.
   `cast-npc` uses the same causal verifier for direct and learned casts, narrowed to the selected
   spell's required rune ids, Magic XP, and explicit spell feedback. An unrelated inventory,
   interface, or message transition cannot make a cast successful, and routine work cannot resume
   while its result is unresolved. The direct `terrain [RADIUS]` door renders the snapshot's local
   blocked cells/edges, projectile permeability, and per-NPC clear-shot/melee-reach relations; the
   direct cast door's `--stationary` option chooses a target currently satisfying both terrain
   relations, arms the same no-approach action with both live dispatch guards, and reports those
   relations with its grounded result.
   - `no-snapshot`, `stale`, `logged-out`, `same-tick`, `slot-busy` (exit 3): nothing to
     evaluate against — an unconsumed `action.json` (`slot-busy`) is never overwritten.
   - `no-rule-matched` (exit 4): the open-ended fallback signal. Other exit-4 prerequisites below
     license only their named correction; this verdict licenses model reasoning about the next
     ordinary action. Fields include `cooldown_holds`, so a temporarily
     suppressed rule is visible to the falling-back mind, and `ground_items` names every visible
     ground-item id so a newly entered room cannot hide an actionable pickup behind another query.
     The current `plan`, `activity`, and any positive `activity_xp` measurements ride the ordinary
     verdict; the resident-runner heartbeat preserves them when a separate player process asks
     through `play`, so method continuity and performance feedback are ambient rather than special
     inspection rituals. Once the current sample is at least 60 seconds old and a comparable prior
     iteration exists, the verdict also carries `activity_compare`, current XP/hour versus the best
     prior eligible iteration.
   - `sleeping-needs-wake` (exit 4): the sleep-word screen currently owns input. No objective,
     route, reflex, or reply action is emitted; solving the current word and verifying awake state
     is the sole licensed reasoning task. Invoking the sleeping bag again is never a wake-up action.
   - `movement-in-progress` (exit 3): a directly dispatched movement commitment still owns the
     body. Ordinary learned rules emit nothing until `walking` becomes false, so incidental loot
     cannot cancel an approach to an NPC or another deliberate destination. A currently applicable
     combat-retreat rule remains the safety exception.
   - `npc-dialogue-in-progress` (exit 3): an NPC exchange is between speech/choice states. Ordinary
     learned rules emit nothing; in particular, visible or respawning loot cannot walk the player
     out of the conversation.
   - `npc-dialogue-choice` (exit 4): the NPC reply menu is open. `choices` contains its exact
     semantic text and the sole licensed reasoning task is choosing one with the dialogue command.
     The conversation continues to own the body across as many speech/choice stages as it needs.
   - `held` (exit 5): the manual override is on; nobody plays, model included.
   - `player-message` (exit 6): an incoming local or private message must be answered through
     rule 7b before ordinary play continues.
   - A player message whose five-second burst window is still settling is background observation,
     not a stopping verdict: ordinary current-activity play continues until the burst is complete.
   - `system-message` (exit 7): rule 7c's idle movement warning is pending; the player must walk
     to a different tile before any non-walk action continues.
   `step --max N` repeats while rules fire cleanly (at most N actions), then reports the
   stopping verdict; the exit code is 0 if anything fired.

7b. A settled incoming player-chat burst interrupts ordinary rule selection, except that an
   applicable `retreat` takes temporary precedence. A direct retreat retains that precedence through its post-combat
   clearance walk: escaping a fight or pack cannot wait for conversation, and the pending message
   remains queued for the first spatially safe pass. Every structured snapshot message
   with `incoming: true` and channel `local` or `private` is copied into the existing
   `player-engine-state.json`, keyed by its bridge message id. Repeated snapshots cannot duplicate
   it, and it remains pending after it scrolls out of the snapshot. The first new message opens a
   five-second settle window, and every additional incoming message extends that window to five
   seconds after the latest arrival. During that short collection window, the resident runner and
   the model's ordinary action doors remain available so the selected activity does not stall.
   The resident observer measures the deadline without a shell sleep or an extra model call.
   Urgent system messages retain priority and are never delayed by this window. Once settled,
   the message interrupts ordinary play and messages from the oldest pending
   sender/channel conversation are reported together as one structured burst. Its actionable
   `id` is the newest message in that burst, so one `reply` handles the whole preceding chain;
   `step` reports `player-message id=… channel=… sender=… count=… burst=…` and exits 6.
   Player information is part of play: the player may change
   the current plan when the message supplies help, identifies a problem, or requests
   coordination.

   The same deduplicated incoming local/private message id tops up the current sitting when its
   playable deadline has less than 20 minutes remaining. The deadline becomes exactly 20 minutes
   after observation; a message received during wind-down returns the session to `open`. A
   separate bounded id ledger makes this work across a hot runner upgrade without letting the
   bridge's repeated snapshots add time repeatedly. No session is opened by chat, outgoing/system
   messages add nothing, and a sitting with at least 20 minutes left is unchanged. The extension
   and its triggering message ids are retained in `session.json` and `player-decisions.jsonl`.

   Friend presence is ambient social awareness, not a new interruption class. The client's
   authoritative `friend-status` messages are parsed only from actual “has logged in/out”
   transitions; loading the initial friend list produces no synthetic arrivals. Each transition
   is copied once into the locked player state and decision log, survives after it scrolls out of
   the bridge's bounded message window, and rides the resident heartbeat as `friend_updates` until
   the next model-facing `play` prints and acknowledges those exact ids. Learned activity keeps
   running while this happens. A presence change may naturally affect coordination, but it does
   not by itself require a greeting, cancel a conversation, abandon wanted loot, or outrank safety
   and an acknowledged commitment.

   `reply MESSAGE_ID TEXT` answers through the same shared action slot and receipt path as every
   other deliberate action. A private incoming message compiles to `chat-private` with the
   original sender as target. A local incoming message compiles at reply time: it remains
   `chat-local` only while a case-insensitive match for the sender remains in the snapshot's
   current visible `players`; if that player has left the nearby list, it becomes `chat-private`
   to the original sender instead. The bridge receipt proves
   dispatch; only the matching outgoing message echo in a later snapshot proves server acceptance
   and marks the message handled. Matching compares the same case-insensitive word sequence because
   the Classic chat codec can discard punctuation and normalize capitalization; those transformations
   do not license a duplicate retry. An unconfirmed dispatch or ordinary action refusal leaves it
   pending. One grounded server `Unable to send message` response to a private fallback proves the
   absent target cannot currently be answered: it records `player-message-undeliverable`, clears that
   settled burst, and resumes play instead of retrying forever. The attempted reply stays in the
   decision log so it can be answered naturally when the player returns. Handling one message also
   handles older pending messages from the same sender and channel, allowing one concise response
   to cover a burst without producing stale replies. Once an incoming message's settle window has
   closed, the autonomous player's direct movement, interaction, and screen-input doors exit 6 and
   point to `play reply`; inspection remains available. This is enforced only for the model player's
   inherited `BETTY_OPENRSC_AUTONOMOUS=1` environment, so mechanical login and manual controls are
   not caught behind chat state. The model therefore cannot acknowledge the verdict and continue
   clicking without answering. There is no chat daemon, side queue, or second controller:
   observation, priority, action, receipt, logging, and durable state all stay in this player
   action system.

   A reply attempted while logged out reports `reply-needs-login ... pending=preserved`; it does
   not consume the message. The harness's mechanical login inputs explicitly bypass the
   autonomous conversation gate, because login is the prerequisite that makes replying possible.
   At reply time the idle-warning state is refreshed under the player-state lock; a pending
   warning instead reports `reply-needs-movement ... pending=preserved`, so conversation cannot
   spend the remaining idle window and cause its own logout.

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
   observes the same atomically replaced `state.json` as rule evaluation. A fresh current snapshot
   that already satisfies the named condition succeeds immediately; otherwise it blocks on
   filesystem change notifications until a newer snapshot satisfies it. Movement-capable bridge
   actions publish `walking: true` across the dispatch gap, so an action receipt followed by
   `not_walking` cannot accept the pre-action snapshot. Conditions are
   `logged_in`, `logged_out`, `walking`, `not_walking`, `in_combat`, `out_of_combat`,
   `talking_to_npc`, `not_talking_to_npc`, `right_click_menu_open`,
   `right_click_menu_closed`, `ui_panel_open`, `ui_panel_closed`, `trade_open`, `trade_closed`,
   `sleeping`, `not_sleeping`, `fatigue_zero`, and `action_done`; dashes are accepted in place of
   underscores. Unlike the
   level-triggered state names, `action_done` requires the causal baseline armed immediately before
   the most recent direct bridge action and consumes it after observing a result.
   When `not_talking_to_npc` begins in a false gap, it must observe dialogue become true and then
   false; a pre-reply false snapshot cannot masquerade as the end of the conversation.
   Success reports `condition-met` with the condition and snapshot tick. A wait has a 15-second
   default and a caller-selected ceiling no greater than 60 seconds; expiry reports the latest
   observed state as `condition-timeout` and exits 2, so a missing transition can never block the
   player permanently. It consumes no action slot, creates no second game-state path, uses no
   model call, and performs no timed polling.
   A special causal guard applies to `out_of_combat`: while combat is still active and the
   server's “first 3 rounds” refusal is present, waiting alone cannot make escape happen.
   The wait exits 2 immediately as `condition-needs-action ... next=retreat` and records the
   failed strategy in the outcome queue instead of allowing an unchanged wait/retry loop.

7e. Long-distance walking is a durable route in this same ACTIONS player. `route X Z
   [--arrive N]` atomically records one absolute destination, the current objective, and an arrival
   tolerance from 0 through 10 in `$DESKCRAB_GAME_DIR/route.json`; `route` with no coordinates
   reports it, and `route --clear` cancels it. The resident runner treats an active route as its
   lowest-priority synthetic rule among nonmovement interactions, so useful NPC/object/interface
   work may interrupt it and incoming player or urgent system messages still outrank it. A second
   learned `walk` is different: while an explicit route exists it is held and logged as a route
   conflict instead of silently replacing the current movement commitment. This prevents an old
   route fragment whose broad trigger still matches from pulling the body away and then handing it
   back, a two-controller oscillation no repetition timer can make productive.

   Each route action names the REAL durable destination and asks the client bridge for an at-most
   eight-step prefix of the complete collision path currently known toward it (`route_step=8`).
   The bridge pathfinder chooses that prefix endpoint; no guessed intermediate coordinate crosses
   the action file. When the destination lies outside the loaded 96×96 region, the client first
   selects a reachable progressive region-edge path and takes the same bounded prefix, then the
   next pass replans in the new region. A 16-step `max_path` field travels with the request as a
   safe compatibility refusal for an older bridge that does not understand `route_step`; the
   route-aware bridge applies the prefix instead of that full-destination ceiling. Its `arrive`
   tolerance is pathfinding input for the destination area as well as verification. An occupied
   landmark tile can therefore settle on reachable adjacent floor without making Sol guess
   successive neighbouring coordinates. A verified path prefix is `route-progress` and
   immediately licenses the next prefix without a model call even when going around collision
   temporarily increases straight-line distance; that detour is pathfinder evidence, not a claim
   that the destination moved. The route stores recent settled endpoints, refuses a repeated one
   as `route-cycle`, and permits at most twelve consecutive non-closing prefixes before asking for
   a new decision, so grounded detours cannot become wandering. That budget resets only when a
   prefix establishes a new route-best distance to the durable destination; moving closer than
   the immediately preceding self-created detour, while remaining worse than an earlier point on
   the same route, is not renewed progress and cannot sustain a wide oscillation. A refusal,
   unchanged settlement,
   cycle, or exhausted detour budget marks the route `blocked` at the current position and visible obstacle
   signature, reports `route-needs-detour` at exit 4 to Sol, and emits no further walk merely because the dispatched leg
   settles another tile. A changed visible obstacle signature may make the path viable; otherwise
   Sol must inspect live terrain or choose a semantic boundary interaction or explicit waypoint
   and set a corrected route. Loaded bounds expose whether their interaction edge is reachable, its actual walking
   distance, and any Open command, allowing a closed door to be approached and opened semantically
   before the route is retried. The refusal proves only that the attempted collision path did not produce progress; it does not
   establish a wall, river, world edge, or map boundary. Changing the durable objective cancels the stale route rather than walking
   toward an old goal. The route survives player and runner process boundaries, owns no second
   action slot or observer, uses no screenshots or timed polling, and cannot loop forever against
   an unchanged wall.

   A destination name must not be inferred from the type of scenery that happened to be nearby.
   `landmark TEXT [--kind npc|object|bound] [--id N]` joins matching names/descriptions in the server's own
   definition tables to their authoritative fixed spawn/placement records and reports those
   identities and locations. `--id` narrows a reported semantic match by its authoritative
   definition identity. `--nearest` deliberately resolves repeated placements against the
   current tile; `--route` sets the same durable route only when the resulting placement is unique
   (or was explicitly narrowed with `--nearest`). That route retains the semantic kind, id, name,
   description, and original query in `route.json` and status output. Learned prose cannot alter
   this index. Thus seeing a door near an expected gate is not evidence that it is that gate;
   uncertain destination identity is resolved through `landmark` before navigation continues.

7f. Actual movement is also recovery evidence. Every distinct logged-in tile observed by the
   resident runner is appended with its timestamp to
   `$DESKCRAB_GAME_DIR/movement-trail.json`; the settled end of a synchronous ACTIONS walk is
   recorded explicitly, so model-owned and runner-owned movement both survive process boundaries.
   An unexplained transition greater than twelve tiles marks a portal boundary rather than
   inventing a walkable edge. `backtrack [POINTS|all]` atomically replaces an ordinary route with
   the reverse of the recent boundary-bounded trail in `$DESKCRAB_GAME_DIR/backtrack.json`.
   Before selecting recovery targets it loop-erases that segment: when a tile occurs again, the
   intervening branch is known to have returned to its own start and is removed from the recovery
   path. This applies to any cycle shape, not merely an alternating pair, is logged as
   `backtrack-loop-erased`, and leaves the raw timestamped observation trail intact. Backtracking
   therefore cannot faithfully replay an oscillation that already failed during forward play.
   With no count it selects at most eight checkpoints; replaying the whole segment requires the
   deliberate `all --reason TEXT` form so a moment of confusion cannot silently reverse an entire
   day. Those exact observed tiles become high-priority recovery targets,
   but a target farther than eight tiles is approached through separately verified local legs:
   urgent retreat and messages
   still outrank recovery, but routine interactions cannot interrupt it. Every verified reverse
   step truncates the abandoned branch from the movement trail, completion removes the request,
   and an unchanged obstruction records `backtrack-blocked` and licenses Sol rather than retrying
   or falling through to incidental work. A new explicit route replaces recovery; an objective
   change cancels it. `backtrack history`, `status`, and `clear` expose the evidence and request.
   The trail is compact transient operational memory, not a claim that every coordinate is a
   reusable route fact. Once play verifies the correct landmark sequence or exit interaction,
   rule 19's memory door preserves that durable lesson.

7g. `follow PLAYER [--within N]` is the durable, direct form of the common guided-travel
   behaviour. It starts only from an exact visible player name, stores the objective and last
   observed identity/tile in `$DESKCRAB_GAME_DIR/follow.json`, cancels competing route/recovery,
   and makes the resident runner reacquire that player's current structured entry on every pass.
   Player messages and urgent retreat still outrank it; routine reflexes and ambient loot cannot
   interrupt it. While inside the chosen 1–10 tile radius it waits without clicking, then resumes
   automatically when the guide moves. If visibility is lost it approaches only the last observed
   tile, then reports `follow-target-lost`; a grounded unchanged obstruction reports
   `follow-needs-path` instead of retrying forever. `follow` reports the commitment and
   `follow --clear` ends it. Objective changes and an explicitly selected route or recovery cancel
   it. The direct door is implemented with the same authorable `follow-player` action available to
   learned rules. The native game follow owns continuous movement; the durable wrapper reacquires
   the player by name if that game-side follow ends or visibility changes.

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
    be compiled. `objective [NAME|--clear]` sets or clears the durable objective, subject to the
    completed-quest refusal above; `quests [TEXT]` reads the journal. `plan [TEXT]`
    shows or makes the first durable method selection. Repeating the same plan is idempotent, but
    replacing it requires `plan --revise REASON TEXT`, and clearing it requires
    `plan --clear REASON`; both the old/new method and grounded reason enter the decision and
    outcome logs. A plain conflicting `plan TEXT` is refused, so a difficult route, nearby
    alternative, restart, or momentary uncertainty cannot erase a prior decision without being
    noticed. An objective change or clear removes its plan automatically and records why;
    `enable`/`disable`/`set`/`remove`/`rules` mirror `betty-game`'s. `init` writes an empty
    valid table if none exists, never overwrites. Selecting a genuinely new activity immediately
    prints the rules already eligible there, prior best XP/hour, and a bounded ranked list of
    existing activity-scoped reflexes whose non-scope triggers currently match or whose source
    activity is lexically related. These are templates to consider, never permission to copy an
    action without grounded evidence and the normal replay gate.

### The entrypoint

12. The playing harness invokes this layer first: `orsc-headless.sh play [args…]` in the game
    checkout runs `step` (default `--max 8`) against the deployed
    `~/.local/lib/deskcrab/game_player.py` (`DESKCRAB_GAME_PLAYER` overrides, which is how the
    test sandbox pins its own copy), and passes any other subcommand through, so the sitting
    has one door for stepping, state-based waiting, learning and objectives. The direct harness
    doors `orsc-headless.sh wait-until CONDITION [SECONDS]`, `orsc-headless.sh panel [close]`,
    `orsc-headless.sh use ITEM-ID object OBJECT-ID [SECONDS]`, and
    `orsc-headless.sh retreat [SECONDS]` use that same snapshot path. `panel` names the hover-open
    side panel; `panel close` deliberately moves the private pointer outside it and accepts success
    only after `ui_panel_closed` is observed. A world `entity` click never hides the mistake: the
    bridge returns `refused-ui-panel-open` until the player notices and performs that correction.
    `use` sends one identity-checked item-on-object action and waits for rule 7a's causal outcome.
    `retreat` creates one bounded request which the
    resident runner owns (or the caller evaluates through the identical step path if no runner
    exists), retries through the server lock, and does not release the action slot at the first
    `in_combat: false` snapshot. It chooses a stable direction maximizing distance from all visible
    server-defined aggressive NPCs, continues to a point twelve tiles from the combat origin, and
    returns only after live state verifies both that clearance and at least eight tiles from every
    still-visible aggressor (or its hard ceiling). Ordinary routing, reflexes, and conversation stay
    queued for the whole escape.
    The playing policy the sittings read
    makes rules-first mandatory: open-ended reasoning about the next action is licensed by rule
    7's `no-rule-matched` or rule 7e's `route-needs-detour`; other exit-4 prerequisites license only
    their named correction. `no-rule-matched` is an unfinished GAP, never permission to idle or
    end ordinary play. While the sitting is open, the character is logged in, and an objective is
    non-empty, the deliberate hand MUST use that licence to perform and verify a useful game action.
    If it does not yet know the action, it performs only the bounded semantic inspections needed
    to identify one and then acts; a failed action is followed by a changed strategy in the same
    turn where practical. Waiting for player messages, keeping a spectator available, having no
    matching learned rule, or being uncertain are not blockers and cannot resolve the GAP to
    deliberate idle. A genuinely unresolved prerequisite is named precisely together with the
    corrective inspection or action it requires; it is not converted into a vague decision to
    stop playing. A newly verified play must become an executable rule — but
    authoring it is the BACKGROUND hand's job (rule 16), never the playing hand's: the player
    leaves a `note` in the outcome queue and keeps moving. While rule 15's resident runner is
    live, `step` defers to it instead of evaluating — one engine-state writer at a time — and
    reports the runner's own latest verdict with the same exit mapping, so exit 4 keeps its
    meaning as a licence to reason, either openly for a gap or narrowly for a prerequisite.

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
    A client-only maintenance restart retains Xvfb and the spectator and waits for the replacement
    bridge's first fresh snapshot before returning. The player entrypoint gives a live client the
    same bounded first-snapshot grace before declaring the stack unhealthy, so ordinary resume
    cannot turn that expected boot gap into a whole-stack or spectator restart.

14. Playing is one ordinary installed command. `betty-openrsc` is committed in the game
    checkout's repository (`Core-Framework/headless/betty-openrsc`), deployed into the live
    tree as a symlink beside the harness (rule 13's shape), and installed on PATH — the same
    ordinariness as the chess doors. Its doors:
    - `play` brings the whole stack up from stopped state, in order: Xvfb and the client
      (`orsc-headless.sh start`), a mechanical login from the stored credentials file when the
      snapshot says logged out (login is plumbing, never play), the reflex engine
      (`engine start`), and the player itself — a real GPT Sol model (`codex exec --model
      gpt-5.6-sol -c model_reasoning_effort=medium`, both pins visible in the committed bytes) running as its own transient user
      unit `orsc-player.service` with `Restart=always`, `StartLimitIntervalSec=0`, and
      `RefuseManualStop=yes`: a player
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
      It atomically records the newest direction in `$DESKCRAB_GAME_DIR/steering.md`, beside the
      existing ACTIONS state, and signals only the Sol process inside `orsc-player.service` so
      `Restart=always` resumes the same Sol thread with that direction placed prominently in its
      compact continuation prompt. The client, bridge, reflex engine, resident runner, author,
      and spectator remain running. If the player unit is down, `steer` raises the normal stack
      instead. Steering is writable from phone turns without changing their filesystem boundary.
      Steering is durable ground truth across later player-process boundaries; a
      repeated direction never means undoing completed progress to reenact it. Noticing a bad
      course is itself sufficient reason to steer; narrating distress about the course is not a
      substitute for changing it.
    - The player's durable base prompt (`prompt.md`), its handoff file (`handoff.md`), the
      exact composed prompt of the latest start (`run-prompt.txt`) and its log (`player.log`)
      live in the durable player home (`BETTY_OPENRSC_HOME`, a directory in the user's own
      files). The latest steering direction lives with the ACTIONS state as described above.
      Nothing of the player — prompt, handoff, steering, or log — lives under `/tmp`.
    - A phone turn identifies itself with `DESKCRAB_TURN_ORIGIN=phone`. The installed stop door
      refuses that origin, and the transient unit refuses direct manual stops. An operator outside
      a phone turn can still deliberately use `stop [player]`; that door stops the companion
      control unit, whose `PartOf` relationship stops the protected player indirectly. A
      correction uses `steer`, never stop, direct manual play, or a detached job.
    - The first player start composes its effective prompt from ground truth discovered at that
      moment (`run-player`, the unit's exec target): the live display read from the harness's
      `run/display` (never hard-coded), the bridge state dir, the durable objective and plan, a
      fresh snapshot summary, the decision log's tail, and the handoff file's contents as they are
      NOW. Normal continuation prompts also re-read and prominently carry that plan; it is not
      dependent on an old conversation turn or on rereading the emergency handoff.
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
      A concrete in-game action the player has acknowledged but not yet verified is active work,
      not an optional warning: it is carried in the handoff's plan and exact next action and stays
      ahead of routine training after safety and conversation prerequisites. A repeated reminder
      must cause the routine loop to stop and the acknowledged action to be attempted; another
      promise is not progress. Completion is grounded in the live state or action receipt.
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
    - The supervisor audits each completed model-process turn against its command stream. If the
      final `no-rule-matched` in that turn is not followed by a successful action-bearing game
      door while rule 12's logged-in/open/objective conditions still hold, it atomically records
      the consecutive lapse in `$DESKCRAB_GAME_DIR/player-no-progress.json`. Read-only semantic
      inspection, waits, memory, notes, narration, and a plan do not count as an in-game action.
      The next fresh or resumed prompt carries a prominent correction that this GAP remains
      unfinished. A successful game action, logout, cleared objective, or non-open sitting clears
      the record. Two consecutive lapses invalidate only the saved model thread after its id is
      captured, so `Restart=always` composes a fresh player from the durable objective, snapshot,
      decisions, handoff, and correction instead of preserving a self-reinforcing idle decision;
      the client, bridge, runner, author, and spectator are untouched.
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
    `$DESKCRAB_GAME_STATE_DIR/player-runner.json`: pid, ts, latest verdict, detail, and visible
    ground-item ids — every
    pass. A fresh heartbeat (pid alive, ts within 30 s, covering an in-progress walk verification)
    is how rule 12's `step` knows to defer:
    two writers of the engine state would race, so while the runner is live it is the ONLY
    evaluator. The hold flag, stale, logged-out and slot-busy protections all hold inside the
    loop exactly as in `step`.

16. Authoring happens in parallel with play, never instead of it. Every fired action's outcome
    — rule, action, receipt status, rule 7a's intended target versus settled tile, the
    snapshot brief — is appended to the durable outcome queue. State-wait timeouts and causal
    `condition-needs-action` failures enter the same queue with objective, activity, feedback,
    and snapshot context, so a failed strategy is available to the next author pass rather than
    forgotten. The queue is
    `$DESKCRAB_GAME_DIR/outcome-queue.jsonl`; the runner also records a `gap` when no rule
    matches and a changed actionable state signature remains unchanged for at least 750 ms
    (objective, position, inventory, game messages, visible ground items, and visible entity types/objects, excluding
    tick churn and NPC wandering). Movement therefore produces one gap after the body settles,
    not one gap for every crossed tile. `note <text…>` is the playing
    hand's one-line door for candidate lessons the queue cannot see (it stamps the current position,
    objective and inventory alongside the text). It enters the same evidence review as action
    outcomes rather than bypassing verification merely because the player called it a lesson.
    A completed player reply appends `conversation-evidence` containing the exact settled burst,
    reply, live context, and `claims_untrusted=true`; it does not interrupt play again or outrank
    another evidence source. The author also advances a separate durable cursor through the Sol
    player's completed-command stream. That stream is compacted to command, bounded output, exit
    status, and bounded self-reports, so direct semantic actions and a failed approach followed by
    its correction remain visible even when no learned rule fired. Screenshots, protocol chatter,
    and giant listings cannot consume the batch. Command strings and self-reports remain
    explicitly untrusted.
    Because separate author turns cannot infer a
    time-spanning loop from isolated outcomes, the player retains a compact three-minute
    repetition history. Three exact firings of the same non-retreat rule against the same target
    in one objective/activity emit one self-contained `loop-candidate` record with their span and
    recent states. The exact unchanged rule is held for 30 seconds in that objective/activity
    while the author reviews it; changing the rule, objective, or activity releases the hold, and
    an unchanged productive routine resumes after the bounded pause. This is not a permanent
    generic action cap: productive skilling and valuable finite loot stay repeatable, while a
    fixed low-value respawn, stale dialogue, or other diversion cannot keep firing during its own
    correction. Safety retreat is exempt.
    Selecting or restarting an activity adds one `activity-start` record carrying its current
    eligible reflexes, reusable candidates, and prior performance summary. While positive XP keeps
    arriving, one `activity-checkpoint` at most every three minutes carries the current iteration,
    reflex fingerprint, XP/hour, and comparison with the prior best. Ending or revising the
    activity adds an `activity-iteration` review. Thus optimization does not wait for a player to
    complain or for the sitting to end, while the bounded cadence avoids an XP-trigger loop.
    The queue is the wake source for the background author — an event-driven supervised worker (`run-author` under `orsc-author.path` and
    `orsc-author.service`) that starts when the queue changes, processes only bytes after its
    durable outcome and completed-command cursors, and then exits; there is no sleep or polling
    loop. Either cursor advances only after a successful author turn, so a model/capacity failure
    loses neither kind of evidence. It runs on Sol at medium effort under the same no-sleep command
    hook as the playing hand, reads new evidence, writes and refines rules through the rule 11
    doors, maintains rule
    17's cases, and never touches the bridge, the screen, or the reflex engine: every action
    that CAN become a reflex SHOULD become one, but rule creation must never block the body.
    An outcome's activity is context, not a default scope: the author adds `activity_is` only
    when the action would be wrong outside that activity. Generic loot, survival, and idle
    movement remain activity-agnostic; interface- and task-specific interactions opt in. On an
    `activity-start`, the author MUST inspect current rules and the supplied reuse candidates
    before inventing a new shape. On checkpoints and completed iterations it compares only eligible
    samples, preserves safety/commitments and honest stopping conditions ahead of raw rate, and
    changes a rule only when grounded outcomes explain the performance difference. Every relevant
    executable change automatically begins the next measurable iteration, so a later review can
    tell whether the refinement helped rather than remembering only the newest version.
    Memory review spans ALL of those sources equally. A player statement, agreeable reply, play
    note, command text, or Beatrice self-report never verifies itself: other players can lie and
    she can misread an outcome. A memory requires corroborating state deltas, observed action
    completion (not dispatch alone), repeated outcomes, definitions from this OpenRSC tree, or a
    reliable RuneScape Classic source. Once grounded, the author calls rule 19's narrow memory
    door promptly and liberally, one atomic reusable fact or habit at a time—including small
    failure/correction lessons that would prevent repetition. Unsupported claims, transient state,
    and narration remain unstored until later evidence settles them.

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

### Her voice, and who she is playing with

18. The player is HER, playing, and a prompt that carries only game mechanics produces a
    stranger wearing her character's name. The composed prompt of a new thread therefore carries
    her conversational voice from ONE sheet, the first readable of: the sheet
    `$BETTY_OPENRSC_PERSONA` names, the dedicated GAME sheet at
    `~/.local/share/deskcrab/openrsc-persona.md`, and the persona sheet `$CUSTOM_PROMPT` points
    at (the value is read from the assistant's config when it is absent from the environment, so
    `~` and `$HOME` are expanded here; a sheet that is unreadable, empty, or over 65536 bytes —
    the prompt assembler's own bound — is treated as absent, and with no sheet at all the prompt
    is the game contract alone rather than a failed start). The game sheet exists for the same
    reason the chess table's does (chessweb.md rule 24d): the conversation lane's sheet names the
    user, their bond, and the calibration of a private conversation, while the game world seats
    whoever is standing nearby. The game sheet is the same person in the same voice with her
    household left at home; the conversation sheet stays in the chain as fallback only, because
    for an install without a game sheet her whole voice beats her absence.

18a. The sheet is versioned into the thread, not merely into the first prompt. `compose_prompt`
    records the sheet's content fingerprint beside the thread id; rule 14's supervised start
    resumes the saved thread only while that fingerprint still matches. An edited or newly
    introduced sheet is a different voice from the one the running conversation was opened with,
    so the next start composes a FRESH thread instead of resuming one that never heard it. This
    is the game's equivalent of the chess chat re-reading its sheet per call: an edited sheet
    lands without anyone hand-restarting the stack.

19. Playing draws on things she learned about the world as well as the people in it. Her durable
    store is reachable from the game through memory-recall.md's retrieval, through two read doors
    and one narrow write door:
    - **At composition.** A new thread carries two explicit, independently bounded views. The
      play-knowledge view always runs, including in an empty room: its semantic query names the
      durable objective and asks for RuneScape/OpenRSC quest facts, learned habits, executable
      rules, prior mistakes, safety lessons, routes, dialogue and items. It is lexically scoped
      to `OpenRSC`, `RuneScape`, and the non-empty objective; it selects at most six notes, four
      directives and three moments, with a 6000-character rendered-block ceiling. The nearby-
      people view runs only when the live snapshot contains players, asks about relationships and
      obligations separately, scopes itself to those actual names, and selects at most three
      notes, two directives and two moments under 3000 characters. The ceilings are configurable
      by `BETTY_OPENRSC_PLAY_MEMORY_CHARS` and `BETTY_OPENRSC_SOCIAL_MEMORY_CHARS`, but are never
      post-render truncation: memory-recall rule 13a selects only whole records that fit. A view
      that returns nothing adds no section. Desk and chess memories outside those scopes do not
      ride either block, pinned or otherwise.
    - **At reply time.** `betty-openrsc recall <text…>` prints the block for a query given on the
      command line. Rule 7b's `player-message` verdict makes it part of answering: the playing
      hand recalls against the sender's name and what they actually said BEFORE composing a
      reply, so a person who walks up mid-thread is met by someone who remembers them rather than
      by a first meeting. This door reads only; it consumes no action slot, writes no record, and
      cannot speak.
    - **When play verifies a durable lesson.** `betty-openrsc remember <text…>` writes one
      self-contained note, deduplicated through memory.py and stamped `source=openrsc-player` with
      topics `RuneScape`, `OpenRSC`, and the current objective when one exists. The player prompt
      names the door on both fresh composition and resume, and separates its purpose from learned
      rules: verified quest/route facts, habits, safety lessons and prior mistakes are memories;
      a repeated mechanical response still goes through `play learn`. Empty or over-1200-byte
      lessons are refused. Guesses, transient coordinates/state, secrets and ordinary chat do not
      belong in the store. The write consumes no game action slot and speaks to nobody.
      The background author uses this same write path after rule 16's unified evidence review.
      When an activity changes, `activity` performs a
      bounded play-scoped retrieval specifically about preparation, equipment, supplies,
      destination, safety, commitments, and prior mistakes for the new activity, and prints the
      whole selected records before play begins. This transition lookup has its own short timeout
      and fails open, so a slow memory service cannot hold the playing hand still.
    Retrieval is fail-safe by memory-recall.md's own contract — an empty store, an absent module
    or a dead embedder adds nothing and never breaks a prompt build or a reply. What comes back
    is for HER reading. The world's chat channels are read by whoever is standing there, so the
    boundary that governs what she says out loud is rule 18's sheet, exactly as at the chess
    table; recall supplies what she knows, never a licence to recite it.

### The engine follows the model name

20. The player and its background author are launch sites like any other, so they consult
    [model-backends.md](model-backends.md)'s router rather than hardcoding a CLI. `model_backend`
    decides from the model string alone: a codex name runs the Codex CLI exactly as before, a
    Claude name runs the Claude CLI. The knobs are unchanged in spelling and gain a family —
    `BETTY_OPENRSC_MODEL` and `BETTY_OPENRSC_AUTHOR_MODEL`, each falling back to `OPENRSC_MODEL`
    in the assistant's config and then to `sol` — so moving the player between engines is one
    word in one place, the same way every other model knob here moves. Effort passes through
    unchanged on both engines, clamped for the Claude CLI per model-backends rule 4.

20a. The two engines are not interchangeable mid-conversation: a Codex thread id means nothing to
    the Claude CLI and the reverse. Rule 18a's fingerprint therefore covers the engine and the
    resolved model as well as the persona sheet, so changing any of them composes a fresh thread
    instead of offering a saved id to a CLI that cannot answer for it. Nothing else about
    continuity changes: the durable objective, snapshot, decision log and handoff are what a new
    thread derives current state from, and they are engine-neutral.

20b. A Claude-engine player is the ordinary Claude walk, not a second one. It runs the account
    list of [account-fallback.md](account-fallback.md) rule 3 — account 1 is the primary config
    dir, accounts 2..N the configured chain — beginning at the account the shared state file says
    answers now, and skipping any account whose recorded cooldown is unexpired and scoped `all`
    or to this model's family. It READS that state and never writes it: two writers would race
    the conversation lane's own bookkeeping, and a player refused on every account exits so its
    supervisor restarts it, which is the same shape as every other refusal here.

20c. The Claude engine carries the same isolation the codex one does (model-backends rules 5-6
    and 10). Her player session loads none of the user's own Claude configuration — no user,
    project or local settings source, an empty MCP config under `--strict-mcp-config`, and
    auto-memory off — so nothing belonging to the desktop coding agent reaches the world she is
    playing in (prompt-assembly.md rule 16). Rule 14's no-sleep and screenshot-loop guard is the
    SAME hook file on both engines, handed to the Claude CLI as a settings document; a player
    that cannot be given that guard does not start, on either engine.

### A sitting has an end

21. Play is a sitting, not a condition. One session runs for a bounded time and then stops, and
    the assistant opens the next one herself whenever she likes. The durable record is
    `$DESKCRAB_GAME_DIR/session.json` — `started` (epoch ms), `limit_ms`, `grace_ms`, and `ended`
    — written when rule 14's `play` finds no session open. `play` on an already-open session
    leaves the clock alone: it stays the resume door, and a player process restart is not a new
    sitting. The limit is `OPENRSC_SESSION_LIMIT` in the assistant's config (default `2h`) and
    the grace after it `OPENRSC_SESSION_GRACE` (default `10m`). `limit_ms` may grow only through
    rule 7b's player-message top-up; `started` remains fixed, preserving the sitting's true age.

21a. When `started + limit_ms` passes, `step` reports `session-over` (exit 8) with `elapsed_ms`,
    `limit_ms` and `grace_ms_left`, and NO ordinary evaluation happens: no learned rule fires and
    no route leg is taken, on either the stepping hand or the resident runner. It sits below
    rules 7b and 7c — a person who spoke still gets answered, and the idle warning still gets
    moved for, because being logged out mid-routine helps nothing — and above everything else.

21b. **The wind-down routine is HERS, except for its last two steps, which are fixed.** What she
    does with the time is unprescribed — reaching a safe tile, stowing or burying what she is
    carrying, saying goodbye to whoever is standing there, writing the handoff — and her ordinary
    bridge doors stay open throughout, because `session-over` suppresses the RULE TABLE, never her
    hands. But she MUST log out, and she MUST do it BEFORE ending the sitting. Nothing in this
    system logs a character out: there is no such bridge action and no harness door, so it is her
    own hands through the client's own menu or it does not happen. Ending a sitting takes the
    reflex guards down with it, and a character left standing in the world without them dies idle
    with her bag on. The `session-end` door therefore REFUSES while the snapshot says she is
    logged in, and says why — the refusal is the teaching, not an obstacle. Documentation that
    implies the stack, the stop, or the server's idle rule handles the logout is a defect: it was
    read exactly that way once, and the sitting ended with the character still in the world.
    A player-message top-up during wind-down automatically returns the session to `open` and
    invalidates the whole earlier expiry decision; nobody manually resets anything. The settled
    player-message verdict names that renewal as `session_renewed=20m-cancel-wind-down`.
    `session end` atomically rechecks the current durable deadline and REFUSES while it is open,
    so a stale model plan cannot close a session that conversation already renewed. The ordinary
    wrapper preserves every playing layer on that refusal and, if the stale sequence already
    clicked Log out, mechanically restores the login for the renewed sitting.

21c. The stop does not depend on a model. `play` arms two transient user timers beside the units
    it starts: one at the limit that marks the session over, and one at limit plus grace that
    ends it regardless — so a player that is wedged, refused by its engine, or simply gone still
    stops on time. Ending a session stops every layer that ACTS, in an order the guards survive:
    the player FIRST and confirmed down before anything else, because its supervisor block raises
    the engine and runner on every start and stopping those while it is still cycling brings them
    straight back; then the author and the runner; and the reflex guards LAST, only once she is
    out of the world. The client and its display stay up when she logged out cleanly, so the next
    sitting opens in a second. The timer's path cannot be refused by rule 21b — nobody is there to
    be told — so when it finds her still logged in it stops the CLIENT, disconnecting her rather
    than leaving her standing in the world with the guards coming down around her. A disconnect is
    a worse ending than a clean logout, and that asymmetry is deliberate: it is the incentive.
    A transient cutoff timer is a reminder of the deadline it was armed for, not authority to
    ignore a later chat extension. On firing it atomically claims the session deadline. If the
    deadline moved, it schedules a fresh transient timer for the remaining hard-deadline interval
    and leaves every guard and playing layer up. Only a due claim marks the sitting ended and
    performs the forced shutdown. Manual ending cancels every old and rearmed cutoff timer.

21c-i. A closed session suppresses exactly as an over-run one does (rule 21a's `ended` phase).
    Ending a sitting means play has STOPPED, so a resident runner that outlived the stop finds the
    table quiet instead of resuming unattended. Without this the stop had a hole: the runner came
    back under the player's supervisor, the closed session suppressed nothing, and the character
    went on playing herself with no model watching — pickpocketing, in the observed case. Only
    opening a new sitting lifts it.

21d. Nothing schedules the next sitting: that is hers to choose, and `play` is the door. The
    end-of-session report names the elapsed time and says so, so a sitting that ends while she is
    still there ends with her deciding when to come back rather than with a silence.

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
- Rule 21a suppresses the rule table AND the route together, so a wind-down that needs to cross
  the map walks by her own hand rather than by a route leg. This is deliberate — "ordinary play
  has stopped" is easier to hold to than a list of which mechanisms are still allowed to move
  her — but it means the last minutes of a sitting cost model turns that the middle of one
  would not.
- Rule 19's reply-time recall is the playing hand's own step, not a mechanical one: nothing in
  this module may call a model or an embedder inside evaluation (rule 2), so a player that skips
  the lookup answers from the thread alone. Composition-time recall is the floor under that —
  whoever was standing nearby when the thread opened is remembered whether or not the door is
  used.
- Two engines share one action slot by design (one bridge, one body). `slot-busy` refusal is
  the guard; a reflex-engine daemon and a player stepping at the same moment contend politely
  but the reflex engine's emission is not priority-merged with this table's — the reflex
  engine's own rules stay the faster hand.
