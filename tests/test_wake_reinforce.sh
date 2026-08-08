#!/usr/bin/env bash
# End-to-end proof that a WORDLESS wake still reaches the reinforcement judge.
#
# The turn test (test_turn_reinforce.sh) covers a wake that says something. This
# covers the case the directive actually exists for: a wake that works entirely
# through tool calls and ends with no reply text at all. Until 2026-08-07 that
# path deleted the injected-ids sidecar and returned — the judge was never
# fired, so a memory obeyed for ten silent minutes was credited exactly as much
# as one nobody read. The stub claude here emits a stream with a tool_use block
# and NO text, so the wake's whole output is its work trace; a green run means
# that trace reached the judge and the credited record was stamped.
#
# Needs the local ollama embedder (like tests/test_memory.py); everything else
# is stubbed, silent, and confined to the sandbox.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -euo pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"

sandbox_need_ollama
# The stub claude: the wake call gets a stream holding ONE tool_use block and
# no assistant text — the shape of a wake that worked and said nothing. The
# judge's plain `-p` call gets the verdict, and records its prompt so the test
# can assert the work trace was actually shown to it.
sandbox_stub claude <<EOF
#!/usr/bin/env bash
case "\$*" in
    *--output-format*)
        cat > /dev/null
        printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"tool_use","name":"Write","input":{"file_path":"$WORK/proof-of-work.md"}}]}}'
        printf '%s\n' '{"type":"result"}'
        ;;
    *)
        cat > "$WORK/judge-prompt.txt"
        printf '[1]\n'
        ;;
esac
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=1
PROMISE_AUDIT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
LAST_ORIGIN_FILE="$WORK/last-origin"
WANTS_FILE="$WORK/wants.md"
WAKE_QUIET_HOURS=""
EOF
printf '# Wants\n\n- a want, so the wake path is enabled at all\n' > "$WORK/wants.md"

"$REPO/crab" memory add --kind directive --topics files \
    "Never report a build done without verifying it with a real test." >/dev/null

WAKE_REASON="a file that constitutes you changed" "$REPO/crab" wake >/dev/null 2>&1 || true

DB="$DESKCRAB_MEMORY_DIR/memory.db"
# The judge is detached on purpose — give it a bounded moment to land.
for _ in $(seq 60); do
    [ "$(sqlite3 "$DB" 'SELECT use_count FROM memories WHERE id=1')" = "1" ] && break
    sleep 0.5
done

[ -f "$WORK/judge-prompt.txt" ] \
    || { cat "${DESKCRAB_STATE_PREFIX}-memory-judge.log" 2>/dev/null; die "wordless wake never fired the judge"; }
grep -q "What she DID this turn" "$WORK/judge-prompt.txt" \
    || die "the work trace never reached the judge prompt"
grep -q "proof-of-work.md" "$WORK/judge-prompt.txt" \
    || die "the trace reached the judge but named no work"
[ "$(sqlite3 "$DB" 'SELECT use_count FROM memories WHERE id=1')" = "1" ] \
    || { cat "${DESKCRAB_STATE_PREFIX}-memory-judge.log" 2>/dev/null; die "credited record was never reinforced"; }
ls "${DESKCRAB_STATE_PREFIX}"-memory-injected-*.json 2>/dev/null \
    && die "injected-ids sidecar not consumed"

ok "wordless wake -> work trace -> judge -> reinforce"
