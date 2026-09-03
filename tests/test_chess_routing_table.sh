#!/bin/bash
# The user's decided chess routing table, resolved through the real bridge
# code path with every model backend stubbed — specs/chessweb.md rule 16b,
# eng record redo-the-chess-benchmark-across-full-model-effor.
# Run: bash tests/test_chess_routing_table.sh
#
# The contract under test, all of it local and fully stubbed (no live model
# call of any kind, and the real Spark backend is NEVER invoked — the only
# executions are sandbox-local stub scripts):
#
#   1. Every standard timer resolves the user's final table (2026-09-01)
#      through the bridge's own resolution path (chess_cli.make_time_control
#      -> chessweb.mover_model_for + chess_effort.pair_for, the exact calls
#      answer_position/move_effort make): bullet Sonnet low/low, blitz
#      gpt-5.3-codex-spark low/low, rapid Opus low/low, untimed Fable
#      low/medium.
#   2. A routed model is exact. A cooling codex login yields NO attempt at
#      all; a stub-refused routed codex model leaves the move unplayed with
#      the failure exposed; neither ever substitutes a Claude call.
#   3. Same-model Claude account rotation still succeeds: a routed Claude
#      model refused on account 1 is answered on account 2 with the SAME
#      model on both argvs.
#   4. The honest wording stands pinned: the bullet verdict carries the
#      "no MEASURED configuration" qualifier and the blitz Spark cell is
#      named an explicit USER-SELECTED live-play trial in code, spec, and
#      report.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
PY="$VENV/bin/python"
if [ ! -x "$PY" ]; then
    echo "SKIP: no chess venv at $VENV — the mover needs python-chess"
    exit 0
fi

echo "the routing table, resolved through the bridge's own path:"
RES="$("$PY" -B - <<PYEOF
import sys
sys.path.insert(0, "$REPO/lib")
import chess_cli, chess_effort, chessweb
for name in ("1+0", "2+1", "3+2", "5+0", "10+0", "15+10"):
    tc, clock = chess_cli.make_time_control(name)
    g = {"time_control": tc, "clock": clock}
    model = chessweb.mover_model_for(g)
    q, s = chess_effort.pair_for(tc["speed"], tc["name"])
    print("%s: %s %s/%s" % (name, model, q, s))
model = chessweb.mover_model_for({})
q, s = chess_effort.pair_for(None)
print("untimed: %s %s/%s" % (model, q, s))
PYEOF
)"
echo "$RES" | sed 's/^/    /'
contains "$RES" "1+0: sonnet low/low" \
    && ok "1+0 resolves Sonnet low/low" || fail "1+0 resolution" "$(printf '%s\n' "$RES" | grep '^1+0:')"
contains "$RES" "2+1: sonnet low/low" \
    && ok "2+1 resolves Sonnet low/low" || fail "2+1 resolution" "$(printf '%s\n' "$RES" | grep '^2+1:')"
contains "$RES" "3+2: gpt-5.3-codex-spark low/low" \
    && ok "3+2 resolves the user-selected Spark trial at low/low" \
    || fail "3+2 resolution" "$(printf '%s\n' "$RES" | grep '^3+2:')"
contains "$RES" "5+0: gpt-5.3-codex-spark low/low" \
    && ok "5+0 resolves the user-selected Spark trial at low/low" \
    || fail "5+0 resolution" "$(printf '%s\n' "$RES" | grep '^5+0:')"
contains "$RES" "10+0: opus low/low" \
    && ok "10+0 resolves Opus low/low" || fail "10+0 resolution" "$(printf '%s\n' "$RES" | grep '^10+0:')"
contains "$RES" "15+10: opus low/low" \
    && ok "15+10 resolves Opus low/low" || fail "15+10 resolution" "$(printf '%s\n' "$RES" | grep '^15+10:')"
contains "$RES" "untimed: fable low/medium" \
    && ok "untimed resolves the configured Fable model at low/medium" \
    || fail "untimed resolution" "$(printf '%s\n' "$RES" | grep '^untimed:')"

echo
echo "a routed model is exact — unavailable means unplayed, never substituted:"
CODEX_STUB="$T/bin/codex-refusing"
CODEX_WITNESS="$T/witness/codex-calls"
cat > "$CODEX_STUB" <<STUB
#!/bin/bash
cat > /dev/null
printf 'invoked\t%s\n' "\$*" >> "$CODEX_WITNESS"
echo '{"type":"error","message":"You have hit your usage limit. Try again later."}' >&2
exit 1
STUB
chmod +x "$CODEX_STUB"

