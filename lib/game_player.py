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
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import game_reflex  # noqa: E402  (the shared engine; specs/game-player.md rule 2)

# The closed vocabularies (spec rules 4 and 5). They grow by spec change only.
TRIGGER_KEYS = ("objective_is", "npc_visible", "object_visible", "bound_visible",
                "message_contains", "near_tile", "inventory_has", "inventory_lacks")
ACTIONS = ("talk-npc", "walk", "interact-object", "interact-bound", "click-entity",
           "click-inventory")
SYSTEM_FEEDBACK_CHANNELS = ("game", "quest", "inventory")
WAIT_CONDITIONS = (
    "logged_in", "logged_out", "walking", "not_walking", "in_combat",
    "out_of_combat", "talking_to_npc", "not_talking_to_npc",
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
RUNNER_FRESH_MS = 30000     # a heartbeat younger than this (and a live pid) means the
                            # runner owns evaluation; wide enough to cover one walk's
                            # verification, and a crashed runner fails the pid check at once
GAP_STABLE_MS = 750          # moving across tiles is one situation, not one Sol wake per tile

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

EMPTY_TABLE = {"v": 1, "defaults": dict(DEFAULTS), "rules": [], "unfinished": []}


def state_dir() -> Path:
    return game_reflex.state_dir()


def game_dir() -> Path:
    return game_reflex.game_dir()


def rules_path() -> Path:
    return game_dir() / "learned-rules.json"


def objective_path() -> Path:
    return game_dir() / "objective"


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
            if key == "objective_is":
                if not isinstance(val, str) or not val.strip() or "\n" in val:
                    bad(f"{where}: trigger.objective_is must be a non-empty single line")
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
                         "inventory_has", "inventory_lacks"):
                if not isinstance(val, int) or val < 0:
                    bad(f"{where}: trigger.{key} must be a non-negative type/item id")
        if "inventory_has" in trig and "inventory_lacks" in trig \
                and trig["inventory_has"] == trig["inventory_lacks"]:
            bad(f"{where}: inventory_has and inventory_lacks name the same id")

        action = rule.get("action")
        if not isinstance(action, dict) or action.get("type") not in ACTIONS:
            bad(f"{where}: action.type must be one of {', '.join(ACTIONS)}")
        atype = action["type"]
        if atype == "talk-npc":
            if set(action) != {"type", "npc"} or not isinstance(action.get("npc"), int):
                bad(f"{where}: talk-npc takes exactly npc=<type id>")
        elif atype == "walk":
            if not set(action) <= {"type", "x", "z", "arrive"} \
                    or not isinstance(action.get("x"), int) \
                    or not isinstance(action.get("z"), int):
                bad(f"{where}: walk takes integer x and z (and optionally arrive)")
            if "arrive" in action and (not isinstance(action["arrive"], int)
                                       or not 0 <= action["arrive"] <= 10):
                bad(f"{where}: walk arrive must be an integer 0..10")
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
        elif atype == "click-inventory":
            if set(action) - {"type", "item", "button"} \
                    or not isinstance(action.get("item"), int) \
                    or action["item"] < 0:
                bad(f"{where}: click-inventory takes item=<item id>, "
                    "with optional button")
            if "button" in action and action["button"] not in (1, 2, 3):
                bad(f"{where}: click-inventory button must be 1, 2, or 3")


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
    est.setdefault("seen_system_message_ids", [])
    est.setdefault("pending_system_messages", [])
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


def capture_player_messages(snap: dict, est: dict, events: list) -> None:
    """Copy new incoming local/private messages into the existing engine state."""
    seen = set(est.get("seen_message_ids") or [])
    pending = est.get("pending_messages") or []
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
                "sender": sender, "text": text}
        pending.append(item)
        seen.add(message_id)
        events.append({"ts": now_ms(), "kind": "player-message-received", **item})
    est["pending_messages"] = sorted(pending, key=lambda m: m["id"])
    est["seen_message_ids"] = sorted(seen)[-500:]


def oldest_pending_message(est: dict):
    pending = est.get("pending_messages") or []
    return min(pending, key=lambda m: m["id"]) if pending else None


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
    return False


