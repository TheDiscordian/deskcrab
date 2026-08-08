#!/usr/bin/env bash
# End-to-end proof that a real turn path reaches the reinforcement judge: a
# scratch-instance `crab remote` turn (the same claude_generate +
# fire_memory_judge plumbing the desktop turn uses) with the claude binary
# stubbed. The stub answers the turn with a reply that uses the Xena record,
# then answers the detached judge with the verdict [1] — so a green run means
# recall-block wrote the injected-ids sidecar, the turn fired the judge after
# the reply, and the judge stamped ONLY the record it credited. Needs the
# local ollama embedder (like tests/test_memory.py); everything else is
# stubbed, silent, and confined to the sandbox.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -euo pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"

sandbox_need_ollama

# The stub claude: a turn call carries --output-format stream-json and gets a
# stream holding one assistant reply; the judge's plain `-p` call gets the
# verdict — record 1 (Xena) was used, record 2 was not.
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *--output-format*)
        cat > /dev/null
        printf '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Your character is Xena, the Paladin."}]}}\n'
        printf '{"type":"result"}\n'
        ;;
    *)
        cat > /dev/null
        printf '[1]\n'
        ;;
esac
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=1
PROMISE_AUDIT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
LAST_ORIGIN_FILE="$WORK/last-origin"
EOF

# Seed: record 1 will be used by the reply, record 2 surfaces on the same
# query family but is ignored.
"$REPO/crab" memory add --kind note --topics wow \
    "His character Xena is a Paladin on the DiscoWoW server." >/dev/null
"$REPO/crab" memory add --kind note --topics wow \
    "DiscoWoW runs on a WotLK private server core." >/dev/null

OUT="$("$REPO/crab" remote "which character do I play on DiscoWoW")"
printf '%s' "$OUT" | grep -q "Xena" \
    || die "turn reply missing the stubbed text" "$OUT"

# The judge is detached on purpose — give it a bounded moment to land.
DB="$DESKCRAB_MEMORY_DIR/memory.db"
for _ in $(seq 60); do
    [ "$(sqlite3 "$DB" 'SELECT use_count FROM memories WHERE id=1')" = "1" ] && break
    sleep 0.5
done

[ "$(sqlite3 "$DB" 'SELECT use_count FROM memories WHERE id=1')" = "1" ] \
    || { cat "${DESKCRAB_STATE_PREFIX}-memory-judge.log" 2>/dev/null; die "judged record was never reinforced"; }
[ -n "$(sqlite3 "$DB" 'SELECT last_used_at FROM memories WHERE id=1')" ] \
    || die "last_used_at not stamped"
[ "$(sqlite3 "$DB" 'SELECT use_count FROM memories WHERE id=2')" = "0" ] \
    || die "ignored record was reinforced"
[ -z "$(sqlite3 "$DB" 'SELECT last_used_at FROM memories WHERE id=2')" ] \
    || die "ignored record was stamped"
grep -q "used=\[1\]" "${DESKCRAB_STATE_PREFIX}-memory-judge.log" \
    || die "judge log missing the verdict"
ls "${DESKCRAB_STATE_PREFIX}"-memory-injected-*.json 2>/dev/null \
    && die "injected-ids sidecar not consumed"

ok "turn -> judge -> reinforce, only the used record stamped"
