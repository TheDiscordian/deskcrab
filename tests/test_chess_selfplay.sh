#!/bin/bash
# Chess self-play economics (specs/chess-selfplay.md). The 2026-08-15 night:
# a grind driver inherited the real-game model knob and made ~1,590 calls on
# the dearest model in the house, cooling every account by morning. These
# cases prove the two guards that make that night unrepeatable — self-play
# builds its own model invocation and never reads the real-game knob, and the
# nightly move budget binds both in the driver's loop (a clean stop) and at
# the mover's choke point (the backstop no driver can skip) — and that a real
# game feels none of it.
# Run: bash tests/test_chess_selfplay.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
# The sandbox moves HOME, and a venv is 100MB of install — so the live one is
# borrowed read-only rather than rebuilt per run. Skip if it was never made.
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
if [ ! -x "$VENV/bin/python" ]; then
  echo "SKIP: no chess venv at $VENV — run betty-chess once to bootstrap it"
  exit 0
fi
PY="$VENV/bin/python"

export DESKCRAB_CHESS_DIR="$SANDBOX/chess"
mkdir -p "$DESKCRAB_CHESS_DIR/selfplay" "$DESKCRAB_CHESS_DIR/games"
# The counter is keyed by NIGHT — the date of (now - 12 h) — not by the
# calendar day (specs/chess-selfplay.md rule 4).
COUNTER="$DESKCRAB_CHESS_DIR/selfplay/model-calls-$(date -d '12 hours ago' +%Y%m%d).log"
# A wall a couple of hours ahead keeps every driver run below on the night
# path whatever hour the suite runs at, so the daytime guard never trips
# where it is not the case under test.
NEAR_WALL="$(date -d '+2 hours' +%H:%M)"

# The stub mover: records the call, then answers with the prompt itself —
# the prompt lists every legal move in UCI, and the parser keeps the last
# LEGAL token, so the reply is always a legal move without a model anywhere.
STUB="$SANDBOX/stub-mover"
CALLS="$SANDBOX/stub-calls"
cat > "$STUB" <<EOF
#!/bin/bash
echo called >> "$CALLS"
cat
EOF
chmod +x "$STUB"
export DESKCRAB_CHESS_MOVER_CMD="$STUB"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

echo "the model knob — self-play has its own, and never the user's:"
knob() {  # <selfplay flag> [env pairs...] -> the --model value of the built cmd
  local sp="$1"; shift
  env "$@" "$PY" - "$REPO/lib" "$sp" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import chess_mover
cmd = chess_mover.Mover._claude_cmd("low", selfplay=(sys.argv[2] == "yes"))
print(cmd[cmd.index("--model") + 1])
PYEOF
}
check_eq "a self-play invocation defaults to sonnet" "$(knob yes)" "sonnet"
check_eq "DESKCRAB_CHESS_SELFPLAY_MODEL is honoured" \
    "$(knob yes DESKCRAB_CHESS_SELFPLAY_MODEL=haiku)" "haiku"
check_eq "the real-game knob does NOT reach a self-play invocation" \
    "$(knob yes DESKCRAB_CHESS_MOVER_MODEL=fable CLAUDE_MODEL=fable)" "sonnet"
check_eq "a real game still follows the mover knob" \
    "$(knob no DESKCRAB_CHESS_MOVER_MODEL=fable)" "fable"

check_eq "a selfplay- game id is self-play" "$("$PY" - "$REPO/lib" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1])
import chess_mover
print(chess_mover.is_selfplay({"gid": "selfplay-007", "opponent": "selfplay"}))
PYEOF
)" "True"
check_eq "a game against a person is not" "$("$PY" - "$REPO/lib" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1])
import chess_mover
print(chess_mover.is_selfplay({"gid": "browser-014", "opponent": "a friend"}))
PYEOF
)" "False"

echo
echo "the driver stops cleanly at the nightly move budget:"
OUT="$(DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES=5 \
       "$PY" "$REPO/lib/chess_selfplay.py" --budget 120 --games 4 \
       --deadline "$NEAR_WALL" 2>&1)"
STATUS_LINE="$(grep '^STATUS ' <<<"$OUT" | tail -n1)"
contains "$STATUS_LINE" '"status": "budget-spent"' \
    && ok "the chunk ends on budget-spent" \
    || fail "STATUS line: $STATUS_LINE"