def wait_state_brief(snap: dict) -> str:
    if not isinstance(snap, dict):
        return "none"
    parts = []
    for key in ("logged_in", "walking", "in_combat", "talking_to_npc"):
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
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                report("condition-timeout", condition=condition,
                       timeout=f"{args.timeout:g}", state=wait_state_brief(latest))
                sys.exit(EXIT_NOT_DONE)
            watch.wait(remaining)


# --------------------------------------------------------------------------
# The vocabulary plugged into game_reflex.evaluate (spec rules 4, 5, 8).
# A field the snapshot does not carry makes the condition false, never an
# exception — the same fail-safe rule the reflex triggers follow.
# --------------------------------------------------------------------------
def make_trigger_fn(objective: str):
    def trigger_true(trig, snap, food):
        if "objective_is" in trig:
            if not objective or objective != trig["objective_is"]:
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
        inv_ids = {i.get("id") for i in snap.get("inventory") or []}
        if "inventory_has" in trig and trig["inventory_has"] not in inv_ids:
            return False
        if "inventory_lacks" in trig and trig["inventory_lacks"] in inv_ids:
            return False
        return True
    return trigger_true


def compile_player_action(rule, snap, food, eat_pick):
    action = rule["action"]
    if action["type"] == "talk-npc":
        want = action["npc"]
        for npc in snap.get("npcs") or []:      # already nearest-first (rule 3 there)
            if npc.get("id") == want and isinstance(npc.get("sidx"), int):
                return {"type": "talk-npc", "sidx": npc["sidx"], "npc": want}, None
        return None, "npc-not-visible"
    if action["type"] == "walk":
        return {"type": "walk", "x": action["x"], "z": action["z"]}, None
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
            for npc in snap.get("npcs") or []:
                if npc.get("id") == want and isinstance(npc.get("sidx"), int):
                    return {"type": "click-entity", "kind": "npc",
                            "sidx": npc["sidx"], "npc": want,
                            "button": button}, None
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
    return None, f"unknown-action-{action['type']}"


def emit_player_action(path_name: str, action: dict, action_id: int, ts: int) -> None:
    lines = [f"ts={ts}", f"id={action_id}", f"type={action['type']}"]
    for key in ("kind", "sidx", "npc", "x", "z", "dir", "obj", "cmd", "item", "button",
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
                                      "walking", "in_combat", "talking_to_npc")}
    brief["inventory"] = [i.get("id") for i in snap.get("inventory") or []]
    brief["messages"] = (snap.get("messages") or [])[-5:]
    brief["npcs"] = (snap.get("npcs") or [])[:12]
    brief["objects"] = (snap.get("objects") or [])[:12]
    brief["bounds"] = (snap.get("bounds") or [])[:12]
    return brief


def gap_signature(snap: dict, objective: str) -> str:
    """Stable author input: game ticks and wandering NPC tiles are not new gaps."""
    game_messages = [
        {"channel": m.get("channel"), "sender": m.get("sender"), "text": m.get("text")}
        for m in (snap.get("messages") or [])[-5:]
        if isinstance(m, dict) and m.get("channel") not in ("local", "private")
    ]
    shape = {
        "objective": objective or None,
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
    }
    return json.dumps(shape, sort_keys=True, separators=(",", ":"))


def append_outcome(record: dict) -> None:
    path = queue_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as fh:
        fh.write(json.dumps(record, separators=(",", ":")) + "\n")


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


# --------------------------------------------------------------------------
# The resident runner's heartbeat (spec rule 15): pid, ts, latest verdict.
# A fresh heartbeat makes the runner the only evaluator; `step` defers.
# --------------------------------------------------------------------------
def write_heartbeat(verdict: str, detail: str = "") -> None:
    game_reflex.atomic_write(runner_path(), json.dumps(
        {"pid": os.getpid(), "ts": now_ms(),
         "verdict": verdict, "detail": detail}) + "\n")


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


