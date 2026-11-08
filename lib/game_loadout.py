"""Activity-specific inventory preparation; no model calls or gameplay actions."""
import json
import os
import time
from pathlib import Path

import game_reflex
import game_decisions

ROLES = {'tool', 'support', 'food', 'material', 'product'}
PREPARATION_MODES = {'bank', 'banking', 'travel', 'travelling', 'traveling', 'transit',
                     'walking', 'journey', 'trading', 'selling', 'shopping', 'recovery', 'healing', 'resupply', 'retreat'}
PREPARATION_RECOVERY = (
    'Routine work and its route are held by inventory preparation, not a path failure. '
    'Use play activity --consider "prepare inventory and reach supplies"; select an existing '
    'banking, travel, or resupply mode. A preparation-sounding name is not an exemption. '
    'Prepare through semantic doors, return to the productive activity, then '
    'play loadout set FILE and verify play loadout; preserve the skill target and destination.')


def directory():
    return Path(os.environ.get('DESKCRAB_GAME_DIR') or
                Path.home() / '.local/share/deskcrab/game')


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def context():
    root = directory()
    data = {}
    for name in ('objective', 'activity', 'plan'):
        try:
            data[name] = (root / name).read_text().strip()
        except OSError:
            data[name] = ''
    session = read_json(root / 'session.json') or {}
    data['sitting'] = session.get('started') if isinstance(session, dict) else None
    return data


def enabled():
    path = directory() / 'loadout-policy.json'
    if not path.exists():
        return False
    policy = read_json(path)
    # A corrupted enabled policy does not silently remove the gate.
    return not isinstance(policy, dict) or policy.get('enabled') is not False


def validate(doc):
    if not isinstance(doc, dict) or set(doc) != {'risk', 'min_working_slots', 'items'}:
        raise ValueError('loadout needs exactly risk, min_working_slots, and items')
    if not isinstance(doc['risk'], str) or not doc['risk'].strip():
        raise ValueError('name the actual activity and route risks')
    slots = doc['min_working_slots']
    if type(slots) is not int or not 0 <= slots <= 30:
        raise ValueError('min_working_slots must be 0..30')
    if not isinstance(doc['items'], list) or not doc['items']:
        raise ValueError('items must be a nonempty list of purposeful inventory items')
    seen = set()
    for item in doc['items']:
        if not isinstance(item, dict) or set(item) != {'id', 'role', 'min', 'max', 'reason'}:
            raise ValueError('each item needs exactly id, role, min, max, and reason')
        if type(item['id']) is not int or item['id'] < 0 or item['id'] in seen:
            raise ValueError('item ids must be unique nonnegative integers')
        seen.add(item['id'])
        if not isinstance(item['role'], str) or item['role'] not in ROLES:
            raise ValueError('role must be tool, support, food, material, or product')
        if any(type(item[k]) is not int for k in ('min', 'max')) \
                or not 0 <= item['min'] <= item['max'] <= 2147483647:
            raise ValueError('item bounds must satisfy 0 <= min <= max')
        if not isinstance(item['reason'], str) or not item['reason'].strip():
            raise ValueError('every retained item needs a current purpose')
    return doc


