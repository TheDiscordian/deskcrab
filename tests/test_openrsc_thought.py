#!/usr/bin/env python3
"""Focused allowlist and rendering contract for OpenRSC Recent thought."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]


with tempfile.TemporaryDirectory() as raw:
    temp = Path(raw)
    state_dir = temp / "state"
    game_dir = temp / "game"
    state_dir.mkdir()
    game_dir.mkdir()
    player_log = temp / "player.log"
    now = int(time.time() * 1000)
    (state_dir / "state.json").write_text(json.dumps({
        "ts": now, "logged_in": True, "x": 12, "z": 34,
        "hits": 7, "hits_max": 21, "fatigue": 4, "skills": [],
        "messages": [{"text": "private chat must stay private"}],
        "inventory": [{"name": "credential-shaped secret"}],
    }))
    (game_dir / "activity").write_text("bank-resupply\n")
    (game_dir / "objective").write_text("prayer-training\n")
    player_log.write_text("\n".join((
        json.dumps({"type": "assistant", "message": {"content": [
            {"type": "text", "text": "Low on tea; banking before the next load."}
        ]}}),
        json.dumps({"type": "assistant", "message": {"content": [
            {"type": "thinking", "thinking": "private chain of thought"},
            {"type": "tool_use", "name": "Bash", "input": {"command": "secret"}},
        ]}}),
    )) + "\n")

    os.environ.update({
        "DESKCRAB_OPENRSC_STATE_DIR": str(state_dir),
        "DESKCRAB_OPENRSC_GAME_DIR": str(game_dir),
        "DESKCRAB_OPENRSC_PLAYER_LOG": str(player_log),
    })
    spec = importlib.util.spec_from_file_location(
        "openrsc_spectator_thought_test", ROOT / "lib/openrsc_spectator.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    doc = module.spectator_state(now)

assert doc["recent_thought"] == "Low on tea; banking before the next load.", doc
encoded = json.dumps(doc)
assert "private chain" not in encoded, encoded
assert "private chat" not in encoded, encoded
assert "credential-shaped" not in encoded, encoded

page = (ROOT / "lib/webapp/openrsc.html").read_text()
assert 'id="recent-thought"' in page, "Recent thought card missing"
assert "thoughtText.textContent = st.recent_thought" in page, \
    "thought must render as text, never injected HTML"
assert "Recent thought" in page

print("test_openrsc_thought: 8 passed, 0 failed")
