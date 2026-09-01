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
   `magic_level` (the live current Magic level), `selected_spell` (the selected spell id or
   `null`), and `spells` (the complete client spellbook: id, name, description, required level,
   semantic target kind, `ready`, and every required rune's id/name, literally held count,
   required count, and staff-aware `available` result),
   `x` and `z` (world coordinates), `walking` (the local player still has
   an unconsumed client waypoint, or a movement-capable bridge action was dispatched within the
   last second and may still be waiting for its server path), `in_combat`, `hover_text` (the
   colour-free action hint actually rendered at the top-left for the current pointer; empty when
   no hint or while the full context menu is open),
   `right_click_menu_open` (the ordinary world context menu is visibly open), `menu_options`
   (its live visible entries as colour-free text, otherwise empty), `ui_panel_open` and `ui_panel`
   (whether a hover-open side panel currently covers the world and its semantic name—inventory,
   minimap, skills/quests, magic/prayer, friends, or options—otherwise false and `null`),
   `trade_open` (either ordinary
   player-trade screen is visible),
   `talking_to_npc` (an NPC choice menu is open or
   the client received NPC-spoken quest dialogue within the last four seconds; NPC speech is the
   quest-channel `Name: words` form with an empty sender, not the local player's named reply),
   `dialogue_open` (the server is currently asking for an NPC reply), `dialogue_options` (the
   live reply texts as a colour-free array, otherwise empty), `opponent`
   (`{"x":…,"z":…}`
   while a fighting opponent is visible, else `null`), `sleeping` (whether the sleep-word screen
   owns input), `sleep_fatigue` (the fatigue shown on that screen), and `sleep_status` (its current
   status text), alongside ordinary `fatigue`; `inventory` (slot-order array of
   `{"id":…,"name":…,"count":…,"equipped":…,"wearable":…,"commands":[…]}`; commands are the item's
   current definition-backed verbs), `equipment` (the equipped subset as named id/count entries),
   `equipment_stats` (the client's resulting named Armour/aim/power/magic/prayer bonuses),
   `messages` (the last 20 messages seen by the client, newest last; each is
   `{"id":…,"channel":…,"incoming":…,"sender":…,"text":…}`, where `id` is unique across
   client restarts, `channel` distinguishes `local`, `private`, and non-player message types, and
   `incoming` is true only for chat received from another player), `players` (other players the
   client currently holds as visible, nearest by ordinary walking steps first, capped at 24: each
   `{"sidx":…,"name":…,"x":…,"z":…}`), `npcs` (the NPCs the
   client currently holds as loaded, nearest by ordinary walking steps to the player first,
   capped at 64: each
   `{"sidx":…,"id":…,"name":…,"description":…,"commands":[…],"attackable":…,"stats":{"attack":…,
   "strength":…,"defense":…,"hits":…},"x":…,"z":…,"distance":…,
   "clear_shot":…,"terrain_melee_reachable":…}` — the client's own index for that NPC, its
   client-cache identity, definition verbs, stats and world tile, Chebyshev distance, the ordinary-game
   projectile-line result, and whether the
   currently loaded movement topology contains a route from it into melee range), plus `npc_count`
   (the complete loaded count) and `npcs_truncated` (whether the 64-entry safety cap omitted
   anything). Scenery does not occlude this list: an absent NPC is outside the client's loaded set
   or, when explicitly marked, beyond the cap. `objects` (the game objects — scenery: fishing spots, gates, ranges, trees —
   the client currently holds as loaded, nearest by walking steps first, capped at 12: each
   `{"id":…,"name":…,"description":…,"commands":[…],"x":…,"z":…,"dir":…,
   "blocks_movement":…,"projectiles_pass":…}` — type id/name and the two client-cache verbs,
   world tile, facing direction, and its two collision
   properties), and `bounds` (the
   wall objects — doors and other boundaries — likewise nearest by walking steps first, capped at
   12, with those same semantic fields plus `reachable`, collision-aware `path_distance` (null
   when unreachable), and `open_command` (1/2, or zero when it has no Open command); `dir` is which
   wall of the tile the boundary stands on, so two doors sharing a tile stay distinct). `terrain`
   is a compact radius-6 topology centred on the player. `default_surface` names the implicit
   natural ground; `underfoot` names the player's current overlay and conservative surface kind;
   and `surface_cells` gives every non-default tile's absolute `x/z`, raw client-cache `overlay`,
   and kind (`path`, `water`, `floor`, `bridge`, or `surface-N` when no conservative semantic name
   exists). Fully blocked cells and cardinal `barriers` are listed separately, and every such entry
   independently says `projectiles_pass`; barrier endpoints are absolute `a:[x,z]` and `b:[x,z]`
   tiles. It comes from the same loaded map and collision data used by ordinary client walking and
   the same projectile-permeability classifications used by ordinary client play. `ground_items`
   (items currently visible on the ground, reachable items first by collision-aware walking steps,
   capped at 12: each carries client-cache `id`/`name`/`description`, world `x/z`, `reachable`, and
   `path_distance`). An unreachable
   item may also carry a `door` identity only when the player's and item's collision components
   meet on the two sides of that loaded, blocking, openable boundary; visual proximity alone never
   names a door. `shop_open` and
   `bank_open`, plus `shop_items` and `bank_items`. A shop item is
   `{"slot":…,"id":…,"name":…,"count":…,"noted":…}` from the open shop's 40-slot
   display. A bank item is `{"slot":…,"id":…,"name":…,"count":…}` from the complete
   item list the open bank interface has already received; it is empty while the bank is closed.
   Only what the
   player's own client can see is ever in it; the bridge reads
   no server internals.

   A second read-only IPC pair, `route-request.json` / `route-result.json`, lets the player ask the
   running client to plan from the complete landscape archive already installed for that client.
   The request may include openable object/boundary observations learned from normal snapshots;
   those become high-cost portal edges. The planner does not send a packet, consume the action
   slot, read server files, or require the server to know that it exists.

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

4a. Once the opted-in client is logged in, the bridge dismisses the client-local post-login
   welcome overlay before it publishes state or consumes any queued action. This close-first
   precondition uses the overlay's own client state, never a remembered pointer coordinate, so
   the window cannot obscure the player's sight or intercept ordinary play.

### Actions

5. The action vocabulary is closed, and grows only by a change to this spec: `eat` (use one
   inventory food item, by slot), `walk` (walk toward an absolute tile), `retreat` (the bridge's
   combat-lock-aware escape walk; an in-combat `flee` rule compiles to this), `warn` (display a local client-side message to the player — nothing is sent to the
   server), `chat-local` (send public chat to nearby players), `chat-private` (send a private
   message to a named online player at any distance), `talk-npc` (initiate dialogue with a currently visible NPC by server index — the
   same walk-and-talk the player's own Talk-to menu entry performs; it addresses server-defined
   NPCs only and structurally cannot message another player), `attack-npc` (walk to and attack an
   attackable visible NPC by server/type identity through the native NPC attack packet), `interact-npc`
   (perform command 1 or 2 from a visible NPC's own definition — the same
   walk-and-command as its context-menu entry, without reconstructing that menu), `cast-npc`
   (cast one NPC/player-targeted spell by spell id on a visible NPC server/type identity after
   rechecking the live Magic level and staff-aware rune requirements, through the ordinary
   walk-and-cast packet path, or, with `stationary=1`, the cast packet without an approach walk
   after enforcing Magic's four-tile range), `interact-object` (perform a menu
   command on a loaded game object at an absolute tile — the same walk-and-act the object's own
   right-click Command entry performs; `cmd` 1 or 2 picks the object definition's first or second
   command, so a fishing spot's Net and Bait, a gate's Open, a range's nothing-at-all are all the
   game's own menu, never an invented verb), and `interact-bound` (the same for a wall object —
   a door or other boundary — at a tile and wall direction; Open and Close are its usual
   commands), and `click-entity` (move the private display's pointer to a currently rendered NPC,
   game object, or wall object identified by stable game identity, let the game loop process that
   pointer position on a later frame, then click button 1, 2, or 3 without blocking that loop),
   `click-inventory` (find an inventory item by item id, open the inventory tab, resolve the
   current slot centre, and click button 1, 2, or 3), `equip-inventory` / `unequip-inventory`
   (idempotently request the named held item's equipped state, returning `already-equipped` or
   `already-unequipped` without sending a second toggle), `command-inventory` (run one of the
   held item's published definition-backed commands by one-based command number and positive
   amount), `use-item-object` (resolve a held item id and loaded object identity together, walk to
   that object, and send the ordinary item-on-object packet as one operation, without opening the
   inventory pane or staging pointer clicks), `use-item-npc` (resolve a held item id and a visible
   NPC's server/type identity together, walk to that NPC, and send the ordinary item-on-NPC packet
   as one operation, without selecting the inventory item or moving the pointer), `click-shop` and `click-bank` (find an item
   by id in the currently open interface, expose its containing page or scroll row, resolve its
   current slot centre, and click button 1, 2, or 3; bank identity covers
   inventory items shown for deposit even when no bank stack exists),
   `bank-deposit` / `bank-withdraw` and `shop-buy` / `shop-sell` (send the
   open interface's ordinary transaction by item identity and positive amount,
   without selecting a row or an amount button), `trade-player` (send the ordinary Trade-with
   request to a currently visible non-local player by server identity), `choose-menu` (choose an
   option from the context menu that is open now by a case-insensitive text fragment; an absent or
   ambiguous fragment is refused), `choose-dialogue` (choose one currently open NPC reply by the
   same exact-then-unambiguous text discipline), `take-ground` (walk to and take a
   currently visible ground item identified by item id and world tile), and `retreat` (while in
   combat, choose a collision-map-reachable walk away from an identified opponent or a supplied
   fallback direction, trying alternate directions and nearer tiles without sending failed path
   probes). `talk-npc`, `attack-npc`, `interact-npc`, `cast-npc`, `interact-object`, `interact-bound`,
   `click-entity`, `click-inventory`, `use-item-object`, `use-item-npc`,
   `equip-inventory`, `unequip-inventory`, `command-inventory`, `click-shop`,
   `click-bank`, the four bank/shop transaction actions, `trade-player`, `choose-menu`, `choose-dialogue`, `take-ground`, `retreat`,
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
   parameters (`slot` and `item` — the item id the engine saw in that slot — for eat; `x`, `z`,
   optional arrival radius `arrive`, optional preflight ceiling `max_path`, and optional
   collision-path prefix length `route_step` for walk; `text` for warn and chat-local; `target`
   and `text` for chat-private; `sidx` and `npc` — the server index and the type id the emitter saw
   there, the latter deliberately NOT named `id` so it can never collide with the action id line —
   for talk-npc, attack-npc, and interact-npc (attack-npc and interact-npc may carry `within`
   0–10; interact-npc also carries `cmd` 1 or 2), so a despawned or swapped NPC is refused as `refused-no-such-npc` or
   `refused-npc-mismatch`, never talked to blind. Immediately before dispatch the bridge also
   refuses `refused-nearer-equivalent` when another currently loaded NPC of that type is strictly
   fewer walking steps away; `attack-npc` additionally refuses `refused-not-attackable`; both it
   and `interact-npc` recheck `within` against the NPC's current tile and
   refuses `refused-npc-out-of-range` if it roamed beyond the cap. `cast-npc` carries `spell`,
   `sidx`, and `npc`, plus optional `within` 0–10 and 0/1 `stationary`,
   `require_clear_shot`, and `require_melee_unreachable`; it refuses a missing spell, a non-NPC spell target, insufficient live Magic,
   or any unavailable rune as `refused-no-such-spell`, `refused-wrong-spell-target`,
   `refused-magic-level`, or `refused-missing-runes`, then applies the same NPC identity and
   nearer-equivalent and locality checks before dispatch. A stationary cast beyond four tiles is
   `refused-stationary-out-of-range`; requested terrain relations are re-read on that same NPC and
   refuse as `refused-no-clear-shot` or `refused-melee-reachable` when no longer true. No approach
   walk is emitted for a stationary cast. `x`, `z`, `obj` — the object type id, NOT named
   `id` for the same collision reason — and `cmd` for interact-object, so an unloaded or swapped
   object is refused as `refused-no-such-object` or `refused-object-mismatch` and a `cmd` outside
   1–2 as `refused-bad-command`; `x`, `z`, `dir`, `obj`, `cmd` for interact-bound, matched on
   tile AND wall direction, refused as `refused-no-such-bound` / `refused-bound-mismatch` /
   `refused-bad-command` the same way; `kind` (`npc`, `object`, or `bound`) and `button` for
   click-entity, plus the same identity fields as that entity's normal action; `item` and `button`
   for click-inventory, click-shop, and click-bank; `item`, `x`, `z`, and `obj` for
   use-item-object; `item`, `sidx`, and `npc`, plus optional `within` 0–10, for use-item-npc;
   `item` for equip-inventory and
   unequip-inventory; `item`, one-based `cmd`, and positive `amount` for command-inventory;
   `item` and `amount` for the
   four transaction actions; `sidx` for trade-player; `text` for choose-menu and
   choose-dialogue; `x`, `z`, and
   `item` for take-ground; `distance` 1–10 and fallback `dx`/`dz` for retreat). The bridge resolves
   the identity against the current client arrays at execution time, obtains that exact entity's
   latest rendered screen point, and emits pointer move then click as one bridge operation. A
   missing, swapped, or off-screen entity is refused with the same identity refusal or
   `refused-not-on-screen`; a world pointer click while `ui_panel_open` is true is refused as
   `refused-ui-panel-open`, leaving the panel visible so the player must notice, dismiss, verify,
   and retry deliberately. Interface-targeting actions are not blocked by this guard. No screen
   coordinates cross the action file. For click-inventory it
   finds the first matching current item id, opens the inventory tab, and calculates the slot
   centre from the current client UI; a missing item is `refused-no-such-item`. The snapshot's
   `selected_inventory_item` is the item id currently selected for a later Use-with action, or
   null. It distinguishes a consumed click from a pointer that merely reached the item. No slot or
   screen coordinate crosses the action file. Equipment actions resolve the same live identity, refuse a
   non-wearable item, and never invert an item already in the requested state. Inventory commands
   recheck that the requested definition command still exists on that item before sending the
   ordinary item-command packet. `use-item-object` rechecks both the item's current slot and the
   object's exact tile/type before sending the same walk-and-use packet as the client's ordinary
   menu action; a missing item or changed object is refused rather than becoming a stale second
   click. `use-item-npc` performs the equivalent rechecks against the current inventory slot and
   NPC server/type identity, including the nearer-equivalent and optional locality checks used by
   other NPC actions. It sends the ordinary item-on-NPC packet without an inventory selection
   phase. `click-shop` and `click-bank` use the same identity-only
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
   `choose-dialogue` applies that same matching contract to the current server-authored NPC reply
   menu and sends its ordinary option packet. A closed menu, absent choice, or ambiguous fragment
   is refused. The snapshot exposes `dialogue_open` and colour-free `dialogue_options` separately
   from the ordinary context menu, while `talking_to_npc` remains true across the short NPC-speech
   gaps between reply menus.
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
   the client's collision map and pathfinder. `arrive` is bounded to 0–10. `max_path`, when
   positive, refuses a loaded destination whose actual collision path is longer than that ceiling.
   `route_step`, when present, is bounded to 1–32 and instead asks the pathfinder for at most that
   many actual steps along the complete currently loaded path toward `x,z`: the action file still
   names the real destination, and the bridge—not a model-authored coordinate guess—chooses and
   dispatches the grounded prefix endpoint. If its destination is outside the currently loaded
   map, the client clips the request to the edge of the current region in the destination's
   direction, searches that edge for a reachable alternative when the direct crossing is blocked,
   and `route_step` truncates that proven regional path to the same bounded prefix. A later action
   re-plans from the resulting live region; no guessed intermediate coordinates cross the action
   file. If the destination is already loaded, an ordinary walk remains exact while a route-step
   walk follows only its grounded prefix. A visible NPC currently standing on the destination tile
   does not pre-refuse that walk: NPCs move, are not static collision landmarks, and the client's
   own pathfinder remains authoritative. Semantic NPC actions express an intended interaction, but
   NPC presence cannot turn an otherwise valid navigation request into a prohibition. A walk for
   which no progressive local path exists is
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

13. `flee` compiles according to combat state. While `in_combat: true`, it emits the bridge's
    `retreat` action with the rule's `distance` and fallback `dx`/`dz`, so the server's first-three-
    round lock, live opponent direction, collision-map alternatives, and no-path refusals are
    handled as combat rather than mistaken for an ordinary walk. Once out of combat, it compiles
    to a `distance`-tile walk along the configured `dx`/`dz` direction (default south), allowing
    low-health/no-food survival to keep creating separation. The engine clamps ordinary walks to
    at most 15 tiles from the player's position.

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
- The version 1 bridge resolves `opponent` only when the client can name the fighter cheaply. The
  combat-aware `retreat` action rechecks that live identity inside the client and otherwise uses
  the flee rule's `dx`/`dz`, trying collision-map alternatives. The server remains authoritative
  over whether the first-three-round lock permits escape; the receipt proves only dispatch.
- The engine's latency floor is `poll_ms` plus the bridge's write cadence — about 150–400 ms in
  practice. That is sub-second, not sub-tick; a rule cannot outrun the game's own 640 ms combat
  round anyway.
- One game in, one game's bridge. The engine and rule table are game-agnostic by construction, but
  nothing has proven that against a second game yet.
