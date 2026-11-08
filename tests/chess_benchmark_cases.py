"""Selection fixtures; invoked only by test_chess_benchmark.sh's sandbox."""
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

if 'SANDBOX' not in os.environ:
    raise SystemExit('run through tests/test_chess_benchmark.sh')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import chess_benchmark as bench


class Selection(unittest.TestCase):
    def setUp(self):
        self.plan = {'run': 'fixture', 'selection': {'models': ['fable']},
                     'configs': {'f': {'model': 'fable', 'quiet': 'low', 'sharp': 'low'},
                                 'm': {'model': 'fable', 'quiet': 'low', 'sharp': 'medium'},
                                 's': {'model': 'sonnet', 'quiet': 'low', 'sharp': 'low'},
                                 'o': {'model': 'opus', 'quiet': 'low', 'sharp': 'low'}},
                     'games': []}
        self.rows = []
        self.ladder = patch.object(bench, 'LADDER', (('low', 'low'), ('low', 'medium')))
        self.ladder.start()
        self.addCleanup(self.ladder.stop)

    def game(self, white='f', black='s', result='1/2-1/2', control='15+10', flagged=None):
        gid = f'selfplay-bench-fixture-{len(self.plan["games"]) + 1:03d}'
        self.plan['games'].append(dict(id=gid, control=control, white=white, black=black))
        stats = dict(model_moves=20, attempts=20, model_secs_max=10, fallback_moves=0)
        row = dict(game=gid, control=control, white=white, black=black, result=result,
                   flagged=flagged, sides={'white': dict(stats), 'black': dict(stats)})
        self.rows.append(row)
        return row

    def pair(self, a='f', b='s', **kwargs):
        self.game(a, b, **kwargs)
        self.game(b, a, **kwargs)

    def evidence(self, exclusions=None):
        return bench.Evidence(self.plan, self.rows, exclusions)

    def summary(self):
        return bench.analyse(self.plan, self.evidence())

    def test_reference_clock_loss_eliminates_both_axes(self):
        self.plan['selection']['models'] = ['sonnet']
        failed = self.game('f', 's', '1-0', flagged='black')
        ev = self.evidence()
        self.assertEqual(ev.disqualified('15+10', bench.REFERENCE)['game'], failed['game'])
        self.assertEqual(ev.disqualified('3+2', ('sonnet', 'medium', 'high'))['kind'],
                         'inference from a clock loss')
        self.assertTrue(self.summary()['complete'])
        self.assertIsNone(self.summary()['controls']['15+10']['winner'])

    def test_nonclock_retry_failure_does_not_infer_shorter(self):
        self.game()['sides']['white']['attempts'] = 30
        ev = self.evidence()
        cfg = ev.configs['f']
        self.assertIsNotNone(ev.disqualified('15+10', cfg))
        self.assertIsNone(ev.disqualified('10+0', cfg))
        self.assertIsNone(ev.disqualified('15+10', ev.configs['m']))

    def test_exclusions_neither_poison_nor_complete_gates(self):
        first = self.game(flagged='white')
        self.game('s', 'f')['sides']['black']['fallback_moves'] = 1
        ev = self.evidence({first['game']: 'pause artifact'})
        self.assertEqual(len(ev.rows), 0)
        self.assertFalse(ev.failures)
        self.assertEqual(len(ev.round('15+10', ev.configs['f'], bench.REFERENCE)['missing']), 2)

    def test_aliases_share_colour_evidence(self):
        self.plan['configs']['alias'] = dict(self.plan['configs']['f'])
        self.game('f', 's')
        self.game('s', 'alias')
        ev = self.evidence()
        self.assertTrue(ev.round('15+10', ev.configs['f'], bench.REFERENCE)['complete'])

    def test_bad_identity_is_rejected(self):
        self.game()
        with self.assertRaisesRegex(ValueError, 'duplicate ledger'):
            bench.Evidence(self.plan, self.rows * 2)
        self.rows[0]['control'] = '1+0'
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            self.evidence()

    def test_gates_require_both_colours_and_longer_pass(self):
        self.game()
        self.game()
        self.pair(control='10+0')
        summary = self.summary()
        cells = summary['controls']['15+10']['families']['fable']['cells']
        self.assertEqual([c['status'] for c in cells], ['pending', 'waiting'])
        self.assertEqual(summary['controls']['10+0']['families']['fable']['cells'][0]['status'], 'waiting')
        self.assertEqual(summary['active_control'], '15+10')

    def test_direct_family_round_cannot_be_skipped(self):
        self.pair()
        self.pair('m', 's')
        family = self.summary()['controls']['15+10']['families']['fable']
        self.assertFalse(family['complete'])
        self.assertEqual(len(family['comparisons'][0]['missing']), 2)
        self.assertEqual(self.summary()['ready'][0]['role'], 'same-model')

    def test_drawn_direct_round_gets_only_one_topup(self):
        self.pair('f', 'm')
        ev = self.evidence()
        self.assertEqual(len(ev.round('15+10', ev.configs['f'], ev.configs['m'], True)['missing']), 2)
        self.pair('f', 'm')
        ev = self.evidence()
        self.assertTrue(ev.round('15+10', ev.configs['f'], ev.configs['m'], True)['complete'])

    def test_first_topup_win_does_not_cancel_other_colour(self):
        self.pair('f', 'm')
        self.game('f', 'm', '1-0')
        ev = self.evidence()
        result = ev.round('15+10', ev.configs['f'], ev.configs['m'], True)
        self.assertFalse(result['complete'])
        self.assertEqual(result['missing'], [(ev.configs['m'], ev.configs['f'])])

    def test_finalist_round_required_despite_reference_win(self):
        self.plan['selection']['models'].append('opus')
        with patch.object(bench, 'LADDER', (('low', 'low'),)):
            self.pair()
            self.game('o', 's', '1-0')
            self.game('s', 'o', '0-1')
            result = self.summary()['controls']['15+10']
            self.assertFalse(result['complete'])
            self.assertEqual(result['requests'][0]['role'], 'finalist')
            self.game('f', 'o', '1-0')
            self.game('o', 'f', '0-1')
            result = self.summary()['controls']['15+10']
            self.assertTrue(result['complete'])
            self.assertEqual(result['winner'][0], 'fable')

    def test_schedule_idempotent_and_invalid_game_replaced(self):
        row = self.game()
        excluded = {row['game']: 'invalid'}
        ev = self.evidence(excluded)
        ready, added = bench.schedule(self.plan, ev, bench.analyse(self.plan, ev))
        self.assertEqual(len(added), 2)
        self.assertNotIn(row['game'], ready)
        ev = self.evidence(excluded)
        again, added = bench.schedule(self.plan, ev, bench.analyse(self.plan, ev))
        self.assertEqual(ready, again)
        self.assertEqual(added, [])
        self.assertEqual(self.rows[0], row)

    def test_pruned_unplayed_slots_are_not_evidence(self):
        self.pair()
        self.rows.clear()
        for spec in self.plan['games']:
            spec['pruned'] = 'old scope'
        self.plan['status'] = 'complete'
        ev = self.evidence()
        summary = bench.analyse(self.plan, ev)
        self.assertFalse(summary['complete'])
        _, added = bench.schedule(self.plan, ev, summary)
        self.assertEqual(len(added), 2)

    def test_spark_roster_refused_without_calls(self):
        self.plan['selection']['models'].append('gpt-5.3-codex-spark')
        with self.assertRaisesRegex(ValueError, 'excluding Spark'):
            self.summary()

    def test_worker_does_not_reuse_old_completion_line(self):
        with tempfile.TemporaryDirectory(dir=os.environ['SANDBOX']) as temp:
            plan = Path(temp) / 'plan.json'
            plan.write_text(json.dumps(self.plan))
            log = Path(temp) / 'game.log'
            log.write_text('STATUS {"status":"bench-done"}\n')
            with patch.object(bench.subprocess, 'run') as run:
                run.return_value.returncode = 1
                code, status = bench.worker(plan, 'fixture', log, True, 60, '07:00')
                self.assertEqual((code, status), (1, None))
                argv = run.call_args.args[0]
                self.assertIn('--bench-game', argv)
                self.assertIn('--live-session', argv)
                self.assertTrue(argv[2].endswith('chess_selfplay.py'))

    def test_coordinator_stops_dispatch_after_account_interruption(self):
        with tempfile.TemporaryDirectory(dir=os.environ['SANDBOX']) as temp:
            path = Path(temp) / 'plan.json'
            path.write_text(json.dumps(self.plan))
            args = SimpleNamespace(plan=path, output=Path(temp) / 'output', workers=1,
                                   live_session=True, budget=60, deadline='07:00')
            with patch.object(bench, 'worker', return_value=(0, 'subscription-limit')) as worker:
                self.assertEqual(bench.coordinate(args), 2)
                self.assertEqual(worker.call_count, 1)
            saved = json.loads(path.read_text())
            self.assertEqual(saved['status'], 'incomplete')
            self.assertEqual(len(saved['games']), 2)


unittest.main()
