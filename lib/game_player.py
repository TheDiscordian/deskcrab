#!/usr/bin/env python3
"""game_player.py — learned rules are the primary play path (specs/game-player.md).

The deliberate-play channel's trigger-action table: rules the player's own
hand wrote down at the moment a play verified, evaluated against the live
bridge snapshot BEFORE any model reasoning, executed through the bridge's
one action slot. The evaluation machinery is lib/game_reflex.py's evaluate —
the same priorities, cooldowns, debounce, one receipted action in flight,
pacing and hold override — with this layer's own trigger and action
vocabulary plugged in. No model call is ever made anywhere in this module.

Stdlib only, plain python3.
"""

import argparse
import ctypes
import fcntl
import json
import os
import select
import sys
import time
import unicodedata
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import game_reflex  # noqa: E402  (the shared engine; specs/game-player.md rule 2)

# The closed vocabularies (spec rules 4 and 5). They grow by spec change only.
TRIGGER_KEYS = ("objective_is", "activity_is", "npc_visible", "object_visible", "bound_visible",
                "ground_item_visible", "shop_item_visible", "bank_item_visible",
                "message_contains", "near_tile",
                "inventory_has", "inventory_lacks", "inventory_slots_below",
                "inventory_slots_at_least", "in_combat", "out_of_combat")
ACTIONS = ("talk-npc", "interact-npc", "walk", "retreat", "interact-object", "interact-bound", "click-entity",
           "click-inventory", "click-shop", "click-bank", "take-ground")
SYSTEM_FEEDBACK_CHANNELS = ("game", "quest", "inventory")
WAIT_CONDITIONS = (
    "logged_in", "logged_out", "walking", "not_walking", "in_combat",
    "out_of_combat", "talking_to_npc", "not_talking_to_npc",
    "right_click_menu_open", "right_click_menu_closed",
    "trade_open", "trade_closed", "sleeping", "not_sleeping", "fatigue_zero",
)
WAIT_DEFAULT_S = 15.0
WAIT_MAX_S = 60.0
WAIT_SNAPSHOT_FRESH_MS = 2000

# Spec rule 4: a stored near_tile radius below this evaluates as this, and the
# lint (rule 17) refuses to author one. A trigger names the vicinity while
# walk verification owns the exact destination.
NEAR_RADIUS_FLOOR = 2

# Spec rule 7a: a walk's receipt is dispatch, not completion. Verification
# follows the snapshot until the body stops moving, then compares the settled
# tile against the TARGET's coordinates within the action's arrive tolerance.
WALK_ARRIVE_DEFAULT = 1     # Chebyshev tiles
WALK_SETTLE_S = 1.6         # no position change for this long = stopped
WALK_TIMEOUT_S = 25.0       # hard ceiling on one walk's verification
TAKE_TIMEOUT_S = 25.0       # a pickup can include the same bounded pathing delay
TAKE_MISSING_GRACE_S = 0.75 # let inventory follow a just-removed ground entry
RETREAT_VERIFY_S = 1.25     # one server-round-sized observation before a retry
RUNNER_FRESH_MS = 30000     # a heartbeat younger than this (and a live pid) means the
                            # runner owns evaluation; wide enough to cover one walk's
                            # verification, and a crashed runner fails the pid check at once
GAP_STABLE_MS = 750          # moving across tiles is one situation, not one Sol wake per tile
PLAYER_MESSAGE_SETTLE_MS = 5000  # collect one RuneScape-length chat chain before Sol replies
REPETITION_WINDOW_MS = 3 * 60 * 1000
REPETITION_THRESHOLD = 3
ROUTE_RULE_NAME = "active-route"
ROUTE_PRIORITY = -1_000_000  # every learned interaction outranks ordinary travel
MANUAL_RETREAT_RULE_NAME = "manual-retreat-request"
MANUAL_RETREAT_PRIORITY = 1_000_000

DEFAULTS = {
    "stale_ms": 2000,
    "min_action_interval_ms": 600,
    "max_actions_per_min": 20,
    "inflight_timeout_ms": 3000,
}

EXIT_FIRED = 0
EXIT_NOT_DONE = 2
EXIT_NOT_READY = 3
EXIT_NO_RULE = 4
EXIT_HELD = 5
EXIT_PLAYER_MESSAGE = 6
EXIT_SYSTEM_MESSAGE = 7
EXIT_SESSION_OVER = 8

# Spec rule 21: a sitting is bounded. Defaults in milliseconds; the entrypoint
# reads the user's own spelling out of the config and hands them down.
SESSION_LIMIT_MS = 2 * 60 * 60 * 1000
SESSION_GRACE_MS = 10 * 60 * 1000

EMPTY_TABLE = {"v": 1, "defaults": dict(DEFAULTS), "rules": [], "unfinished": []}


def state_dir() -> Path:
    return game_reflex.state_dir()


def game_dir() -> Path:
    return game_reflex.game_dir()


def rules_path() -> Path:
    return game_dir() / "learned-rules.json"


def objective_path() -> Path:
    return game_dir() / "objective"


def activity_path() -> Path:
    return game_dir() / "activity"


def activity_stats_path() -> Path:
    return game_dir() / "activity-stats.json"


def retreat_request_path() -> Path:
    return state_dir() / "retreat-request.json"


def take_progress_path() -> Path:
    return state_dir() / "take-in-progress.json"