def step_once(cfg: dict, objective: str, wait_ms: int):
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

    # Spec rules 7b-7c: capture urgent messages before ordinary play.
    # The small lock prevents the resident runner from racing a Sol reply.
    message_events = []
    with player_state_lock():
        est = load_player_state()
        est["_inflight_timeout_ms"] = defaults["inflight_timeout_ms"]
        capture_player_messages(snap, est, message_events)
        capture_urgent_system_messages(snap, est, message_events)
        pending_system_message = oldest_pending_system_message(est)
        pending_message = oldest_pending_message(est)
        save_player_state(est)
        flush_events(message_events)
    if pending_system_message is not None and snap.get("logged_in") \
            and now - snap.get("ts", 0) <= defaults["stale_ms"]:
        report("system-message", id=pending_system_message["id"],
               channel=pending_system_message["channel"],
               action="move-required", text=pending_system_message["text"])
        return "system-message", EXIT_SYSTEM_MESSAGE
    if pending_message is not None and snap.get("logged_in") \
            and now - snap.get("ts", 0) <= defaults["stale_ms"]:
        report("player-message", id=pending_message["id"],
               channel=pending_message["channel"], sender=pending_message["sender"],
               text=pending_message["text"])
        return "player-message", EXIT_PLAYER_MESSAGE

    if (state_dir() / "action.json").exists():
        report("slot-busy")
        return "slot-busy", EXIT_NOT_READY

    if snap.get("logged_in") and snap.get("tick", -1) == est["last_tick"]:
        report("same-tick", tick=snap.get("tick"))
        return "same-tick", EXIT_NOT_READY

    # Rules spent for this objective (spec rule 9) step aside BEFORE the
    # engine sees the table, so the machinery stays vocabulary-blind.
    live_rules = []
    for rule in cfg["rules"]:
        if rule.get("once_per_objective") and rule["enabled"] \
                and once_key(rule["name"], objective) in est["objective_fired"]:
            continue
        # Every player rule is game-channel by construction (spec rule 5);
        # the shared engine wants the key spelled out.
        live_rules.append(dict(rule, channel="game"))
    eval_cfg = {"v": cfg.get("v", 1),
                "defaults": {k: v for k, v in defaults.items()},
                "rules": live_rules}

    # An old receipt for our own in-flight action is consumed first, exactly
    # like the reflex loop does.
    game_reflex.consume_receipt(est, now, sink=events)

    game_reflex.evaluate(
        eval_cfg, {}, snap, est, now,
        emit=emit_player_action, sink=events,
        trigger_fn=make_trigger_fn(objective),
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
        report("no-rule-matched", objective=objective or None,
               rules_enabled=sum(1 for r in cfg["rules"] if r["enabled"]),
               cooldown_holds=cooldown_holds,
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

    rule = next((r for r in cfg["rules"] if r["name"] == rule_name), None)

    # Spec rule 7a: a walk's `done` receipt is dispatch, not arrival. Verify
    # against the target's coordinates before anything treats it as complete.
    action = event["action"]
    final_x = final_z = None
    if status == "done" and action["type"] == "walk":
        arrive = WALK_ARRIVE_DEFAULT
        if rule is not None and isinstance(rule["action"].get("arrive"), int):
            arrive = rule["action"]["arrive"]
        status, final_x, final_z = verify_walk(action["x"], action["z"], arrive)
        if status != "done":
            flush_events([{"ts": now_ms(), "kind": status, "rule": rule_name,
                           "id": action_id, "intended": {"x": action["x"], "z": action["z"]},
                           "settled": {"x": final_x, "z": final_z}}])

    # The once-per-objective mark is spent only on a VERIFIED done (rule 7a).
    if rule is not None and rule.get("once_per_objective") and status == "done":
        est = load_player_state()
        est["objective_fired"][once_key(rule_name, objective)] = now
        save_player_state(est)

    # Every outcome feeds the background author (spec rule 16).
    outcome = {"ts": now_ms(), "kind": "outcome", "rule": rule_name,
               "id": action_id, "action": action, "status": status,
               "objective": objective or None, "snap": snap_brief(snap)}
    if action["type"] == "walk":
        outcome["intended"] = {"x": action["x"], "z": action["z"]}
        if final_x is not None:
            outcome["settled"] = {"x": final_x, "z": final_z}
    append_outcome(outcome)

    if action["type"] == "walk" and final_x is not None:
        report("fired", rule=rule_name, id=action_id, type=action["type"],
               status=status, x=final_x, z=final_z, objective=objective or None)
    else:
        report("fired", rule=rule_name, id=action_id, type=action["type"],
               status=status, objective=objective or None)
    return "fired", (EXIT_FIRED if status == "done" else EXIT_NOT_DONE)


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


def predict(cfg: dict, snap: dict, objective: str):
    """The rule that would win the slot for this snapshot: the highest
    priority whose trigger holds AND whose action compiles. Pure."""
    trigger_fn = make_trigger_fn(objective)
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
        got, _action = predict(cfg, case["snapshot"], case.get("objective") or "")
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


def verify_chat_delivery(action: dict, after_id: int, timeout_s: float = 3.0) -> str:
    """Confirm the server echoed outgoing chat; a bridge receipt is dispatch only."""
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
                    and message.get("text") == action["text"]:
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
    if snap is None or not snap.get("logged_in"):
        die("cannot reply while the game is logged out")
    if now_ms() - snap.get("ts", 0) > defaults["stale_ms"]:
        die("cannot reply from a stale game snapshot")
    if (state_dir() / "hold").exists():
        die("cannot reply while play is held")
    if (state_dir() / "action.json").exists():
        die("cannot reply while the shared action slot is busy")

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
        action = {"type": "chat-local", "text": text}
        if pending["channel"] == "private":
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
        save_player_state(est)
        flush_events([{"ts": now_ms(), "kind": "player-message-reply",
                       "message_id": pending["id"], "action_id": action_id,
                       "channel": pending["channel"], "sender": pending["sender"],
                       "status": status}])
    report("replied", message_id=pending["id"], action_id=action_id,
           channel=pending["channel"], sender=pending["sender"], status=status)
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
                "expect": None if args.expect == "none" else args.expect,
                "snapshot": snapshot}
        # A case must be true the moment it is added — the suite stays green
        # so the gate only trips when a MUTATION breaks something.
        cfg = load_config()
        got, _ = predict(cfg, snapshot, case["objective"])
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

            verdict, _code = step_once(cfg, read_objective(), wait_ms)

            if verdict in ("no-rule-matched", "same-tick") \
                    and (verdict == "no-rule-matched" or gap_candidate_signature is not None):
                snap = game_reflex.read_snapshot() or {}
                objective = read_objective()
                signature = gap_signature(snap, objective)
                now = now_ms()
                if signature != gap_candidate_signature:
                    gap_candidate_signature = signature
                    gap_candidate_since = now
                elif signature != last_gap_signature \
                        and now - gap_candidate_since >= GAP_STABLE_MS:
                    append_outcome({"ts": now_ms(), "kind": "gap",
                                    "objective": objective or None,
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
            write_heartbeat(last_verdict,
                            latest_system_feedback(game_reflex.read_snapshot() or {}) or "")
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

    p = sub.add_parser("test", help="replay the cases against the table "
                                    "(spec rule 17)")
    p.add_argument("action", nargs="?", default="run",
                   choices=["run", "list", "add", "remove"])
    p.add_argument("name", nargs="?")
    p.add_argument("--expect", help="the rule that must win, or 'none'")
    p.add_argument("--snapshot", help="snapshot JSON file, or - for stdin")
    p.add_argument("--objective", help="objective the case runs under")
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
                    pending = oldest_pending_message(load_player_state())
                    if pending is not None:
                        report("player-message", id=pending["id"],
                               channel=pending["channel"], sender=pending["sender"],
                               text=pending["text"])
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
                           feedback=hb.get("detail") or None)
                sys.exit({"no-rule-matched": EXIT_NO_RULE,
                          "held": EXIT_HELD,
                          "fired": EXIT_FIRED,
                          "player-message": EXIT_PLAYER_MESSAGE,
                          "system-message": EXIT_SYSTEM_MESSAGE}.get(verdict, EXIT_NOT_READY))
        cfg = load_config()
        if args.wait_ms is None:
            args.wait_ms = config_defaults(cfg)["inflight_timeout_ms"]
        objective = read_objective()
        fired_count = 0
        verdict, code = "no-rule-matched", EXIT_NO_RULE
        for _ in range(max(1, args.max)):
            verdict, code = step_once(cfg, objective, args.wait_ms)
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