def assessment(snap, ctx=None):
    if not enabled():
        return {'state': 'disabled'}
    ctx = context() if ctx is None else ctx
    if not ctx['objective'] or not ctx['activity'] or ctx['activity'].casefold() in PREPARATION_MODES:
        return {'state': 'preparation-mode', 'activity': ctx['activity']}
    record = read_json(directory() / 'loadout.json')
    if not isinstance(record, dict) or record.get('context') != ctx:
        return {'state': 'needs-review', 'activity': ctx['activity'],
                'reason': 'Assess inventory for this activity, method, and sitting; old reserves do not carry over.',
                'recovery': PREPARATION_RECOVERY}
    try:
        declaration = validate(record.get('declaration'))
    except (ValueError, TypeError):
        return {'state': 'needs-review', 'reason': 'Invalid inventory declaration; replace it.',
                'recovery': PREPARATION_RECOVERY}
    if not isinstance(snap, dict) or not isinstance(snap.get('inventory'), list):
        return {'state': 'needs-preparation', 'issues': ['inventory snapshot unavailable']}
    allowed = {item['id']: item for item in declaration['items']}
    quantities, occupied, names = {}, {}, {}
    for item in snap['inventory']:
        iid = item['id']
        quantities[iid] = quantities.get(iid, 0) + int(item.get('count') or 1)
        occupied[iid] = occupied.get(iid, 0) + 1
        names[iid] = item.get('name') or str(iid)
    issues = []
    try:
        decided = {iid for doc in game_decisions.active() for iid in doc['items']}
    except ValueError as exc:
        issues.append(str(exc))
        decided = set()
    for iid, item in allowed.items():
        if item['role'] == 'product' and iid not in decided:
            issues.append(f'product {iid} needs a durable disposal decision: play decision set FILE')
    for iid, amount in quantities.items():
        if iid not in allowed:
            issues.append(f'assess undeclared {names[iid]} ({iid}), quantity {amount}, {occupied[iid]} slots: '
                          'classify if useful to this work cycle, otherwise bank; expected proceeds are not junk')
    for iid, item in allowed.items():
        amount = quantities.get(iid, 0)
        if amount < item['min']:
            issues.append(f'missing {iid}: have {amount}, need at least {item["min"]} ({item["reason"]})')
        elif amount > item['max']:
            issues.append(f'excess {names.get(iid, iid)} ({iid}): have {amount}, maximum {item["max"]}')
    nonworking = sum(slots for iid, slots in occupied.items()
                     if allowed.get(iid, {}).get('role') not in {'material', 'product'})
    working = max(0, 30 - nonworking)
    if working < declaration['min_working_slots']:
        issues.append(f'working capacity {working}, require {declaration["min_working_slots"]}; '
                      'bank excess non-working items')
    return {'state': 'needs-preparation' if issues else 'ready', 'activity': ctx['activity'],
            'occupied_slots': len(snap['inventory']), 'working_capacity': working,
            'risk': declaration['risk'], 'issues': issues}


def check_pickup(action, snap):
    """Keep ordinary incidental loot inside the current activity's inventory decision."""
    if action.get('type') != 'take-ground' or not enabled():
        return
    ctx = context()
    activity = ctx['activity'].casefold()
    travel = activity in {'travel', 'travelling', 'traveling', 'transit', 'walking', 'journey', 'trading', 'selling', 'shopping'}
    if not ctx['objective'] or not activity or (activity in PREPARATION_MODES and not travel):
        return
    record = read_json(directory() / 'loadout.json')
    saved = record.get('context') if isinstance(record, dict) else None
    matching = isinstance(saved, dict) and all(saved.get(k) == ctx[k]
                   for k in ('objective', 'plan', 'sitting'))
    if travel:
        if not matching or saved.get('activity', '').casefold() in PREPARATION_MODES:
            return
    elif not matching or saved.get('activity') != ctx['activity']:
        raise ValueError('inventory-pickup-needs-review')
    try:
        declaration = validate(record.get('declaration'))
    except (ValueError, TypeError):
        raise ValueError('inventory-pickup-needs-review') from None
    iid = action.get('item')
    allowed = next((item for item in declaration['items'] if item['id'] == iid), None)
    if allowed is None:
        raise ValueError(f'inventory-pickup-undeclared-item:{iid}')
    if not isinstance(snap, dict) or not isinstance(snap.get('inventory'), list):
        raise ValueError('inventory-pickup-snapshot-unavailable')
    held = sum(int(item.get('count') or 1) for item in snap['inventory']
               if isinstance(item, dict) and item.get('id') == iid)
    if held >= allowed['max']:
        raise ValueError(f'inventory-pickup-at-maximum:{iid}')


def _command(args):
    root = directory()
    root.mkdir(parents=True, exist_ok=True)
    if args.action == 'enable':
        game_reflex.atomic_write(root / 'loadout-policy.json', '{"enabled":true}\n')
    elif args.action == 'set':
        if not args.file:
            raise ValueError('usage: play loadout set FILE (JSON; see specs/game-loadout.md)')
        declaration = validate(json.loads(Path(args.file).read_text()))
        ctx = context()
        if not ctx['activity'] or not ctx['objective']:
            raise ValueError('select the objective and activity before declaring their inventory')
        snap = game_reflex.read_snapshot()
        if not snap or not snap.get('logged_in') or time.time()*1000 - snap.get('ts', 0) > 5000:
            raise ValueError('a fresh logged-in snapshot is required for an inventory decision')
        record = {'v': 1, 'reviewed_ms': int(time.time()*1000), 'context': ctx, 'declaration': declaration}
        game_reflex.atomic_write(root / 'loadout.json', json.dumps(record) + '\n')
    print(json.dumps(assessment(game_reflex.read_snapshot()), ensure_ascii=False))


def command(args):
    try:
        _command(args)
    except (ValueError, OSError) as exc:
        raise SystemExit(f'game-player: {exc}') from exc