check "the counter holds exactly the budget's worth of calls" \
    [ "$(grep -c . "$COUNTER" 2>/dev/null)" -eq 5 ]
check "the stub was called exactly that many times" \
    [ "$(grep -c . "$CALLS" 2>/dev/null)" -eq 5 ]
check "the game the grind played is a selfplay- game" \
    bash -c 'ls "$1"/games/selfplay-*.json >/dev/null 2>&1' _ "$DESKCRAB_CHESS_DIR"

echo
echo "the mover backstop binds whatever is driving, and spares a real game:"
: > "$CALLS"
# The counter already sits at the cap from the run above (5/5 with the same
# budget). A self-play position must be refused without the stub being
# called; a real-game position on the same mover must still answer.
BACK="$(DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES=5 "$PY" - "$REPO/lib" <<'PYEOF'
import sys, time
sys.path.insert(0, sys.argv[1])
import chess
import chess_mover

posted = []
def play(job, move):
    posted.append((job["gid"], move.uci()))
    return True

m = chess_mover.Mover(play, log=lambda *a: None, alert=lambda *a: None)
fen = chess.Board().fen()
def job(gid, opp):
    return {"key": gid, "gid": gid, "ply": 0, "fen": fen, "side": "white",
            "opponent": opp, "history": "", "note": "", "effort": "",
            "t0": time.time()}
m.submit(job("selfplay-001", "selfplay"))
m.wait_idle(timeout=30)
n, stalled, why = m.failure_state("selfplay-001")
print("selfplay-why:", why)
m.submit(job("opponent-001", "a friend"))
m.wait_idle(timeout=30)
print("posted:", posted)
PYEOF
)"
contains "$BACK" "selfplay-why: selfplay nightly move budget spent (5/5)" \
    && ok "the self-play position is refused with the budget named" \
    || fail "backstop output: $BACK"
contains "$BACK" "posted: [('opponent-001'" \
    && ok "the real game's position was answered on the same mover" \
    || fail "real game went unanswered: $BACK"
check_eq "the refused self-play position never reached the stub" \
    "$(grep -c . "$CALLS")" "1"
check "and the counter did not move for it" \
    [ "$(grep -c . "$COUNTER")" -eq 5 ]

echo
echo "the games cap creates nothing once the night is full:"
GAMES2="$SANDBOX/chess2"
mkdir -p "$GAMES2"
OUT2="$(DESKCRAB_CHESS_DIR="$GAMES2" \
        "$PY" "$REPO/lib/chess_selfplay.py" --budget 60 --games 0 \
        --deadline "$NEAR_WALL" 2>&1)"
contains "$(grep '^STATUS ' <<<"$OUT2" | tail -n1)" '"status": "games-cap"' \
    && ok "the chunk ends on games-cap" \
    || fail "STATUS line: $(grep '^STATUS ' <<<"$OUT2" | tail -n1)"
refute "no game was created" \
    bash -c 'ls "$1"/games/selfplay-*.json >/dev/null 2>&1' _ "$GAMES2"

echo
echo "the budget window is the night, not the calendar day:"
NK="$("$PY" - "$REPO/lib" <<'PYEOF'
import sys, time
sys.path.insert(0, sys.argv[1])
import chess_mover as cm

def at(y, mo, d, h, mi):
    return time.mktime((y, mo, d, h, mi, 0, 0, 1, -1))

print("pre-midnight:", cm.night_key(at(2026, 8, 14, 23, 30)))
print("post-midnight:", cm.night_key(at(2026, 8, 15, 0, 30)))
print("small-hours:", cm.night_key(at(2026, 8, 15, 4, 0)))
print("next-afternoon:", cm.night_key(at(2026, 8, 15, 13, 0)))
PYEOF
)"
contains "$NK" "pre-midnight: 20260814" \
    && contains "$NK" "post-midnight: 20260814" \
    && contains "$NK" "small-hours: 20260814" \
    && ok "23:30, 00:30 and 04:00 across one midnight share the night key" \
    || fail "night keys: $NK"
contains "$NK" "next-afternoon: 20260815" \
    && ok "the next afternoon opens the next night's key" \
    || fail "night keys: $NK"