def foreign_take_in_progress() -> dict | None:
    try:
        progress = json.loads(take_progress_path().read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(progress, dict) or progress.get("v") != 1 \
            or not isinstance(progress.get("pid"), int) \
            or not isinstance(progress.get("expires"), int) \
            or progress["expires"] <= now_ms():
        try:
            take_progress_path().unlink()
        except FileNotFoundError:
            pass
        return None
    return progress if progress["pid"] != os.getpid() else None


def load_retreat_request():
    try:
        request = json.loads(retreat_request_path().read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(request, dict) or request.get("v") != 1 \
            or not isinstance(request.get("expires"), int) \
            or request["expires"] <= now_ms() \
            or not isinstance(request.get("distance"), int) \
            or not 1 <= request["distance"] <= 10 \
            or request.get("dx") not in (-1, 0, 1) \
            or request.get("dz") not in (-1, 0, 1) \
            or (request.get("dx") == 0 and request.get("dz") == 0):
        clear_retreat_request()
        return None
    return request


def clear_retreat_request() -> None:
    try:
        retreat_request_path().unlink()
    except FileNotFoundError:
        pass


def route_path() -> Path:
    return game_dir() / "route.json"


def session_path() -> Path:
    return game_dir() / "session.json"


def read_session() -> dict:
    """The session record, ended or not, or {} when there is none (spec rule
    21). A file that cannot be read is no session: the clock never invents a
    deadline out of damage."""
    try:
        body = json.loads(session_path().read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(body, dict) or not body.get("started"):
        return {}
    return body


def session_state(now: int = None) -> dict:
    """Where the sitting stands:

    - `none`    — no record at all. Nothing is suppressed: the limit bounds a
                  sitting that was opened, not the act of playing.
    - `open`    — inside its limit.
    - `over`    — past the limit, inside the grace. Wind-down time.
    - `expired` — past the grace too.
    - `ended`   — closed, by her hand or the timer's.

    `ended` SUPPRESSES exactly as `over` does, and that is the point: a closed
    sitting means play has stopped, so a resident runner that outlived the stop
    (its supervisor can re-raise it) finds the table quiet instead of happily
    resuming unattended play. Only opening a new sitting lifts it.
    """
    s = read_session()
    if not s:
        return {"phase": "none"}
    now = now_ms() if now is None else now
    limit = int(s.get("limit_ms") or SESSION_LIMIT_MS)
    grace = int(s.get("grace_ms") or SESSION_GRACE_MS)
    elapsed = now - int(s["started"])
    out = {"phase": "open", "started": int(s["started"]), "elapsed_ms": elapsed,
           "limit_ms": limit, "grace_ms": grace,
           "grace_ms_left": max(0, limit + grace - elapsed)}
    if s.get("ended"):
        out["phase"] = "ended"
        out["grace_ms_left"] = 0
    elif elapsed >= limit + grace:
        out["phase"] = "expired"
    elif elapsed >= limit:
        out["phase"] = "over"
    return out


def tests_path() -> Path:
    return game_dir() / "learned-rule-tests.json"


def queue_path() -> Path:
    return game_dir() / "outcome-queue.jsonl"


def runner_path() -> Path:
    return state_dir() / "player-runner.json"


def player_lock_path() -> Path:
    return state_dir() / "player-engine.lock"


def die(msg: str) -> None:
    sys.exit(f"game-player: {msg}")


def now_ms() -> int:
    return int(time.time() * 1000)


def load_route():
    try:
        route = json.loads(route_path().read_text())
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError):
        return {"status": "invalid"}
    if not isinstance(route, dict) or route.get("v") != 1 \
            or not isinstance(route.get("x"), int) \
            or not isinstance(route.get("z"), int) \
            or not isinstance(route.get("arrive"), int) \
            or not 0 <= route["arrive"] <= 10 \
            or not isinstance(route.get("objective"), str) \
            or route.get("status") not in ("active", "blocked"):
        return {"status": "invalid"}
    return route


def save_route(route: dict) -> None:
    game_dir().mkdir(parents=True, exist_ok=True)
    game_reflex.atomic_write(route_path(), json.dumps(route, indent=2) + "\n")


def clear_route() -> None:
    try:
        route_path().unlink()
    except FileNotFoundError:
        pass


def route_distance(x: int, z: int, route: dict) -> int:
    return max(abs(x - route["x"]), abs(z - route["z"]))


def route_obstacle_signature(snap: dict) -> str:
    """Facts whose change can make a locally blocked route worth retrying."""
    shape = {
        # Do not include the body tile. A dispatched route leg can continue
        # settling for one tile after verification classifies it as blocked;
        # treating that late step as a new obstacle state immediately retries
        # the same failed strategy and can walk farther away. A changed local
        # collision scene may make the route viable; otherwise Sol must choose
        # a correction and explicitly set a new route.
        "objects": sorted((o.get("id"), o.get("x"), o.get("z"), o.get("dir"))
                          for o in snap.get("objects") or [] if isinstance(o, dict)),
        "bounds": sorted((b.get("id"), b.get("x"), b.get("z"), b.get("dir"))
                         for b in snap.get("bounds") or [] if isinstance(b, dict)),
    }
    return json.dumps(shape, sort_keys=True, separators=(",", ":"))


def block_route(route: dict, snap: dict, reason: str) -> None:
    blocked = dict(route)
    blocked.update({"status": "blocked", "blocked_reason": reason,
                    "blocked_signature": route_obstacle_signature(snap),
                    "blocked_ts": now_ms()})
    save_route(blocked)


# --------------------------------------------------------------------------
# The rule table (spec rule 3): load, validate, save. Same one-gate shape as
# the reflex table — nothing unvalidated is written or evaluated.
# --------------------------------------------------------------------------
def validate_config(cfg: dict) -> None:
    def bad(msg):
        raise ValueError(msg)

    if not isinstance(cfg, dict) or "rules" not in cfg:
        bad("the learned table must be an object with a 'rules' list")
    defaults = cfg.get("defaults", {})
    if not isinstance(defaults, dict):
        bad("'defaults' must be an object")
    for key in defaults:
        if key not in DEFAULTS:
            bad(f"unknown defaults key '{key}' (known: {', '.join(sorted(DEFAULTS))})")
        if not isinstance(defaults[key], int) or defaults[key] < 0:
            bad(f"defaults.{key} must be a non-negative integer")

    unfinished = cfg.get("unfinished", [])
    if not isinstance(unfinished, list):
        bad("'unfinished' must be a list")
    for entry in unfinished:
        if not isinstance(entry, dict) or not entry.get("name") or not entry.get("note"):
            bad("every unfinished entry needs a name and a note")

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
        for key in ("enabled",):
            if not isinstance(rule.get(key), bool):
                bad(f"{where}: {key} must be true or false")
        if not isinstance(rule.get("priority"), int):
            bad(f"{where}: priority must be an integer")
        if not isinstance(rule.get("cooldown_ms"), int) or rule["cooldown_ms"] < 0:
            bad(f"{where}: cooldown_ms must be a non-negative integer")
        if not isinstance(rule.get("hold_ticks"), int) or rule["hold_ticks"] < 1:
            bad(f"{where}: hold_ticks must be an integer >= 1")
        if "once_per_objective" in rule and not isinstance(rule["once_per_objective"], bool):
            bad(f"{where}: once_per_objective must be true or false")
        if "note" in rule and not isinstance(rule["note"], str):
            bad(f"{where}: note must be a string")
        extra = set(rule) - {"name", "enabled", "priority", "cooldown_ms",
                             "hold_ticks", "once_per_objective", "note",
                             "trigger", "action"}
        if extra:
            bad(f"{where}: unknown key(s) {', '.join(sorted(extra))}")

        trig = rule.get("trigger")
        if not isinstance(trig, dict) or not trig:
            bad(f"{where}: trigger must be a non-empty object")
        for key, val in trig.items():
            if key not in TRIGGER_KEYS:
                bad(f"{where}: unknown trigger '{key}' "
                    f"(known: {', '.join(TRIGGER_KEYS)})")
            if key in ("objective_is", "activity_is"):
                if not isinstance(val, str) or not val.strip() or "\n" in val:
                    bad(f"{where}: trigger.{key} must be a non-empty single line")
            elif key == "message_contains":
                if not isinstance(val, str) or not val.strip() or "\n" in val:
                    bad(f"{where}: trigger.message_contains must be a non-empty single line")
            elif key == "near_tile":
                if (not isinstance(val, dict)
                        or not isinstance(val.get("x"), int)
                        or not isinstance(val.get("z"), int)
                        or not isinstance(val.get("radius"), int)
                        or not 0 <= val["radius"] <= 50
                        or set(val) != {"x", "z", "radius"}):
                    bad(f"{where}: trigger.near_tile must be "
                        "{{\"x\":int,\"z\":int,\"radius\":0..50}}")
            elif key in ("npc_visible", "object_visible", "bound_visible",
                         "ground_item_visible", "shop_item_visible", "bank_item_visible",
                         "inventory_has", "inventory_lacks"):
                if not isinstance(val, int) or val < 0:
                    bad(f"{where}: trigger.{key} must be a non-negative type/item id")
            elif key in ("inventory_slots_below", "inventory_slots_at_least"):
                if not isinstance(val, int) or not 0 <= val <= 30:
                    bad(f"{where}: trigger.{key} must be an integer from 0 to 30")
            elif key in ("in_combat", "out_of_combat"):
                if val is not True:
                    bad(f"{where}: trigger.{key} must be true when present")
        if "inventory_has" in trig and "inventory_lacks" in trig \
                and trig["inventory_has"] == trig["inventory_lacks"]:
            bad(f"{where}: inventory_has and inventory_lacks name the same id")
        if "inventory_slots_below" in trig and "inventory_slots_at_least" in trig \
                and trig["inventory_slots_at_least"] >= trig["inventory_slots_below"]:
            bad(f"{where}: inventory slot range can never match")

        action = rule.get("action")
        if not isinstance(action, dict) or action.get("type") not in ACTIONS:
            bad(f"{where}: action.type must be one of {', '.join(ACTIONS)}")
        atype = action["type"]
        if atype == "talk-npc":
            if set(action) != {"type", "npc"} or not isinstance(action.get("npc"), int):
                bad(f"{where}: talk-npc takes exactly npc=<type id>")
        elif atype == "interact-npc":
            if not set(action) <= {"type", "npc", "cmd", "within"} \
                    or not isinstance(action.get("npc"), int) or action["npc"] < 0:
                bad(f"{where}: interact-npc takes npc=<type id> and optionally cmd/within")
            if "cmd" in action and action["cmd"] not in (1, 2):
                bad(f"{where}: interact-npc cmd must be 1 or 2 (the def's menu commands)")
            if "within" in action and (not isinstance(action["within"], int)
                                        or not 0 <= action["within"] <= 10):
                bad(f"{where}: interact-npc within must be an integer 0..10")
        elif atype == "walk":
            if not set(action) <= {"type", "x", "z", "arrive"} \
                    or not isinstance(action.get("x"), int) \
                    or not isinstance(action.get("z"), int):
                bad(f"{where}: walk takes integer x and z (and optionally arrive)")
            if "arrive" in action and (not isinstance(action["arrive"], int)
                                       or not 0 <= action["arrive"] <= 10):
                bad(f"{where}: walk arrive must be an integer 0..10")
        elif atype == "retreat":
            if set(action) - {"type", "distance", "dx", "dz"}:
                bad(f"{where}: retreat takes only optional distance/dx/dz")
            distance = action.get("distance", 5)
            dx, dz = action.get("dx", 0), action.get("dz", 1)
            if not isinstance(distance, int) or not 1 <= distance <= 10:
                bad(f"{where}: retreat distance must be an integer 1..10")
            if dx not in (-1, 0, 1) or dz not in (-1, 0, 1) or (dx == 0 and dz == 0):
                bad(f"{where}: retreat dx/dz must be -1, 0, or 1 and not both zero")
        elif atype in ("interact-object", "interact-bound"):
            if not set(action) <= {"type", "obj", "cmd"} \
                    or not isinstance(action.get("obj"), int) or action["obj"] < 0:
                bad(f"{where}: {atype} takes obj=<type id> and optionally cmd")
            if "cmd" in action and action["cmd"] not in (1, 2):
                bad(f"{where}: {atype} cmd must be 1 or 2 (the def's menu commands)")
        elif atype == "click-entity":
            if set(action) - {"type", "kind", "entity", "button"} \
                    or action.get("kind") not in ("npc", "object", "bound") \
                    or not isinstance(action.get("entity"), int) \
                    or action["entity"] < 0:
                bad(f"{where}: click-entity takes kind=npc|object|bound and "
                    "entity=<type id>, with optional button")
            if "button" in action and action["button"] not in (1, 2, 3):
                bad(f"{where}: click-entity button must be 1, 2, or 3")
        elif atype in ("click-inventory", "click-shop", "click-bank"):
            if set(action) - {"type", "item", "button"} \
                    or not isinstance(action.get("item"), int) \
                    or action["item"] < 0:
                bad(f"{where}: {atype} takes item=<item id>, "
                    "with optional button")
            if "button" in action and action["button"] not in (1, 2, 3):
                bad(f"{where}: {atype} button must be 1, 2, or 3")
        elif atype == "take-ground":
            if not set(action) <= {"type", "item", "within"} \
                    or not isinstance(action.get("item"), int) \
                    or action["item"] < 0:
                bad(f"{where}: take-ground takes item=<item id> and optionally within")
            if "within" in action and (not isinstance(action["within"], int)
                                        or not 0 <= action["within"] <= 10):
                bad(f"{where}: take-ground within must be an integer 0..10")


def load_config() -> dict:
    path = rules_path()
    if not path.exists():
        die(f"no learned table at {path} — run `game_player.py init` first")
    try:
        cfg = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        die(f"learned table {path} is not valid JSON: {e}")
    try:
        validate_config(cfg)
    except ValueError as e:
        die(f"learned table {path}: {e}")
    cfg.setdefault("unfinished", [])
    return cfg


def save_config(cfg: dict) -> None:
    validate_config(cfg)
    game_reflex.atomic_write(rules_path(), json.dumps(cfg, indent=2) + "\n")


def config_defaults(cfg: dict) -> dict:
    merged = dict(DEFAULTS)
    merged.update(cfg.get("defaults", {}))
    return merged


def read_objective() -> str:
    try:
        return objective_path().read_text().strip()
    except OSError:
        return ""


def read_activity() -> str:
    try:
        return activity_path().read_text().strip()
    except OSError:
        return ""


def snapshot_skills(snap: dict) -> dict:
    """Skill id -> the grounded cumulative XP currently published by the client."""
    found = {}
    for skill in snap.get("skills") or []:
        if not isinstance(skill, dict) or not isinstance(skill.get("id"), int) \
                or not isinstance(skill.get("xp"), int):
            continue
        found[str(skill["id"])] = {
            "id": skill["id"],
            "name": str(skill.get("name") or f"skill-{skill['id']}")[:64],
            "level": skill.get("level") if isinstance(skill.get("level"), int) else None,
            "xp": skill["xp"],
        }
    return found


def skills_ready(skills: dict) -> bool:
    """Login briefly exposes zero-filled client arrays. A real RSC skill table
    always has at least one positive base level, even for a new character."""
    return any(isinstance(skill.get("level"), int) and skill["level"] > 0
               for skill in skills.values())


def load_activity_stats() -> dict:
    try:
        body = json.loads(activity_stats_path().read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return body if isinstance(body, dict) else {}


def clear_activity_stats() -> None:
    try:
        activity_stats_path().unlink()
    except FileNotFoundError:
        pass


def start_activity_stats(activity: str, snap: dict, started_ms=None) -> dict:
    """Start one activity clock from a cumulative-XP snapshot, when available."""
    skills = snapshot_skills(snap)
    if not activity or not skills_ready(skills):
        return {}
    started = started_ms if isinstance(started_ms, int) else now_ms()
    stats = {
        "v": 2,
        "activity": activity,
        "started_ms": started,
        "baseline_ready": True,
        "baseline_xp": {key: val["xp"] for key, val in skills.items()},
        "last_xp": {key: val["xp"] for key, val in skills.items()},
        "skill_names": {key: val["name"] for key, val in skills.items()},
        "last_action_xp": [],
        "updated_ms": started,
    }
    game_reflex.atomic_write(activity_stats_path(), json.dumps(stats, indent=2) + "\n")
    return stats


def refresh_activity_stats(snap: dict, activity: str) -> dict:
    """Observe XP drops without inventing an action from chat or screen state.

    OpenRSC changes cumulative XP once for each XP-bearing game action. The
    resident 150ms observer records each positive delta as that action's XP;
    the longer-lived baseline remains tied to the selected activity.
    """
    if not activity:
        return {}
    skills = snapshot_skills(snap)
    stats = load_activity_stats()
    if stats.get("activity") != activity or not stats.get("baseline_xp"):
        return start_activity_stats(activity, snap)
    if not skills_ready(skills):
        return stats
    # A pre-v2 baseline has no proof it was not captured from the zero-filled
    # login placeholder. Establish it honestly from this first ready frame.
    if stats.get("baseline_ready") is not True:
        return start_activity_stats(activity, snap)

    previous = stats.get("last_xp") if isinstance(stats.get("last_xp"), dict) else {}
    changes = []
    for key, skill in skills.items():
        old = previous.get(key)
        if isinstance(old, int) and skill["xp"] > old:
            changes.append({"id": skill["id"], "name": skill["name"],
                            "xp": skill["xp"] - old})
    current = {key: val["xp"] for key, val in skills.items()}
    names = {key: val["name"] for key, val in skills.items()}
    if current != previous or names != stats.get("skill_names"):
        stats["last_xp"] = current
        stats["skill_names"] = names
        stats["updated_ms"] = now_ms()
        if changes:
            stats["last_action_xp"] = changes
            stats["last_action_ms"] = snap.get("ts") if isinstance(snap.get("ts"), int) \
                else stats["updated_ms"]
        game_reflex.atomic_write(activity_stats_path(), json.dumps(stats, indent=2) + "\n")
    return stats


def activity_metrics(snap: dict, activity: str) -> dict:
    stats = refresh_activity_stats(snap, activity)
    if not stats:
        return {}
    now = now_ms()
    elapsed = max(1, now - stats.get("started_ms", now))
    baseline = stats.get("baseline_xp") or {}
    current = snapshot_skills(snap)
    last_by_id = {str(v.get("id")): v for v in stats.get("last_action_xp") or []
                  if isinstance(v, dict)}
    skills = []
    for key, skill in current.items():
        start_xp = baseline.get(key)
        if not isinstance(start_xp, int) or skill["xp"] <= start_xp:
            continue
        gained = skill["xp"] - start_xp
        item = {"id": skill["id"], "name": skill["name"], "gained": gained,
                "xp_per_hour": round(gained * 3600000 / elapsed)}
        if key in last_by_id and isinstance(last_by_id[key].get("xp"), int):
            item["last_action_xp"] = last_by_id[key]["xp"]
        skills.append(item)
    return {"activity": activity, "started_ms": stats.get("started_ms"),
            "elapsed_ms": elapsed, "skills": skills}


def activity_xp_text(snap: dict, activity: str) -> str:
    parts = []
    for skill in activity_metrics(snap, activity).get("skills") or []:
        fields = []
        if skill.get("last_action_xp", 0) > 0:
            fields.append(f"+{skill['last_action_xp']}/action")
        fields.extend((f"+{skill['gained']}_total", f"{skill['xp_per_hour']}/hr"))
        parts.append(f"{skill['name']}:" + ",".join(fields))
    return ";".join(parts)


# --------------------------------------------------------------------------
# Engine state (spec rules 1 and 9): the reflex engine's counters plus the
# once-per-objective marks, in this layer's own file. The action id sequence
# is seeded from the clock at first creation so the shared receipt channel
# can never confuse this engine's ids with the reflex engine's small ones.
# --------------------------------------------------------------------------
def load_player_state() -> dict:
    path = state_dir() / "player-engine-state.json"
    try:
        est = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        est = {}
    est.setdefault("action_seq", now_ms())
    est.setdefault("fired", {})
    est.setdefault("streak", {})
    est.setdefault("blocked", {})
    est.setdefault("inflight", None)
    est.setdefault("last_game_ms", 0)
    est.setdefault("window", [])
    est.setdefault("last_tick", -1)
    est.setdefault("was_stale", False)
    est.setdefault("was_out", False)
    est.setdefault("was_held", False)
    est.setdefault("objective_fired", {})   # "rule\tobjective" -> epoch ms
    est.setdefault("seen_message_ids", [])
    est.setdefault("pending_messages", [])
    est.setdefault("message_settle_until", 0)
    est.setdefault("seen_system_message_ids", [])
    est.setdefault("pending_system_messages", [])
    est.setdefault("recent_repetitions", [])
    est.setdefault("reported_repetitions", {})
    return est


def save_player_state(est: dict) -> None:
    est = {k: v for k, v in est.items() if not k.startswith("_")}
    game_reflex.atomic_write(state_dir() / "player-engine-state.json",
                             json.dumps(est) + "\n")


def flush_events(events: list) -> None:
    if not events:
        return
    path = state_dir() / "player-decisions.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as fh:
        for event in events:
            fh.write(json.dumps(event, separators=(",", ":")) + "\n")


class player_state_lock:
    """Cross-process guard for the runner and deliberate reply command."""
    def __enter__(self):
        player_lock_path().parent.mkdir(parents=True, exist_ok=True)
        self.fh = open(player_lock_path(), "a+")
        fcntl.flock(self.fh.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc, tb):
        fcntl.flock(self.fh.fileno(), fcntl.LOCK_UN)
        self.fh.close()


def capture_player_messages(snap: dict, est: dict, events: list) -> int:
    """Copy new incoming local/private messages into the existing engine state."""
    seen = set(est.get("seen_message_ids") or [])
    pending = est.get("pending_messages") or []
    captured = 0
    captured_at = now_ms()
    for message in snap.get("messages") or []:
        if not isinstance(message, dict):
            continue
        message_id = message.get("id")
        channel = message.get("channel")
        if not isinstance(message_id, int) or message_id in seen \
                or message.get("incoming") is not True \
                or channel not in ("local", "private"):
            continue
        sender, text = message.get("sender"), message.get("text")
        if not isinstance(sender, str) or not sender.strip() \
                or not isinstance(text, str) or not text.strip():
            continue
        item = {"id": message_id, "channel": channel,
                "sender": sender, "text": text, "captured_ts": captured_at}
        pending.append(item)
        seen.add(message_id)
        captured += 1
        events.append({"ts": now_ms(), "kind": "player-message-received", **item})
    est["pending_messages"] = sorted(pending, key=lambda m: m["id"])
    est["seen_message_ids"] = sorted(seen)[-500:]
    if captured:
        est["message_settle_until"] = captured_at + PLAYER_MESSAGE_SETTLE_MS
    return captured


def pending_message_batch(est: dict) -> list:
    """The oldest sender/channel conversation, including its full pending chain."""
    pending = sorted(est.get("pending_messages") or [], key=lambda m: m["id"])
    if not pending:
        return []
    first = pending[0]
    sender = str(first.get("sender", "")).casefold()
    channel = first.get("channel")
    return [m for m in pending
            if m.get("channel") == channel
            and str(m.get("sender", "")).casefold() == sender]


def pending_message_burst(batch: list) -> str:
    return json.dumps([
        {"id": m["id"], "text": m["text"]} for m in batch
    ], separators=(",", ":"), ensure_ascii=False)


def oldest_pending_message(est: dict):
    batch = pending_message_batch(est)
    # Replying to the newest id clears every older message in this same
    # sender/channel chain, while a different player's burst remains pending.
    return batch[-1] if batch else None


def is_idle_movement_warning(message: dict) -> bool:
    """The server's blue idle warning, tolerant of wording variants."""
    if not isinstance(message, dict) or message.get("channel") != "game":
        return False
    text = " ".join(str(message.get("text", "")).casefold().split())
    standing = "standing here for" in text or "standing still for" in text
    return standing and (" min" in text or "minute" in text) and "move" in text


def capture_urgent_system_messages(snap: dict, est: dict, events: list) -> None:
    """Persist the idle warning until a changed player tile proves movement."""
    px, pz = snap.get("x"), snap.get("z")
    pending = est.get("pending_system_messages") or []
    still_pending = []
    for message in pending:
        if isinstance(px, int) and isinstance(pz, int) \
                and (px != message.get("x") or pz != message.get("z")):
            events.append({"ts": now_ms(), "kind": "system-message-handled",
                           "id": message.get("id"), "reason": "player-moved",
                           "x": px, "z": pz})
        else:
            still_pending.append(message)
    pending = still_pending

    seen = set(est.get("seen_system_message_ids") or [])
    for message in snap.get("messages") or []:
        if not is_idle_movement_warning(message):
            continue
        message_id = message.get("id")
        text = message.get("text")
        if not isinstance(message_id, int) or message_id in seen \
                or not isinstance(text, str) or not isinstance(px, int) \
                or not isinstance(pz, int):
            continue
        item = {"id": message_id, "channel": message.get("channel", "game"),
                "text": text, "x": px, "z": pz}
        pending.append(item)
        seen.add(message_id)
        events.append({"ts": now_ms(), "kind": "system-message-received", **item})
    est["pending_system_messages"] = sorted(pending, key=lambda m: m["id"])
    est["seen_system_message_ids"] = sorted(seen)[-500:]


def oldest_pending_system_message(est: dict):
    pending = est.get("pending_system_messages") or []
    return min(pending, key=lambda m: m["id"]) if pending else None


def latest_system_feedback(snap: dict):
    """Latest non-player game text, compact enough to ride a play verdict."""
    for message in reversed(snap.get("messages") or []):
        if not isinstance(message, dict) \
                or message.get("channel") not in SYSTEM_FEEDBACK_CHANNELS:
            continue
        text = " ".join(str(message.get("text", "")).split())
        if text:
            return text[:240]
    return None


def retreat_lock_feedback(snap: dict) -> bool:
    """The server's authoritative refusal. If it is still in the current
    snapshot while combat remains active, merely waiting cannot clear combat:
    a later retreat request is still required."""
    needle = "can't retreat during the first 3 rounds of combat"
    return any(
        isinstance(message, dict)
        and needle in str(message.get("text", "")).casefold()
        for message in snap.get("messages") or []
    )


def record_wait_failure(condition: str, verdict: str, snap: dict, timeout=None) -> None:
    record = {"ts": now_ms(), "kind": "wait-failure", "condition": condition,
              "status": verdict, "objective": read_objective() or None,
              "activity": read_activity() or None, "snap": snap_brief(snap)}
    if timeout is not None:
        record["timeout"] = timeout
    append_outcome(record)
    flush_events([{k: v for k, v in record.items() if k != "snap"}])


# --------------------------------------------------------------------------
# State waiting (spec rule 7d): one ACTIONS snapshot path, no timed polling.
# Atomic snapshot writes arrive as inotify move/create events. A hard deadline
# is mandatory so a missing transition can never strand the playing hand.
# --------------------------------------------------------------------------
class SnapshotChangeWatch:
    IN_CLOSE_WRITE = 0x00000008
    IN_MOVED_TO = 0x00000080
    IN_CREATE = 0x00000100
    MASK = IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE

    def __enter__(self):
        state_dir().mkdir(parents=True, exist_ok=True)
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libc.inotify_init1.argtypes = [ctypes.c_int]
        self.libc.inotify_init1.restype = ctypes.c_int
        self.libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p,
                                                ctypes.c_uint32]
        self.libc.inotify_add_watch.restype = ctypes.c_int
        self.fd = self.libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
        if self.fd < 0:
            err = ctypes.get_errno()
            die(f"cannot watch ACTIONS state: {os.strerror(err)}")
        wd = self.libc.inotify_add_watch(
            self.fd, os.fsencode(str(state_dir())), self.MASK)
        if wd < 0:
            err = ctypes.get_errno()
            os.close(self.fd)
            die(f"cannot watch ACTIONS state directory: {os.strerror(err)}")
        self.poller = select.poll()
        self.poller.register(self.fd, select.POLLIN)
        return self

    def wait(self, seconds: float) -> None:
        timeout_ms = max(1, int(seconds * 1000))
        if self.poller.poll(timeout_ms):
            try:
                os.read(self.fd, 65536)
            except BlockingIOError:
                pass

    def __exit__(self, exc_type, exc, tb):
        os.close(self.fd)


def normalise_wait_condition(value: str) -> str:
    condition = value.strip().casefold().replace("-", "_")
    if condition not in WAIT_CONDITIONS:
        die(f"unknown wait condition '{value}' (known: {', '.join(WAIT_CONDITIONS)})")
    return condition


def wait_condition_met(condition: str, snap: dict) -> bool:
    if not isinstance(snap, dict) or not isinstance(snap.get("ts"), int) \
            or now_ms() - snap["ts"] > WAIT_SNAPSHOT_FRESH_MS:
        return False
    logged_in = snap.get("logged_in") is True
    if condition == "logged_in":
        return logged_in
    if condition == "logged_out":
        return snap.get("logged_in") is False
    if not logged_in:
        return False
    if condition == "walking":
        return snap.get("walking") is True
    if condition == "not_walking":
        return snap.get("walking") is False
    if condition == "in_combat":
        return snap.get("in_combat") is True
    if condition == "out_of_combat":
        return snap.get("in_combat") is False
    if condition == "talking_to_npc":
        return snap.get("talking_to_npc") is True
    if condition == "not_talking_to_npc":
        return snap.get("talking_to_npc") is False
    if condition == "right_click_menu_open":
        return snap.get("right_click_menu_open") is True
    if condition == "right_click_menu_closed":
        return snap.get("right_click_menu_open") is False
    if condition == "trade_open":
        return snap.get("trade_open") is True
    if condition == "trade_closed":
        return snap.get("trade_open") is False
    if condition == "sleeping":
        return snap.get("sleeping") is True
    if condition == "not_sleeping":
        return snap.get("sleeping") is False
    if condition == "fatigue_zero":
        return snap.get("fatigue") == 0
    return False


def wait_state_brief(snap: dict) -> str:
    if not isinstance(snap, dict):
        return "none"
    parts = []
    for key in ("logged_in", "walking", "in_combat", "talking_to_npc",
                "right_click_menu_open", "trade_open", "sleeping", "fatigue"):
        value = snap.get(key)
        if isinstance(value, bool):
            value = str(value).lower()
        parts.append(f"{key}:{value}")
    return ",".join(parts)


def cmd_wait_until(args):
    condition = normalise_wait_condition(args.condition)
    if not 0 < args.timeout <= WAIT_MAX_S:
        die(f"wait timeout must be greater than 0 and no more than {WAIT_MAX_S:g} seconds")
    deadline = time.monotonic() + args.timeout
    latest = None
    with SnapshotChangeWatch() as watch:
        baseline = game_reflex.read_snapshot()
        baseline_tick = baseline.get("tick") if isinstance(baseline, dict) else None
        baseline_ts = baseline.get("ts") if isinstance(baseline, dict) else None
        # Immediately after a dialogue click, the first replacement can still
        # describe the gap before the server's reply. A negative dialogue wait
        # that began in that gap must observe dialogue start before it is
        # allowed to observe dialogue end.
        dialogue_observed = (
            condition == "not_talking_to_npc"
            and isinstance(baseline, dict)
            and baseline.get("talking_to_npc") is True
        )
        # `wait until` is level-triggered: if the fresh current state already
        # holds, the transition may have completed while this process was
        # starting. The dialogue-end condition is the one deliberate edge:
        # false before an NPC reply is the dispatch gap, not proof of ending.
        if condition != "not_talking_to_npc" \
                and wait_condition_met(condition, baseline):
            report("condition-met", condition=condition,
                   tick=baseline.get("tick"), x=baseline.get("x"), z=baseline.get("z"))
            return
        if condition == "out_of_combat" and isinstance(baseline, dict) \
                and baseline.get("in_combat") is True \
                and retreat_lock_feedback(baseline):
            record_wait_failure(condition, "needs-retreat-action", baseline)
            report("condition-needs-action", condition=condition,
                   reason="retreat-locked", next="retreat")
            sys.exit(EXIT_NOT_DONE)
        while True:
            latest = game_reflex.read_snapshot()
            newer = isinstance(latest, dict) and (
                baseline is None
                or latest.get("tick") != baseline_tick
                or (isinstance(latest.get("ts"), int)
                    and isinstance(baseline_ts, int) and latest["ts"] > baseline_ts)
            )
            if newer and condition == "not_talking_to_npc" \
                    and isinstance(latest, dict) \
                    and latest.get("talking_to_npc") is True:
                dialogue_observed = True
            phase_ready = condition != "not_talking_to_npc" or dialogue_observed
            if newer and phase_ready and wait_condition_met(condition, latest):
                report("condition-met", condition=condition,
                       tick=latest.get("tick"), x=latest.get("x"), z=latest.get("z"))
                return
            if condition == "out_of_combat" and newer \
                    and isinstance(latest, dict) \
                    and latest.get("in_combat") is True \
                    and retreat_lock_feedback(latest):
                record_wait_failure(condition, "needs-retreat-action", latest)
                report("condition-needs-action", condition=condition,
                       reason="retreat-locked", next="retreat")
                sys.exit(EXIT_NOT_DONE)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                record_wait_failure(condition, "timeout", latest or {}, args.timeout)
                report("condition-timeout", condition=condition,
                       timeout=f"{args.timeout:g}", state=wait_state_brief(latest))
                sys.exit(EXIT_NOT_DONE)
            watch.wait(remaining)


def cmd_retreat(args):
    """One bounded intent, not a wait-for-the-impossible loop. The resident
    runner owns it when present; otherwise this process uses the identical
    rules-first step path until the server verifies combat has ended."""
    if not 0 < args.timeout <= 30:
        die("retreat timeout must be greater than 0 and no more than 30 seconds")
    if not 1 <= args.distance <= 10:
        die("retreat distance must be an integer 1..10")
    if args.dx not in (-1, 0, 1) or args.dz not in (-1, 0, 1) \
            or (args.dx == 0 and args.dz == 0):
        die("retreat dx/dz must be -1, 0, or 1 and not both zero")
    if (state_dir() / "hold").exists():
        report("retreat-held", reason="maintenance-hold")
        sys.exit(EXIT_HELD)
    snap = game_reflex.read_snapshot()
    if not isinstance(snap, dict) or snap.get("logged_in") is not True \
            or now_ms() - snap.get("ts", 0) > WAIT_SNAPSHOT_FRESH_MS:
        report("retreat-not-ready", state=wait_state_brief(snap))
        sys.exit(EXIT_NOT_READY)
    if snap.get("in_combat") is False:
        clear_retreat_request()
        report("retreated", status="already-safe", x=snap.get("x"), z=snap.get("z"))
        return

    expires = now_ms() + int(args.timeout * 1000)
    request = {"v": 1, "requested": now_ms(), "expires": expires,
               "distance": args.distance, "dx": args.dx, "dz": args.dz}
    game_reflex.atomic_write(retreat_request_path(), json.dumps(request) + "\n")
    cfg = load_config()
    wait_ms = config_defaults(cfg)["inflight_timeout_ms"]
    deadline = time.monotonic() + args.timeout
    latest = snap
    with SnapshotChangeWatch() as watch:
        while True:
            latest = game_reflex.read_snapshot() or latest
            if latest.get("logged_in") is not True:
                clear_retreat_request()
                report("retreat-unverified", reason="logged-out")
                sys.exit(EXIT_NOT_READY)
            if latest.get("in_combat") is False:
                clear_retreat_request()
                report("retreated", status="done", tick=latest.get("tick"),
                       x=latest.get("x"), z=latest.get("z"))
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                clear_retreat_request()
                record_wait_failure("out_of_combat", "retreat-timeout", latest,
                                    args.timeout)
                report("retreat-timeout", timeout=f"{args.timeout:g}",
                       feedback=latest_system_feedback(latest),
                       state=wait_state_brief(latest))
                sys.exit(EXIT_NOT_DONE)
            # A live runner sees retreat-request.json and gives it precedence
            # over chat and ordinary activity. Without one, use exactly the
            # same evaluation locally—never a second ad-hoc action loop.
            if read_live_runner() is None:
                step_once(cfg, read_objective(), read_activity(), wait_ms)
            else:
                watch.wait(min(remaining, 0.5))


def cmd_take(args):
    """Take one wanted visible item and keep routine play from cancelling the
    walk. Completion requires both the targeted ground entry to decrease and
    the matching inventory quantity to increase."""
    cfg = load_config()
    defaults = config_defaults(cfg)
    snap = game_reflex.read_snapshot()
    if not isinstance(snap, dict) or snap.get("logged_in") is not True \
            or now_ms() - snap.get("ts", 0) > WAIT_SNAPSHOT_FRESH_MS:
        report("take-not-ready", item=args.item, state=wait_state_brief(snap))
        sys.exit(EXIT_NOT_READY)
    if (state_dir() / "hold").exists():
        report("take-held", item=args.item, reason="maintenance-hold")
        sys.exit(EXIT_HELD)
    if snap.get("in_combat") is True:
        report("take-needs-retreat", item=args.item,
               reason="combat-blocks-pickup", next="retreat")
        sys.exit(EXIT_NOT_DONE)
    matches = [entry for entry in snap.get("ground_items") or []
               if isinstance(entry, dict) and entry.get("id") == args.item
               and isinstance(entry.get("x"), int) and isinstance(entry.get("z"), int)]
    if not matches:
        report("take-not-visible", item=args.item)
        sys.exit(EXIT_NOT_DONE)
    px, pz = snap.get("x"), snap.get("z")
    target = min(matches, key=lambda entry: max(
        abs(entry["x"] - px), abs(entry["z"] - pz)))
    action = {"type": "take-ground", "item": args.item,
              "x": target["x"], "z": target["z"]}
    before_inventory = inventory_quantity(snap, args.item)
    before_ground = ground_quantity_at(snap, args.item, target["x"], target["z"])
    progress = {"v": 1, "pid": os.getpid(), "started": now_ms(),
                "expires": now_ms() + int((TAKE_TIMEOUT_S + 5) * 1000),
                "item": args.item, "x": target["x"], "z": target["z"]}
    game_reflex.atomic_write(take_progress_path(), json.dumps(progress) + "\n")
    status = "no-receipt"
    final_x = final_z = None
    gained = 0
    action_id = None
    try:
        with player_state_lock():
            if (state_dir() / "action.json").exists():
                report("take-not-ready", item=args.item, reason="slot-busy")
                sys.exit(EXIT_NOT_READY)
            est = load_player_state()
            est["action_seq"] += 1
            action_id = est["action_seq"]
            sent_at = now_ms()
            est["inflight"] = {"id": action_id, "ts": sent_at}
            save_player_state(est)
            emit_player_action("action.json", action, action_id, sent_at)

        deadline = time.monotonic() + defaults["inflight_timeout_ms"] / 1000.0
        receipt_path = state_dir() / "receipt.json"
        with SnapshotChangeWatch() as watch:
            while time.monotonic() < deadline:
                try:
                    receipt = json.loads(receipt_path.read_text())
                except (OSError, json.JSONDecodeError):
                    receipt = None
                if receipt and receipt.get("id") == action_id:
                    status = receipt.get("status", "no-status")
                    try:
                        receipt_path.unlink()
                    except OSError:
                        pass
                    break
                watch.wait(max(0.01, min(0.25, deadline - time.monotonic())))
        if status == "done":
            status, final_x, final_z, gained = verify_take_ground(
                args.item, target["x"], target["z"],
                before_inventory, before_ground)
    finally:
        with player_state_lock():
            est = load_player_state()
            if action_id is not None and (est.get("inflight") or {}).get("id") == action_id:
                est["inflight"] = None
                save_player_state(est)
        try:
            take_progress_path().unlink()
        except FileNotFoundError:
            pass

    record = {"ts": now_ms(), "kind": "manual-take", "id": action_id,
              "action": action, "status": status, "gained": gained,
              "settled": {"x": final_x, "z": final_z}}
    append_outcome(record)
    flush_events([record])
    report("taken", id=action_id, item=args.item, status=status,
           x=final_x, z=final_z, gained=gained)
    if status != "done":
        sys.exit(EXIT_NOT_DONE)


# --------------------------------------------------------------------------
# The vocabulary plugged into game_reflex.evaluate (spec rules 4, 5, 8).
# A field the snapshot does not carry makes the condition false, never an
# exception — the same fail-safe rule the reflex triggers follow.
# --------------------------------------------------------------------------
def make_trigger_fn(objective: str, activity: str = ""):
    def trigger_true(trig, snap, food):
        if "objective_is" in trig:
            if not objective or objective != trig["objective_is"]:
                return False
        if "activity_is" in trig:
            if not activity or activity != trig["activity_is"]:
                return False
        if "npc_visible" in trig:
            if not any(n.get("id") == trig["npc_visible"]
                       for n in snap.get("npcs") or []):
                return False
        if "object_visible" in trig:
            if not any(o.get("id") == trig["object_visible"]
                       for o in snap.get("objects") or []):
                return False
        if "bound_visible" in trig:
            if not any(b.get("id") == trig["bound_visible"]
                       for b in snap.get("bounds") or []):
                return False
        if "ground_item_visible" in trig:
            if not any(i.get("id") == trig["ground_item_visible"]
                       for i in snap.get("ground_items") or []):
                return False
        if "shop_item_visible" in trig:
            if not any(i.get("id") == trig["shop_item_visible"]
                       for i in snap.get("shop_items") or []):
                return False
        if "bank_item_visible" in trig:
            if not any(i.get("id") == trig["bank_item_visible"]
                       for i in snap.get("bank_items") or []):
                return False
        if "message_contains" in trig:
            want = trig["message_contains"].lower()
            texts = [(m.get("text", "") if isinstance(m, dict) else str(m))
                     for m in snap.get("messages") or []]
            if not any(want in t.lower() for t in texts):
                return False
        if "near_tile" in trig:
            px, pz = snap.get("x"), snap.get("z")
            t = trig["near_tile"]
            if not isinstance(px, int) or not isinstance(pz, int):
                return False
            # Spec rule 4: the effective radius floor keeps vicinity triggers
            # from being mistaken for destination checks.
            radius = max(t["radius"], NEAR_RADIUS_FLOOR)
            if max(abs(px - t["x"]), abs(pz - t["z"])) > radius:
                return False
        inventory = snap.get("inventory") or []
        inv_ids = {i.get("id") for i in inventory}
        if "inventory_has" in trig and trig["inventory_has"] not in inv_ids:
            return False
        if "inventory_lacks" in trig and trig["inventory_lacks"] in inv_ids:
            return False
        if "inventory_slots_below" in trig \
                and len(inventory) >= trig["inventory_slots_below"]:
            return False
        if "inventory_slots_at_least" in trig \
                and len(inventory) < trig["inventory_slots_at_least"]:
            return False
        if "in_combat" in trig and snap.get("in_combat") is not True:
            return False
        if "out_of_combat" in trig and snap.get("in_combat") is not False:
            return False
        return True
    return trigger_true


def nearest_npc(snap: dict, wanted: int):
    """Choose by actual walking steps, independently of snapshot list order."""
    px, pz = snap.get("x"), snap.get("z")
    if not isinstance(px, int) or not isinstance(pz, int):
        return None
    candidates = [npc for npc in snap.get("npcs") or []
                  if npc.get("id") == wanted
                  and all(isinstance(npc.get(key), int)
                          for key in ("sidx", "x", "z"))]
    if not candidates:
        return None
    return min(candidates, key=lambda npc: (
        max(abs(npc["x"] - px), abs(npc["z"] - pz)),
        abs(npc["x"] - px) + abs(npc["z"] - pz), npc["sidx"]))


def compiled_npc_action(action_type: str, npc: dict, wanted: int, **extra):
    return {"type": action_type, "sidx": npc["sidx"], "npc": wanted,
            "target_x": npc["x"], "target_z": npc["z"], **extra}


def compile_player_action(rule, snap, food, eat_pick):
    action = rule["action"]
    if action["type"] == "talk-npc":
        want = action["npc"]
        npc = nearest_npc(snap, want)
        if npc is not None:
            return compiled_npc_action("talk-npc", npc, want), None
        return None, "npc-not-visible"
    if action["type"] == "interact-npc":
        want = action["npc"]
        within = action.get("within")
        px, pz = snap.get("x"), snap.get("z")
        npc = nearest_npc(snap, want)
        if npc is not None:
            distance = max(abs(px - npc["x"]), abs(pz - npc["z"]))
            if within is not None and distance > within:
                return None, "npc-not-within-range"
            extra = {"cmd": action.get("cmd", 1), "target_distance": distance}
            if within is not None:
                extra["within"] = within
            return compiled_npc_action("interact-npc", npc, want, **extra), None
        return None, "npc-not-within-range" if within is not None else "npc-not-visible"
    if action["type"] == "walk":
        return {"type": "walk", "x": action["x"], "z": action["z"]}, None
    if action["type"] == "retreat":
        if snap.get("in_combat") is not True:
            return None, "already-out-of-combat"
        return {"type": "retreat", "distance": action.get("distance", 5),
                "dx": action.get("dx", 0), "dz": action.get("dz", 1)}, None
    if action["type"] == "interact-object":
        want = action["obj"]
        for obj in snap.get("objects") or []:    # already nearest-first (rule 3 there)
            if obj.get("id") == want and isinstance(obj.get("x"), int) \
                    and isinstance(obj.get("z"), int):
                return {"type": "interact-object", "x": obj["x"], "z": obj["z"],
                        "obj": want, "cmd": action.get("cmd", 1)}, None
        return None, "object-not-loaded"
    if action["type"] == "interact-bound":
        want = action["obj"]
        for bnd in snap.get("bounds") or []:     # already nearest-first
            if bnd.get("id") == want and isinstance(bnd.get("x"), int) \
                    and isinstance(bnd.get("z"), int):
                return {"type": "interact-bound", "x": bnd["x"], "z": bnd["z"],
                        "dir": bnd.get("dir", 0), "obj": want,
                        "cmd": action.get("cmd", 1)}, None
        return None, "bound-not-loaded"
    if action["type"] == "click-entity":
        kind = action["kind"]
        want = action["entity"]
        button = action.get("button", 1)
        if kind == "npc":
            npc = nearest_npc(snap, want)
            if npc is not None:
                return compiled_npc_action("click-entity", npc, want,
                                           kind="npc", button=button), None
            return None, "npc-not-visible"
        source = snap.get("objects" if kind == "object" else "bounds") or []
        for entity in source:
            if entity.get("id") == want and isinstance(entity.get("x"), int) \
                    and isinstance(entity.get("z"), int):
                compiled = {"type": "click-entity", "kind": kind,
                            "x": entity["x"], "z": entity["z"],
                            "obj": want, "button": button}
                if kind == "bound":
                    compiled["dir"] = entity.get("dir", 0)
                return compiled, None
        return None, f"{kind}-not-loaded"
    if action["type"] == "click-inventory":
        want = action["item"]
        if any(entry.get("id") == want for entry in snap.get("inventory") or []):
            return {"type": "click-inventory", "item": want,
                    "button": action.get("button", 1)}, None
        return None, "item-not-held"
    if action["type"] in ("click-shop", "click-bank"):
        interface = action["type"].split("-", 1)[1]
        want = action["item"]
        if not snap.get(f"{interface}_open"):
            return None, f"{interface}-closed"
        visible = any(entry.get("id") == want
                      for entry in snap.get(f"{interface}_items") or [])
        if action["type"] == "click-bank":
            # The bank's selectable grid includes inventory items available
            # for deposit even when no bank stack exists yet.
            visible = visible or any(entry.get("id") == want
                                     for entry in snap.get("inventory") or [])
        if visible:
            return {"type": action["type"], "item": want,
                    "button": action.get("button", 1)}, None
        return None, f"item-not-in-{interface}"
    if action["type"] == "take-ground":
        want = action["item"]
        within = action.get("within")
        px, pz = snap.get("x"), snap.get("z")
        for item in snap.get("ground_items") or []:  # already nearest-first
            if item.get("id") == want and isinstance(item.get("x"), int) \
                    and isinstance(item.get("z"), int):
                if within is not None and (
                        not isinstance(px, int) or not isinstance(pz, int)
                        or max(abs(px - item["x"]), abs(pz - item["z"])) > within):
                    continue
                return {"type": "take-ground", "x": item["x"], "z": item["z"],
                        "item": want}, None
        return None, "ground-item-not-within-range" if within is not None \
            else "ground-item-not-visible"
    return None, f"unknown-action-{action['type']}"


def emit_player_action(path_name: str, action: dict, action_id: int, ts: int) -> None:
    lines = [f"ts={ts}", f"id={action_id}", f"type={action['type']}"]
    for key in ("kind", "sidx", "npc", "x", "z", "dir", "obj", "cmd", "within",
                "item", "button",
                "distance", "dx", "dz",
                "target", "text"):
        if key in action:
            lines.append(f"{key}={action[key]}")
    game_reflex.atomic_write(state_dir() / path_name, "\n".join(lines) + "\n")


# --------------------------------------------------------------------------
# The outcome queue (spec rule 16): the background author's inbox. Play
# appends and keeps moving; nothing here ever blocks an action.
# --------------------------------------------------------------------------
def snap_brief(snap: dict) -> dict:
    brief = {k: snap.get(k) for k in ("tick", "x", "z", "hits", "hits_max",
                                      "fatigue", "sleeping", "sleep_fatigue", "sleep_status",
                                      "walking", "in_combat", "talking_to_npc",
                                      "right_click_menu_open")}
    brief["inventory"] = [i.get("id") for i in snap.get("inventory") or []]
    brief["messages"] = (snap.get("messages") or [])[-5:]
    brief["players"] = (snap.get("players") or [])[:24]
    brief["npcs"] = (snap.get("npcs") or [])[:12]
    brief["objects"] = (snap.get("objects") or [])[:12]
    brief["bounds"] = (snap.get("bounds") or [])[:12]
    brief["ground_items"] = (snap.get("ground_items") or [])[:12]
    brief["shop_open"] = bool(snap.get("shop_open"))
    brief["shop_items"] = (snap.get("shop_items") or [])[:40]
    brief["bank_open"] = bool(snap.get("bank_open"))
    brief["bank_items"] = snap.get("bank_items") or []
    return brief


def gap_signature(snap: dict, objective: str, activity: str = "") -> str:
    """Stable author input: game ticks and wandering NPC tiles are not new gaps."""
    game_messages = [
        {"channel": m.get("channel"), "sender": m.get("sender"), "text": m.get("text")}
        for m in (snap.get("messages") or [])[-5:]
        if isinstance(m, dict) and m.get("channel") not in ("local", "private")
    ]
    shape = {
        "objective": objective or None,
        "activity": activity or None,
        "x": snap.get("x"),
        "z": snap.get("z"),
        "inventory": [i.get("id") for i in snap.get("inventory") or []],
        "messages": game_messages,
        "npcs": sorted(n.get("id") for n in snap.get("npcs") or []
                       if isinstance(n, dict) and isinstance(n.get("id"), int)),
        "objects": sorted((o.get("id"), o.get("x"), o.get("z"))
                          for o in snap.get("objects") or []
                          if isinstance(o, dict) and isinstance(o.get("id"), int)),
        "bounds": sorted((b.get("id"), b.get("x"), b.get("z"), b.get("dir"))
                         for b in snap.get("bounds") or []
                         if isinstance(b, dict) and isinstance(b.get("id"), int)),
        "ground_items": sorted((i.get("id"), i.get("x"), i.get("z"))
                               for i in snap.get("ground_items") or []
                               if isinstance(i, dict) and isinstance(i.get("id"), int)),
    }
    return json.dumps(shape, sort_keys=True, separators=(",", ":"))


def append_outcome(record: dict) -> None:
    path = queue_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as fh:
        fh.write(json.dumps(record, separators=(",", ":")) + "\n")


def repetition_candidate(est: dict, rule: dict | None, outcome: dict) -> dict | None:
    """Aggregate exact repeated plays for the event-driven Sol author.

    One outcome at a time is normally enough to author a rule, but it cannot
    reveal a time-spanning loop to an ephemeral author turn. Keep a compact
    three-minute history and emit one self-contained candidate after the same
    rule targets the same thing three times in the same objective/activity.
    This is diagnostic, not a blanket loot cap: the author must distinguish a
    productive routine or valuable finite drops from a fixed-spawn diversion.
    """
    action = outcome.get("action") or {}
    if rule is None or action.get("type") == "retreat" \
            or outcome.get("rule") in (ROUTE_RULE_NAME, MANUAL_RETREAT_RULE_NAME):
        return None
    now = int(outcome.get("ts") or now_ms())
    identity = {key: action.get(key) for key in (
        "type", "npc", "obj", "item", "x", "z", "dir", "cmd", "button")
        if key in action}
    key = json.dumps({"rule": outcome.get("rule"),
                      "objective": outcome.get("objective"),
                      "activity": outcome.get("activity"),
                      "action": identity}, sort_keys=True, separators=(",", ":"))
    recent = [item for item in est.get("recent_repetitions") or []
              if isinstance(item, dict) and isinstance(item.get("ts"), int)
              and now - item["ts"] <= REPETITION_WINDOW_MS]
    snap = outcome.get("snap") or {}
    recent.append({"ts": now, "key": key, "status": outcome.get("status"),
                   "x": snap.get("x"), "z": snap.get("z"),
                   "inventory": snap.get("inventory") or []})
    est["recent_repetitions"] = recent[-48:]
    reported = {k: v for k, v in (est.get("reported_repetitions") or {}).items()
                if isinstance(v, int) and now - v <= REPETITION_WINDOW_MS}
    est["reported_repetitions"] = reported
    matches = [item for item in recent if item.get("key") == key]
    if len(matches) < REPETITION_THRESHOLD or key in reported:
        return None
    reported[key] = now
    return {"ts": now, "kind": "loop-candidate", "rule": outcome.get("rule"),
            "objective": outcome.get("objective"), "activity": outcome.get("activity"),
            "action": identity, "count": len(matches),
            "span_ms": now - matches[0]["ts"],
            "activity_scoped": "activity_is" in (rule.get("trigger") or {}),
            "recent": [{k: v for k, v in item.items() if k != "key"}
                       for item in matches[-REPETITION_THRESHOLD:]],
            "note": "Exact repetition needs review: preserve productive routines and valuable "
                    "finite loot; prevent fixed low-value respawns or stale interactions from "
                    "starving the current commitment."}


# --------------------------------------------------------------------------
# Walk verification (spec rule 7a): the receipt is dispatch, not completion.
# Follow the snapshot until the body stops moving, then judge against the
# TARGET's coordinates — never the receipt alone.
# --------------------------------------------------------------------------
def verify_walk(tx: int, tz: int, arrive: int,
                timeout_s: float = WALK_TIMEOUT_S,
                settle_s: float = WALK_SETTLE_S,
                poll_s: float = 0.2):
    """Returns (status, final_x, final_z): status 'done', 'walk-short' or
    'walk-unverified' (snapshot lost or logged out mid-walk)."""
    deadline = time.time() + timeout_s
    last_pos, last_move = None, time.time()
    while time.time() < deadline:
        snap = game_reflex.read_snapshot()
        if snap is None or not snap.get("logged_in"):
            return "walk-unverified", None, None
        px, pz = snap.get("x"), snap.get("z")
        if not isinstance(px, int) or not isinstance(pz, int):
            return "walk-unverified", None, None
        if max(abs(px - tx), abs(pz - tz)) <= arrive:
            return "done", px, pz
        if (px, pz) != last_pos:
            last_pos, last_move = (px, pz), time.time()
        elif time.time() - last_move >= settle_s:
            return "walk-short", px, pz
        time.sleep(poll_s)
    return "walk-short", (last_pos or (None, None))[0], (last_pos or (None, None))[1]


def inventory_quantity(snap: dict, item_id: int) -> int:
    return sum(
        entry.get("count", entry.get("amount", 1))
        for entry in snap.get("inventory") or []
        if isinstance(entry, dict) and entry.get("id") == item_id
        and isinstance(entry.get("count", entry.get("amount", 1)), int)
    )


def ground_quantity_at(snap: dict, item_id: int, x: int, z: int) -> int:
    return sum(
        1 for entry in snap.get("ground_items") or []
        if isinstance(entry, dict) and entry.get("id") == item_id
        and entry.get("x") == x and entry.get("z") == z
    )


def verify_take_ground(item_id: int, x: int, z: int,
                       before_inventory: int, before_ground: int,
                       timeout_s: float = TAKE_TIMEOUT_S):
    """Keep the action slot conceptually occupied until the wanted pickup is
    grounded. A pile disappearing is not collection: inventory must also grow.
    While this function observes the walk-and-take, the runner cannot issue a
    routine interaction that cancels the path halfway to the drop."""
    deadline = time.monotonic() + timeout_s
    latest = game_reflex.read_snapshot() or {}
    last_pos = (latest.get("x"), latest.get("z"))
    last_progress = time.monotonic()
    missing_since = None
    with SnapshotChangeWatch() as watch:
        while True:
            latest = game_reflex.read_snapshot() or latest
            if latest.get("logged_in") is not True:
                return "take-unverified", latest.get("x"), latest.get("z"), 0
            now = time.monotonic()
            current_inventory = inventory_quantity(latest, item_id)
            current_ground = ground_quantity_at(latest, item_id, x, z)
            gained = current_inventory - before_inventory
            removed = current_ground < before_ground
            if gained > 0 and removed:
                return "done", latest.get("x"), latest.get("z"), gained
            if removed:
                missing_since = missing_since or now
                if now - missing_since >= TAKE_MISSING_GRACE_S:
                    return "take-missed", latest.get("x"), latest.get("z"), max(0, gained)
            else:
                missing_since = None

            pos = (latest.get("x"), latest.get("z"))
            if pos != last_pos or latest.get("walking") is True:
                last_pos, last_progress = pos, now
            elif now - last_progress >= WALK_SETTLE_S:
                return "take-short", latest.get("x"), latest.get("z"), max(0, gained)

            remaining = deadline - now
            if remaining <= 0:
                return "take-short", latest.get("x"), latest.get("z"), max(0, gained)
            wake_in = min(remaining, 0.5)
            if missing_since is not None:
                wake_in = min(wake_in, TAKE_MISSING_GRACE_S - (now - missing_since))
            watch.wait(max(0.01, wake_in))


def verify_retreat(timeout_s: float = RETREAT_VERIFY_S):
    """Verify the effect the player actually wants: combat ended. A bridge
    receipt proves only that a reachable escape walk was sent; the server may
    still reject it during the first three opposing hits."""
    deadline = time.monotonic() + timeout_s
    latest = game_reflex.read_snapshot() or {}
    with SnapshotChangeWatch() as watch:
        while True:
            latest = game_reflex.read_snapshot() or latest
            if latest.get("logged_in") is not True:
                return "retreat-unverified", latest.get("x"), latest.get("z")
            if latest.get("in_combat") is False:
                return "done", latest.get("x"), latest.get("z")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                status = "retreat-locked" if retreat_lock_feedback(latest) \
                    else "retreat-unconfirmed"
                return status, latest.get("x"), latest.get("z")
            watch.wait(remaining)


# --------------------------------------------------------------------------
# The resident runner's heartbeat (spec rule 15): pid, ts, latest verdict.
# A fresh heartbeat makes the runner the only evaluator; `step` defers.
# --------------------------------------------------------------------------
def write_heartbeat(verdict: str, detail: str = "", ground_items=None,
                    activity: str = "", activity_xp: str = "") -> None:
    game_reflex.atomic_write(runner_path(), json.dumps(
        {"pid": os.getpid(), "ts": now_ms(),
         "verdict": verdict, "detail": detail,
         "ground_items": ground_items or [],
         "activity": activity or None,
         "activity_xp": activity_xp or None}) + "\n")


def read_live_runner():
    """The heartbeat, iff fresh and its pid is alive; else None."""
    try:
        hb = json.loads(runner_path().read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if now_ms() - hb.get("ts", 0) > RUNNER_FRESH_MS:
        return None
    pid = hb.get("pid")
    if not isinstance(pid, int) or pid == os.getpid():
        return None
    try:
        os.kill(pid, 0)
    except (OSError, ProcessLookupError):
        return None
    return hb


# --------------------------------------------------------------------------
# step (spec rule 7): one rules-first evaluation and one report line.
# --------------------------------------------------------------------------
QUIET_REPEATS = False       # the resident runner's log discipline: repeated
_last_verdict = None        # idle verdicts collapse; firings always print


def report(verdict, **fields):
    global _last_verdict
    if QUIET_REPEATS and verdict == _last_verdict and verdict != "fired":
        return
    _last_verdict = verdict
    parts = [verdict]
    for key, val in fields.items():
        if val is not None:
            parts.append(f"{key}={val}")
    print(" ".join(parts), flush=True)


def once_key(rule_name: str, objective: str) -> str:
    return f"{rule_name}\t{objective}"


def step_once(cfg: dict, objective: str, activity: str, wait_ms: int):
    """One evaluation. Returns (verdict, exit_code)."""
    defaults = config_defaults(cfg)
    est = load_player_state()
    est["_inflight_timeout_ms"] = defaults["inflight_timeout_ms"]
    events = []
    now = now_ms()

    if (state_dir() / "hold").exists():
        if not est["was_held"]:
            events.append({"ts": now, "kind": "hold"})
            est["was_held"] = True
            save_player_state(est)
            flush_events(events)
        report("held")
        return "held", EXIT_HELD

    snap = game_reflex.read_snapshot()
    if snap is None:
        report("no-snapshot", dir=str(state_dir()))
        return "no-snapshot", EXIT_NOT_READY
    xp_text = activity_xp_text(snap, activity)
    # The sleep screen owns keyboard input and blocks ordinary play. Never let
    # an old objective, route, reflex, or queued reply pretend it can proceed
    # until the current word has been solved and live state says awake.
    if snap.get("logged_in") is True and snap.get("sleeping") is True:
        report("sleeping-needs-wake", fatigue=snap.get("fatigue"),
               sleep_fatigue=snap.get("sleep_fatigue"),
               status=snap.get("sleep_status") or None,
               next="solve-current-word-then-wait-until-not_sleeping")
        return "sleeping-needs-wake", EXIT_NO_RULE
    source_rules = list(cfg["rules"])
    retreat_request = load_retreat_request()
    if retreat_request is not None and snap.get("in_combat") is False:
        clear_retreat_request()
        retreat_request = None
    if retreat_request is not None:
        source_rules.append({
            "name": MANUAL_RETREAT_RULE_NAME, "enabled": True,
            "priority": MANUAL_RETREAT_PRIORITY, "cooldown_ms": 0,
            "hold_ticks": 1, "once_per_objective": False,
            "note": "one bounded explicit retreat request",
            "trigger": {"in_combat": True},
            "action": {"type": "retreat",
                       "distance": retreat_request["distance"],
                       "dx": retreat_request["dx"], "dz": retreat_request["dz"]},
        })
    trigger_true = make_trigger_fn(objective, activity)
    urgent_retreat_names = {
        rule["name"] for rule in source_rules
        if rule.get("enabled")
        and (rule.get("action") or {}).get("type") == "retreat"
        and snap.get("in_combat") is True
        and trigger_true(rule.get("trigger") or {}, snap, {})
    }

    # Spec rules 7b-7c: capture urgent messages before ordinary play.
    # The small lock prevents the resident runner from racing a Sol reply.
    message_events = []
    with player_state_lock():
        est = load_player_state()
        est["_inflight_timeout_ms"] = defaults["inflight_timeout_ms"]
        capture_player_messages(snap, est, message_events)
        capture_urgent_system_messages(snap, est, message_events)
        pending_system_message = oldest_pending_system_message(est)
        pending_batch = pending_message_batch(est)
        pending_message = pending_batch[-1] if pending_batch else None
        settle_until = est.get("message_settle_until", 0)
        save_player_state(est)
        flush_events(message_events)
    if not urgent_retreat_names and pending_system_message is not None and snap.get("logged_in") \
            and now - snap.get("ts", 0) <= defaults["stale_ms"]:
        report("system-message", id=pending_system_message["id"],
               channel=pending_system_message["channel"],
               action="move-required", text=pending_system_message["text"])
        return "system-message", EXIT_SYSTEM_MESSAGE
    if not urgent_retreat_names and pending_message is not None and snap.get("logged_in") \
            and now - snap.get("ts", 0) <= defaults["stale_ms"]:
        if now < settle_until:
            report("player-message-settling", count=len(pending_batch),
                   remaining_ms=settle_until - now)
            return "player-message-settling", EXIT_NOT_READY
        report("player-message", id=pending_message["id"],
               channel=pending_message["channel"], sender=pending_message["sender"],
               count=len(pending_batch), burst=pending_message_burst(pending_batch))
        return "player-message", EXIT_PLAYER_MESSAGE

    # Spec rule 21a: past the limit, ordinary evaluation stops — no learned
    # rule, no route leg, on either hand. It sits BELOW rules 7b-7c above: a
    # person who spoke still gets an answer, and the idle warning still gets
    # moved for, because being logged out mid-routine helps nothing. Her own
    # bridge doors stay open; what stops here is the table, not her hands.
    sess = session_state(now)
    if sess["phase"] in ("over", "expired", "ended"):
        report("session-over", phase=sess["phase"], elapsed_ms=sess["elapsed_ms"],
               limit_ms=sess["limit_ms"], grace_ms_left=sess["grace_ms_left"])
        return "session-over", EXIT_SESSION_OVER

    if (state_dir() / "action.json").exists():
        report("slot-busy")
        return "slot-busy", EXIT_NOT_READY

    take_progress = foreign_take_in_progress()
    if take_progress is not None:
        report("take-in-progress", item=take_progress.get("item"),
               x=take_progress.get("x"), z=take_progress.get("z"))
        return "take-in-progress", EXIT_NOT_READY

    if snap.get("logged_in") and snap.get("tick", -1) == est["last_tick"]:
        report("same-tick", tick=snap.get("tick"))
        return "same-tick", EXIT_NOT_READY

    # A direct hand may have committed to an NPC outside this resident
    # runner. Ordinary learned rules must not cancel that approach or abandon
    # a live conversation for incidental work (notably respawning loot).
    # An applicable retreat remains the one exception: survival can interrupt
    # either state, and the still-open commitment is reconsidered once safe.
    if not urgent_retreat_names and snap.get("logged_in") \
            and snap.get("walking") is True:
        report("movement-in-progress", x=snap.get("x"), z=snap.get("z"),
               next="wait-until-not_walking")
        return "movement-in-progress", EXIT_NOT_READY
    if not urgent_retreat_names and snap.get("logged_in") \
            and snap.get("talking_to_npc") is True:
        choices = snap.get("dialogue_options") or []
        if snap.get("dialogue_open") is True and choices:
            report("npc-dialogue-choice",
                   choices=json.dumps(choices, separators=(",", ":")),
                   next="choose-dialogue-by-text")
            return "npc-dialogue-choice", EXIT_NO_RULE
        report("npc-dialogue-in-progress", next="wait-for-next-dialogue-state")
        return "npc-dialogue-in-progress", EXIT_NOT_READY

    # Spec rule 7e: one durable destination, executed by this resident runner
    # as ordinary lowest-priority walk actions. Messages above and every
    # learned interaction below retain priority.
    route = load_route()
    route_blocked = False
    if route is not None and route.get("status") == "invalid":
        report("route-invalid", file=str(route_path()))
        return "route-blocked", EXIT_NO_RULE
    if route is not None and route["objective"] != objective:
        clear_route()
        flush_events([{"ts": now_ms(), "kind": "route-cancelled",
                       "reason": "objective-changed", "from": route["objective"],
                       "to": objective}])
        route = None
    if route is not None:
        px, pz = snap.get("x"), snap.get("z")
        if isinstance(px, int) and isinstance(pz, int) \
                and route_distance(px, pz, route) <= route["arrive"]:
            clear_route()
            flush_events([{"ts": now_ms(), "kind": "route-complete",
                           "x": px, "z": pz, "target_x": route["x"],
                           "target_z": route["z"]}])
            route = None
        elif route.get("status") == "blocked":
            signature = route_obstacle_signature(snap)
            if signature == route.get("blocked_signature"):
                route_blocked = True
            else:
                route = {k: v for k, v in route.items()
                         if not k.startswith("blocked_")}
                route["status"] = "active"
                save_route(route)

    # Rules spent for this objective (spec rule 9) step aside BEFORE the
    # engine sees the table, so the machinery stays vocabulary-blind.
    live_rules = []
    for rule in source_rules:
        if urgent_retreat_names and rule["name"] not in urgent_retreat_names:
            continue
        if rule.get("once_per_objective") and rule["enabled"] \
                and once_key(rule["name"], objective) in est["objective_fired"]:
            continue
        # Every player rule is game-channel by construction (spec rule 5);
        # the shared engine wants the key spelled out.
        live_rules.append(dict(rule, channel="game"))
    if route is not None and not route_blocked and not urgent_retreat_names:
        live_rules.append({"name": ROUTE_RULE_NAME, "enabled": True,
                           "priority": ROUTE_PRIORITY, "cooldown_ms": 0,
                           "hold_ticks": 1, "channel": "game", "trigger": {},
                           "action": {"type": "walk", "x": route["x"],
                                      "z": route["z"], "arrive": route["arrive"]}})
    eval_cfg = {"v": cfg.get("v", 1),
                "defaults": {k: v for k, v in defaults.items()},
                "rules": live_rules}

    # An old receipt for our own in-flight action is consumed first, exactly
    # like the reflex loop does.
    game_reflex.consume_receipt(est, now, sink=events)

    game_reflex.evaluate(
        eval_cfg, {}, snap, est, now,
        emit=emit_player_action, sink=events,
        trigger_fn=trigger_true,
        compile_fn=compile_player_action, live=True)

    fired = [e for e in events if e.get("kind") == "fired"]
    cooldown_holds = sum(1 for e in events if e.get("kind") == "cooldown-hold")
    save_player_state(est)
    flush_events(events)

    if not fired:
        if not snap.get("logged_in"):
            report("logged-out")
            return "logged-out", EXIT_NOT_READY
        if now - snap.get("ts", 0) > config_defaults(cfg)["stale_ms"]:
            report("stale", age_ms=now - snap.get("ts", 0))
            return "stale", EXIT_NOT_READY
        if route_blocked and route is not None:
            report("route-blocked", x=snap.get("x"), z=snap.get("z"),
                   target_x=route["x"], target_z=route["z"],
                   reason=route.get("blocked_reason", "no-progress"),
                   feedback=latest_system_feedback(snap))
            return "route-blocked", EXIT_NO_RULE
        if route is not None:
            report("route-waiting", x=snap.get("x"), z=snap.get("z"),
                   target_x=route["x"], target_z=route["z"])
            return "route-waiting", EXIT_NOT_READY
        report("no-rule-matched", objective=objective or None,
               activity=activity or None,
               activity_xp=xp_text or None,
               rules_enabled=sum(1 for r in cfg["rules"] if r["enabled"]),
               cooldown_holds=cooldown_holds,
               ground_items=",".join(str(i.get("id"))
                                     for i in snap.get("ground_items") or []) or None,
               feedback=latest_system_feedback(snap))
        return "no-rule-matched", EXIT_NO_RULE

    event = fired[0]
    rule_name = event["rule"]
    action_id = event["id"]

    # Await the bridge's receipt for our id (spec rule 7).
    status = "no-receipt"
    deadline = time.time() + wait_ms / 1000.0
    receipt_path = state_dir() / "receipt.json"
    while time.time() < deadline:
        try:
            receipt = json.loads(receipt_path.read_text())
        except (OSError, json.JSONDecodeError):
            receipt = None
        if receipt and receipt.get("id") == action_id:
            status = receipt.get("status", "no-status")
            est = load_player_state()
            est["inflight"] = None
            save_player_state(est)
            flush_events([{"ts": now_ms(), "kind": "receipt", "id": action_id,
                           "status": status}])
            try:
                receipt_path.unlink()
            except OSError:
                pass
            break
        time.sleep(0.05)

    rule = next((r for r in live_rules if r["name"] == rule_name), None)

    # Spec rule 7a: a walk's `done` receipt is dispatch, not arrival. Verify
    # against the target's coordinates before anything treats it as complete.
    action = event["action"]
    final_x = final_z = None
    gained = 0
    is_retreat = rule is not None and rule["action"].get("type") == "retreat"
    if status == "done" and is_retreat:
        status, final_x, final_z = verify_retreat()
        if status != "done":
            flush_events([{"ts": now_ms(), "kind": status, "rule": rule_name,
                           "id": action_id, "x": final_x, "z": final_z,
                           "feedback": latest_system_feedback(
                               game_reflex.read_snapshot() or snap)}])
    elif status == "done" and action["type"] == "walk":
        arrive = WALK_ARRIVE_DEFAULT
        if rule is not None and isinstance(rule["action"].get("arrive"), int):
            arrive = rule["action"]["arrive"]
        status, final_x, final_z = verify_walk(action["x"], action["z"], arrive)
        if status != "done":
            flush_events([{"ts": now_ms(), "kind": status, "rule": rule_name,
                           "id": action_id, "intended": {"x": action["x"], "z": action["z"]},
                           "settled": {"x": final_x, "z": final_z}}])
    elif status == "done" and action["type"] == "take-ground":
        before_inventory = inventory_quantity(snap, action["item"])
        before_ground = ground_quantity_at(
            snap, action["item"], action["x"], action["z"])
        status, final_x, final_z, gained = verify_take_ground(
            action["item"], action["x"], action["z"],
            before_inventory, before_ground)
        if status != "done":
            flush_events([{"ts": now_ms(), "kind": status, "rule": rule_name,
                           "id": action_id, "item": action["item"],
                           "x": final_x, "z": final_z, "gained": gained}])

    is_route = rule_name == ROUTE_RULE_NAME and route is not None
    route_was_blocked = False
    if is_route:
        latest = game_reflex.read_snapshot() or snap
        lx, lz = latest.get("x"), latest.get("z")
        start_distance = route_distance(snap["x"], snap["z"], route)
        if status == "done":
            clear_route()
            status = "route-complete"
            flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                           "x": lx, "z": lz, "target_x": route["x"],
                           "target_z": route["z"]}])
        elif status == "walk-short" and isinstance(lx, int) and isinstance(lz, int) \
                and route_distance(lx, lz, route) < start_distance:
            status = "route-progress"
            flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                           "x": lx, "z": lz, "target_x": route["x"],
                           "target_z": route["z"]}])
        else:
            route_was_blocked = True
            block_route(route, latest, status)
            flush_events([{"ts": now_ms(), "kind": "route-blocked", "id": action_id,
                           "reason": status, "x": lx, "z": lz,
                           "target_x": route["x"], "target_z": route["z"]}])
            status = "route-blocked"

    # The once-per-objective mark is spent only on a VERIFIED done (rule 7a).
    if rule is not None and rule.get("once_per_objective") and status == "done":
        est = load_player_state()
        est["objective_fired"][once_key(rule_name, objective)] = now
        save_player_state(est)

    # Every outcome feeds the background author (spec rule 16).
    outcome = {"ts": now_ms(), "kind": "outcome", "rule": rule_name,
               "id": action_id, "action": action, "status": status,
               "objective": objective or None, "activity": activity or None,
               "snap": snap_brief(snap)}
    if action["type"] == "walk":
        outcome["intended"] = {"x": action["x"], "z": action["z"]}
        if final_x is not None:
            outcome["settled"] = {"x": final_x, "z": final_z}
    elif action["type"] == "take-ground":
        outcome["target"] = {"item": action["item"], "x": action["x"], "z": action["z"]}
        outcome["settled"] = {"x": final_x, "z": final_z}
        outcome["gained"] = gained
    append_outcome(outcome)
    est = load_player_state()
    candidate = repetition_candidate(est, rule, outcome)
    save_player_state(est)
    if candidate is not None:
        append_outcome(candidate)
        flush_events([candidate])

    if action["type"] in ("walk", "take-ground") and final_x is not None:
        if route_was_blocked:
            report("route-blocked", id=action_id, x=final_x, z=final_z,
                   target_x=action["x"], target_z=action["z"])
        else:
            report("fired", rule=rule_name, id=action_id, type=action["type"],
                   status=status, x=final_x, z=final_z, objective=objective or None,
                   activity=activity or None, activity_xp=xp_text or None)
    else:
        if route_was_blocked:
            report("route-blocked", id=action_id, target_x=action["x"],
                   target_z=action["z"], reason=status)
        else:
            report("fired", rule=rule_name, id=action_id, type=action["type"],
                   status=status, objective=objective or None,
                   activity=activity or None, activity_xp=xp_text or None)
    if route_was_blocked:
        return "route-blocked", EXIT_NO_RULE
    return "fired", (EXIT_FIRED if status in ("done", "route-progress", "route-complete")
                     else EXIT_NOT_DONE)


