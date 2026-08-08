#!/bin/bash
# Tests for /watch across a conversation REWRITE (lib/serve.py).
# Run: bash tests/test_watch_rewrite.sh
#
# What he saw on 2026-08-07 (again): the phone only showed new replies after a
# manual refresh. The serve log tells the story — at 15:53:05 he refreshed the
# page THREE SECONDS after the conversation archived (his poll cursor said 20,
# the file now held 2 turns), and the same shape precedes most of the day's
# refreshes.
#
# The /watch cursor is a POSITION in a list that compaction and archival are
# allowed to rewrite. The old handling, when the count shrank below the cursor,
# was to snap the cursor down to the new total and wait for the count to pass
# it — which silently consumes every turn that rode in with the rewrite. The
# archive case is the worst: after 15 minutes of quiet the next exchange
# archives the file and starts fresh, so the FIRST exchange of every new
# conversation landed behind the snapped cursor and was never delivered. And a
# rewrite that shrinks and then regrows past the cursor is undetectable by
# count alone — turns[since:] would be the WRONG turns, delivered as if
# nothing happened.
#
# So the conversation now carries a generation token (`gen`): the identity of
# this incarnation of the file, derived from the summary and the first
# surviving turn — stable across appends, changed by every compaction or
# archive. A poll whose gen no longer matches is answered IMMEDIATELY with
# `reset` and the full current list; the client reseeds from /context exactly
# as a manual refresh would, without the hand.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

SERVER_PID=""
# The exit trap belongs to the sandbox — it is what proves the run left the live
# instance alone — so the server is stopped through its hook rather than by
# installing a second one over the top.
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

SECRET="testsecret"
# A port nobody else is on; the live instance sits on 8723, test_phone_live on 18723.
PORT=18724
CONVO="$T/deskcrab-convo.txt"
SUMMARY="$T/deskcrab-convo-summary.txt"

# Short long-poll timeout so the "nothing arrives" cases don't take 25 s each.
DESKCRAB_SERVE_SECRET="$SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 \
DESKCRAB_SERVE_WATCH_TIMEOUT=3 \
DESKCRAB_STATE_PREFIX="$T/deskcrab" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 100); do
    curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1; then
    die "the server never came up" "$(cat "$T/server.log")"
fi

AUTH=(-H "X-Crab-Key: $SECRET")