GT="$("$PY" - "$REPO/lib" <<'PYEOF'
import sys
from datetime import datetime
sys.path.insert(0, sys.argv[1])
import chess_selfplay as sp

tz = datetime.now().astimezone().tzinfo
g = {"created": datetime(2026, 8, 14, 23, 0, tzinfo=tz).isoformat()}
print("same-night:", sp.created_tonight(
    g, now=datetime(2026, 8, 15, 1, 0, tzinfo=tz)))
print("next-night:", sp.created_tonight(
    g, now=datetime(2026, 8, 15, 13, 0, tzinfo=tz)))
PYEOF
)"
contains "$GT" "same-night: True" \
    && contains "$GT" "next-night: False" \
    && ok "a game created before midnight still counts against the same night's games cap" \
    || fail "created_tonight: $GT"

echo
echo "a daytime start is refused, and the night path keeps its walls:"
DL="$("$PY" - "$REPO/lib" <<'PYEOF'
import sys, time
sys.path.insert(0, sys.argv[1])
import chess_selfplay as sp

def at(y, mo, d, h, mi):
    return time.mktime((y, mo, d, h, mi, 0, 0, 1, -1))

wall = "07:00"
print("daytime:", sp.resolve_deadline(at(2026, 8, 14, 14, 0), wall, False))
print("daytime--day:",
      sp.resolve_deadline(at(2026, 8, 14, 14, 0), wall, True)
      == at(2026, 8, 15, 7, 0))
print("evening:",
      sp.resolve_deadline(at(2026, 8, 14, 22, 0), wall, False)
      == at(2026, 8, 15, 7, 0))
print("small-hours:",
      sp.resolve_deadline(at(2026, 8, 15, 2, 0), wall, False)
      == at(2026, 8, 15, 7, 0))
print("just-past:",
      sp.resolve_deadline(at(2026, 8, 15, 7, 30), wall, False)
      == at(2026, 8, 15, 7, 0))
PYEOF
)"
contains "$DL" "daytime: None" \
    && ok "a 14:00 start against a 07:00 wall is refused (not aimed at tomorrow)" \
    || fail "resolve_deadline: $DL"
contains "$DL" "daytime--day: True" \
    && ok "--day makes the same start a deliberate chunk with tomorrow's wall" \
    || fail "resolve_deadline: $DL"
contains "$DL" "evening: True" && contains "$DL" "small-hours: True" \
    && contains "$DL" "just-past: True" \
    && ok "evening, small-hours and just-past-the-wall starts keep their old walls" \
    || fail "resolve_deadline: $DL"

# End to end when the clock allows it: a wall 2 h behind us makes the start
# daytime everywhere except the first two hours after midnight, where no
# HH:MM can sit 1-12 h in the past (the unit cases above still cover it).
if [ "$(date +%H)" -ge 2 ] 2>/dev/null; then
  GAMES3="$SANDBOX/chess3"
  mkdir -p "$GAMES3"
  PAST_WALL="$(date -d '2 hours ago' +%H:%M)"
  OUT3="$(DESKCRAB_CHESS_DIR="$GAMES3" \
          "$PY" "$REPO/lib/chess_selfplay.py" --budget 60 --games 0 \
          --deadline "$PAST_WALL" 2>&1)"; RC3=$?
  contains "$(grep '^STATUS ' <<<"$OUT3" | tail -n1)" '"status": "daytime"' \
      && ok "the driver refuses the daytime start with status daytime" \
      || fail "STATUS line: $(grep '^STATUS ' <<<"$OUT3" | tail -n1)"
  check "and exits non-zero" [ "$RC3" -ne 0 ]
  contains "$OUT3" "Pass --day" \
      && ok "the refusal names the --day flag" \
      || fail "refusal output: $OUT3"
  OUT4="$(DESKCRAB_CHESS_DIR="$GAMES3" \
          "$PY" "$REPO/lib/chess_selfplay.py" --budget 60 --games 0 \
          --deadline "$PAST_WALL" --day 2>&1)"
  contains "$(grep '^STATUS ' <<<"$OUT4" | tail -n1)" '"status": "games-cap"' \
      && ok "with --day the same invocation runs (and stops on its games cap)" \
      || fail "STATUS line: $(grep '^STATUS ' <<<"$OUT4" | tail -n1)"
