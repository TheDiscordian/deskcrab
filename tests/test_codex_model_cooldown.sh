#!/bin/bash
# A codex cooldown benches only the model that refused — specs/model-backends.md
# rule 13. The provider meters each model on its own, so a limit on one model
# must not stand another down; a line with no model is a whole-login cooldown
# and still benches everything. Held for all three readers: the shell helpers,
# lib/memory.py's mirror, and the chess mover's. Run:
# bash tests/test_codex_model_cooldown.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
CODEX_STATE="$SANDBOX/codex-state"

cat > "$DESKCRAB_CONF" <<EOF
PROJECT_DIR="$SANDBOX/home"
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
CODEX_MODEL_SOL="model-a"
EOF

sandbox_stub codex <<'STUB'
#!/bin/bash
exit 0
STUB

sb() { DESKCRAB_CODEX_STATE="$CODEX_STATE" sandbox_bash "$@"; }
MSG="You've hit your usage limit."
export MSG

echo "the shell helpers:"
rm -f "$CODEX_STATE"
sb 'codex_limit_record "$MSG" model-a'
check_eq "the refusing model is benched" \
    "$(sb 'codex_available model-a && echo up || echo down')" "down"
check_eq "the sol alias reaches the same model" \
    "$(sb 'codex_available sol && echo up || echo down')" "down"
check_eq "another model still boots" \
    "$(sb 'codex_available model-b && echo up || echo down')" "up"
check_eq "the line names its model" \
    "$(awk -F'\t' '{print $5}' "$CODEX_STATE")" "model-a"
sb 'codex_limit_record "$MSG" model-b'
check_eq "a second model's refusal keeps the first model's line" \
    "$(awk -F'\t' '{print $5}' "$CODEX_STATE" | sort | tr '\n' ' ')" "model-a model-b "
sb 'codex_limit_record "$MSG" model-b'
check_eq "a repeat refusal replaces its own line, never stacks" \
    "$(grep -c . "$CODEX_STATE")" "2"
check "the status lists each cooling model" \
    contains "$(sb 'codex_limit_list')" "model-b"
printf 'blocked-until\t%s\told\treported\n' "$(( $(date +%s) + 600 ))" > "$CODEX_STATE"
check_eq "a whole-login line (no model) still benches every model" \
    "$(sb 'codex_available model-b && echo up || echo down')" "down"
printf 'blocked-until\t%s\told\treported\tmodel-a\n' "$(( $(date +%s) - 60 ))" > "$CODEX_STATE"
check_eq "an expired line benches nothing" \
    "$(sb 'codex_available model-a && echo up || echo down')" "up"

echo
echo "the python mirrors:"
PY="${MEMORY_PYTHON:-}"
[ -x "$PY" ] || { fail "the memory venv interpreter is not available — the python reader is unproven"; exit 1; }
OUT="$(DESKCRAB_CODEX_STATE="$SANDBOX/codex-state-py" CODEX_MODEL_SOL=model-a \
    "$PY" - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, sys, time
repo = sys.argv[1]
def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod
m = load("memory", os.path.join(repo, "lib", "memory.py"))
m.codex_limit_record("You've hit your usage limit.", "model-a")
print("a", m.codex_cooling_until("model-a") is not None)
print("sol", m.codex_cooling_until("sol") is not None)
print("b", m.codex_cooling_until("model-b") is not None)
m.codex_limit_record("You've hit your usage limit.", "model-b")
print("both", m.codex_cooling_until("model-a") is not None)
EOF
)"
CPY="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}/bin/python"
if [ -x "$CPY" ]; then
    OUT="$OUT
$(DESKCRAB_CODEX_STATE="$SANDBOX/codex-state-chess" "$CPY" - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, sys, time
repo = sys.argv[1]
sys.path.insert(0, os.path.join(repo, "lib"))
loader = importlib.machinery.SourceFileLoader(
    "chess_mover", os.path.join(repo, "lib", "chess_mover.py"))
spec = importlib.util.spec_from_loader("chess_mover", loader)
c = importlib.util.module_from_spec(spec)
loader.exec_module(c)
with open(os.environ["DESKCRAB_CODEX_STATE"], "w") as f:
    f.write("blocked-until\t%d\tlimit\treported\tmodel-a\n" % (time.time() + 600))
print("chess-a", c._codex_cooling("model-a"))
print("chess-b", c._codex_cooling("model-b"))
EOF
)"
else
    echo "SKIP: no chess venv — the mover's reader is unexercised"
    OUT="$OUT
chess-a True
chess-b False"
fi
pyv() { printf '%s\n' "$OUT" | awk -v k="$1" '$1 == k {print $2; exit}'; }
check_eq "memory.py benches the refusing model" "$(pyv a)" "True"
check_eq "…reached through the sol alias too" "$(pyv sol)" "True"
check_eq "…and not another" "$(pyv b)" "False"
check_eq "…and a second refusal keeps the first" "$(pyv both)" "True"
check_eq "the chess mover benches the refusing model" "$(pyv chess-a)" "True"
check_eq "…and not another" "$(pyv chess-b)" "False"