# --------------------------------------------------------------------------
# The test suite and the gate (spec rule 17): rules are deterministic
# trigger-to-action data, so they are tested like data. `predict` is the pure
# selection — triggers and compilation in priority order, no cooldowns, no
# marks, no pacing — and every table-mutating door runs the whole suite
# against the WOULD-BE table before writing a byte.
# --------------------------------------------------------------------------
EMPTY_TESTS = {"v": 1, "cases": []}


def load_tests() -> dict:
    path = tests_path()
    if not path.exists():
        return dict(EMPTY_TESTS, cases=[])
    try:
        tests = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        die(f"test cases {path} are not valid JSON: {e}")
    if not isinstance(tests, dict) or not isinstance(tests.get("cases"), list):
        die(f"test cases {path} must be an object with a 'cases' list")
    for case in tests["cases"]:
        if not isinstance(case, dict) or not case.get("name") \
                or not isinstance(case.get("snapshot"), dict):
            die(f"test cases {path}: every case needs a name and a snapshot object")
    return tests


def save_tests(tests: dict) -> None:
    game_reflex.atomic_write(tests_path(), json.dumps(tests, indent=2) + "\n")


def predict(cfg: dict, snap: dict, objective: str, activity: str = ""):
    """The rule that would win the slot for this snapshot: the highest
    priority whose trigger holds AND whose action compiles. Pure."""
    trigger_fn = make_trigger_fn(objective, activity)
    rules = sorted((r for r in cfg["rules"] if r["enabled"]),
                   key=lambda r: -r["priority"])
    for rule in rules:
        if not trigger_fn(rule["trigger"], snap, {}):
            continue
        action, _why = compile_player_action(rule, snap, {}, "min")
        if action is not None:
            return rule["name"], action
    return None, None