else
  echo "note: before 02:00 no HH:MM wall sits 1-12 h in the past —" \
       "end-to-end daytime case skipped, unit cases above cover it"
fi

echo
echo "the benchmark: a self-play job's model is allowlist-bound (rule 15):"
JM="$("$PY" - "$REPO/lib" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import os
import chess_mover as cm

said = []
def alert(msg): said.append(msg)

job = lambda m: {"gid": "selfplay-bench-001", "model": m}
print("haiku:", cm.selfplay_job_model(job("haiku"), alert))
print("sonnet:", cm.selfplay_job_model(job("sonnet"), alert))
print("fable-default:", cm.selfplay_job_model(job("fable"), alert))
print("codex-default:", cm.selfplay_job_model(job("sol"), alert))
os.environ["DESKCRAB_CHESS_SELFPLAY_MODELS"] = "haiku sonnet fable"
print("fable-widened:", cm.selfplay_job_model(job("fable"), alert))
print("codex-widened:", cm.selfplay_job_model(job("gpt-5.6-sol"), alert))
print("none:", cm.selfplay_job_model({"gid": "selfplay-bench-001"}, alert))
print("alerts:", len(said))
PYEOF
)"
contains "$JM" "haiku: haiku" && contains "$JM" "sonnet: sonnet" \
    && ok "an allowlisted Claude model rides the job" \
    || fail "job model: $JM"
contains "$JM" "fable-default: None" \
    && ok "an unlisted model is refused to the self-play default" \
    || fail "job model: $JM"
contains "$JM" "fable-widened: fable" \
    && ok "the operator can widen the allowlist deliberately, per run" \
    || fail "job model: $JM"
contains "$JM" "codex-default: None" && contains "$JM" "codex-widened: None" \
    && ok "a codex-family name is refused unconditionally — the conversation engine is not for grinding" \
    || fail "job model: $JM"
contains "$JM" "none: None" && contains "$JM" "alerts: 3" \
    && ok "no model field is quiet; every refusal was loud" \
    || fail "job model: $JM"

MODEL_CMD="$(env -u DESKCRAB_CHESS_MOVER_CMD "$PY" - "$REPO/lib" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import chess_mover as cm
m = cm.Mover(lambda j, mv: True, log=lambda *a: None, alert=lambda *a: None)
for label, cmd, env in m._attempts("low", True, "haiku"):
    print("with-job-model:", cmd[cmd.index("--model") + 1]); break
for label, cmd, env in m._attempts("low", True, None):
    print("without:", cmd[cmd.index("--model") + 1]); break
PYEOF
)"
contains "$MODEL_CMD" "with-job-model: haiku" \
    && contains "$MODEL_CMD" "without: sonnet" \
    && ok "the job's model reaches the built invocation; its absence keeps rule 2's default" \
    || fail "attempts: $MODEL_CMD"

echo
echo "the benchmark plays its plan with real clocks, resumes, records once:"
BDIR="$SANDBOX/chessb"
mkdir -p "$BDIR/selfplay" "$BDIR/games"
BPLAN="$BDIR/selfplay/bench-t1.json"
cat > "$BPLAN" <<'PLANEOF'
{"run": "t1",
 "probe": {"configs": [["haiku", "low"]],
           "positions": ["rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"],
           "rounds": 1},
 "configs": {"a": {"model": "haiku", "quiet": "low", "sharp": "low"},
             "b": {"model": "sonnet", "quiet": "low", "sharp": "medium"}},
 "games": [{"id": "selfplay-bencht1-001", "control": "1+0", "white": "a", "black": "b"},
           {"id": "selfplay-bencht1-002", "control": "1+0", "white": "b", "black": "a"}]}
PLANEOF
BCALLS="$SANDBOX/stub-calls-bench"
: > "$BCALLS"
sed "s|$CALLS|$BCALLS|" "$STUB" > "$SANDBOX/stub-mover-bench"
chmod +x "$SANDBOX/stub-mover-bench"
OUTB="$(DESKCRAB_CHESS_DIR="$BDIR" DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES=600 \
        DESKCRAB_CHESS_MOVER_CMD="$SANDBOX/stub-mover-bench" \
        "$PY" "$REPO/lib/chess_selfplay.py" --bench "$BPLAN" --budget 300 \
        --games 10 --deadline "$NEAR_WALL" 2>&1)"
