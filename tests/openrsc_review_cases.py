"""Run only through the shared sandbox in test_openrsc_review.sh."""
import fcntl
from datetime import datetime
import json
import os
import re
import shutil
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
        (self.root/'bin').mkdir()
        manager = self.root/'bin/systemctl'
        manager.write_text('#!/bin/sh\nexit 0\n')
        manager.chmod(0o755)
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
            'PATH': str(self.root/'bin') + os.pathsep + os.environ['PATH'],
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
        review.atomic(self.paths.game / 'session.json', {
            'started': int(time.time()*1000)-1000, 'limit_ms': 3600000, 'ended': None})
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
        self.assertEqual(self.status()['session_started'], review.load(self.paths.game/'session.json')['started'])
        self.assertTrue(self.status()['first_review_of_sitting'])
        self.assertTrue(json.loads(call['input'])['first_review_of_sitting'])

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
        self.assertFalse(prompt['first_review_of_sitting'])
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
            self.assertEqual(('stop', 'orsc-author.path') in calls, authorised)
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

    def test_offline_launches_leave_no_artifacts_or_author_calls(self):
        session = review.load(self.paths.game/'session.json')
        state = review.load(self.paths.state/'state.json')
        cases = [
            ({}, state), ([], state),
            (dict(session, ended=int(time.time()*1000)), state),
            (dict(session, limit_ms=1), state),
            (dict(session, started='bad'), state),
            (session, {}), (session, []),
            (session, dict(state, logged_in=False)),
            (session, dict(state, ts=1)), (session, dict(state, ts='bad'))]
        for sitting, snapshot in cases:
            with self.subTest(session=sitting, state=snapshot):
                review.atomic(self.paths.game/'session.json', sitting)
                review.atomic(self.paths.state/'state.json', snapshot)
                with patch.object(review, 'systemctl') as manager:
                    self.assertEqual(review.run(self.paths), 0)
                    manager.assert_not_called()
                self.assertFalse(self.paths.reviews.exists())
                self.assertFalse((self.root/'called.json').exists())
                self.assertFalse((self.paths.game/'author.lock').exists())
        review.atomic(self.paths.game/'session.json', session)
        review.atomic(self.paths.state/'state.json', state)
        with patch.object(review, 'systemctl', return_value=subprocess.CompletedProcess([], 3)) as manager:
            self.assertEqual(review.run(self.paths), 0)
            manager.assert_called_once_with('is-active', '--quiet', review.CONTROL_UNIT)
        self.assertFalse(self.paths.reviews.exists())
        with patch.object(review, 'systemctl', side_effect=subprocess.TimeoutExpired('systemctl', 20)):
            self.assertFalse(review.playing(self.paths))

    def test_pending_control_stop_blocks_reviews_and_author_restoration(self):
        def manager(*args, check=False):
            return subprocess.CompletedProcess(args, 0, stdout='1234' if args[0] == 'show' else '')
        with patch.object(review, 'systemctl', side_effect=manager):
            self.assertFalse(review.playing(self.paths))
            self.assertEqual(review.run(self.paths), 0)
            status = {}
            review.restore_author(self.paths, status)
        self.assertFalse(status['author_watcher_restored'])
        self.assertFalse(self.paths.reviews.exists())
        self.assertFalse((self.root/'author-calls').exists())

    def test_real_offline_launcher_and_condition_do_not_call_model(self):
        (self.paths.game/'session.json').unlink()
        for command, code in (('run', 0), ('eligible', 1)):
            result = subprocess.run([str(review.HERE/'openrsc-review'), command],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, code, result.stderr)
        self.assertFalse(self.paths.reviews.exists())
        self.assertFalse((self.root/'called.json').exists())
        self.assertFalse((self.root/'author-calls').exists())

    def end_play(self):
        session = review.load(self.paths.game/'session.json')
        review.atomic(self.paths.game/'session.json', dict(session, ended=int(time.time()*1000)))

    def test_play_ending_during_author_wait_never_launches_model(self):
        with (self.paths.game/'author.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            timer = threading.Timer(0.25, self.end_play)
            timer.start()
            try:
                self.assertEqual(review.run(self.paths), 0)
            finally:
                timer.join()
        self.assertEqual(self.status()['state'], 'cancelled')
        self.assertFalse((self.root/'called.json').exists())
        self.assertFalse((self.paths.reviews/'last-success.json').exists())

    def test_play_ending_before_spawn_never_launches_model(self):
        original = self.paths.snapshot
        def snapshot():
            self.end_play()
            return original()
        with patch.object(self.paths, 'snapshot', side_effect=snapshot):
            self.assertEqual(review.run(self.paths), 0)
        self.assertEqual(self.status()['state'], 'cancelled')
        self.assertFalse((self.root/'called.json').exists())

    def test_play_ending_kills_running_model_and_preserves_last_success(self):
        self.assertEqual(review.run(self.paths), 0)
        prior = (self.paths.reviews/'last-success.json').read_bytes()
        timer = threading.Timer(0.4, self.end_play)
        timer.start()
        try:
            with patch.dict(os.environ, REVIEW_MODE='wait'):
                self.assertEqual(review.run(self.paths), 0)
        finally:
            timer.join()
        self.assertEqual(self.status()['state'], 'cancelled')
        pid = int((self.root/'child.pid').read_text())
        with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
        self.assertEqual((self.paths.reviews/'last-success.json').read_bytes(), prior)
        with (self.paths.game/'author.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_new_sitting_cannot_inherit_a_running_review(self):
        old = review.load(self.paths.game/'session.json')['started']
        session = review.load(self.paths.game/'session.json')
        review.atomic(self.paths.game/'session.json', dict(session, started=old+1))
        self.assertTrue(review.playing(self.paths))
        with self.assertRaises(review.PlayEnded):
            review.require_playing(self.paths, old)

    def test_watcher_only_arms_timer_during_play_and_stops_on_logout(self):
        calls = []
        def manager(*args, check=False):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0)
        with patch.object(review, 'systemctl', side_effect=manager):
            armed = review.watch_step(self.paths, None)
            self.assertTrue(armed)
            self.assertIn(('start', review.TIMER_UNIT), calls)
            calls.clear()
            armed = review.watch_step(self.paths, armed)
            self.assertEqual(calls, [('is-active', '--quiet', review.CONTROL_UNIT),
                                     ('show', '--property=Job', '--value', review.CONTROL_UNIT),
                                     ('show', '--property=ActiveState', '--value', review.REVIEW_UNIT)])
            self.end_play()
            calls.clear()
            armed = review.watch_step(self.paths, armed)
            self.assertFalse(armed)
            self.assertEqual(calls, [('stop', review.TIMER_UNIT, review.REVIEW_UNIT)])
            calls.clear()
            self.assertFalse(review.watch_step(self.paths, armed))
            self.assertEqual(calls, [])
        self.assertFalse(self.paths.reviews.exists())
        self.assertFalse((self.root/'called.json').exists())

    def startup_manager(self, *args, check=False):
        state = 'inactive' if args == ('show', '--property=ActiveState', '--value', review.REVIEW_UNIT) else ''
        return subprocess.CompletedProcess(args, 0, stdout=state)

    def test_startup_requests_review_once_and_retains_the_periodic_timer(self):
        with patch.object(review, 'systemctl', side_effect=self.startup_manager) as manager:
            self.assertTrue(review.watch_step(self.paths, None))
            manager.assert_any_call('start', review.TIMER_UNIT, check=True)
            manager.assert_any_call('start', '--no-block', review.REVIEW_UNIT, check=True)
            self.assertFalse(self.paths.reviews.exists())  # admission belongs to the service
            self.assertEqual(review.run(self.paths), 0)
            manager.reset_mock()
            self.assertTrue(review.watch_step(review.Paths(), None))  # scheduler restart
            self.assertFalse(any(call.args == ('start', '--no-block', review.REVIEW_UNIT)
                                 for call in manager.call_args_list))
            session = review.load(self.paths.game/'session.json')
            review.atomic(self.paths.game/'session.json', dict(session, limit_ms=7200000))
            self.assertTrue(review.watch_step(self.paths, True))  # deadline extension
            self.end_play()
            self.assertFalse(review.watch_step(self.paths, True))
            review.atomic(self.paths.game/'session.json', session)  # reconnect in same sitting
            self.assertTrue(review.watch_step(self.paths, False))
            self.assertFalse(any(call.args == ('start', '--no-block', review.REVIEW_UNIT)
                                 for call in manager.call_args_list))

    def test_new_sitting_gets_startup_review_even_if_watcher_never_saw_offline(self):
        self.assertEqual(review.run(self.paths), 0)
        session = review.load(self.paths.game/'session.json')
        review.atomic(self.paths.game/'session.json', dict(session, started=session['started']+1))
        with patch.object(review, 'systemctl', side_effect=self.startup_manager) as manager:
            self.assertTrue(review.watch_step(self.paths, True))
            manager.assert_any_call('start', '--no-block', review.REVIEW_UNIT, check=True)

    def test_startup_waits_for_inflight_review_without_interrupting_it(self):
        for state in ('active', 'activating', 'deactivating', 'unknown'):
            with self.subTest(state=state), patch.object(review, 'systemctl',
                    return_value=subprocess.CompletedProcess([], 0, stdout=state)) as manager:
                review.request_start_review(self.paths)
                manager.assert_called_once_with('show', '--property=ActiveState', '--value', review.REVIEW_UNIT)
        self.assertFalse(self.paths.reviews.exists())

    def test_startup_waits_for_login_and_does_not_consume_offline_attempt(self):
        snapshot = review.load(self.paths.state/'state.json')
        review.atomic(self.paths.state/'state.json', dict(snapshot, logged_in=False))
        with patch.object(review, 'systemctl', side_effect=self.startup_manager) as manager:
            self.assertFalse(review.watch_step(self.paths, False))
            manager.assert_not_called()
            self.assertFalse(self.paths.reviews.exists())
            review.atomic(self.paths.state/'state.json', snapshot)
            self.assertTrue(review.watch_step(self.paths, False))
            manager.assert_any_call('start', '--no-block', review.REVIEW_UNIT, check=True)

    def test_startup_rechecks_play_after_reading_service_state(self):
        def manager(*args, check=False):
            self.end_play()
            return subprocess.CompletedProcess(args, 0, stdout='inactive')
        with patch.object(review, 'systemctl', side_effect=manager) as manager:
            review.request_start_review(self.paths)
            manager.assert_called_once()
        self.assertFalse(self.paths.reviews.exists())

    def test_failed_launch_can_be_retried_without_duplicate_admission(self):
        def manager(*args, check=False):
            if args == ('start', '--no-block', review.REVIEW_UNIT):
                raise subprocess.CalledProcessError(1, args)
            return self.startup_manager(*args, check=check)
        with patch.object(review, 'systemctl', side_effect=manager):
            with self.assertRaises(subprocess.CalledProcessError):
                review.request_start_review(self.paths)
        self.assertFalse(self.paths.reviews.exists())
        with patch.object(review, 'systemctl', side_effect=self.startup_manager) as manager:
            review.request_start_review(self.paths)
            manager.assert_any_call('start', '--no-block', review.REVIEW_UNIT, check=True)

    def test_failed_admitted_review_does_not_loop_on_startup(self):
        with patch.dict(os.environ, REVIEW_MODE='error'):
            self.assertEqual(review.run(self.paths), 1)
        with patch.object(review, 'systemctl') as manager:
            review.request_start_review(self.paths)
            manager.assert_not_called()

    def test_existing_report_identifies_already_reviewed_sitting(self):
        self.paths.reviews.mkdir()
        sitting = review.load(self.paths.game/'session.json')['started']
        legacy = {'state': 'completed', 'started_at': review.utc()}
        review.atomic(self.paths.reviews/'latest.json', legacy)
        self.assertTrue(review.reviewed_sitting(self.paths, sitting))
        review.atomic(self.paths.reviews/'latest.json', dict(legacy, session_started=sitting-1000))
        self.assertFalse(review.reviewed_sitting(self.paths, sitting))
        review.atomic(self.paths.reviews/'latest.json', dict(legacy, started_at='2000-01-01T00:00:00+00:00'))
        self.assertFalse(review.reviewed_sitting(self.paths, sitting))

    def test_watcher_exits_when_control_is_inactive(self):
        with patch.object(review, 'systemctl', return_value=subprocess.CompletedProcess([], 3)) as manager:
            self.assertEqual(review.watch(self.paths), 0)
        self.assertEqual([call.args for call in manager.call_args_list], [
            ('is-active', '--quiet', review.CONTROL_UNIT),
            ('stop', '--no-block', review.TIMER_UNIT, review.REVIEW_UNIT)])
        self.assertFalse(self.paths.reviews.exists())

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
        self.assertNotIn('Persistent=true', timer)
        self.assertNotIn('[Install]', timer)
        self.assertIn('DefaultDependencies=no', timer)
        self.assertIn('Conflicts=shutdown.target', timer)
        self.assertIn('Before=shutdown.target', timer)
        watcher = (units/'deskcrab-openrsc-review-watch.service').read_text()
        control = (units/'orsc-player-control.service.d/openrsc-review.conf').read_text()
        self.assertIn('Wants=deskcrab-openrsc-review-watch.service', control)
        self.assertNotIn('[Install]', watcher)
        self.assertIn('openrsc-review watch', watcher)
        for unit in (timer, watcher, (units/'deskcrab-openrsc-review.service').read_text()):
            self.assertIn('Requisite=orsc-player-control.service', unit)
            self.assertIn('PartOf=orsc-player-control.service', unit)
            self.assertNotRegex(unit, r'(?m)^(Requires|Wants|BindsTo)=')
        service = (units/'deskcrab-openrsc-review.service').read_text()
        self.assertIn('Type=oneshot', service)
        self.assertIn('KillMode=control-group', service)
        self.assertIn('ExecCondition=%h/.local/lib/deskcrab/openrsc-review eligible', service)

    def test_lifecycle_units_have_no_ordering_cycle(self):
        units = review.HERE.parent/'systemd'
        target = self.root/'units'
        target.mkdir()
        names = ('deskcrab-openrsc-review.service', 'deskcrab-openrsc-review.timer',
                 'deskcrab-openrsc-review-watch.service')
        for name in names:
            (target/name).write_text((units/name).read_text().replace(
                '%h/.local/lib/deskcrab/openrsc-review', '/usr/bin/true'))
        shutil.copytree(units/'orsc-player-control.service.d', target/'orsc-player-control.service.d')
        (target/'orsc-player-control.service').write_text(
            '[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/true\n')
        result = subprocess.run(['systemd-analyze', '--user', 'verify',
                                 *[str(target/name) for name in names]],
                                env=dict(os.environ, SYSTEMD_UNIT_PATH=str(target)+':'),
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