def lint_table(cfg: dict) -> list:
    problems = []
    for rule in cfg["rules"]:
        tile = rule["trigger"].get("near_tile")
        if tile and tile["radius"] < NEAR_RADIUS_FLOOR:
            problems.append(
                f"lint: rule '{rule['name']}' near_tile radius {tile['radius']} "
                f"is below the floor {NEAR_RADIUS_FLOOR} — scope the vicinity "
                "honestly; verification owns the destination")
    return problems


def run_suite(cfg: dict):
    """(failures, case-count) for lint plus every replay case."""
    failures = lint_table(cfg)
    tests = load_tests()
    for case in tests["cases"]:
        want = case.get("expect")
        if want in (None, "", "none"):
            want = None
        got, _action = predict(cfg, case["snapshot"], case.get("objective") or "",
                               case.get("activity") or "")
        if got != want:
            failures.append(f"case '{case['name']}': expected "
                            f"{want or 'none'}, got {got or 'none'}")
    return failures, len(tests["cases"])


def gate_or_die(cfg: dict, doing: str) -> None:
    failures, _n = run_suite(cfg)
    if failures:
        for line in failures:
            print(f"gate: {line}", file=sys.stderr)
        die(f"{doing} refused — {len(failures)} failure(s) against the "
            "would-be table; a broken rule must not be armed (fix the rule, "
            "or update the cases through the test doors first)")