SB="$(grep '^STATUS ' <<<"$OUTB" | tail -n1)"
contains "$SB" '"status": "bench-done"' \
    && contains "$SB" '"bench_recorded": 2' \
    && contains "$SB" '"bench_total": 2' \
    && ok "the chunk plays the whole plan and says bench-done 2/2" \
    || fail "STATUS line: $SB"
BLEDGER="$BDIR/selfplay/bench-t1.jsonl"
check_eq "the ledger holds exactly one line per finished game" \
    "$(sandbox_count_in '"game"' "$BLEDGER")" "2"
GB="$("$PY" - "$BDIR" <<'PYEOF'
import json, sys
d = sys.argv[1]
g1 = json.load(open(d + "/games/selfplay-bencht1-001.json"))
g2 = json.load(open(d + "/games/selfplay-bencht1-002.json"))
print("controls:", g1["time_control"]["name"], g2["time_control"]["name"])
print("clocks:", "clock" in g1, "clock" in g2)
print("colours:", g1["bench"]["white"], g1["bench"]["black"],
      g2["bench"]["white"], g2["bench"]["black"])
rows = g1["bench"]["rows"] + g2["bench"]["rows"]
print("rows:", len(rows) > 0,
      all(r[1] in ("white", "black")
          and r[2] in ("book", "reflex", "model") for r in rows))
led = [json.loads(x) for x in open(d + "/selfplay/bench-t1.jsonl")]
games = [e for e in led if "game" in e]
print("results:", all(e["result"] in ("1-0", "0-1", "1/2-1/2")
                      for e in games))
print("sides:", all("sides" in e and "white" in e["sides"] for e in games))
PYEOF
)"
contains "$GB" "controls: 1+0 1+0" && contains "$GB" "clocks: True True" \
    && ok "both games carry the scheduled control and a stored clock" \
    || fail "bench games: $GB"
contains "$GB" "colours: a b b a" \
    && ok "the matchup rotated colours across its two games" \
    || fail "bench games: $GB"
contains "$GB" "rows: True True" \
    && ok "every move landed a bench row naming side and source" \
    || fail "bench games: $GB"
contains "$GB" "results: True" && contains "$GB" "sides: True" \
    && ok "the ledger lines carry results and per-side summaries" \
    || fail "bench ledger: $GB"

NCALLS="$(grep -c . "$BCALLS")"
OUTB2="$(DESKCRAB_CHESS_DIR="$BDIR" DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES=600 \
         DESKCRAB_CHESS_MOVER_CMD="$SANDBOX/stub-mover-bench" \
         "$PY" "$REPO/lib/chess_selfplay.py" --bench "$BPLAN" --budget 60 \
         --games 10 --deadline "$NEAR_WALL" 2>&1)"
contains "$(grep '^STATUS ' <<<"$OUTB2" | tail -n1)" '"status": "bench-done"' \
    && ok "a re-run of a finished plan says bench-done at once" \
    || fail "STATUS line: $(grep '^STATUS ' <<<"$OUTB2" | tail -n1)"
check_eq "and replays nothing: not one new model call" \
    "$(grep -c . "$BCALLS")" "$NCALLS"
check_eq "and appends nothing: the ledger still holds one line per game" \
    "$(sandbox_count_in '"game"' "$BLEDGER")" "2"

echo
echo "a clock that ran out is a recorded flag, never a model call:"
FDIR="$SANDBOX/chessf"
mkdir -p "$FDIR/selfplay" "$FDIR/games"
FPLAN="$FDIR/selfplay/bench-t2.json"
"$PY" - "$FDIR" <<'PYEOF'
import json, sys, time
d = sys.argv[1]
plan = {"run": "t2",
        "configs": {"a": {"model": "haiku", "quiet": "low", "sharp": "low"},
                    "b": {"model": "sonnet", "quiet": "low",
                          "sharp": "medium"}},
        "games": [{"id": "selfplay-bencht2-001", "control": "1+0",
                   "white": "a", "black": "b"}]}
