# game-reflex — visible state into sub-second actions

## PURPOSE

Playing a real-time world cannot mean a reasoning turn per urgent moment: by the time a model call
returns, the fight is over. This layer is the fast body — a trigger-action machine that watches the
**visible** game state and answers time-critical moments (eat when health is low and food is in the
bag, run when it is low and the bag is empty, warn when a threshold is crossed) in well under a
second, mechanically, with **no model call anywhere in the loop**. Deliberate play — goals, routes,
spending, conversation — stays where it always was; this layer only executes the habits the player
has explicitly written down, and every habit is a named, tunable, disableable rule rather than a
buried constant.

The first game is the local single-player OpenRSC world, through a small bridge compiled into that
client. The engine itself knows nothing OpenRSC-specific beyond the trigger and action vocabulary,
which is a closed list this spec owns.

Three parts:

- **the bridge** — a per-tick hook inside the game client (`orsc/ReflexBridge.java` under
  `Core-Framework/Client_Base/src` in the local OpenRSC checkout, not this repo). It publishes a
  snapshot of what the player can see and executes the small closed set of actions. It holds no
  opinions: no thresholds, no rules.
- **the engine** — `lib/game_reflex.py`, stdlib only, run as `betty-game run`. It reads snapshots,
  evaluates the rule table, and emits at most one game action at a time.
- **the rule table** — a durable JSON file the player views and edits through `betty-game`.

## CONTRACT

### Files and places

