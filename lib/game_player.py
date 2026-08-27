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
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import game_reflex  # noqa: E402  (the shared engine; specs/game-player.md rule 2)

# The closed vocabularies (spec rules 4 and 5). They grow by spec change only.
TRIGGER_KEYS = ("objective_is", "npc_visible", "object_visible", "bound_visible",
                "message_contains", "near_tile", "inventory_has", "inventory_lacks")
ACTIONS = ("talk-npc", "walk", "interact-object", "interact-bound")

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

EMPTY_TABLE = {"v": 1, "defaults": dict(DEFAULTS), "rules": [], "unfinished": []}


def state_dir() -> Path:
    return game_reflex.state_dir()


def game_dir() -> Path:
    return game_reflex.game_dir()


def rules_path() -> Path:
    return game_dir() / "learned-rules.json"


def objective_path() -> Path:
    return game_dir() / "objective"


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
            if set(action) != {"type", "x", "z"} \
                    or not isinstance(action.get("x"), int) \
                    or not isinstance(action.get("z"), int):
                bad(f"{where}: walk takes exactly integer x and z")
        elif atype in ("interact-object", "interact-bound"):
            if not set(action) <= {"type", "obj", "cmd"} \
                    or not isinstance(action.get("obj"), int) or action["obj"] < 0:
                bad(f"{where}: {atype} takes obj=<type id> and optionally cmd")
            if "cmd" in action and action["cmd"] not in (1, 2):
                bad(f"{where}: {atype} cmd must be 1 or 2 (the def's menu commands)")


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
            if max(abs(px - t["x"]), abs(pz - t["z"])) > t["radius"]:
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
    return None, f"unknown-action-{action['type']}"


def emit_player_action(path_name: str, action: dict, action_id: int, ts: int) -> None:
    lines = [f"ts={ts}", f"id={action_id}", f"type={action['type']}"]
    for key in ("sidx", "npc", "x", "z", "dir", "obj", "cmd"):
        if key in action:
            lines.append(f"{key}={action[key]}")
    game_reflex.atomic_write(state_dir() / path_name, "\n".join(lines) + "\n")


# --------------------------------------------------------------------------
# step (spec rule 7): one rules-first evaluation and one report line.
# --------------------------------------------------------------------------
def report(verdict, **fields):
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
               cooldown_holds=cooldown_holds)
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
    if rule is not None and rule.get("once_per_objective"):
        est = load_player_state()
        est["objective_fired"][once_key(rule_name, objective)] = now
        save_player_state(est)

    report("fired", rule=rule_name, id=action_id,
           type=event["action"]["type"], status=status,
           objective=objective or None)
    return "fired", (EXIT_FIRED if status == "done" else EXIT_NOT_DONE)


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
        save_config(cfg)
    except ValueError as e:
        die(str(e))
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
        save_config(cfg)
    except SystemExit:
        raise
    except ValueError as e:
        die(str(e))
    print(f"{args.rule}: {key} = {value!r}")


def cmd_remove(args):
    cfg = load_config()
    before = len(cfg["rules"]) + len(cfg["unfinished"])
    cfg["rules"] = [r for r in cfg["rules"] if r["name"] != args.rule]
    cfg["unfinished"] = [e for e in cfg["unfinished"] if e["name"] != args.rule]
    if len(cfg["rules"]) + len(cfg["unfinished"]) == before:
        die(f"nothing named '{args.rule}' in rules or unfinished")
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
    p.set_defaults(fn=None)  # handled below: needs config-aware default

    p = sub.add_parser("log", help="tail the player decision log")
    p.add_argument("-n", type=int, default=20)
    p.set_defaults(fn=cmd_log)

    args = parser.parse_args()
    if args.cmd == "step":
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
