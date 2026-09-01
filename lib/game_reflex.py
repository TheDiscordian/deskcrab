#!/usr/bin/env python3
"""betty-game: the visible-state reflex engine (specs/game-reflex.md).

A trigger-action machine for real-time play: the game client's bridge writes a
snapshot of what the player can see, this engine evaluates a durable rule
table against it, and emits at most one game action at a time — eat, flee,
warn — in well under a second, with no model call anywhere in the loop.

Stdlib only, like job-status: this must run with nothing installed. Run it
through the `betty-game` wrapper.
"""

import argparse
import json
import math
import os
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

SNAPSHOT_VERSION = 1

# The closed vocabularies (spec rules 5 and 9). They grow by spec change only.
TRIGGER_KEYS = ("hp_below", "requires_food", "no_food", "in_combat", "fatigue_above")
GAME_ACTIONS = ("eat", "flee", "walk")
NOTICE_ACTIONS = ("warn",)
CHANNELS = ("game", "notice")

WALK_CLAMP = 15  # tiles; spec rule 13
ACTION_FRESH_MS = 1500  # the bridge's freshness window; spec rule 7

DEFAULTS = {
    "stale_ms": 2000,
    "poll_ms": 150,
    "min_action_interval_ms": 0,
    "max_actions_per_min": 0,
    "inflight_timeout_ms": 2000,
    "eat_pick": "min",
}

# Shipped disabled on the game channel deliberately (spec rule 14): a reflex
# is armed by the player's own hand after the moment that justifies it.
DEFAULT_RULES = {
    "v": 1,
    "defaults": dict(DEFAULTS),
    "rules": [
        {
            "name": "warn-low-health",
            "enabled": True,
            "channel": "notice",
            "priority": 5,
            "cooldown_ms": 10000,
            "hold_ticks": 1,
            "trigger": {"hp_below": 0.5},
            "action": {"type": "warn", "text": "health low: {hits}/{hits_max}"},
        },
        {
            "name": "eat-low-health",
            "enabled": False,
            "channel": "game",
            "priority": 10,
            "cooldown_ms": 0,
            "hold_ticks": 2,
            "trigger": {"hp_below": 0.5, "requires_food": True,
                        "in_combat": False},
            "action": {"type": "eat"},
        },
        {
            "name": "flee-starved",
            "enabled": False,
            "channel": "game",
            "priority": 20,
            "cooldown_ms": 0,
            "hold_ticks": 2,
            "trigger": {"hp_below": 0.35, "no_food": True},
            "action": {"type": "flee", "distance": 5, "dx": 0, "dz": 1},
        },
    ],
}


def state_dir() -> Path:
    return Path(os.environ.get("DESKCRAB_GAME_STATE_DIR", "/tmp/deskcrab-game"))


def game_dir() -> Path:
    return Path(
        os.environ.get(
            "DESKCRAB_GAME_DIR", os.path.expanduser("~/.local/share/deskcrab/game")
        )
    )


def rules_path() -> Path:
    return game_dir() / "reflex-rules.json"


def food_path() -> Path:
    return game_dir() / "food-heals.xml"


def now_ms() -> int:
    return int(time.time() * 1000)


def die(msg: str) -> None:
    sys.exit(f"betty-game: {msg}")


