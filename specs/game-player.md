# game-player — learned rules are the primary play path

## PURPOSE

Deliberate play taught itself actions all through Tutorial Island (2026-08-27) and wrote them down
as prose — triggers like "tutorial cooking instruction needed" in `learned-actions.json` — and
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
   - `message_contains` (string, non-empty, single-line): some message in the snapshot's
     `messages` contains it, case-insensitively.
   - `near_tile` (`{"x":…,"z":…,"radius":…}`): Chebyshev distance from the player's tile is at
     most `radius` (0 ≤ radius ≤ 50).
   - `inventory_has` / `inventory_lacks` (int): an item of that id is / is not in the inventory.

5. The action vocabulary is closed: `talk-npc` (`npc`: the type id; the server index is resolved
   from the snapshot at fire time — nearest matching NPC — and both ride the action file exactly
   as game-reflex rule 6 defines, so the bridge's despawn/mismatch re-checks still protect the
   click) and `walk` (absolute `x`/`z`, **unclamped** — deliberate travel crosses the map, and
   the game's own pathing already decides reachability; the 15-tile clamp is a reflex-channel
   rule about panic moves, not a bridge property). Everything the bridge refuses stays refused;
   nothing in this layer can log in, spend, trade or message a player, and screen-space clicks
   (camera-dependent presses) are structurally outside the vocabulary — an action that cannot
   be expressed here belongs in `unfinished`, not approximated.

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
     `type`, `status`, `objective`.
   - `fired` with a non-`done` status, or no receipt inside the window (exit 2): the action was
     emitted but did not execute; the model should look before retrying.
   - `no-snapshot`, `stale`, `logged-out`, `same-tick`, `slot-busy` (exit 3): nothing to
     evaluate against — an unconsumed `action.json` (`slot-busy`) is never overwritten.
   - `no-rule-matched` (exit 4): the fallback signal — **only this verdict licenses model
     reasoning about the next action**. Fields include `cooldown_holds`, so a temporarily
     suppressed rule is visible to the falling-back mind.
   - `held` (exit 5): the manual override is on; nobody plays, model included.
   `step --max N` repeats while rules fire cleanly (at most N actions), then reports the
   stopping verdict; the exit code is 0 if anything fired.

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
    has one door for stepping, learning and objectives. The playing policy the sittings read
    makes rules-first mandatory: reasoning about the next action is licensed only by rule 7's
    `no-rule-matched` (exit 4), and a newly verified play must be written back with `learn` —
    an executable rule, not only a prose note.

## KNOWN LIMITS

- The trigger vocabulary sees what the snapshot carries (game-reflex rule 3). Doors, scenery,
  quest state and dialogue menus are invisible; plays that need them wait in `unfinished` for
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
