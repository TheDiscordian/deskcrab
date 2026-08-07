#!/usr/bin/env bash
# End-to-end proof that a real turn path reaches the reinforcement judge: a
# scratch-instance `crab remote` turn (the same claude_generate +
# fire_memory_judge plumbing the desktop turn uses) with the claude binary
# stubbed. The stub answers the turn with a reply that uses the Xena record,
# then answers the detached judge with the verdict [1] — so a green run means
# recall-block wrote the injected-ids sidecar, the turn fired the judge after
# the reply, and the judge stamped ONLY the record it credited. Needs the
# local ollama embedder (like tests/test_memory.py); everything else is
# stubbed, silent, and confined to a mktemp dir.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/deskcrab-reinforce-test-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export DESKCRAB_STATE_PREFIX="$WORK/state"
export DESKCRAB_MEMORY_DIR="$WORK/memory"
export DESKCRAB_CONF="$WORK/conf"
export CLAUDE_BIN="$WORK/bin/claude"

mkdir -p "$WORK/bin"
# The stub claude: a turn call carries --output-format stream-json and gets a
# stream holding one assistant reply; the judge's plain `-p` call gets the
# verdict — record 1 (Xena) was used, record 2 was not.
cat > "$WORK/bin/claude" <<'EOF'
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
chmod +x "$WORK/bin/claude"
# A test must never reach the desktop: no notifications, no synthesis.
for tool in notify-send piper-tts hyprctl aplay; do
    printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$tool"
    chmod +x "$WORK/bin/$tool"
done
export PATH="$WORK/bin:$PATH"

cat > "$WORK/conf" <<EOF
MEMORY_STORE=1
PROMISE_AUDIT=0
CLAUDE_BIN="$WORK/bin/claude"
ARCHIVE_DIR="$WORK/archive"
JOBS_DIR="$WORK/jobs"
WAKES_DIR="$WORK/wakes"
DAY_JOURNAL_DIR="$WORK/journal"
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
    || { echo "FAIL: turn reply missing the stubbed text: $OUT"; exit 1; }

# The judge is detached on purpose — give it a bounded moment to land.
DB="$WORK/memory/memory.db"
for _ in $(seq 60); do
    [ "$(sqlite3 "$DB" 'SELECT use_count FROM memories WHERE id=1')" = "1" ] && break
    sleep 0.5
done

[ "$(sqlite3 "$DB" 'SELECT use_count FROM memories WHERE id=1')" = "1" ] \
    || { echo "FAIL: judged record was never reinforced"; cat "$WORK/state-memory-judge.log" 2>/dev/null; exit 1; }
[ -n "$(sqlite3 "$DB" 'SELECT last_used_at FROM memories WHERE id=1')" ] \
    || { echo "FAIL: last_used_at not stamped"; exit 1; }
[ "$(sqlite3 "$DB" 'SELECT use_count FROM memories WHERE id=2')" = "0" ] \
    || { echo "FAIL: ignored record was reinforced"; exit 1; }
[ -z "$(sqlite3 "$DB" 'SELECT last_used_at FROM memories WHERE id=2')" ] \
    || { echo "FAIL: ignored record was stamped"; exit 1; }
grep -q "used=\[1\]" "$WORK/state-memory-judge.log" \
    || { echo "FAIL: judge log missing the verdict"; exit 1; }
ls "$WORK"/state-memory-injected-*.json 2>/dev/null \
    && { echo "FAIL: injected-ids sidecar not consumed"; exit 1; }

echo "OK: turn -> judge -> reinforce, only the used record stamped"
