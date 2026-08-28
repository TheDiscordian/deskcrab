# game-npc-click — one deliberate click, aimed from the latest frame

## PURPOSE

The game-reflex layer answers urgent *state* with rule actions; it cannot point at anything.
Deliberate play occasionally needs a visual distinction that stable game identity cannot express —
the nearer of two same-type lookalikes, the red-caped one, the one standing beside a screen hint.
Ordinary NPC/object/bound clicks use `orsc-headless.sh entity`: its server identity and in-client
render-point resolution are safer and remain the first door. This visual fallback exists for the
remaining cases, where a reasoning turn per click is both too slow and aimed at a frame that is
already history by the time the click fires:
headless tutorial play spent whole minutes chasing wandering tutors with screenshot-guessed clicks
(2026-08-27). This tool is the aiming reflex between those layers: an intent in — an NPC name, or a
visual/screen target — and at most one verified click out, with **no model call anywhere inside**.
It chooses nothing: which NPC to click, with which button, was decided by the deliberate hand that
invoked it, and the visual registry that names NPCs is written by that same hand, like the rule
table.

The mechanism is screen-space and belongs to the isolated headless client: it reads the private
display's framebuffer and synthesizes pointer input against that display only. What the framebuffer
shows is what it matches — an open side panel occludes, and the tool does not see through it. The
bridge snapshot (specs/game-reflex.md rule 3) is consulted for *presence* — is the named NPC
visible to the client at all — never for aiming, and the tool works unchanged when no bridge is
attached. The `talk-npc` action is the right door for starting a conversation; this tool exists for
every click that is not one (attack, chase, menus, disambiguation by eye).

## CONTRACT

### The tool and its doors

1. The tool is `lib/game_npc_click.py`, stdlib only. Invocation:
   `game_npc_click.py --display N <intent> [options]`. Frames are read with ImageMagick `import`
   (8-bit binary PPM over a pipe) and pointer input is synthesized with `xte`, both resolved from
   `PATH`; nothing else touches the display. The player-facing door is
   `orsc-headless.sh aim <intent> [options]`: it discovers the private display, supplies the live
   bridge state and server NPC definitions, and delegates to this one implementation.

2. Its entire action surface is: pointer moves and at most **one** button click per invocation, on
   the private display it was pointed at, plus one report line on stdout. It never presses a key,
   never opens the game database, never writes into the exchange directory, and reads `state.json`
   read-only. It structurally cannot log in, talk, type, drop, trade or spend: the only xte verbs
   it ever emits are `mousemove` and `mouseclick`.

3. `--display 0` and `--display 1` are refused (exit 6) before anything else runs: those are the
   physical seat. `DESKCRAB_NPC_CLICK_ANY_DISPLAY=1` is the explicit override for a harness that
   knows better. A non-numeric display is a usage error (exit 5).

3a. The shared manual hold and action slot govern this pointer too. A present `hold` file in the
    state directory returns exit 7 `held`; an unconsumed `action.json` returns exit 8 `busy`.
    Both happen before a frame grab or pointer movement, so a visual fallback cannot race a bridge
    action or evade the same stop-everything override as the learned player.

### Intent

4. The intent argument resolves in order: a registry name (rule 5, case-insensitive), a built-in
   spec name (`red-cape`, `skin` — the same predicates the harness hunter uses), or a literal
   `R,G,B[:tol]` (per-channel tolerance, default 30). Anything else is a usage error (exit 5).
   `--button` (default 1; 3 is the menu button) overrides a registry `button=`.

5. The visual registry `$DESKCRAB_GAME_DIR/npc-visuals.conf` (override `--conf`;
   `$DESKCRAB_GAME_DIR` defaults as in game-reflex rule 1) is flat lines
   `name = spec [button=N] [min=PIXELS]`, where `spec` is a built-in name or `R,G,B[:tol]` with
   channels and tolerance each in 0–255; `button` is 1–3 and `min` is positive; `#`
   lines and blank lines are ignored; any other token on a line is a load error (exit 5) — a typo
   must not silently become a default. The tool ships knowing no NPC: every visual is the player's
   own entry.

6. Candidates are connected blobs of matching pixels inside the game viewport (`--view`, default
   `258,212,766,536`) minus the toolbar strip (`--toolbar`, default `568,212,766,248`), each of at
   least min pixels (default 12; `--min-pixels` or registry `min=`). Choice among them: nearest to
   the `--near X,Y` screen hint when given, else the `--nth K` largest (1-based) when given, else
   the largest.