# --------------------------------------------------------------------------
# Commands.
# --------------------------------------------------------------------------
def cmd_init(args):
    game_dir().mkdir(parents=True, exist_ok=True)
    state_dir().mkdir(parents=True, exist_ok=True)
    if rules_path().exists():
        print(f"learned table already at {rules_path()} — left untouched")
    else:
        game_reflex.atomic_write(rules_path(),
                                 json.dumps(EMPTY_TABLE, indent=2) + "\n")
        print(f"wrote empty learned table to {rules_path()}")


def cmd_rules(args):
    cfg = load_config()
    if not cfg["rules"] and not cfg["unfinished"]:
        print("no learned rules yet")
    for rule in sorted(cfg["rules"], key=lambda r: -r["priority"]):
        state = "on " if rule["enabled"] else "OFF"
        trig = " ".join(f"{k}={json.dumps(v) if isinstance(v, dict) else v}"
                        for k, v in rule["trigger"].items())
        act = " ".join(f"{k}={v}" for k, v in rule["action"].items() if k != "type")
        act = rule["action"]["type"] + (f" {act}" if act else "")
        once = ", once/objective" if rule.get("once_per_objective") else ""
        print(f"[{state}] {rule['name']}  (priority {rule['priority']}, "
              f"cooldown {rule['cooldown_ms']}ms, hold {rule['hold_ticks']}{once})")
        print(f"       when {trig}  ->  {act}")
        if rule.get("note"):
            print(f"       note: {rule['note']}")
    for entry in cfg["unfinished"]:
        print(f"[UNFINISHED] {entry['name']}: {entry['note']}")
    d = config_defaults(cfg)
    print("defaults: " + " ".join(f"{k}={v}" for k, v in sorted(d.items())))
    obj = read_objective()
    print(f"objective: {obj if obj else '(none)'}")
    activity = read_activity()
    print(f"activity: {activity if activity else '(none)'}")


