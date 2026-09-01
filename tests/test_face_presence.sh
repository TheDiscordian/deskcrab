#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DESKCRAB_STATE_PREFIX="$TMP/state" \
DESKCRAB_SESSIONS_DIR="$TMP/sessions" \
JOBS_DIR="$TMP/jobs" \
DESKCRAB_GAME_STATE="$TMP/game.json" \
REPO_DIR="$REPO_DIR" python3 - <<'PY'
import importlib.util, importlib.machinery, json, os, sys, time
from pathlib import Path

repo = Path(os.environ["REPO_DIR"])
lib = repo / "lib"
sys.path.insert(0, str(lib))
import face_state

loader = importlib.machinery.SourceFileLoader("presence", str(lib / "face-presence"))
spec = importlib.util.spec_from_loader("presence", loader)
p = importlib.util.module_from_spec(spec)
loader.exec_module(p)
p.SESSIONS.mkdir(); p.JOBS.mkdir()
pid = os.getpid(); start = p.proc_start(pid)
(p.SESSIONS / str(pid)).write_text(
    "autonomous wake\t%d\t2026-08-31 17:00:00\t1\t%d\n" % (pid, start))
(p.JOBS / "builder.json").write_text(json.dumps(
    {"state":"running", "pid":pid, "pidstart":start, "started":"now"}))
name, detail, sources = p.observe()
assert name == "considering" and len(sources) == 2, (name, detail, sources)

(p.SESSIONS / str(pid)).unlink(); (p.JOBS / "builder.json").unlink()
p.GAME.write_text('{"logged_in":true}')
assert p.observe()[0] == "openrsc-live"
p.GAME.write_text('{"logged_in":false}')
assert p.observe()[0] == "sleeping"

b = face_state.Broker(str(Path(os.environ["DESKCRAB_STATE_PREFIX"] + "-face.json")))
b.set_mood("pleased")
b.set_ambient("sleeping", "all hands idle", [])
s = b.snapshot()
assert (s["activity"], s["expression"], s["expression_source"]) == \
       ("sleeping", "sleeping", "activity"), s
b.set_expression("caught", source="explicit", seconds=30)
assert b.snapshot()["expression"] == "caught"
b.release()
assert b.snapshot()["expression"] == "sleeping"
b.set_ambient("considering", "one working hand", ["session:wake"])
s = b.snapshot()
assert s["activity"] == "considering" and s["expression"] == "pleased", s
b.activity = "chess"; b.activity_set_at = time.time() - 999
assert b.snapshot()["activity"] == "considering"
b.ambient_updated = time.time() - 999
assert b.snapshot()["activity"] == "sleeping"
print("face presence tests passed")
PY

# All runtime surfaces must know the sleeping frame and motion state.
grep -q '"sleeping": {"energy"' "$REPO_DIR/lib/face-window"
grep -q 'sleeping: { energy:' "$REPO_DIR/lib/face_card.js"
grep -q 'sleeping: "asleep"' "$REPO_DIR/lib/webapp/face.html"
test -x "$REPO_DIR/lib/face-presence"
