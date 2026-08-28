#!/usr/bin/env python3
"""Read-only OpenRSC frames and allowlisted HUD state for the phone server."""

import importlib.util
import json
import os
import subprocess
import threading
import time
from pathlib import Path


HEADLESS_DIR = Path(os.environ.get(
    "DESKCRAB_OPENRSC_HEADLESS",
    "~/Games/OpenRSC/headless")).expanduser()
STATE_DIR = Path(os.environ.get(
    "DESKCRAB_OPENRSC_STATE_DIR", "/tmp/deskcrab-game"))
GAME_DIR = Path(os.environ.get(
    "DESKCRAB_OPENRSC_GAME_DIR",
    "~/.local/share/deskcrab/game")).expanduser()
FFMPEG = os.environ.get("DESKCRAB_OPENRSC_FFMPEG", "ffmpeg")


def _bounded_int(name, default, low, high):
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError:
        value = default
    return max(low, min(high, value))


FPS = _bounded_int("DESKCRAB_OPENRSC_FPS", 4, 1, 8)
IDLE_SECONDS = _bounded_int("DESKCRAB_OPENRSC_IDLE_SECONDS", 15, 3, 120)
FRAME_WAIT_SECONDS = 3.0
MAX_JPEG_BYTES = 4 * 1024 * 1024


def _read_json(path):
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def spectator_state(now_ms=None):
    """Return only the small set of game facts useful to a spectator.

    Inventory, chat, credentials, routes, memory, and engine internals are
    deliberately absent. This endpoint is a view, not a second state API.
    """
    now = int(time.time() * 1000) if now_ms is None else int(now_ms)
    state = _read_json(STATE_DIR / "state.json")
    ts = state.get("ts")
    fresh = isinstance(ts, int) and 0 <= now - ts <= 5000
    activity = ""
    objective = ""
    try:
        activity = (GAME_DIR / "activity").read_text().strip()
    except OSError:
        pass
    try:
        objective = (GAME_DIR / "objective").read_text().strip()
    except OSError:
        pass

    xp_rates = []
    stats = _read_json(GAME_DIR / "activity-stats.json")
    started = stats.get("started_ms")
    baseline = stats.get("baseline_xp") or {}
    if activity and stats.get("activity") == activity \
            and isinstance(started, int) and isinstance(baseline, dict):
        elapsed = max(1, now - started)
        for skill in state.get("skills") or []:
            if not isinstance(skill, dict) or not isinstance(skill.get("id"), int) \
                    or not isinstance(skill.get("xp"), int):
                continue
            start = baseline.get(str(skill["id"]))
            if not isinstance(start, int) or skill["xp"] <= start:
                continue
            gained = skill["xp"] - start
            per_hour = round(gained * 3600000 / elapsed)
            if per_hour > 0:
                xp_rates.append({
                    "skill": str(skill.get("name") or f"skill-{skill['id']}"),
                    "gained": gained,
                    "per_hour": per_hour,
                })

    return {
        "available": fresh,
        "logged_in": bool(state.get("logged_in")) if fresh else False,
        "snapshot_age_ms": max(0, now - ts) if isinstance(ts, int) else None,
        "activity": activity,
        "objective": objective,
        "tile": ({"x": state.get("x"), "z": state.get("z")}
                 if fresh and isinstance(state.get("x"), int)
                 and isinstance(state.get("z"), int) else None),
        "hp": ({"current": state.get("hits"), "maximum": state.get("hits_max")}
               if fresh and isinstance(state.get("hits"), int)
               and isinstance(state.get("hits_max"), int) else None),
        "fatigue": state.get("fatigue") if fresh else None,
        "walking": bool(state.get("walking")) if fresh else False,
        "in_combat": bool(state.get("in_combat")) if fresh else False,
        "sleeping": bool(state.get("sleeping")) if fresh else False,
        "xp_rates": xp_rates,
    }


def _display_number():
    try:
        value = int((HEADLESS_DIR / "run" / "display").read_text().strip())
    except (OSError, ValueError):
        raise RuntimeError("OpenRSC is not running") from None
    socket_missing = not Path(f"/tmp/.X11-unix/X{value}").exists()
    if not 0 <= value <= 9999 \
            or (socket_missing and not os.environ.get("DESKCRAB_OPENRSC_SOURCE")):
        raise RuntimeError("OpenRSC private display is unavailable")
    return value