def parse_kv(pairs):
    out = {}
    for pair in pairs or []:
        if "=" not in pair:
            die(f"'{pair}' is not key=value")
        key, val = pair.split("=", 1)
        out[key] = game_reflex.parse_value(val)
    return out


def cmd_learn(args):
    cfg = load_config()
    if any(r["name"] == args.name for r in cfg["rules"]):
        die(f"a rule named '{args.name}' already exists")
    rule = {
        "name": args.name,
        "enabled": not args.disabled,
        "priority": args.priority,
        "cooldown_ms": args.cooldown_ms,
        "hold_ticks": args.hold_ticks,
        "trigger": parse_kv(args.trigger),
        "action": {"type": args.action, **parse_kv(args.param)},
    }
    if args.once_per_objective:
        rule["once_per_objective"] = True
    if args.note:
        rule["note"] = args.note
    cfg["rules"].append(rule)
    try:
        validate_config(cfg)
    except ValueError as e:
        die(str(e))
    gate_or_die(cfg, f"learning '{args.name}'")
    save_config(cfg)
    print(f"learned '{args.name}' "
          f"({'disabled' if args.disabled else 'enabled'}, durable)")


def cmd_unfinished(args):
    cfg = load_config()
    if any(e["name"] == args.name for e in cfg["unfinished"]):
        die(f"an unfinished entry named '{args.name}' already exists")
    cfg["unfinished"].append({"name": args.name, "note": " ".join(args.note)})
    try:
        save_config(cfg)
    except ValueError as e:
        die(str(e))
    print(f"recorded '{args.name}' as unfinished — not evaluated, not forgotten")