1. Ephemeral exchange lives in `$DESKCRAB_GAME_STATE_DIR` (default `/tmp/deskcrab-game`):
   `state.json` (bridge → engine), `action.json` (engine → bridge, game channel), `notice-<id>.json`
   (engine → bridge, the notice queue — one file per notice firing), `receipt.json` (bridge → engine),
   `hold` (the override flag,
   either side may create it), `decisions.jsonl` (the engine's event log), `engine-state.json`
   (the engine's own counters, so cooldowns survive a restart). Durable configuration lives in
   `$DESKCRAB_GAME_DIR` (default `~/.local/share/deskcrab/game`): `reflex-rules.json` and
   `food-heals.xml`. Every path is overridable by those two variables alone; the test sandbox pins
   both.

2. Every file either side writes into the exchange directory is written atomically: temp file in
   the same directory, then rename. A reader never sees a half-written snapshot or action.

### The snapshot

3. The bridge writes `state.json` at least every 250 ms while the client runs — **including at the
   title and login screens**, where it carries `logged_in: false` and nothing else of substance.
   The snapshot is one JSON object: `v` (format version, this document describes 1), `ts` (epoch
   milliseconds at write), `tick` (a counter that increments every client game tick since launch),
   `logged_in`, and, when logged in: `hits` and `hits_max` (the Hits skill, current and base),
   `fatigue` (0–100), `skills` (every skill's `id`, `name`, base `level`, and cumulative `xp`),
   `x` and `z` (world coordinates), `walking` (the local player still has
   an unconsumed client waypoint, or a movement-capable bridge action was dispatched within the
   last second and may still be waiting for its server path), `in_combat`,
   `right_click_menu_open` (the ordinary world context menu is visibly open), `menu_options`
   (its live visible entries as colour-free text, otherwise empty), `trade_open` (either ordinary
   player-trade screen is visible),
   `talking_to_npc` (an NPC choice menu is open or
   the client received NPC-spoken quest dialogue within the last four seconds; NPC speech is the
   quest-channel `Name: words` form with an empty sender, not the local player's named reply), `opponent`
   (`{"x":…,"z":…}`
   while a fighting opponent is visible, else `null`), `inventory` (array of `{"id":…,"count":…}`
   in slot order), `messages` (the last 20 messages seen by the client, newest last; each is
   `{"id":…,"channel":…,"incoming":…,"sender":…,"text":…}`, where `id` is unique across
   client restarts, `channel` distinguishes `local`, `private`, and non-player message types, and
   `incoming` is true only for chat received from another player), `players` (other players the
   client currently holds as visible, nearest first, capped at 24: each
   `{"sidx":…,"name":…,"x":…,"z":…}`), `npcs` (the NPCs the
   client currently holds as loaded, nearest to the player first, capped at 64: each
   `{"sidx":…,"id":…,"x":…,"z":…}` — the client's own server index for that NPC, its type id, and
   its world tile), plus `npc_count` (the complete loaded count) and `npcs_truncated` (whether the
   64-entry safety cap omitted anything). Scenery does not occlude this list: an absent NPC is
   outside the client's loaded set or, when explicitly marked, beyond the cap; the snapshot never
   establishes a fence as the cause. `objects` (the game objects — scenery: fishing spots, gates, ranges, trees —
   the client currently holds as loaded, nearest first, capped at 12: each
   `{"id":…,"x":…,"z":…,"dir":…}` — type id, world tile, facing direction), and `bounds` (the
   wall objects — doors and other boundaries — likewise nearest first, capped at 12, the same
   four fields; `dir` is which wall of the tile the boundary stands on, so two doors sharing a
   tile stay distinct), `ground_items` (items currently visible on the ground, nearest first,
   capped at 12: each `{"id":…,"x":…,"z":…}` — item id and world tile), `shop_open` and
   `bank_open`, plus `shop_items` and `bank_items`. A shop item is
   `{"slot":…,"id":…,"name":…,"count":…,"noted":…}` from the open shop's 40-slot
   display. A bank item is `{"slot":…,"id":…,"name":…,"count":…}` from the complete
   item list the open bank interface has already received; it is empty while the bank is closed.
   Only what the
   player's own client can see is ever in it; the bridge reads
   no server internals.

4. The bridge is **inert by default**. It activates only when `DESKCRAB_GAME_STATE_DIR` is present
   in the client's environment; the stock launcher does not set it, so the plain client is
   byte-for-byte unaffected in behaviour. A separate launcher script beside the stock one is the
   opt-in door: `launch-client-reflex.sh`, **committed at the root of the same Core-Framework
   checkout that carries the bridge** — it exports `DESKCRAB_GAME_STATE_DIR` (respecting a value
   already set) and hands over to the stock launcher it finds beside the checkout; the callable
   file next to the stock launcher is a symlink to that committed copy, so both routes run the
   same versioned bytes. The bridge suite pins all three properties: the launcher is under
   version control, the stock launcher never mentions the variable, and executing the committed
   bytes sets the exchange directory before handing over.

### Actions

5. The action vocabulary is closed, and grows only by a change to this spec: `eat` (use one
   inventory food item, by slot), `walk` (walk toward an absolute tile; `flee` in a rule compiles
   to this), `warn` (display a local client-side message to the player — nothing is sent to the
   server), `chat-local` (send public chat to nearby players), `chat-private` (send a private
   message to a named online player at any distance), `talk-npc` (initiate dialogue with a currently visible NPC by server index — the
   same walk-and-talk the player's own Talk-to menu entry performs; it addresses server-defined
   NPCs only and structurally cannot message another player), `interact-npc`
   (perform command 1 or 2 from a visible NPC's own definition — the same
   walk-and-command as its context-menu entry, without reconstructing that menu), `interact-object` (perform a menu
   command on a loaded game object at an absolute tile — the same walk-and-act the object's own
   right-click Command entry performs; `cmd` 1 or 2 picks the object definition's first or second
   command, so a fishing spot's Net and Bait, a gate's Open, a range's nothing-at-all are all the
   game's own menu, never an invented verb), and `interact-bound` (the same for a wall object —
   a door or other boundary — at a tile and wall direction; Open and Close are its usual
   commands), and `click-entity` (move the private display's pointer to a currently rendered NPC,
   game object, or wall object identified by stable game identity, then click button 1, 2, or 3),
   `click-inventory` (find an inventory item by item id, open the inventory tab, resolve the
   current slot centre, and click button 1, 2, or 3), `click-shop` and `click-bank` (find an item
   by id in the currently open interface, expose its containing page or scroll row, resolve its
   current slot centre, and click button 1, 2, or 3; bank identity covers
   inventory items shown for deposit even when no bank stack exists),
   `bank-deposit` / `bank-withdraw` and `shop-buy` / `shop-sell` (send the
   open interface's ordinary transaction by item identity and positive amount,
   without selecting a row or an amount button), `trade-player` (send the ordinary Trade-with
   request to a currently visible non-local player by server identity), `choose-menu` (choose an
   option from the context menu that is open now by a case-insensitive text fragment; an absent or
   ambiguous fragment is refused), `take-ground` (walk to and take a
   currently visible ground item identified by item id and world tile), and `retreat` (while in
   combat, choose a collision-map-reachable walk away from an identified opponent or a supplied
   fallback direction, trying alternate directions and nearer tiles without sending failed path
   probes). `talk-npc`,
   `interact-object`, `interact-bound`, `click-entity`, `click-inventory`, `click-shop`,
   `click-bank`, the four bank/shop transaction actions, `trade-player`, `choose-menu`, `take-ground`, `retreat`,
   `chat-local`, and `chat-private` belong to the deliberate-play
   channel — an action file written by the player's own hand or harness — not to
   reflex rules: the engine's rule-action vocabulary stays `eat`, `walk`/`flee`, and `warn`
   (rule 9). The reflex table cannot author speech. Nothing in this layer can log in, create or
   delete a character or drop. Trading is available only through a deliberate player action;
   neither executable rule table can initiate it. Spending through `shop-buy` is available
   only to a deliberate action; it is absent from both executable rule tables.
   The bridge refuses any action type it does not know.

6. `action.json` and every notice file are flat `key=value` lines: `ts` (epoch ms when the engine
   emitted it), `id` (the engine's monotonically increasing action id), `type`, then the type's
   parameters (`slot` and `item` — the item id the engine saw in that slot — for eat; `x`, `z`
   for walk; `text` for warn and chat-local; `target` and `text` for chat-private; `sidx` and `npc` — the server index and the type id the emitter saw
   there, the latter deliberately NOT named `id` so it can never collide with the action id line —
   for talk-npc and interact-npc (the latter also carries `cmd` 1 or 2), so a despawned or swapped NPC is refused as `refused-no-such-npc` or
   `refused-npc-mismatch`, never talked to blind; `x`, `z`, `obj` — the object type id, NOT named
   `id` for the same collision reason — and `cmd` for interact-object, so an unloaded or swapped
   object is refused as `refused-no-such-object` or `refused-object-mismatch` and a `cmd` outside
   1–2 as `refused-bad-command`; `x`, `z`, `dir`, `obj`, `cmd` for interact-bound, matched on
   tile AND wall direction, refused as `refused-no-such-bound` / `refused-bound-mismatch` /
   `refused-bad-command` the same way; `kind` (`npc`, `object`, or `bound`) and `button` for
   click-entity, plus the same identity fields as that entity's normal action; `item` and `button`
   for click-inventory, click-shop, and click-bank; `item` and `amount` for the
   four transaction actions; `sidx` for trade-player; `text` for choose-menu; `x`, `z`, and
   `item` for take-ground; `distance` 1–10 and fallback `dx`/`dz` for retreat). The bridge resolves
   the identity against the current client arrays at execution time, obtains that exact entity's
   latest rendered screen point, and emits pointer move then click as one bridge operation. A
   missing, swapped, or off-screen entity is refused with the same identity refusal or
   `refused-not-on-screen`; no screen coordinates cross the action file. For click-inventory it
   finds the first matching current item id, opens the inventory tab, and calculates the slot
   centre from the current client UI; a missing item is `refused-no-such-item`. No slot or screen
   coordinate crosses the action file. `click-shop` and `click-bank` use the same identity-only
   contract. A closed interface or missing item is refused; for a bank item the bridge switches
   the live bank to the page or scroll row containing the item before resolving its slot centre.
   A transaction rechecks that its interface is open and that its item has a
   positive live quantity in the relevant source (shop stock, bank, or
   inventory), clamps an overlarge request to that quantity, and then sends the
   ordinary client transaction. Amount zero or negative is refused.
   `trade-player` re-matches the server index against the current visible player list and refuses
   a vanished player. `choose-menu` strips client colour tags, normalizes case and whitespace,
   prefers one exact full-label match, and otherwise requires exactly one containing match; it
   never guesses between two options.
   `take-ground` re-matches the item id at the named tile
   immediately before sending the game's own walk-and-take action; a missing tile or changed item
   is refused rather than taking a replacement. `action.json` is a single slot: one action, and the engine never
   writes a second while one is in flight (rule 10). A notice is **never** a single slot: each
   firing is written to its own `notice-<id>.json`, named by the same monotonic id it carries, so
   two notice rules firing on one snapshot — or on adjacent snapshots inside one bridge tick —
   can never overwrite each other; every firing the log records is a file the bridge will see.
   The engine sweeps notice files whose `ts` has aged past rule 7's 1500 ms freshness window (the
   bridge would drop them as stale anyway), so an exchange directory with no bridge attached
   cannot fill without bound; the sweep runs only in the live loop, never in replay.

7. The bridge polls `action.json` and the notice queue every client tick. It executes at most one
   game action per tick from `action.json`, then deletes the file; it drains the notice queue
   oldest id first — numeric id order, not filename order — at most 8 notices per tick, the rest
   waiting their turn with order preserved. Before executing anything it checks, in order: the
   client is logged in, the `hold` flag is absent, and `ts` is no older than 1500 ms. An `eat`
   additionally executes only when the named slot still holds the named `item` and that item's own
   first inventory command is eat or drink — a shifted bag or a poisoned food table must not make
   the bridge consume, bury, or light something else. A check that fails still deletes the file
   and, on the game channel, writes the receipt with status `held`, `stale`, or `refused-<why>` —
   a refused action is never silently dropped. Notices need no receipt; `action.json` always gets
   one: `receipt.json` carrying `id`, `status` (`done` or the refusal), and `ts`. A `walk` uses
   the client's collision map and pathfinder. If its destination is outside the currently loaded
   map, the client clips the request to the edge of the current region in the destination's
   direction, searches that edge for a reachable alternative when the direct crossing is blocked,
   and dispatches one regional leg. A later action re-plans from the resulting live region; no
   guessed intermediate coordinates cross the action file. If the destination is already loaded,
   the walk remains exact. A walk for which no progressive local path exists is
   `refused-no-path`, never `done`. A retreat tries the requested distance first in its preferred
   direction, then alternate directions and shorter nonzero distances, and sends only the first
   pathfinder-approved ordinary walk. With no reachable candidate it reports
   `refused-no-retreat-path`. Its `done` receipt remains dispatch only: the server's three-opponent-
   hit escape lock is authoritative, and the game-player layer verifies `in_combat: false` before
   calling the retreat complete. Chat text and
   private targets must be non-empty single lines; text is capped at the client's 80-character
   input limit and targets at 40 characters. `click-entity`, `click-inventory`, `click-shop`, and
   `click-bank` accept only mouse
   buttons 1, 2, and 3, and never fall back to coordinates supplied by the caller. Invalid values
   are refused rather than truncated.

8. The bridge may never break the game: every per-tick step runs inside a catch-everything guard,
   and after 5 consecutive failing ticks the bridge announces once (a local client message) that it
   has disabled itself, and goes quiet until the client restarts.

### Rules

9. `reflex-rules.json` holds `defaults` (`stale_ms` 2000, `poll_ms` 150, `min_action_interval_ms`
   600, `max_actions_per_min` 20, `inflight_timeout_ms` 2000, `eat_pick` `min`) and `rules`, each:
   `name` (unique), `enabled`, `channel` (`game` or `notice`), `priority` (higher wins),
   `cooldown_ms`, `hold_ticks` (the trigger must be true on this many consecutive snapshots before
   firing — the debounce), `trigger` (a set of named conditions, all of which must hold), and
   `action` (`type` plus parameters). The trigger vocabulary is closed: `hp_below` (fraction of
   `hits_max`, 0–1), `requires_food` (inventory holds an item in the food table), `no_food` (it
   holds none), `in_combat`, `fatigue_above` (fraction, 0–1). An unknown trigger key, action type,
   channel, or out-of-range value is refused loudly at load and by `betty-game set`/`add` — a rule
   that cannot be evaluated must not sit in the table looking armed.

10. Engine evaluation, once per fresh snapshot: rules are considered in descending priority.
    Notice-channel rules fire independently (each is only bound by its own cooldown and
    `hold_ticks`), and every firing lands in its own queue file (rule 6) — when two notice rules
    fire on one snapshot, both are delivered, neither overwritten. Game-channel rules compete for
    one slot: the highest-priority eligible rule
    fires; every other eligible game rule is logged as a conflict loss, not fired. A game action
    fires only when no previous game action is in flight (receipt received, or
    `inflight_timeout_ms` passed), at least `min_action_interval_ms` after the previous one, and
    under the `max_actions_per_min` cap. Cooldown starts when a rule fires. A trigger that is true
    while its cooldown runs is logged as suppressed once per blocked episode.

11. Stale-state protection: a snapshot whose `ts` is older than `stale_ms` fires nothing, and the
    engine logs the transition into and out of staleness. A snapshot with `logged_in: false` fires
    nothing and resets every rule's `hold_ticks` counter. The engine never acts on a tick it has
    already acted on.

12. `eat` picks the slot: among inventory items in the food table, `eat_pick: min` (the default)
    takes the lowest heal value — a panicked early eat wastes the least — and `max` the highest.
    The food table is `food-heals.xml`, in the game server's own `ItemEdibleHeals.xml` format
    (item id → heal), installed by `betty-game init --food-xml <path>`. `betty-game run` refuses
    to start while any **enabled** rule needs the food table and the table is missing or empty —
    an eat rule that can never find food must not sit there looking like protection.

13. `flee` compiles to `walk`: when the snapshot shows a fighting opponent, the destination is
    `distance` tiles (default 5, clamped to 15) directly away from it, per-axis; otherwise
    `distance` tiles along the rule's configured `dx`/`dz` unit direction (default south).
    The engine clamps every walk to at most 15 tiles from the player's position.

14. The shipped default table carries exactly three rules: `warn-low-health` (notice channel,
    enabled, `hp_below` 0.5), `eat-low-health` (game, **disabled**, `hp_below` 0.5 +
    `requires_food`), and `flee-starved` (game, **disabled**, `hp_below` 0.35 + `no_food`). The
    game-channel rules ship disabled deliberately: a reflex is enabled by the player's own hand
    after the moment that justifies it, never inherited pre-armed from a default file.

### Override

15. The `hold` flag is the manual override, honoured at **both** ends: while it exists the engine
    emits nothing (checked every loop iteration, so within `poll_ms`), and the bridge executes
    nothing (checked immediately before every execution, so an action already emitted still dies).
    `betty-game hold` creates it, `betty-game resume` removes it, `betty-game state` shows it.
    Stopping the engine process is always sufficient by itself: no emitter, no actions, and
    anything already emitted goes stale inside 1500 ms (rule 7).

### Logging and replay

16. Every engine decision is an event line in `decisions.jsonl`: fired actions (with the snapshot
    values the trigger read), conflict losses, cooldown suppressions, stale and logged-out
    transitions, hold transitions, receipts as they are consumed, and refusals. `betty-game log`
    tails it. `betty-game run --record <file>` additionally appends every snapshot evaluated, and
    `betty-game replay <file>` re-evaluates a recording through the current rule table, printing
    what would have fired, writing **no** action or notice files anywhere.

### The CLI

17. `betty-game` (a thin wrapper on `lib/game_reflex.py`, plain python3, no venv) exposes:
    `state` (the current snapshot, its age, and the hold flag), `rules` (the table with priority,
    channel, enabled, trigger, cooldown), `actions` (the action vocabulary and each type's
    parameters), `enable <rule>` / `disable <rule>`, `set <rule> <key> <value>` (dotted keys reach
    trigger and action parameters), `add` / `remove`, `hold` / `resume`, `run`, `replay`, `log`,
    and `init` (write the default table if absent, install the food table). Every mutation is
    validated by rule 9's loader before it is written. The installed door is
    `~/.local/bin/betty-game`, a symlink to the deployed `~/.local/lib/deskcrab/betty-game`, so
    the command resolves by name from an ordinary shell like the other `betty-*` doors — and the
    suite pins the door itself, resolved off the user's own `bin` and executed, never only the
    checkout-relative wrapper.

### Boundaries

18. No model call is ever made by the bridge or the engine — the layer is mechanical end to end;
    that is what makes sub-second honest. And the layer never plays on its own: with no rules
    enabled it does nothing, with the engine stopped it does nothing, and nothing in it can
    initiate sessions, log in, or act while `logged_in` is false — so it structurally cannot
    create, enter, or alter a character on its own.

## KNOWN LIMITS

- The bridge sees exactly what the client renders for the player. Poison, prayer, quest state and
  other players' actions are invisible to version 1 snapshots; rules cannot trigger on what is not
  in rule 3.
- The version 1 bridge only resolves `opponent` when the client can name the fighter cheaply (the
  character the player is attacking); in most fights it is `null`, and combat in this engine stands
  both fighters on one tile anyway — so `flee` in practice takes the rule's `dx`/`dz` direction.
  The opponent-away arithmetic is engine-tested and waiting for a bridge that resolves more.
- `flee` is a walk request. The game's own rules decide whether walking out of combat is possible
  at that moment; the layer does not model catch mechanics, it just asks, and the receipt says only
  that the request was sent.
- The engine's latency floor is `poll_ms` plus the bridge's write cadence — about 150–400 ms in
  practice. That is sub-second, not sub-tick; a rule cannot outrun the game's own 640 ms combat
  round anyway.
- One game in, one game's bridge. The engine and rule table are game-agnostic by construction, but
  nothing has proven that against a second game yet.
