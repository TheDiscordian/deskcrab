"""Run through test_game_sleep_wake.sh; the optional argument is read-only harness source."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

if 'SANDBOX' not in os.environ:
    raise SystemExit('run tests/test_game_sleep_wake.sh')
HARNESS = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path('/absent-harness')
PLAYER = Path(__file__).resolve().parents[1]/'lib/game_player.py'


class SleepWake(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['SANDBOX'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root/'state'
        self.state.mkdir()
        self.env = dict(os.environ, DESKCRAB_GAME_DIR=str(self.root/'game'),
                        DESKCRAB_GAME_STATE_DIR=str(self.state))
        self.command('init', expected=0)

    def command(self, *args, expected):
        result = subprocess.run([sys.executable, '-B', str(PLAYER), *args], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout+'\n'+result.stderr)
        return result.stdout

    def snapshot(self, **extra):
        body = dict(ts=int(time.time()*1000), tick=1, x=100, z=100,
                    logged_in=True, sleeping=True, sleep_fatigue=0, fatigue=100,
                    sleep_status='Please wait...', messages=[], players=[], inventory=[])
        body.update(extra)
        (self.state/'state.json').write_text(json.dumps(body))

    def test_sleep_requires_input_even_after_sleep_fatigue_reaches_zero(self):
        for resident in (False, True):
            for remaining in (50, 0):
                with self.subTest(resident=resident, sleep_fatigue=remaining):
                    self.snapshot(sleep_fatigue=remaining)
                    if resident:
                        (self.state/'player-runner.json').write_text(json.dumps({
                            'pid': os.getpid(), 'ts': int(time.time()*1000),
                            'verdict': 'sleeping-needs-wake'}))
                    else:
                        (self.state/'player-runner.json').unlink(missing_ok=True)
                    output = self.command('step', expected=4)
                    self.assertIn('sleeping-needs-wake', output)
                    self.assertIn('next=solve-current-word-from-screenshot-submit-Return', output)
                    self.assertIn('then-wait-until-not_sleeping-and-fatigue_zero', output)
                    self.assertIn('current-word-submission-even-when-sleep-fatigue-is-zero', output)
                    self.assertFalse((self.state/'action.json').exists())

    def test_waits_verify_actual_wake_completion(self):
        self.snapshot()
        self.command('wait-until', 'not_sleeping', '--timeout', '0.05', expected=2)
        self.snapshot(sleeping=False, fatigue=0)
        self.command('wait-until', 'not_sleeping', '--timeout', '0.05', expected=0)
        self.command('wait-until', 'fatigue_zero', '--timeout', '0.05', expected=0)

    @unittest.skipUnless(HARNESS.is_file(), 'companion OpenRSC harness is not installed')
    def test_fresh_and_resumed_prompts_share_the_required_sleep_input(self):
        source = HARNESS.read_text()
        helper = source.split('\nsleep_guidance() {', 1)[1].split('\ncompose_prompt()', 1)[0]
        fresh = source.split('\ncompose_prompt()', 1)[1].split('\ncompose_resume_prompt()', 1)[0]
        resume = source.split('\ncompose_resume_prompt()', 1)[1].split('\ncmd_steer()', 1)[0]
        self.assertIn('    sleep_guidance\n', fresh)
        self.assertIn('$(sleep_guidance)', resume)
        result = subprocess.run(['bash', '-c', 'sleep_guidance() {'+helper+'\nsleep_guidance'],
                                env=self.env, capture_output=True, text=True, check=True)
        self.assertIn('type it and press Return', result.stdout)
        self.assertIn('BEFORE waiting for not_sleeping', result.stdout)
        self.assertIn('not a server failure', result.stdout)


if __name__ == '__main__':
    unittest.main()