7. Presence gate: when the intent is a registry name, the defs file (`--defs`, default
   `$DESKCRAB_GAME_NPC_DEFS`) knows that name (case-insensitive; all matching type ids count), and
   a snapshot from `--state-dir` (default `$DESKCRAB_GAME_STATE_DIR`, then `/tmp/deskcrab-game`)
   is readable, fresh (`ts` within 2000 ms), logged in, and carries an `npcs` field — then an
   `npcs` list with no matching type id means exit 4 `not-visible` with the pointer untouched. A
   missing, stale, logged-out or `npcs`-less snapshot, a name the defs do not know, a non-name
   intent, or no defs file at all **skips** the gate and the report says `gate=skipped` — silence
   never implies the check ran. `--no-presence-gate` disables it explicitly (`gate=off`).

### Acquire, verify, act

8. Acquisition: grab a fresh frame, find candidates (rule 6). None → exit 3 `no-target`, pointer
   untouched.

9. The act sequence: move the pointer to the candidate centroid; settle (`--settle-ms`, default
   180); grab a **fresh** frame; re-find the matching blob nearest the pointer. Only when that
   fresh centroid lies within `--stable-px` (default 4) of the pointer does the tool click — and
   the click is a bare `mouseclick B` in its own xte invocation with no movement in it, followed
   by a settle. A click therefore always fires on a target verified in the latest frame with the
   pointer already at rest on it: the move-then-click-against-stale-coordinates race (the
   password-into-the-username-field incident, 2026-08-27) is structurally excluded, because no xte
   invocation that clicks ever also moves.

10. Movement coping: a fresh centroid beyond stable-px but within `--max-jump` (default 48) px of
    the pointer means the NPC stepped — the pointer follows it and rule 9 verifies again. Farther
    than max-jump, or no matching blob near the pointer, means reacquisition as in rule 8 (the
    `--near`/`--nth` choice applies again). Either way costs one attempt; attempts are bounded by
    `--retries` (default 5). Exhaustion without a verified click → exit 2 `unstable`, the last
    known position in the report, and **no click** — unless `--chase`, which spends the final
    attempt moving to the freshest centroid, settling, and clicking, reported as `chased=1`.

11. `--dry-run` performs acquisition and one settle-and-regrab stability measurement without
    invoking xte at all: it never moves the pointer and never clicks.

12. The report is exactly one line on stdout, `<verdict> key=value ...`, verdict one of `clicked`,
    `dry-run`, `no-target`, `not-visible`, `unstable`, `held`, `busy`; fields always include `intent` and `gate`
    (`ok`/`skipped`/`off`), and where meaningful `x`, `y`, `button`, `attempt`, `drift`,
    `pixels`, `chased`, `stable`. Exit codes: 0 clicked or dry-run acquired, 2 unstable, 3
    no-target, 4 not-visible, 5 usage or configuration, 6 display refused, 7 held, 8 action slot
    busy.

13. Bounded work: `retries` is 1–50, `settle-ms` is 0–5000, at most `1 + retries` frame grabs occur
    per invocation, no internal wait exceeds settle-ms, and each external `import`/`xte` call has a
    five-second timeout. The still-target path is exactly two grabs, one settle, one click. The tool
    either acts or reports within that budget — it never lingers watching the screen.

14. Identity wins whenever it can. The playing prompt directs an ordinary visible NPC, object or
    bound click through `entity KIND TYPE-ID [BUTTON]`; `aim` is licensed only when the intended
    distinction is visual and cannot be named by the structured snapshot. Raw remembered screen
    coordinates are never the fallback.

## TESTS

`tests/test_game_npc_click.py` drives the real selection and retry loop with deterministic fresh
frames and a recording display: still and walking targets, far-jump reacquisition from the same
frame, transient disappearance, bounded no-click exhaustion, explicit chase, dry-run, registry and
RGB validation, live presence, hold/action-slot gates, the `:0`/`:1` refusal including leading-zero
spellings, and invalid budgets. `tests/test_game_player.sh` pins the real
`orsc-headless.sh aim` delegation, including discovered private display, shared state directory and
unchanged intent.