json.dump(plan, open(d + "/selfplay/bench-t2.json", "w"))
g = {"id": "selfplay-bencht2-001", "opponent": "selfplay",
     "my_side": "white", "moves": ["e2e4", "e7e5", "g1f3", "b8c6"],
     "resigned_by": None, "draw_agreed": False, "engine_level": None,
     "created": "2026-01-01T00:00:00+00:00",
     "time_control": {"name": "1+0", "speed": "bullet", "base_ms": 60000,
                      "inc_ms": 0},
     "clock": {"white_ms": 1000, "black_ms": 60000,
               "turn_started": time.time() - 30},
     "bench": {"control": "1+0", "white": "a", "black": "b", "rows": []}}
json.dump(g, open(d + "/games/selfplay-bencht2-001.json", "w"))
PYEOF
FCALLS="$SANDBOX/stub-calls-flag"
: > "$FCALLS"
sed "s|$CALLS|$FCALLS|" "$STUB" > "$SANDBOX/stub-mover-flag"
chmod +x "$SANDBOX/stub-mover-flag"
OUTF="$(DESKCRAB_CHESS_DIR="$FDIR" DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES=600 \
        DESKCRAB_CHESS_MOVER_CMD="$SANDBOX/stub-mover-flag" \
        "$PY" "$REPO/lib/chess_selfplay.py" --bench "$FPLAN" --budget 60 \
        --games 10 --deadline "$NEAR_WALL" 2>&1)"
contains "$(grep '^STATUS ' <<<"$OUTF" | tail -n1)" '"status": "bench-done"' \
    && ok "the flagged game is finished business to the driver" \
    || fail "STATUS line: $(grep '^STATUS ' <<<"$OUTF" | tail -n1)"
check_eq "no model call was made for it" "$(sandbox_count_in . "$FCALLS")" "0"
FLINE="$(cat "$FDIR/selfplay/bench-t2.jsonl")"
contains "$FLINE" '"flagged": "white"' \
    && contains "$FLINE" '"result": "0-1"' \
    && ok "the ledger names the fallen flag and the timed loss" \
    || fail "flag ledger: $FLINE"
grep -q '"flag_fell": "white"' "$FDIR/games/selfplay-bencht2-001.json" \
    && ok "the flag is recorded onto the game file for every later reader" \
    || fail "game file: $(cat "$FDIR/games/selfplay-bencht2-001.json")"

echo
echo "the probe prices a configuration's bare call, budget-counted:"
PCOUNTER="$BDIR/selfplay/model-calls-$(date -d '12 hours ago' +%Y%m%d).log"
NPROBE_BEFORE="$(sandbox_count_in . "$PCOUNTER")"
OUTP="$(DESKCRAB_CHESS_DIR="$BDIR" DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES=600 \
        DESKCRAB_CHESS_MOVER_CMD="$SANDBOX/stub-mover-bench" \
        "$PY" "$REPO/lib/chess_selfplay.py" --bench-probe "$BPLAN" \
        --deadline "$NEAR_WALL" 2>&1)"
contains "$(grep '^STATUS ' <<<"$OUTP" | tail -n1)" '"status": "probe-done"' \
    && ok "the probe chunk ends on probe-done" \
    || fail "STATUS line: $(grep '^STATUS ' <<<"$OUTP" | tail -n1)"
PROBE_LINE="$(grep '"probe"' "$BLEDGER" | tail -n1)"
contains "$PROBE_LINE" '"probe": "haiku"' \
    && contains "$PROBE_LINE" '"ok": true' \
    && contains "$PROBE_LINE" '"secs"' \
    && ok "the probe line carries the model, the seconds, and the verdict" \
    || fail "probe line: $PROBE_LINE"
check "the probe was charged to the nightly counter" \
    [ "$(grep -c . "$PCOUNTER" 2>/dev/null)" -gt "$NPROBE_BEFORE" ]

echo
echo "the report renders what was measured:"
REPORT="$(DESKCRAB_CHESS_DIR="$BDIR" \
          "$PY" "$REPO/lib/chess_selfplay.py" --bench-report "$BPLAN" 2>&1)"
contains "$REPORT" "## 1+0" \
    && contains "$REPORT" "| a |" && contains "$REPORT" "| b |" \
    && ok "the per-control table names each configuration" \
    || fail "report: $REPORT"
contains "$REPORT" "| haiku | low |" \
    && ok "the probe table prices the probed configuration" \
    || fail "report: $REPORT"
