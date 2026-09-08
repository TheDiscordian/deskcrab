#!/usr/bin/env python3
"""Derive timed chess completion from recorded evidence (self-play rule 20c)."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from contextlib import contextmanager
import fcntl
import itertools
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile

CONTROLS = ('15+10', '10+0', '5+0', '3+2', '2+1', '1+0')
EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
LADDER = (('low', 'low'), ('low', 'medium'), ('medium', 'medium'),
          ('medium', 'high'), ('high', 'high'), ('high', 'xhigh'),
          ('xhigh', 'xhigh'))
DEFAULT_MODELS = ('haiku', 'sonnet', 'opus', 'fable', 'sol',
                  'gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-6-astra')
REFERENCE = ('sonnet', 'low', 'low')
RETRY_STORM = 10


def model_name(value):
    value = value.removeprefix('codex:')
    return os.environ.get('CODEX_MODEL_SOL', 'gpt-5.6-sol') if value == 'sol' else value


def canonical(definition):
    model, quiet, sharp = (definition[k] for k in ('model', 'quiet', 'sharp'))
    if quiet not in EFFORTS or sharp not in EFFORTS:
        raise ValueError(f'unknown effort pair: {quiet}/{sharp}')
    return model_name(model), quiet, sharp


def forbidden(model):
    return model_name(model) in ('spark', 'gpt-5.3-codex-spark')


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, indent=2)
            handle.write('\n')
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


@contextmanager
def plan_lock(path):
    with open(str(path) + '.coordinator.lock', 'a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('another coordinator owns this plan')
        yield


def side_points(row, side):
    winner = {'1-0': 'white', '0-1': 'black'}.get(row['result'])
    return 0.5 if winner is None else float(winner == side)


class Evidence:
    def __init__(self, plan, rows, excluded=None):
        self.plan = plan
        self.configs = {name: canonical(value) for name, value in plan['configs'].items()}
        self.labels = {}
        for label, key in self.configs.items():
            self.labels.setdefault(key, label)
        self.specs = {spec['id']: spec for spec in plan['games']}
        if len(self.specs) != len(plan['games']):
            raise ValueError('duplicate game identity in plan')
        self.excluded = dict(excluded or {})
        self.rows = []
        self.recorded = set()
        self.seats = defaultdict(list)
        self.failures = []
        for row in rows:
            if 'game' not in row:
                continue
            gid = row['game']
            if gid in self.recorded:
                raise ValueError(f'duplicate ledger identity: {gid}')
            self.recorded.add(gid)
            spec = self.specs.get(gid)
            if spec is None:
                raise ValueError(f'ledger game absent from plan: {gid}')
            if row['control'] != spec['control'] or any(
                    self.configs[row[side]] != self.configs[spec[side]]
                    for side in ('white', 'black')):
                raise ValueError(f'ledger/plan mismatch: {gid}')
            if any((row['sides'][side].get('fallback_moves') or 0) > 0
                   for side in ('white', 'black')):
                self.excluded[gid] = 'manufactured fallback move'
            if row.get('state') in ('limit', 'stalled', 'capacity'):
                self.excluded[gid] = 'interrupted game; requires a valid completion'
            if gid in self.excluded:
                continue
            if row['result'] not in ('1-0', '0-1', '1/2-1/2'):
                raise ValueError(f'ledger contains unfinished result: {gid}')
            self.rows.append(row)
            for side in ('white', 'black'):
                cfg = self.configs[row[side]]
                stats = row['sides'][side]
                events = []
                if row.get('flagged') == side:
                    events.append('flag')
                if (stats.get('attempts') or 0) - (stats.get('model_moves') or 0) >= RETRY_STORM:
                    events.append('retry storm')
                seat = {'game': gid, 'side': side, 'points': side_points(row, side),
                        'events': events, 'stats': stats}
                self.seats[row['control'], cfg].append(seat)
                if events:
                    self.failures.append({'game': gid, 'control': row['control'],
                                          'configuration': cfg, 'events': events})

    def label(self, cfg):
        return self.labels.get(cfg, '-'.join(cfg))

    def disqualified(self, control, cfg):
        for failure in self.failures:
            source = failure['configuration']
            if source[0] != cfg[0] or failure['control'] not in CONTROLS:
                continue
            exact = source == cfg and failure['control'] == control
            clock = ('flag' in failure['events']
                     and CONTROLS.index(failure['control']) <= CONTROLS.index(control)
                     and all(EFFORTS.index(source[i]) <= EFFORTS.index(cfg[i]) for i in (1, 2)))
            if exact or clock:
                kind = 'recorded failure' if exact else 'inference from a clock loss'
                return {**failure, 'kind': kind}
        return None

    def pair_rows(self, control, a, b):
        return [row for row in self.rows if row['control'] == control
                and sorted((self.configs[row['white']], self.configs[row['black']])) == sorted((a, b))]

    def round(self, control, a, b, topup=False):
        rows = self.pair_rows(control, a, b)
        if a == b:
            return {'complete': len(rows) >= 2, 'score': 0.5,
                    'games': [r['game'] for r in rows],
                    'missing': [(a, b)] * max(0, 2 - len(rows)), 'topup': False}
        scores = {'white': [], 'black': []}
        for row in rows:
            side = 'white' if self.configs[row['white']] == a else 'black'
            scores[side].append(side_points(row, side))
        base = all(scores.values())
        score = statistics.mean(statistics.mean(v) for v in scores.values()) if base else None
        # Once a top-up has begun, its other colour remains owed even if
        # the first extra game breaks the tie.
        extra = topup and base and (score == 0.5 or any(len(v) > 1 for v in scores.values()))
        required = 2 if extra else 1
        missing = [(a, b)] * max(0, required - len(scores['white']))
        missing += [(b, a)] * max(0, required - len(scores['black']))
        return {'complete': not missing, 'score': score,
                'games': [r['game'] for r in rows], 'missing': missing, 'topup': extra}

    def tail(self, control, cfg):
        values = [seat['stats']['model_secs_max'] for seat in self.seats[control, cfg]
                  if seat['stats'].get('model_secs_max') is not None]
        return max(values) if values else float('inf')

    def ranking(self, control, candidates, finalist=False):
        def key(cfg):
            direct = [self.round(control, cfg, other)['score']
                      for other in candidates if other != cfg]
            direct_score = statistics.mean(direct) if direct else 0.5
            reference = self.round(control, cfg, REFERENCE)['score']
            cost = next((i for i, model in enumerate(DEFAULT_MODELS)
                         if model_name(model) == cfg[0]), len(DEFAULT_MODELS))
            return (-direct_score, -(reference or 0) if finalist else 0,
                    self.tail(control, cfg), EFFORTS.index(cfg[1]),
                    EFFORTS.index(cfg[2]), cost, cfg)
        return sorted(candidates, key=key)


def load(path):
    path = Path(path)
    plan = json.loads(path.read_text())
    ledger = path.with_suffix('.jsonl')
    rows = [json.loads(line) for line in ledger.read_text().splitlines() if line.strip()] if ledger.exists() else []
    excluded = {}
    for suffix in ('invalid', 'artifacts'):
        sidecar = path.with_name(path.stem + '.' + suffix + '.json')
        if sidecar.exists():
            excluded.update(json.loads(sidecar.read_text()))
    return plan, Evidence(plan, rows, excluded)


def analyse(plan, evidence):
    models = plan.get('selection', {}).get('models', list(DEFAULT_MODELS))
    if not models or any(forbidden(model) for model in models):
        raise ValueError('selection requires a non-empty model roster excluding Spark')
    models = list(dict.fromkeys(model_name(model) for model in models))
    controls = {}
    previous = {}
    for control in CONTROLS:
        requests = []
        families = {}
        current = {}

        def request(a, b, role, result):
            if result['missing']:
                requests.append({'control': control, 'a': a, 'b': b,
                                 'role': role, 'topup': result['topup'],
                                 'missing': result['missing']})

        for model in models:
            cells = []
            earlier_pending = False
            for quiet, sharp in LADDER:
                cfg = (model, quiet, sharp)
                cell = {'configuration': cfg, 'label': evidence.label(cfg)}
                failure = evidence.disqualified(control, cfg)
                if failure:
                    cell.update(status='eliminated', evidence=failure)
                elif earlier_pending or any(
                        previous[longer].get(cfg) != 'passed'
                        for longer in CONTROLS[:CONTROLS.index(control)]):
                    cell['status'] = 'waiting'
                    earlier_pending = True
                else:
                    gate = evidence.round(control, cfg, REFERENCE)
                    cell.update(status='passed' if gate['complete'] else 'pending', games=gate['games'])
                    request(cfg, REFERENCE, 'gate', gate)
                    earlier_pending |= not gate['complete']
                cells.append(cell)
                current[cfg] = cell['status']
            candidates = [cell['configuration'] for cell in cells if cell['status'] == 'passed']
            ladder_done = all(cell['status'] in ('passed', 'eliminated') for cell in cells)
            comparisons = []
            if ladder_done:
                for a, b in itertools.combinations(candidates, 2):
                    result = evidence.round(control, a, b, topup=True)
                    comparisons.append({'a': a, 'b': b, **result})
                    request(a, b, 'same-model', result)
            complete = ladder_done and all(r['complete'] for r in comparisons)
            ranking = evidence.ranking(control, candidates) if complete and candidates else []
            families[model] = {'cells': cells, 'complete': complete,
                               'comparisons': comparisons, 'ranking': ranking,
                               'winner': ranking[0] if ranking else None}
        previous[control] = current
        families_done = all(f['complete'] for f in families.values())
        finalists = [f['winner'] for f in families.values() if f['winner']]
        comparisons = []
        if families_done:
            for a, b in itertools.combinations(finalists, 2):
                result = evidence.round(control, a, b, topup=True)
                comparisons.append({'a': a, 'b': b, **result})
                request(a, b, 'finalist', result)
        complete = families_done and all(r['complete'] for r in comparisons)
        ranking = evidence.ranking(control, finalists, finalist=True) if complete and finalists else []
        controls[control] = {'complete': complete, 'families': families,
                             'comparisons': comparisons, 'requests': requests,
                             'ranking': ranking, 'winner': ranking[0] if ranking else None}
    active = next((c for c in CONTROLS if not controls[c]['complete']), None)
    return {'run': plan['run'], 'complete': active is None, 'active_control': active,
            'ready': controls[active]['requests'] if active else [],
            'controls': controls, 'valid_games': len(evidence.rows),
            'excluded': evidence.excluded}


def schedule(plan, evidence, summary):
    """Append only currently required missing seats; never replace recorded history."""
    added = []
    numbers = [int(spec['id'].rsplit('-', 1)[1]) for spec in plan['games']]
    number = max(numbers, default=0)
    prefix = plan['games'][0]['id'].rsplit('-', 1)[0] if plan['games'] else 'selfplay-bench-' + plan['run']
    labels = dict(evidence.labels)

    def label(cfg):
        cfg = tuple(cfg)
        if cfg not in labels:
            name = '-'.join(cfg)
            if name in plan['configs']:
                raise ValueError(f'configuration label collision: {name}')
            plan['configs'][name] = dict(zip(('model', 'quiet', 'sharp'), cfg))
            labels[cfg] = name
        return labels[cfg]

    needed = Counter()
    roles = {}
    for request in sorted(summary['ready'], key=lambda r: r['role'] != 'gate'):
        for white, black in request['missing']:
            key = request['control'], tuple(white), tuple(black)
            # One game can satisfy a gate and a same-family comparison.
            needed[key] = max(needed[key], request['missing'].count((white, black)))
            roles[key] = request['role']
    pending = defaultdict(list)
    for spec in plan['games']:
        if not spec.get('pruned') and spec['id'] not in evidence.recorded:
            key = spec['control'], canonical(plan['configs'][spec['white']]), canonical(plan['configs'][spec['black']])
            if spec['id'] not in evidence.excluded:
                pending[key].append(spec['id'])
    ready_ids = []
    for key, count in needed.items():
        control, white, black = key
        ready_ids.extend(pending[key][:count])
        for _ in range(max(0, count - len(pending[key]))):
            number += 1
            spec = {'id': f'{prefix}-{number:03d}', 'control': control,
                    'white': label(white), 'black': label(black),
                    'selection_role': roles[key]}
            plan['games'].append(spec)
            added.append(spec['id'])
            ready_ids.append(spec['id'])
    plan['status'] = 'complete' if summary['complete'] else 'incomplete'
    plan['status_reason'] = ('All required gates and direct comparisons are resolved.' if summary['complete']
                             else 'Required games are derived by tools/chess-benchmark.')
    plan['pending_tests'] = [f"{r['control']}: {r['role']} {evidence.label(tuple(r['a']))} vs {evidence.label(tuple(r['b']))}"
                             for r in summary['ready']]
    return ready_ids, added


def markdown(summary, evidence):
    lines = ['# Timed chess benchmark', '',
             '**' + ('COMPLETE' if summary['complete'] else 'INCOMPLETE') + '**', '',
             f"Valid recorded games: {summary['valid_games']}. Excluded records: {len(summary['excluded'])}.", '',
             '| Control | State | Selected model | Quiet / sharp |',
             '|---|---|---|---|']
    for control, result in summary['controls'].items():
        winner = result['winner']
        state = 'complete' if result['complete'] else 'pending'
        lines.append(f"| {control} | {state} | {winner[0] if winner else 'none established'} | {' / '.join(winner[1:]) if winner else '—'} |")
    for control, result in summary['controls'].items():
        lines += ['', f'## {control}', '']
        for model, family in result['families'].items():
            text = ', '.join('/'.join(cell['configuration'][1:]) + ': ' + cell['status']
                             for cell in family['cells'])
            lines.append(f'- **{model}**: {text}.')
            if family['winner']:
                lines.append('  Selected pair: ' + '/'.join(family['winner'][1:]) + '.')
            for cell in family['cells']:
                if cell['status'] == 'eliminated':
                    failure = cell['evidence']
                    lines.append(f"  {'/'.join(cell['configuration'][1:])}: {failure['kind']}, {failure['game']} ({failure['control']}, {', '.join(failure['events'])}).")
        if result['requests']:
            lines += ['', 'Remaining comparisons:', '']
            for request in result['requests']:
                lines.append(f"- {request['role']}: {evidence.label(tuple(request['a']))} vs {evidence.label(tuple(request['b']))}; {len(request['missing'])} game(s) missing.")
    lines += ['', '## Excluded evidence', '']
    lines += [f'- {gid}: {str(reason).replace(str(Path.home()), "~")}.'
              for gid, reason in sorted(summary['excluded'].items())]
    lines += ['', 'Results describe the recorded sample. A clock-safe winner has no valid recorded timing failure and has completed both colours and the required direct comparisons.', '']
    return '\n'.join(lines)


def worker(plan_path, gid, output, live, budget, deadline):
    plan = json.loads(Path(plan_path).read_text())
    models = plan.get('selection', {}).get('models', DEFAULT_MODELS)
    env = dict(os.environ)
    names = set(models) | {model_name(model) for model in models}
    env['DESKCRAB_CHESS_SELFPLAY_MODELS'] = ' '.join(sorted(names))
    env['DESKCRAB_CHESS_SELFPLAY_MODEL'] = 'sonnet'
    cmd = [sys.executable, '-B', str(Path(__file__).with_name('chess_selfplay.py')),
           '--bench', str(plan_path), '--bench-game', gid, '--day',
           '--budget', str(budget), '--deadline', deadline,
           '--games', str(len(plan['games']) + 100)]
    if live:
        cmd.append('--live-session')
    with open(output, 'a+') as handle:
        handle.seek(0, os.SEEK_END)
        offset = handle.tell()
        result = subprocess.run(cmd, env=env, stdout=handle, stderr=subprocess.STDOUT)
        handle.seek(offset)
        current_output = handle.read()
    status = None
    for line in current_output.splitlines():
        if line.startswith('STATUS '):
            status = json.loads(line[7:])['status']
    return result.returncode, status


def coordinate(args):
    root = Path(args.output)
    root.mkdir(parents=True, exist_ok=True)
    running = {}
    halted = None
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        while True:
            plan, evidence = load(args.plan)
            summary = analyse(plan, evidence)
            ready, added = schedule(plan, evidence, summary)
            atomic_json(args.plan, plan)
            atomic_json(root / 'progress.json', summary)
            (root / 'report.md').write_text(markdown(summary, evidence))
            if added:
                print('SCHEDULED ' + json.dumps(added), flush=True)
            if not halted:
                active_ids = set(running.values())
                for gid in ready:
                    if len(running) >= args.workers:
                        break
                    if gid in active_ids:
                        continue
                    future = pool.submit(worker, args.plan, gid, root / (gid + '.log'),
                                         args.live_session, args.budget, args.deadline)
                    running[future] = gid
                    print('STARTED ' + gid, flush=True)
            if not running:
                if summary['complete']:
                    print('COMPLETE ' + str(root / 'report.md'), flush=True)
                    return 0
                print('STOPPED ' + (halted or 'no eligible game; inspect progress.json'), flush=True)
                return 2
            completed, _ = wait(running, return_when=FIRST_COMPLETED)
            for future in completed:
                gid = running.pop(future)
                code, status = future.result()
                print(f'FINISHED {gid} exit={code} status={status}', flush=True)
                if code or status not in ('bench-done',):
                    halted = f'{gid}: {status or code}; game remains resumable'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('analyse', 'schedule', 'run'))
    parser.add_argument('plan', type=Path)
    parser.add_argument('--json', type=Path)
    parser.add_argument('--out', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--workers', type=int, default=3)
    parser.add_argument('--live-session', action='store_true')
    parser.add_argument('--budget', type=int, default=21600)
    parser.add_argument('--deadline', default='07:00')
    args = parser.parse_args(argv)
    if args.command == 'run':
        if args.output is None or not 1 <= args.workers <= 3:
            parser.error('run needs --output and between one and three workers')
        with plan_lock(args.plan):
            return coordinate(args)
    plan, evidence = load(args.plan)
    summary = analyse(plan, evidence)
    if args.command == 'schedule':
        with plan_lock(args.plan):
            plan, evidence = load(args.plan)
            summary = analyse(plan, evidence)
            ready, added = schedule(plan, evidence, summary)
            atomic_json(args.plan, plan)
        print(json.dumps({'ready': ready, 'added': added}))
    else:
        report = markdown(summary, evidence)
        if args.out:
            args.out.write_text(report)
        else:
            print(report)
    if args.json:
        atomic_json(args.json, summary)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
