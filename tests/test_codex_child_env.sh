#!/bin/bash
# The configured codex engine reaches every detached child —
# specs/model-backends.md rule 5a.
# Run: bash tests/test_codex_child_env.sh
#
# The fault this pins (2026-08-31): the live conf pointed CODEX_BIN and
# CODEX_HOME at a dedicated second binary and login home, but a detached
# benchmark builder's shell carried neither variable — the conf set them as
# plain shell variables in the dispatching process, nothing exported them,
# and lib/chess_mover.py fell back to stock `codex` and `~/.codex`, so the
# wrong account authenticated an evidence run. The contract now: the shared
# config layer exports both, so a builder session, everything that builder
# launches, and the mover's own codex subprocess all inherit the CONF's
# answer even when the parent environment (a bare systemd unit) carried
# neither name.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"

# The conf under test: the sandbox's minimal honest conf plus a codex engine
# of this test's own — values distinct from the sandbox's PATH stub so
# conf-resolution can never be mistaken for PATH luck.
CONF_CODEX_BIN="$T/bin/codex-from-conf"
CONF_CODEX_HOME="$T/codex-home-from-conf"
mkdir -p "$CONF_CODEX_HOME"
cat >> "$DESKCRAB_CONF" <<CONF
CODEX_BIN="$CONF_CODEX_BIN"
CODEX_HOME="$CONF_CODEX_HOME"
CONF

# The stand-in engine: records the CODEX_HOME its own environment carries —
# exactly what the real codex reads its login from — then answers like a
# plain-text engine so the mover's call path completes.
cat > "$CONF_CODEX_BIN" <<'STUB'
#!/bin/bash
cat > /dev/null
printf '%s\n' "${CODEX_HOME:-UNSET}" > "${CODEX_SUBPROC_WITNESS:?}"
echo "e2e4"
STUB
chmod +x "$CONF_CODEX_BIN"

# Every probe below runs with CODEX_BIN and CODEX_HOME REMOVED from the
# parent environment — the bare-unit shape the failure happened under. What
# arrives in a child can then only have come from the conf, through the
# config layer's export.
bare() { env -u CODEX_BIN -u CODEX_HOME "$@"; }

echo "the config layer itself exports the conf's engine (rule 5a):"
GOT="$(bare bash -c 'source "'"$REPO"'/lib/common.sh" >/dev/null 2>&1
    printf "%s|%s" "$(printenv CODEX_BIN)" "$(printenv CODEX_HOME)"')"
check_eq "a child of any conf-sourcing shell inherits both values" \
    "$GOT" "$CONF_CODEX_BIN|$CONF_CODEX_HOME"

echo
echo "a detached builder's shell inherits the conf's engine:"
BUILDER_WITNESS="$T/witness/builder-codex-env"
sandbox_stub claude <<STUB
#!/bin/bash
cat > /dev/null
printf '%s|%s\n' "\${CODEX_BIN:-UNSET}" "\${CODEX_HOME:-UNSET}" > "$BUILDER_WITNESS"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"probed the environment."}]}}'
STUB
mkdir -p "$JOBS_DIR" "$T/work"
"$REPO/lib/job-status" new "$JOBS_DIR" envprobe "a probe of the builder environment" ""
bare "$REPO/lib/job-runner" envprobe "$T/work" >/dev/null 2>&1
check "the stub builder ran at all" test -s "$BUILDER_WITNESS"
check_eq "the builder saw the conf's CODEX_BIN and CODEX_HOME" \
    "$(cat "$BUILDER_WITNESS" 2>/dev/null)" "$CONF_CODEX_BIN|$CONF_CODEX_HOME"

echo
echo "the python mover and its codex subprocess inherit the conf's engine:"
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
PY="$VENV/bin/python"
if [ ! -x "$PY" ]; then
    echo "SKIP: no chess venv at $VENV — the mover half needs python-chess"
else
    SUBPROC_WITNESS="$T/witness/mover-codex-subproc"
    PYOUT="$(bare env CODEX_SUBPROC_WITNESS="$SUBPROC_WITNESS" \
        DESKCRAB_CHESS_DIR="$T/chess-games" \
        bash -c 'source "'"$REPO"'/lib/common.sh" >/dev/null 2>&1
        exec "'"$PY"'" -B - <<PYEOF
import os, sys
sys.path.insert(0, "'"$REPO"'/lib")
print("env:", os.environ.get("CODEX_BIN", "UNSET"),
      os.environ.get("CODEX_HOME", "UNSET"))
import chess_mover
m = chess_mover.Mover(lambda job, mv: True,
                      log=lambda *a, **k: None,
                      metric=lambda stage, detail="": None)
att = list(m._attempts("low", True, "gpt-5.3-codex-spark"))
print("attempts:", " ".join(label for label, _, _ in att))
label, cmd, env = att[0]
print("resolved:", cmd[0])
print("key-stripped:", "OPENAI_API_KEY" not in env)
out, why = m._call(cmd, env, "probe position")
print("call:", (out or "").strip(), why)
PYEOF')"
    contains "$PYOUT" "env: $CONF_CODEX_BIN $CONF_CODEX_HOME" \
        && ok "the mover process inherits the conf's values through the export" \
        || fail "mover env: $PYOUT"
    contains "$PYOUT" "attempts: codex" \
        && ok "a codex self-play model yields the one codex attempt, nothing else" \
        || fail "attempts: $PYOUT"
    contains "$PYOUT" "resolved: $CONF_CODEX_BIN" \
        && ok "the mover resolves the CONF's binary, not stock codex" \
        || fail "resolved: $PYOUT"
    contains "$PYOUT" "key-stripped: True" \
        && ok "OPENAI_API_KEY is stripped from the codex attempt (rule 5)" \
        || fail "key: $PYOUT"
    contains "$PYOUT" "call: e2e4" \
        && ok "the call ran the conf's binary to completion" \
        || fail "call: $PYOUT"
    check_eq "and the codex SUBPROCESS itself received the conf's CODEX_HOME" \
        "$(cat "$SUBPROC_WITNESS" 2>/dev/null)" "$CONF_CODEX_HOME"
fi
