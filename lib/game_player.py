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
import hashlib
import json
import os
import re
import select
import subprocess
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
ACTIONS = ("talk-npc", "interact-npc", "cast-npc", "walk", "retreat", "interact-object", "interact-bound", "click-entity",
           "click-inventory", "click-shop", "click-bank", "take-ground")
SYSTEM_FEEDBACK_CHANNELS = ("game", "quest", "inventory")
FRIEND_STATUS_RE = re.compile(r"^(.+?)\s+has logged\s+(in|out)\s*$", re.IGNORECASE)
WAIT_CONDITIONS = (
    "logged_in", "logged_out", "walking", "not_walking", "in_combat",
    "out_of_combat", "talking_to_npc", "not_talking_to_npc",
    "right_click_menu_open", "right_click_menu_closed",
    "ui_panel_open", "ui_panel_closed",
    "trade_open", "trade_closed", "sleeping", "not_sleeping", "fatigue_zero",
    "action_done",
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
RETREAT_CLEARANCE_TILES = 12  # leaving one combat flag is not clearing a pack
RETREAT_SAFE_NPC_RADIUS = 8   # Classic aggression is local; leave visible threats behind
RUNNER_FRESH_MS = 30000     # a heartbeat younger than this (and a live pid) means the
                            # runner owns evaluation; wide enough to cover one walk's
                            # verification, and a crashed runner fails the pid check at once
GAP_STABLE_MS = 750          # moving across tiles is one situation, not one Sol wake per tile
PLAYER_MESSAGE_SETTLE_MS = 5000  # collect one RuneScape-length chat chain before Sol replies
REPETITION_WINDOW_MS = 3 * 60 * 1000
REPETITION_THRESHOLD = 3
REPETITION_REVIEW_HOLD_MS = 30 * 1000
ACTIVITY_PERFORMANCE_MIN_MS = 60 * 1000
ACTIVITY_REVIEW_INTERVAL_MS = 3 * 60 * 1000
MOVEMENT_TRAIL_MAX_POINTS = 1024
MOVEMENT_TRAIL_BREAK_DISTANCE = 12
NAVIGATION_LEG_MAX_TILES = 8  # stay inside the collision map a person can currently see
NAVIGATION_LEG_MAX_PATH_TILES = 16  # reject a nearby waypoint whose real route is a huge loop
NAVIGATION_ROUTE_STEP_TILES = 8  # client-grounded prefix of the real destination path
NAVIGATION_MAX_NONCLOSING_LEGS = 12  # allow real detours, never unbounded wandering
NAVIGATION_VISITED_MAX = 64
BACKTRACK_DEFAULT_POINTS = 8  # recovery is a recent correction, not a replay of the whole day
ROUTE_RULE_NAME = "active-route"
ROUTE_PRIORITY = -1_000_000  # every learned interaction outranks ordinary travel
BACKTRACK_RULE_NAME = "active-backtrack"
BACKTRACK_PRIORITY = 900_000  # deliberate recovery beats routine work; retreat still wins
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
SESSION_MESSAGE_TOP_UP_MS = 20 * 60 * 1000

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


def activity_history_path() -> Path:
    return game_dir() / "activity-history.jsonl"


def reflex_history_path() -> Path:
    return game_dir() / "reflex-history.jsonl"


def retreat_request_path() -> Path:
    return state_dir() / "retreat-request.json"


def take_progress_path() -> Path:
    return state_dir() / "take-in-progress.json"


def action_observation_path() -> Path:
    return state_dir() / "last-action-observation.json"


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
    if not isinstance(request, dict) or request.get("v") != 2 \
            or not isinstance(request.get("expires"), int) \
            or request["expires"] <= now_ms() \
            or not isinstance(request.get("distance"), int) \
            or not 1 <= request["distance"] <= 10 \
            or not isinstance(request.get("origin_x"), int) \
            or not isinstance(request.get("origin_z"), int) \
            or not isinstance(request.get("clearance"), int) \
            or not 1 <= request["clearance"] <= 30 \
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


_aggressive_npc_ids_cache = None


def aggressive_npc_ids() -> set[int]:
    """Server-defined aggressive NPC identities, when this OpenRSC install
    exposes its ordinary definition file. Missing definitions fail open for
    movement but the origin-clearance proof still applies."""
    global _aggressive_npc_ids_cache
    if _aggressive_npc_ids_cache is not None:
        return _aggressive_npc_ids_cache
    candidates = []
    configured = os.environ.get("DESKCRAB_GAME_NPC_DEFS")
    if configured:
        candidates.append(Path(configured))
    candidates.append(Path.home() / "Games/OpenRSC/Core-Framework/server/conf/server/defs/NpcDefs.json")
    result = set()
    for path in candidates:
        try:
            raw = json.loads(path.read_text())
            result = {
                item["id"] for item in raw.get("npcs", [])
                if isinstance(item, dict) and isinstance(item.get("id"), int)
                and item.get("aggressive") in (1, True)
            }
            break
        except (OSError, json.JSONDecodeError, AttributeError):
            continue
    _aggressive_npc_ids_cache = result
    return result


def visible_aggressive_npcs(snap: dict) -> list[dict]:
    ids = aggressive_npc_ids()
    return [npc for npc in snap.get("npcs") or []
            if isinstance(npc, dict) and npc.get("id") in ids
            and isinstance(npc.get("x"), int) and isinstance(npc.get("z"), int)]


def choose_retreat_direction(snap: dict, fallback_x: int, fallback_z: int,
                             distance: int = RETREAT_CLEARANCE_TILES) -> tuple[int, int]:
    """Choose one stable outward direction for the entire escape. Scoring the
    projected clearance tile against every visible aggressive NPC prevents a
    five-tile dodge away from one member of a pack from running into another."""
    px, pz = snap.get("x"), snap.get("z")
    if not isinstance(px, int) or not isinstance(pz, int):
        return fallback_x, fallback_z
    hazards = visible_aggressive_npcs(snap)
    opponent = snap.get("opponent") or {}
    if not hazards and isinstance(opponent.get("x"), int) \
            and isinstance(opponent.get("z"), int):
        hazards = [{"x": opponent["x"], "z": opponent["z"]}]
    if not hazards:
        return fallback_x, fallback_z
    directions = [(dx, dz) for dx in (-1, 0, 1) for dz in (-1, 0, 1)
                  if dx != 0 or dz != 0]

    def score(direction):
        dx, dz = direction
        tx, tz = px + dx * distance, pz + dz * distance
        distances = [max(abs(tx - npc["x"]), abs(tz - npc["z"]))
                     for npc in hazards]
        # Stable tie-breaks: maximize nearest safety, then total separation,
        # then respect the caller's fallback rather than changing direction.
        return (min(distances), sum(distances),
                int(direction == (fallback_x, fallback_z)), dx, dz)

    return max(directions, key=score)


def retreat_has_clearance(snap: dict, request: dict) -> bool:
    if snap.get("in_combat") is not False:
        return False
    px, pz = snap.get("x"), snap.get("z")
    if not isinstance(px, int) or not isinstance(pz, int):
        return False
    moved = max(abs(px - request["origin_x"]), abs(pz - request["origin_z"]))
    if moved < request["clearance"]:
        return False
    return all(max(abs(px - npc["x"]), abs(pz - npc["z"]))
               >= RETREAT_SAFE_NPC_RADIUS
               for npc in visible_aggressive_npcs(snap))


def retreat_clearance_target(snap: dict, request: dict) -> tuple[int, int]:
    """An absolute target anchored at the combat origin. Repeated runner
    passes therefore complete one escape instead of walking another leg on
    every tick."""
    return (request["origin_x"] + request["dx"] * request["clearance"],
            request["origin_z"] + request["dz"] * request["clearance"])


def route_path() -> Path:
    return game_dir() / "route.json"


def movement_trail_path() -> Path:
    return game_dir() / "movement-trail.json"


def backtrack_path() -> Path:
    return game_dir() / "backtrack.json"


def session_path() -> Path:
    return game_dir() / "session.json"


def session_lock_path() -> Path:
    return game_dir() / "session.lock"


class session_state_lock:
    """Serialize session opening, ending, deadline claims, and chat top-ups."""
    def __enter__(self):
        session_lock_path().parent.mkdir(parents=True, exist_ok=True)
        self.fh = open(session_lock_path(), "a+")
        fcntl.flock(self.fh.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc, tb):
        fcntl.flock(self.fh.fileno(), fcntl.LOCK_UN)
        self.fh.close()


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
    # A closed sitting is historical state. Its elapsed counter must stop at
    # the close rather than continuing to grow every time status is read.
    clock_now = min(now, int(s["ended"])) if s.get("ended") else now
    elapsed = clock_now - int(s["started"])
    deadline = int(s["started"]) + limit
    hard_deadline = deadline + grace
    out = {"phase": "open", "started": int(s["started"]), "elapsed_ms": elapsed,
           "limit_ms": limit, "grace_ms": grace,
           "deadline_ms": deadline, "hard_deadline_ms": hard_deadline,
           "remaining_ms": max(0, deadline - now),
           "grace_ms_left": max(0, hard_deadline - now)}
    if s.get("ended"):
        out["phase"] = "ended"
        out["remaining_ms"] = 0
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


def memory_program() -> Path:
    """The same durable store door used by betty-openrsc.

    Tests and alternate installs may replace it explicitly; ordinary play
    resolves the sibling memory.py from this installed DeskCrab tree.
    """
    return Path(os.environ.get("BETTY_OPENRSC_MEMORY")
                or os.environ.get("DESKCRAB_PLAYER_MEMORY")
                or Path(__file__).with_name("memory.py"))


def memory_environment() -> dict:
    env = os.environ.copy()
    # Keep hermetic game-player roots hermetic. In the live topology the game
    # directory is .../deskcrab/game, so this is the established shared store.
    env.setdefault("DESKCRAB_MEMORY_DIR", str(game_dir().parent / "memory"))
    return env


def recall_activity_memories(activity: str) -> str:
    """Retrieve preparation/transition lessons at the moment they matter."""
    program = memory_program()
    if not program.is_file() or not os.access(program, os.X_OK):
        return ""
    objective = read_objective() or "none"
    query = (
        f"OpenRSC RuneScape preparation before switching to activity {activity}. "
        f"Current objective: {objective}. What equipment, supplies, destination, "
        "route, safety checks, unfinished commitments, prior mistakes, and useful "
        "habits should I apply before beginning?"
    )
    argv = [str(program), "recall-block", "--query", query,
            "--scope", "OpenRSC", "--scope", "RuneScape"]
    if objective != "none":
        argv += ["--scope", objective]
    argv += ["--notes", "8", "--directives", "4", "--episodes", "2",
             "--max-chars", "5000"]
    try:
        result = subprocess.run(
            argv, text=True, capture_output=True, check=False,
            timeout=float(os.environ.get("BETTY_OPENRSC_ACTIVITY_RECALL_TIMEOUT", "8")),
            env=memory_environment())
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


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
    visited = route.get("visited", [])
    if not isinstance(visited, list) or len(visited) > NAVIGATION_VISITED_MAX \
            or any(not isinstance(point, list) or len(point) != 2
                   or not all(isinstance(value, int) for value in point)
                   for point in visited):
        return {"status": "invalid"}
    nonclosing = route.get("nonclosing_legs", 0)
    if not isinstance(nonclosing, int) or nonclosing < 0:
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


def load_movement_trail() -> dict:
    try:
        trail = json.loads(movement_trail_path().read_text())
    except (OSError, json.JSONDecodeError):
        return {"v": 1, "points": []}
    points = trail.get("points") if isinstance(trail, dict) else None
    if not isinstance(trail, dict) or trail.get("v") != 1 \
            or not isinstance(points, list):
        return {"v": 1, "points": []}
    valid = []
    for point in points[-MOVEMENT_TRAIL_MAX_POINTS:]:
        if not isinstance(point, dict) \
                or not isinstance(point.get("x"), int) \
                or not isinstance(point.get("z"), int) \
                or not isinstance(point.get("ts"), int):
            continue
        valid.append({"x": point["x"], "z": point["z"], "ts": point["ts"],
                      "break": point.get("break") is True})
    return {"v": 1, "points": valid}


def record_movement_trail(snap: dict, connected: bool = False) -> None:
    """Remember actual settled/observed tiles, including direct Sol movement.

    Large jumps are portal boundaries, not walkable edges. Backtracking stops
    at the near side so a ladder, stair, or door can be handled semantically.
    """
    if snap.get("logged_in") is not True:
        return
    active_backtrack = load_backtrack()
    if active_backtrack is not None and active_backtrack.get("status") in ("active", "blocked"):
        return
    x, z = snap.get("x"), snap.get("z")
    if not isinstance(x, int) or not isinstance(z, int):
        return
    trail = load_movement_trail()
    points = trail["points"]
    if points and points[-1]["x"] == x and points[-1]["z"] == z:
        return
    is_break = False
    if points:
        distance = max(abs(x - points[-1]["x"]), abs(z - points[-1]["z"]))
        # A verified ACTIONS walk may cover more than twelve tiles while this
        # runner is synchronously observing its receipt. That is still a
        # reversible, connected edge. Unexplained jumps are stair/ladder/
        # portal boundaries and must never be guessed across as a walk.
        is_break = not connected and distance > MOVEMENT_TRAIL_BREAK_DISTANCE
    points.append({"x": x, "z": z, "ts": int(snap.get("ts") or now_ms()),
                   "break": is_break})
    trail["points"] = points[-MOVEMENT_TRAIL_MAX_POINTS:]
    game_dir().mkdir(parents=True, exist_ok=True)
    game_reflex.atomic_write(movement_trail_path(), json.dumps(trail) + "\n")


def rewind_movement_trail(x: int, z: int) -> None:
    """Make a successful reverse step the new end of known history.

    Without truncation, the next ordinary poll would append the recovered
    position after the abandoned branch and a later backtrack could walk the
    same wrong turn forward again.
    """
    trail = load_movement_trail()
    points = trail["points"]
    match = next((index for index in range(len(points) - 1, -1, -1)
                  if points[index]["x"] == x and points[index]["z"] == z), None)
    if match is None:
        return
    trail["points"] = points[:match + 1]
    game_reflex.atomic_write(movement_trail_path(), json.dumps(trail) + "\n")


def load_backtrack():
    try:
        request = json.loads(backtrack_path().read_text())
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError):
        return {"status": "invalid"}
    points = request.get("points") if isinstance(request, dict) else None
    if not isinstance(request, dict) or request.get("v") != 1 \
            or not isinstance(request.get("objective"), str) \
            or request.get("status") not in ("active", "blocked") \
            or not isinstance(request.get("index"), int) \
            or not isinstance(points, list) or not points:
        return {"status": "invalid"}
    if not 0 <= request["index"] <= len(points):
        return {"status": "invalid"}
    if any(not isinstance(point, list) or len(point) != 2
           or not all(isinstance(value, int) for value in point)
           for point in points):
        return {"status": "invalid"}
    return request