CLAUDE_STUB="$T/bin/claude-account"
CLAUDE_WITNESS="$T/witness/claude-calls"
cat > "$CLAUDE_STUB" <<STUB
#!/bin/bash
cat > /dev/null
printf '%s\t%s\n' "\${CLAUDE_CONFIG_DIR:-none}" "\$*" >> "$CLAUDE_WITNESS"
case "\${CLAUDE_CONFIG_DIR:-}" in
  */acct2) echo "e2e4"; exit 0 ;;
  *) echo "You've hit your session limit." >&2; exit 1 ;;
esac
STUB
chmod +x "$CLAUDE_STUB"
mkdir -p "$T/acct2"

PYOUT="$(env CODEX_BIN="$CODEX_STUB" CLAUDE_BIN="$CLAUDE_STUB" \
    CLAUDE_FALLBACK_CONFIG_DIR="$T/acct2" \
    DESKCRAB_CHESS_DIR="$T/chess-games" \
    DESKCRAB_CHESS_MEMORY_PROMPT=0 DESKCRAB_CHESS_SIMILAR=0 \
    DESKCRAB_CODEX_STATE="$T/codex-state-clean" \
    "$PY" -B - <<PYEOF
import os, sys, time
sys.path.insert(0, "$REPO/lib")
import chess, chess_effort, chess_mover

alerts, played = [], []
m = chess_mover.Mover(lambda job, mv: played.append((job["gid"], mv.uci())) or True,
                      log=lambda *a, **k: None,
                      metric=lambda stage, detail="": None,
                      alert=lambda msg: alerts.append(msg))

FEN = chess.STARTING_FEN
def job(gid, model):
    return {"key": gid, "gid": gid, "ply": 2, "fen": FEN, "side": "white",
            "opponent": "tester", "history": "(none)", "model": model,
            "effort": "low", "t0": time.time()}

blitz_model = chess_effort.model_for("blitz", "3+2")
bullet_model = chess_effort.model_for("bullet", "1+0")
print("blitz-routed-model:", blitz_model)
print("bullet-routed-model:", bullet_model)

# 1. COOLING: the routed blitz model's login is cooling — zero attempts of
#    any kind, the refusal named out loud, the move unplayed.
cool = "$T/codex-state-cooling"
with open(cool, "w") as fh:
    fh.write("blocked-until\t%d\tusage limit\n" % (int(time.time()) + 900))
os.environ["DESKCRAB_CODEX_STATE"] = cool
outcome, why = m._answer(job("cool-1", blitz_model))
print("cooling-outcome:", outcome)
print("cooling-alerted:", any("cooling" in a and "no substitute" in a
                              for a in alerts))
print("cooling-played:", len(played))

# 2. REFUSAL: the login answers but the routed model refuses over usage —
#    exactly one local stub attempt, the failure exposed, still unplayed.
os.environ["DESKCRAB_CODEX_STATE"] = "$T/codex-state-clean"
outcome, why = m._answer(job("refuse-1", blitz_model))
print("refusal-outcome:", outcome)
print("refusal-why-visible:", "usage limit" in (why or "").lower())
print("refusal-alerted:", any("refuse-1" in a and "every attempt failed" in a
                              for a in alerts))
print("refusal-played:", len(played))

# 3. ROTATION: the routed bullet model is Claude-family; account 1 refuses,
#    account 2 answers — the move lands, the model never changes.
outcome, why = m._answer(job("rotate-1", bullet_model))
print("rotation-outcome:", outcome)
print("rotation-played:", played)
PYEOF
)"
echo "$PYOUT" | sed 's/^/    /'

contains "$PYOUT" "blitz-routed-model: gpt-5.3-codex-spark" \
    && ok "the blitz offer under test is the live table's own Spark slug" \
    || fail "blitz routed model" "$(printf '%s\n' "$PYOUT" | grep blitz-routed-model)"
contains "$PYOUT" "bullet-routed-model: sonnet" \
    && ok "the bullet offer under test is the live table's own Sonnet" \
    || fail "bullet routed model" "$(printf '%s\n' "$PYOUT" | grep bullet-routed-model)"

echo
echo "cooling: no attempt, no substitute, failure exposed:"
contains "$PYOUT" "cooling-outcome: failed" \
    && ok "the move is unplayed — the round is a visible failure" \
    || fail "cooling outcome" "$(printf '%s\n' "$PYOUT" | grep cooling-outcome)"
