#!/bin/bash
# The user's decided chess routing table, resolved through the real bridge
# code path with every model backend stubbed — specs/chessweb.md rules 16b
# and 16h.
# Run: bash tests/test_chess_routing_table.sh
#
# The contract under test, all of it local and fully stubbed (no live model
# call of any kind, no network beyond a doomed loopback connect — the only
# executions are sandbox-local stub scripts):
#
#   1. Every standard timer resolves the user's 2026-09-17 table through
#      the bridge's own resolution path (chess_cli.make_time_control ->
#      chessweb.mover_model_for + chess_effort.pair_for, the exact calls
#      answer_position/move_effort make): every timed control except 15+10
#      rides TypeSafe's jev-latest; 15+10 keeps the measured rapid winner
#      (Opus low/low); untimed keeps Fable low/medium. The 10+5 route is
#      the exact-control door (CONTROL_MODELS) splitting rapid.
#   2. A routed model is exact. A routed jev offer with no TYPESAFE_API_KEY
#      yields NO attempt at all with the refusal named out loud; a routed
#      jev offer whose endpoint is unreachable makes exactly one typesafe
#      attempt and leaves the move unplayed with the failure exposed;
#      neither ever substitutes a Claude or codex call.
#   3. Same-model Claude account rotation still succeeds: the routed 15+10
#      Opus refused on account 1 is answered on account 2 with the SAME
#      model on both argvs.
#   4. The honest wording stands pinned: Jev is named UNMEASURED on the
#      clock matrix in code and spec, and the spec's bullet gate still
#      claims only what was measured.
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
for name in ("1+0", "2+1", "3+2", "5+0", "10+5", "15+10"):
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
contains "$RES" "1+0: jev-latest low/low" \
    && ok "1+0 resolves jev-latest" || fail "1+0 resolution" "$(printf '%s\n' "$RES" | grep '^1+0:')"
contains "$RES" "2+1: jev-latest low/low" \
    && ok "2+1 resolves jev-latest" || fail "2+1 resolution" "$(printf '%s\n' "$RES" | grep '^2+1:')"
contains "$RES" "3+2: jev-latest low/low" \
    && ok "3+2 resolves jev-latest" \
    || fail "3+2 resolution" "$(printf '%s\n' "$RES" | grep '^3+2:')"
contains "$RES" "5+0: jev-latest low/low" \
    && ok "5+0 resolves jev-latest" \
    || fail "5+0 resolution" "$(printf '%s\n' "$RES" | grep '^5+0:')"
contains "$RES" "10+5: jev-latest low/low" \
    && ok "10+5 resolves jev-latest through the exact-control door" \
    || fail "10+5 resolution" "$(printf '%s\n' "$RES" | grep '^10+5:')"
contains "$RES" "15+10: claude-opus-5-5 low/low" \
    && ok "15+10 keeps the measured rapid winner, Opus low/low" \
    || fail "15+10 resolution" "$(printf '%s\n' "$RES" | grep '^15+10:')"
contains "$RES" "untimed: fable low/medium" \
    && ok "untimed resolves the configured Fable model at low/medium" \
    || fail "untimed resolution" "$(printf '%s\n' "$RES" | grep '^untimed:')"

echo
echo "a routed model is exact — unavailable means unplayed, never substituted:"
CODEX_STUB="$T/bin/codex-witness"
CODEX_WITNESS="$T/witness/codex-calls"
cat > "$CODEX_STUB" <<STUB
#!/bin/bash
cat > /dev/null
printf 'invoked\t%s\n' "\$*" >> "$CODEX_WITNESS"
echo "e2e4"
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
    TYPESAFE_HTTP_TIMEOUT=2 \
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
rapid_model = chess_effort.model_for("rapid", "15+10")
print("blitz-routed-model:", blitz_model)
print("rapid-routed-model:", rapid_model)

# 1. NO KEY: the routed jev offer without TYPESAFE_API_KEY — zero attempts
#    of any kind, the refusal named out loud, the move unplayed.
os.environ.pop("TYPESAFE_API_KEY", None)
outcome, why = m._answer(job("nokey-1", blitz_model))
print("nokey-outcome:", outcome)
print("nokey-alerted:", any("TYPESAFE_API_KEY" in a and "no substitute" in a
                            for a in alerts))
print("nokey-played:", len(played))

