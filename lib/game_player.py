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
import heapq
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
                "entity_visible",
                "ground_item_visible", "shop_item_visible", "bank_item_visible",
                "message_contains", "near_tile",
                "inventory_has", "inventory_lacks", "inventory_slots_below",
                "inventory_slots_at_least", "fatigue_below", "in_combat", "out_of_combat")
ACTIONS = ("talk-npc", "attack-npc", "interact-npc", "use-item-npc", "cast-npc", "walk", "approach-entity", "follow-player", "retreat", "interact-object", "interact-bound", "click-entity",
           "click-inventory", "click-shop", "click-bank", "take-ground")
ENTITY_COLLECTIONS = ("players", "npcs", "objects", "bounds", "ground_items")
ENTITY_SELECTOR_FIELDS = ("name", "id", "sidx")
SYSTEM_FEEDBACK_CHANNELS = ("game", "quest", "inventory")
FRIEND_STATUS_RE = re.compile(r"^(.+?)\s+has logged\s+(in|out)\s*$", re.IGNORECASE)
WAIT_CONDITIONS = (
    "logged_in", "logged_out", "walking", "not_walking", "in_combat",
    "out_of_combat", "talking_to_npc", "not_talking_to_npc",
    "right_click_menu_open", "right_click_menu_closed",
    "ui_panel_open", "ui_panel_closed",
    "trade_open", "trade_closed", "duel_open", "duel_confirm", "duel_closed",
    "sleeping", "not_sleeping", "fatigue_zero",
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
STOP_VERIFY_S = 6.0         # a stop's postcondition: a snapshot with walking false
TAKE_TIMEOUT_S = 25.0       # a pickup can include the same bounded pathing delay
TAKE_MISSING_GRACE_S = 0.75 # let inventory follow a just-removed ground entry
RETREAT_VERIFY_S = 1.25     # one server-round-sized observation before a retry
# Spec rule 7a: scenery transitions. The server's own floor arithmetic packs
# each floor into one 944-tile band of the north-south axis (its Point
# arithmetic: height = z / 944), so the snapshot's z names the current floor.
FLOOR_BAND_TILES = 944
OBJECT_SETTLE_AWAY_TILES = 3  # walked and settled farther than this from the
                              # target with no evidence = the click missed it
OBJECT_VANISH_NEAR_TILES = 3  # a still body watching its target vanish = the
                              # scenery set reloaded (a transition happened)
PORTAL_JUMP_TILES = 12        # rule 7f's unexplained-transition boundary, reused
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
CLIENT_ROUTE_TIMEOUT_S = 5.0
NAVIGATION_ATLAS_REFRESH_MS = 60 * 1000
NAVIGATION_ATLAS_NPC_SITES = 128
NAVIGATION_ATLAS_STATIC_SITES = 2048
NAVIGATION_ATLAS_LINKS = 8192
NAVIGATION_BLOCKER_MARGIN_TILES = 32
NAVIGATION_BLOCKER_MAX = 4096
BACKTRACK_DEFAULT_POINTS = 8  # recovery is a recent correction, not a replay of the whole day
MOVEMENT_CONTRADICTION_LIMIT = 3  # consecutive settles against the request stop re-dispatching
ROUTE_RULE_NAME = "active-route"
ROUTE_PRIORITY = -1_000_000  # every learned interaction outranks ordinary travel
BACKTRACK_RULE_NAME = "active-backtrack"
BACKTRACK_PRIORITY = 900_000  # deliberate recovery beats routine work; retreat still wins
FOLLOW_RULE_NAME = "active-follow-player"
FOLLOW_PRIORITY = 850_000  # an accepted guide beats routine work; escape still wins
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
PLAN_MAX_CHARS = 1200
PLAN_REASON_MAX_CHARS = 500

EMPTY_TABLE = {"v": 1, "defaults": dict(DEFAULTS), "rules": [], "unfinished": []}


def state_dir() -> Path:
    return game_reflex.state_dir()


def game_dir() -> Path:
    return game_reflex.game_dir()


def rules_path() -> Path:
    return game_dir() / "learned-rules.json"


def objective_path() -> Path:
    return game_dir() / "objective"


def plan_path() -> Path:
    return game_dir() / "plan"


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


def action_observation_lock_path() -> Path:
    return state_dir() / "last-action-observation.lock"


class action_observation_lock:
    """Serialize arming with a waiter's compare-and-update or removal."""
    def __enter__(self):
        action_observation_lock_path().parent.mkdir(parents=True, exist_ok=True)
        self.fh = open(action_observation_lock_path(), "a+")
        fcntl.flock(self.fh.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc, tb):
        fcntl.flock(self.fh.fileno(), fcntl.LOCK_UN)
        self.fh.close()


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


def movement_progress_path() -> Path:
    return state_dir() / "movement-in-progress.json"


def foreign_movement_in_progress() -> dict | None:
    """A direct hand's committed recovery walk (rule 7f's retrace). The
    resident runner must not evaluate around it and cancel the leg midway."""
    try:
        progress = json.loads(movement_progress_path().read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(progress, dict) or progress.get("v") != 1 \
            or not isinstance(progress.get("pid"), int) \
            or not isinstance(progress.get("expires"), int) \
            or progress["expires"] <= now_ms():
        try:
            movement_progress_path().unlink()
        except FileNotFoundError:
            pass
        return None
    return progress if progress["pid"] != os.getpid() else None


def movement_agrees(start_x: int, start_z: int, leg_x: int, leg_z: int,
                    settled_x: int, settled_z: int) -> bool:
    """Did the observed settlement move WITH the request? Coordinate-free:
    a settled displacement with a positive component along the requested
    displacement agrees; no movement, or movement with no positive component
    (opposite or purely sideways), is a contradiction — the click was
    delivered but something else owned the body (spec rule 7f)."""
    requested = (leg_x - start_x, leg_z - start_z)
    observed = (settled_x - start_x, settled_z - start_z)
    if observed == (0, 0) or requested == (0, 0):
        return requested == observed
    return requested[0] * observed[0] + requested[1] * observed[1] > 0


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


def visible_aggressive_npcs(snap: dict) -> list[dict]:
    """Visible combat-capable NPCs known through the ordinary client.

    The client cache exposes whether an NPC can be attacked, but not the
    server's private aggression policy.  Treating every attackable visible
    NPC as a possible hazard is conservative during an explicit retreat and
    never consults a server definition file.
    """
    return [npc for npc in snap.get("npcs") or []
            if isinstance(npc, dict) and npc.get("attackable") is True
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


def follow_path() -> Path:
    return game_dir() / "follow.json"


def follow_lock_path() -> Path:
    return game_dir() / "follow.lock"


class follow_state_lock:
    """Serialize direct follow changes with the resident runner's settlement."""
    def __enter__(self):
        follow_lock_path().parent.mkdir(parents=True, exist_ok=True)
        self.fh = open(follow_lock_path(), "a+")
        fcntl.flock(self.fh.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc, tb):
        fcntl.flock(self.fh.fileno(), fcntl.LOCK_UN)
        self.fh.close()


def navigation_atlas_path() -> Path:
    return game_dir() / "navigation-atlas.json"


def navigation_atlas_lock_path() -> Path:
    return game_dir() / "navigation-atlas.lock"


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
    waypoints = route.get("waypoints", [])
    if not isinstance(waypoints, list) or len(waypoints) > 512 \
            or any(not isinstance(point, list) or len(point) != 2
                   or not all(isinstance(value, int) for value in point)
                   for point in waypoints):
        return {"status": "invalid"}
    planned_from = route.get("planned_from")
    if planned_from is not None \
            and (not isinstance(planned_from, list) or len(planned_from) != 2
                 or not all(isinstance(value, int) for value in planned_from)):
        return {"status": "invalid"}
    portal = route.get("next_portal")
    if portal is not None and (not isinstance(portal, dict)
            or portal.get("kind") not in ("object", "bound")
            or not all(isinstance(portal.get(key), int)
                       for key in ("id", "x", "z", "dir"))
            or not isinstance(portal.get("from"), list)
            or len(portal["from"]) != 2
            or not all(isinstance(value, int) for value in portal["from"])):
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


def _normalise_landmark_text(value) -> str:
    return " ".join(str(value or "").casefold().split())


def load_navigation_atlas() -> dict:
    try:
        atlas = json.loads(navigation_atlas_path().read_text())
    except (OSError, json.JSONDecodeError):
        return {"v": 1, "tiles": {}, "barriers": {}, "entities": {}, "links": {}}
    if not isinstance(atlas, dict) or atlas.get("v") != 1:
        return {"v": 1, "tiles": {}, "barriers": {}, "entities": {}, "links": {}}
    for field in ("tiles", "barriers", "entities", "links"):
        if not isinstance(atlas.get(field), dict):
            atlas[field] = {}
    return atlas


def _atlas_refresh(entry: dict, observed_ms: int) -> bool:
    last_seen = entry.get("last_seen")
    return not isinstance(last_seen, int) \
        or observed_ms - last_seen >= NAVIGATION_ATLAS_REFRESH_MS


def _atlas_site_key(x: int, z: int, direction) -> str:
    return f"{x},{z},{direction if isinstance(direction, int) else '-'}"


def record_navigation_observation(snap: dict) -> None:
    """Persist only world facts delivered to this ordinary client.

    The local terrain square comes from the client's collision map; entity
    names and commands come from the client's cache; locations come from
    normal packets.  Repeated frames are coalesced to one refresh per minute
    so the resident observer does not rewrite the atlas every tick.
    """
    if snap.get("logged_in") is not True:
        return
    px, pz = snap.get("x"), snap.get("z")
    if not isinstance(px, int) or not isinstance(pz, int):
        return
    observed_ms = snap.get("ts") if isinstance(snap.get("ts"), int) else now_ms()
    game_dir().mkdir(parents=True, exist_ok=True)
    try:
        with open(navigation_atlas_lock_path(), "a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            atlas = load_navigation_atlas()
            changed = False

            terrain = snap.get("terrain")
            if isinstance(terrain, dict) and isinstance(terrain.get("radius"), int):
                radius = min(12, max(0, terrain["radius"]))
                blocked = {
                    (cell.get("x"), cell.get("z")): cell
                    for cell in terrain.get("blocked_cells") or []
                    if isinstance(cell, dict) and isinstance(cell.get("x"), int)
                    and isinstance(cell.get("z"), int)
                }
                for x in range(px - radius, px + radius + 1):
                    for z in range(pz - radius, pz + radius + 1):
                        cell = blocked.get((x, z))
                        facts = {
                            "x": x, "z": z, "blocked": cell is not None,
                            "projectiles_pass": (
                                cell.get("projectiles_pass") if cell is not None else True),
                        }
                        key = f"{x},{z}"
                        old = atlas["tiles"].get(key)
                        if not isinstance(old, dict):
                            atlas["tiles"][key] = {
                                **facts, "first_seen": observed_ms,
                                "last_seen": observed_ms, "sightings": 1,
                            }
                            changed = True
                        elif any(old.get(name) != value for name, value in facts.items()) \
                                or _atlas_refresh(old, observed_ms):
                            old.update(facts)
                            old["last_seen"] = observed_ms
                            old["sightings"] = int(old.get("sightings", 0)) + 1
                            changed = True

                for barrier in terrain.get("barriers") or []:
                    if not isinstance(barrier, dict) \
                            or not isinstance(barrier.get("a"), list) \
                            or not isinstance(barrier.get("b"), list) \
                            or len(barrier["a"]) != 2 or len(barrier["b"]) != 2 \
                            or not all(isinstance(value, int)
                                       for value in barrier["a"] + barrier["b"]):
                        continue
                    a, b = sorted((barrier["a"], barrier["b"]))
                    key = f"{a[0]},{a[1]}:{b[0]},{b[1]}"
                    facts = {"a": a, "b": b,
                             "projectiles_pass": barrier.get("projectiles_pass") is True}
                    old = atlas["barriers"].get(key)
                    if not isinstance(old, dict):
                        atlas["barriers"][key] = {
                            **facts, "first_seen": observed_ms,
                            "last_seen": observed_ms, "sightings": 1,
                        }
                        changed = True
                    elif any(old.get(name) != value for name, value in facts.items()) \
                            or _atlas_refresh(old, observed_ms):
                        old.update(facts)
                        old["last_seen"] = observed_ms
                        old["sightings"] = int(old.get("sightings", 0)) + 1
                        changed = True

            for kind, collection in (("npc", "npcs"), ("object", "objects"),
                                     ("bound", "bounds")):
                for entity in snap.get(collection) or []:
                    if not isinstance(entity, dict) \
                            or not isinstance(entity.get("id"), int) \
                            or not isinstance(entity.get("x"), int) \
                            or not isinstance(entity.get("z"), int):
                        continue
                    entity_key = f"{kind}:{entity['id']}"
                    stored = atlas["entities"].get(entity_key)
                    if not isinstance(stored, dict):
                        stored = {"kind": kind, "id": entity["id"], "sites": {}}
                        atlas["entities"][entity_key] = stored
                        changed = True
                    metadata = {
                        "name": str(entity.get("name") or "").strip(),
                        "description": str(entity.get("description") or "").strip(),
                    }
                    if kind == "npc":
                        metadata.update({"attackable": entity.get("attackable") is True,
                                         "stats": entity.get("stats") or {}})
                    else:
                        metadata.update({
                            "commands": [str(value or "").strip()
                                         for value in entity.get("commands") or []][:2],
                        })
                    if any(stored.get(name) != value for name, value in metadata.items()):
                        stored.update(metadata)
                        changed = True
                    direction = entity.get("dir")
                    site_key = _atlas_site_key(entity["x"], entity["z"], direction)
                    sites = stored.setdefault("sites", {})
                    site_facts = {"x": entity["x"], "z": entity["z"]}
                    if isinstance(direction, int):
                        site_facts["dir"] = direction
                    if kind != "npc":
                        site_facts.update({
                            "blocks_movement": entity.get("blocks_movement") is True,
                            "projectiles_pass": entity.get("projectiles_pass") is True,
                        })
                    old = sites.get(site_key)
                    if not isinstance(old, dict):
                        sites[site_key] = {
                            **site_facts, "first_seen": observed_ms,
                            "last_seen": observed_ms, "sightings": 1,
                        }
                        changed = True
                    elif any(old.get(name) != value for name, value in site_facts.items()) \
                            or _atlas_refresh(old, observed_ms):
                        old.update(site_facts)
                        old["last_seen"] = observed_ms
                        old["sightings"] = int(old.get("sightings", 0)) + 1
                        changed = True
                    limit = (NAVIGATION_ATLAS_NPC_SITES if kind == "npc"
                             else NAVIGATION_ATLAS_STATIC_SITES)
                    if len(sites) > limit:
                        for remove in sorted(
                                sites, key=lambda key: sites[key].get("last_seen", 0))[
                                    :len(sites) - limit]:
                            del sites[remove]
                            changed = True

            if changed:
                atlas["updated_ms"] = observed_ms
                game_reflex.atomic_write(
                    navigation_atlas_path(), json.dumps(atlas, indent=2) + "\n")
    except OSError:
        # Observation must never prevent the next game action.
        return


def learned_navigation_portals(atlas: dict | None = None) -> list[dict]:
    """Openable blockers learned from ordinary client packets/cache."""
    portals = []
    atlas = load_navigation_atlas() if atlas is None else atlas
    for entity in atlas["entities"].values():
        if not isinstance(entity, dict) or entity.get("kind") not in ("object", "bound"):
            continue
        commands = {_normalise_landmark_text(value)
                    for value in entity.get("commands") or []}
        if "open" not in commands or not isinstance(entity.get("id"), int):
            continue
        for site in (entity.get("sites") or {}).values():
            if not isinstance(site, dict) or site.get("blocks_movement") is not True \
                    or not isinstance(site.get("x"), int) \
                    or not isinstance(site.get("z"), int):
                continue
            portals.append({"kind": entity["kind"], "id": entity["id"],
                            "x": site["x"], "z": site["z"],
                            "dir": site.get("dir", 0)})
    return sorted(portals, key=lambda item: (
        item["kind"], item["x"], item["z"], item["id"], item["dir"]))


def learned_navigation_blockers(start_x: int, start_z: int, target_x: int,
                                target_z: int, atlas: dict | None = None) -> list[dict]:
    """Observed collision geometry relevant to one complete-cache query.

    Static definitions supply footprint and collision type in the client; its
    packets supply the placement direction that the landscape cache lacks.
    Bound the transfer to a generous corridor around this route so a mature
    world atlas cannot make every request grow forever.
    """
    atlas = load_navigation_atlas() if atlas is None else atlas
    low_x = min(start_x, target_x) - NAVIGATION_BLOCKER_MARGIN_TILES
    high_x = max(start_x, target_x) + NAVIGATION_BLOCKER_MARGIN_TILES
    low_z = min(start_z, target_z) - NAVIGATION_BLOCKER_MARGIN_TILES
    high_z = max(start_z, target_z) + NAVIGATION_BLOCKER_MARGIN_TILES
    blockers = []
    for entity in atlas["entities"].values():
        if not isinstance(entity, dict) \
                or entity.get("kind") not in ("object", "bound") \
                or not isinstance(entity.get("id"), int):
            continue
        for site in (entity.get("sites") or {}).values():
            if not isinstance(site, dict) or site.get("blocks_movement") is not True \
                    or not isinstance(site.get("x"), int) \
                    or not isinstance(site.get("z"), int) \
                    or not low_x <= site["x"] <= high_x \
                    or not low_z <= site["z"] <= high_z:
                continue
            direction = site.get("dir")
            last_seen = site.get("last_seen")
            blockers.append({"kind": entity["kind"], "id": entity["id"],
                             "x": site["x"], "z": site["z"],
                             "dir": direction if isinstance(direction, int) else 0,
                             "last_seen": last_seen if isinstance(last_seen, int) else 0})
    if len(blockers) > NAVIGATION_BLOCKER_MAX:
        blockers = sorted(blockers, key=lambda item: (
            -item["last_seen"], item["kind"], item["x"], item["z"],
            item["id"], item["dir"]))[:NAVIGATION_BLOCKER_MAX]
    for blocker in blockers:
        blocker.pop("last_seen", None)
    return sorted(blockers, key=lambda item: (
        item["kind"], item["x"], item["z"], item["id"], item["dir"]))


def world_landmark_candidates(query: str, kind: str | None = None) -> list[dict]:
    """Resolve semantic places from this player's own observation atlas."""
    wanted = _normalise_landmark_text(query)
    if not wanted:
        return []
    candidates = []
    for entity in load_navigation_atlas()["entities"].values():
        if not isinstance(entity, dict) or entity.get("kind") not in ("npc", "object", "bound") \
                or kind not in (None, entity.get("kind")):
            continue
        normal_name = _normalise_landmark_text(entity.get("name", ""))
        normal_description = _normalise_landmark_text(entity.get("description", ""))
        name_match = wanted in normal_name
        description_match = wanted in normal_description
        if not name_match and not description_match:
            continue
        # "To Varrock" describes where a sign points, not where the sign is.
        # An exact query for the whole inscription may deliberately select the
        # sign itself; a bare place name must not silently become its location.
        directional_cue = bool(
            not name_match and wanted != normal_description
            and ("sign" in normal_name or normal_description.startswith("to ")))
        sites = [site for site in (entity.get("sites") or {}).values()
                 if isinstance(site, dict) and isinstance(site.get("x"), int)
                 and isinstance(site.get("z"), int)]
        if entity["kind"] == "npc" and sites:
            sites = [max(sites, key=lambda site: site.get("last_seen", 0))]
        commands = entity.get("commands") or []
        for site in sites:
            candidates.append({
                "kind": entity["kind"], "id": entity["id"],
                "name": entity.get("name") or "?",
                "description": entity.get("description") or "",
                "command1": commands[0] if commands else "",
                "command2": commands[1] if len(commands) > 1 else "",
                "x": site["x"], "z": site["z"], "dir": site.get("dir"),
                "first_seen": site.get("first_seen"),
                "last_seen": site.get("last_seen"),
                "sightings": site.get("sightings", 1),
                "match": ("directional-cue" if directional_cue else
                          "name" if name_match else "description"),
            })
    return sorted(candidates, key=lambda item: (
        item["match"] == "directional-cue", item["kind"],
        item["name"].casefold(), item["x"], item["z"], item["id"]))


def observed_arrival_walkability(target_x: int, target_z: int, arrive: int):
    """Return False only when the entire requested area is observed blocked.

    Missing tiles are unknown rather than open: the complete client-cache planner
    remains responsible for terrain this character has not observed yet.
    """
    tiles = load_navigation_atlas()["tiles"]
    saw_unknown = False
    for x in range(target_x - arrive, target_x + arrive + 1):
        for z in range(target_z - arrive, target_z + arrive + 1):
            tile = tiles.get(f"{x},{z}")
            if not isinstance(tile, dict) or not isinstance(tile.get("blocked"), bool):
                saw_unknown = True
            elif tile["blocked"] is False:
                return True
    return None if saw_unknown else False


def refuse_observed_blocked_destination(target_x: int, target_z: int, arrive: int) -> None:
    if observed_arrival_walkability(target_x, target_z, arrive) is False:
        die(f"destination area around ({target_x},{target_z}) is already observed "
            "as entirely movement-blocked; resolve the intended landmark instead "
            "of routing toward that coordinate")


def _navigation_link_key(start_x: int, start_z: int, end_x: int, end_z: int) -> str:
    return f"{start_x},{start_z}>{end_x},{end_z}"


def record_navigation_link(start_x: int, start_z: int, end_x: int, end_z: int,
                           landmark: dict | None = None) -> None:
    """Remember one actually completed client-side walk as a directed edge.

    The activity or objective chooses a destination. A verified ordinary walk
    between two tiles is game-wide movement evidence and can serve any later
    activity, while every reuse still passes through live collision checks.
    """
    if (start_x, start_z) == (end_x, end_z):
        return
    if max(abs(end_x - start_x), abs(end_z - start_z)) \
            > NAVIGATION_LEG_MAX_PATH_TILES:
        # Larger settlements can contain an unseen portal transition. Never
        # promote one of those to an ordinary reusable walk edge.
        return
    observed_ms = now_ms()
    game_dir().mkdir(parents=True, exist_ok=True)
    try:
        with open(navigation_atlas_lock_path(), "a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            atlas = load_navigation_atlas()
            key = _navigation_link_key(start_x, start_z, end_x, end_z)
            old = atlas["links"].get(key)
            successes = int(old.get("successes", 0)) + 1 \
                if isinstance(old, dict) else 1
            link = {
                "from": [start_x, start_z], "to": [end_x, end_z],
                "distance": max(abs(end_x - start_x), abs(end_z - start_z)),
                "successes": successes,
                "first_success": (old.get("first_success", observed_ms)
                                  if isinstance(old, dict) else observed_ms),
                "last_success": observed_ms,
                "disabled": False,
            }
            if isinstance(old, dict) and isinstance(old.get("failures"), int):
                link["failures"] = old["failures"]
            if isinstance(landmark, dict) and landmark.get("name"):
                link["destination"] = {
                    field: landmark[field]
                    for field in ("kind", "id", "name", "query")
                    if field in landmark
                }
            atlas["links"][key] = link
            if len(atlas["links"]) > NAVIGATION_ATLAS_LINKS:
                removable = sorted(
                    atlas["links"],
                    key=lambda item: atlas["links"][item].get("last_success", 0))
                for item in removable[:len(atlas["links"]) - NAVIGATION_ATLAS_LINKS]:
                    del atlas["links"][item]
            atlas["updated_ms"] = observed_ms
            game_reflex.atomic_write(
                navigation_atlas_path(), json.dumps(atlas, indent=2) + "\n")
    except OSError:
        return


def disable_navigation_link(key: str) -> None:
    """Retire a remembered edge that failed its current live collision check."""
    if not key:
        return
    try:
        with open(navigation_atlas_lock_path(), "a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            atlas = load_navigation_atlas()
            link = atlas["links"].get(key)
            if not isinstance(link, dict):
                return
            link["disabled"] = True
            link["failures"] = int(link.get("failures", 0)) + 1
            link["last_failure"] = now_ms()
            atlas["updated_ms"] = link["last_failure"]
            game_reflex.atomic_write(
                navigation_atlas_path(), json.dumps(atlas, indent=2) + "\n")
    except OSError:
        return


def verified_navigation_path(start_x: int, start_z: int, target_x: int,
                             target_z: int, arrive: int) -> list[list]:
    """Return the cheapest chain of actually completed directed walk edges."""
    start = (start_x, start_z)
    adjacency = {}
    for key, link in load_navigation_atlas()["links"].items():
        if not isinstance(link, dict) or link.get("disabled") is True \
                or not isinstance(link.get("from"), list) \
                or not isinstance(link.get("to"), list) \
                or len(link["from"]) != 2 or len(link["to"]) != 2 \
                or not all(isinstance(value, int)
                           for value in link["from"] + link["to"]):
            continue
        origin, destination = tuple(link["from"]), tuple(link["to"])
        distance = int(link.get("distance") or
                       max(abs(destination[0] - origin[0]),
                           abs(destination[1] - origin[1])))
        if distance <= 0 or distance > NAVIGATION_LEG_MAX_PATH_TILES:
            continue
        adjacency.setdefault(origin, []).append((distance, destination, key))
    if start not in adjacency:
        return []
    queue = [(0, start)]
    best = {start: 0}
    previous = {}
    goal = None
    while queue and len(best) <= NAVIGATION_ATLAS_LINKS:
        cost, node = heapq.heappop(queue)
        if cost != best.get(node):
            continue
        if max(abs(node[0] - target_x), abs(node[1] - target_z)) <= arrive:
            goal = node
            break
        for distance, destination, key in adjacency.get(node, []):
            new_cost = cost + distance
            if new_cost >= best.get(destination, sys.maxsize):
                continue
            best[destination] = new_cost
            previous[destination] = (node, key)
            heapq.heappush(queue, (new_cost, destination))
    if goal is None or goal == start:
        return []
    path = []
    node = goal
    while node != start:
        origin, key = previous[node]
        path.append([node[0], node[1], key])
        node = origin
    path.reverse()
    return path


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


def loop_erase_movement_segment(points: list) -> tuple:
    """Return the useful connected path after removing observed cycles.

    If a tile is visited again, every point after its earlier occurrence is a
    branch that returned to where it began. Recovery should retrace the
    remaining route, not replay that already-observed loop in reverse.
    """
    path = []
    positions = {}
    for point in points:
        key = (point["x"], point["z"])
        previous = positions.get(key)
        if previous is None:
            positions[key] = len(path)
            path.append(point)
            continue
        abandoned = path[previous + 1:]
        for old in abandoned:
            positions.pop((old["x"], old["z"]), None)
        path = path[:previous + 1]
    return path, len(points) - len(path)


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
            or request.get("status") not in ("active", "blocked", "diverged") \
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


def load_follow():
    try:
        request = json.loads(follow_path().read_text())
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError):
        return {"status": "invalid"}
    if not isinstance(request, dict) or request.get("v") != 1 \
            or not isinstance(request.get("player"), str) \
            or not request["player"].strip() or "\n" in request["player"] \
            or not isinstance(request.get("within"), int) \
            or not 1 <= request["within"] <= 10 \
            or not isinstance(request.get("objective"), str) \
            or request.get("status") not in ("active", "blocked", "cancelling"):
        return {"status": "invalid"}
    for key in ("last_x", "last_z"):
        if key in request and not isinstance(request[key], int):
            return {"status": "invalid"}
    # The method binding (spec rule 7g) is optional in the schema so that a
    # pre-binding record still LOADS — prepare_follow cancels it honestly
    # instead of this validator quietly calling it invalid.
    for key in ("plan", "activity", "cancel_reason"):
        if key in request and not isinstance(request[key], str):
            return {"status": "invalid"}
    if "rev" in request and (not isinstance(request["rev"], int)
                              or request["rev"] < 1):
        return {"status": "invalid"}
    return request


def save_follow(request: dict) -> None:
    with follow_state_lock():
        request.setdefault("rev", 1)
        game_reflex.atomic_write(follow_path(), json.dumps(request, indent=2) + "\n")


def clear_follow() -> None:
    with follow_state_lock():
        try:
            follow_path().unlink()
        except FileNotFoundError:
            pass


def replace_follow_if_current(expected: dict, replacement: dict | None) -> bool:
    """Compare and mutate under one cross-process lock.

    `set_ts` is the commitment generation and `rev` is its update generation.
    A route selection, direct clear, target refresh, or newer follow can
    therefore win while an older action is in flight without that older
    settlement resurrecting or rewinding itself afterwards.
    """
    with follow_state_lock():
        current = load_follow()
        if current is None or current.get("status") == "invalid" \
                or current.get("set_ts") != expected.get("set_ts") \
                or current.get("status") != expected.get("status") \
                or current.get("rev") != expected.get("rev"):
            return False
        if replacement is None:
            try:
                follow_path().unlink()
            except FileNotFoundError:
                return False
        else:
            replacement["rev"] = int(current.get("rev") or 0) + 1
            game_reflex.atomic_write(
                follow_path(), json.dumps(replacement, indent=2) + "\n")
        return True


def goal_invariants_path() -> Path:
    return game_dir() / "goal-invariants.json"


GOAL_REQUIREMENT_KINDS = ("arrive", "entity", "interface", "inventory_has", "message")
GOAL_INTERFACES = ("bank", "shop")
GOAL_ENTITY_COLLECTIONS = ("players", "npcs", "objects", "bounds", "ground_items")
GOAL_ARRIVE_DEFAULT_TOL = 2


def load_goal():
    try:
        goal = json.loads(goal_invariants_path().read_text())
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError):
        return {"status": "invalid"}
    if not isinstance(goal, dict) or goal.get("v") != 1 \
            or not isinstance(goal.get("text"), str) or not goal["text"].strip() \
            or not isinstance(goal.get("requires"), list) or not goal["requires"]:
        return {"status": "invalid"}
    return goal


def save_goal(goal: dict) -> None:
    game_dir().mkdir(parents=True, exist_ok=True)
    game_reflex.atomic_write(goal_invariants_path(),
                             json.dumps(goal, indent=2) + "\n")


def clear_goal(reason: str) -> bool:
    goal = load_goal()
    if goal is None:
        return False
    try:
        goal_invariants_path().unlink()
    except FileNotFoundError:
        return False
    flush_events([{"ts": now_ms(), "kind": "goal-cleared", "reason": reason,
                   "goal": goal.get("text")}])
    return True


def parse_goal_requirement(pair: str) -> dict:
    """One --require k=v into a validated requirement (spec rule 7h). The
    vocabulary is closed; anything else is refused loudly, never stored."""
    if "=" not in pair:
        die(f"goal requirement '{pair}' is not KIND=VALUE")
    kind, value = pair.split("=", 1)
    kind = kind.strip()
    if kind == "arrive":
        parts = value.split(",")
        if len(parts) not in (2, 3):
            die(f"arrive takes X,Z[,TOL]: '{value}'")
        try:
            numbers = [int(part) for part in parts]
        except ValueError:
            die(f"arrive coordinates must be integers: '{value}'")
        tol = numbers[2] if len(numbers) == 3 else GOAL_ARRIVE_DEFAULT_TOL
        if not 0 <= tol <= 10:
            die(f"arrive tolerance must be 0..10: {tol}")
        return {"kind": "arrive", "x": numbers[0], "z": numbers[1], "tol": tol}
    if kind == "entity":
        parts = value.split(":")
        if len(parts) not in (3, 4):
            die(f"entity takes collection:field:value[:within]: '{value}'")
        collection, field, wanted = parts[0], parts[1], parts[2]
        if collection not in GOAL_ENTITY_COLLECTIONS:
            die(f"entity collection must be one of {GOAL_ENTITY_COLLECTIONS}: '{collection}'")
        if field not in ("name", "id", "sidx"):
            die(f"entity field must be name, id or sidx: '{field}'")
        if not wanted:
            die("entity value must be non-empty")
        requirement = {"kind": "entity", "collection": collection,
                       "field": field, "value": wanted}
        if field in ("id", "sidx"):
            try:
                requirement["value"] = int(wanted)
            except ValueError:
                die(f"entity {field} must be an integer: '{wanted}'")
        if len(parts) == 4:
            try:
                within = int(parts[3])
            except ValueError:
                die(f"entity within must be an integer: '{parts[3]}'")
            if not 1 <= within <= 50:
                die(f"entity within must be 1..50: {within}")
            requirement["within"] = within
        return requirement
    if kind == "interface":
        if value not in GOAL_INTERFACES:
            die(f"interface must be one of {GOAL_INTERFACES}: '{value}'")
        return {"kind": "interface", "interface": value}
    if kind == "inventory_has":
        try:
            return {"kind": "inventory_has", "item": int(value)}
        except ValueError:
            die(f"inventory_has takes an item id: '{value}'")
    if kind == "message":
        if not value.strip() or "\n" in value:
            die("message takes a non-empty single-line fragment")
        return {"kind": "message", "text": value}
    die(f"unknown goal requirement kind '{kind}' "
        f"(the vocabulary is {GOAL_REQUIREMENT_KINDS})")


def goal_requirement_met(requirement: dict, snap: dict) -> bool:
    """Answerable from the snapshot alone, fail-safe like rule 4's triggers:
    a field the snapshot does not carry makes the requirement false."""
    kind = requirement.get("kind")
    px, pz = snap.get("x"), snap.get("z")
    if kind == "arrive":
        return isinstance(px, int) and isinstance(pz, int) \
            and max(abs(px - requirement["x"]),
                    abs(pz - requirement["z"])) <= requirement["tol"]
    if kind == "entity":
        matches = matching_state_entities(snap, requirement)
        within = requirement.get("within")
        if within is None:
            return bool(matches)
        if not isinstance(px, int) or not isinstance(pz, int):
            return False
        return any(max(abs(entity["x"] - px), abs(entity["z"] - pz)) <= within
                   for entity in matches)
    if kind == "interface":
        return snap.get(f"{requirement['interface']}_open") is True
    if kind == "inventory_has":
        return inventory_quantity(snap, requirement["item"]) > 0
    if kind == "message":
        wanted = requirement["text"].casefold()
        return any(wanted in str(message.get("text", "")).casefold()
                   for message in snap.get("messages") or []
                   if isinstance(message, dict))
    return False


def describe_goal_requirement(requirement: dict) -> str:
    kind = requirement.get("kind")
    if kind == "arrive":
        return f"arrive=({requirement['x']},{requirement['z']})±{requirement['tol']}"
    if kind == "entity":
        within = requirement.get("within")
        suffix = f":within{within}" if within is not None else ""
        return (f"entity={requirement['collection']}:{requirement['field']}:"
                f"{requirement['value']}{suffix}")
    if kind == "interface":
        return f"interface={requirement['interface']}"
    if kind == "inventory_has":
        return f"inventory_has={requirement['item']}"
    if kind == "message":
        return f"message={requirement['text']}"
    return json.dumps(requirement, separators=(",", ":"))


def evaluate_goal(goal: dict, snap: dict) -> dict:
    """All requirements against one snapshot. The shared-resource distinction
    (spec rule 7h): an open interface plus an unmet place/target requirement is
    the WRONG copy of a universal resource, never destination success."""
    met, unmet = [], []
    for requirement in goal["requires"]:
        (met if goal_requirement_met(requirement, snap) else unmet) \
            .append(requirement)
    shared_resource = any(item.get("kind") == "interface" for item in met) \
        and any(item.get("kind") in ("arrive", "entity") for item in unmet)
    return {"met": met, "unmet": unmet, "all_met": not unmet,
            "shared_resource": shared_resource}


def state_entity_matches(entity: dict, field: str, value) -> bool:
    actual = entity.get(field)
    if isinstance(value, str):
        return isinstance(actual, str) and actual.casefold() == value.casefold()
    return actual == value


def matching_state_entities(snap: dict, selector: dict) -> list[dict]:
    collection = snap.get(selector["collection"]) or []
    return [entity for entity in collection
            if isinstance(entity, dict)
            and state_entity_matches(entity, selector["field"], selector["value"])
            and isinstance(entity.get("x"), int) and isinstance(entity.get("z"), int)]


def nearest_state_entity(snap: dict, selector: dict):
    px, pz = snap.get("x"), snap.get("z")
    if not isinstance(px, int) or not isinstance(pz, int):
        return None
    candidates = matching_state_entities(snap, selector)
    if not candidates:
        return None

    def candidate_key(entity):
        path = entity.get("path_distance")
        if isinstance(path, int) and path >= 0:
            return (0, path, entity.get("sidx", 0), entity["x"], entity["z"])
        return (1, max(abs(entity["x"] - px), abs(entity["z"] - pz)),
                abs(entity["x"] - px) + abs(entity["z"] - pz),
                entity.get("sidx", 0))

    return min(candidates, key=candidate_key)


def prepare_follow(snap: dict, objective: str, activity: str):
    request = load_follow()
    if request is None or request.get("status") == "invalid":
        return request, None
    if request.get("status") == "cancelling":
        # Already ending; step_once owns the stop's postcondition. Nothing
        # here may reacquire the target or write the record back to active.
        return request, None
    # Spec rule 7g: the follow binds the method that chose it — objective,
    # plan, and activity — and ends when any of them changes. A record
    # without the binding predates the rule and cancels on first sight.
    changed = None
    for name, recorded, current in (
            ("objective", request.get("objective"), objective),
            ("plan", request.get("plan"), read_plan()),
            ("activity", request.get("activity"), activity)):
        if not isinstance(recorded, str):
            changed = (name, "method-binding-missing", recorded, current)
            break
        if recorded != current:
            changed = (name, f"{name}-changed", recorded, current)
            break
    if changed is not None:
        name, reason, recorded, current = changed
        events = [{"ts": now_ms(), "kind": "follow-cancelled",
                   "reason": reason, "binding": name,
                   "player": request["player"],
                   "from": recorded, "to": current}]
        if snap.get("logged_in") is True and snap.get("walking") is True:
            # The native follow or its last walk still owns the body. Keep
            # the record as a cancelling stub so every pass retries the stop
            # and nothing — including a racing in-flight leg — refires it.
            previous = request
            request = dict(request)
            request.update({"status": "cancelling", "cancel_reason": reason,
                            "cancel_ts": now_ms()})
            if not replace_follow_if_current(previous, request):
                return load_follow(), None
            flush_events(events)
            return request, None
        if not replace_follow_if_current(request, None):
            return load_follow(), None
        events.append({"ts": now_ms(), "kind": "follow-stopped",
                       "player": request["player"], "reason": reason,
                       "walking": False,
                       "x": snap.get("x"), "z": snap.get("z")})
        flush_events(events)
        return None, None
    selector = {"collection": "players", "field": "name", "value": request["player"]}
    target = nearest_state_entity(snap, selector)
    if target is not None:
        previous = dict(request)
        target_changed = (request.get("last_x"), request.get("last_z")) \
            != (target["x"], target["z"])
        request.update({"last_x": target["x"], "last_z": target["z"],
                        "last_sidx": target.get("sidx"), "last_seen_ts": now_ms()})
        if target_changed and isinstance(snap.get("x"), int) \
                and isinstance(snap.get("z"), int):
            request = {key: value for key, value in request.items()
                       if key not in ("waypoints", "next_portal")
                       and not key.startswith("planner_")}
            request.update({
                "visited": [[snap["x"], snap["z"]]],
                "best_distance_sq": navigation_distance_sq(
                    snap["x"], snap["z"], target["x"], target["z"]),
                "nonclosing_legs": 0})
        if request.get("status") == "blocked" and target_changed:
            request = {key: value for key, value in request.items()
                       if not key.startswith("blocked_")}
            request["status"] = "active"
        if not replace_follow_if_current(previous, request):
            return load_follow(), target
    elif request.get("status") == "blocked" \
            and route_obstacle_signature(snap) != request.get("blocked_signature"):
        previous = request
        request = {key: value for key, value in request.items()
                   if not key.startswith("blocked_")}
        request["status"] = "active"
        if not replace_follow_if_current(previous, request):
            return load_follow(), target
    return request, target


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


def client_cache_route_plan(start_x: int, start_z: int, target_x: int,
                            target_z: int, arrive: int) -> dict:
    """Ask the running client to plan from its own landscape cache.

    The request/result files are a read-only query door separate from the
    action slot. The game server is neither contacted nor aware of it.
    """
    directory = state_dir()
    directory.mkdir(parents=True, exist_ok=True)
    request_path = directory / "route-request.json"
    result_path = directory / "route-result.json"
    lock_path = directory / "route-request.lock"
    request_id = now_ms() * 1000 + os.getpid() % 1000
    try:
        with open(lock_path, "a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            lines = [f"id={request_id}", f"ts={now_ms()}",
                     f"start_x={start_x}", f"start_z={start_z}",
                     f"x={target_x}", f"z={target_z}", f"arrive={arrive}"]
            atlas = load_navigation_atlas()
            portals = learned_navigation_portals(atlas)
            if portals:
                lines.append("learned_portals=" + ";".join(
                    f"{portal['kind']},{portal['id']},{portal['x']},"
                    f"{portal['z']},{portal['dir']}" for portal in portals))
            blockers = learned_navigation_blockers(
                start_x, start_z, target_x, target_z, atlas)
            if blockers:
                lines.append("learned_blockers=" + ";".join(
                    f"{blocker['kind']},{blocker['id']},{blocker['x']},"
                    f"{blocker['z']},{blocker['dir']}" for blocker in blockers))
            game_reflex.atomic_write(request_path, "\n".join(lines) + "\n")
            deadline = time.monotonic() + CLIENT_ROUTE_TIMEOUT_S
            response = None
            while time.monotonic() < deadline:
                try:
                    envelope = json.loads(result_path.read_text())
                    if envelope.get("id") == request_id:
                        response = envelope.get("plan")
                        break
                except (OSError, ValueError, AttributeError):
                    pass
                time.sleep(0.02)
    except OSError as exc:
        return {"status": "error",
                "reason": f"client-cache-planner-io:{exc.__class__.__name__}"}
    if response is None:
        return {"status": "error", "reason": "client-cache-planner-timeout"}
    if not isinstance(response, dict) \
            or response.get("status") not in ("ok", "error") \
            or response.get("source") != "client-cache":
        return {"status": "error", "reason": "client-cache-planner-invalid-response"}
    if response["status"] == "error":
        reason = response.get("reason")
        return {"status": "error",
                "reason": reason if isinstance(reason, str) else "client-cache-planner-error"}
    waypoints = response.get("waypoints")
    if not isinstance(waypoints, list) or len(waypoints) > 512 \
            or any(not isinstance(point, list) or len(point) != 2
                   or not all(isinstance(value, int) for value in point)
                   for point in waypoints):
        return {"status": "error", "reason": "client-cache-planner-invalid-waypoints"}
    portals = response.get("portals", [])
    if not isinstance(portals, list) or len(portals) > 64 \
            or any(not isinstance(portal, dict)
                   or portal.get("kind") not in ("object", "bound")
                   or not all(isinstance(portal.get(key), int)
                              for key in ("id", "x", "z", "dir"))
                   or not isinstance(portal.get("from"), list)
                   or len(portal["from"]) != 2
                   or not all(isinstance(value, int) for value in portal["from"])
                   for portal in portals):
        return {"status": "error", "reason": "client-cache-planner-invalid-portals"}
    return {"status": response["status"], "waypoints": waypoints,
            "steps": response.get("steps"), "expanded": response.get("expanded"),
            "remaining_cost": response.get("remaining_cost"), "portals": portals}


def _observed_closed_portal(snap: dict, portal: dict) -> bool:
    collection = "objects" if portal.get("kind") == "object" else "bounds"
    return any(entity.get("id") == portal.get("id")
               and entity.get("x") == portal.get("x")
               and entity.get("z") == portal.get("z")
               and (collection != "bounds" or entity.get("dir") == portal.get("dir"))
               and entity.get("blocks_movement") is True
               for entity in snap.get(collection) or [] if isinstance(entity, dict))


def distinct_route_portals(portals: list[dict]) -> list[dict]:
    """Collapse the same wide door appearing on more than one path edge."""
    distinct = {}
    for portal in portals:
        key = tuple(portal.get(field) for field in ("kind", "id", "x", "z", "dir"))
        distinct.setdefault(key, portal)
    return list(distinct.values())


def semantic_portal_action(portal: dict) -> dict:
    """The exact loaded portal named by the client-cache path.

    x/z/dir are internal selector guards. Learned interact rules still accept
    only an object identity; the route/follow planner must never substitute a
    different nearby gate with the same definition id.
    """
    action = {"type": ("interact-object" if portal["kind"] == "object"
                       else "interact-bound"),
              "obj": portal["id"], "cmd": 1,
              "x": portal["x"], "z": portal["z"]}
    if portal["kind"] == "bound":
        action["dir"] = portal["dir"]
    return action


def prepare_follow_navigation(request: dict, target: dict | None,
                              snap: dict) -> tuple[dict | None, dict | None, str | None]:
    """Return one client-grounded action toward the current/last-seen player.

    The optional follow method is abandoned on planning or causal failure so
    it can never mask the binding current plan. It does not own a second route
    file and it never hands a far remembered tile to the live-region walker.
    """
    px, pz = snap.get("x"), snap.get("z")
    tx = target.get("x") if target is not None else request.get("last_x")
    tz = target.get("z") if target is not None else request.get("last_z")
    if not all(isinstance(value, int) for value in (px, pz, tx, tz)):
        return request, None, None
    if max(abs(px - tx), abs(pz - tz)) <= request["within"]:
        return request, None, None
    plan = client_cache_route_plan(px, pz, tx, tz, request["within"])
    if plan.get("status") != "ok":
        reason = str(plan.get("reason") or "client-cache-planner-error")
        replace_follow_if_current(request, None)
        flush_events([{"ts": now_ms(), "kind": "follow-abandoned",
                       "player": request["player"], "reason": reason,
                       "controller": "self", "next": "current-plan"}])
        return None, None, reason
    portals = plan.get("portals") or []
    next_portal = portals[0] if portals else None
    updated = {key: value for key, value in request.items()
               if key not in ("waypoints", "next_portal")
               and not key.startswith("planner_")}
    updated.update({"planner": "client-cache",
                    "planner_ts": now_ms(),
                    "planner_target_x": tx, "planner_target_z": tz,
                    "waypoints": plan.get("waypoints") or []})
    if next_portal is not None:
        updated["next_portal"] = next_portal
    if not replace_follow_if_current(request, updated):
        return load_follow(), None, "commitment-replaced"
    request = updated
    if next_portal is not None and next_portal.get("from") == [px, pz] \
            and _observed_closed_portal(snap, next_portal):
        return request, semantic_portal_action(next_portal), None
    waypoints = plan.get("waypoints") or []
    if not waypoints:
        replace_follow_if_current(request, None)
        reason = "client-cache-route-empty"
        flush_events([{"ts": now_ms(), "kind": "follow-abandoned",
                       "player": request["player"], "reason": reason,
                       "controller": "self", "next": "current-plan"}])
        return None, None, reason
    leg_x, leg_z = waypoints[0]
    return request, {"type": "walk", "x": leg_x, "z": leg_z,
                     "arrive": (request["within"] if len(waypoints) == 1 else 0),
                     "route_step": NAVIGATION_ROUTE_STEP_TILES,
                     "max_path": NAVIGATION_LEG_MAX_PATH_TILES}, None


def prepare_client_cache_route(route: dict, snap: dict) -> tuple[dict, tuple | None]:
    """Plan the next local leg without replacing the final destination."""
    px, pz = snap.get("x"), snap.get("z")
    if not isinstance(px, int) or not isinstance(pz, int):
        return route, None
    plan = client_cache_route_plan(
        px, pz, route["x"], route["z"], route["arrive"])
    if plan["status"] == "error":
        blocked = dict(route)
        blocked.update({"status": "blocked", "blocked_reason": plan["reason"],
                        "blocked_ts": now_ms(), "planner": "client-cache"})
        save_route(blocked)
        return blocked, None
    waypoints = plan.get("waypoints") or []
    portals = plan.get("portals") or []
    distinct_portals = distinct_route_portals(portals)
    if len(distinct_portals) > 1 and not route.get("landmark") \
            and not route.get("portal_authorized_reason"):
        blocked = {key: value for key, value in route.items()
                   if key != "next_portal"}
        blocked.update({"status": "blocked",
                        "blocked_reason": "raw-route-crosses-multiple-portals",
                        "blocked_ts": now_ms(), "planner": "client-cache",
                        "planner_status": plan["status"],
                        "planned_from": [px, pz], "waypoints": waypoints,
                        "route_portal_count": len(distinct_portals),
                        "blocked_signature": route_obstacle_signature(snap)})
        save_route(blocked)
        return blocked, None
    next_portal = portals[0] if portals else None
    if next_portal is not None and next_portal["from"] == [px, pz] \
            and _observed_closed_portal(snap, next_portal):
        planned = {key: value for key, value in route.items()
                   if key != "next_portal" and not key.startswith("blocked_")}
        planned.update({"status": "active", "planner": "client-cache",
                        "planner_status": plan["status"],
                        "planned_from": [px, pz], "waypoints": waypoints,
                        "next_portal": next_portal,
                        "planner_steps": plan.get("steps"),
                        "planner_expanded": plan.get("expanded"),
                        "planner_ts": now_ms()})
        save_route(planned)
        return planned, None
    if not waypoints:
        blocked = dict(route)
        reason = "client-cache-route-empty"
        blocked.update({"status": "blocked", "blocked_reason": reason,
                        "blocked_ts": now_ms(), "planner": "client-cache",
                        "planner_status": plan["status"], "planned_from": [px, pz],
                        "waypoints": [],
                        "blocked_signature": route_obstacle_signature(snap)})
        save_route(blocked)
        return blocked, None
    planned = {key: value for key, value in route.items()
               if key != "next_portal"}
    planned.update({"status": "active", "planner": "client-cache",
                    "planner_status": plan["status"], "planned_from": [px, pz],
                    "waypoints": waypoints, "planner_steps": plan.get("steps"),
                    "planner_expanded": plan.get("expanded"),
                    "planner_ts": now_ms()})
    if next_portal is not None:
        planned["next_portal"] = next_portal
    if plan.get("remaining_cost") is not None:
        planned["planner_remaining_cost"] = plan["remaining_cost"]
    save_route(planned)
    return planned, tuple(waypoints[0])


def prepare_navigation_route(route: dict, snap: dict) -> tuple[dict, tuple | None]:
    """Prefer a chain already walked successfully, then ask the client cache."""
    px, pz = snap.get("x"), snap.get("z")
    if isinstance(px, int) and isinstance(pz, int):
        path = verified_navigation_path(
            px, pz, route["x"], route["z"], route["arrive"])
        if path:
            planned = {key: value for key, value in route.items()
                       if key != "next_portal" and not key.startswith("blocked_")}
            planned.update({
                "status": "active", "planner": "verified-links",
                "planned_from": [px, pz],
                "waypoints": [[point[0], point[1]] for point in path],
                "graph_link": path[0][2], "planner_ts": now_ms(),
            })
            save_route(planned)
            return planned, (path[0][0], path[0][1])
    return prepare_client_cache_route(route, snap)


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
            elif key == "entity_visible":
                if not isinstance(val, dict) \
                        or set(val) != {"collection", "field", "value"} \
                        or val.get("collection") not in ENTITY_COLLECTIONS \
                        or val.get("field") not in ENTITY_SELECTOR_FIELDS \
                        or not isinstance(val.get("value"), (str, int)) \
                        or isinstance(val.get("value"), bool) \
                        or isinstance(val.get("value"), str) and not val["value"].strip():
                    bad(f"{where}: trigger.entity_visible must be "
                        "{\"collection\":players|npcs|objects|bounds|ground_items,"
                        "\"field\":name|id|sidx,\"value\":string|int}")
            elif key in ("npc_visible", "object_visible", "bound_visible",
                         "ground_item_visible", "shop_item_visible", "bank_item_visible",
                         "inventory_has", "inventory_lacks"):
                if not isinstance(val, int) or val < 0:
                    bad(f"{where}: trigger.{key} must be a non-negative type/item id")
            elif key in ("inventory_slots_below", "inventory_slots_at_least"):
                if not isinstance(val, int) or not 0 <= val <= 30:
                    bad(f"{where}: trigger.{key} must be an integer from 0 to 30")
            elif key == "fatigue_below":
                if not isinstance(val, int) or isinstance(val, bool) \
                        or not 1 <= val <= 101:
                    bad(f"{where}: trigger.fatigue_below must be an integer from 1 to 101")
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
        elif atype == "attack-npc":
            if not set(action) <= {"type", "npc", "within"} \
                    or not isinstance(action.get("npc"), int) or action["npc"] < 0:
                bad(f"{where}: attack-npc takes npc=<type id> and optionally within")
            if "within" in action and (not isinstance(action["within"], int)
                                        or not 0 <= action["within"] <= 10):
                bad(f"{where}: attack-npc within must be an integer 0..10")
        elif atype == "interact-npc":
            if not set(action) <= {"type", "npc", "cmd", "within"} \
                    or not isinstance(action.get("npc"), int) or action["npc"] < 0:
                bad(f"{where}: interact-npc takes npc=<type id> and optionally cmd/within")
            if "cmd" in action and action["cmd"] not in (1, 2):
                bad(f"{where}: interact-npc cmd must be 1 or 2 (the def's menu commands)")
            if "within" in action and (not isinstance(action["within"], int)
                                        or not 0 <= action["within"] <= 10):
                bad(f"{where}: interact-npc within must be an integer 0..10")
        elif atype == "use-item-npc":
            if not set(action) <= {"type", "item", "npc", "within"} \
                    or not isinstance(action.get("item"), int) or action["item"] < 0 \
                    or not isinstance(action.get("npc"), int) or action["npc"] < 0:
                bad(f"{where}: use-item-npc takes item=<item id>, npc=<type id>, "
                    "and optionally within")
            if "within" in action and (not isinstance(action["within"], int)
                                        or not 0 <= action["within"] <= 10):
                bad(f"{where}: use-item-npc within must be an integer 0..10")
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
        elif atype == "approach-entity":
            if set(action) != {"type", "collection", "field", "value", "within"} \
                    or action.get("collection") not in ENTITY_COLLECTIONS \
                    or action.get("field") not in ENTITY_SELECTOR_FIELDS \
                    or not isinstance(action.get("value"), (str, int)) \
                    or isinstance(action.get("value"), bool) \
                    or isinstance(action.get("value"), str) and not action["value"].strip() \
                    or not isinstance(action.get("within"), int) \
                    or not 1 <= action["within"] <= 10:
                bad(f"{where}: approach-entity takes collection, field, value, "
                    "and within=1..10")
        elif atype == "follow-player":
            if set(action) != {"type", "name", "within"} \
                    or not isinstance(action.get("name"), str) \
                    or not action["name"].strip() or "\n" in action["name"] \
                    or not isinstance(action.get("within"), int) \
                    or not 1 <= action["within"] <= 10:
                bad(f"{where}: follow-player takes a non-empty player name and "
                    "within=1..10")
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


def read_plan() -> str:
    try:
        return plan_path().read_text().strip()
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
    """Latest fresh non-player game text, compact enough for a play verdict.

    Bridge message ids carry their wall-clock millisecond in the high digits.
    Old retained messages are history, not causal evidence for the current
    action or location, and must not be presented to Sol as current feedback.
    """
    snap_ts = snap.get("ts")
    for message in reversed(snap.get("messages") or []):
        if not isinstance(message, dict) \
                or message.get("channel") not in SYSTEM_FEEDBACK_CHANNELS:
            continue
        message_id = message.get("id")
        if isinstance(snap_ts, int) and isinstance(message_id, int) \
                and message_id >= 1_000_000_000_000 \
                and snap_ts - message_id // 1000 > 10_000:
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
    if condition == "duel_open":
        return snap.get("duel_open") is True
    if condition == "duel_confirm":
        duel = snap.get("duel")
        return isinstance(duel, dict) and duel.get("stage") == "confirm"
    if condition == "duel_closed":
        return snap.get("duel_open") is False
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
                "trade_open", "duel_open", "sleeping", "fatigue"):
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


def _trade_offer_totals(snap: dict) -> dict:
    trade = snap.get("trade")
    if not isinstance(trade, dict):
        return {}
    totals = {}
    for entry in trade.get("my_offer") or []:
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


def floor_band(z):
    """The floor the north-south coordinate encodes (spec rule 7a).

    The server's own Point arithmetic packs each floor into one 944-tile band
    (height = z / 944); the snapshot's z therefore names the current floor
    without any new bridge field."""
    if isinstance(z, int) and z >= 0:
        return z // FLOOR_BAND_TILES
    return None


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
            "in_combat": snap.get("in_combat"),
            "opponent": snap.get("opponent"),
            "talking_to_npc": snap.get("talking_to_npc"),
            "right_click_menu_open": snap.get("right_click_menu_open"),
            "ui_panel_open": snap.get("ui_panel_open"),
            "ui_panel": snap.get("ui_panel"),
            "selected_inventory_item": snap.get("selected_inventory_item"),
            "trade_open": snap.get("trade_open"),
            "trade_stage": snap["trade"].get("stage")
            if isinstance(snap.get("trade"), dict) else None,
            "trade_partner": snap["trade"].get("partner")
            if isinstance(snap.get("trade"), dict) else None,
            "trade_my_accepted": snap["trade"].get("my_accepted")
            if isinstance(snap.get("trade"), dict) else None,
            "trade_my_offer": _trade_offer_totals(snap),
            "duel_open": snap.get("duel_open"),
            "duel_stage": snap["duel"].get("stage")
            if isinstance(snap.get("duel"), dict) else None,
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
    with action_observation_lock():
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


def same_action_observation(left: dict, right: dict) -> bool:
    """Whether two records name the same dispatch, not merely the same type."""
    return isinstance(left, dict) and isinstance(right, dict) \
        and left.get("id") == right.get("id") \
        and left.get("sent_ts") == right.get("sent_ts")


def settle_action_observation(observation: dict, remove: bool = False) -> bool:
    """Compare-and-update one armed action without clobbering a newer dispatch."""
    with action_observation_lock():
        current = load_action_observation()
        if not same_action_observation(current, observation):
            return False
        if remove:
            try:
                action_observation_path().unlink()
            except FileNotFoundError:
                pass
        else:
            game_reflex.atomic_write(
                action_observation_path(), json.dumps(observation) + "\n")
        return True


def action_completion(observation: dict, snap: dict, context: dict = None):
    """Return grounded postcondition details, or None while still unresolved.

    `context` is the awaiting loop's memory across polls (currently whether
    any polled snapshot showed the body walking); a caller replaying a single
    captured snapshot may omit it."""
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
                "duel_open", "bank_open", "shop_open", "sleeping"):
        if isinstance(snap.get(key), bool) and snap.get(key) != before.get(key):
            ui_changes.append(f"{key}:{str(snap[key]).lower()}")
    live_duel_stage = snap["duel"].get("stage") \
        if isinstance(snap.get("duel"), dict) else None
    if live_duel_stage != before.get("duel_stage"):
        ui_changes.append(f"duel_stage:{live_duel_stage or 'closed'}")
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
    fields = dict(field.split("=", 1) for field in observation.get("fields", [])
                  if isinstance(field, str) and "=" in field)
    if observation["type"] == "click-inventory":
        try:
            selected = int(fields.get("item", ""))
        except ValueError:
            selected = -1
        selected_now = snap.get("selected_inventory_item") == selected \
            and before.get("selected_inventory_item") != selected
        menu_opened = snap.get("right_click_menu_open") is True \
            and before.get("right_click_menu_open") is not True
        if selected_now:
            ui_changes.append(f"selected_inventory_item:{selected}")
        completed = bool(selected_now or menu_opened or inventory_changes
                         or xp_changes or message or failure)
    if observation["type"] == "click-entity":
        for key in ("walking", "in_combat"):
            if isinstance(snap.get(key), bool) and snap.get(key) != before.get(key):
                ui_changes.append(f"{key}:{str(snap[key]).lower()}")
        completed = bool(inventory_changes or xp_changes or message
                         or ui_changes or moved or failure)
    if observation["type"] == "attack-npc":
        combat_started = snap.get("in_combat") is True \
            and before.get("in_combat") is not True
        opponent_acquired = snap.get("opponent") is not None \
            and snap.get("opponent") != before.get("opponent")
        combat_skill_ids = {
            skill_id for skill_id, skill in current_skills.items()
            if str(skill.get("name", "")).casefold()
            in {"attack", "defense", "strength", "hits"}
        }
        combat_xp = bool(changed_skill_ids & combat_skill_ids)
        if combat_started:
            ui_changes.append("in_combat:true")
        if opponent_acquired:
            ui_changes.append("opponent:acquired")
        completed = bool(combat_started or opponent_acquired or combat_xp or failure)
    if observation["type"] == "use-item-object":
        # Pane/menu changes were the old two-click race, not evidence that the
        # server used the selected item. A furnace's start line also precedes
        # the bar. Ground success in its input changing or XP; only explicit
        # failure feedback may terminate it without either delta.
        completed = bool(fields.get("item") in changed_item_ids
                         or xp_changes or failure)
    trade_give = None
    trade_stage = None
    if observation["type"] in ("trade-offer", "trade-remove"):
        try:
            item = int(fields.get("item", ""))
            amount = int(fields.get("amount", ""))
        except ValueError:
            item = amount = -1
        item_key = str(item)
        before_offer = before.get("trade_my_offer") or {}
        current_offer = _trade_offer_totals(snap)
        old_count = (before_offer.get(item_key) or {}).get("count", 0)
        current_count = (current_offer.get(item_key) or {}).get("count", 0)
        expected = old_count + amount \
            if observation["type"] == "trade-offer" else old_count - amount
        trade = snap.get("trade")
        same_offer = isinstance(trade, dict) \
            and trade.get("stage") == "offer" \
            and trade.get("partner") == before.get("trade_partner")
        exact_change = item >= 0 and amount > 0 and expected >= 0 \
            and same_offer and current_count == expected
        if exact_change:
            name = (current_offer.get(item_key)
                    or before_offer.get(item_key) or {}).get("name") or f"item-{item}"
            trade_give = f"id={item} {name} x{current_count}"
            ui_changes.append(f"trade-give:{item}:{old_count}->{current_count}")
        completed = bool(exact_change or failure)
    if observation["type"] == "trade-accept":
        wanted_stage = fields.get("stage")
        trade = snap.get("trade")
        same_partner = isinstance(trade, dict) \
            and trade.get("partner") == before.get("trade_partner")
        offer_accepted = wanted_stage == "offer" and same_partner \
            and (trade.get("stage") == "confirm"
                 or trade.get("my_accepted") is True)
        completed_feedback = "trade completed" in message.casefold()
        confirm_completed = wanted_stage == "confirm" \
            and not isinstance(trade, dict) and completed_feedback
        trade_failed = failure or (bool(message) and any(
            needle in message.casefold() for needle in (
                "trade declined", "trade cancelled", "trade canceled",
                "other player declined",
            )))
        if offer_accepted:
            live_stage = trade.get("stage")
            trade_stage = f"offer->{live_stage or 'accepted'}"
            ui_changes.append(f"trade-stage:{trade_stage}")
        if confirm_completed:
            trade_stage = "confirm->closed"
            ui_changes.append("trade-stage:confirm->closed")
        failure = trade_failed
        completed = bool(offer_accepted or confirm_completed or trade_failed)
    if observation["type"] == "interact-object":
        # Spec rule 7a: a scenery action's walk is only the approach, never
        # the result. The floor-band arithmetic (the server's own z / 944) is
        # the transition witness for ladders and stairs; a still body watching
        # its target vanish is a scenery reload; an unexplained twelve-tile
        # settled jump with no walking observed is a portal. A body that
        # WALKED and settled away from the target with none of that evidence
        # is the grounded failure — dispatch was never a climb.
        band_before = floor_band(before.get("z"))
        band_now = floor_band(snap.get("z"))
        band_changed = band_before is not None and band_now is not None \
            and band_now != band_before
        if band_changed:
            ui_changes.append(f"floor:{band_before}->{band_now}")
        try:
            target_x = int(fields.get("x", ""))
            target_z = int(fields.get("z", ""))
            target_obj = int(fields.get("obj", ""))
        except ValueError:
            target_x = target_z = target_obj = None
        px, pz = snap.get("x"), snap.get("z")
        bx, bz = before.get("x"), before.get("z")
        here = isinstance(px, int) and isinstance(pz, int)
        settled = snap.get("walking") is False
        saw_walking = bool(context and context.get("saw_walking"))
        displacement = max(abs(px - bx), abs(pz - bz)) \
            if here and isinstance(bx, int) and isinstance(bz, int) else None
        portal_jump = settled and not band_changed and not saw_walking \
            and displacement is not None and displacement >= PORTAL_JUMP_TILES
        if portal_jump:
            ui_changes.append(f"portal-jump:({bx},{bz})->({px},{pz})")
        vanished = False
        settled_distance = None
        if target_x is not None and here:
            target_present = any(
                isinstance(entity, dict) and entity.get("id") == target_obj
                and entity.get("x") == target_x and entity.get("z") == target_z
                for entity in snap.get("objects") or [])
            settled_distance = max(abs(px - target_x), abs(pz - target_z))
            vanished = settled and not target_present and not band_changed \
                and not portal_jump and displacement is not None \
                and displacement <= OBJECT_VANISH_NEAR_TILES
            if vanished:
                ui_changes.append(f"scenery-reloaded:obj-{target_obj}-gone")
        settled_away = settled and saw_walking and not band_changed \
            and not vanished and not failure \
            and not (inventory_changes or xp_changes or message or ui_changes) \
            and settled_distance is not None \
            and settled_distance > OBJECT_SETTLE_AWAY_TILES
        if settled_away:
            failure = True
            ui_changes.append(
                f"settled-away:({px},{pz})-target:({target_x},{target_z})"
                f"-distance:{settled_distance}")
        completed = bool(inventory_changes or xp_changes or message
                         or ui_changes or failure)
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
        "trade_give": trade_give,
        "trade_stage": trade_stage,
    }


def await_action_completion(observation: dict, timeout: float):
    deadline = time.monotonic() + timeout
    latest = None
    # The loop's memory across polls: whether the body was ever observed
    # walking. It separates a pedestrian settle-away from a portal's
    # instantaneous jump (spec rule 7a's scenery transitions).
    saved_context = observation.get("wait_context")
    context = {
        "saw_walking": bool(isinstance(saved_context, dict)
                            and saved_context.get("saw_walking")),
    }
    observation["wait_context"] = context
    with SnapshotChangeWatch() as watch:
        while True:
            latest = game_reflex.read_snapshot()
            if isinstance(latest, dict) and latest.get("walking") is True:
                context["saw_walking"] = True
            completion = action_completion(observation, latest, context)
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
        settle_action_observation(observation, remove=True)
        report("action-unarmed", reason="expired",
               next="perform-one-bridge-action-first")
        sys.exit(EXIT_NOT_READY)
    completion, latest = await_action_completion(observation, args.timeout)
    if completion is not None:
        settle_action_observation(observation, remove=True)
        report("action-done", id=observation["id"], type=observation["type"],
               **completion)
        return
    # A short wait can end midway through a legitimate approach. Preserve the
    # fact that walking was observed so a subsequent waiter does not call the
    # eventual distant pedestrian stop an instantaneous portal. The
    # compare-and-update leaves a newer action's observation untouched.
    settle_action_observation(observation)
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


def cmd_retrace(args):
    """One movement request whose postcondition is squared-distance progress
    toward one CHOSEN previously occupied tile (spec rule 7f). A receipt is
    dispatch; the settled snapshot's distance to the chosen tile is the only
    thing that can call this progress."""
    cfg = load_config()
    defaults = config_defaults(cfg)
    target_x, target_z = args.x, args.z
    snap = game_reflex.read_snapshot()
    if not isinstance(snap, dict) or snap.get("logged_in") is not True \
            or now_ms() - snap.get("ts", 0) > WAIT_SNAPSHOT_FRESH_MS \
            or not isinstance(snap.get("x"), int) \
            or not isinstance(snap.get("z"), int):
        report("retrace-not-ready", target_x=target_x, target_z=target_z,
               state=wait_state_brief(snap))
        sys.exit(EXIT_NOT_READY)
    if (state_dir() / "hold").exists():
        report("retrace-held", reason="maintenance-hold")
        sys.exit(EXIT_HELD)
    if snap.get("in_combat") is True:
        report("retrace-needs-retreat", reason="combat-owns-movement",
               next="retreat")
        sys.exit(EXIT_NOT_DONE)

    trail_points = load_movement_trail()["points"]
    if not any(point.get("x") == target_x and point.get("z") == target_z
               for point in trail_points):
        recent = ",".join(f"({p['x']},{p['z']})" for p in trail_points[-8:])
        report("retrace-not-prior-tile", target_x=target_x, target_z=target_z,
               recent_trail=recent or None,
               reason="recovery-targets-come-from-observed-evidence")
        sys.exit(EXIT_NOT_DONE)

    route = load_route()
    if route is not None:
        report("retrace-conflicts-route",
               route_status=route.get("status"),
               route_x=route.get("x"), route_z=route.get("z"),
               reason="the-explicit-route-is-the-movement-commitment",
               next="route-completes-or-route-clear-deliberately")
        sys.exit(EXIT_NOT_DONE)
    backtrack = load_backtrack()
    if backtrack is not None and backtrack.get("status") in (
            "active", "blocked", "invalid"):
        report("retrace-conflicts-backtrack",
               backtrack_status=backtrack.get("status"),
               next="backtrack-status-or-backtrack-clear")
        sys.exit(EXIT_NOT_DONE)
    if backtrack is not None and backtrack.get("status") == "diverged":
        clear_backtrack()
        flush_events([{"ts": now_ms(), "kind": "backtrack-replaced-by-retrace",
                       "target_x": target_x, "target_z": target_z,
                       "contradictions": backtrack.get("contradictions")}])

    start_x, start_z = snap["x"], snap["z"]
    d2_before = navigation_distance_sq(start_x, start_z, target_x, target_z)
    if max(abs(start_x - target_x), abs(start_z - target_z)) <= args.arrive:
        rewind_movement_trail(target_x, target_z)
        report("done", target_x=target_x, target_z=target_z,
               x=start_x, z=start_z, d2=f"{d2_before}->{d2_before}")
        return

    leg_x, leg_z = bounded_navigation_leg(start_x, start_z, target_x, target_z)
    leg_arrive = args.arrive if (leg_x, leg_z) == (target_x, target_z) else 0
    progress = {"v": 1, "pid": os.getpid(), "started": now_ms(),
                "expires": now_ms() + int((WALK_TIMEOUT_S + 5) * 1000),
                "x": start_x, "z": start_z,
                "target_x": target_x, "target_z": target_z,
                "leg_x": leg_x, "leg_z": leg_z}
    game_reflex.atomic_write(movement_progress_path(),
                             json.dumps(progress) + "\n")
    action = {"type": "walk", "x": leg_x, "z": leg_z, "arrive": leg_arrive}
    status = "no-receipt"
    final_x = final_z = None
    action_id = None
    try:
        with player_state_lock():
            if (state_dir() / "action.json").exists():
                report("retrace-not-ready", reason="slot-busy")
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
            status, final_x, final_z = verify_walk(leg_x, leg_z, leg_arrive)
    finally:
        with player_state_lock():
            est = load_player_state()
            if action_id is not None \
                    and (est.get("inflight") or {}).get("id") == action_id:
                est["inflight"] = None
                save_player_state(est)
        try:
            movement_progress_path().unlink()
        except FileNotFoundError:
            pass

    if final_x is None or final_z is None:
        record = {"ts": now_ms(), "kind": "manual-retrace", "id": action_id,
                  "target": {"x": target_x, "z": target_z},
                  "leg": {"x": leg_x, "z": leg_z},
                  "start": {"x": start_x, "z": start_z},
                  "status": status, "d2_before": d2_before}
        append_outcome(record)
        flush_events([record])
        report("retrace-not-dispatched", id=action_id, status=status,
               target_x=target_x, target_z=target_z)
        sys.exit(EXIT_NOT_DONE)

    # The settled snapshot may already be beyond the leg endpoint; measure the
    # postcondition against the CHOSEN tile, never the receipt or the leg.
    latest = game_reflex.read_snapshot() or {}
    if isinstance(latest.get("x"), int) and isinstance(latest.get("z"), int):
        final_x, final_z = latest["x"], latest["z"]
        record_movement_trail(latest, connected=True)
    d2_after = navigation_distance_sq(final_x, final_z, target_x, target_z)
    arrived = max(abs(final_x - target_x), abs(final_z - target_z)) <= args.arrive
    if arrived:
        verdict = "done"
        rewind_movement_trail(target_x, target_z)
    elif d2_after < d2_before:
        verdict = "retrace-progress"
    else:
        verdict = "retrace-regressed"
    record = {"ts": now_ms(), "kind": "manual-retrace", "id": action_id,
              "target": {"x": target_x, "z": target_z},
              "leg": {"x": leg_x, "z": leg_z},
              "start": {"x": start_x, "z": start_z},
              "settled": {"x": final_x, "z": final_z},
              "status": verdict, "walk_status": status,
              "d2_before": d2_before, "d2_after": d2_after}
    if verdict == "retrace-regressed":
        record["useful_substitute"] = False
    append_outcome(record)
    flush_events([record])
    if verdict == "retrace-regressed":
        report(verdict, id=action_id, target_x=target_x, target_z=target_z,
               d2=f"{d2_before}->{d2_after}",
               requested=f"({leg_x - start_x},{leg_z - start_z})",
               observed=f"({final_x - start_x},{final_z - start_z})",
               useful_substitute="false",
               reason="settled-no-closer-to-chosen-prior-tile",
               next="different-strategy;repeating-the-identical-request-"
                    "is-not-licensed")
        sys.exit(EXIT_NOT_DONE)
    report(verdict, id=action_id, target_x=target_x, target_z=target_z,
           x=final_x, z=final_z, d2=f"{d2_before}->{d2_after}",
           next=(None if verdict == "done"
                 else "repeat-retrace-for-the-next-leg"))


def cmd_goal(args):
    """Spec rule 7h: the current goal's machine-checkable invariants."""
    if args.action == "clear":
        if not args.reason or not args.reason.strip():
            die("goal clear records why: --reason TEXT")
        if clear_goal(args.reason.strip()):
            print("goal cleared")
        else:
            print("goal: (none)")
        return
    if args.action == "set":
        if not args.text or not args.text.strip():
            die("goal set takes the goal line as TEXT")
        text = " ".join(args.text.split())
        if len(text) > 300:
            die("the goal line stays under 300 characters")
        requirements = [parse_goal_requirement(pair)
                        for pair in args.require or []]
        if not requirements:
            die("goal set declares at least one --require KIND=VALUE "
                f"(kinds: {', '.join(GOAL_REQUIREMENT_KINDS)})")
        goal = {"v": 1, "text": text, "objective": read_objective() or None,
                "requires": requirements, "set_ts": now_ms()}
        save_goal(goal)
        flush_events([{"ts": now_ms(), "kind": "goal-set", "goal": text,
                       "requires": requirements}])
        print(f"goal-set text={text!r} requires="
              + ";".join(describe_goal_requirement(r) for r in requirements))
        return
    goal = load_goal()
    if goal is None:
        report("goal-none",
               note="declare-one-with:goal-set-TEXT---require-KIND=VALUE")
        return
    if goal.get("status") == "invalid":
        report("goal-invalid", file=str(goal_invariants_path()),
               next="goal-clear-or-goal-set")
        sys.exit(EXIT_NOT_DONE)
    if args.action == "show":
        print(f"goal: {goal['text']}")
        print(f"objective: {goal.get('objective') or '(none)'}")
        for requirement in goal["requires"]:
            print(f"  require {describe_goal_requirement(requirement)}")
        return
    # check
    objective = read_objective() or None
    if goal.get("objective") != objective:
        report("goal-stale", goal=goal["text"],
               goal_objective=goal.get("objective"),
               current_objective=objective,
               next="goal-clear-or-goal-set-under-the-current-objective")
        sys.exit(EXIT_NOT_DONE)
    if args.snapshot:
        source = sys.stdin.read() if args.snapshot == "-" \
            else Path(args.snapshot).read_text()
        try:
            snap = json.loads(source)
        except json.JSONDecodeError as error:
            die(f"snapshot is not JSON: {error}")
    else:
        snap = game_reflex.read_snapshot()
        if not isinstance(snap, dict) or snap.get("logged_in") is not True \
                or now_ms() - snap.get("ts", 0) > WAIT_SNAPSHOT_FRESH_MS:
            report("goal-not-ready", state=wait_state_brief(snap))
            sys.exit(EXIT_NOT_READY)
    result = evaluate_goal(goal, snap)
    met_text = ";".join(describe_goal_requirement(r) for r in result["met"])
    unmet_text = ";".join(describe_goal_requirement(r) for r in result["unmet"])
    if result["all_met"]:
        report("goal-met", goal=goal["text"], satisfied=met_text or None)
        return
    if result["shared_resource"]:
        # Spec rule 7h: the assessment is computed here, never composed after
        # the fact — an open universal interface at an unproven place is a
        # navigation failure even when the interface work itself succeeds.
        append_outcome({
            "ts": now_ms(), "kind": "unintended-outcome",
            "goal": goal["text"], "objective": goal.get("objective"),
            "met": result["met"], "unmet": result["unmet"],
            "useful_substitute": False,
            "assessment": "shared-resource-access-not-destination-success",
            "snap": snap_brief(snap)})
        report("goal-unmet-shared-resource", goal=goal["text"],
               unmet=unmet_text, satisfied=met_text or None,
               useful_substitute="false",
               assessment="shared-resource-access-not-destination-success",
               next="replan-toward-the-declared-goal-from-observed-state")
        sys.exit(EXIT_NOT_DONE)
    report("goal-unmet", goal=goal["text"], unmet=unmet_text,
           satisfied=met_text or None)
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
        if "entity_visible" in trig:
            if not matching_state_entities(snap, trig["entity_visible"]):
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
        if "fatigue_below" in trig:
            fatigue = snap.get("fatigue")
            if not isinstance(fatigue, (int, float)) or isinstance(fatigue, bool) \
                    or fatigue >= trig["fatigue_below"]:
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
    if action["type"] == "attack-npc":
        want = action["npc"]
        within = action.get("within")
        px, pz = snap.get("x"), snap.get("z")
        npc = nearest_npc(snap, want)
        if npc is None:
            return None, "npc-not-visible"
        if npc.get("attackable") is not True:
            return None, "npc-not-attackable"
        distance = max(abs(px - npc["x"]), abs(pz - npc["z"]))
        if within is not None and distance > within:
            return None, "npc-not-within-range"
        extra = {"target_distance": distance}
        if within is not None:
            extra["within"] = within
        return compiled_npc_action("attack-npc", npc, want, **extra), None
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
    if action["type"] == "use-item-npc":
        item_id = action["item"]
        if not any(entry.get("id") == item_id for entry in snap.get("inventory") or []):
            return None, "item-not-held"
        want = action["npc"]
        within = action.get("within")
        px, pz = snap.get("x"), snap.get("z")
        npc = nearest_npc(snap, want)
        if npc is not None:
            distance = max(abs(px - npc["x"]), abs(pz - npc["z"]))
            if within is not None and distance > within:
                return None, "npc-not-within-range"
            extra = {"item": item_id, "target_distance": distance}
            if within is not None:
                extra["within"] = within
            return compiled_npc_action("use-item-npc", npc, want, **extra), None
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
    if action["type"] == "approach-entity":
        selector = {"collection": action["collection"], "field": action["field"],
                    "value": action["value"]}
        target = nearest_state_entity(snap, selector)
        if target is None:
            return None, "semantic-entity-not-visible"
        px, pz = snap.get("x"), snap.get("z")
        distance = max(abs(px - target["x"]), abs(pz - target["z"]))
        if distance <= action["within"]:
            return None, "semantic-entity-already-near"
        return {"type": "walk", "x": target["x"], "z": target["z"],
                "arrive": action["within"]}, None
    if action["type"] == "follow-player":
        target = nearest_state_entity(
            snap, {"collection": "players", "field": "name",
                   "value": action["name"]})
        if target is None or not isinstance(target.get("sidx"), int):
            return None, "follow-player-not-visible"
        px, pz = snap.get("x"), snap.get("z")
        distance = max(abs(px - target["x"]), abs(pz - target["z"]))
        if distance <= action["within"]:
            return None, "follow-player-already-near"
        # x/z/arrive are causal metadata for verification and the durable
        # reacquisition loop. The client acts only on the current server
        # index, using RuneScape's native Follow request.
        return {"type": "follow-player", "sidx": target["sidx"],
                "name": target.get("name") or action["name"],
                "x": target["x"], "z": target["z"],
                "arrive": action["within"]}, None
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
        exact_x, exact_z = action.get("x"), action.get("z")
        for obj in snap.get("objects") or []:    # already nearest-first (rule 3 there)
            if obj.get("id") == want and isinstance(obj.get("x"), int) \
                    and isinstance(obj.get("z"), int) \
                    and (not isinstance(exact_x, int) or obj["x"] == exact_x) \
                    and (not isinstance(exact_z, int) or obj["z"] == exact_z):
                return {"type": "interact-object", "x": obj["x"], "z": obj["z"],
                        "obj": want, "cmd": action.get("cmd", 1)}, None
        return None, "object-not-loaded"
    if action["type"] == "interact-bound":
        want = action["obj"]
        exact_x, exact_z, exact_dir = (action.get("x"), action.get("z"),
                                       action.get("dir"))
        blocked = False
        for bnd in snap.get("bounds") or []:     # already nearest-first
            if bnd.get("id") == want and isinstance(bnd.get("x"), int) \
                    and isinstance(bnd.get("z"), int) \
                    and (not isinstance(exact_x, int) or bnd["x"] == exact_x) \
                    and (not isinstance(exact_z, int) or bnd["z"] == exact_z) \
                    and (not isinstance(exact_dir, int)
                         or bnd.get("dir") == exact_dir):
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
                                      "magic_level", "selected_spell",
                                      "selected_inventory_item", "quest_points")}
    brief["quests"] = [
        {key: quest.get(key) for key in ("id", "name", "stage", "status")}
        for quest in snap.get("quests") or []
        if quest.get("status") in ("completed", "started")
    ]
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
                ROUTE_RULE_NAME, BACKTRACK_RULE_NAME, FOLLOW_RULE_NAME,
                MANUAL_RETREAT_RULE_NAME):
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


