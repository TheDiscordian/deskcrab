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
# The wake is fired the way every booker fires one — kind and reason on the
# command line — because that is the only channel `crab wake` reads
# (_wake_norm, over argv). The reason is the wake's agenda AND its recall
# query (specs/memory-recall.md rule 4): a wake that arrives without one
# beside an unrelated want retrieves nothing, writes no injected-ids sidecar,
# and the judge has nothing to judge. So the chain is pinned from the front
# as well as the back — the agenda and the directive both reach the judge —
# and every step is a counted assertion, so a red run says which step broke
# instead of "0 passed, 0 failed".
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
# judge's call gets the verdict, and records its prompt so the test can assert
# the work trace was actually shown to it. The two are told apart by
# stream-json, NEVER by --output-format alone: the judge's own call carries
# `--output-format json` too (the ledger's result object, metrics.md rule 15),
# and a stub that keyed on the flag fed the judge the wake's stream — the
# verdict came back unparseable and this file sat red while the code was fine.
sandbox_stub claude <<EOF
#!/usr/bin/env bash
case "\$*" in
    *stream-json*)
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

DIRECTIVE="Never report a build done without verifying it with a real test."
REASON="a file that constitutes you changed"
"$REPO/crab" memory add --kind directive --topics files "$DIRECTIVE" >/dev/null

# An event wake carrying what happened, the reason as its own argument. The
# first draft of this file exported WAKE_REASON and fired a bare `crab wake`;
# crab reads kind and reason from argv and overwrote the environment's with
# nothing, so the wake it tested had no agenda, recalled nothing, wrote no
# sidecar, and the judge was — correctly — never fired. A reasoned event wake
# is also never the standing own-time return (idle_return_candidate), so
# nothing routes it to the choosing session on the other engine.
"$REPO/crab" wake event "$REASON" >/dev/null 2>&1 || true

DB="$DESKCRAB_MEMORY_DIR/memory.db"
# The judge is detached on purpose — give it a bounded moment to land.
for _ in $(seq 60); do
    [ "$(sqlite3 "$DB" 'SELECT use_count FROM memories WHERE id=1')" = "1" ] && break
    sleep 0.5
done

# The judge's own log beside a miss, when there is one. Guarded on purpose:
# this file runs under set -e, and a bare `cat` of a log that was never
# written exits 1 inside the `|| { …; die; }` group BEFORE die runs — the
# test then ended silently, "exited 1 — 0 passed, 0 failed", and the
# diagnostic hid the very verdict it was there to explain.
judge_log() { cat "${DESKCRAB_STATE_PREFIX}-memory-judge.log" 2>/dev/null || true; }

[ -f "$WORK/judge-prompt.txt" ] \
    || { judge_log; die "wordless wake never fired the judge"; }
ok "the wordless wake fired the judge"
# The front of the chain: the reason reached the wake (it is the agenda the
# judge is shown) and the recall it composed injected the directive (the
# record the judge is asked about). Lose either and no sidecar is written,
# so the judge is never fired at all — which is what a reason left in the
# environment looked like.
grep -qF "$REASON" "$WORK/judge-prompt.txt" \
    && ok "the wake's reason reached the judge as its agenda" \
    || fail "the wake's reason never reached the judge as its agenda"
grep -qF "$DIRECTIVE" "$WORK/judge-prompt.txt" \
    && ok "the recalled directive reached the judge" \
    || fail "the recalled directive never reached the judge"
grep -q "What she DID this turn" "$WORK/judge-prompt.txt" \
    && ok "the work trace reached the judge prompt" \
    || fail "the work trace never reached the judge prompt"
grep -q "proof-of-work.md" "$WORK/judge-prompt.txt" \
    && ok "the trace named the work" \
    || fail "the trace reached the judge but named no work"
if [ "$(sqlite3 "$DB" 'SELECT use_count FROM memories WHERE id=1')" = "1" ]; then
    ok "the credited record was reinforced"
else
    judge_log; fail "credited record was never reinforced"
fi
if ls "${DESKCRAB_STATE_PREFIX}"-memory-injected-*.json >/dev/null 2>&1; then
    fail "injected-ids sidecar not consumed"
else
    ok "the injected-ids sidecar was consumed"
fi

ok "wordless wake -> work trace -> judge -> reinforce"