# 2. DEAD ENDPOINT: the key is set but the endpoint is unreachable — one
#    typesafe attempt (the helper), the failure exposed, still unplayed,
#    and never a Claude or codex substitute.
os.environ["TYPESAFE_API_KEY"] = "test-key-never-sent-anywhere"
os.environ["TYPESAFE_API_URL"] = "http://127.0.0.1:1/systemone"
outcome, why = m._answer(job("dead-1", blitz_model))
print("dead-outcome:", outcome)
print("dead-why-visible:", "connection failed" in (why or "").lower()
      or "api error" in (why or "").lower())
print("dead-played:", len(played))
del os.environ["TYPESAFE_API_KEY"]
del os.environ["TYPESAFE_API_URL"]

# 3. ROTATION: the routed 15+10 model is Claude-family; account 1 refuses,
#    account 2 answers — the move lands, the model never changes.
outcome, why = m._answer(job("rotate-1", rapid_model))
print("rotation-outcome:", outcome)
print("rotation-played:", played)
PYEOF
)"
echo "$PYOUT" | sed 's/^/    /'

contains "$PYOUT" "blitz-routed-model: jev-latest" \
    && ok "the blitz offer under test is the live table's own jev-latest" \
    || fail "blitz routed model" "$(printf '%s\n' "$PYOUT" | grep blitz-routed-model)"
contains "$PYOUT" "rapid-routed-model: claude-opus-5-5" \
    && ok "the 15+10 offer under test is the live table's own Opus" \
    || fail "rapid routed model" "$(printf '%s\n' "$PYOUT" | grep rapid-routed-model)"

echo
echo "no key: no attempt, no substitute, failure exposed:"
contains "$PYOUT" "nokey-outcome: failed" \
    && ok "the move is unplayed — the round is a visible failure" \
    || fail "nokey outcome" "$(printf '%s\n' "$PYOUT" | grep nokey-outcome)"
contains "$PYOUT" "nokey-alerted: True" \
    && ok "the missing key is named out loud with no substitute engine" \
    || fail "nokey alert" "$(printf '%s\n' "$PYOUT" | grep nokey-alerted)"
contains "$PYOUT" "nokey-played: 0" \
    && ok "nothing was posted to the board" || fail "nokey played" "$(printf '%s\n' "$PYOUT" | grep nokey-played)"

echo
echo "dead endpoint: one typesafe attempt, unplayed, exposed, zero Claude calls:"
contains "$PYOUT" "dead-outcome: failed" \
    && ok "the unreachable routed jev leaves the move unplayed" \
    || fail "dead outcome" "$(printf '%s\n' "$PYOUT" | grep dead-outcome)"
contains "$PYOUT" "dead-why-visible: True" \
    && ok "the failure cause names the transport" \
    || fail "dead why" "$(printf '%s\n' "$PYOUT" | grep dead-why)"
contains "$PYOUT" "dead-played: 0" \
    && ok "still nothing posted to the board" || fail "dead played" "$(printf '%s\n' "$PYOUT" | grep dead-played)"

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
    "$(sandbox_count_in "--model claude-opus-5-5" "$CLAUDE_WITNESS")" "2"
check_eq "both Claude attempts carried the routed low effort" \
    "$(sandbox_count_in "--effort low" "$CLAUDE_WITNESS")" "2"

echo
echo "no cross-engine walk anywhere in the routed cases:"
check_eq "the codex stub never ran at all" \
    "$(sandbox_count_in invoked "$CODEX_WITNESS")" "0"
check_eq "no Claude invocation ever named a jev model" \
    "$(sandbox_count_in jev "$CLAUDE_WITNESS")" "0"

echo
echo "the honest wording stands pinned (rule 20a honesty, the 2026-09-17 route):"
check "chess_effort.py names Jev UNMEASURED on the clock matrix" \
    grep -q "UNMEASURED on the clock matrix" "$REPO/lib/chess_effort.py"
check "the spec says the same of the Jev rows" \
    grep -qi "unmeasured on the clock matrix" "$REPO/specs/chessweb.md"
check_eq "no absolute physically-finishes claim in chess_effort.py" \
    "$(sandbox_count_in "physically finishes" "$REPO/lib/chess_effort.py")" "0"
check_eq "no unqualified 'no configuration ... finishes' claim either" \
    "$(grep -ci "no configuration[^.]*finishes" "$REPO/lib/chess_effort.py")" "0"
check "the spec's bullet gate claims only what was measured" \
    grep -q "no MEASURED configuration finished bullet reliably" \
    "$REPO/specs/chessweb.md"