def dispatch_stop_walk(defaults: dict, slot_wait_s: float = 0.0):
    """The game's own stop (spec rule 7g): one receipted walk to the body's
    freshest current tile. The server answers WALK_TO_POINT by resetting the
    native follow and replacing the walk queue with that tile, so this is how
    an ended follow releases the body. Returns (status, x, z): 'done' only
    after a LATER snapshot reports walking false; 'slot-busy', a bridge
    refusal, or 'stop-unverified' leave the caller's cancelling record for
    the next pass to retry."""
    snap = game_reflex.read_snapshot() or {}
    if snap.get("logged_in") is not True \
            or not isinstance(snap.get("x"), int) \
            or not isinstance(snap.get("z"), int):
        return "stop-unverified", snap.get("x"), snap.get("z")
    action = {"type": "walk", "x": snap["x"], "z": snap["z"], "arrive": 0}
    action_id = None
    slot_deadline = time.monotonic() + slot_wait_s
    while True:
        with player_state_lock():
            if not (state_dir() / "action.json").exists():
                est = load_player_state()
                est["action_seq"] += 1
                action_id = est["action_seq"]
                sent_at = now_ms()
                est["inflight"] = {"id": action_id, "ts": sent_at}
                save_player_state(est)
                emit_player_action("action.json", action, action_id, sent_at)
                break
        if time.monotonic() >= slot_deadline:
            return "slot-busy", snap.get("x"), snap.get("z")
        time.sleep(0.1)
    flush_events([{"ts": now_ms(), "kind": "follow-stop", "id": action_id,
                   "action": action}])
    status = "no-receipt"
    receipt_path = state_dir() / "receipt.json"
    deadline = time.monotonic() + defaults["inflight_timeout_ms"] / 1000.0
    try:
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
                    flush_events([{"ts": now_ms(), "kind": "receipt",
                                   "id": action_id, "status": status}])
                    break
                watch.wait(max(0.01, min(0.25, deadline - time.monotonic())))
    finally:
        with player_state_lock():
            est = load_player_state()
            if action_id is not None \
                    and (est.get("inflight") or {}).get("id") == action_id:
                est["inflight"] = None
                save_player_state(est)
    if status != "done":
        return status, snap.get("x"), snap.get("z")
    latest = snap
    verify_deadline = time.monotonic() + STOP_VERIFY_S
    with SnapshotChangeWatch() as watch:
        while True:
            latest = game_reflex.read_snapshot() or latest
            if latest.get("logged_in") is not True \
                    or latest.get("walking") is not True:
                return "done", latest.get("x"), latest.get("z")
            remaining = verify_deadline - time.monotonic()
            if remaining <= 0:
                return "stop-unverified", latest.get("x"), latest.get("z")
            watch.wait(max(0.01, min(0.5, remaining)))