# jq without depending on jq.
jget() { # <file> <python-expr over doc>
    python3 -c 'import json,sys; doc=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$3" 2>/dev/null ||
    python3 -c 'import json,sys; doc=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}
jq_() { python3 -c 'import json,sys; doc=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

mkconvo() { # <n-pairs> <tag>
    : > "$CONVO"
    local i
    for i in $(seq 1 "$1"); do
        printf 'User [2026-08-07 12:%02d]: %s question %d\n' "$i" "$2" "$i" >> "$CONVO"
        printf 'Assistant [2026-08-07 12:%02d]: %s reply %d\n' "$i" "$2" "$i" >> "$CONVO"
    done
}

echo "== a fresh conversation reaches a held-open poll (the archive case) =="

mkconvo 10 old            # 20 turns; the phone's cursor stands at 20
CTX="$T/ctx1.json"
curl -fsS -m 5 "${AUTH[@]}" "http://127.0.0.1:$PORT/context" > "$CTX"
N=$(jq_ "$CTX" 'doc["n"]')
GEN=$(jq_ "$CTX" 'doc.get("gen","")')
[ "$N" = 20 ] || fail "seed count" "expected 20, got $N"
[ -n "$GEN" ] && ok "/context carries a generation token" \
    || fail "/context carries a generation token" "no gen field"

# Hold a poll open with the current cursor+gen, exactly as the page does...
OUT="$T/watch1.json"
curl -fsS -m 30 "${AUTH[@]}" \
    "http://127.0.0.1:$PORT/watch?wait=1&wakeseen=&since=$N&gen=$GEN" > "$OUT" &
WPID=$!
sleep 1

# ...and archive out from under it: file moved away, fresh convo, first exchange.
printf 'Old conversation summarized here.\n' > "$SUMMARY"
: > "$CONVO"
printf 'User [2026-08-07 13:01]: fresh question\n' >> "$CONVO"
printf 'Assistant [2026-08-07 13:01]: FRESH-REPLY-CANARY\n' >> "$CONVO"

wait "$WPID" 2>/dev/null
grep -q 'FRESH-REPLY-CANARY' "$OUT" \
    && ok "the first exchange of the new conversation arrives on the held poll" \
    || fail "the first exchange of the new conversation arrives on the held poll" \
            "the rewrite was swallowed: $(cat "$OUT" 2>/dev/null | head -c 300)"
[ "$(jq_ "$OUT" 'doc.get("reset") is True' 2>/dev/null)" = True ] \
    && ok "the poll says reset, so the client knows to reseed" \
    || fail "the poll says reset, so the client knows to reseed" "$(head -c 200 "$OUT")"

echo "== turns riding a compaction are not consumed by the snapped cursor =="

mkconvo 10 older
rm -f "$SUMMARY"
CTX="$T/ctx2.json"
curl -fsS -m 5 "${AUTH[@]}" "http://127.0.0.1:$PORT/context" > "$CTX"
N=$(jq_ "$CTX" 'doc["n"]')
GEN=$(jq_ "$CTX" 'doc.get("gen","")')

OUT="$T/watch2.json"
curl -fsS -m 30 "${AUTH[@]}" \
    "http://127.0.0.1:$PORT/watch?wait=1&wakeseen=&since=$N&gen=$GEN" > "$OUT" &
WPID=$!
sleep 1

# Compaction folds the first half into the summary and the new exchange lands
# in the same lock window: 10 surviving turns + 2 new ones = 12 < cursor 20.
printf 'First half folded into this summary.\n' > "$SUMMARY"
tail -n 10 "$CONVO" > "$CONVO.new" && mv "$CONVO.new" "$CONVO"
printf 'User [2026-08-07 13:05]: compacted question\n' >> "$CONVO"
printf 'Assistant [2026-08-07 13:05]: COMPACTED-REPLY-CANARY\n' >> "$CONVO"

wait "$WPID" 2>/dev/null
# A poll can catch the rewrite mid-flight (summary swapped, tail not yet) and
# return a reset holding the OLD turns; the client then re-polls with the new
# gen and the next mismatch resets again. Follow that loop, as the page does —
# what must never be needed is a refresh.
for _ in 1 2 3; do
    grep -q 'COMPACTED-REPLY-CANARY' "$OUT" && break
    N=$(jq_ "$OUT" 'doc["n"]'); GEN=$(jq_ "$OUT" 'doc.get("gen","")')
    curl -fsS -m 30 "${AUTH[@]}" \
        "http://127.0.0.1:$PORT/watch?wait=1&wakeseen=&since=$N&gen=$GEN" > "$OUT"
done
grep -q 'COMPACTED-REPLY-CANARY' "$OUT" \
    && ok "a reply that rode the compaction still arrives" \
    || fail "a reply that rode the compaction still arrives" \
            "swallowed by the snap: $(head -c 300 "$OUT")"

echo "== a shrink that regrows past the cursor is still caught =="

mkconvo 3 shrink          # 6 turns, cursor at 6
rm -f "$SUMMARY"
CTX="$T/ctx3.json"
curl -fsS -m 5 "${AUTH[@]}" "http://127.0.0.1:$PORT/context" > "$CTX"
N=$(jq_ "$CTX" 'doc["n"]')
GEN=$(jq_ "$CTX" 'doc.get("gen","")')

# Archive and regrow PAST the old cursor before the next poll even starts: by
# count alone this looks like two new turns at positions 6..7 — wrong ones.
: > "$CONVO"
for i in 1 2 3 4; do
    printf 'User [2026-08-07 13:%02d]: regrown question %d\n' "$i" "$i" >> "$CONVO"
    printf 'Assistant [2026-08-07 13:%02d]: REGROWN-REPLY-%d\n' "$i" "$i" >> "$CONVO"
done

OUT="$T/watch3.json"
curl -fsS -m 30 "${AUTH[@]}" \
    "http://127.0.0.1:$PORT/watch?wait=1&wakeseen=&since=$N&gen=$GEN" > "$OUT"
[ "$(jq_ "$OUT" 'doc.get("reset") is True' 2>/dev/null)" = True ] \
    && ok "the regrown conversation is a reset, not a slice of wrong turns" \
    || fail "the regrown conversation is a reset, not a slice of wrong turns" "$(head -c 200 "$OUT")"
grep -q 'REGROWN-REPLY-1' "$OUT" \
    && ok "the reset carries the whole regrown conversation" \
    || fail "the reset carries the whole regrown conversation" "$(head -c 300 "$OUT")"

echo "== plain appends still flow incrementally, no reset =="

mkconvo 3 steady
rm -f "$SUMMARY"
CTX="$T/ctx4.json"
curl -fsS -m 5 "${AUTH[@]}" "http://127.0.0.1:$PORT/context" > "$CTX"
N=$(jq_ "$CTX" 'doc["n"]')
GEN=$(jq_ "$CTX" 'doc.get("gen","")')

OUT="$T/watch4.json"
curl -fsS -m 30 "${AUTH[@]}" \
    "http://127.0.0.1:$PORT/watch?wait=1&wakeseen=&since=$N&gen=$GEN" > "$OUT" &
WPID=$!
sleep 1
printf 'User [2026-08-07 13:10]: appended question\n' >> "$CONVO"
printf 'Assistant [2026-08-07 13:10]: APPENDED-REPLY-CANARY\n' >> "$OUT.ignore" # decoy: not the convo
printf 'Assistant [2026-08-07 13:10]: APPENDED-REPLY-CANARY\n' >> "$CONVO"
wait "$WPID" 2>/dev/null

grep -q 'APPENDED-REPLY-CANARY' "$OUT" \
    && ok "an appended reply arrives on the held poll" \
    || fail "an appended reply arrives on the held poll" "$(head -c 300 "$OUT")"
[ "$(jq_ "$OUT" 'doc.get("reset", False) is False' 2>/dev/null)" = True ] \
    && ok "an append is not a reset" \
    || fail "an append is not a reset" "$(head -c 200 "$OUT")"
COUNT=$(jq_ "$OUT" 'len(doc["turns"])')
[ "$COUNT" = 2 ] \
    && ok "only the new turns are delivered ($COUNT)" \
    || fail "only the new turns are delivered" "got $COUNT turns"

echo "== a gen-less client (an old cached page) keeps the old snap behaviour =="

OUT="$T/watch5.json"
curl -fsS -m 30 "${AUTH[@]}" \
    "http://127.0.0.1:$PORT/watch?wait=0&wakeseen=&since=999" > "$OUT"
[ "$(jq_ "$OUT" 'doc.get("reset", False) is False' 2>/dev/null)" = True ] \
    && ok "no gen sent, no reset forced" \
    || fail "no gen sent, no reset forced" "$(head -c 200 "$OUT")"