def save_backtrack(request: dict) -> None:
    game_dir().mkdir(parents=True, exist_ok=True)
    game_reflex.atomic_write(backtrack_path(), json.dumps(request, indent=2) + "\n")


def clear_backtrack() -> None:
    try:
        backtrack_path().unlink()
    except FileNotFoundError:
        pass


def prepare_backtrack(snap: dict, objective: str):
    request = load_backtrack()
    if request is None or request.get("status") == "invalid":
        return request
    if request["objective"] != objective:
        clear_backtrack()
        flush_events([{"ts": now_ms(), "kind": "backtrack-cancelled",
                       "reason": "objective-changed", "from": request["objective"],
                       "to": objective}])
        return None
    x, z = snap.get("x"), snap.get("z")
    changed = False
    while request["index"] < len(request["points"]) \
            and request["points"][request["index"]] == [x, z]:
        rewind_movement_trail(x, z)
        request["index"] += 1
        request["status"] = "active"
        changed = True
    if request["index"] >= len(request["points"]):
        clear_backtrack()
        flush_events([{"ts": now_ms(), "kind": "backtrack-complete",
                       "x": x, "z": z, "steps": len(request["points"])}])
        return None
    if changed:
        save_backtrack(request)
    return request


def route_distance(x: int, z: int, route: dict) -> int:
    return max(abs(x - route["x"]), abs(z - route["z"]))


def navigation_distance_sq(x: int, z: int, target_x: int, target_z: int) -> int:
    """Directional progress measure that cannot hide a huge sideways detour."""
    return (x - target_x) ** 2 + (z - target_z) ** 2


def bounded_navigation_leg(x: int, z: int, target_x: int, target_z: int,
                           limit: int = NAVIGATION_LEG_MAX_TILES) -> tuple:
    """Return one human-sized step toward a potentially distant destination.

    The OpenRSC client only owns the currently loaded collision region. Sending
    the far destination directly makes its edge fallback choose and dispatch a
    regional endpoint before the runner can verify whether that endpoint still
    represents the intended direction. Keep every autonomous leg local; an
    unpathable attempted leg then becomes an explicit evidence-gathering point.
    """
    dx, dz = target_x - x, target_z - z
    distance = max(abs(dx), abs(dz))
    if distance <= limit:
        return target_x, target_z
    scale = limit / float(distance)
    leg_x = x + int(round(dx * scale))
    leg_z = z + int(round(dz * scale))
    if leg_x == x and leg_z == z:
        # Defensive only: distance > limit guarantees one dominant component,
        # but never let rounding turn a navigation commitment into an idle tick.
        leg_x += 1 if dx > 0 else -1 if dx < 0 else 0
        leg_z += 1 if dz > 0 else -1 if dz < 0 else 0
    return leg_x, leg_z


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
    blocked = {key: value for key, value in route.items()
               if not key.startswith("detour_")}
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
        elif atype == "cast-npc":
            if not set(action) <= {"type", "spell", "npc", "within", "stationary",
                                   "require_clear_shot", "require_melee_unreachable"} \
                    or not isinstance(action.get("spell"), int) or action["spell"] < 0 \
                    or not isinstance(action.get("npc"), int) or action["npc"] < 0:
                bad(f"{where}: cast-npc takes spell=<spell id>, npc=<type id>, "
                    "and optional within/stationary/terrain guards")
            if "within" in action and (not isinstance(action["within"], int)
                                        or not 0 <= action["within"] <= 10):
                bad(f"{where}: cast-npc within must be an integer 0..10")
            for guard in ("stationary", "require_clear_shot",
                          "require_melee_unreachable"):
                if guard in action and (not isinstance(action[guard], int)
                                        or isinstance(action[guard], bool)
                                        or action[guard] not in (0, 1)):
                    bad(f"{where}: cast-npc {guard} must be 0 or 1")
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


def load_jsonl(path: Path) -> list:
    records = []
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return records
    for line in lines:
        try:
            record = json.loads(line)
        except (ValueError, TypeError):
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


