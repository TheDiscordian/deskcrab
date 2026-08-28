#!/usr/bin/env python3
"""Focused contract tests for the OpenRSC visual aiming fallback."""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import time
import unittest
from argparse import Namespace

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "game_npc_click", os.path.join(REPO, "lib", "game_npc_click.py"))
aim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aim)


def frame(cx=None, cy=None, width=160, height=120):
    hits = set()
    if cx is not None:
        hits = {(x, y) for x in range(cx - 1, cx + 2)
                for y in range(cy - 1, cy + 2)}

    def pixel(x, y):
        return (255, 0, 0) if (x, y) in hits else (0, 0, 0)

    return width, height, pixel


class FakeDisplay:
    def __init__(self, frames):
        self.frames = list(frames)
        self.grabs = 0
        self.calls = []

    def grab(self):
        result = self.frames[min(self.grabs, len(self.frames) - 1)]
        self.grabs += 1
        return result

    def xte(self, *commands):
        self.calls.append(commands)


class AimCase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="npc-click-")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def args(self, **changes):
        values = dict(
            intent="255,0,0:0", conf=os.path.join(self.root, "missing.conf"),
            button=None, min_pixels=4, no_presence_gate=True, defs="",
            state_dir=self.root, view=(0, 0, 160, 120),
            toolbar=(200, 200, 210, 210), settle_ms=0, stable_px=2,
            max_jump=48, near=None, nth=None, dry_run=False, retries=5,
            chase=False)
        values.update(changes)
        return Namespace(**values)

    def invoke(self, display, **changes):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = aim.run(self.args(**changes), display)
        return code, out.getvalue().strip()


class TestAcquireVerifyAct(AimCase):
    def test_still_target_moves_then_clicks_in_separate_calls(self):
        display = FakeDisplay([frame(30, 40), frame(30, 40)])
        code, out = self.invoke(display)
        self.assertEqual(code, aim.EXIT_CLICKED)
        self.assertIn("clicked", out)
        self.assertEqual(display.grabs, 2)
        self.assertEqual(display.calls,
                         [("mousemove 30 40",), ("mouseclick 1",)])
        self.assertFalse(any("mousemove" in " ".join(call)
                             and "mouseclick" in " ".join(call)
                             for call in display.calls))

    def test_walking_target_is_followed_then_reverified(self):
        display = FakeDisplay([frame(30, 40), frame(42, 40), frame(42, 40)])
        code, out = self.invoke(display)
        self.assertEqual(code, aim.EXIT_CLICKED)
        self.assertIn("attempt=2", out)
        self.assertEqual(display.calls,
                         [("mousemove 30 40",), ("mousemove 42 40",),
                          ("mouseclick 1",)])

    def test_far_jump_reacquires_from_the_same_fresh_frame(self):
        # This was the abandoned slice's concrete bug: beyond max-jump it
        # threw the fresh candidates away and could never find the NPC again.
        display = FakeDisplay([frame(30, 40), frame(110, 40), frame(110, 40)])
        code, _ = self.invoke(display, max_jump=20)
        self.assertEqual(code, aim.EXIT_CLICKED)
        self.assertEqual(display.grabs, 3)  # initial + one per attempt
        self.assertEqual(display.calls,
                         [("mousemove 30 40",), ("mousemove 110 40",),
                          ("mouseclick 1",)])

    def test_transient_disappearance_can_reappear_inside_the_budget(self):
        display = FakeDisplay([frame(30, 40), frame(), frame(30, 40)])
        code, out = self.invoke(display, retries=3)
        self.assertEqual(code, aim.EXIT_CLICKED)
        self.assertIn("attempt=2", out)
        self.assertEqual(display.grabs, 3)

    def test_exhaustion_never_clicks(self):
        display = FakeDisplay([frame(30, 40), frame(40, 40), frame(50, 40)])
        code, out = self.invoke(display, retries=2, stable_px=1)
        self.assertEqual(code, aim.EXIT_UNSTABLE)
        self.assertIn("unstable", out)
        self.assertFalse(any(call[0].startswith("mouseclick")
                             for call in display.calls))
        self.assertLessEqual(display.grabs, 3)  # 1 + retries

    def test_explicit_chase_spends_the_last_attempt(self):
        display = FakeDisplay([frame(30, 40), frame(50, 40)])
        code, out = self.invoke(display, retries=1, chase=True)
        self.assertEqual(code, aim.EXIT_CLICKED)
        self.assertIn("chased=1", out)
        self.assertEqual(display.calls[-2:],
                         [("mousemove 50 40",), ("mouseclick 1",)])

    def test_dry_run_grabs_twice_and_never_touches_the_pointer(self):
        display = FakeDisplay([frame(30, 40), frame(31, 40)])
        code, out = self.invoke(display, dry_run=True)
        self.assertEqual(code, aim.EXIT_CLICKED)
        self.assertIn("dry-run", out)
        self.assertEqual(display.grabs, 2)
        self.assertEqual(display.calls, [])


