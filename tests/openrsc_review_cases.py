"""Run only through the shared sandbox in test_openrsc_review.sh."""
import fcntl
from datetime import datetime
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

if 'SANDBOX' not in os.environ:
    raise SystemExit('run tests/test_openrsc_review.sh')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import openrsc_review as review


class Review(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['SANDBOX'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ('game', 'headless', 'player', 'state', 'account'):
            (self.root / directory).mkdir()
        self.persona = self.root / 'persona.md'
        self.persona.write_text('You are the fixture player. Speak in first person.')
        self.cli = self.root / 'codex'
        self.cli.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
root = pathlib.Path(os.environ['REVIEW_FIXTURE'])
(root/'called.json').write_text(json.dumps({'args': args, 'input': sys.stdin.read(),
    'account': os.environ.get('CODEX_HOME'), 'api_key': os.environ.get('OPENAI_API_KEY'),
    'codex_key': os.environ.get('CODEX_API_KEY')}))
mode = os.environ.get('REVIEW_MODE', '')
if mode == 'wait':
    (root/'child.pid').write_text(str(os.getpid()))
    time.sleep(30)
result = {k: 'Verified fixture ' + k for k in
    ('objective','training','reflexes','changes','verification','next_review')}
if mode == 'partial': del result['reflexes']
pathlib.Path(args[args.index('-o')+1]).write_text(json.dumps(result))
print(json.dumps({'type': 'turn.failed' if mode == 'error' else 'turn.completed',
                  'usage': {'input_tokens': 10, 'output_tokens': 5}}), flush=True)
sys.exit(1 if mode == 'nonzero' else 0)
''')
        self.cli.chmod(0o755)
        author = self.root / 'headless/betty-openrsc'
        author.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$REVIEW_FIXTURE/author-calls"\n')
        author.chmod(0o755)
        self.env = patch.dict(os.environ, {
            'BETTY_OPENRSC_HOME': str(self.root / 'player'),
            'BETTY_OPENRSC_HEADLESS': str(self.root / 'headless'),
            'BETTY_OPENRSC_PERSONA': str(self.persona),
            'BETTY_OPENRSC_PERSONA_SHEET': str(self.root / 'absent'),
            'CUSTOM_PROMPT': '', 'DESKCRAB_GAME_DIR': str(self.root / 'game'),
            'DESKCRAB_GAME_STATE_DIR': str(self.root / 'state'),
            'OPENRSC_REVIEW_DIR': str(self.root / 'reviews'),
            'OPENRSC_REVIEW_TIMEOUT': '10', 'CODEX_BIN': str(self.cli),
            'CODEX_HOME': str(self.root / 'account'), 'OPENAI_API_KEY': 'fixture-key',
            'CODEX_API_KEY': 'fixture-key', 'REVIEW_FIXTURE': str(self.root), 'REVIEW_MODE': ''})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.paths = review.Paths()
        (self.paths.game / 'objective').write_text('Improve total levels')
        (self.paths.state / 'state.json').write_text(json.dumps({
            'ts': int(time.time()*1000), 'logged_in': True,
            'skills': [{'name': 'Fishing', 'xp': 100, 'base': 2}]}))
        self.ledger = patch.object(review, 'ledger')
        self.ledger_mock = self.ledger.start()
        self.addCleanup(self.ledger.stop)

    def status(self):
        return review.load(self.paths.reviews / 'latest.json')

    def test_routing_persona_evidence_and_success(self):
        self.assertEqual(review.run(self.paths), 0)
        call = review.load(self.root / 'called.json')
        args = call['args']
        self.assertEqual(args[args.index('-m')+1], 'gpt-6-astra')
        self.assertIn('model_reasoning_effort=high', args)
        self.assertIn('project_doc_max_bytes=0', args)
        self.assertIn('--ignore-user-config', args)
        self.assertEqual(call['account'], str(self.root / 'account'))
        self.assertIsNone(call['api_key'])
        self.assertIsNone(call['codex_key'])
        folder = Path(self.status()['directory'])
        instructions = (folder/'instructions.md').read_text()
        self.assertIn(self.persona.read_text(), instructions)
        self.assertIn('may change or upgrade ANY', instructions)
        self.assertIn('do not reopen a closed sitting', instructions)
        self.assertIn('Do not emit audio', instructions)
        self.assertIn('Improve total levels', call['input'])
        self.assertIn('"Fishing"', (folder/'before.json').read_text())
        self.assertTrue((folder/'after.json').exists())
        self.assertEqual(review.load(self.paths.reviews/'last-success.json')['state'], 'completed')
        self.ledger_mock.assert_called_once()

    def test_failures_preserve_prior_success(self):
        self.assertEqual(review.run(self.paths), 0)
        old = (self.paths.reviews/'last-success.json').read_bytes()
        for mode in ('error', 'partial', 'nonzero'):
            with self.subTest(mode=mode), patch.dict(os.environ, REVIEW_MODE=mode):
                self.assertEqual(review.run(self.paths), 1)
                self.assertEqual(self.status()['state'], 'failed')
                self.assertEqual((self.paths.reviews/'last-success.json').read_bytes(), old)
        self.assertEqual(self.ledger_mock.call_count, 4)

    def test_previous_report_is_in_next_prompt(self):
        review.run(self.paths)
        review.run(self.paths)
        prompt = json.loads(review.load(self.root/'called.json')['input'])
        self.assertIn('Verified fixture training', prompt['previous_report']['text'])
        self.assertEqual(prompt['previous_evidence']['state']['skills'][0]['xp'], 100)

    def test_author_watcher_restores_only_during_authorised_play(self):
        for authorised in (True, False):
            (self.root/'author-calls').unlink(missing_ok=True)
            calls = []
            def manager(*args, check=False):
                calls.append(args)
                code = 1 if 'orsc-player-control.service' in args and not authorised else 0
                return subprocess.CompletedProcess(args, code)
            with patch.object(review, 'systemctl', side_effect=manager):
                self.assertEqual(review.run(self.paths), 0)
            self.assertIn(('stop', 'orsc-author.path'), calls)
            self.assertNotIn(('stop', 'orsc-author.service'), calls)
            self.assertEqual((self.root/'author-calls').exists(), authorised)

    def test_author_watcher_restored_on_failed_review(self):
        with patch.object(review, 'systemctl', return_value=subprocess.CompletedProcess([], 0)) as manager:
            with patch.dict(os.environ, REVIEW_MODE='error'):
                self.assertEqual(review.run(self.paths), 1)
            self.assertEqual((self.root/'author-calls').read_text().strip(), 'author start')

    def test_crash_recovery_restores_author_and_marks_failure(self):
        folder = self.paths.reviews/'interrupted'
        folder.mkdir(parents=True)
        review.atomic(self.paths.reviews/'latest.json', {
            'state': 'running', 'directory': str(folder), 'author_watcher_paused': True})
        with patch.object(review, 'systemctl', return_value=subprocess.CompletedProcess([], 0)):
            self.assertEqual(review.recover(self.paths), 0)
        self.assertEqual(self.status()['state'], 'failed')
        self.assertTrue(self.status()['author_watcher_restored'])
        self.assertFalse((self.paths.reviews/'last-success.json').exists())

    def test_crash_recovery_leaves_live_review_alone(self):
        self.paths.reviews.mkdir()
        with (self.paths.reviews/'review.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertEqual(review.recover(self.paths), 0)
            self.assertFalse((self.root/'author-calls').exists())

    def test_missing_persona_does_not_call_model(self):
        self.persona.unlink()
        self.assertEqual(review.run(self.paths), 1)
        self.assertFalse((self.root/'called.json').exists())
        self.assertIn('persona', self.status()['error'])

    def test_duplicate_does_not_overwrite_status(self):
        self.paths.reviews.mkdir()
        with (self.paths.reviews/'review.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertEqual(review.run(self.paths), 0)
            self.assertFalse((self.paths.reviews/'latest.json').exists())
            self.assertFalse((self.root/'called.json').exists())

    def test_author_lock_excludes_review_then_releases(self):
        with (self.paths.game/'author.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            def release():
                self.assertFalse((self.root/'called.json').exists())
                fcntl.flock(lock, fcntl.LOCK_UN)
            timer = threading.Timer(0.2, release)
            timer.start()
            self.assertEqual(review.run(self.paths), 0)
            timer.join()
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_deadline_while_waiting_for_author(self):
        with (self.paths.game/'author.lock').open('a') as lock, patch.dict(os.environ, OPENRSC_REVIEW_TIMEOUT='1'):
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertEqual(review.run(self.paths), 1)
            self.assertFalse((self.root/'called.json').exists())
            self.assertIn('deadline', self.status()['error'])

    def test_deadline_kills_model_and_releases_author(self):
        with patch.dict(os.environ, OPENRSC_REVIEW_TIMEOUT='1', REVIEW_MODE='wait'):
            self.assertEqual(review.run(self.paths), 1)
        pid = int((self.root/'child.pid').read_text())
        with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
        with (self.paths.game/'author.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_real_shell_launcher_reads_config(self):
        config = self.root/'deskcrab.conf'
        config.write_text(f'CODEX_BIN="{self.cli}"\nCODEX_HOME="{self.root / "account"}"\n')
        env = dict(os.environ, DESKCRAB_CONF=str(config))
        completed = subprocess.run([str(review.HERE/'openrsc-review'), 'run'], env=env,
                                   capture_output=True, text=True, timeout=15)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(review.load(self.root/'called.json')['account'], str(self.root/'account'))
        self.assertNotIn('ledger_error', self.status())

    def test_timer_contract(self):
        units = review.HERE.parent/'systemd'
        timer = (units/'deskcrab-openrsc-review.timer').read_text()
        calendars = [line.split('=', 1)[1] for line in timer.splitlines() if line.startswith('OnCalendar=')]
        self.assertEqual(len(calendars), 3)
        stamps = []
        for expression in calendars:
            result = subprocess.run(['systemd-analyze', 'calendar', '--iterations=18',
                '--base-time=2026-01-01 00:00:00 UTC', expression],
                env=dict(os.environ, TZ='UTC'), capture_output=True, text=True, check=True)
            stamps += [datetime.strptime(value, '%Y-%m-%d %H:%M:%S') for value in
                       re.findall(r'(?:Next elapse|Iteration #\d+): \w+ ([0-9-]+ [0-9:]+) UTC', result.stdout)]
        stamps = sorted(stamps)[:34]
        self.assertEqual(len(stamps), 34)
        self.assertEqual({(b-a).total_seconds() for a,b in zip(stamps, stamps[1:])}, {2700})
        self.assertNotEqual(stamps[0].day, stamps[-1].day)
        self.assertIn('Persistent=true', timer)
        service = (units/'deskcrab-openrsc-review.service').read_text()
        self.assertIn('Type=oneshot', service)
        self.assertIn('KillMode=control-group', service)


if __name__ == '__main__':
    unittest.main()