def find_rule(cfg, name):
    for rule in cfg["rules"]:
        if rule["name"] == name:
            return rule
    die(f"no rule named '{name}' (game_player.py rules lists them)")


def cmd_enable(args, value=True):
    cfg = load_config()
    find_rule(cfg, args.rule)["enabled"] = value
    gate_or_die(cfg, f"{'enabling' if value else 'disabling'} '{args.rule}'")
    save_config(cfg)
    print(f"{args.rule}: {'enabled' if value else 'disabled'}")


def cmd_set(args):
    cfg = load_config()
    rule = find_rule(cfg, args.rule)
    key, value = args.key, game_reflex.parse_value(args.value)
    if key in ("priority", "cooldown_ms", "hold_ticks", "enabled",
               "once_per_objective", "note"):
        rule[key] = value
    elif key.startswith("trigger.") or key.startswith("action."):
        section, sub = key.split(".", 1)
        if value is None:
            rule[section].pop(sub, None)
        else:
            rule[section][sub] = value
    else:
        die(f"unknown key '{key}' — priority, cooldown_ms, hold_ticks, enabled, "
            "once_per_objective, note, trigger.<cond>, action.<param>")
    try:
        validate_config(cfg)
    except ValueError as e:
        die(str(e))
    gate_or_die(cfg, f"setting '{args.rule}' {key}")
    save_config(cfg)
    print(f"{args.rule}: {key} = {value!r}")


def cmd_remove(args):
    cfg = load_config()
    before = len(cfg["rules"]) + len(cfg["unfinished"])
    cfg["rules"] = [r for r in cfg["rules"] if r["name"] != args.rule]
    cfg["unfinished"] = [e for e in cfg["unfinished"] if e["name"] != args.rule]
    if len(cfg["rules"]) + len(cfg["unfinished"]) == before:
        die(f"nothing named '{args.rule}' in rules or unfinished")
    gate_or_die(cfg, f"removing '{args.rule}'")
    save_config(cfg)
    print(f"removed '{args.rule}'")


def cmd_objective(args):
    if args.clear:
        try:
            objective_path().unlink()
        except FileNotFoundError:
            pass
        print("objective cleared")
        return
    if args.name is None:
        obj = read_objective()
        print(obj if obj else "(none)")
        return
    if "\n" in args.name or not args.name.strip():
        die("the objective is one non-empty line")
    game_dir().mkdir(parents=True, exist_ok=True)
    game_reflex.atomic_write(objective_path(), args.name.strip() + "\n")
    print(f"objective: {args.name.strip()}")


def cmd_activity(args):
    """The immediate mode of play, separate from the longer-lived objective."""
    if args.clear:
        try:
            activity_path().unlink()
        except FileNotFoundError:
            pass
        clear_activity_stats()
        print("activity cleared")
        return
    if args.name is None:
        activity = read_activity()
        print(activity if activity else "(none)")
        return
    if "\n" in args.name or not args.name.strip():
        die("the activity is one non-empty line")
    selected = args.name.strip()
    previous = read_activity()
    game_dir().mkdir(parents=True, exist_ok=True)
    game_reflex.atomic_write(activity_path(), selected + "\n")
    if selected != previous or args.restart:
        clear_activity_stats()
        start_activity_stats(selected, game_reflex.read_snapshot() or {})
    print(f"activity: {selected}")


def cmd_session(args):
    """Spec rule 21: open, inspect, or close the sitting.

    `open` is the entrypoint's hand and never restarts a clock that is already
    running — `play` stays the resume door. `end` is HER hand, declaring the
    wind-down finished; it is also what the grace timer runs when nobody
    declared anything. `status` is one line either hand can read."""
    if args.action == "open":
        # An ENDED record is not an open sitting — opening past one is exactly
        # how the next sitting starts, and it is what lifts rule 21c-i's
        # suppression. Only a live sitting refuses to be reopened.
        st = session_state()
        if st["phase"] in ("open", "over", "expired"):
            print(f"session already open: {st['elapsed_ms'] // 60000}m elapsed "
                  f"of {st['limit_ms'] // 60000}m ({st['phase']})")
            return
        game_dir().mkdir(parents=True, exist_ok=True)
        body = {"started": now_ms(),
                "limit_ms": int(args.limit_ms or SESSION_LIMIT_MS),
                "grace_ms": int(args.grace_ms or SESSION_GRACE_MS),
                "ended": None}
        game_reflex.atomic_write(session_path(), json.dumps(body) + "\n")
        print(f"session open: {body['limit_ms'] // 60000}m to play, "
              f"{body['grace_ms'] // 60000}m of grace after that")
        return
    if args.action == "end":
        st = session_state()
        if st["phase"] == "none":
            print("session: none open")
            return
        body = dict(read_session())
        body["ended"] = now_ms()
        game_reflex.atomic_write(session_path(), json.dumps(body) + "\n")
        print(f"session ended after {st['elapsed_ms'] // 60000}m "
              f"of a {st['limit_ms'] // 60000}m sitting")
        return
    st = session_state()
    if st["phase"] == "none":
        print("session: none open")
        return
    print(f"session: {st['phase']} — {st['elapsed_ms'] // 60000}m elapsed of "
          f"{st['limit_ms'] // 60000}m, grace left {st['grace_ms_left'] // 60000}m")


def cmd_route(args):
    """Spec rule 7e: set, inspect, or clear the runner's durable route."""
    if args.clear:
        if args.x is not None or args.z is not None:
            die("route --clear takes no coordinates")
        clear_route()
        print("route cleared")
        return
    if args.x is None and args.z is None:
        route = load_route()
        if route is None:
            print("route: (none)")
        elif route.get("status") == "invalid":
            print(f"route: invalid ({route_path()})")
        else:
            print(f"route: status={route['status']} target=({route['x']},{route['z']}) "
                  f"arrive={route['arrive']} objective={route['objective'] or '(none)'}"
                  f"{(' reason=' + route.get('blocked_reason', '')) if route['status'] == 'blocked' else ''}")
        return
    if args.x is None or args.z is None:
        die("route needs both X and Z")
    if not 0 <= args.arrive <= 10:
        die("route --arrive must be from 0 through 10")
    route = {"v": 1, "x": args.x, "z": args.z, "arrive": args.arrive,
             "objective": read_objective(), "status": "active", "set_ts": now_ms()}
    save_route(route)
    print(f"route-set target=({args.x},{args.z}) arrive={args.arrive} "
          f"objective={route['objective'] or '(none)'}")


def cmd_log(args):
    path = state_dir() / "player-decisions.jsonl"
    try:
        lines = path.read_text().splitlines()
    except OSError:
        print(f"no decisions yet at {path}")
        return
    for line in lines[-args.n:]:
        print(line)


def cmd_note(args):
    """Spec rule 16: the playing hand's one-line door for lessons — stamped
    with the live context and queued for the background author."""
    snap = game_reflex.read_snapshot() or {}
    append_outcome({"ts": now_ms(), "kind": "lesson", "text": " ".join(args.text),
                    "objective": read_objective() or None,
                    "snap": snap_brief(snap)})
    print("noted for the background author")


def validate_reply_text(text: str) -> None:
    if not text.strip() or "\n" in text or "\r" in text:
        die("reply text must be one non-empty line")
    if len(text) > 80:
        die("reply text exceeds the client's 80-character limit")


def canonical_chat_text(text: str) -> str:
    """Compare the words the Classic client actually carries.

    RSC's chat codec can discard punctuation and normalize capitalization
    between dispatch and the outgoing snapshot echo (for example `PM` becomes
    `Pm`). Those are not delivery failures. Keep word/order differences
    meaningful while making punctuation, case, and Unicode punctuation forms
    irrelevant to confirmation.
    """
    normalized = unicodedata.normalize("NFKC", str(text)).casefold()
    return " ".join("".join(ch if ch.isalnum() else " "
                            for ch in normalized).split())


def verify_chat_delivery(action: dict, after_id: int, timeout_s: float = 3.0) -> str:
    """Confirm the outgoing chat echo; a bridge receipt is dispatch only."""
    expected_text = canonical_chat_text(action["text"])
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        snap = game_reflex.read_snapshot() or {}
        for message in snap.get("messages") or []:
            if not isinstance(message, dict) or message.get("id", -1) <= after_id:
                continue
            if message.get("channel") == "game" \
                    and "unable to send message" in message.get("text", "").casefold():
                return "refused-server"
            channel = "private" if action["type"] == "chat-private" else "local"
            if message.get("channel") == channel \
                    and message.get("incoming") is False \
                    and canonical_chat_text(message.get("text", "")) == expected_text:
                if channel != "private" \
                        or message.get("sender", "").casefold() == action["target"].casefold():
                    return "done"
        time.sleep(0.05)
    return "chat-unconfirmed"


def cmd_reply(args):
    """Answer one pending player message through the shared action slot."""
    text = " ".join(args.text)
    validate_reply_text(text)
    cfg = load_config()
    defaults = config_defaults(cfg)
    snap = game_reflex.read_snapshot()
    if snap is None:
        report("reply-not-ready", message_id=args.message_id, reason="no-snapshot")
        sys.exit(EXIT_NOT_READY)
    if not snap.get("logged_in"):
        report("reply-needs-login", message_id=args.message_id,
               next="betty-openrsc-login", pending="preserved")
        sys.exit(EXIT_NOT_READY)
    if now_ms() - snap.get("ts", 0) > defaults["stale_ms"]:
        die("cannot reply from a stale game snapshot")
    if (state_dir() / "hold").exists():
        die("cannot reply while play is held")
    if (state_dir() / "action.json").exists():
        die("cannot reply while the shared action slot is busy")

    # The idle warning outranks conversation even when that conversation was
    # already pending. Refresh it against the current tile here as well as in
    # the runner, so a direct reply can neither race past a new warning nor be
    # blocked by one whose required move just completed.
    with player_state_lock():
        est = load_player_state()
        system_events = []
        capture_urgent_system_messages(snap, est, system_events)
        pending_system = oldest_pending_system_message(est)
        save_player_state(est)
        flush_events(system_events)
    if pending_system is not None:
        report("reply-needs-movement", message_id=args.message_id,
               system_message_id=pending_system["id"], next="walk-one-tile",
               pending="preserved")
        sys.exit(EXIT_SYSTEM_MESSAGE)

    baseline_message_id = max((m.get("id", -1) for m in snap.get("messages") or []
                               if isinstance(m, dict)), default=-1)
    with player_state_lock():
        # The runner may have filled the slot after the quick check above but
        # before this reply acquired the shared state lock.
        if (state_dir() / "action.json").exists():
            die("cannot reply while the shared action slot is busy")
        est = load_player_state()
        pending = next((m for m in est["pending_messages"] if m["id"] == args.message_id), None)
        if pending is None:
            die(f"no pending player message {args.message_id}")
        nearby_names = {
            str(player.get("name", "")).casefold()
            for player in snap.get("players") or [] if isinstance(player, dict)
        }
        action = {"type": "chat-local", "text": text}
        if pending["channel"] == "private" \
                or pending["sender"].casefold() not in nearby_names:
            action = {"type": "chat-private", "target": pending["sender"], "text": text}
        est["action_seq"] += 1
        action_id = est["action_seq"]
        sent_at = now_ms()
        est["inflight"] = {"id": action_id, "ts": sent_at}
        save_player_state(est)
        emit_player_action("action.json", action, action_id, sent_at)

    status = "no-receipt"
    deadline = time.time() + defaults["inflight_timeout_ms"] / 1000.0
    receipt_path = state_dir() / "receipt.json"
    while time.time() < deadline:
        try:
            receipt = json.loads(receipt_path.read_text())
        except (OSError, json.JSONDecodeError):
            receipt = None
        if receipt and receipt.get("id") == action_id:
            status = receipt.get("status", "no-status")
            try:
                receipt_path.unlink()
            except OSError:
                pass
            break
        time.sleep(0.05)

    if status == "done":
        status = verify_chat_delivery(action, baseline_message_id)

    with player_state_lock():
        est = load_player_state()
        est["inflight"] = None
        if status == "done":
            est["pending_messages"] = [m for m in est["pending_messages"]
                    if not (m["channel"] == pending["channel"]
                            and m["sender"].casefold() == pending["sender"].casefold()
                            and m["id"] <= pending["id"])]
            if not est["pending_messages"]:
                est["message_settle_until"] = 0
        save_player_state(est)
        flush_events([{"ts": now_ms(), "kind": "player-message-reply",
                       "message_id": pending["id"], "action_id": action_id,
                       "channel": pending["channel"], "sender": pending["sender"],
                       "reply_channel": "private" if action["type"] == "chat-private" else "local",
                       "status": status}])
    report("replied", message_id=pending["id"], action_id=action_id,
           channel=pending["channel"], sender=pending["sender"],
           reply_channel="private" if action["type"] == "chat-private" else "local",
           status=status)
    if status != "done":
        sys.exit(EXIT_NOT_DONE)