class TestRegistryAndGate(AimCase):
    def test_manual_hold_and_shared_action_slot_keep_pointer_untouched(self):
        display = FakeDisplay([frame(30, 40)])
        open(os.path.join(self.root, "hold"), "w").close()
        code, out = self.invoke(display)
        self.assertEqual(code, aim.EXIT_HELD)
        self.assertIn("held", out)
        os.remove(os.path.join(self.root, "hold"))
        open(os.path.join(self.root, "action.json"), "w").close()
        code, out = self.invoke(display)
        self.assertEqual(code, aim.EXIT_BUSY)
        self.assertIn("busy", out)
        self.assertEqual(display.grabs, 0)
        self.assertEqual(display.calls, [])

    def test_absent_named_npc_is_refused_before_a_frame_grab(self):
        conf = os.path.join(self.root, "npc-visuals.conf")
        defs = os.path.join(self.root, "NpcDefs.json")
        with open(conf, "w") as fh:
            fh.write("sheep = red-cape button=3 min=4\n")
        with open(defs, "w") as fh:
            json.dump({"npcs": [{"id": 2, "name": "Sheep"}]}, fh)
        with open(os.path.join(self.root, "state.json"), "w") as fh:
            json.dump({"ts": int(time.time() * 1000), "logged_in": True,
                       "npcs": [{"id": 7}]}, fh)
        display = FakeDisplay([frame(30, 40)])
        code, out = self.invoke(
            display, intent="sheep", conf=conf, defs=defs,
            no_presence_gate=False)
        self.assertEqual(code, aim.EXIT_NOT_VISIBLE)
        self.assertIn("not-visible", out)
        self.assertIn("gate=ok", out)
        self.assertEqual(display.grabs, 0)
        self.assertEqual(display.calls, [])

    def test_registry_refuses_unsafe_button_and_zero_pixel_floor(self):
        conf = os.path.join(self.root, "npc-visuals.conf")
        with open(conf, "w") as fh:
            fh.write("sheep = red-cape button=4\n")
        with self.assertRaises(aim.Usage):
            aim.load_registry(conf)
        with open(conf, "w") as fh:
            fh.write("sheep = red-cape min=0\n")
        with self.assertRaises(aim.Usage):
            aim.load_registry(conf)

    def test_rgb_specs_are_bounded_to_real_channels(self):
        self.assertIsNotNone(aim.parse_rgb_spec("255,0,128:30"))
        self.assertIsNone(aim.parse_rgb_spec("256,0,0"))
        self.assertIsNone(aim.parse_rgb_spec("255,-1,0"))
        self.assertIsNone(aim.parse_rgb_spec("255,0,0:999"))


class TestCliSafety(unittest.TestCase):
    def test_physical_displays_are_refused(self):
        for display in ("0", "1", "00", "01", "0001"):
            with self.subTest(display=display):
                self.assertEqual(
                    aim.main(["red-cape", "--display", display]),
                    aim.EXIT_DISPLAY)

    def test_invalid_work_budgets_are_refused(self):
        self.assertEqual(aim.main(["red-cape", "--display", "98",
                                   "--retries", "0"]), aim.EXIT_USAGE)
        self.assertEqual(aim.main(["red-cape", "--display", "98",
                                   "--settle-ms", "6000"]), aim.EXIT_USAGE)

    def test_help_is_success(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(aim.main(["--help"]), 0)


if __name__ == "__main__":
    unittest.main()