def verify_semantic_portal_open(portal: dict, timeout_s: float = STOP_VERIFY_S):
    """Observe the exact planned obstacle cease blocking movement."""
    latest = game_reflex.read_snapshot() or {}
    deadline = time.monotonic() + timeout_s
    with SnapshotChangeWatch() as watch:
        while True:
            latest = game_reflex.read_snapshot() or latest
            if latest.get("logged_in") is not True:
                return "portal-open-unverified", latest
            if not _observed_closed_portal(latest, portal):
                return "done", latest
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return "portal-open-unverified", latest
            watch.wait(max(0.01, min(0.5, remaining)))


# --------------------------------------------------------------------------
# The resident runner's heartbeat (spec rule 15): pid, ts, latest verdict.
# A fresh heartbeat makes the runner the only evaluator; `step` defers.
# --------------------------------------------------------------------------
def write_heartbeat(verdict: str, detail: str = "", ground_items=None,
                    plan: str = "", activity: str = "", activity_xp: str = "",
                    activity_compare: str = "", friend_updates=None,
                    goal: str = "") -> None:
    game_reflex.atomic_write(runner_path(), json.dumps(
        {"pid": os.getpid(), "ts": now_ms(),
         "verdict": verdict, "detail": detail,
         "ground_items": ground_items or [],
         "plan": plan or None,
         "goal": goal or None,
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
    record_navigation_observation(snap)
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
    follow, follow_target = prepare_follow(snap, objective, activity)
    follow_abandoned_reason = None
    if follow is not None and follow.get("status") == "active":
        follow, follow_action, follow_abandoned_reason = \
            prepare_follow_navigation(follow, follow_target, snap)
        if follow_action is not None:
            source_rules.append({
                "name": FOLLOW_RULE_NAME, "enabled": True,
                "priority": FOLLOW_PRIORITY, "cooldown_ms": 0,
                "hold_ticks": 1, "once_per_objective": False,
                "note": "reacquire the chosen live player and stay nearby",
                "trigger": {}, "action": follow_action,
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

    # A direct hand's committed recovery leg (rule 7f's retrace) owns the
    # body until its own postcondition is measured; evaluating around it
    # would re-create the two-controller drag it exists to diagnose.
    movement_progress = foreign_movement_in_progress()
    if movement_progress is not None:
        report("movement-in-progress", x=movement_progress.get("x"),
               z=movement_progress.get("z"),
               target_x=movement_progress.get("target_x"),
               target_z=movement_progress.get("target_z"),
               next="wait-for-retrace-postcondition")
        return "movement-in-progress", EXIT_NOT_READY

    # Spec rule 7g: a cancelled follow's stop owns the pass until a snapshot
    # reports walking false. It runs BEFORE the walking gate below because a
    # walking body is exactly the state it exists to end, and nothing here
    # can refire the follow — a cancelling record never builds a follow
    # action, and only a fresh `follow PLAYER` writes a new one.
    if not urgent_retreat_names and follow is not None \
            and follow.get("status") == "cancelling":
        reason = follow.get("cancel_reason") or "cancelled"
        if now - snap.get("ts", 0) > defaults["stale_ms"]:
            report("stale", age_ms=now - snap.get("ts", 0))
            return "stale", EXIT_NOT_READY
        if snap.get("logged_in") is True and snap.get("in_combat") is True:
            report("follow-stopping", player=json.dumps(follow["player"]),
                   reason=reason, blocked="combat-owns-movement",
                   next="retreat-then-the-stop-retries")
            return "follow-stopping", EXIT_NOT_DONE
        if snap.get("logged_in") is not True \
                or snap.get("walking") is not True:
            if not replace_follow_if_current(follow, None):
                return "follow-replaced", EXIT_NOT_READY
            flush_events([{"ts": now_ms(), "kind": "follow-stopped",
                           "player": follow["player"], "reason": reason,
                           "walking": False,
                           "x": snap.get("x"), "z": snap.get("z")}])
            report("follow-stopped", player=json.dumps(follow["player"]),
                   reason=reason, walking="false",
                   x=snap.get("x"), z=snap.get("z"))
            return "follow-stopped", EXIT_FIRED
        status, stop_x, stop_z = dispatch_stop_walk(defaults)
        if status == "done":
            if not replace_follow_if_current(follow, None):
                return "follow-replaced", EXIT_NOT_READY
            flush_events([{"ts": now_ms(), "kind": "follow-stopped",
                           "player": follow["player"], "reason": reason,
                           "walking": False, "x": stop_x, "z": stop_z}])
            report("follow-stopped", player=json.dumps(follow["player"]),
                   reason=reason, walking="false", x=stop_x, z=stop_z)
            return "follow-stopped", EXIT_FIRED
        report("follow-stopping", player=json.dumps(follow["player"]),
               reason=reason, status=status,
               next="the-stop-retries-next-pass")
        return "follow-stopping", EXIT_NOT_DONE

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

    if not urgent_retreat_names and follow is not None:
        if follow.get("status") == "invalid":
            report("follow-invalid", file=str(follow_path()))
            return "follow-needs-path", EXIT_NO_RULE
        px, pz = snap.get("x"), snap.get("z")
        if follow.get("status") == "blocked":
            report("follow-needs-path", player=json.dumps(follow["player"]),
                   x=px, z=pz, reason=follow.get("blocked_reason", "no-progress"),
                   next="inspect-obstacle-or-clear-follow")
            return "follow-needs-path", EXIT_NO_RULE
        if follow_target is not None and isinstance(px, int) and isinstance(pz, int) \
                and max(abs(px - follow_target["x"]),
                        abs(pz - follow_target["z"])) <= follow["within"]:
            report("following-near", player=json.dumps(follow["player"]),
                   distance=max(abs(px - follow_target["x"]),
                                abs(pz - follow_target["z"])),
                   within=follow["within"], next="runner-will-reacquire-if-player-moves")
            return "following-near", EXIT_NOT_READY
        if follow_target is None and isinstance(px, int) and isinstance(pz, int) \
                and isinstance(follow.get("last_x"), int) \
                and max(abs(px - follow["last_x"]), abs(pz - follow["last_z"])) \
                    <= follow["within"]:
            report("follow-target-lost", player=json.dumps(follow["player"]),
                   last_seen=f"({follow['last_x']},{follow['last_z']})",
                   next="wait-for-visibility-or-clear-follow")
            return "follow-target-lost", EXIT_NO_RULE

    # Spec rule 7e: one durable destination, executed by this resident runner
    # as ordinary lowest-priority walk actions. Messages above and every
    # learned interaction below retain priority.
    route = None if backtrack is not None or follow is not None else load_route()
    route_blocked = False
    route_leg = None
    route_portal_action = None
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
        if route is not None and route.get("status") == "active":
            route, route_leg = prepare_navigation_route(route, snap)
            route_blocked = route.get("status") == "blocked"
            portal = route.get("next_portal")
            if not route_blocked and route_leg is None \
                    and isinstance(portal, dict) \
                    and portal.get("from") == [px, pz] \
                    and _observed_closed_portal(snap, portal):
                route_portal_action = semantic_portal_action(portal)

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
        # Following a human guide is a live navigation commitment. Ambient
        # loot and routine reflexes cannot repeatedly cut across it; chat and
        # an urgent retreat were already given their higher precedence.
        if follow is not None and rule["name"] != FOLLOW_RULE_NAME \
                and rule["name"] not in urgent_retreat_names:
            continue
        # One explicit route is the movement commitment. A stale learned
        # travel leg must not pull the body away and then hand it back to the
        # route (the observed east/west ping-pong). Nonmovement interactions
        # retain their normal priority and may still interrupt useful travel.
        if route is not None and (rule.get("action") or {}).get("type") \
                in ("walk", "approach-entity") \
                and rule["name"] not in urgent_retreat_names \
                and trigger_true(rule.get("trigger") or {}, snap, {}):
            events.append({"ts": now, "kind": "route-conflict-hold",
                           "rule": rule["name"],
                           "rule_target": ({"x": rule["action"]["x"],
                                            "z": rule["action"]["z"]}
                                           if rule["action"]["type"] == "walk"
                                           else {"semantic": rule["action"]}),
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
    if route is not None and route_portal_action is not None \
            and not route_blocked and not urgent_retreat_names:
        live_rules.append({"name": ROUTE_RULE_NAME, "enabled": True,
                           "priority": ROUTE_PRIORITY, "cooldown_ms": 0,
                           "hold_ticks": 1, "channel": "game", "trigger": {},
                           "action": route_portal_action})
    elif route is not None and route_leg is not None \
            and not route_blocked and not urgent_retreat_names:
        leg_x, leg_z = route_leg
        live_rules.append({"name": ROUTE_RULE_NAME, "enabled": True,
                           "priority": ROUTE_PRIORITY, "cooldown_ms": 0,
                           "hold_ticks": 1, "channel": "game", "trigger": {},
                           "action": {"type": "walk", "x": leg_x,
                                      "z": leg_z,
                                      "route_step": NAVIGATION_ROUTE_STEP_TILES,
                                      "max_path": NAVIGATION_LEG_MAX_PATH_TILES,
                                      "arrive": (route["arrive"]
                                                 if len(route.get("waypoints") or []) == 1
                                                 else 0)}})
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
        if follow is not None:
            report("follow-waiting", player=json.dumps(follow.get("player")),
                   last_seen=(f"({follow.get('last_x')},{follow.get('last_z')})"
                              if isinstance(follow.get("last_x"), int) else None))
            return "follow-waiting", EXIT_NOT_READY
        if route_blocked and route is not None:
            cache_planned = route.get("planner") == "client-cache"
            route_gap = ("route-needs-local-interaction" if cache_planned else
                         "route-needs-detour")
            report(route_gap, x=snap.get("x"), z=snap.get("z"),
                   target_x=route["x"], target_z=route["z"],
                   reason=route.get("blocked_reason", "no-progress"),
                   feedback=latest_system_feedback(snap),
                   portal=(json.dumps(route.get("next_portal"), separators=(",", ":"))
                           if route.get("next_portal") else None),
                   evidence=("client-cache-path" if cache_planned
                             else "grounded-collision-path"),
                   map_boundary=(None if cache_planned else "unproven"),
                   next=("use-nearby-semantic-door-gate-stair-or-ladder;"
                         "final-route-remains-binding" if cache_planned else
                         "inspect-terrain-or-use-semantic-boundary-or-waypoint"))
            return route_gap, EXIT_NO_RULE
        if backtrack is not None and backtrack.get("status") == "invalid":
            report("backtrack-invalid", file=str(backtrack_path()))
            return "backtrack-blocked", EXIT_NO_RULE
        if backtrack is not None and backtrack.get("status") == "diverged":
            target_x, target_z = backtrack["points"][backtrack["index"]]
            report("backtrack-diverged", x=snap.get("x"), z=snap.get("z"),
                   target_x=target_x, target_z=target_z,
                   contradictions=backtrack.get("contradictions"),
                   reason=backtrack.get("diverged_reason",
                                        "movement-opposed-request"),
                   next="retrace-a-chosen-prior-tile-or-set-explicit-route-"
                        "or-backtrack-clear")
            return "backtrack-diverged", EXIT_NO_RULE
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
        current_goal = load_goal()
        report("no-rule-matched", objective=objective or None,
               plan=read_plan() or None,
               goal=(current_goal.get("text")
                     if current_goal is not None
                     and current_goal.get("status") != "invalid" else None),
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
        if isinstance(action.get("arrive"), int):
            arrive = action["arrive"]
        elif rule is not None and isinstance(rule["action"].get("arrive"), int):
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
    elif status == "done" and action["type"] in (
            "attack-npc", "use-item-npc", "click-inventory", "click-entity"):
        fields = [f"{key}={action[key]}" for key in (
            "item", "kind", "sidx", "npc", "x", "z", "dir", "obj",
            "within", "button") if key in action]
        observation = make_action_observation(
            action_id, action["type"], fields, snap, event.get("ts"))
        completion_detail, latest = await_action_completion(
            observation, WAIT_DEFAULT_S)
        if completion_detail is None:
            status = f"{action['type']}-unverified"
        elif completion_detail.get("result") == "failed":
            status = f"{action['type']}-failed"
        if status != "done":
            flush_events([{"ts": now_ms(), "kind": status, "rule": rule_name,
                           "id": action_id, "item": action.get("item"),
                           "npc": action.get("npc"),
                           "completion": completion_detail,
                           "feedback": latest_system_feedback(latest or snap)}])

    commitment_portal = None
    if rule_name == ROUTE_RULE_NAME and route is not None:
        commitment_portal = route.get("next_portal")
    elif rule_name == FOLLOW_RULE_NAME and follow is not None:
        commitment_portal = follow.get("next_portal")
    if status == "done" and action["type"] in ("interact-object", "interact-bound") \
            and isinstance(commitment_portal, dict):
        status, latest = verify_semantic_portal_open(commitment_portal)
        if status != "done":
            flush_events([{"ts": now_ms(), "kind": status,
                           "rule": rule_name, "id": action_id,
                           "portal": commitment_portal}])

    if action["type"] == "walk" and final_x is not None and final_z is not None \
            and rule_name != BACKTRACK_RULE_NAME:
        # Preserve the settled end of a verified player-owned walk even while
        # this synchronous pass prevented ordinary snapshot polling.
        latest_walk = game_reflex.read_snapshot() or dict(snap, x=final_x, z=final_z)
        record_movement_trail(latest_walk, connected=status in ("done", "walk-short"))

    is_route = rule_name == ROUTE_RULE_NAME and route is not None
    route_was_blocked = False
    route_block_reason = None
    is_route_portal = is_route \
        and action["type"] in ("interact-object", "interact-bound") \
        and isinstance(commitment_portal, dict)
    if is_route_portal:
        latest = game_reflex.read_snapshot() or snap
        if status == "done":
            progressed = {key: value for key, value in route.items()
                          if key not in ("next_portal", "waypoints", "planned_from")
                          and not key.startswith("planner_")
                          and not key.startswith("blocked_")}
            progressed.update({"status": "active", "last_ts": now_ms()})
            save_route(progressed)
            status = "route-portal-opened"
            flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                           "portal": commitment_portal,
                           "target_x": route["x"], "target_z": route["z"]}])
        else:
            route_was_blocked = True
            route_block_reason = status or "portal-open-unverified"
            block_route(route, latest, route_block_reason)
            status = "route-needs-local-interaction"
            flush_events([{"ts": now_ms(), "kind": "route-portal-blocked",
                           "id": action_id, "reason": route_block_reason,
                           "portal": commitment_portal,
                           "target_x": route["x"], "target_z": route["z"]}])
    elif is_route:
        latest = game_reflex.read_snapshot() or snap
        lx, lz = latest.get("x"), latest.get("z")
        start_distance = navigation_distance_sq(
            snap["x"], snap["z"], route["x"], route["z"])
        route_best_distance = int(route.get("best_distance_sq", start_distance))
        current_distance = navigation_distance_sq(
            lx, lz, route["x"], route["z"]) \
            if isinstance(lx, int) and isinstance(lz, int) else None
        reached_destination = isinstance(lx, int) and isinstance(lz, int) \
            and route_distance(lx, lz, route) <= route["arrive"]
        made_progress = current_distance is not None and current_distance < start_distance
        made_best_progress = current_distance is not None \
            and current_distance < route_best_distance
        moved = isinstance(lx, int) and isinstance(lz, int) \
            and (lx, lz) != (snap.get("x"), snap.get("z"))
        endpoint = [lx, lz] if isinstance(lx, int) and isinstance(lz, int) else None
        visited = [point for point in route.get("visited") or []
                   if isinstance(point, list) and len(point) == 2]
        repeated_endpoint = endpoint is not None and endpoint in visited
        route_planner = route.get("planner")
        if route_planner in ("client-cache", "verified-links") \
                and status in ("done", "walk-short") and moved:
            record_navigation_link(
                snap["x"], snap["z"], lx, lz, route.get("landmark"))
        if reached_destination:
            clear_route()
            status = "route-complete"
            flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                           "x": lx, "z": lz, "target_x": route["x"],
                           "target_z": route["z"], "planner": route_planner}])
        elif route_planner in ("client-cache", "verified-links") \
                and status in ("done", "walk-short") and moved \
                and not repeated_endpoint:
            # This leg is on a grounded topology path. It may intentionally
            # move away from the destination for much longer than an arbitrary
            # straight-line detour budget would allow. Replan from the body's
            # observed settlement while retaining the original destination.
            # A settle that moved AGAINST the requested leg is different from
            # a legitimate away-leg: the planner asked for that direction, the
            # body went the other way (spec rule 7f). Count it; enough stop
            # the route rather than replanning a drag forever.
            leg_agrees = movement_agrees(snap["x"], snap["z"],
                                         action["x"], action["z"], lx, lz)
            contradictions = 0 if leg_agrees \
                else int(route.get("contradictions") or 0) + 1
            if contradictions >= MOVEMENT_CONTRADICTION_LIMIT:
                route_was_blocked = True
                route_block_reason = "movement-contradiction"
                block_route(dict(route, contradictions=contradictions),
                            latest, route_block_reason)
                append_outcome({
                    "ts": now_ms(), "kind": "movement-contradiction",
                    "id": action_id, "commitment": "route",
                    "contradictions": contradictions,
                    "requested": {"x": action["x"], "z": action["z"]},
                    "settled": {"x": lx, "z": lz},
                    "start": {"x": snap.get("x"), "z": snap.get("z")},
                    "target": {"x": route["x"], "z": route["z"]},
                    "useful_substitute": False})
                flush_events([{"ts": now_ms(), "kind": "route-leg-blocked",
                               "id": action_id, "reason": route_block_reason,
                               "x": lx, "z": lz, "target_x": route["x"],
                               "target_z": route["z"], "leg_x": action["x"],
                               "leg_z": action["z"],
                               "contradictions": contradictions,
                               "planner": route_planner}])
                status = "route-needs-detour"
            else:
                status = "route-progress"
                progressed = {key: value for key, value in route.items()
                              if key not in ("waypoints", "planned_from", "planner",
                                             "graph_link")
                              and not key.startswith("planner_")
                              and not key.startswith("blocked_")}
                visited.append(endpoint)
                nonclosing = 0 if made_best_progress \
                    else int(route.get("nonclosing_legs") or 0) + 1
                progressed.update({"status": "active", "last_x": lx, "last_z": lz,
                                   "last_distance_sq": current_distance,
                                   "best_distance_sq": min(route_best_distance,
                                                           current_distance),
                                   "nonclosing_legs": nonclosing,
                                   "contradictions": contradictions,
                                   "visited": visited[-NAVIGATION_VISITED_MAX:],
                                   "last_ts": now_ms()})
                save_route(progressed)
                flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                               "x": lx, "z": lz, "target_x": route["x"],
                               "target_z": route["z"], "leg_x": action["x"],
                               "leg_z": action["z"],
                               "nonclosing_legs": nonclosing,
                               "contradictions": contradictions or None,
                               "planner": route_planner}])
        elif route_planner == "verified-links":
            # A remembered edge is only a hint. If today's live collision
            # state rejects it, retire that edge and mechanically fall back to
            # a fresh cache plan without changing or blocking the destination.
            disable_navigation_link(str(route.get("graph_link") or ""))
            replanning = {key: value for key, value in route.items()
                          if key not in ("waypoints", "planned_from", "planner",
                                         "graph_link")
                          and not key.startswith("planner_")
                          and not key.startswith("blocked_")}
            replanning["status"] = "active"
            replanning["last_ts"] = now_ms()
            save_route(replanning)
            flush_events([{"ts": now_ms(), "kind": "route-link-retired",
                           "id": action_id, "reason": status,
                           "x": lx, "z": lz, "target_x": route["x"],
                           "target_z": route["z"],
                           "link": route.get("graph_link")}])
            status = "route-replanning"
        elif route_planner == "client-cache" \
                and status in ("done", "walk-short") and moved \
                and repeated_endpoint:
            route_was_blocked = True
            route_block_reason = "route-cycle"
            block_route(route, latest, route_block_reason)
            flush_events([{"ts": now_ms(), "kind": "route-leg-blocked",
                           "id": action_id, "reason": route_block_reason,
                           "x": lx, "z": lz, "target_x": route["x"],
                           "target_z": route["z"],
                           "planner": "client-cache"}])
            status = "route-needs-local-interaction"
        elif route_planner == "client-cache":
            route_was_blocked = True
            route_block_reason = "client-cache-leg-no-progress" \
                if status in ("done", "walk-short") else status
            block_route(route, latest, route_block_reason)
            flush_events([{"ts": now_ms(), "kind": "route-leg-blocked",
                           "id": action_id, "reason": route_block_reason,
                           "x": lx, "z": lz, "target_x": route["x"],
                           "target_z": route["z"], "leg_x": action["x"],
                           "leg_z": action["z"],
                           "planner": "client-cache"}])
            status = "route-needs-local-interaction"
        elif status in ("done", "walk-short") and action.get("route_step") \
                and moved and not repeated_endpoint:
            # A route can legitimately move closer after first wandering far
            # away, but that is not renewed progress until it beats the best
            # point already reached on this route. Otherwise a wide
            # oscillation can reset its own detour budget forever.
            nonclosing = 0 if made_best_progress \
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
                                   "last_distance_sq": current_distance,
                                   "best_distance_sq": min(route_best_distance,
                                                           current_distance),
                                   "nonclosing_legs": nonclosing,
                                   "visited": visited[-NAVIGATION_VISITED_MAX:],
                                   "last_ts": now_ms()})
                save_route(progressed)
                flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                               "x": lx, "z": lz, "target_x": route["x"],
                               "target_z": route["z"],
                               "pathfinder_prefix": True,
                               "detour": not made_progress,
                               "new_route_best": made_best_progress,
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

    is_follow = rule_name == FOLLOW_RULE_NAME and follow is not None
    if is_follow:
        # Spec rule 7g: a leg that settles after the record was cleared or
        # marked cancelling performs no follow bookkeeping — a cancelled
        # commitment cannot write itself back to active.
        current_follow = load_follow()
        if current_follow is None \
                or current_follow.get("status") in ("invalid", "cancelling") \
                or current_follow.get("set_ts") != follow.get("set_ts"):
            is_follow = False
    follow_was_blocked = False
    if is_follow:
        latest = game_reflex.read_snapshot() or snap
        lx, lz = latest.get("x"), latest.get("z")
        if action["type"] in ("interact-object", "interact-bound") \
                and isinstance(commitment_portal, dict):
            if status == "done":
                progressed = {key: value for key, value in follow.items()
                              if key not in ("next_portal", "waypoints")
                              and not key.startswith("planner_")}
                progressed.update({"status": "active", "last_move_ts": now_ms()})
                if replace_follow_if_current(follow, progressed):
                    follow = progressed
                    status = "follow-portal-opened"
                    flush_events([{"ts": now_ms(), "kind": status,
                                   "id": action_id, "player": follow["player"],
                                   "portal": commitment_portal}])
                else:
                    is_follow = False
            else:
                follow_abandoned_reason = status or "portal-open-unverified"
        elif action["type"] == "walk":
            moved = isinstance(lx, int) and isinstance(lz, int) \
                and (lx, lz) != (snap.get("x"), snap.get("z"))
            endpoint = [lx, lz] if isinstance(lx, int) and isinstance(lz, int) else None
            visited = [point for point in follow.get("visited") or []
                       if isinstance(point, list) and len(point) == 2]
            if not visited and isinstance(snap.get("x"), int) \
                    and isinstance(snap.get("z"), int):
                visited.append([snap["x"], snap["z"]])
            repeated_endpoint = endpoint is not None and endpoint in visited
            leg_agrees = moved and movement_agrees(
                snap["x"], snap["z"], action["x"], action["z"], lx, lz)
            target_x = follow.get("planner_target_x", action["x"])
            target_z = follow.get("planner_target_z", action["z"])
            start_distance = navigation_distance_sq(
                snap["x"], snap["z"], target_x, target_z)
            current_distance = navigation_distance_sq(lx, lz, target_x, target_z) \
                if endpoint is not None else None
            best_distance = int(follow.get("best_distance_sq", start_distance))
            made_best_progress = current_distance is not None \
                and current_distance < best_distance
            nonclosing = 0 if made_best_progress \
                else int(follow.get("nonclosing_legs") or 0) + 1
            if status in ("done", "walk-short") and moved and leg_agrees \
                    and not repeated_endpoint \
                    and nonclosing <= NAVIGATION_MAX_NONCLOSING_LEGS:
                status = "follow-progress"
                progressed = {key: value for key, value in follow.items()
                              if key not in ("waypoints", "next_portal")
                              and not key.startswith("planner_")
                              and not key.startswith("blocked_")}
                visited.append(endpoint)
                progressed.update({
                    "status": "active", "last_move_ts": now_ms(),
                    "last_distance_sq": current_distance,
                    "best_distance_sq": min(best_distance, current_distance),
                    "nonclosing_legs": nonclosing,
                    "visited": visited[-NAVIGATION_VISITED_MAX:]})
                if replace_follow_if_current(follow, progressed):
                    follow = progressed
                    flush_events([{"ts": now_ms(), "kind": status,
                                   "id": action_id, "player": follow["player"],
                                   "x": lx, "z": lz,
                                   "leg_x": action["x"], "leg_z": action["z"],
                                   "target_x": target_x, "target_z": target_z,
                                   "nonclosing_legs": nonclosing,
                                   "within": follow["within"]}])
                else:
                    is_follow = False
            elif repeated_endpoint:
                follow_abandoned_reason = "follow-cycle"
            elif moved and not leg_agrees:
                follow_abandoned_reason = "movement-contradiction"
            elif nonclosing > NAVIGATION_MAX_NONCLOSING_LEGS:
                follow_abandoned_reason = "detour-budget"
            else:
                follow_abandoned_reason = ("no-progress" if status in
                                           ("done", "walk-short") else status)
        else:
            follow_abandoned_reason = status or "unsupported-follow-action"
        if is_follow and follow_abandoned_reason:
            if replace_follow_if_current(follow, None):
                flush_events([{"ts": now_ms(), "kind": "follow-abandoned",
                               "id": action_id, "player": follow["player"],
                               "reason": follow_abandoned_reason,
                               "controller": "self", "x": lx, "z": lz,
                               "next": "current-plan"}])
            else:
                follow_abandoned_reason = None

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
            backtrack["contradictions"] = 0
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
            backtrack["contradictions"] = 0
            save_backtrack(backtrack)
            status = "backtrack-progress"
            flush_events([{"ts": now_ms(), "kind": status, "id": action_id,
                           "x": lx, "z": lz,
                           "remaining": len(backtrack["points"]) - backtrack["index"],
                           "target_x": target_x, "target_z": target_z,
                           "leg_x": action["x"], "leg_z": action["z"]}])
        else:
            # Spec rule 7f: a settle that MOVED against its own request is a
            # movement contradiction — something other than the request owned
            # the body. Counted consecutively; enough of them stop the blind
            # obstacle-signature retry loop entirely.
            moved_against = status in ("done", "walk-short") \
                and isinstance(lx, int) and isinstance(lz, int) \
                and (lx, lz) != (snap.get("x"), snap.get("z")) \
                and not movement_agrees(snap["x"], snap["z"],
                                        action["x"], action["z"], lx, lz)
            contradictions = int(backtrack.get("contradictions") or 0)
            if moved_against:
                contradictions += 1
            backtrack_was_blocked = True
            blocked = dict(backtrack)
            if contradictions >= MOVEMENT_CONTRADICTION_LIMIT:
                blocked.update({"status": "diverged",
                                "contradictions": contradictions,
                                "diverged_reason": "movement-opposed-request",
                                "diverged_ts": now_ms()})
                save_backtrack(blocked)
                backtrack["status"] = "diverged"
                append_outcome({
                    "ts": now_ms(), "kind": "movement-contradiction",
                    "id": action_id, "commitment": "backtrack",
                    "contradictions": contradictions,
                    "requested": {"x": action["x"], "z": action["z"]},
                    "settled": {"x": lx, "z": lz},
                    "start": {"x": snap.get("x"), "z": snap.get("z")},
                    "target": {"x": target_x, "z": target_z},
                    "useful_substitute": False})
                flush_events([{"ts": now_ms(), "kind": "backtrack-diverged",
                               "id": action_id, "x": lx, "z": lz,
                               "target_x": target_x, "target_z": target_z,
                               "contradictions": contradictions}])
            else:
                blocked.update({"status": "blocked", "blocked_reason": status,
                                "contradictions": contradictions,
                                "blocked_signature": route_obstacle_signature(latest),
                                "blocked_ts": now_ms()})
                save_backtrack(blocked)
                flush_events([{"ts": now_ms(), "kind": "backtrack-blocked",
                               "id": action_id, "reason": status, "x": lx, "z": lz,
                               "target_x": target_x, "target_z": target_z,
                               "contradictions": contradictions or None}])

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
        if backtrack_was_blocked and backtrack.get("status") == "diverged":
            report("backtrack-diverged", id=action_id, x=final_x, z=final_z,
                   target_x=action["x"], target_z=action["z"],
                   contradictions=backtrack.get("contradictions"),
                   reason="movement-opposed-request",
                   next="retrace-a-chosen-prior-tile-or-set-explicit-route-"
                        "or-backtrack-clear")
        elif backtrack_was_blocked:
            report("backtrack-blocked", id=action_id, x=final_x, z=final_z,
                   target_x=action["x"], target_z=action["z"])
        elif follow_abandoned_reason:
            report("follow-abandoned", id=action_id,
                   player=json.dumps(follow["player"]),
                   reason=follow_abandoned_reason, controller="self",
                   x=final_x, z=final_z, next="current-plan")
        elif route_was_blocked:
            cache_planned = route.get("planner") == "client-cache"
            report(("route-needs-local-interaction" if cache_planned else
                    "route-needs-detour"),
                   id=action_id, x=final_x, z=final_z,
                   leg_x=action["x"], leg_z=action["z"],
                   reason=route_block_reason,
                   portal=(json.dumps(route.get("next_portal"), separators=(",", ":"))
                           if route.get("next_portal") else None),
                   evidence=("client-cache-path" if cache_planned
                             else "grounded-collision-path"),
                   map_boundary=(None if cache_planned else "unproven"),
                   next=("use-nearby-semantic-door-gate-stair-or-ladder;"
                         "final-route-remains-binding" if cache_planned else
                         "inspect-terrain-or-use-semantic-boundary-or-waypoint"))
        elif follow_was_blocked:
            report("follow-needs-path", id=action_id,
                   player=json.dumps(follow["player"]), x=final_x, z=final_z,
                   reason=follow.get("blocked_reason"),
                   next="inspect-obstacle-or-clear-follow")
        else:
            report("fired", rule=rule_name, id=action_id, type=action["type"],
                   status=status, x=final_x, z=final_z, objective=objective or None,
                   activity=activity or None, activity_xp=xp_text or None,
                   activity_compare=xp_compare or None)
    else:
        if backtrack_was_blocked:
            report("backtrack-blocked", id=action_id, target_x=action["x"],
                   target_z=action["z"], reason=status)
        elif follow_abandoned_reason:
            report("follow-abandoned", id=action_id,
                   player=json.dumps(follow["player"]),
                   reason=follow_abandoned_reason, controller="self",
                   next="current-plan")
        elif route_was_blocked:
            cache_planned = route.get("planner") == "client-cache"
            report(("route-needs-local-interaction" if cache_planned else
                    "route-needs-detour"), id=action_id,
                   leg_x=action["x"], leg_z=action["z"], reason=route_block_reason,
                   portal=(json.dumps(route.get("next_portal"), separators=(",", ":"))
                           if route.get("next_portal") else None),
                   evidence=("client-cache-path" if cache_planned
                             else "grounded-collision-path"),
                   map_boundary=(None if cache_planned else "unproven"),
                   next=("use-nearby-semantic-door-gate-stair-or-ladder;"
                         "final-route-remains-binding" if cache_planned else
                         "inspect-terrain-or-use-semantic-boundary-or-waypoint"))
        elif follow_was_blocked:
            report("follow-needs-path", id=action_id,
                   player=json.dumps(follow["player"]),
                   reason=follow.get("blocked_reason"),
                   next="inspect-obstacle-or-clear-follow")
        else:
            report("fired", rule=rule_name, id=action_id, type=action["type"],
                   status=status, objective=objective or None,
                   activity=activity or None, activity_xp=xp_text or None,
                   activity_compare=xp_compare or None)
    if backtrack_was_blocked:
        return "backtrack-blocked", EXIT_NO_RULE
    if route_was_blocked:
        return ("route-needs-local-interaction"
                if route is not None and route.get("planner") == "client-cache"
                else "route-needs-detour"), EXIT_NO_RULE
    if follow_abandoned_reason:
        return "follow-abandoned", EXIT_NO_RULE
    if follow_was_blocked:
        return "follow-needs-path", EXIT_NO_RULE
    return "fired", (EXIT_FIRED if status in ("done", "route-progress", "route-complete",
                                               "route-replanning", "route-portal-opened",
                                               "follow-progress", "follow-portal-opened",
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


def quest_key(value: str) -> str:
    """Compare journal names with objective slugs without trusting punctuation."""
    words = re.findall(r"[a-z0-9]+", unicodedata.normalize("NFKD", value).casefold())
    wrappers = {"begin", "complete", "do", "finish", "quest", "start"}
    while words and words[0] in wrappers:
        words.pop(0)
    while words and words[-1] in wrappers:
        words.pop()
    return "".join(words)


def snapshot_quests() -> tuple[dict, list[dict]]:
    snap = game_reflex.read_snapshot() or {}
    quests = snap.get("quests")
    if not isinstance(quests, list):
        return snap, []
    return snap, [quest for quest in quests
                  if isinstance(quest, dict)
                  and isinstance(quest.get("name"), str)
                  and quest.get("name", "").strip()]


def cmd_quests(args):
    snap, quests = snapshot_quests()
    if "quests" not in snap:
        die("quest journal unavailable — the running client bridge has not published it")
    fragment = " ".join(args.query or []).strip().casefold()
    shown = [quest for quest in quests
             if not fragment or fragment in quest["name"].casefold()]
    print(f"quest-points={snap.get('quest_points', '?')} matches={len(shown)}")
    for quest in shown:
        print(f"{quest.get('status', 'unknown'):11s} stage={quest.get('stage', '?'):>3} "
              f"id={quest.get('id', '?'):>2} {quest['name']}")
    if fragment and not shown:
        die(f"no quest name contains {fragment!r}")


def cmd_objective(args):
    old_objective = read_objective()
    old_plan = read_plan()
    if args.clear:
        try:
            objective_path().unlink()
        except FileNotFoundError:
            pass
        if old_plan:
            clear_plan_for_objective_change(
                old_objective, "objective-cleared", old_plan)
        clear_goal("objective-cleared")
        print("objective cleared")
        return
    if args.name is None:
        obj = read_objective()
        print(obj if obj else "(none)")
        return
    if "\n" in args.name or not args.name.strip():
        die("the objective is one non-empty line")
    new_objective = args.name.strip()
    _snap, quests = snapshot_quests()
    wanted = quest_key(new_objective)
    for quest in quests:
        if wanted and quest_key(quest["name"]) == wanted \
                and (quest.get("status") == "completed" or quest.get("stage", 0) < 0):
            die(f"objective refused: {quest['name']} is already completed "
                f"(journal stage={quest.get('stage')}); choose unfinished work")
    game_dir().mkdir(parents=True, exist_ok=True)
    game_reflex.atomic_write(objective_path(), new_objective + "\n")
    if old_plan and old_objective != new_objective:
        clear_plan_for_objective_change(
            old_objective, f"objective-changed-to:{new_objective}", old_plan)
    if old_objective != new_objective:
        clear_goal(f"objective-changed-to:{new_objective}")
    print(f"objective: {new_objective}")


def validate_plan_line(value: str, label: str, maximum: int) -> str:
    value = value.strip()
    if not value or "\n" in value or "\r" in value:
        die(f"the {label} must be one non-empty line")
    if len(value) > maximum:
        die(f"the {label} exceeds {maximum} characters")
    return value


def record_plan_change(change: str, old_plan: str, new_plan: str,
                       reason: str) -> None:
    event = {"ts": now_ms(), "kind": f"plan-{change}",
             "objective": read_objective() or None,
             "old_plan": old_plan or None, "new_plan": new_plan or None,
             "reason": reason}
    flush_events([event])
    append_outcome(dict(event, kind="plan-change", change=change))


def clear_plan_for_objective_change(old_objective: str, reason: str,
                                    old_plan: str) -> None:
    try:
        plan_path().unlink()
    except FileNotFoundError:
        pass
    event = {"ts": now_ms(), "kind": "plan-cleared",
             "objective": old_objective or None, "old_plan": old_plan,
             "new_plan": None, "reason": reason}
    flush_events([event])
    append_outcome(dict(event, kind="plan-change", change="cleared"))


def cmd_plan(args):
    objective = read_objective()
    current = read_plan()
    if args.clear is not None:
        if args.text is not None:
            die("plan --clear REASON does not accept plan text")
        reason = validate_plan_line(
            args.clear, "plan-clear reason", PLAN_REASON_MAX_CHARS)
        if not current:
            print("plan already clear")
            return
        try:
            plan_path().unlink()
        except FileNotFoundError:
            pass
        record_plan_change("cleared", current, "", reason)
        print("plan cleared")
        return
    if args.text is None:
        print(current if current else "(none)")
        return
    if not objective:
        die("set an objective before selecting its plan")
    proposed = validate_plan_line(args.text, "plan", PLAN_MAX_CHARS)
    if args.revise is not None:
        reason = validate_plan_line(
            args.revise, "plan-revision reason", PLAN_REASON_MAX_CHARS)
        if not current:
            die("there is no current plan to revise; set the first plan without --revise")
        if proposed == current:
            print(f"plan unchanged: {current}")
            return
        game_reflex.atomic_write(plan_path(), proposed + "\n")
        record_plan_change("revised", current, proposed, reason)
        print(f"plan revised: {proposed}")
        return
    if current and current != proposed:
        die("a different plan is already binding; use plan --revise REASON TEXT")
    if current == proposed:
        print(f"plan unchanged: {current}")
        return
    game_dir().mkdir(parents=True, exist_ok=True)
    game_reflex.atomic_write(plan_path(), proposed + "\n")
    record_plan_change("selected", "", proposed, "initial-selection")
    print(f"plan: {proposed}")


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
        if args.allow_portals is not None:
            die("route --clear does not accept --allow-portals")
        clear_route()
        print("route cleared")
        return
    if args.x is None and args.z is None:
        if args.allow_portals is not None:
            die("route --allow-portals needs destination coordinates")
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
            landmark = route.get("landmark") or {}
            label = f" landmark={json.dumps(landmark.get('name'))}" \
                if landmark.get("name") else ""
            planner = f" planner={route.get('planner')}" \
                if route.get("planner") else ""
            next_waypoint = route.get("waypoints", [None])[0] \
                if route.get("waypoints") else None
            waypoint = f" next=({next_waypoint[0]},{next_waypoint[1]})" \
                if next_waypoint else ""
            portal_value = route.get("next_portal") or {}
            portal = (f" portal={portal_value.get('kind')}:{portal_value.get('id')}"
                      f"@({portal_value.get('x')},{portal_value.get('z')})"
                      if portal_value else "")
            print(f"route: status={route['status']} target=({route['x']},{route['z']}) "
                  f"arrive={route['arrive']} objective={route['objective'] or '(none)'}"
                  f"{label}{planner}{waypoint}{portal}{current}{last}{detour}"
                  f"{(' reason=' + route.get('blocked_reason', '')) if route['status'] == 'blocked' else ''}")
        return
    if args.x is None or args.z is None:
        die("route needs both X and Z")
    if not 0 <= args.arrive <= 10:
        die("route --arrive must be from 0 through 10")
    refuse_observed_blocked_destination(args.x, args.z, args.arrive)
    snap = game_reflex.read_snapshot() or {}
    route = {"v": 1, "x": args.x, "z": args.z, "arrive": args.arrive,
             "objective": read_objective(), "status": "active", "set_ts": now_ms(),
             "visited": [], "nonclosing_legs": 0}
    if args.allow_portals is not None:
        route["portal_authorized_reason"] = validate_plan_line(
            args.allow_portals, "route portal reason", PLAN_REASON_MAX_CHARS)
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
    clear_follow()
    save_route(route)
    print(f"route-set target=({args.x},{args.z}) arrive={args.arrive} "
          f"objective={route['objective'] or '(none)'}")


def cmd_landmark(args):
    """Find client-observed places by semantic identity, optionally route."""
    query = " ".join(args.query).strip()
    snap = game_reflex.read_snapshot() or {}
    record_navigation_observation(snap)
    candidates = world_landmark_candidates(query, args.kind)
    if args.id is not None:
        candidates = [item for item in candidates if item["id"] == args.id]
    if not candidates:
        die(f"no client-observed {args.kind or 'world'} landmark matches {query!r}")
    if args.route:
        routeable = [item for item in candidates
                     if item.get("match") != "directional-cue"]
        if routeable:
            candidates = routeable
        else:
            die(f"{query!r} matches only a directional sign, not the named place; "
                "use the sign as a cue and resolve an actual destination landmark")
    px, pz = snap.get("x"), snap.get("z")
    if args.nearest:
        if not isinstance(px, int) or not isinstance(pz, int):
            die("landmark --nearest needs a snapshot with the current tile")
        candidates = [min(candidates,
                          key=lambda item: (max(abs(item["x"] - px), abs(item["z"] - pz)),
                                            item["kind"], item["id"], item["x"], item["z"]))]
    for item in candidates[:40]:
        distance = ""
        if isinstance(px, int) and isinstance(pz, int):
            distance = f" distance={max(abs(item['x'] - px), abs(item['z'] - pz))}"
        command = f" command={item.get('command1')}" if item.get("command1") else ""
        seen = f" sightings={item.get('sightings', 1)} last_seen={item.get('last_seen')}"
        match = f" match={item.get('match')}" if item.get("match") else ""
        print(f"landmark kind={item['kind']} id={item['id']} name={json.dumps(item['name'])} "
              f"observed=({item['x']},{item['z']}){distance}{command}{seen} "
              f"description={json.dumps(item['description'])}{match}")
    if len(candidates) > 40:
        print(f"landmark: {len(candidates) - 40} more matches; narrow --kind or use --nearest")
    if not args.route:
        return
    if len(candidates) != 1:
        die(f"landmark --route is ambiguous ({len(candidates)} placements); "
            "narrow --kind or deliberately select --nearest")
    if not 0 <= args.arrive <= 10:
        die("landmark --arrive must be from 0 through 10")
    item = candidates[0]
    refuse_observed_blocked_destination(item["x"], item["z"], args.arrive)
    route = {"v": 1, "x": item["x"], "z": item["z"], "arrive": args.arrive,
             "objective": read_objective(), "status": "active", "set_ts": now_ms(),
             "visited": [], "nonclosing_legs": 0,
             "landmark": {"query": query, "kind": item["kind"], "id": item["id"],
                          "name": item["name"], "description": item["description"]}}
    if isinstance(px, int) and isinstance(pz, int):
        route.update({"origin_x": px, "origin_z": pz,
                      "origin_distance_sq": navigation_distance_sq(
                          px, pz, item["x"], item["z"]),
                      "best_distance_sq": navigation_distance_sq(
                          px, pz, item["x"], item["z"]),
                      "visited": [[px, pz]]})
    clear_backtrack()
    clear_follow()
    save_route(route)
    print(f"landmark-route-set kind={item['kind']} id={item['id']} "
          f"name={json.dumps(item['name'])} target=({item['x']},{item['z']}) "
          f"arrive={args.arrive} objective={route['objective'] or '(none)'}")


def cmd_follow(args):
    """Keep reacquiring one visible player and stay within a useful radius."""
    if args.clear:
        if args.player:
            die("follow --clear takes no player name")
        request = load_follow()
        snap = game_reflex.read_snapshot() or {}
        fresh = now_ms() - snap.get("ts", 0) <= WAIT_SNAPSHOT_FRESH_MS
        walking = fresh and snap.get("logged_in") is True \
            and snap.get("walking") is True
        if request is None or request.get("status") == "invalid" or not walking:
            if request is None or request.get("status") == "invalid":
                clear_follow()
            else:
                replace_follow_if_current(request, None)
            if request is not None and request.get("status") != "invalid":
                flush_events([
                    {"ts": now_ms(), "kind": "follow-cancelled",
                     "reason": "cleared", "player": request.get("player")},
                    {"ts": now_ms(), "kind": "follow-stopped",
                     "player": request.get("player"), "reason": "cleared",
                     "walking": False,
                     "x": snap.get("x"), "z": snap.get("z")}])
            print("follow cleared")
            return
        # Spec rule 7g: the body is still moving on this commitment. Mark
        # the record cancelling FIRST — a live runner mid-pass can then
        # neither refire nor resurrect it — and prove the stop: the
        # postcondition is a later snapshot with walking false.
        previous = request
        request = dict(request)
        request.update({"status": "cancelling", "cancel_reason": "cleared",
                        "cancel_ts": now_ms()})
        if not replace_follow_if_current(previous, request):
            die("follow changed while clear was taking ownership; inspect it again")
        flush_events([{"ts": now_ms(), "kind": "follow-cancelled",
                       "reason": "cleared", "player": request["player"]}])
        defaults = config_defaults(load_config())
        status, stop_x, stop_z = dispatch_stop_walk(defaults, slot_wait_s=2.0)
        if status == "done":
            if not replace_follow_if_current(request, None):
                die("follow changed while its stop was settling; the newer follow remains")
            flush_events([{"ts": now_ms(), "kind": "follow-stopped",
                           "player": request["player"], "reason": "cleared",
                           "walking": False, "x": stop_x, "z": stop_z}])
            print(f"follow-stopped walking=false x={stop_x} z={stop_z}")
            return
        print(f"follow-stopping status={status} — the record stays "
              "cancelling and the resident runner completes the stop; "
              "postcondition walking=false")
        sys.exit(EXIT_NOT_DONE)
    if not args.player:
        request = load_follow()
        if request is None:
            print("follow: (none)")
        elif request.get("status") == "invalid":
            print(f"follow: invalid ({follow_path()})")
        else:
            last = ""
            if isinstance(request.get("last_x"), int):
                last = f" last_seen=({request['last_x']},{request['last_z']})"
            reason = f" reason={request.get('blocked_reason')}" \
                if request.get("status") == "blocked" else ""
            print(f"follow: status={request['status']} player={json.dumps(request['player'])} "
                  f"within={request['within']} objective={request['objective'] or '(none)'}"
                  f"{last}{reason}")
        return
    player = args.player.strip()
    if not player or "\n" in player or "\r" in player:
        die("follow needs one non-empty player name")
    if not 1 <= args.within <= 10:
        die("follow --within must be from 1 through 10")
    snap = game_reflex.read_snapshot() or {}
    target = nearest_state_entity(
        snap, {"collection": "players", "field": "name", "value": player})
    if target is None:
        die(f"follow cannot start: no visible player named {player!r}")
    canonical = str(target.get("name") or player)
    request = {"v": 1, "player": canonical, "within": args.within,
               "objective": read_objective(),
               "plan": read_plan(), "activity": read_activity(),
               "status": "active",
               "set_ts": now_ms(), "last_seen_ts": now_ms(),
               "last_sidx": target.get("sidx"),
               "last_x": target["x"], "last_z": target["z"],
               "visited": [], "nonclosing_legs": 0}
    if isinstance(snap.get("x"), int) and isinstance(snap.get("z"), int):
        request.update({
            "visited": [[snap["x"], snap["z"]]],
            "best_distance_sq": navigation_distance_sq(
                snap["x"], snap["z"], target["x"], target["z"])})
    clear_route()
    clear_backtrack()
    save_follow(request)
    print(f"follow-set player={json.dumps(canonical)} within={args.within} "
          f"last_seen=({target['x']},{target['z']}) "
          f"objective={request['objective'] or '(none)'}")


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
    if existing is not None and existing.get("status") in ("active", "blocked",
                                                           "diverged"):
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
    segment, loop_points_removed = loop_erase_movement_segment(
        trail[segment_start:])
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
    elif not args.reason or not args.reason.strip():
        die("backtrack all replays the whole connected history; provide --reason TEXT, "
            "or use the bounded default")
    request = {"v": 1, "objective": read_objective(), "status": "active",
               "index": 0, "points": targets, "set_ts": now_ms(),
               "reason": args.reason.strip() if args.reason else None}
    clear_route()
    clear_follow()
    save_backtrack(request)
    if loop_points_removed:
        flush_events([{"ts": now_ms(), "kind": "backtrack-loop-erased",
                       "removed_points": loop_points_removed,
                       "remaining_points": len(segment)}])
    print(f"backtrack-set points={len(targets)} next=({targets[0][0]},{targets[0][1]}) "
          f"objective={request['objective'] or '(none)'}"
          f"{(' loop_erased=' + str(loop_points_removed)) if loop_points_removed else ''}")


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
            live_goal = load_goal()
            write_heartbeat(last_verdict, detail,
                            [i.get("id") for i in latest.get("ground_items") or []],
                            read_plan(), live_activity, live_xp, live_compare,
                            live_friend_updates,
                            (live_goal.get("text")
                             if live_goal is not None
                             and live_goal.get("status") != "invalid" else ""))
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

    p = sub.add_parser("quests", help="show or search the authoritative quest journal")
    p.add_argument("query", nargs="*")
    p.set_defaults(fn=cmd_quests)

    p = sub.add_parser("plan", help="show or deliberately revise the objective's method")
    p.add_argument("text", nargs="?")
    plan_change = p.add_mutually_exclusive_group()
    plan_change.add_argument("--revise", metavar="REASON")
    plan_change.add_argument("--clear", metavar="REASON")
    p.set_defaults(fn=cmd_plan)

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
    p.add_argument("--allow-portals", metavar="REASON",
                   help="allow an exact verified raw route through multiple doors")
    p.set_defaults(fn=cmd_route)

    p = sub.add_parser("landmark",
                       help="find authoritative world placements by semantic identity")
    p.add_argument("query", nargs="+")
    p.add_argument("--kind", choices=["npc", "object", "bound"])
    p.add_argument("--id", type=int,
                   help="narrow the authoritative matches to one definition id")
    p.add_argument("--nearest", action="store_true",
                   help="deliberately select the matching spawn nearest the current tile")
    p.add_argument("--route", action="store_true",
                   help="set a durable route when the result is unambiguous")
    p.add_argument("--arrive", type=int, default=2)
    p.set_defaults(fn=cmd_landmark)

    p = sub.add_parser("follow",
                       help="durably reacquire one visible player and stay nearby")
    p.add_argument("player", nargs="?")
    p.add_argument("--within", type=int, default=2)
    p.add_argument("--clear", action="store_true")
    p.set_defaults(fn=cmd_follow)

    p = sub.add_parser("backtrack",
                       help="retrace observed successful tiles to the current portal boundary")
    p.add_argument("action", nargs="?", default=str(BACKTRACK_DEFAULT_POINTS),
                   help="point count, all, history, status, or clear")
    p.add_argument("--reason",
                   help="required evidence for the exceptional whole-history replay")
    p.set_defaults(fn=cmd_backtrack)

    p = sub.add_parser("retrace",
                       help="one verified movement request toward one chosen "
                            "previously occupied tile (spec rule 7f)")
    p.add_argument("x", type=int)
    p.add_argument("z", type=int)
    p.add_argument("--arrive", type=int, default=0, choices=range(0, 11),
                   metavar="N", help="Chebyshev arrival tolerance (default 0)")
    p.set_defaults(fn=cmd_retrace)

    p = sub.add_parser("goal",
                       help="the current goal's machine-checkable invariants "
                            "(spec rule 7h)")
    p.add_argument("action", nargs="?", default="show",
                   choices=["show", "set", "check", "clear"])
    p.add_argument("text", nargs="?")
    p.add_argument("--require", action="append", metavar="KIND=VALUE")
    p.add_argument("--reason", help="required by goal clear")
    p.add_argument("--snapshot",
                   help="check against a captured snapshot JSON file, or - for stdin")
    p.set_defaults(fn=cmd_goal)

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
                           plan=hb.get("plan") or read_plan() or None,
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
                          "route-needs-local-interaction": EXIT_NO_RULE,
                          "follow-needs-path": EXIT_NO_RULE,
                          "follow-target-lost": EXIT_NO_RULE,
                          "follow-abandoned": EXIT_NO_RULE,
                          "backtrack-blocked": EXIT_NO_RULE,
                          "backtrack-diverged": EXIT_NO_RULE,
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
