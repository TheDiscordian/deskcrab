"""Durable gameplay choices and item disposition checks; no model or game calls."""
import fcntl
import json
import os
import re
import time
from pathlib import Path

import game_reflex

DISPOSITIONS = {'sell', 'bank', 'use', 'keep', 'drop'}


def directory():
    return Path(os.environ.get('DESKCRAB_GAME_DIR') or
                Path.home() / '.local/share/deskcrab/game')


def read():
    path = directory() / 'decisions.json'
    if not path.exists():
        return {'v': 1, 'entries': {}, 'history': []}
    try:
        data = json.loads(path.read_text())
        if data.get('v') != 1 or not isinstance(data['entries'], dict) \
                or not isinstance(data['history'], list):
            raise ValueError('invalid decision store')
        for key, entry in data['entries'].items():
            validate(entry['decision'])
            if entry['decision']['key'] != key or entry['status'] not in ('active', 'closed'):
                raise ValueError('invalid decision entry')
        return data
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
        raise ValueError('decisions.json is invalid; inspect and repair it before disposal') from exc


def validate(doc):
    if not isinstance(doc, dict) or set(doc) != {'key', 'choice', 'reason', 'trigger', 'items', 'disposition'}:
        raise ValueError('decision needs exactly key, choice, reason, trigger, items, and disposition')
    for name in ('key', 'choice', 'reason', 'trigger', 'disposition'):
        if not isinstance(doc[name], str) or not doc[name].strip():
            raise ValueError(f'decision {name} must be nonempty text')
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,79}', doc['key']):
        raise ValueError('decision key must be a short lowercase identifier')
    if doc['disposition'] not in DISPOSITIONS:
        raise ValueError('disposition must be sell, bank, use, keep, or drop')
    if not isinstance(doc['items'], list) or any(type(i) is not int or i < 0 for i in doc['items']) \
            or len(set(doc['items'])) != len(doc['items']):
        raise ValueError('items must be unique nonnegative item ids')
    return doc


def save(doc=None, revise=None, close=None, reason=None):
    if doc is not None:
        validate(doc)
    root = directory()
    root.mkdir(parents=True, exist_ok=True)
    with (root / 'decisions.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = read()
        key = close if close is not None else doc['key']
        before = data['entries'].get(key)
        if close is not None:
            if not before or before['status'] != 'active' or not reason or not reason.strip():
                raise ValueError('close requires an active decision and --reason with its result or blocker')
            after = dict(before, status='closed')
        else:
            if before and before['status'] == 'active' and before['decision'] != doc \
                    and (not revise or not revise.strip()):
                raise ValueError('active decision differs: use --revise with the observed reason before changing it')
            for other, entry in data['entries'].items():
                if other != key and entry['status'] == 'active' \
                        and set(entry['decision']['items']) & set(doc['items']):
                    raise ValueError(f'item decision already belongs to {other}; revise that decision')
            after = {'status': 'active', 'decision': doc}
            if before and before['status'] == 'active' and before['decision'] == doc:
                return before
            reason = revise or doc['reason']
        after['updated_ms'] = int(time.time()*1000)
        data['history'].append({'ts': after['updated_ms'], 'key': key, 'before': before,
                                'after': after, 'reason': reason})
        data['entries'][key] = after
        game_reflex.atomic_write(root / 'decisions.json', json.dumps(data) + '\n')
        return after


def active():
    return [entry['decision'] for entry in read()['entries'].values() if entry['status'] == 'active']


def check(action, item, snap=None):
    wanted = {'bank-deposit': 'bank', 'shop-sell': 'sell', 'drop-inventory': 'drop'}.get(action)
    if action in ('click-inventory', 'click-bank') and snap and snap.get('bank_open'):
        wanted = 'bank'  # ambiguous selection can deposit: use explicit bank withdraw instead
    elif action in ('click-inventory', 'click-shop') and snap and snap.get('shop_open'):
        wanted = 'sell'
    if wanted is None:
        return
    for doc in active():
        if item in doc['items'] and doc['disposition'] != wanted:
            raise ValueError(f'decision {doc["key"]}: {doc["choice"]} '
                             f'(reason: {doc["reason"]}); {action} contradicts {doc["disposition"]}. '
                             'Follow the decision or revise it with observed evidence first.')


def command(args):
    try:
        if args.action == 'set':
            if not args.value:
                raise ValueError('usage: play decision set FILE [--revise REASON]')
            save(json.loads(Path(args.value).read_text()), revise=args.revise)
        elif args.action == 'close':
            if not args.value:
                raise ValueError('usage: play decision close KEY --reason REASON')
            save(close=args.value, reason=args.reason)
        elif args.action == 'check':
            if not args.value or args.item is None:
                raise ValueError('usage: play decision check ACTION --item ID')
            check(args.value, args.item, game_reflex.read_snapshot())
            print('decision-consistent')
            return
        print(json.dumps(active(), ensure_ascii=False))
    except (ValueError, OSError) as exc:
        raise SystemExit(f'game-player: {exc}') from exc