def atomic_write(path: Path, text: str) -> None:
    """Spec rule 2: temp file in the same directory, then rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --------------------------------------------------------------------------
# The food table (spec rule 12): the game server's own ItemEdibleHeals.xml
# format — <map><entry><int>id</int><int>heal</int></entry>…</map>.
# --------------------------------------------------------------------------
def load_food(path: Path = None) -> dict:
    path = path or food_path()
    if not path.exists():
        return {}
    try:
        root = ET.parse(str(path)).getroot()
    except ET.ParseError as e:
        die(f"food table {path} is not parseable XML: {e}")
    table = {}
    for entry in root.findall(".//entry"):
        ints = entry.findall("int")
        if len(ints) >= 2:
            table[int(ints[0].text)] = int(ints[1].text)
    return table


# --------------------------------------------------------------------------
# The rule table: load, validate, save. Validation is the one gate — nothing
# unvalidated is ever written, and nothing unvalidated ever evaluates
# (spec rule 9).
# --------------------------------------------------------------------------
def validate_config(cfg: dict) -> None:
    def bad(msg):
        raise ValueError(msg)

    if not isinstance(cfg, dict) or "rules" not in cfg:
        bad("the rule table must be an object with a 'rules' list")
    defaults = cfg.get("defaults", {})
    if not isinstance(defaults, dict):
        bad("'defaults' must be an object")
    for key in defaults:
        if key not in DEFAULTS:
            bad(f"unknown defaults key '{key}' (known: {', '.join(sorted(DEFAULTS))})")
    for key in ("stale_ms", "poll_ms", "min_action_interval_ms",
                "max_actions_per_min", "inflight_timeout_ms"):
        v = defaults.get(key, DEFAULTS[key])
        if not isinstance(v, int) or v < 0:
            bad(f"defaults.{key} must be a non-negative integer, not {v!r}")
    if defaults.get("min_action_interval_ms", 0) != 0:
        bad("defaults.min_action_interval_ms must be 0: gameplay eligibility "
            "comes from observed state transitions")
    if defaults.get("max_actions_per_min", 0) != 0:
        bad("defaults.max_actions_per_min must be 0: the in-flight action and "
            "its observed completion own sequencing")
    if defaults.get("eat_pick", "min") not in ("min", "max"):
        bad("defaults.eat_pick must be 'min' or 'max'")

    if not isinstance(cfg["rules"], list):
        bad("'rules' must be a list")
    seen = set()
    for rule in cfg["rules"]:
        if not isinstance(rule, dict) or not rule.get("name"):
            bad("every rule needs a name")
        name = rule["name"]
        if not all(c.islower() or c.isdigit() or c == "-" for c in name):
            bad(f"rule name '{name}' must be lowercase letters, digits and dashes")
        if name in seen:
            bad(f"rule name '{name}' appears twice")
        seen.add(name)
        where = f"rule '{name}'"
        channel = rule.get("channel")
        if channel not in CHANNELS:
            bad(f"{where}: channel must be one of {', '.join(CHANNELS)}")
        if not isinstance(rule.get("enabled"), bool):
            bad(f"{where}: enabled must be true or false")
        if not isinstance(rule.get("priority"), int):
            bad(f"{where}: priority must be an integer")
        if not isinstance(rule.get("cooldown_ms"), int) or rule["cooldown_ms"] < 0:
            bad(f"{where}: cooldown_ms must be a non-negative integer")
        if channel == "game" and rule["cooldown_ms"] != 0:
            bad(f"{where}: game-channel cooldown_ms must be 0: use an observed "
                "trigger and completion transition")
        if not isinstance(rule.get("hold_ticks"), int) or rule["hold_ticks"] < 1:
            bad(f"{where}: hold_ticks must be an integer >= 1")

        trig = rule.get("trigger")
        if not isinstance(trig, dict) or not trig:
            bad(f"{where}: trigger must be a non-empty object")
        for key, val in trig.items():
            if key not in TRIGGER_KEYS:
                bad(f"{where}: unknown trigger '{key}' "
                    f"(known: {', '.join(TRIGGER_KEYS)})")
            if key in ("hp_below", "fatigue_above"):
                if not isinstance(val, (int, float)) or not 0 < val <= 1:
                    bad(f"{where}: trigger.{key} must be a fraction in (0, 1]")
            elif key in ("requires_food", "no_food"):
                if val is not True:
                    bad(f"{where}: trigger.{key} can only be true "
                        "(use the other one for the opposite)")
            elif key == "in_combat":
                if not isinstance(val, bool):
                    bad(f"{where}: trigger.in_combat must be true or false")
        if trig.get("requires_food") and trig.get("no_food"):
            bad(f"{where}: requires_food and no_food cannot both hold")

        action = rule.get("action")
        if not isinstance(action, dict) or "type" not in action:
            bad(f"{where}: action must be an object with a type")
        atype = action["type"]
        if atype == "eat" and trig.get("in_combat") is not False:
            bad(f"{where}: eat requires trigger.in_combat=false; leave combat first")
        allowed = GAME_ACTIONS if channel == "game" else NOTICE_ACTIONS
        if atype not in allowed:
            bad(f"{where}: action '{atype}' is not allowed on the {channel} "
                f"channel (allowed: {', '.join(allowed)})")
        if atype == "eat":
            extra = set(action) - {"type"}
            if extra:
                bad(f"{where}: eat takes no parameters, got {', '.join(sorted(extra))}")
        elif atype == "flee":
            extra = set(action) - {"type", "distance", "dx", "dz"}
            if extra:
                bad(f"{where}: flee takes distance/dx/dz, got {', '.join(sorted(extra))}")
            dist = action.get("distance", 5)
            if not isinstance(dist, int) or not 1 <= dist <= WALK_CLAMP:
                bad(f"{where}: flee distance must be 1..{WALK_CLAMP}")
            dx, dz = action.get("dx", 0), action.get("dz", 1)
            if dx not in (-1, 0, 1) or dz not in (-1, 0, 1) or (dx == 0 and dz == 0):
                bad(f"{where}: flee dx/dz must be -1, 0 or 1 and not both 0")
        elif atype == "walk":
            extra = set(action) - {"type", "x", "z"}
            if extra:
                bad(f"{where}: walk takes x/z, got {', '.join(sorted(extra))}")
            if not isinstance(action.get("x"), int) or not isinstance(action.get("z"), int):
                bad(f"{where}: walk needs integer x and z")
        elif atype == "warn":
            text = action.get("text")
            extra = set(action) - {"type", "text"}
            if extra:
                bad(f"{where}: warn takes text, got {', '.join(sorted(extra))}")
            if not isinstance(text, str) or not text.strip() or "\n" in text:
                bad(f"{where}: warn needs a non-empty single-line text")


def load_config() -> dict:
    path = rules_path()
    if not path.exists():
        die(f"no rule table at {path} — run `betty-game init` first")
    try:
        cfg = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        die(f"rule table {path} is not valid JSON: {e}")
    migrated = False
    defaults = cfg.get("defaults") if isinstance(cfg, dict) else None
    if isinstance(defaults, dict):
        for key in ("min_action_interval_ms", "max_actions_per_min"):
            if defaults.get(key) != 0:
                defaults[key] = 0
                migrated = True
    for rule in cfg.get("rules", []) if isinstance(cfg, dict) else []:
        if isinstance(rule, dict) and rule.get("channel") == "game" \
                and isinstance(rule.get("cooldown_ms"), int) \
                and rule["cooldown_ms"] != 0:
            rule["cooldown_ms"] = 0
            migrated = True
        if isinstance(rule, dict) and (rule.get("action") or {}).get("type") == "eat" \
                and isinstance(rule.get("trigger"), dict) \
                and rule["trigger"].get("in_combat") is not False:
            rule["trigger"]["in_combat"] = False
            migrated = True
    try:
        validate_config(cfg)
    except ValueError as e:
        die(f"rule table {path}: {e}")
    if migrated:
        atomic_write(path, json.dumps(cfg, indent=2) + "\n")
    return cfg


def save_config(cfg: dict) -> None:
    validate_config(cfg)
    atomic_write(rules_path(), json.dumps(cfg, indent=2) + "\n")


def config_defaults(cfg: dict) -> dict:
    merged = dict(DEFAULTS)
    merged.update(cfg.get("defaults", {}))
    return merged


def find_rule(cfg: dict, name: str) -> dict:
    for rule in cfg["rules"]:
        if rule["name"] == name:
            return rule
    die(f"no rule named '{name}' (betty-game rules lists them)")


def needs_food_table(rule: dict) -> bool:
    return (
        rule["trigger"].get("requires_food") is True
        or rule["trigger"].get("no_food") is True
        or rule["action"]["type"] == "eat"
    )


# --------------------------------------------------------------------------
# Engine state: the counters that make cooldowns and debounce survive a
# restart (spec rule 1). One JSON file, engine-private.
# --------------------------------------------------------------------------
def load_engine_state() -> dict:
    path = state_dir() / "engine-state.json"
    try:
        est = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        est = {}
    est.setdefault("action_seq", 0)
    est.setdefault("fired", {})        # rule name -> last fired epoch ms
    est.setdefault("streak", {})       # rule name -> consecutive true snapshots
    est.setdefault("blocked", {})      # rule name -> currently in a logged cooldown episode
    est.setdefault("gated", {})        # rule name -> currently in a logged combat-hold episode
    est.setdefault("inflight", None)   # {"id":…, "ts":…} while a game action awaits receipt
    est.setdefault("last_game_ms", 0)
    est.setdefault("window", [])       # recent game-action fire times, per-minute cap
    est.setdefault("last_tick", -1)
    est.setdefault("was_stale", False)
    est.setdefault("was_out", False)
    est.setdefault("was_held", False)
    return est


def save_engine_state(est: dict) -> None:
    atomic_write(state_dir() / "engine-state.json", json.dumps(est) + "\n")


def log_event(event: dict, sink=None) -> None:
    line = json.dumps(event, separators=(",", ":"))
    if sink is not None:
        sink.append(event)
        return
    path = state_dir() / "decisions.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as fh:
        fh.write(line + "\n")


# --------------------------------------------------------------------------
# Snapshot and receipt reading.
# --------------------------------------------------------------------------
def read_snapshot():
    path = state_dir() / "state.json"
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def sweep_dead_notices(now: int) -> None:
    """Spec rule 6: a notice whose ts has aged past the bridge's freshness
    window is dead either way — the bridge would drop it as stale — so the
    live loop sweeps it, and an exchange directory with no bridge attached
    cannot fill without bound. Never called from replay."""
    for path in state_dir().glob("notice-*.json"):
        try:
            ts = 0
            for line in path.read_text().splitlines():
                if line.startswith("ts="):
                    ts = int(line[3:])
                    break
        except (OSError, ValueError):
            ts = 0  # unreadable or unparseable: dead by definition
        if now - ts > ACTION_FRESH_MS:
            try:
                path.unlink()
            except OSError:
                pass  # the bridge consumed it first; that is fine


def inventory_item_quantity(snap: dict, item_id: int) -> int:
    return sum(int(item.get("count", 1)) for item in snap.get("inventory") or []
               if isinstance(item, dict) and item.get("id") == item_id)


def consume_receipt(est: dict, now: int, snap: dict = None, sink=None) -> None:
    """Consume dispatch receipts; an eat receipt is not completion.

    Eating owns the slot until newer visible state proves food consumption or
    healing, or explicit server feedback proves success/failure. The ordinary
    inflight timeout remains the maximum failure lease.
    """
    path = state_dir() / "receipt.json"
    try:
        receipt = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        receipt = None
    inflight = est.get("inflight")
    if receipt is not None and inflight and receipt.get("id") == inflight["id"]:
        log_event({"ts": now, "kind": "receipt", "id": receipt.get("id"),
                   "status": receipt.get("status")}, sink)
        if inflight.get("type") == "eat" and receipt.get("status") == "done":
            inflight["receipted"] = True
        else:
            est["inflight"] = None
        try:
            path.unlink()
        except OSError:
            pass
    inflight = est.get("inflight")
    if inflight and inflight.get("type") == "eat" \
            and inflight.get("receipted") and isinstance(snap, dict):
        baseline_hits = inflight.get("hits")
        healed = isinstance(snap.get("hits"), int) \
            and isinstance(baseline_hits, int) and snap["hits"] > baseline_hits
        consumed = inventory_item_quantity(snap, inflight.get("item")) \
            < inflight.get("item_quantity", 0)
        old_ids = set(inflight.get("message_ids") or [])
        messages = [m for m in snap.get("messages") or []
                    if isinstance(m, dict) and m.get("id") not in old_ids]
        success = next((str(m.get("text", "")) for m in messages
                        if "you eat" in str(m.get("text", "")).casefold()
                        or "heals some health" in str(m.get("text", "")).casefold()), None)
        failure = next((str(m.get("text", "")) for m in messages
                        if "can't do that whilst you are fighting"
                        in str(m.get("text", "")).casefold()), None)
        if healed or consumed or success or failure:
            log_event({"ts": now,
                       "kind": "action-complete" if not failure else "action-failed",
                       "id": inflight["id"], "type": "eat",
                       "healed": healed, "consumed": consumed,
                       "message": success or failure}, sink)
            est["inflight"] = None
    inflight = est.get("inflight")
    if inflight and now - inflight["ts"] > est["_inflight_timeout_ms"]:
        log_event({"ts": now, "kind": "inflight-timeout", "id": inflight["id"]}, sink)
        est["inflight"] = None


# --------------------------------------------------------------------------
# Trigger evaluation. A field the snapshot does not carry makes the condition
# false, never an exception — a thin snapshot must fail safe.
# --------------------------------------------------------------------------
def food_slots(snap: dict, food: dict) -> list:
    """(slot, id, heal) for every inventory item in the food table."""
    out = []
    for slot, item in enumerate(snap.get("inventory") or []):
        heal = food.get(item.get("id"))
        if heal is not None:
            out.append((slot, item["id"], heal))
    return out


def trigger_true(trig: dict, snap: dict, food: dict) -> bool:
    if "hp_below" in trig:
        hits, hits_max = snap.get("hits"), snap.get("hits_max")
        if not isinstance(hits, int) or not isinstance(hits_max, int) or hits_max <= 0:
            return False
        if not hits / hits_max < trig["hp_below"]:
            return False
    if "fatigue_above" in trig:
        fatigue = snap.get("fatigue")
        if not isinstance(fatigue, (int, float)):
            return False
        if not fatigue / 100.0 > trig["fatigue_above"]:
            return False
    if trig.get("requires_food") and not food_slots(snap, food):
        return False
    if trig.get("no_food") and food_slots(snap, food):
        return False
    if "in_combat" in trig and bool(snap.get("in_combat")) != trig["in_combat"]:
        return False
    return True


# --------------------------------------------------------------------------
# Action compilation (spec rules 12 and 13).
# --------------------------------------------------------------------------
def clamp_walk(px: int, pz: int, tx: int, tz: int):
    dx, dz = tx - px, tz - pz
    if abs(dx) <= WALK_CLAMP and abs(dz) <= WALK_CLAMP:
        return tx, tz
    scale = WALK_CLAMP / max(abs(dx), abs(dz))
    return px + int(math.copysign(math.floor(abs(dx) * scale), dx)), \
        pz + int(math.copysign(math.floor(abs(dz) * scale), dz))


def compile_action(rule: dict, snap: dict, food: dict, eat_pick: str):
    """The concrete parameters, or (None, why-not)."""
    action = rule["action"]
    atype = action["type"]
    if atype == "eat":
        if snap.get("in_combat") is not False:
            return None, "eat-requires-out-of-combat"
        slots = food_slots(snap, food)
        if not slots:
            return None, "no-food-in-inventory"
        slots.sort(key=lambda s: (s[2], s[0]))
        slot = slots[-1] if eat_pick == "max" else slots[0]
        return {"type": "eat", "slot": slot[0], "item": slot[1]}, None
    if atype in ("flee", "walk"):
        px, pz = snap.get("x"), snap.get("z")
        if not isinstance(px, int) or not isinstance(pz, int):
            return None, "no-position-in-snapshot"
        if atype == "walk":
            tx, tz = clamp_walk(px, pz, action["x"], action["z"])
            return {"type": "walk", "x": tx, "z": tz}, None
        dist = action.get("distance", 5)
        # In combat, an ordinary walk packet is not a retreat: the server may
        # reject it during the first three rounds, and a blocked destination
        # has no directional fallbacks. Use the bridge's combat-aware action.
        # Once combat has ended, the same survival rule remains an ordinary
        # outward walk so low-health/no-food state can create more separation.
        if snap.get("in_combat") is True:
            return {"type": "retreat", "distance": dist,
                    "dx": action.get("dx", 0), "dz": action.get("dz", 1)}, None
        opp = snap.get("opponent")
        if isinstance(opp, dict) and isinstance(opp.get("x"), int) \
                and isinstance(opp.get("z"), int):
            dx, dz = px - opp["x"], pz - opp["z"]
            if dx == 0 and dz == 0:
                dx, dz = action.get("dx", 0), action.get("dz", 1)
            length = max(abs(dx), abs(dz))
            tx = px + round(dx / length * dist)
            tz = pz + round(dz / length * dist)
        else:
            tx = px + action.get("dx", 0) * dist
            tz = pz + action.get("dz", 1) * dist
        tx, tz = clamp_walk(px, pz, tx, tz)
        return {"type": "walk", "x": tx, "z": tz}, None
    if atype == "warn":
        values = {k: snap.get(k) for k in
                  ("hits", "hits_max", "fatigue", "x", "z", "tick")}
        try:
            text = action["text"].format(**values)
        except (KeyError, IndexError, ValueError):
            text = action["text"]
        return {"type": "warn", "text": text}, None
    return None, f"unknown-action-{atype}"


def emit_action(path_name: str, action: dict, action_id: int, ts: int) -> None:
    lines = [f"ts={ts}", f"id={action_id}", f"type={action['type']}"]
    for key in ("slot", "item", "x", "z", "distance", "dx", "dz", "text"):
        if key in action:
            lines.append(f"{key}={action[key]}")
    atomic_write(state_dir() / path_name, "\n".join(lines) + "\n")


# --------------------------------------------------------------------------
# One evaluation of one snapshot (spec rules 10 and 11). `emit` is real in
# the run loop and a no-op in replay; `sink` collects events for replay.
#
# The machinery is shared with the deliberate-play channel
# (specs/game-player.md rule 8): `trigger_fn` and `compile_fn` plug that
# layer's own vocabulary into the SAME priority/cooldown/debounce/slot
# discipline, and `live` says whether the hold flag governs — it defaults
# to "emitting for real", which is exactly the old `emit is emit_action`
# test, so replay stays hold-blind and the run loop stays hold-bound.
# --------------------------------------------------------------------------
def evaluate(cfg: dict, food: dict, snap: dict, est: dict, now: int,
             emit=emit_action, sink=None, trigger_fn=None, compile_fn=None,
             live=None) -> None:
    if trigger_fn is None:
        trigger_fn = trigger_true
    if compile_fn is None:
        compile_fn = compile_action
    if live is None:
        live = emit is emit_action
    defaults = config_defaults(cfg)
    est["_inflight_timeout_ms"] = defaults["inflight_timeout_ms"]

    held = (state_dir() / "hold").exists() if live else False
    if held != est["was_held"]:
        log_event({"ts": now, "kind": "hold" if held else "resume"}, sink)
        est["was_held"] = held
    if held:
        return

    if not snap.get("logged_in"):
        if not est["was_out"]:
            log_event({"ts": now, "kind": "logged-out"}, sink)
            est["was_out"] = True
        est["streak"] = {}
        est["gated"] = {}
        return
    if est["was_out"]:
        log_event({"ts": now, "kind": "logged-in"}, sink)
        est["was_out"] = False

    stale = now - snap.get("ts", 0) > defaults["stale_ms"]
    if stale != est["was_stale"]:
        log_event({"ts": now, "kind": "stale" if stale else "fresh",
                   "age_ms": now - snap.get("ts", 0)}, sink)
        est["was_stale"] = stale
    if stale:
        return

    tick = snap.get("tick", -1)
    if tick == est["last_tick"]:
        return  # never act twice on one tick (spec rule 11)
    est["last_tick"] = tick

    # Debounce streaks first, for every enabled rule, so the counters are
    # honest whatever fires. On this engine's own vocabulary, a game rule's
    # in_combat condition is a live dispatch gate (spec rule 10a): the need
    # keeps its streak through a fight, and dispatch waits for the first
    # snapshot whose combat state matches — combat defers a reflex, it never
    # denies the observed need. The player layer plugs in its own trigger_fn
    # and keeps its own combat vocabulary, so the split binds only here.
    rules = sorted((r for r in cfg["rules"] if r["enabled"]),
                   key=lambda r: -r["priority"])
    gated = est.setdefault("gated", {})
    eligible = []
    for rule in rules:
        name = rule["name"]
        trig = rule["trigger"]
        combat_gated = (trigger_fn is trigger_true and rule["channel"] == "game"
                        and "in_combat" in trig)
        need = {k: v for k, v in trig.items() if k != "in_combat"} \
            if combat_gated else trig
        if trigger_fn(need, snap, food):
            est["streak"][name] = est["streak"].get(name, 0) + 1
        else:
            est["streak"][name] = 0
            est["blocked"].pop(name, None)
            gated.pop(name, None)
            continue
        if est["streak"][name] < rule["hold_ticks"]:
            continue
        if combat_gated and bool(snap.get("in_combat")) != trig["in_combat"]:
            if not gated.get(name):
                log_event({"ts": now, "kind": "combat-hold", "rule": name,
                           "in_combat": bool(snap.get("in_combat"))}, sink)
                gated[name] = True
            continue
        gated.pop(name, None)
        last = est["fired"].get(name, 0)
        if now - last < rule["cooldown_ms"]:
            if not est["blocked"].get(name):
                log_event({"ts": now, "kind": "cooldown-hold", "rule": name,
                           "remaining_ms": rule["cooldown_ms"] - (now - last)}, sink)
                est["blocked"][name] = True
            continue
        est["blocked"].pop(name, None)
        eligible.append(rule)

    snap_brief = {k: snap.get(k) for k in ("tick", "hits", "hits_max", "fatigue",
                                           "x", "z", "in_combat")}

    # Notice channel: independent (spec rule 10). Every firing lands in its
    # own queue file, notice-<id>.json (spec rule 6) — two rules firing on one
    # snapshot must both reach the bridge, so a single shared filename would
    # let the last atomic rename silently swallow the first warning while the
    # log claimed delivery.
    for rule in eligible:
        if rule["channel"] != "notice":
            continue
        action, why = compile_fn(rule, snap, food, defaults["eat_pick"])
        if action is None:
            log_event({"ts": now, "kind": "refused", "rule": rule["name"],
                       "why": why}, sink)
            continue
        est["action_seq"] += 1
        emit("notice-%d.json" % est["action_seq"], action, est["action_seq"], now)
        est["fired"][rule["name"]] = now
        log_event({"ts": now, "kind": "fired", "rule": rule["name"],
                   "id": est["action_seq"], "action": action,
                   "snap": snap_brief}, sink)

    # Game channel: one slot.
    game = [r for r in eligible if r["channel"] == "game"]
    if not game:
        return
    if est["inflight"] is not None:
        log_event({"ts": now, "kind": "inflight-hold",
                   "rules": [r["name"] for r in game],
                   "id": est["inflight"]["id"]}, sink)
        return
    if now - est["last_game_ms"] < defaults["min_action_interval_ms"]:
        log_event({"ts": now, "kind": "interval-hold",
                   "rules": [r["name"] for r in game]}, sink)
        return
    est["window"] = [t for t in est["window"] if now - t < 60000]
    if defaults["max_actions_per_min"] > 0 \
            and len(est["window"]) >= defaults["max_actions_per_min"]:
        log_event({"ts": now, "kind": "cap", "rules": [r["name"] for r in game],
                   "per_min": defaults["max_actions_per_min"]}, sink)
        return

    fired = False
    for rule in game:
        if fired:
            log_event({"ts": now, "kind": "conflict-loss", "rule": rule["name"],
                       "lost_to": game[0]["name"]}, sink)
            continue
        action, why = compile_fn(rule, snap, food, defaults["eat_pick"])
        if action is None:
            log_event({"ts": now, "kind": "refused", "rule": rule["name"],
                       "why": why}, sink)
            continue
        est["action_seq"] += 1
        emit("action.json", action, est["action_seq"], now)
        est["fired"][rule["name"]] = now
        est["last_game_ms"] = now
        est["window"].append(now)
        est["inflight"] = {"id": est["action_seq"], "ts": now,
                           "type": action.get("type")}
        if action.get("type") == "eat":
            est["inflight"].update({
                "item": action["item"],
                "item_quantity": inventory_item_quantity(snap, action["item"]),
                "hits": snap.get("hits"),
                "message_ids": [m.get("id") for m in snap.get("messages") or []
                                if isinstance(m, dict) and m.get("id") is not None],
                "receipted": False,
            })
        log_event({"ts": now, "kind": "fired", "rule": rule["name"],
                   "id": est["action_seq"], "action": action,
                   "snap": snap_brief}, sink)
        fired = True


def refuse_without_food(cfg: dict, food: dict) -> None:
    """Spec rule 12: an eat rule that can never find food must not sit there
    looking like protection."""
    needy = [r["name"] for r in cfg["rules"] if r["enabled"] and needs_food_table(r)]
    if needy and not food:
        die(f"rule(s) {', '.join(needy)} need the food table, and "
            f"{food_path()} is missing or empty — "
            "betty-game init --food-xml <the server's ItemEdibleHeals.xml>")


# --------------------------------------------------------------------------
# Commands.
# --------------------------------------------------------------------------
def cmd_init(args):
    game_dir().mkdir(parents=True, exist_ok=True)
    state_dir().mkdir(parents=True, exist_ok=True)
    if rules_path().exists():
        print(f"rule table already at {rules_path()} — left untouched")
    else:
        atomic_write(rules_path(), json.dumps(DEFAULT_RULES, indent=2) + "\n")
        print(f"wrote default rule table to {rules_path()}")
    if args.food_xml:
        src = Path(args.food_xml)
        if not src.exists():
            die(f"no such file: {src}")
        atomic_write(food_path(), src.read_text())
        table = load_food()
        if not table:
            die(f"{src} held no entries — is it ItemEdibleHeals.xml?")
        print(f"installed food table: {len(table)} edible items")
    elif not food_path().exists():
        print("no food table installed — eat/flee-on-food rules will refuse "
              "to run until `betty-game init --food-xml <path>`")


def cmd_state(args):
    snap = read_snapshot()
    held = (state_dir() / "hold").exists()
    if snap is None:
        print(f"no snapshot at {state_dir() / 'state.json'} — is the bridge running?")
        print(f"hold: {'yes' if held else 'no'}")
        sys.exit(3)
    age = now_ms() - snap.get("ts", 0)
    print(f"snapshot v{snap.get('v')} tick {snap.get('tick')} age {age}ms"
          + (" (STALE)" if age > config_defaults_safe()["stale_ms"] else ""))
    print(f"hold: {'yes' if held else 'no'}")
    if not snap.get("logged_in"):
        print("logged_in: false")
        return
    print(f"logged_in: true  hits: {snap.get('hits')}/{snap.get('hits_max')}"
          f"  fatigue: {snap.get('fatigue')}  at: ({snap.get('x')}, {snap.get('z')})"
          f"  in_combat: {snap.get('in_combat')}")
    inv = snap.get("inventory") or []
    food = load_food()
    for slot, item in enumerate(inv):
        heal = food.get(item.get("id"))
        tag = f"  (food, heals {heal})" if heal is not None else ""
        print(f"  slot {slot}: id {item.get('id')} x{item.get('count')}{tag}")
    for msg in (snap.get("messages") or [])[-5:]:
        print(f"  msg: {msg.get('text') if isinstance(msg, dict) else msg}")


def config_defaults_safe() -> dict:
    try:
        return config_defaults(json.loads(rules_path().read_text()))
    except (OSError, json.JSONDecodeError):
        return dict(DEFAULTS)


def cmd_rules(args):
    cfg = load_config()
    for rule in sorted(cfg["rules"], key=lambda r: -r["priority"]):
        state = "on " if rule["enabled"] else "OFF"
        trig = " ".join(f"{k}={v}" for k, v in rule["trigger"].items())
        act = " ".join(f"{k}={v}" for k, v in rule["action"].items() if k != "type")
        act = rule["action"]["type"] + (f" {act}" if act else "")
        print(f"[{state}] {rule['name']}  ({rule['channel']}, priority "
              f"{rule['priority']}, cooldown {rule['cooldown_ms']}ms, "
              f"hold {rule['hold_ticks']})")
        print(f"       when {trig}  ->  {act}")
    d = config_defaults(cfg)
    print("defaults: " + " ".join(f"{k}={v}" for k, v in sorted(d.items())))


def cmd_actions(args):
    print("game channel (one in flight, receipted):")
    print("  eat            use one food item; slot picked by the food table "
          "and defaults.eat_pick")
    print("  flee           walk distance tiles away from the opponent, or "
          "along dx/dz; clamped to " + str(WALK_CLAMP))
    print("  walk           walk to absolute x/z, clamped to "
          f"{WALK_CLAMP} tiles from the player")
    print("notice channel (independent, no receipt):")
    print("  warn           show the player a local client message; "
          "{hits} {hits_max} {fatigue} {x} {z} {tick} interpolate")


def cmd_enable(args, value=True):
    cfg = load_config()
    rule = find_rule(cfg, args.rule)
    rule["enabled"] = value
    save_config(cfg)
    print(f"{args.rule}: {'enabled' if value else 'disabled'}")


def parse_value(text: str):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def cmd_set(args):
    cfg = load_config()
    rule = find_rule(cfg, args.rule)
    key, value = args.key, parse_value(args.value)
    if key in ("priority", "cooldown_ms", "hold_ticks", "enabled", "channel"):
        rule[key] = value
    elif key.startswith("trigger.") or key.startswith("action."):
        section, sub = key.split(".", 1)
        if value is None:
            rule[section].pop(sub, None)
        else:
            rule[section][sub] = value
    else:
        die(f"unknown key '{key}' — priority, cooldown_ms, hold_ticks, enabled, "
            "channel, trigger.<cond>, action.<param>")
    try:
        save_config(cfg)
    except SystemExit:
        raise
    except ValueError as e:
        die(str(e))
    print(f"{args.rule}: {key} = {value!r}")


def parse_kv(pairs):
    out = {}
    for pair in pairs or []:
        if "=" not in pair:
            die(f"'{pair}' is not key=value")
        key, val = pair.split("=", 1)
        out[key] = parse_value(val)
    return out


def cmd_add(args):
    cfg = load_config()
    rule = {
        "name": args.name,
        "enabled": False,
        "channel": args.channel,
        "priority": args.priority,
        "cooldown_ms": args.cooldown_ms,
        "hold_ticks": args.hold_ticks,
        "trigger": parse_kv(args.trigger),
        "action": {"type": args.action, **parse_kv(args.param)},
    }
    if any(r["name"] == args.name for r in cfg["rules"]):
        die(f"a rule named '{args.name}' already exists")
    cfg["rules"].append(rule)
    try:
        save_config(cfg)
    except ValueError as e:
        die(str(e))
    print(f"added '{args.name}' (disabled — betty-game enable {args.name} arms it)")


def cmd_remove(args):
    cfg = load_config()
    find_rule(cfg, args.rule)
    cfg["rules"] = [r for r in cfg["rules"] if r["name"] != args.rule]
    save_config(cfg)
    print(f"removed '{args.rule}'")


def cmd_hold(args):
    state_dir().mkdir(parents=True, exist_ok=True)
    (state_dir() / "hold").touch()
    print("held: the engine emits nothing and the bridge executes nothing")


def cmd_resume(args):
    try:
        (state_dir() / "hold").unlink()
        print("resumed")
    except FileNotFoundError:
        print("was not held")


def cmd_log(args):
    path = state_dir() / "decisions.jsonl"
    try:
        lines = path.read_text().splitlines()
    except OSError:
        print(f"no decisions yet at {path}")
        return
    for line in lines[-args.n:]:
        print(line)


def cmd_run(args):
    cfg = load_config()
    food = load_food()
    refuse_without_food(cfg, food)
    defaults = config_defaults(cfg)
    poll_ms = args.poll_ms or defaults["poll_ms"]
    state_dir().mkdir(parents=True, exist_ok=True)
    est = load_engine_state()
    est["_inflight_timeout_ms"] = defaults["inflight_timeout_ms"]
    record = open(args.record, "a") if args.record else None
    last_seen = None
    try:
        while True:
            now = now_ms()
            snap = read_snapshot()
            consume_receipt(est, now, snap)
            sweep_dead_notices(now)
            if snap is not None:
                seen = (snap.get("tick"), snap.get("ts"))
                if seen != last_seen:
                    last_seen = seen
                    if record:
                        record.write(json.dumps(snap, separators=(",", ":")) + "\n")
                        record.flush()
                    evaluate(cfg, food, snap, est, now)
                    est.pop("_inflight_timeout_ms", None)
                    save_engine_state(est)
                    est["_inflight_timeout_ms"] = defaults["inflight_timeout_ms"]
            elif args.once:
                die(f"no snapshot at {state_dir() / 'state.json'}")
            if args.once:
                break
            time.sleep(poll_ms / 1000.0)
    except KeyboardInterrupt:
        pass
    finally:
        if record:
            record.close()


def cmd_replay(args):
    cfg = load_config()
    food = load_food()
    path = Path(args.file)
    if not path.exists():
        die(f"no recording at {path}")
    est = load_engine_state.__wrapped__() if hasattr(load_engine_state, "__wrapped__") \
        else None
    # A fresh, in-memory engine state: replay never reads or writes the live one.
    est = {
        "action_seq": 0, "fired": {}, "streak": {}, "blocked": {}, "gated": {},
        "inflight": None, "last_game_ms": 0, "window": [], "last_tick": -1,
        "was_stale": False, "was_out": False, "was_held": False,
    }
    sink = []

    def no_emit(name, action, action_id, ts):
        pass

    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        snap = json.loads(line)
        # Time in a replay is the snapshot's own clock, so staleness and
        # cooldowns replay on the recorded timeline.
        evaluate(cfg, food, snap, est, snap.get("ts", 0), emit=no_emit, sink=sink)
        # A game action in a replay is never in flight: there is no bridge.
        est["inflight"] = None
    for event in sink:
        print(json.dumps(event, separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser(
        prog="betty-game", description="the visible-state reflex engine")
    sub = parser.add_subparsers(dest="cmd")

    p = sub.add_parser("init", help="write the default rule table, install the food table")
    p.add_argument("--food-xml", help="the game server's ItemEdibleHeals.xml")
    p.set_defaults(fn=cmd_init)

    sub.add_parser("state", help="the current snapshot").set_defaults(fn=cmd_state)
    sub.add_parser("rules", help="the rule table").set_defaults(fn=cmd_rules)
    sub.add_parser("actions", help="the action vocabulary").set_defaults(fn=cmd_actions)

    p = sub.add_parser("enable", help="arm a rule")
    p.add_argument("rule")
    p.set_defaults(fn=lambda a: cmd_enable(a, True))
    p = sub.add_parser("disable", help="disarm a rule")
    p.add_argument("rule")
    p.set_defaults(fn=lambda a: cmd_enable(a, False))

    p = sub.add_parser("set", help="tune one rule key")
    p.add_argument("rule")
    p.add_argument("key")
    p.add_argument("value")
    p.set_defaults(fn=cmd_set)

    p = sub.add_parser("add", help="add a rule (it arrives disabled)")
    p.add_argument("name")
    p.add_argument("--channel", required=True, choices=CHANNELS)
    p.add_argument("--priority", type=int, required=True)
    p.add_argument("--cooldown-ms", type=int, default=1500)
    p.add_argument("--hold-ticks", type=int, default=2)
    p.add_argument("--trigger", action="append", metavar="COND=VALUE")
    p.add_argument("--action", required=True)
    p.add_argument("--param", action="append", metavar="KEY=VALUE")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("remove", help="remove a rule")
    p.add_argument("rule")
    p.set_defaults(fn=cmd_remove)

    sub.add_parser("hold", help="the manual override: stop everything now") \
        .set_defaults(fn=cmd_hold)
    sub.add_parser("resume", help="lift the override").set_defaults(fn=cmd_resume)

    p = sub.add_parser("log", help="tail the decision log")
    p.add_argument("-n", type=int, default=20)
    p.set_defaults(fn=cmd_log)

    p = sub.add_parser("run", help="the engine loop")
    p.add_argument("--once", action="store_true",
                   help="evaluate the current snapshot once and exit")
    p.add_argument("--poll-ms", type=int)
    p.add_argument("--record", help="append every evaluated snapshot to this file")
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("replay", help="re-evaluate a recording; emits nothing")
    p.add_argument("file")
    p.set_defaults(fn=cmd_replay)

    args = parser.parse_args()
    if not getattr(args, "fn", None):
        parser.print_help()
        sys.exit(2)
    args.fn(args)


if __name__ == "__main__":
    main()