def append_jsonl(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as fh:
        fh.write(json.dumps(record, separators=(",", ":")) + "\n")


def rule_behavior(rule: dict | None) -> dict | None:
    """The executable part of a reflex, excluding prose provenance."""
    if not isinstance(rule, dict):
        return None
    return {key: rule.get(key) for key in (
        "enabled", "priority", "cooldown_ms", "hold_ticks",
        "once_per_objective", "trigger", "action") if key in rule}


def rule_behavior_hash(rule: dict) -> str:
    body = json.dumps(rule_behavior(rule), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(body.encode()).hexdigest()[:16]


def rule_scope_applies(rule: dict, objective: str, activity: str) -> bool:
    trig = rule.get("trigger") or {}
    return (not trig.get("objective_is") or trig.get("objective_is") == objective) \
        and (not trig.get("activity_is") or trig.get("activity_is") == activity)


def activity_rule_snapshot(cfg: dict, objective: str, activity: str) -> list:
    """Compact executable rule set that could affect one activity iteration."""
    rules = []
    for rule in cfg.get("rules") or []:
        if not rule.get("enabled") or not rule_scope_applies(rule, objective, activity):
            continue
        trig = rule.get("trigger") or {}
        rules.append({
            "name": rule.get("name"),
            "behavior": rule_behavior_hash(rule),
            "activity_scope": trig.get("activity_is"),
            "objective_scope": trig.get("objective_is"),
            "action": (rule.get("action") or {}).get("type"),
            "priority": rule.get("priority"),
            "cooldown_ms": rule.get("cooldown_ms"),
        })
    return sorted(rules, key=lambda item: str(item.get("name")))


def current_config_or_empty() -> dict:
    try:
        cfg = json.loads(rules_path().read_text())
        validate_config(cfg)
        cfg.setdefault("unfinished", [])
        return cfg
    except (OSError, ValueError, json.JSONDecodeError):
        return dict(EMPTY_TABLE, defaults=dict(DEFAULTS), rules=[], unfinished=[])


def next_activity_iteration(activity: str) -> int:
    return 1 + sum(1 for record in load_jsonl(activity_history_path())
                   if record.get("activity") == activity)


def activity_metrics_from_stats(stats: dict, ended_ms=None) -> dict:
    if not stats:
        return {}
    end = ended_ms if isinstance(ended_ms, int) else now_ms()
    started = stats.get("started_ms", end)
    elapsed = max(1, end - started) if isinstance(started, int) else 1
    baseline = stats.get("baseline_xp") or {}
    current = stats.get("last_xp") or {}
    names = stats.get("skill_names") or {}
    last_by_id = {str(v.get("id")): v for v in stats.get("last_action_xp") or []
                  if isinstance(v, dict)}
    skills = []
    for key, value in current.items():
        start_xp = baseline.get(key)
        if not isinstance(start_xp, int) or not isinstance(value, int) or value <= start_xp:
            continue
        gained = value - start_xp
        item = {"id": int(key), "name": names.get(key, f"skill-{key}"),
                "gained": gained,
                "xp_per_hour": round(gained * 3600000 / elapsed)}
        if key in last_by_id and isinstance(last_by_id[key].get("xp"), int):
            item["last_action_xp"] = last_by_id[key]["xp"]
        skills.append(item)
    return {
        "activity": stats.get("activity"),
        "objective": stats.get("objective"),
        "iteration": stats.get("iteration"),
        "started_ms": started,
        "elapsed_ms": elapsed,
        "reason": stats.get("reason"),
        "rule_set": stats.get("rule_set") or [],
        "rule_set_hash": stats.get("rule_set_hash"),
        "skills": skills,
    }


def activity_history_summary(activity: str, current: dict = None) -> dict:
    rows = [row for row in load_jsonl(activity_history_path())
            if row.get("activity") == activity]
    eligible = [row for row in rows
                if isinstance(row.get("elapsed_ms"), int)
                and row["elapsed_ms"] >= ACTIVITY_PERFORMANCE_MIN_MS]
    best = {}
    for row in eligible:
        for skill in row.get("skills") or []:
            rate = skill.get("xp_per_hour")
            key = str(skill.get("id"))
            if not isinstance(rate, int) or rate <= 0:
                continue
            if key not in best or rate > best[key]["xp_per_hour"]:
                best[key] = {**skill, "iteration": row.get("iteration"),
                             "elapsed_ms": row.get("elapsed_ms")}
    comparison = []
    if current and current.get("elapsed_ms", 0) >= ACTIVITY_PERFORMANCE_MIN_MS:
        for skill in current.get("skills") or []:
            prior = best.get(str(skill.get("id")))
            if prior:
                comparison.append({"id": skill.get("id"), "name": skill.get("name"),
                                   "xp_per_hour": skill.get("xp_per_hour"),
                                   "best_xp_per_hour": prior["xp_per_hour"],
                                   "delta": skill.get("xp_per_hour", 0)
                                            - prior["xp_per_hour"],
                                   "best_iteration": prior.get("iteration")})
    return {"activity": activity, "iterations": len(rows),
            "latest": rows[-1] if rows else None,
            "best": list(best.values()), "comparison": comparison}


def reusable_rule_candidates(cfg: dict, activity: str, objective: str,
                             snap: dict, limit=8) -> list:
    """Rank old activity-scoped reflexes worth considering as templates.

    These are suggestions, never executable rewrites: the background author
    still needs grounded evidence and the normal test gate before copying one.
    """
    tokens = set(re.findall(r"[a-z0-9]+", activity.lower()))
    candidates = []
    trigger_fn = make_trigger_fn(objective, activity)
    for rule in cfg.get("rules") or []:
        trig = rule.get("trigger") or {}
        source = trig.get("activity_is")
        action = rule.get("action") or {}
        if not source or source == activity or rule.get("once_per_objective") \
                or action.get("type") in ("walk", "retreat"):
            continue
        other = {key: value for key, value in trig.items()
                 if key not in ("activity_is", "objective_is")}
        try:
            live_match = bool(trigger_fn(other, snap, {}))
        except Exception:
            live_match = False
        haystack = " ".join((str(rule.get("name") or ""), source,
                             str(rule.get("note") or ""))).lower()
        overlap = sum(1 for token in tokens if token in haystack)
        if not live_match and not overlap:
            continue
        score = (50 if live_match else 0) + overlap * 20 \
            + (6 if trig.get("objective_is") == objective else 0) \
            + (2 if rule.get("enabled") else 0)
        candidates.append({
            "name": rule.get("name"), "source_activity": source,
            "enabled": bool(rule.get("enabled")), "score": score,
            "live_non_scope_match": live_match,
            "trigger_template": other, "action": action,
            "note": str(rule.get("note") or "")[:240],
        })
    candidates.sort(key=lambda item: (-item["score"], str(item.get("name"))))
    return candidates[:limit]


def activity_briefing(cfg: dict, activity: str, snap: dict) -> dict:
    objective = read_objective()
    return {
        "activity": activity, "objective": objective or None,
        "current_rules": [item["name"] for item in
                          activity_rule_snapshot(cfg, objective, activity)],
        "reuse_candidates": reusable_rule_candidates(
            cfg, activity, objective, snap),
        "history": activity_history_summary(activity),
    }


def start_activity_stats(activity: str, snap: dict, started_ms=None,
                         reason="selected", cfg: dict = None) -> dict:
    """Start one comparable activity/reflex iteration from grounded XP."""
    skills = snapshot_skills(snap)
    if not activity or not skills_ready(skills):
        return {}
    started = started_ms if isinstance(started_ms, int) else now_ms()
    cfg = cfg or current_config_or_empty()
    objective = read_objective()
    rule_set = activity_rule_snapshot(cfg, objective, activity)
    stats = {
        "v": 3,
        "activity": activity,
        "objective": objective or None,
        "iteration": next_activity_iteration(activity),
        "reason": reason,
        "started_ms": started,
        "baseline_ready": True,
        "baseline_xp": {key: val["xp"] for key, val in skills.items()},
        "last_xp": {key: val["xp"] for key, val in skills.items()},
        "skill_names": {key: val["name"] for key, val in skills.items()},
        "last_action_xp": [],
        "updated_ms": started,
        "last_review_ms": started,
        "last_review_gained": 0,
        "rule_set": rule_set,
        "rule_set_hash": hashlib.sha256(json.dumps(
            rule_set, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16],
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
    return activity_metrics_from_stats(stats)


def activity_xp_metrics_text(metrics: dict) -> str:
    parts = []
    for skill in metrics.get("skills") or []:
        fields = []
        if skill.get("last_action_xp", 0) > 0:
            fields.append(f"+{skill['last_action_xp']}/action")
        fields.extend((f"+{skill['gained']}_total", f"{skill['xp_per_hour']}/hr"))
        parts.append(f"{skill['name']}:" + ",".join(fields))
    return ";".join(parts)


def activity_xp_text(snap: dict, activity: str) -> str:
    return activity_xp_metrics_text(activity_metrics(snap, activity))


def activity_comparison_text(metrics: dict) -> str:
    if not metrics or metrics.get("elapsed_ms", 0) < ACTIVITY_PERFORMANCE_MIN_MS:
        return ""
    comparison = activity_history_summary(
        metrics.get("activity") or "", metrics).get("comparison") or []
    return ";".join(
        f"{item['name']}:{item['xp_per_hour']}/hr_vs_best_"
        f"{item['best_xp_per_hour']}/hr,delta={item['delta']:+d}"
        for item in comparison)


def finish_activity_iteration(reason: str, snap: dict = None,
                              queue_review=True) -> dict:
    stats = load_activity_stats()
    if not stats:
        return {}
    activity = stats.get("activity") or ""
    if snap and activity and stats.get("activity") == activity \
            and skills_ready(snapshot_skills(snap)):
        stats = refresh_activity_stats(snap, activity)
    ended = now_ms()
    record = {"v": 1, "kind": "activity-iteration", "ended_ms": ended,
              "end_reason": reason,
              **activity_metrics_from_stats(stats, ended)}
    prior = activity_history_summary(activity, record)
    record["comparison"] = prior.get("comparison") or []
    record["performance_eligible"] = (
        record.get("elapsed_ms", 0) >= ACTIVITY_PERFORMANCE_MIN_MS
        and any(skill.get("gained", 0) > 0 for skill in record.get("skills") or []))
    append_jsonl(activity_history_path(), record)
    if queue_review:
        append_outcome({
            "ts": ended, "kind": "activity-iteration",
            "activity": activity or None, "objective": record.get("objective"),
            "iteration": record.get("iteration"), "end_reason": reason,
            "performance": {key: record.get(key) for key in
                            ("elapsed_ms", "skills", "comparison",
                             "performance_eligible", "rule_set_hash")},
            "rules": record.get("rule_set") or [],
        })
    clear_activity_stats()
    return record


def maybe_queue_activity_checkpoint(metrics: dict, cfg: dict,
                                    objective: str, activity: str) -> None:
    if not metrics or metrics.get("elapsed_ms", 0) < ACTIVITY_REVIEW_INTERVAL_MS \
            or not metrics.get("skills"):
        return
    stats = load_activity_stats()
    now = now_ms()
    total = sum(skill.get("gained", 0) for skill in metrics.get("skills") or [])
    if now - stats.get("last_review_ms", stats.get("started_ms", now)) \
            < ACTIVITY_REVIEW_INTERVAL_MS \
            or total <= stats.get("last_review_gained", 0):
        return
    stats["last_review_ms"] = now
    stats["last_review_gained"] = total
    game_reflex.atomic_write(activity_stats_path(), json.dumps(stats, indent=2) + "\n")
    append_outcome({
        "ts": now, "kind": "activity-checkpoint", "activity": activity,
        "objective": objective or None, "iteration": metrics.get("iteration"),
        "performance": metrics,
        "comparison": activity_history_summary(activity, metrics).get("comparison") or [],
        "rules": activity_rule_snapshot(cfg, objective, activity),
    })


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
    est.setdefault("seen_friend_status_ids", [])
    est.setdefault("pending_friend_status", [])
    est.setdefault("session_top_up_message_ids", [])
    est.setdefault("recent_repetitions", [])
    est.setdefault("reported_repetitions", {})
    est.setdefault("repetition_holds", [])
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


def top_up_session_from_player_messages(snap: dict, est: dict,
                                        events: list) -> dict:
    """Give a live sitting twenty playable minutes after genuine player chat.

    Conversation capture and timer credit have separate id ledgers. That is
    intentional: a long-lived runner from the previous code generation may
    already have captured the conversation before a new model-facing `play`
    loads this feature. Pending messages therefore remain enough evidence to
    grant the top-up exactly once after a hot upgrade.
    """
    credited = set(est.get("session_top_up_message_ids") or [])
    messages = []
    sources = list(snap.get("messages") or []) + list(est.get("pending_messages") or [])
    for message in sources:
        if not isinstance(message, dict) or message.get("incoming") is not True \
                or message.get("channel") not in ("local", "private"):
            continue
        message_id = message.get("id")
        if not isinstance(message_id, int) or message_id in credited:
            continue
        sender = str(message.get("sender") or "").strip()
        text = str(message.get("text") or "").strip()
        if not sender or not text:
            continue
        credited.add(message_id)
        messages.append({"id": message_id, "sender": sender[:80],
                         "channel": message.get("channel")})
    est["session_top_up_message_ids"] = sorted(credited)[-500:]
    if not messages:
        return {}

    now = now_ms()
    with session_state_lock():
        session = read_session()
        if not session or session.get("ended"):
            return {}
        started = int(session["started"])
        old_limit = int(session.get("limit_ms") or SESSION_LIMIT_MS)
        old_deadline = started + old_limit
        remaining = old_deadline - now
        if remaining >= SESSION_MESSAGE_TOP_UP_MS:
            return {}
        new_deadline = now + SESSION_MESSAGE_TOP_UP_MS
        session["limit_ms"] = new_deadline - started
        session["last_message_top_up"] = {
            "at": now, "message_ids": [item["id"] for item in messages],
            "senders": sorted({item["sender"] for item in messages}),
        }
        game_reflex.atomic_write(session_path(), json.dumps(session) + "\n")

    event = {
        "ts": now, "kind": "session-message-top-up",
        "message_ids": [item["id"] for item in messages],
        "senders": sorted({item["sender"] for item in messages}),
        "remaining_before_ms": max(0, remaining),
        "old_deadline_ms": old_deadline,
        "new_deadline_ms": new_deadline,
        "play_minutes": SESSION_MESSAGE_TOP_UP_MS // 60000,
    }
    events.append(event)
    est["last_session_top_up"] = event
    return event


def message_batch_session_renewal(est: dict, batch: list) -> str:
    """Name an automatic renewal belonging to the pending chat verdict.

    The resident runner usually credits the message before the model-facing
    `play` call reads its heartbeat, so the immediate return value from the
    top-up function is not a reliable notification channel. The durable
    engine-state event is. Tie it to message ids so an old renewal is never
    presented alongside an unrelated later conversation.
    """
    renewal = est.get("last_session_top_up") or {}
    renewed_ids = set(renewal.get("message_ids") or [])
    batch_ids = {item.get("id") for item in batch if isinstance(item, dict)}
    if not renewed_ids.intersection(batch_ids):
        return ""
    minutes = renewal.get("play_minutes") or SESSION_MESSAGE_TOP_UP_MS // 60000
    return f"{minutes}m-cancel-wind-down"


def capture_friend_status(snap: dict, est: dict, events: list) -> int:
    """Keep authoritative friend login/logout transitions until Sol sees them.

    The client emits this channel only for an actual status transition, not
    while loading the initial friend list. It therefore needs no inference
    from nearby players and cannot announce everyone at login.
    """
    seen = set(est.get("seen_friend_status_ids") or [])
    pending = est.get("pending_friend_status") or []
    captured = 0
    captured_at = now_ms()
    for message in snap.get("messages") or []:
        if not isinstance(message, dict) or message.get("channel") != "friend-status":
            continue
        message_id = message.get("id")
        text = " ".join(str(message.get("text", "")).split())
        if not isinstance(message_id, int) or message_id in seen:
            continue
        match = FRIEND_STATUS_RE.fullmatch(text)
        if not match or not match.group(1).strip():
            # Remember the id even when a future server wording is unknown;
            # repeated snapshots must not keep reparsing one malformed event.
            seen.add(message_id)
            continue
        item = {
            "id": message_id,
            "name": match.group(1).strip()[:80],
            "status": "online" if match.group(2).casefold() == "in" else "offline",
            "text": text[:240],
            "captured_ts": captured_at,
        }
        pending.append(item)
        seen.add(message_id)
        captured += 1
        events.append({"ts": captured_at, "kind": "friend-status-received", **item})
    est["pending_friend_status"] = sorted(pending, key=lambda item: item["id"])[-20:]
    est["seen_friend_status_ids"] = sorted(seen)[-500:]
    return captured


def pending_friend_status(est: dict) -> list:
    return sorted((item for item in est.get("pending_friend_status") or []
                   if isinstance(item, dict) and isinstance(item.get("id"), int)),
                  key=lambda item: item["id"])


def friend_status_text(items: list) -> str:
    return json.dumps([
        {"id": item["id"], "name": item.get("name"), "status": item.get("status")}
        for item in items
    ], separators=(",", ":"), ensure_ascii=False)


def acknowledge_friend_status(items: list) -> None:
    """A model-facing `play` printed these exact events; retire only those ids."""
    ids = {item.get("id") for item in items if isinstance(item, dict)}
    if not ids:
        return
    with player_state_lock():
        est = load_player_state()
        est["pending_friend_status"] = [
            item for item in est.get("pending_friend_status") or []
            if not isinstance(item, dict) or item.get("id") not in ids
        ]
        save_player_state(est)


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
    if condition == "ui_panel_open":
        return snap.get("ui_panel_open") is True
    if condition == "ui_panel_closed":
        return snap.get("ui_panel_open") is False
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
                "right_click_menu_open", "ui_panel_open", "ui_panel",
                "trade_open", "sleeping", "fatigue"):
        value = snap.get(key)
        if isinstance(value, bool):
            value = str(value).lower()
        parts.append(f"{key}:{value}")
    return ",".join(parts)


def _inventory_totals(snap: dict) -> dict:
    totals = {}
    for entry in snap.get("inventory") or []:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), int):
            continue
        count = entry.get("count", entry.get("amount", 1))
        if not isinstance(count, int):
            continue
        key = str(entry["id"])
        current = totals.setdefault(key, {"count": 0, "name": ""})
        current["count"] += count
        if entry.get("name"):
            current["name"] = " ".join(str(entry["name"]).split())[:80]
    return totals


def _skill_totals(snap: dict) -> dict:
    totals = {}
    for skill in snap.get("skills") or []:
        if not isinstance(skill, dict) or not isinstance(skill.get("id"), int) \
                or not isinstance(skill.get("xp"), int):
            continue
        totals[str(skill["id"])] = {
            "xp": skill["xp"],
            "name": " ".join(str(skill.get("name") or f"skill-{skill['id']}").split())[:80],
        }
    return totals


def _message_ids(snap: dict) -> list:
    return [message["id"] for message in snap.get("messages") or []
            if isinstance(message, dict) and isinstance(message.get("id"), int)]


def _spell_rune_ids(snap: dict, spell_id: int) -> list:
    spell = next((entry for entry in snap.get("spells") or []
                  if isinstance(entry, dict) and entry.get("id") == spell_id), None)
    if spell is None:
        return []
    return [rune["id"] for rune in spell.get("runes") or []
            if isinstance(rune, dict) and isinstance(rune.get("id"), int)]


def make_action_observation(action_id: int, action_type: str, fields: list,
                            snap: dict, sent_ts: int = None) -> dict:
    parsed = dict(field.split("=", 1) for field in fields
                  if isinstance(field, str) and "=" in field)
    try:
        spell_id = int(parsed.get("spell", ""))
    except ValueError:
        spell_id = -1
    return {
        "v": 1, "id": action_id, "type": action_type,
        "sent_ts": sent_ts if isinstance(sent_ts, int) else now_ms(),
        "fields": list(fields),
        "baseline": {
            "ts": snap.get("ts"), "tick": snap.get("tick"),
            "x": snap.get("x"), "z": snap.get("z"),
            "walking": snap.get("walking"),
            "talking_to_npc": snap.get("talking_to_npc"),
            "right_click_menu_open": snap.get("right_click_menu_open"),
            "ui_panel_open": snap.get("ui_panel_open"),
            "ui_panel": snap.get("ui_panel"),
            "trade_open": snap.get("trade_open"),
            "bank_open": snap.get("bank_open"),
            "shop_open": snap.get("shop_open"),
            "sleeping": snap.get("sleeping"),
            "inventory": _inventory_totals(snap),
            "skills": _skill_totals(snap),
            "message_ids": _message_ids(snap),
            "spell_runes": _spell_rune_ids(snap, spell_id),
        },
    }


def cmd_action_arm(args):
    """Remember the state immediately before a direct bridge action.

    This is an internal door used by orsc-headless.sh. It gives a later
    `wait-until action_done` the causal baseline that an after-the-fact wait
    cannot reconstruct.
    """
    snap = game_reflex.read_snapshot() or {}
    observation = make_action_observation(args.id, args.type, list(args.fields), snap)
    state_dir().mkdir(parents=True, exist_ok=True)
    game_reflex.atomic_write(action_observation_path(), json.dumps(observation) + "\n")
    report("action-armed", id=args.id, type=args.type)


def load_action_observation():
    try:
        observation = json.loads(action_observation_path().read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(observation, dict) or observation.get("v") != 1 \
            or not isinstance(observation.get("id"), int) \
            or not isinstance(observation.get("type"), str) \
            or not isinstance(observation.get("sent_ts"), int) \
            or not isinstance(observation.get("baseline"), dict):
        return None
    return observation


def action_completion(observation: dict, snap: dict):
    """Return grounded postcondition details, or None while still unresolved."""
    if not isinstance(snap, dict) or snap.get("logged_in") is not True \
            or not isinstance(snap.get("ts"), int) \
            or now_ms() - snap["ts"] > WAIT_SNAPSHOT_FRESH_MS:
        return None
    before = observation["baseline"]
    newer = snap.get("tick") != before.get("tick") \
        or (isinstance(before.get("ts"), int) and snap["ts"] > before["ts"])
    if not newer:
        return None

    inventory_changes = []
    changed_item_ids = set()
    current_inventory = _inventory_totals(snap)
    old_inventory = before.get("inventory") or {}
    for item in sorted(set(old_inventory) | set(current_inventory), key=int):
        old = (old_inventory.get(item) or {}).get("count", 0)
        new = (current_inventory.get(item) or {}).get("count", 0)
        if new == old:
            continue
        name = (current_inventory.get(item) or old_inventory.get(item) or {}).get("name") or item
        inventory_changes.append(f"{name}({item}):{new - old:+d}")
        changed_item_ids.add(item)

    xp_changes = []
    changed_skill_ids = set()
    current_skills = _skill_totals(snap)
    old_skills = before.get("skills") or {}
    for skill in sorted(set(old_skills) & set(current_skills), key=int):
        old = (old_skills.get(skill) or {}).get("xp")
        new = (current_skills.get(skill) or {}).get("xp")
        if not isinstance(old, int) or not isinstance(new, int) or new == old:
            continue
        name = (current_skills.get(skill) or {}).get("name") or skill
        xp_changes.append(f"{name}:{new - old:+d}")
        changed_skill_ids.add(skill)

    old_message_ids = set(before.get("message_ids") or [])
    new_messages = [message for message in snap.get("messages") or []
                    if isinstance(message, dict)
                    and isinstance(message.get("id"), int)
                    and message["id"] not in old_message_ids
                    and message.get("channel") in SYSTEM_FEEDBACK_CHANNELS
                    and str(message.get("text", "")).strip()]
    message = " ".join(str(new_messages[-1].get("text", "")).split())[:240] \
        if new_messages else ""

    ui_changes = []
    for key in ("talking_to_npc", "right_click_menu_open", "trade_open",
                "bank_open", "shop_open", "sleeping"):
        if isinstance(snap.get(key), bool) and snap.get(key) != before.get(key):
            ui_changes.append(f"{key}:{str(snap[key]).lower()}")
    moved = isinstance(snap.get("x"), int) and isinstance(snap.get("z"), int) \
        and (snap.get("x"), snap.get("z")) != (before.get("x"), before.get("z"))
    movement_done = observation["type"] in ("walk", "retreat") \
        and moved and snap.get("walking") is False

    failure = bool(message) and any(needle in message.casefold() for needle in (
        "nothing interesting happens", "you can't", "you cannot", "unable to",
        "not enough", "not high enough", "you need", "reagents", "spell fails",
        "can't reach", "cannot reach", "clear shot",
    ))
    completed = bool(inventory_changes or xp_changes or message
                     or ui_changes or movement_done)
    if observation["type"] == "use-item-object":
        # Pane/menu changes were the old two-click race, not evidence that the
        # server used the selected item. A furnace's start line also precedes
        # the bar. Ground success in its input changing or XP; only explicit
        # failure feedback may terminate it without either delta.
        fields = dict(field.split("=", 1) for field in observation.get("fields", [])
                      if isinstance(field, str) and "=" in field)
        completed = bool(fields.get("item") in changed_item_ids
                         or xp_changes or failure)
    if observation["type"] == "cast-npc":
        rune_ids = {str(item) for item in before.get("spell_runes") or []}
        magic_ids = {skill_id for skill_id, skill in current_skills.items()
                     if str(skill.get("name", "")).casefold() == "magic"}
        spell_message = bool(message) and any(needle in message.casefold() for needle in (
            "spell", "reagent", "magic ability", "you need to wait",
        ))
        completed = bool(changed_item_ids & rune_ids
                         or changed_skill_ids & magic_ids
                         or spell_message or failure)
    if not completed:
        return None
    return {
        "result": "failed" if failure else "done",
        "inventory": ",".join(inventory_changes) or None,
        "xp": ",".join(xp_changes) or None,
        "message": message or None,
        "state": ",".join(ui_changes) or ("movement-settled" if movement_done else None),
    }


def await_action_completion(observation: dict, timeout: float):
    deadline = time.monotonic() + timeout
    latest = None
    with SnapshotChangeWatch() as watch:
        while True:
            latest = game_reflex.read_snapshot()
            completion = action_completion(observation, latest)
            if completion is not None:
                return completion, latest
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None, latest
            watch.wait(remaining)


def cmd_wait_action_done(args):
    observation = load_action_observation()
    if observation is None:
        report("action-unarmed", next="perform-one-bridge-action-first")
        sys.exit(EXIT_NOT_READY)
    if now_ms() - observation["sent_ts"] > WAIT_MAX_S * 1000:
        try:
            action_observation_path().unlink()
        except FileNotFoundError:
            pass
        report("action-unarmed", reason="expired",
               next="perform-one-bridge-action-first")
        sys.exit(EXIT_NOT_READY)
    completion, latest = await_action_completion(observation, args.timeout)
    if completion is not None:
        try:
            action_observation_path().unlink()
        except FileNotFoundError:
            pass
        report("action-done", id=observation["id"], type=observation["type"],
               **completion)
        return
    record_wait_failure("action_done", "timeout", latest or {}, args.timeout)
    report("action-timeout", id=observation["id"],
           type=observation["type"], timeout=f"{args.timeout:g}",
           state=wait_state_brief(latest))
    sys.exit(EXIT_NOT_DONE)


def cmd_wait_until(args):
    condition = normalise_wait_condition(args.condition)
    if not 0 < args.timeout <= WAIT_MAX_S:
        die(f"wait timeout must be greater than 0 and no more than {WAIT_MAX_S:g} seconds")
    if condition == "action_done":
        return cmd_wait_action_done(args)
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
    """One bounded escape commitment. The resident runner owns it when
    present; otherwise this process uses the identical rules-first step path.
    A momentary out-of-combat snapshot is only the midpoint: completion also
    requires verified distance from the combat origin and nearby aggressors."""
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
            or now_ms() - snap.get("ts", 0) > WAIT_SNAPSHOT_FRESH_MS \
            or not isinstance(snap.get("x"), int) \
            or not isinstance(snap.get("z"), int):
        report("retreat-not-ready", state=wait_state_brief(snap))
        sys.exit(EXIT_NOT_READY)
    if snap.get("in_combat") is False:
        clear_retreat_request()
        report("retreated", status="already-safe", x=snap.get("x"), z=snap.get("z"))
        return

    dx, dz = choose_retreat_direction(snap, args.dx, args.dz)
    expires = now_ms() + int(args.timeout * 1000)
    request = {"v": 2, "requested": now_ms(), "expires": expires,
               "distance": args.distance, "dx": dx, "dz": dz,
               "origin_x": snap["x"], "origin_z": snap["z"],
               "clearance": RETREAT_CLEARANCE_TILES}
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
            if retreat_has_clearance(latest, request):
                clear_retreat_request()
                report("retreated", status="clear", tick=latest.get("tick"),
                       x=latest.get("x"), z=latest.get("z"),
                       origin=f"({request['origin_x']},{request['origin_z']})",
                       clearance=request["clearance"])
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                clear_retreat_request()
                record_wait_failure("out_of_combat", "retreat-timeout", latest,
                                    args.timeout)
                lx, lz = latest.get("x"), latest.get("z")
                moved = max(abs(lx - request["origin_x"]),
                            abs(lz - request["origin_z"])) \
                    if isinstance(lx, int) and isinstance(lz, int) else "unknown"
                report("retreat-timeout", timeout=f"{args.timeout:g}",
                       moved=moved,
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
    reachable = [entry for entry in matches if entry.get("reachable") is not False]
    if not reachable:
        door_entry = next((entry for entry in matches
                           if isinstance(entry.get("door"), dict)), None)
        if door_entry is not None:
            door = door_entry["door"]
            next_action = "bound-{x}-{z}-{dir}-{id}-{cmd}".format(**door)
            report("take-needs-door", item=args.item,
                   x=door_entry["x"], z=door_entry["z"],
                   door=door.get("name") or door.get("id"),
                   door_x=door.get("x"), door_z=door.get("z"),
                   door_dir=door.get("dir"), door_cmd=door.get("cmd"),
                   next=next_action)
        else:
            report("take-unreachable", item=args.item,
                   reason="collision-path-unavailable", next="choose-other-work")
        sys.exit(EXIT_NOT_DONE)

    def route_key(entry):
        distance = entry.get("path_distance")
        if isinstance(distance, int) and distance >= 0:
            return (0, distance)
        return (1, max(abs(entry["x"] - px), abs(entry["z"] - pz)))

    target = min(reachable, key=route_key)
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


def nearest_npc(snap: dict, wanted: int, predicate=None):
    """Choose by actual walking steps, independently of snapshot list order."""
    px, pz = snap.get("x"), snap.get("z")
    if not isinstance(px, int) or not isinstance(pz, int):
        return None
    candidates = [npc for npc in snap.get("npcs") or []
                  if npc.get("id") == wanted
                  and all(isinstance(npc.get(key), int)
                          for key in ("sidx", "x", "z"))
                  and (predicate is None or predicate(npc))]
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
    if action["type"] == "cast-npc":
        spell_id = action["spell"]
        spell = next((entry for entry in snap.get("spells") or []
                      if entry.get("id") == spell_id), None)
        if spell is None:
            return None, "spell-state-unavailable"
        if spell.get("target") != "npc/player":
            return None, "spell-target-not-npc"
        if spell.get("ready") is not True:
            return None, "spell-not-ready"
        want = action["npc"]
        within = action.get("within")
        px, pz = snap.get("x"), snap.get("z")
        require_clear = action.get("require_clear_shot") == 1
        require_unreachable = action.get("require_melee_unreachable") == 1
        npc = nearest_npc(
            snap, want,
            lambda candidate: (
                (not require_clear or candidate.get("clear_shot") is True)
                and (not require_unreachable
                     or candidate.get("terrain_melee_reachable") is False)))
        if npc is not None:
            distance = max(abs(px - npc["x"]), abs(pz - npc["z"]))
            if within is not None and distance > within:
                return None, "npc-not-within-range"
            extra = {"spell": spell_id, "target_distance": distance}
            if within is not None:
                extra["within"] = within
            for guard in ("stationary", "require_clear_shot",
                          "require_melee_unreachable"):
                if action.get(guard) == 1:
                    extra[guard] = 1
            return compiled_npc_action("cast-npc", npc, want, **extra), None
        if require_clear or require_unreachable:
            return None, "npc-terrain-guards-not-met"
        return None, "npc-not-within-range" if within is not None else "npc-not-visible"
    if action["type"] == "walk":
        compiled = {"type": "walk", "x": action["x"], "z": action["z"]}
        if isinstance(action.get("arrive"), int):
            compiled["arrive"] = action["arrive"]
        # Internal durable-route legs carry a collision-path budget. It does
        # not limit the distant destination: it prevents one nearby waypoint
        # from silently expanding into a long walk in the opposite direction.
        if isinstance(action.get("max_path"), int):
            compiled["max_path"] = action["max_path"]
        if isinstance(action.get("route_step"), int):
            compiled["route_step"] = action["route_step"]
        return compiled, None
    if action["type"] == "retreat":
        if snap.get("in_combat") is not True:
            return None, "already-out-of-combat"
        compiled = {"type": "retreat", "distance": action.get("distance", 5),
                    "dx": action.get("dx", 0), "dz": action.get("dz", 1)}
        if action.get("committed_direction") == 1:
            compiled["committed_direction"] = 1
        return compiled, None
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
        blocked = False
        for bnd in snap.get("bounds") or []:     # already nearest-first
            if bnd.get("id") == want and isinstance(bnd.get("x"), int) \
                    and isinstance(bnd.get("z"), int):
                if bnd.get("reachable") is False:
                    blocked = True
                    continue
                return {"type": "interact-bound", "x": bnd["x"], "z": bnd["z"],
                        "dir": bnd.get("dir", 0), "obj": want,
                        "cmd": action.get("cmd", 1)}, None
        return None, "bound-unreachable" if blocked else "bound-not-loaded"
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
        matching = []
        blocked = []
        for item in snap.get("ground_items") or []:
            if item.get("id") == want and isinstance(item.get("x"), int) \
                    and isinstance(item.get("z"), int):
                if within is not None and (
                        not isinstance(px, int) or not isinstance(pz, int)
                        or max(abs(px - item["x"]), abs(pz - item["z"])) > within):
                    continue
                if item.get("reachable") is False:
                    blocked.append(item)
                else:
                    matching.append(item)
        if matching:
            def route_key(item):
                distance = item.get("path_distance")
                if isinstance(distance, int) and distance >= 0:
                    return (0, distance)
                if isinstance(px, int) and isinstance(pz, int):
                    return (1, max(abs(px - item["x"]), abs(pz - item["z"])))
                return (2, 0)

            item = min(matching, key=route_key)
            return {"type": "take-ground", "x": item["x"], "z": item["z"],
                    "item": want}, None
        if blocked:
            return None, "ground-item-needs-door" \
                if any(isinstance(item.get("door"), dict) for item in blocked) \
                else "ground-item-unreachable"
        return None, "ground-item-not-within-range" if within is not None \
            else "ground-item-not-visible"
    return None, f"unknown-action-{action['type']}"


def emit_player_action(path_name: str, action: dict, action_id: int, ts: int) -> None:
    lines = [f"ts={ts}", f"id={action_id}", f"type={action['type']}"]
    for key in ("kind", "sidx", "npc", "spell", "x", "z", "arrive", "max_path", "route_step", "dir", "obj", "cmd", "within",
                "stationary", "require_clear_shot", "require_melee_unreachable",
                "item", "button",
                "distance", "dx", "dz", "committed_direction",
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
                                      "right_click_menu_open", "ui_panel_open", "ui_panel",
                                      "hover_text",
                                      "magic_level", "selected_spell")}
    brief["ready_spells"] = [
        {key: spell.get(key) for key in ("id", "name", "target")}
        for spell in snap.get("spells") or [] if spell.get("ready") is True
    ]
    brief["inventory"] = [i.get("id") for i in snap.get("inventory") or []]
    brief["messages"] = (snap.get("messages") or [])[-5:]
    brief["players"] = (snap.get("players") or [])[:24]
    brief["npcs"] = (snap.get("npcs") or [])[:12]
    brief["objects"] = (snap.get("objects") or [])[:12]
    brief["bounds"] = (snap.get("bounds") or [])[:12]
    terrain = snap.get("terrain") or {}
    brief["terrain"] = {
        "radius": terrain.get("radius"),
        "blocked_cells": (terrain.get("blocked_cells") or [])[:48],
        "barriers": (terrain.get("barriers") or [])[:64],
    }
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
        "ui_panel": snap.get("ui_panel"),
        "inventory": [i.get("id") for i in snap.get("inventory") or []],
        "messages": game_messages,
        "npcs": sorted(n.get("id") for n in snap.get("npcs") or []
                       if isinstance(n, dict) and isinstance(n.get("id"), int)),
        "objects": sorted((o.get("id"), o.get("x"), o.get("z"))
                          for o in snap.get("objects") or []
                          if isinstance(o, dict) and isinstance(o.get("id"), int)),
        "bounds": sorted((b.get("id"), b.get("x"), b.get("z"), b.get("dir"),
                          b.get("reachable"), b.get("path_distance"), b.get("open_command"))
                         for b in snap.get("bounds") or []
                         if isinstance(b, dict) and isinstance(b.get("id"), int)),
        "ground_items": sorted((i.get("id"), i.get("x"), i.get("z"),
                                i.get("reachable"), i.get("path_distance"),
                                (i.get("door") or {}).get("id"),
                                (i.get("door") or {}).get("x"),
                                (i.get("door") or {}).get("z"))
                               for i in snap.get("ground_items") or []
                               if isinstance(i, dict) and isinstance(i.get("id"), int)),
    }
    return json.dumps(shape, sort_keys=True, separators=(",", ":"))


def append_outcome(record: dict) -> None:
    path = queue_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as fh:
        fh.write(json.dumps(record, separators=(",", ":")) + "\n")


def rule_fingerprint(rule: dict) -> str:
    """Stable authored-rule identity; evaluator-only fields do not count."""
    return json.dumps({key: value for key, value in rule.items() if key != "channel"},
                      sort_keys=True, separators=(",", ":"))


def reflex_changes(before: dict, after: dict) -> list:
    old = {rule["name"]: rule for rule in before.get("rules") or []}
    new = {rule["name"]: rule for rule in after.get("rules") or []}
    changes = []
    for name in sorted(set(old) | set(new)):
        if old.get(name) == new.get(name):
            continue
        changes.append({
            "name": name,
            "operation": "created" if name not in old else
                         "removed" if name not in new else "updated",
            "behavior_changed": rule_behavior(old.get(name)) != rule_behavior(new.get(name)),
            "before": old.get(name), "after": new.get(name),
        })
    return changes


def save_config_change(before: dict, after: dict, doing: str) -> None:
    """Persist one authored mutation and bracket comparable XP iterations."""
    validate_config(after)
    changes = reflex_changes(before, after)
    if not changes:
        save_config(after)
        return
    activity = read_activity()
    objective = read_objective()
    snap = game_reflex.read_snapshot() or {}
    relevant = any(
        change.get("behavior_changed") and (
            (isinstance(change.get("before"), dict)
             and change["before"].get("enabled")
             and rule_scope_applies(change["before"], objective, activity))
            or (isinstance(change.get("after"), dict)
                and change["after"].get("enabled")
                and rule_scope_applies(change["after"], objective, activity)))
        for change in changes) if activity else False
    performance_before = finish_activity_iteration(
        f"reflex-change:{doing}", snap, queue_review=False) if relevant else {}
    save_config(after)
    append_jsonl(reflex_history_path(), {
        "v": 1, "ts": now_ms(), "kind": "reflex-change", "doing": doing,
        "objective": objective or None, "activity": activity or None,
        "relevant_to_activity": relevant, "changes": changes,
        "performance_before": performance_before or None,
    })
    if relevant:
        start_activity_stats(activity, snap, reason=f"reflex-change:{doing}", cfg=after)


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
            or outcome.get("rule") in (
                ROUTE_RULE_NAME, BACKTRACK_RULE_NAME, MANUAL_RETREAT_RULE_NAME):
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
    fingerprint = rule_fingerprint(rule)
    holds = [hold for hold in est.get("repetition_holds") or []
             if isinstance(hold, dict) and isinstance(hold.get("until"), int)
             and hold["until"] > now
             and not (hold.get("rule") == outcome.get("rule")
                      and hold.get("objective") == outcome.get("objective")
                      and hold.get("activity") == outcome.get("activity"))]
    holds.append({"rule": outcome.get("rule"),
                  "objective": outcome.get("objective"),
                  "activity": outcome.get("activity"),
                  "fingerprint": fingerprint,
                  "until": now + REPETITION_REVIEW_HOLD_MS})
    est["repetition_holds"] = holds[-16:]
    return {"ts": now, "kind": "loop-candidate", "rule": outcome.get("rule"),
            "objective": outcome.get("objective"), "activity": outcome.get("activity"),
            "action": identity, "count": len(matches),
            "span_ms": now - matches[0]["ts"],
            "activity_scoped": "activity_is" in (rule.get("trigger") or {}),
            "review_hold_ms": REPETITION_REVIEW_HOLD_MS,
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
                    activity: str = "", activity_xp: str = "",
                    activity_compare: str = "", friend_updates=None) -> None:
    game_reflex.atomic_write(runner_path(), json.dumps(
        {"pid": os.getpid(), "ts": now_ms(),
         "verdict": verdict, "detail": detail,
         "ground_items": ground_items or [],
         "activity": activity or None,
         "activity_xp": activity_xp or None,
         "activity_compare": activity_compare or None,
         "friend_updates": friend_updates or []}) + "\n")


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
    record_movement_trail(snap)
    xp_metrics = activity_metrics(snap, activity)
    xp_text = activity_xp_metrics_text(xp_metrics)
    xp_compare = activity_comparison_text(xp_metrics)
    maybe_queue_activity_checkpoint(xp_metrics, cfg, objective, activity)
    # The sleep screen owns keyboard input and blocks ordinary play. Never let
    # an old objective, route, reflex, or queued reply pretend it can proceed
    # until the current word has been solved and live state says awake.
    if snap.get("logged_in") is True and snap.get("sleeping") is True:
        friend_events = []
        with player_state_lock():
            sleeping_state = load_player_state()
            capture_player_messages(snap, sleeping_state, friend_events)
            top_up_session_from_player_messages(
                snap, sleeping_state, friend_events)
            capture_friend_status(snap, sleeping_state, friend_events)
            save_player_state(sleeping_state)
            flush_events(friend_events)
        report("sleeping-needs-wake", fatigue=snap.get("fatigue"),
               sleep_fatigue=snap.get("sleep_fatigue"),
               status=snap.get("sleep_status") or None,
               next="solve-current-word-then-wait-until-not_sleeping")
        return "sleeping-needs-wake", EXIT_NO_RULE
    source_rules = list(cfg["rules"])
    retreat_request = load_retreat_request()
    if retreat_request is not None and retreat_has_clearance(snap, retreat_request):
        clear_retreat_request()
        retreat_request = None
    if retreat_request is not None:
        if snap.get("in_combat") is True:
            retreat_action = {"type": "retreat",
                              "distance": retreat_request["distance"],
                              "dx": retreat_request["dx"],
                              "dz": retreat_request["dz"],
                              "committed_direction": 1}
            retreat_trigger = {"in_combat": True}
            retreat_note = "bounded escape: break the current combat lock"
        else:
            target_x, target_z = retreat_clearance_target(snap, retreat_request)
            retreat_action = {"type": "walk", "x": target_x, "z": target_z,
                              "arrive": 0}
            retreat_trigger = {"out_of_combat": True}
            retreat_note = "bounded escape: clear the whole aggressive pack"
        source_rules.append({
            "name": MANUAL_RETREAT_RULE_NAME, "enabled": True,
            "priority": MANUAL_RETREAT_PRIORITY, "cooldown_ms": 0,
            "hold_ticks": 1, "once_per_objective": False,
            "note": retreat_note, "trigger": retreat_trigger,
            "action": retreat_action,
        })
    backtrack = prepare_backtrack(snap, objective)
    backtrack_blocked = False
    if backtrack is not None and backtrack.get("status") == "blocked":
        signature = route_obstacle_signature(snap)
        if signature == backtrack.get("blocked_signature"):
            backtrack_blocked = True
        else:
            backtrack = {key: value for key, value in backtrack.items()
                         if not key.startswith("blocked_")}
            backtrack["status"] = "active"
            save_backtrack(backtrack)
    if backtrack is not None and backtrack.get("status") == "active":
        target_x, target_z = backtrack["points"][backtrack["index"]]
        leg_x, leg_z = bounded_navigation_leg(
            snap["x"], snap["z"], target_x, target_z)
        source_rules.append({
            "name": BACKTRACK_RULE_NAME, "enabled": True,
            "priority": BACKTRACK_PRIORITY, "cooldown_ms": 0,
            "hold_ticks": 1, "once_per_objective": False,
            "note": "retrace the body's observed successful tile trail",
            "trigger": {},
            "action": {"type": "walk", "x": leg_x, "z": leg_z,
                       "arrive": 0},
        })
    trigger_true = make_trigger_fn(objective, activity)
    urgent_retreat_names = {
        rule["name"] for rule in source_rules
        if rule.get("enabled")
        and ((rule.get("action") or {}).get("type") == "retreat"
             and snap.get("in_combat") is True
             or rule.get("name") == MANUAL_RETREAT_RULE_NAME)
        and trigger_true(rule.get("trigger") or {}, snap, {})
    }

    # Spec rules 7b-7c: capture urgent messages before ordinary play.
    # The small lock prevents the resident runner from racing a Sol reply.
    message_events = []
    with player_state_lock():
        est = load_player_state()
        est["_inflight_timeout_ms"] = defaults["inflight_timeout_ms"]
        capture_player_messages(snap, est, message_events)
        top_up_session_from_player_messages(snap, est, message_events)
        capture_friend_status(snap, est, message_events)
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
            and now - snap.get("ts", 0) <= defaults["stale_ms"] \
            and now >= settle_until:
        # Collecting a short multi-line chat burst is background observation,
        # not a reason to freeze play. Learned activity and direct model play
        # remain available until the burst is complete; only the settled
        # conversation becomes the priority verdict below.
        report("player-message", id=pending_message["id"],
               channel=pending_message["channel"], sender=pending_message["sender"],
               count=len(pending_batch), burst=pending_message_burst(pending_batch),
               session_renewed=message_batch_session_renewal(est, pending_batch) or None)
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
    route = None if backtrack is not None else load_route()
    route_blocked = False
    if route is not None and route.get("status") == "invalid":
        report("route-invalid", file=str(route_path()))
        return "route-needs-detour", EXIT_NO_RULE
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
    active_repetition_holds = []
    est["repetition_holds"] = [
        hold for hold in est.get("repetition_holds") or []
        if isinstance(hold, dict) and isinstance(hold.get("until"), int)
        and hold["until"] > now
    ]
    for rule in source_rules:
        if urgent_retreat_names and rule["name"] not in urgent_retreat_names:
            continue
        # Retracing is a deliberate recovery commitment. Incidental learned
        # work must neither cut it off nor become a fallback when one reverse
        # leg is obstructed; urgent escape remains the sole exception.
        if backtrack is not None and rule["name"] != BACKTRACK_RULE_NAME \
                and rule["name"] not in urgent_retreat_names:
            continue
        # One explicit route is the movement commitment. A stale learned
        # travel leg must not pull the body away and then hand it back to the
        # route (the observed east/west ping-pong). Nonmovement interactions
        # retain their normal priority and may still interrupt useful travel.
        if route is not None and (rule.get("action") or {}).get("type") == "walk" \
                and rule["name"] not in urgent_retreat_names \
                and trigger_true(rule.get("trigger") or {}, snap, {}):
            events.append({"ts": now, "kind": "route-conflict-hold",
                           "rule": rule["name"],
                           "rule_target": {"x": rule["action"]["x"],
                                           "z": rule["action"]["z"]},
                           "route_target": {"x": route["x"], "z": route["z"]}})
            continue
        if rule.get("once_per_objective") and rule["enabled"] \
                and once_key(rule["name"], objective) in est["objective_fired"]:
            continue
        fingerprint = rule_fingerprint(rule)
        review_hold = next((hold for hold in est["repetition_holds"]
                            if hold.get("rule") == rule["name"]
                            and hold.get("objective") == (objective or None)
                            and hold.get("activity") == (activity or None)
                            and hold.get("fingerprint") == fingerprint), None)
        if review_hold is not None and rule["name"] not in urgent_retreat_names:
            active_repetition_holds.append(review_hold)
            continue
        # Every player rule is game-channel by construction (spec rule 5);
        # the shared engine wants the key spelled out.
        live_rules.append(dict(rule, channel="game"))
    if route is not None and not route_blocked and not urgent_retreat_names:
        live_rules.append({"name": ROUTE_RULE_NAME, "enabled": True,
                           "priority": ROUTE_PRIORITY, "cooldown_ms": 0,
                           "hold_ticks": 1, "channel": "game", "trigger": {},
                           "action": {"type": "walk", "x": route["x"],
                                      "z": route["z"],
                                      "route_step": NAVIGATION_ROUTE_STEP_TILES,
                                      "max_path": NAVIGATION_LEG_MAX_PATH_TILES,
                                      "arrive": route["arrive"]}})
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
            report("route-needs-detour", x=snap.get("x"), z=snap.get("z"),
                   target_x=route["x"], target_z=route["z"],
                   reason=route.get("blocked_reason", "no-progress"),
                   feedback=latest_system_feedback(snap),
                   evidence="grounded-collision-path",
                   map_boundary="unproven",
                   next="inspect-terrain-or-use-semantic-boundary-or-waypoint")
            return "route-needs-detour", EXIT_NO_RULE
        if backtrack is not None and backtrack.get("status") == "invalid":
            report("backtrack-invalid", file=str(backtrack_path()))
            return "backtrack-blocked", EXIT_NO_RULE
        if backtrack_blocked and backtrack is not None:
            target_x, target_z = backtrack["points"][backtrack["index"]]
            report("backtrack-blocked", x=snap.get("x"), z=snap.get("z"),
                   target_x=target_x, target_z=target_z,
                   reason=backtrack.get("blocked_reason", "no-progress"),
                   feedback=latest_system_feedback(snap))
            return "backtrack-blocked", EXIT_NO_RULE
        if route is not None:
            report("route-waiting", x=snap.get("x"), z=snap.get("z"),
                   target_x=route["x"], target_z=route["z"])
            return "route-waiting", EXIT_NOT_READY
        if active_repetition_holds:
            held_names = ",".join(sorted({str(hold.get("rule"))
                                          for hold in active_repetition_holds}))
            left = max(0, max(int(hold["until"]) for hold in active_repetition_holds) - now)
            report("repetition-review-hold", rules=held_names,
                   hold_ms_left=left, objective=objective or None,
                   activity=activity or None)
            return "repetition-review-hold", EXIT_NO_RULE
        report("no-rule-matched", objective=objective or None,
               activity=activity or None,
               activity_xp=xp_text or None,
               activity_compare=xp_compare or None,
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
    completion_detail = None
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
    elif status == "done" and action["type"] == "cast-npc":
        fields = [f"{key}={action[key]}" for key in (
            "spell", "sidx", "npc", "within", "stationary",
            "require_clear_shot", "require_melee_unreachable")
                  if key in action]
        observation = make_action_observation(
            action_id, "cast-npc", fields, snap, event.get("ts"))
        completion_detail, latest = await_action_completion(
            observation, WAIT_DEFAULT_S)
        if completion_detail is None:
            status = "cast-unverified"
        elif completion_detail.get("result") == "failed":
            status = "cast-failed"
        if action.get("stationary") == 1 and latest is not None \
                and (latest.get("x"), latest.get("z")) != (snap.get("x"), snap.get("z")):
            status = "cast-moved"
        if status != "done":
            flush_events([{"ts": now_ms(), "kind": status, "rule": rule_name,
                           "id": action_id, "spell": action["spell"],
                           "npc": action["npc"], "completion": completion_detail,
                           "feedback": latest_system_feedback(latest or snap)}])

    if action["type"] == "walk" and final_x is not None and final_z is not None \
            and rule_name != BACKTRACK_RULE_NAME:
        # Preserve the settled end of a verified player-owned walk even while
        # this synchronous pass prevented ordinary snapshot polling.
        latest_walk = game_reflex.read_snapshot() or dict(snap, x=final_x, z=final_z)
        record_movement_trail(latest_walk, connected=status in ("done", "walk-short"))

    is_route = rule_name == ROUTE_RULE_NAME and route is not None
    route_was_blocked = False
    route_block_reason = None
    if is_route:
        latest = game_reflex.read_snapshot() or snap
        lx, lz = latest.get("x"), latest.get("z")
        start_distance = navigation_distance_sq(
            snap["x"], snap["z"], route["x"], route["z"])
        reached_destination = isinstance(lx, int) and isinstance(lz, int) \
            and route_distance(lx, lz, route) <= route["arrive"]
        made_progress = isinstance(lx, int) and isinstance(lz, int) \
            and navigation_distance_sq(lx, lz, route["x"], route["z"]) \
            < start_distance
        moved = isinstance(lx, int) and isinstance(lz, int) \
            and (lx, lz) != (snap.get("x"), snap.get("z"))
        endpoint = [lx, lz] if isinstance(lx, int) and isinstance(lz, int) else None
        visited = [point for point in route.get("visited") or []
                   if isinstance(point, list) and len(point) == 2]
        repeated_endpoint = endpoint is not None and endpoint in visited
        if reached_destination:
            clear_route()
            status = "route-complete"
            flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                           "x": lx, "z": lz, "target_x": route["x"],
                           "target_z": route["z"]}])
        elif status in ("done", "walk-short") and action.get("route_step") \
                and moved and not repeated_endpoint:
            nonclosing = 0 if made_progress \
                else int(route.get("nonclosing_legs") or 0) + 1
            if nonclosing > NAVIGATION_MAX_NONCLOSING_LEGS:
                route_was_blocked = True
                route_block_reason = "detour-budget"
                block_route(route, latest, route_block_reason)
                flush_events([{"ts": now_ms(), "kind": "route-leg-blocked",
                               "id": action_id, "reason": route_block_reason,
                               "x": lx, "z": lz, "target_x": route["x"],
                               "target_z": route["z"],
                               "nonclosing_legs": nonclosing}])
                status = "route-needs-detour"
            else:
                status = "route-progress"
                progressed = {key: value for key, value in route.items()
                              if not key.startswith("detour_")}
                visited.append(endpoint)
                progressed.update({"status": "active", "last_x": lx, "last_z": lz,
                                   "last_distance_sq": navigation_distance_sq(
                                       lx, lz, route["x"], route["z"]),
                                   "best_distance_sq": min(
                                       int(route.get("best_distance_sq", start_distance)),
                                       navigation_distance_sq(
                                           lx, lz, route["x"], route["z"])),
                                   "nonclosing_legs": nonclosing,
                                   "visited": visited[-NAVIGATION_VISITED_MAX:],
                                   "last_ts": now_ms()})
                save_route(progressed)
                flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                               "x": lx, "z": lz, "target_x": route["x"],
                               "target_z": route["z"],
                               "pathfinder_prefix": True,
                               "detour": not made_progress,
                               "nonclosing_legs": nonclosing}])
        elif status in ("done", "walk-short") and action.get("route_step") \
                and repeated_endpoint:
            route_was_blocked = True
            route_block_reason = "route-cycle"
            block_route(route, latest, route_block_reason)
            flush_events([{"ts": now_ms(), "kind": "route-leg-blocked",
                           "id": action_id, "reason": route_block_reason,
                           "x": lx, "z": lz, "target_x": route["x"],
                           "target_z": route["z"]}])
            status = "route-needs-detour"
        elif status in ("done", "walk-short") and made_progress:
            # Compatibility with route records/actions produced before the
            # path-prefix bridge existed.
            status = "route-progress"
            progressed = {key: value for key, value in route.items()
                          if not key.startswith("detour_")}
            progressed.update({"status": "active", "last_x": lx, "last_z": lz,
                               "last_distance_sq": navigation_distance_sq(
                                   lx, lz, route["x"], route["z"]),
                               "last_ts": now_ms()})
            save_route(progressed)
            flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                           "x": lx, "z": lz, "target_x": route["x"],
                           "target_z": route["z"], "leg_x": action["x"],
                           "leg_z": action["z"]}])
        else:
            route_was_blocked = True
            route_block_reason = "no-progress" \
                if status in ("done", "walk-short") and not moved else status
            block_route(route, latest, route_block_reason)
            flush_events([{"ts": now_ms(), "kind": "route-leg-blocked", "id": action_id,
                           "reason": route_block_reason, "x": lx, "z": lz,
                           "target_x": route["x"], "target_z": route["z"]}])
            status = "route-needs-detour"

    is_backtrack = rule_name == BACKTRACK_RULE_NAME and backtrack is not None
    backtrack_was_blocked = False
    if is_backtrack:
        latest = game_reflex.read_snapshot() or snap
        lx, lz = latest.get("x"), latest.get("z")
        target_x, target_z = backtrack["points"][backtrack["index"]]
        start_distance = navigation_distance_sq(
            snap["x"], snap["z"], target_x, target_z)
        if status == "done" and [lx, lz] == [target_x, target_z]:
            rewind_movement_trail(lx, lz)
            backtrack["index"] += 1
            backtrack["status"] = "active"
            if backtrack["index"] >= len(backtrack["points"]):
                clear_backtrack()
                status = "backtrack-complete"
                flush_events([{"ts": now_ms(), "kind": "backtrack-complete",
                               "id": action_id, "x": lx, "z": lz,
                               "steps": len(backtrack["points"])}])
            else:
                save_backtrack(backtrack)
                status = "backtrack-progress"
                flush_events([{"ts": now_ms(), "kind": "backtrack-progress",
                               "id": action_id, "x": lx, "z": lz,
                               "remaining": len(backtrack["points"]) - backtrack["index"]}])
        elif status in ("done", "walk-short") \
                and isinstance(lx, int) and isinstance(lz, int) \
                and navigation_distance_sq(lx, lz, target_x, target_z) < start_distance:
            # A historical checkpoint can be farther away than one safe local
            # leg. Keep approaching it without pretending the checkpoint was
            # reached or consuming it from the recovery request.
            backtrack["status"] = "active"
            save_backtrack(backtrack)
            status = "backtrack-progress"
            flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                           "x": lx, "z": lz,
                           "remaining": len(backtrack["points"]) - backtrack["index"],
                           "target_x": target_x, "target_z": target_z,
                           "leg_x": action["x"], "leg_z": action["z"]}])
        else:
            backtrack_was_blocked = True
            blocked = dict(backtrack)
            blocked.update({"status": "blocked", "blocked_reason": status,
                            "blocked_signature": route_obstacle_signature(latest),
                            "blocked_ts": now_ms()})
            save_backtrack(blocked)
            flush_events([{"ts": now_ms(), "kind": "backtrack-blocked",
                           "id": action_id, "reason": status, "x": lx, "z": lz,
                           "target_x": target_x, "target_z": target_z}])

    # The once-per-objective mark is spent only on a VERIFIED done (rule 7a).
    if rule is not None and rule.get("once_per_objective") and status == "done":
        est = load_player_state()
        est["objective_fired"][once_key(rule_name, objective)] = now
        save_player_state(est)

    # Every outcome feeds the background author (spec rule 16).
    outcome = {"ts": now_ms(), "kind": "outcome", "rule": rule_name,
               "id": action_id, "action": action, "status": status,
               "objective": objective or None, "activity": activity or None,
               "activity_performance": xp_metrics or None,
               "snap": snap_brief(snap)}
    if completion_detail is not None:
        outcome["completion"] = completion_detail
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
        if backtrack_was_blocked:
            report("backtrack-blocked", id=action_id, x=final_x, z=final_z,
                   target_x=action["x"], target_z=action["z"])
        elif route_was_blocked:
            report("route-needs-detour", id=action_id, x=final_x, z=final_z,
                   leg_x=action["x"], leg_z=action["z"],
                   reason=route_block_reason, evidence="grounded-collision-path",
                   map_boundary="unproven",
                   next="inspect-terrain-or-use-semantic-boundary-or-waypoint")
        else:
            report("fired", rule=rule_name, id=action_id, type=action["type"],
                   status=status, x=final_x, z=final_z, objective=objective or None,
                   activity=activity or None, activity_xp=xp_text or None,
                   activity_compare=xp_compare or None)
    else:
        if backtrack_was_blocked:
            report("backtrack-blocked", id=action_id, target_x=action["x"],
                   target_z=action["z"], reason=status)
        elif route_was_blocked:
            report("route-needs-detour", id=action_id,
                   leg_x=action["x"], leg_z=action["z"], reason=route_block_reason,
                   evidence="grounded-collision-path",
                   map_boundary="unproven",
                   next="inspect-terrain-or-use-semantic-boundary-or-waypoint")
        else:
            report("fired", rule=rule_name, id=action_id, type=action["type"],
                   status=status, objective=objective or None,
                   activity=activity or None, activity_xp=xp_text or None,
                   activity_compare=xp_compare or None)
    if backtrack_was_blocked:
        return "backtrack-blocked", EXIT_NO_RULE
    if route_was_blocked:
        return "route-needs-detour", EXIT_NO_RULE
    return "fired", (EXIT_FIRED if status in ("done", "route-progress", "route-complete",
                                               "backtrack-progress", "backtrack-complete")
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
    if getattr(args, "history", False):
        records = load_jsonl(reflex_history_path())
        wanted = getattr(args, "rule", None)
        shown = 0
        for record in records[-100:]:
            changes = [change for change in record.get("changes") or []
                       if not wanted or change.get("name") == wanted]
            if not changes:
                continue
            names = ",".join(f"{change.get('operation')}:{change.get('name')}"
                             for change in changes)
            perf = record.get("performance_before") or {}
            rates = ",".join(f"{skill.get('name')}={skill.get('xp_per_hour')}/hr"
                             for skill in perf.get("skills") or []) or "no-XP-sample"
            print(f"{record.get('ts')} activity={record.get('activity') or '(none)'} "
                  f"relevant={str(bool(record.get('relevant_to_activity'))).lower()} "
                  f"change={names} before={rates} doing={record.get('doing')}")
            shown += 1
        if not shown:
            print("no reflex change history" + (f" for {wanted}" if wanted else ""))
        return
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
    before = json.loads(json.dumps(cfg))
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
    save_config_change(before, cfg, f"learning '{args.name}'")
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
    before = json.loads(json.dumps(cfg))
    find_rule(cfg, args.rule)["enabled"] = value
    gate_or_die(cfg, f"{'enabling' if value else 'disabling'} '{args.rule}'")
    save_config_change(before, cfg,
                       f"{'enabling' if value else 'disabling'} '{args.rule}'")
    print(f"{args.rule}: {'enabled' if value else 'disabled'}")


def cmd_set(args):
    cfg = load_config()
    before = json.loads(json.dumps(cfg))
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
    save_config_change(before, cfg, f"setting '{args.rule}' {key}")
    print(f"{args.rule}: {key} = {value!r}")


def cmd_remove(args):
    cfg = load_config()
    old_cfg = json.loads(json.dumps(cfg))
    before = len(cfg["rules"]) + len(cfg["unfinished"])
    cfg["rules"] = [r for r in cfg["rules"] if r["name"] != args.rule]
    cfg["unfinished"] = [e for e in cfg["unfinished"] if e["name"] != args.rule]
    if len(cfg["rules"]) + len(cfg["unfinished"]) == before:
        die(f"nothing named '{args.rule}' in rules or unfinished")
    gate_or_die(cfg, f"removing '{args.rule}'")
    if reflex_changes(old_cfg, cfg):
        save_config_change(old_cfg, cfg, f"removing '{args.rule}'")
    else:
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


def print_activity_history(activity: str) -> None:
    if not activity:
        print("no activity selected")
        return
    rows = [row for row in load_jsonl(activity_history_path())
            if row.get("activity") == activity]
    current = {}
    stats = load_activity_stats()
    if stats.get("activity") == activity:
        snap = game_reflex.read_snapshot() or {}
        if skills_ready(snapshot_skills(snap)):
            stats = refresh_activity_stats(snap, activity)
        current = activity_metrics_from_stats(stats)
    if not rows and not current:
        print(f"activity history: {activity} — no measured iterations yet")
        return
    for row in rows[-12:]:
        rates = ",".join(
            f"{skill.get('name')}={skill.get('xp_per_hour')}/hr"
            f"(+{skill.get('gained')})" for skill in row.get("skills") or []) \
            or "no-positive-XP"
        eligible = "comparable" if row.get("performance_eligible") else "short/no-XP"
        print(f"iteration {row.get('iteration')} ended={row.get('ended_ms')} "
              f"elapsed_ms={row.get('elapsed_ms')} {eligible} rates={rates} "
              f"reason={row.get('end_reason')} rules={row.get('rule_set_hash')}")
    if current:
        rates = ",".join(
            f"{skill.get('name')}={skill.get('xp_per_hour')}/hr"
            f"(+{skill.get('gained')})" for skill in current.get("skills") or []) \
            or "no-positive-XP-yet"
        print(f"iteration {current.get('iteration')} CURRENT "
              f"elapsed_ms={current.get('elapsed_ms')} rates={rates} "
              f"reason={current.get('reason')} rules={current.get('rule_set_hash')}")
    summary = activity_history_summary(activity, current)
    if summary.get("best"):
        print("best comparable: " + ", ".join(
            f"{skill.get('name')}={skill.get('xp_per_hour')}/hr "
            f"(iteration {skill.get('iteration')})"
            for skill in summary["best"]))


def cmd_activity(args):
    """The immediate mode of play, separate from the longer-lived objective."""
    if getattr(args, "history", False):
        print_activity_history(args.name or read_activity())
        return
    if args.clear:
        previous = read_activity()
        if previous:
            finish_activity_iteration("activity-cleared", game_reflex.read_snapshot() or {})
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
    cfg = load_config()
    snap = game_reflex.read_snapshot() or {}
    changed = selected != previous or args.restart
    if changed and previous:
        finish_activity_iteration(
            "activity-restarted" if selected == previous else f"activity-switched-to:{selected}",
            snap)
    game_dir().mkdir(parents=True, exist_ok=True)
    game_reflex.atomic_write(activity_path(), selected + "\n")
    if changed:
        clear_activity_stats()
        stats = start_activity_stats(
            selected, snap,
            reason="activity-restarted" if selected == previous else "activity-selected",
            cfg=cfg)
        briefing = activity_briefing(cfg, selected, snap)
        append_outcome({
            "ts": now_ms(), "kind": "activity-start", "activity": selected,
            "objective": read_objective() or None,
            "iteration": stats.get("iteration") or next_activity_iteration(selected),
            "baseline_ready": bool(stats),
            "current_rules": briefing["current_rules"],
            "reuse_candidates": briefing["reuse_candidates"],
            "history": {key: briefing["history"].get(key) for key in
                        ("iterations", "latest", "best")},
            "note": "Review existing reflexes first; reuse only grounded structure, then "
                    "measure this iteration against comparable prior XP/hour.",
        })
    else:
        stats = load_activity_stats()
        briefing = activity_briefing(cfg, selected, snap)
    print(f"activity: {selected}")
    if changed:
        print(f"iteration: {stats.get('iteration') or next_activity_iteration(selected)} "
              f"({'baseline ready' if stats else 'XP baseline pending'})")
    current_names = briefing.get("current_rules") or []
    print("current reflexes: " + (", ".join(current_names[:12]) if current_names else "none"))
    candidates = briefing.get("reuse_candidates") or []
    print("reuse candidates: " + (
        ", ".join(f"{item['name']} (from {item['source_activity']})"
                  for item in candidates) if candidates else "none yet"))
    best = briefing.get("history", {}).get("best") or []
    if best:
        print("prior best: " + ", ".join(
            f"{skill.get('name')} {skill.get('xp_per_hour')}/hr "
            f"(iteration {skill.get('iteration')})" for skill in best))
    if changed:
        recalled = recall_activity_memories(selected)
        if recalled:
            print("relevant play memories for this transition:")
            print(recalled)


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
        with session_state_lock():
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
        with session_state_lock():
            st = session_state()
            if st["phase"] == "none":
                print("session: none open")
                return
            if st["phase"] == "open":
                die("session-end refused phase=open: the automatic deadline is still "
                    f"open for {st['remaining_ms'] // 1000}s; cancel any stale "
                    "wind-down and continue playing")
            if st["phase"] == "ended":
                print("session: already ended")
                return
            body = dict(read_session())
            body["ended"] = now_ms()
            game_reflex.atomic_write(session_path(), json.dumps(body) + "\n")
        print(f"session ended after {st['elapsed_ms'] // 60000}m "
              f"of a {st['limit_ms'] // 60000}m sitting")
        return
    if args.action == "cutoff":
        # The transient hard-stop timer asks atomically. A player message may
        # have moved the deadline since this timer was armed; in that case the
        # caller rearms instead of disconnecting her at the obsolete time.
        with session_state_lock():
            st = session_state()
            if st["phase"] in ("none", "ended"):
                print(f"session-cutoff ignore phase={st['phase']}")
                return
            if st["grace_ms_left"] > 0:
                print(f"session-cutoff wait_ms={st['grace_ms_left']}")
                return
            body = dict(read_session())
            if body and not body.get("ended"):
                body["ended"] = now_ms()
                body["ended_reason"] = "deadline"
                game_reflex.atomic_write(session_path(), json.dumps(body) + "\n")
            print(f"session-cutoff due phase={st['phase']}")
        return
    st = session_state()
    if st["phase"] == "none":
        print("session: none open")
        return
    print(f"session: {st['phase']} — {st['elapsed_ms'] // 60000}m elapsed of "
          f"{st['limit_ms'] // 60000}m, play left {st['remaining_ms'] // 60000}m, "
          f"grace left {st['grace_ms_left'] // 60000}m")


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
            snap = game_reflex.read_snapshot() or {}
            px, pz = snap.get("x"), snap.get("z")
            current = f" current=({px},{pz}) distance={route_distance(px, pz, route)}" \
                if isinstance(px, int) and isinstance(pz, int) else ""
            last = f" last_progress=({route['last_x']},{route['last_z']})" \
                if isinstance(route.get("last_x"), int) \
                and isinstance(route.get("last_z"), int) else ""
            detour = f" local_detour_attempts={len(route.get('detour_failed_legs') or [])}" \
                if route.get("detour_failed_legs") else ""
            print(f"route: status={route['status']} target=({route['x']},{route['z']}) "
                  f"arrive={route['arrive']} objective={route['objective'] or '(none)'}"
                  f"{current}{last}{detour}"
                  f"{(' reason=' + route.get('blocked_reason', '')) if route['status'] == 'blocked' else ''}")
        return
    if args.x is None or args.z is None:
        die("route needs both X and Z")
    if not 0 <= args.arrive <= 10:
        die("route --arrive must be from 0 through 10")
    snap = game_reflex.read_snapshot() or {}
    route = {"v": 1, "x": args.x, "z": args.z, "arrive": args.arrive,
             "objective": read_objective(), "status": "active", "set_ts": now_ms(),
             "visited": [], "nonclosing_legs": 0}
    if isinstance(snap.get("x"), int) and isinstance(snap.get("z"), int):
        route.update({"origin_x": snap["x"], "origin_z": snap["z"],
                      "origin_distance_sq": navigation_distance_sq(
                          snap["x"], snap["z"], args.x, args.z),
                      "best_distance_sq": navigation_distance_sq(
                          snap["x"], snap["z"], args.x, args.z),
                      "visited": [[snap["x"], snap["z"]]]})
    # A newly chosen destination is an explicit replacement strategy, not a
    # second movement commitment to race an old recovery.
    clear_backtrack()
    save_route(route)
    print(f"route-set target=({args.x},{args.z}) arrive={args.arrive} "
          f"objective={route['objective'] or '(none)'}")


def cmd_backtrack(args):
    """Retrace observed successful movement instead of guessing a reverse route."""
    if args.action == "clear":
        clear_backtrack()
        print("backtrack cleared")
        return
    if args.action == "status":
        request = load_backtrack()
        if request is None:
            print("backtrack: (none)")
        elif request.get("status") == "invalid":
            print(f"backtrack: invalid ({backtrack_path()})")
        else:
            remaining = len(request["points"]) - request["index"]
            next_x, next_z = request["points"][request["index"]] \
                if remaining else (None, None)
            print(f"backtrack: status={request['status']} remaining={remaining} "
                  f"next=({next_x},{next_z}) objective={request['objective'] or '(none)'}")
        return
    if args.action == "history":
        points = load_movement_trail()["points"]
        if not points:
            print("movement trail: (none)")
            return
        print(f"movement trail: {len(points)} observed tile(s); newest last")
        for point in points[-20:]:
            stamp = time.strftime("%Y-%m-%d %H:%M:%S",
                                  time.localtime(point["ts"] / 1000.0))
            boundary = " portal-boundary" if point.get("break") else ""
            print(f"{stamp} tile=({point['x']},{point['z']}){boundary}")
        return

    existing = load_backtrack()
    if existing is not None and existing.get("status") in ("active", "blocked"):
        remaining = len(existing["points"]) - existing["index"]
        die(f"backtrack is already {existing['status']} with {remaining} point(s) "
            "remaining; use status or clear before replacing it")

    snap = game_reflex.read_snapshot() or {}
    if snap.get("logged_in") is not True:
        die("backtrack needs a logged-in movement snapshot")
    record_movement_trail(snap)
    trail = load_movement_trail()["points"]
    if not trail:
        die("no observed movement trail is available")
    segment_start = 0
    for index, point in enumerate(trail):
        if point.get("break") is True:
            segment_start = index
    segment = trail[segment_start:]
    current = [snap.get("x"), snap.get("z")]
    while segment and [segment[-1]["x"], segment[-1]["z"]] == current:
        segment = segment[:-1]
    targets = []
    for point in reversed(segment):
        target = [point["x"], point["z"]]
        if not targets or targets[-1] != target:
            targets.append(target)
    if not targets:
        die("the current portal-bounded trail has no earlier tile to retrace")
    if args.action != "all":
        try:
            limit = int(args.action)
        except ValueError:
            die("backtrack takes a positive point count, all, history, status, or clear")
        if limit <= 0:
            die("backtrack point count must be positive")
        targets = targets[:limit]
    request = {"v": 1, "objective": read_objective(), "status": "active",
               "index": 0, "points": targets, "set_ts": now_ms()}
    clear_route()
    save_backtrack(request)
    print(f"backtrack-set points={len(targets)} next=({targets[0][0]},{targets[0][1]}) "
          f"objective={request['objective'] or '(none)'}")


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
    with the live context and queued for the unified rule/memory author."""
    snap = game_reflex.read_snapshot() or {}
    append_outcome({"ts": now_ms(), "kind": "lesson", "text": " ".join(args.text),
                    "objective": read_objective() or None,
                    "snap": snap_brief(snap)})
    print("noted for the unified rule/memory author")


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

    undeliverable = status == "refused-server" and action["type"] == "chat-private"
    replied_batch = []
    with player_state_lock():
        est = load_player_state()
        est["inflight"] = None
        if status == "done" or undeliverable:
            replied_batch = [m for m in est["pending_messages"]
                    if m["channel"] == pending["channel"]
                    and m["sender"].casefold() == pending["sender"].casefold()
                    and m["id"] <= pending["id"]]
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
    if status == "done" or undeliverable:
        append_outcome({
            "ts": now_ms(), "kind": "conversation-evidence",
            "message_id": pending["id"], "channel": pending["channel"],
            "sender": pending["sender"],
            "messages": [{"id": item["id"], "text": item["text"]}
                         for item in replied_batch],
            "reply": text, "delivery_status": status,
            "claims_untrusted": True,
            "objective": read_objective() or None,
            "activity": read_activity() or None,
            "snap": snap_brief(game_reflex.read_snapshot() or snap),
        })
    if undeliverable:
        flush_events([{"ts": now_ms(), "kind": "player-message-undeliverable",
                       "message_id": pending["id"], "sender": pending["sender"],
                       "reply": text, "reason": status,
                       "next": "resume-play-and-answer-when-the-player-returns"}])
        report("reply-undeliverable", message_id=pending["id"], action_id=action_id,
               sender=pending["sender"], reason=status, pending="cleared",
               next="resume-play")
    else:
        report("replied", message_id=pending["id"], action_id=action_id,
               channel=pending["channel"], sender=pending["sender"],
               reply_channel="private" if action["type"] == "chat-private" else "local",
               status=status)
    if status != "done" and not undeliverable:
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
                                    "activity_performance": activity_metrics(
                                        snap, activity) or None,
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
            active_backtrack = load_backtrack()
            if active_backtrack is not None \
                    and active_backtrack.get("status") != "invalid":
                remaining = len(active_backtrack["points"]) - active_backtrack["index"]
                recovery_detail = (f"backtrack {active_backtrack['status']} "
                                   f"with {remaining} point(s) remaining")
                detail = f"{recovery_detail}; {detail}" if detail else recovery_detail
            live_activity = read_activity()
            live_metrics = activity_metrics(latest, live_activity)
            live_xp = activity_xp_metrics_text(live_metrics)
            live_compare = activity_comparison_text(live_metrics)
            live_friend_updates = pending_friend_status(load_player_state())
            write_heartbeat(last_verdict, detail,
                            [i.get("id") for i in latest.get("ground_items") or []],
                            live_activity, live_xp, live_compare, live_friend_updates)
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
    p = sub.add_parser("rules", help="the learned table or durable reflex history")
    p.add_argument("--history", action="store_true",
                   help="show reflex revisions and the XP sample before each change")
    p.add_argument("--rule", help="with --history, restrict changes to one rule")
    p.set_defaults(fn=cmd_rules)

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
    p.add_argument("--history", action="store_true",
                   help="show comparable XP/hour iterations for NAME or the current activity")
    p.set_defaults(fn=cmd_activity)

    p = sub.add_parser("session", help="the sitting's clock: open, status, end")
    p.add_argument("action", nargs="?", default="status",
                   choices=["open", "status", "end", "cutoff"])
    p.add_argument("--limit-ms", type=int, dest="limit_ms")
    p.add_argument("--grace-ms", type=int, dest="grace_ms")
    p.set_defaults(fn=cmd_session)

    p = sub.add_parser("route", help="set, inspect, or clear the durable ACTIONS route")
    p.add_argument("x", nargs="?", type=int)
    p.add_argument("z", nargs="?", type=int)
    p.add_argument("--arrive", type=int, default=1)
    p.add_argument("--clear", action="store_true")
    p.set_defaults(fn=cmd_route)

    p = sub.add_parser("backtrack",
                       help="retrace observed successful tiles to the current portal boundary")
    p.add_argument("action", nargs="?", default=str(BACKTRACK_DEFAULT_POINTS),
                   help="point count, all, history, status, or clear")
    p.set_defaults(fn=cmd_backtrack)

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

    p = sub.add_parser("note", help="queue a lesson for the unified rule/memory "
                                    "author (spec rules 16, 19)")
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

    p = sub.add_parser("action-arm", help=argparse.SUPPRESS)
    p.add_argument("id", type=int)
    p.add_argument("type")
    p.add_argument("fields", nargs="*")
    p.set_defaults(fn=cmd_action_arm)

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
                # The resident process normally captured these already. Do
                # the same read here as a hot-upgrade seam: a newly installed
                # CLI can surface a still-visible transition even while the
                # long-lived runner is finishing its old code generation.
                friend_events = []
                with player_state_lock():
                    live_state = load_player_state()
                    live_snapshot = game_reflex.read_snapshot() or {}
                    capture_player_messages(live_snapshot, live_state, friend_events)
                    top_up_session_from_player_messages(
                        live_snapshot, live_state, friend_events)
                    capture_friend_status(
                        live_snapshot, live_state, friend_events)
                    save_player_state(live_state)
                    flush_events(friend_events)
                friend_updates = pending_friend_status(live_state)
                friend_updates_field = friend_status_text(friend_updates) \
                    if friend_updates else None
                if verdict == "player-message":
                    batch = pending_message_batch(live_state)
                    pending = batch[-1] if batch else None
                    if pending is not None:
                        report("player-message", id=pending["id"],
                               channel=pending["channel"], sender=pending["sender"],
                               count=len(batch), burst=pending_message_burst(batch),
                               session_renewed=(
                                   message_batch_session_renewal(live_state, batch) or None),
                               friend_updates=friend_updates_field)
                    else:
                        report("runner-player-message", age_ms=now_ms() - hb.get("ts", 0),
                               pid=hb.get("pid"), friend_updates=friend_updates_field)
                elif verdict == "system-message":
                    pending = oldest_pending_system_message(live_state)
                    if pending is not None:
                        report("system-message", id=pending["id"],
                               channel=pending["channel"], action="move-required",
                               text=pending["text"], friend_updates=friend_updates_field)
                    else:
                        report("runner-system-message", age_ms=now_ms() - hb.get("ts", 0),
                               pid=hb.get("pid"), friend_updates=friend_updates_field)
                else:
                    report(f"runner-{verdict or 'unknown'}",
                           age_ms=now_ms() - hb.get("ts", 0), pid=hb.get("pid"),
                           activity=hb.get("activity") or None,
                           activity_xp=hb.get("activity_xp") or None,
                           activity_compare=hb.get("activity_compare") or None,
                           ground_items=",".join(str(i)
                                                 for i in hb.get("ground_items") or []) or None,
                           feedback=hb.get("detail") or None,
                           friend_updates=friend_updates_field)
                acknowledge_friend_status(friend_updates)
                sys.exit({"no-rule-matched": EXIT_NO_RULE,
                          "route-needs-detour": EXIT_NO_RULE,
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