def _source_override():
    """Test-only deterministic source rectangle, absent in normal service."""
    raw = os.environ.get("DESKCRAB_OPENRSC_SOURCE", "")
    if not raw:
        return None
    try:
        x, y, width, height = (int(part) for part in raw.split(","))
    except (TypeError, ValueError):
        raise RuntimeError("invalid OpenRSC source override") from None
    if min(x, y) < 0 or not 1 <= width <= 8192 or not 1 <= height <= 8192:
        raise RuntimeError("invalid OpenRSC source override")
    return x, y, width, height


def _discover_source(display):
    override = _source_override()
    if override is not None:
        return override
    module_path = HEADLESS_DIR / "x11_source.py"
    try:
        spec = importlib.util.spec_from_file_location(
            "openrsc_x11_source", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        x11 = module.X11Source(display)
    except (OSError, AttributeError, ImportError) as exc:
        raise RuntimeError(f"OpenRSC source discovery failed: {exc}") from None
    try:
        return x11.discover_source()[:4]
    finally:
        x11.close()


class FrameSource:
    """One latest-frame ffmpeg producer shared by every authenticated viewer."""

    def __init__(self):
        self.cond = threading.Condition()
        self.thread = None
        self.proc = None
        self.stop_requested = False
        self.last_request = 0.0
        self.frame = None
        self.generation = 0
        self.error = ""
        self.source = None
        self.display = None

    def get(self, after=0, timeout=FRAME_WAIT_SECONDS):
        """Return ``(jpeg, generation, error)`` after a newer frame arrives."""
        with self.cond:
            self.last_request = time.monotonic()
            # A page can survive a phone-server restart while its old frame
            # generation cannot. Treat a future cursor as "current" so the
            # first frame from the fresh producer reconnects immediately.
            if after > self.generation:
                after = self.generation
            if self.thread is None or not self.thread.is_alive():
                self.frame = None
                self.error = ""
                self.stop_requested = False
                self.thread = threading.Thread(
                    target=self._run, name="openrsc-spectator", daemon=True)
                self.thread.start()
            deadline = time.monotonic() + max(0.0, timeout)
            while self.generation <= after and not self.error:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.cond.wait(remaining)
            if self.frame is not None and self.generation > after:
                return self.frame, self.generation, ""
            return None, self.generation, self.error or "frame timed out"

    def status(self):
        with self.cond:
            return {
                "streaming": bool(self.thread and self.thread.is_alive()),
                "generation": self.generation,
                "error": self.error,
                "display": self.display,
                "source": ({"x": self.source[0], "y": self.source[1],
                            "width": self.source[2], "height": self.source[3]}
                           if self.source else None),
                "fps": FPS,
            }

    def _run(self):
        proc = None
        reason = ""
        try:
            display = _display_number()
            source = _discover_source(display)
            x, y, width, height = source
            env = {key: value for key, value in os.environ.items()
                   if key not in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY")}
            cmd = [
                FFMPEG, "-nostdin", "-loglevel", "error",
                "-f", "x11grab", "-draw_mouse", "0",
                "-framerate", str(FPS),
                "-video_size", f"{width}x{height}",
                "-i", f":{display}+{x},{y}",
                "-an", "-c:v", "mjpeg", "-q:v", "5",
                "-f", "image2pipe", "pipe:1",
            ]
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                env=env, start_new_session=True)
            with self.cond:
                self.proc = proc
                self.display = display
                self.source = source
                self.cond.notify_all()
            buf = bytearray()
            while True:
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    reason = "OpenRSC frame stream ended"
                    break
                buf.extend(chunk)
                while True:
                    start = buf.find(b"\xff\xd8")
                    if start < 0:
                        if len(buf) > 1:
                            del buf[:-1]
                        break
                    end = buf.find(b"\xff\xd9", start + 2)
                    if end < 0:
                        if start:
                            del buf[:start]
                        if len(buf) > MAX_JPEG_BYTES:
                            raise RuntimeError("OpenRSC JPEG frame exceeded its bound")
                        break
                    jpeg = bytes(buf[start:end + 2])
                    del buf[:end + 2]
                    with self.cond:
                        self.frame = jpeg
                        self.generation += 1
                        idle = time.monotonic() - self.last_request
                        stop = self.stop_requested or idle > IDLE_SECONDS
                        self.cond.notify_all()
                    if stop:
                        reason = ""
                        return
        except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
            reason = str(exc)[:200]
        finally:
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            with self.cond:
                self.proc = None
                self.thread = None
                if reason and not self.stop_requested:
                    self.error = reason
                self.cond.notify_all()

    def close(self):
        with self.cond:
            self.stop_requested = True
            proc = self.proc
            thread = self.thread
            self.cond.notify_all()
        if proc is not None and proc.poll() is None:
            proc.terminate()
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=3)


FRAMES = FrameSource()
