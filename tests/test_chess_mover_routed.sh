#!/bin/bash
# A routed model offer preserves exact model identity — specs/chessweb.md
# rule 16b, specs/model-backends.md rule 15.
# Run: bash tests/test_chess_mover_routed.sh
#
# The contract under test: when a real-game job carries the bridge's
# routed model offer and that model is codex-family, the mover attempts THAT
# model through the codex engine or nothing. The dormant Spark slug is used
# only against stubs here; this is not a Spark benchmark or a live game.
# A refusal over usage makes zero Claude calls and leaves the move unplayed
# with a visible failure; a cooling codex login yields no attempt at all,
# with the refusal named out loud. The engine-fallback walk stays exactly
# where it belongs: a codex model chosen by the mover's own environment
# chain, never a routed offer. Same-model Claude account rotation is
# identity-preserving and untouched. No live codex calls anywhere here —
# stubs only.
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

# The refusing codex stub: answers every call with a usage-limit refusal,
# exit 1 — the shape a dry subscription hands back. Records each invocation.
CODEX_STUB="$T/bin/codex-refusing"
CODEX_WITNESS="$T/witness/codex-calls"
cat > "$CODEX_STUB" <<STUB
#!/bin/bash
cat > /dev/null
echo "invoked" >> "$CODEX_WITNESS"
echo '{"type":"error","message":"You have hit your usage limit. Try again later."}' >&2
exit 1
STUB
chmod +x "$CODEX_STUB"

# The Claude witness: any invocation is a broken contract on the routed path.
CLAUDE_STUB="$T/bin/claude-witness"
CLAUDE_WITNESS="$T/witness/claude-calls"
cat > "$CLAUDE_STUB" <<STUB
#!/bin/bash
cat > /dev/null
echo "invoked" >> "$CLAUDE_WITNESS"
echo "e2e4"
STUB
chmod +x "$CLAUDE_STUB"

PYOUT="$(env CODEX_BIN="$CODEX_STUB" CLAUDE_BIN="$CLAUDE_STUB" \
    DESKCRAB_CHESS_DIR="$T/chess-games" \
    DESKCRAB_CHESS_MEMORY_PROMPT=0 DESKCRAB_CHESS_SIMILAR=0 \
    DESKCRAB_CODEX_STATE="$T/codex-state-clean" \
    "$PY" -B - <<PYEOF
import os, sys
sys.path.insert(0, "$REPO/lib")
import chess_mover

alerts = []
m = chess_mover.Mover(lambda job, mv: True,
                      log=lambda *a, **k: None,
                      metric=lambda stage, detail="": None,
                      alert=lambda msg: alerts.append(msg))

# 1. The routed codex offer: exactly one attempt, the codex engine, no
#    Claude entry anywhere in the walk.
att = list(m._attempts("low", False, "gpt-5.3-codex-spark"))
print("routed-labels:", " ".join(label for label, _, _ in att))
print("routed-binary:", att[0][1][0] if att else "NONE")
print("routed-model:", att[0][1][att[0][1].index("-m") + 1] if att else "NONE")

# 2. The refusal itself: the codex stub refuses, the mover gets the failure
#    back, and the generator is spent — the move is unplayed by construction.
label, cmd, env = att[0]
out, why = m._call(cmd, env, "probe position")
print("refusal-why:", (why or "clean").split(":")[0])
print("refusal-visible:", "usage limit" in (why or "").lower())

# 3. An env-chain codex model still walks to the Claude fallback (rule 15
#    unchanged where it applies).
os.environ["DESKCRAB_CHESS_MOVER_MODEL"] = "sol"
chain = list(m._attempts("low", False, None))
print("chain-labels:", " ".join(label for label, _, _ in chain))

# 4. A cooling codex login on the ROUTED path: zero attempts, the refusal
#    named out loud, identity preserved.
import time
cool = "$T/codex-state-cooling"
with open(cool, "w") as fh:
    fh.write("blocked-until\t%d\tusage limit\n" % (int(time.time()) + 900))
os.environ["DESKCRAB_CODEX_STATE"] = cool
cooled = list(m._attempts("low", False, "gpt-5.3-codex-spark"))
print("cooling-attempts:", len(cooled))
print("cooling-alerted:", any("routed model" in a and "no substitute" in a
                              for a in alerts))
PYEOF
)"
echo "$PYOUT" | sed 's/^/    /'

echo
echo "a routed codex offer is that model or nothing:"
contains "$PYOUT" "routed-labels: codex" \
    && ok "exactly one attempt, the codex engine, for the routed spark offer" \
    || fail "routed attempts: $PYOUT"
contains "$PYOUT" "routed-binary: $CODEX_STUB" \
    && ok "the attempt runs CODEX_BIN, no Claude binary in the walk" \
    || fail "routed binary: $PYOUT"
contains "$PYOUT" "routed-model: gpt-5.3-codex-spark" \
    && ok "the exact routed slug rides the argv" \
    || fail "routed model: $PYOUT"

echo
echo "a usage refusal leaves the move unplayed, visibly, with zero Claude calls:"
contains "$PYOUT" "refusal-why: exit-1" \
    && ok "the refusal comes back as the attempt's own failure" \
    || fail "refusal: $PYOUT"
contains "$PYOUT" "refusal-visible: True" \
    && ok "the failure carries the refusal text for the alert machinery" \
    || fail "refusal text: $PYOUT"
check_eq "the codex stub was invoked exactly once" \
    "$(sandbox_count_in invoked "$CODEX_WITNESS")" "1"
check_eq "and the Claude witness was never invoked at all" \
    "$(sandbox_count_in invoked "$CLAUDE_WITNESS")" "0"

echo
echo "the engine fallback stays where it belongs — the env chain:"
contains "$PYOUT" "chain-labels: codex account" \
    && ok "an env-chain codex model still walks codex then the Claude accounts" \
    || fail "chain: $PYOUT"

echo
echo "a cooling login on the routed path yields nothing, and says so:"
contains "$PYOUT" "cooling-attempts: 0" \
    && ok "zero attempts — no substitute engine" \
    || fail "cooling: $PYOUT"
contains "$PYOUT" "cooling-alerted: True" \
    && ok "the refusal is named out loud" \
    || fail "cooling alert: $PYOUT"
