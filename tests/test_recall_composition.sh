#!/usr/bin/env bash
# What the memory store gets ASKED, proven through common.sh rather than by
# calling the composer directly.
#
# The 2026-08-07 outage was fixed by making the recall query SHORTER, and the
# fix left its subject wrong: every prompt build, interactive turns included,
# asked the store about Beatrice's wants shelf while the user was talking
# about his own business. Memories have nothing to do with wants unless a want
# is actively being pursued. tests/test_memory.py covers the composition
# itself; this covers the wiring — that a turn with a user in it composes from
# the conversation and an autonomous wake composes from its agenda and the one
# want in hand, because those are two different paths through build_system_prompt
# and the composer cannot tell which it is on.
#
# lib/memory.py is replaced by a stub that imports the REAL module, composes
# the query exactly as recall-block would, and writes it out. So a green run
# is a statement about the shipped composer, not about the stub. Deterministic
# and offline: nothing here embeds anything.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -euo pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"

# A private copy of the tree, so the stub memory.py cannot be picked up by
# anything running against the real repo.
mkdir -p "$WORK/repo"
cp "$REPO/crab" "$WORK/repo/"
cp -r "$REPO/lib" "$WORK/repo/lib"

cat > "$WORK/repo/lib/memory.py" <<EOF
#!/usr/bin/env python3
"""Recording stub: composes with the real composer, records, emits nothing."""
import argparse, importlib.util, os, sys

spec = importlib.util.spec_from_file_location("realmem", "$REPO/lib/memory.py")
real = importlib.util.module_from_spec(spec)
spec.loader.exec_module(real)

ap = argparse.ArgumentParser()
ap.add_argument("cmd")
for opt in ("--query", "--reason", "--wants", "--convo", "--ids-out", "--log"):
    ap.add_argument(opt, default="")
ap.add_argument("--wake", action="store_true")
a = ap.parse_args()

with open("$WORK/composed.txt", "w") as f:
    f.write(("WAKE" if a.wake else "CONVERSATION") + "\n")
    f.write(real.recall_query(a.reason, a.wants, a.convo, wake=a.wake) + "\n")
EOF
chmod +x "$WORK/repo/lib/memory.py"

# CLAUDE_BIN is exported by the sandbox, not merely written into the conf:
# common.sh captures the inherited value before sourcing the config and
# restores it afterwards on purpose (a builder must be able to override it), so
# a conf line alone loses to whatever the caller's environment holds. Getting
# this wrong does not fail the test — it runs a REAL autonomous wake session
# and blocks for as long as the model takes.
# The stub claude answers every generation with one plain line.
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *--output-format*)
        cat > /dev/null
        printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"noted."}]}}'
        printf '%s\n' '{"type":"result"}'
        ;;
    *) cat > /dev/null; printf 'ok\n' ;;
esac
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=1
PROMISE_AUDIT=0
MEMORY_JUDGE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
LAST_ORIGIN_FILE="$WORK/last-origin"
WANTS_FILE="$WORK/wants.md"
WAKE_QUIET_HOURS=""
EOF

# A shelf with a distinctive topic, and a want document whose CURRENT dated
# note is distinguishable from its founding one.
mkdir -p "$WORK/wants"
cat > "$WORK/wants.md" <<'EOF'
# Wants

- 🎼 **PIPEORGAN_SHELF_TOPIC** — a standing sitting at 21:20, daily. → `wants/pipeorgan.md`
- 🔊 **SEMAPHORE_OTHER_WANT** — measured it. → `wants/semaphore.md`
EOF
cat > "$WORK/wants/pipeorgan.md" <<'EOF'
# Pipe organ

## What I want

To play it.

## 2026-08-05 — the founding entry

ANCIENT_HISTORY_MARKER

## 2026-08-07 04:15 — where it stands

CURRENT_PROGRESS_MARKER
EOF
printf '# Semaphore\n\n## 2026-08-01 — old\n\nx\n' > "$WORK/wants/semaphore.md"
# Not the want in hand: last written days ago.
touch -d '2026-08-01' "$WORK/wants/semaphore.md"

fail() { [ -f "$WORK/composed.txt" ] && cat "$WORK/composed.txt"; die "$1"; }

# --- (a) a turn with a user in it composes from the conversation ------------
rm -f "$WORK/composed.txt"
"$WORK/repo/crab" remote "what did the doctor say about my knee" >/dev/null 2>&1 || true
[ -f "$WORK/composed.txt" ] || fail "the remote turn never built a recall query"

SHAPE="$(head -n1 "$WORK/composed.txt")"
QUERY="$(tail -n +2 "$WORK/composed.txt")"
[ "$SHAPE" = "CONVERSATION" ] \
    || fail "a turn with a user in it composed as $SHAPE"
grep -q "what did the doctor say about my knee" <<<"$QUERY" \
    || fail "the user's last turn is not in the query"
# Not one word of the shelf, by topic or by pointer.
for forbidden in PIPEORGAN_SHELF_TOPIC SEMAPHORE_OTHER_WANT CURRENT_PROGRESS_MARKER wants/; do
    grep -q "$forbidden" <<<"$QUERY" \
        && fail "want text ('$forbidden') reached an interactive turn's query"
done

# --- (b) an autonomous wake composes from the one want in hand --------------
rm -f "$WORK/composed.txt"
"$WORK/repo/crab" wake >/dev/null 2>&1 || true
[ -f "$WORK/composed.txt" ] || fail "the wake never built a recall query"

SHAPE="$(head -n1 "$WORK/composed.txt")"
QUERY="$(tail -n +2 "$WORK/composed.txt")"
[ "$SHAPE" = "WAKE" ] || fail "an autonomous wake composed as $SHAPE"
grep -q "PIPEORGAN_SHELF_TOPIC" <<<"$QUERY" \
    || fail "the focused want's shelf topic is missing from the wake query"
grep -q "CURRENT_PROGRESS_MARKER" <<<"$QUERY" \
    || fail "the focused want's CURRENT dated note is missing from the wake query"
grep -q "ANCIENT_HISTORY_MARKER" <<<"$QUERY" \
    && fail "the wake query carried the whole want document, not its current note"
grep -q "SEMAPHORE_OTHER_WANT" <<<"$QUERY" \
    && fail "a want that is not being worked reached the focused wake query"

ok "conversation asks about the conversation, a wake asks about the want in hand"