contains "$PYOUT" "cooling-alerted: True" \
    && ok "the cooling refusal is named out loud with no substitute engine" \
    || fail "cooling alert" "$(printf '%s\n' "$PYOUT" | grep cooling-alerted)"
contains "$PYOUT" "cooling-played: 0" \
    && ok "nothing was posted to the board" || fail "cooling played" "$(printf '%s\n' "$PYOUT" | grep cooling-played)"

echo
echo "stub refusal: one local attempt, unplayed, exposed, zero Claude calls:"
contains "$PYOUT" "refusal-outcome: failed" \
    && ok "the refused routed model leaves the move unplayed" \
    || fail "refusal outcome" "$(printf '%s\n' "$PYOUT" | grep refusal-outcome)"
contains "$PYOUT" "refusal-why-visible: True" \
    && ok "the failure cause carries the refusal text" \
    || fail "refusal why" "$(printf '%s\n' "$PYOUT" | grep refusal-why)"
contains "$PYOUT" "refusal-alerted: True" \
    && ok "the failure is exposed through the mover's alert machinery" \
    || fail "refusal alert" "$(printf '%s\n' "$PYOUT" | grep refusal-alerted)"
contains "$PYOUT" "refusal-played: 0" \
    && ok "still nothing posted to the board" || fail "refusal played" "$(printf '%s\n' "$PYOUT" | grep refusal-played)"

echo
echo "same-model account rotation still succeeds:"
contains "$PYOUT" "rotation-outcome: posted" \
    && ok "account 2 answered after account 1 refused — the move landed" \
    || fail "rotation outcome" "$(printf '%s\n' "$PYOUT" | grep rotation-outcome)"
contains "$PYOUT" "rotation-played: [('rotate-1', 'e2e4')]" \
    && ok "the posted move is the stub's answer, once" \
    || fail "rotation played" "$(printf '%s\n' "$PYOUT" | grep rotation-played)"
check_eq "the Claude stub ran exactly twice (both rotation accounts)" \
    "$(sandbox_count_in . "$CLAUDE_WITNESS")" "2"
check_eq "both Claude attempts carried the routed model, never a substitute" \
    "$(sandbox_count_in "--model sonnet" "$CLAUDE_WITNESS")" "2"
check_eq "both Claude attempts carried the routed low effort" \
    "$(sandbox_count_in "--effort low" "$CLAUDE_WITNESS")" "2"

echo
echo "Spark was never really called — every execution was a sandbox stub:"
check_eq "the codex stub ran exactly once (the refusal case; cooling ran none)" \
    "$(sandbox_count_in invoked "$CODEX_WITNESS")" "1"
check_eq "that one stub invocation carried the exact routed slug" \
    "$(sandbox_count_in "-m gpt-5.3-codex-spark" "$CODEX_WITNESS")" "1"
check_eq "no Claude invocation ever named the spark slug (no cross-engine walk)" \
    "$(sandbox_count_in spark "$CLAUDE_WITNESS")" "0"
echo "    real-spark-invocations: 0 (CODEX_BIN and CLAUDE_BIN are sandbox stubs;" \
     "the sandbox PATH holds stubs first and no network client exists here)"

echo
echo "the honest wording stands pinned (rule 20a honesty, the 2026-09-01 trial):"
check "chess_effort.py keeps the bullet MEASURED qualifier" \
    grep -q "no MEASURED configuration" "$REPO/lib/chess_effort.py"
check "chess_effort.py names blitz an explicit USER-SELECTED live-play trial" \
    grep -q "USER-SELECTED live-play trial" "$REPO/lib/chess_effort.py"
check "chess_effort.py states the benchmark found spark-low too slow for 10+0" \
    grep -q "too slow for 10+0" "$REPO/lib/chess_effort.py"
check_eq "no absolute physically-finishes claim in chess_effort.py" \
    "$(sandbox_count_in "physically finishes" "$REPO/lib/chess_effort.py")" "0"
check_eq "no unqualified 'no configuration ... finishes' claim either" \
    "$(grep -ci "no configuration[^.]*finishes" "$REPO/lib/chess_effort.py")" "0"
check "the spec names the blitz trial the same way" \
    grep -q "USER-SELECTED live-play trial" "$REPO/specs/chessweb.md"
check "the report names the blitz trial the same way" \
    grep -q "USER-SELECTED live-play trial" "$REPO/docs/chess-bench-matrix-2026-08.md"
check "the spec's bullet gate claims only what was measured" \
    grep -q "no MEASURED configuration finished bullet reliably" \
    "$REPO/specs/chessweb.md"