def cmd_test(args):
    if args.action in ("run", None):
        cfg = load_config()
        failures, count = run_suite(cfg)
        for line in failures:
            print(f"FAIL {line}")
        print(f"suite: {count} case(s), {len(failures)} failure(s)")
        sys.exit(1 if failures else 0)
    if args.action == "list":
        tests = load_tests()
        if not tests["cases"]:
            print("no cases yet")
        for case in tests["cases"]:
            print(f"{case['name']}: objective={case.get('objective') or '(none)'} "
                  f"activity={case.get('activity') or '(none)'} "
                  f"expect={case.get('expect') or 'none'}")
        return
    if args.action == "add":
        if not args.name or not args.snapshot or args.expect is None:
            die("test add <name> --expect <rule|none> --snapshot <file|-> "
                "[--objective OBJ]")
        raw = sys.stdin.read() if args.snapshot == "-" \
            else Path(args.snapshot).read_text()
        try:
            snapshot = json.loads(raw)
        except json.JSONDecodeError as e:
            die(f"snapshot is not valid JSON: {e}")
        tests = load_tests()
        if any(c["name"] == args.name for c in tests["cases"]):
            die(f"a case named '{args.name}' already exists")
        case = {"name": args.name, "objective": args.objective or "",
                "activity": args.activity or "",
                "expect": None if args.expect == "none" else args.expect,
                "snapshot": snapshot}
        # A case must be true the moment it is added — the suite stays green
        # so the gate only trips when a MUTATION breaks something.
        cfg = load_config()
        got, _ = predict(cfg, snapshot, case["objective"], case["activity"])
        want = case["expect"]
        if got != want:
            die(f"case would fail right now: expected {want or 'none'}, "
                f"the live table gives {got or 'none'} — learn/fix the rule first")
        tests["cases"].append(case)
        save_tests(tests)
        print(f"case '{args.name}' added ({len(tests['cases'])} total)")
        return
    if args.action == "remove":
        if not args.name:
            die("test remove <name>")
        tests = load_tests()
        kept = [c for c in tests["cases"] if c["name"] != args.name]
        if len(kept) == len(tests["cases"]):
            die(f"no case named '{args.name}'")
        tests["cases"] = kept
        save_tests(tests)
        print(f"case '{args.name}' removed")
        return
    die(f"unknown test action '{args.action}' — run, list, add, remove")


def cmd_run(args):
    """Spec rule 15: the resident runner. Rules fire within a poll interval
    of their trigger becoming true; no model anywhere in the loop."""
    global QUIET_REPEATS
    QUIET_REPEATS = True
    cfg = load_config()
    wait_ms = config_defaults(cfg)["inflight_timeout_ms"]
    poll_s = (args.poll_ms or 400) / 1000.0
    state_dir().mkdir(parents=True, exist_ok=True)
    try:
        table_mtime = rules_path().stat().st_mtime
    except OSError:
        table_mtime = 0
    last_gap_signature = None
    gap_candidate_signature = None
    gap_candidate_since = 0
    last_verdict = "starting"
    while True:
        try:
            # Reload the table when its mtime moves; an invalid table is
            # refused loudly and the last valid one kept (spec rule 15).
            try:
                mt = rules_path().stat().st_mtime
            except OSError:
                mt = table_mtime
            if mt != table_mtime:
                table_mtime = mt
                try:
                    fresh = json.loads(rules_path().read_text())
                    validate_config(fresh)
                    fresh.setdefault("unfinished", [])
                    cfg = fresh
                    wait_ms = config_defaults(cfg)["inflight_timeout_ms"]
                    flush_events([{"ts": now_ms(), "kind": "table-reloaded"}])
                except (ValueError, json.JSONDecodeError) as e:
                    flush_events([{"ts": now_ms(), "kind": "table-invalid",
                                   "error": str(e)[:300]}])

            verdict, _code = step_once(cfg, read_objective(), read_activity(), wait_ms)

            if verdict in ("no-rule-matched", "same-tick") \
                    and (verdict == "no-rule-matched" or gap_candidate_signature is not None):
                snap = game_reflex.read_snapshot() or {}
                objective = read_objective()
                activity = read_activity()
                signature = gap_signature(snap, objective, activity)
                now = now_ms()
                if signature != gap_candidate_signature:
                    gap_candidate_signature = signature
                    gap_candidate_since = now
                elif signature != last_gap_signature \
                        and now - gap_candidate_since >= GAP_STABLE_MS:
                    append_outcome({"ts": now_ms(), "kind": "gap",
                                    "objective": objective or None,
                                    "activity": activity or None,
                                    "snap": snap_brief(snap)})
                    last_gap_signature = signature
            elif verdict != "same-tick":
                gap_candidate_signature = None
                gap_candidate_since = 0

            # same-tick is no news between game ticks: the heartbeat keeps
            # carrying the last substantive verdict so `step`'s deferral
            # still hands the model its exit-4 licence when one is due.
            if verdict != "same-tick":
                last_verdict = verdict
            latest = game_reflex.read_snapshot() or {}
            detail = latest_system_feedback(latest) or ""
            active_route = load_route()
            if active_route is not None and active_route.get("status") != "invalid":
                route_detail = (f"route {active_route['status']} to "
                                f"({active_route['x']},{active_route['z']})")
                detail = f"{route_detail}; {detail}" if detail else route_detail
            live_activity = read_activity()
            live_xp = activity_xp_text(latest, live_activity)
            write_heartbeat(last_verdict, detail,
                            [i.get("id") for i in latest.get("ground_items") or []],
                            live_activity, live_xp)
        except SystemExit:
            raise
        except Exception as e:  # one bad pass must not kill the unit
            try:
                flush_events([{"ts": now_ms(), "kind": "runner-error",
                               "error": repr(e)[:300]}])
            except Exception:
                pass
            time.sleep(1.0)
        if args.once:
            break
        time.sleep(0.05 if last_verdict == "fired" else poll_s)


def main():
    parser = argparse.ArgumentParser(
        prog="game_player.py",
        description="learned rules are the primary play path (specs/game-player.md)")
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("init", help="write an empty learned table if none exists") \
        .set_defaults(fn=cmd_init)
    sub.add_parser("rules", help="the learned table, unfinished ledger, objective") \
        .set_defaults(fn=cmd_rules)

    p = sub.add_parser("learn", help="persist a verified play as an executable rule")
    p.add_argument("name")
    p.add_argument("--priority", type=int, required=True)
    p.add_argument("--cooldown-ms", type=int, default=8000)
    p.add_argument("--hold-ticks", type=int, default=1)
    p.add_argument("--once-per-objective", action="store_true")
    p.add_argument("--disabled", action="store_true")
    p.add_argument("--note")
    p.add_argument("--trigger", action="append", metavar="COND=VALUE")
    p.add_argument("--action", required=True)
    p.add_argument("--param", action="append", metavar="KEY=VALUE")
    p.set_defaults(fn=cmd_learn)

    p = sub.add_parser("unfinished",
                       help="record a play whose trigger/action cannot be grounded yet")
    p.add_argument("name")
    p.add_argument("note", nargs="+")
    p.set_defaults(fn=cmd_unfinished)

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

    p = sub.add_parser("remove", help="remove a rule or unfinished entry")
    p.add_argument("rule")
    p.set_defaults(fn=cmd_remove)

    p = sub.add_parser("objective", help="show, set or clear the durable objective")
    p.add_argument("name", nargs="?")
    p.add_argument("--clear", action="store_true")
    p.set_defaults(fn=cmd_objective)

    p = sub.add_parser("activity", help="show, select or clear the current activity")
    p.add_argument("name", nargs="?")
    p.add_argument("--clear", action="store_true")
    p.add_argument("--restart", action="store_true",
                   help="restart this activity's elapsed time and XP baseline")
    p.set_defaults(fn=cmd_activity)

    p = sub.add_parser("session", help="the sitting's clock: open, status, end")
    p.add_argument("action", nargs="?", default="status",
                   choices=["open", "status", "end"])
    p.add_argument("--limit-ms", type=int, dest="limit_ms")
    p.add_argument("--grace-ms", type=int, dest="grace_ms")
    p.set_defaults(fn=cmd_session)

    p = sub.add_parser("route", help="set, inspect, or clear the durable ACTIONS route")
    p.add_argument("x", nargs="?", type=int)
    p.add_argument("z", nargs="?", type=int)
    p.add_argument("--arrive", type=int, default=1)
    p.add_argument("--clear", action="store_true")
    p.set_defaults(fn=cmd_route)

    p = sub.add_parser("step",
                       help="one rules-first evaluation; exit 4 = model may reason")
    p.add_argument("--max", type=int, default=1,
                   help="keep stepping while rules fire cleanly, at most N actions")
    p.add_argument("--wait-ms", type=int, default=None,
                   help="receipt wait (default: defaults.inflight_timeout_ms)")
    p.add_argument("--local", action="store_true",
                   help="evaluate here even if the resident runner is live")
    p.set_defaults(fn=None)  # handled below: needs config-aware default

    p = sub.add_parser("log", help="tail the player decision log")
    p.add_argument("-n", type=int, default=20)
    p.set_defaults(fn=cmd_log)

    p = sub.add_parser("run", help="the resident runner: rules fire on their "
                                   "triggers, continuously (spec rule 15)")
    p.add_argument("--once", action="store_true")
    p.add_argument("--poll-ms", type=int)
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("note", help="queue a lesson for the background author "
                                    "(spec rule 16)")
    p.add_argument("text", nargs="+")
    p.set_defaults(fn=cmd_note)

    p = sub.add_parser("reply", help="answer a pending player message through "
                                      "the shared action slot (spec rule 7b)")
    p.add_argument("message_id", type=int)
    p.add_argument("text", nargs="+")
    p.set_defaults(fn=cmd_reply)

    p = sub.add_parser("wait-until", aliases=["wait_until"],
                       help="wait on live ACTIONS state without sleeps or screenshots")
    p.add_argument("condition")
    p.add_argument("--timeout", type=float, default=WAIT_DEFAULT_S,
                   help=f"hard ceiling in seconds (default {WAIT_DEFAULT_S:g}, max {WAIT_MAX_S:g})")
    p.set_defaults(fn=cmd_wait_until)

    p = sub.add_parser("retreat",
                       help="keep sending reachable escape walks until combat really ends")
    p.add_argument("--timeout", type=float, default=20.0,
                   help="hard ceiling in seconds (default 20, max 30)")
    p.add_argument("--distance", type=int, default=5)
    p.add_argument("--dx", type=int, default=0,
                   help="fallback x direction when the opponent is not identified")
    p.add_argument("--dz", type=int, default=1,
                   help="fallback z direction when the opponent is not identified")
    p.set_defaults(fn=cmd_retreat)

    p = sub.add_parser("take",
                       help="take a visible item and verify it entered inventory")
    p.add_argument("item", type=int)
    p.set_defaults(fn=cmd_take)

    p = sub.add_parser("test", help="replay the cases against the table "
                                    "(spec rule 17)")
    p.add_argument("action", nargs="?", default="run",
                   choices=["run", "list", "add", "remove"])
    p.add_argument("name", nargs="?")
    p.add_argument("--expect", help="the rule that must win, or 'none'")
    p.add_argument("--snapshot", help="snapshot JSON file, or - for stdin")
    p.add_argument("--objective", help="objective the case runs under")
    p.add_argument("--activity", help="current activity the case runs under")
    p.set_defaults(fn=cmd_test)

    args = parser.parse_args()
    if args.cmd == "step":
        # Spec rule 15: while the resident runner is live it is the ONLY
        # evaluator — report ITS latest verdict under the same exit contract.
        if not args.local:
            hb = read_live_runner()
            if hb is not None:
                verdict = hb.get("verdict", "")
                if verdict == "player-message":
                    live_state = load_player_state()
                    batch = pending_message_batch(live_state)
                    pending = batch[-1] if batch else None
                    if pending is not None:
                        report("player-message", id=pending["id"],
                               channel=pending["channel"], sender=pending["sender"],
                               count=len(batch), burst=pending_message_burst(batch))
                    else:
                        report("runner-player-message", age_ms=now_ms() - hb.get("ts", 0),
                               pid=hb.get("pid"))
                elif verdict == "system-message":
                    pending = oldest_pending_system_message(load_player_state())
                    if pending is not None:
                        report("system-message", id=pending["id"],
                               channel=pending["channel"], action="move-required",
                               text=pending["text"])
                    else:
                        report("runner-system-message", age_ms=now_ms() - hb.get("ts", 0),
                               pid=hb.get("pid"))
                else:
                    report(f"runner-{verdict or 'unknown'}",
                           age_ms=now_ms() - hb.get("ts", 0), pid=hb.get("pid"),
                           activity=hb.get("activity") or None,
                           activity_xp=hb.get("activity_xp") or None,
                           ground_items=",".join(str(i)
                                                 for i in hb.get("ground_items") or []) or None,
                           feedback=hb.get("detail") or None)
                sys.exit({"no-rule-matched": EXIT_NO_RULE,
                          "route-blocked": EXIT_NO_RULE,
                          "held": EXIT_HELD,
                          "fired": EXIT_FIRED,
                          "player-message": EXIT_PLAYER_MESSAGE,
                          "system-message": EXIT_SYSTEM_MESSAGE,
                          "session-over": EXIT_SESSION_OVER}.get(verdict, EXIT_NOT_READY))
        cfg = load_config()
        if args.wait_ms is None:
            args.wait_ms = config_defaults(cfg)["inflight_timeout_ms"]
        objective = read_objective()
        activity = read_activity()
        fired_count = 0
        verdict, code = "no-rule-matched", EXIT_NO_RULE
        for _ in range(max(1, args.max)):
            verdict, code = step_once(cfg, objective, activity, args.wait_ms)
            if verdict != "fired":
                break
            fired_count += 1
            if code != EXIT_FIRED:
                break
        if fired_count and verdict == "fired":
            sys.exit(code)
        sys.exit(EXIT_FIRED if fired_count else code)
    if not getattr(args, "fn", None):
        parser.print_help()
        sys.exit(2)
    args.fn(args)


if __name__ == "__main__":
    main()
