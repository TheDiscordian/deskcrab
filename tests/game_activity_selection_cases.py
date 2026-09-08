"""Run through test_game_activity_selection.sh; no live game or model calls."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

if 'SANDBOX' not in os.environ:
    raise SystemExit('run tests/test_game_activity_selection.sh')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import game_player as gp
import openrsc_review as review


class Activities(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir=os.environ['SANDBOX'])
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.data, self.state = self.root / 'data', self.root / 'state'
        self.data.mkdir(); self.state.mkdir()
        env = patch.dict(os.environ, DESKCRAB_GAME_DIR=str(self.data),
                         DESKCRAB_GAME_STATE_DIR=str(self.state),
                         BETTY_OPENRSC_MEMORY=str(self.root / 'memory'))
        env.start(); self.addCleanup(env.stop)
        (self.data / 'objective').write_text('competition')
        (self.data / 'plan').write_text('Obtain bones by fighting nearby low-risk enemies.')
        (self.data / 'activity').write_text('banking')
        self.cfg = dict(gp.EMPTY_TABLE, defaults=dict(gp.DEFAULTS), rules=[
            self.rule('old-burial', 'prayer-training', 'old-target'),
            self.rule('disabled-attack', 'prayer-training', enabled=False, action='attack-npc'),
            self.rule('melee-attack', 'melee-combat', 'competition', action='attack-npc'),
            self.rule('melee-burial', 'melee-combat'),
        ] + [self.rule(f'aaa-global-{i}', None) for i in range(30)])
        (self.data / 'learned-rules.json').write_text(json.dumps(self.cfg))
        (self.state / 'state.json').write_text(json.dumps({
            'v': 1, 'ts': gp.now_ms(), 'tick': 1, 'logged_in': True,
            'inventory': [], 'skills': [], 'npcs': [], 'in_combat': False}))

    def rule(self, name, activity, objective=None, enabled=True, action='click-inventory'):
        trigger = {'inventory_has': 20, 'out_of_combat': True}
        if activity:
            trigger['activity_is'] = activity
        if objective:
            trigger['objective_is'] = objective
        act = {'type': action, 'item': 20} if action == 'click-inventory' else {'type': action, 'npc': 11}
        return dict(name=name, enabled=enabled, trigger=trigger, action=act,
                    priority=10, cooldown_ms=0, hold_ticks=1, note='Grounded test routine')

    def command(self, name=None, **kwargs):
        args = SimpleNamespace(name=name, clear=False, restart=False, history=False,
                               list=False, consider=None, new=None)
        for key, value in kwargs.items():
            setattr(args, key, value)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            gp.cmd_activity(args)
        return out.getvalue()

    def photo(self):
        return {str(f.relative_to(self.root)): f.read_bytes()
                for folder in (self.data, self.state) for f in folder.rglob('*') if f.is_file()}

    def test_unknown_and_variants_cannot_switch_or_close_measurement(self):
        before = self.photo()
        with self.assertRaisesRegex(SystemExit, 'not in the catalog'):
            self.command('prayer-goal')
        with self.assertRaisesRegex(SystemExit, 'variant of'):
            self.command('goblin-melee-combat', new='Different target')
        self.assertEqual(self.photo(), before)

    def test_creation_is_explicit_and_survives_no_xp_and_clear(self):
        self.command('crafting', new='Use material on material; no current production mode fits')
        self.assertFalse(gp.activity_stats_path().exists())
        self.command(clear=True)
        self.assertIn('crafting', gp.activity_catalog(self.cfg))
        self.command('CRAFTING')
        self.assertEqual(gp.read_activity(), 'crafting')
        events = [json.loads(line) for line in gp.queue_path().read_text().splitlines()]
        start = next(e for e in events if e.get('kind') == 'activity-start')
        self.assertIn('no current production mode fits', start['creation_reason'])

    def test_invalid_creation_is_not_a_switch(self):
        before = self.photo()
        for name, reason in [('crafting', '  '), ('melee-combat', 'already available')]:
            with self.assertRaises(SystemExit):
                self.command(name, new=reason)
        self.assertEqual(self.photo(), before)

    def test_existing_selection_survives_removal_of_its_last_rule_without_xp(self):
        self.command('melee-combat')
        self.command(clear=True)
        self.cfg['rules'] = []
        (self.data / 'learned-rules.json').write_text(json.dumps(self.cfg))
        self.command('melee-combat')
        self.assertEqual(gp.read_activity(), 'melee-combat')

    def test_listing_is_read_only_and_shows_actual_scopes(self):
        before = self.photo()
        text = self.command(list=True)
        self.assertIn('prayer-training: 0 applicable activity rules; actions=none; excluded=2', text)
        self.assertIn('melee-combat: 2 applicable activity rules', text)
        self.assertEqual(self.photo(), before)

    def test_consider_recalls_specific_work_and_corrections_before_mutation(self):
        memory = self.root / 'memory'
        memory.write_text('#!/usr/bin/env python3\nimport json, pathlib, sys\n'
                          'pathlib.Path(__file__).with_suffix(".args").write_text(json.dumps(sys.argv))\n'
                          'print("Remembered correction: equip the weapon for combat; safe crafting needs no combat reserve.")\n')
        memory.chmod(0o700)
        before = self.photo()
        text = self.command('melee-combat', consider='fight for bones, then bury them')
        argv = json.loads(memory.with_suffix('.args').read_text())
        query = argv[argv.index('--query') + 1]
        self.assertIn('fight for bones, then bury them', query)
        self.assertIn('Obtain bones by fighting', query)
        self.assertIn('prior user corrections', query)
        self.assertIn('Relevant memories BEFORE deciding', text)
        self.assertIn('Remembered correction: equip', text)
        self.assertEqual(self.photo(), before)

    def test_preview_distinguishes_globals_and_excluded_work(self):
        text = self.command('prayer-training', consider='bury a stored supply of bones')
        self.assertIn('activity-specific reflexes (0)', text)
        self.assertIn('old-burial: requires objective old-target', text)
        self.assertIn('disabled-attack: disabled', text)
        self.assertIn('global support reflexes: 30', text)
        self.assertIn('Memory recall unavailable', text)
        self.assertEqual(gp.read_activity(), 'banking')
        self.assertEqual(gp.load_config()['rules'], self.cfg['rules'])

    def test_applicable_work_is_not_hidden_behind_globals_and_author_gets_scopes(self):
        text = self.command('melee-combat')
        self.assertIn('melee-attack: attack-npc (objective=competition)', text)
        self.assertIn('melee-burial: click-inventory (objective=any)', text)
        event = [json.loads(line) for line in gp.queue_path().read_text().splitlines()
                 if json.loads(line).get('kind') == 'activity-start'][-1]
        self.assertEqual(len(event['activity_rules']), 2)
        self.assertEqual(len(event['global_rules']), 30)
        self.assertEqual(event['excluded_activity_rules'], [])

    def test_reuse_templates_disclose_disabled_state_and_original_objective(self):
        candidates = gp.reusable_rule_candidates(self.cfg, 'prayer', 'competition', {})
        old = next(c for c in candidates if c['name'] == 'old-burial')
        disabled = next(c for c in candidates if c['name'] == 'disabled-attack')
        self.assertEqual(old['objective_scope'], 'old-target')
        self.assertFalse(disabled['enabled'])

    @unittest.skipUnless(hasattr(gp, "progress_gate_or_die"), "baseline has no progress gate")
    def test_inspection_remains_available_when_progress_is_stale(self):
        with patch.object(gp, 'progress_gate_or_die', side_effect=SystemExit('stale progress')):
            self.command(consider='choose the next operation')
            with self.assertRaisesRegex(SystemExit, 'stale progress'):
                self.command('melee-combat')
        self.assertEqual(gp.read_activity(), 'banking')

    def test_malformed_registry_does_not_silently_permit_creation(self):
        (self.data / 'activity-catalog.json').write_text('not json')
        before = self.photo()
        with self.assertRaisesRegex(SystemExit, 'cannot be read'):
            self.command('crafting', new='A new operation')
        self.assertEqual(self.photo(), before)

    def test_cli_inspection_does_not_need_an_activity_name(self):
        result = subprocess.run([sys.executable, str(Path(gp.__file__)), 'activity',
                                 '--consider', 'choose how to obtain bones'],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Existing activities', result.stdout)
        self.assertEqual(gp.read_activity(), 'banking')

    def test_reviewer_audits_memory_application_and_actual_work(self):
        paths = SimpleNamespace(headless=self.root, player=self.root, game=self.data, state=self.state)
        text = review.instructions(paths, 'test persona')
        self.assertIn('failed retrieval at the decision', text)
        self.assertIn('Inspect the actual recalled', text)
        self.assertIn('activity-specific applicable rules separately from global', text)


unittest.main()
