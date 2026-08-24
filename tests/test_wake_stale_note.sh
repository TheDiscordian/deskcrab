#!/usr/bin/env bash
# A held note is a claim about a moment, and the moment can pass in the queue.
#
# specs/wake-queue.md rule 27b. 2026-08-15: the user was told live at 00:48
# that the chess game was won; a note written mid-conversation was held for
# the hot conversation and re-fired at 01:19, announcing the same win as
# fresh news, with three more stale notes queued behind it. The hold judged
# only HEAT — is the conversation busy — and nothing ever compared the note
# to what had been said while it waited.
#
#    1. the hold stamps the comeback's reason with a parseable held-at moment
#    2. a stamped note the intervening exchange already covered is DROPPED:
#       nothing spoken, shown, notified or appended; the wake session never
#       runs; the drop lands on the journal, the wake ledger and the trace;
#       and the judge demonstrably received both the note and the exchange
#    3. a note about something never mentioned since is SAID, and delivered
#    4. no turns since the stamp means the judge is never invoked
#    5. a judge that fails delivers the note and logs the failure plainly
#    6. an unstamped reason never arms the gate (proved inside case 1: that
#       wake's own reason carries no stamp, and the judge count stays zero)
#
# Everything is stubbed and confined to the sandbox.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"
CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
JOURNAL="${DESKCRAB_STATE_PREFIX}-sessions.log"
STALELOG="${DESKCRAB_STATE_PREFIX}-stale-check.log"
LEDGER="$WAKES_DIR/ledger.log"
CALLS="$WORK/claude-calls.txt"

# One claude stub, two hands: the staleness judge is told apart from the wake
# session by the model on its own argv — the conf below pins both names. The
# judge branch records the prompt it was handed, so the test can prove the
# note and the intervening exchange actually reached it; its verdict comes
# from $WORK/judge-mode (drop / say / fail). The wake branch answers with
# whatever reply $WORK/wake-reply.txt holds.
sandbox_stub claude <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/argv.txt"
case "\$*" in
    *claude-fable-5*)
        echo judge >> "$CALLS"
        cat > "$WORK/judge-prompt.txt"
        MODE="\$(cat "$WORK/judge-mode" 2>/dev/null || echo say)"
        case "\$MODE" in
            fail) exit 1 ;;
            drop) TEXT="DROP: he was told about the win at 00:48, in those words" ;;
            *)    TEXT="SAY: nothing since touches this — it is still news" ;;
        esac
        ;;
    *)
        echo wake >> "$CALLS"
        cat > /dev/null
        TEXT="\$(cat "$WORK/wake-reply.txt" 2>/dev/null || echo '(quiet) a stub thought')"
        ;;
esac
python3 - "\$TEXT" <<'PYEOF'
import json, sys
text = sys.argv[1]
print(json.dumps({"type": "assistant",
                  "message": {"model": "stub",
                              "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result", "result": text}))
PYEOF
EOF

sandbox_stub piper-tts <<EOF
#!/usr/bin/env bash
cat >> "$WORK/spoken.txt"
EOF
sandbox_stub render-md <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/displayed.txt"
EOF
sandbox_stub notify-send <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/notified.txt"
EOF

printf '# Wants\n\n- **a want**, so the wake path is enabled at all\n' > "$WORK/wants.md"

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$WORK"
WANTS_FILE="$WORK/wants.md"
PIPER_VOICE="$WORK/voice.onnx"
LAST_ORIGIN_FILE="$WORK/last-origin"
WAKE_QUIET_HOURS=""
CONVO_HOT_WINDOW=120
WAKE_HOT_RETRY=300
WAKE_MODEL="stub-wake"
WAKE_STALE_MODEL="claude-fable-5"
WAKE_STALE_TIMEOUT=30
EOF

he_spoke_at() {  # <seconds ago>
    printf 'desk\t%s\n' "$(( $(date +%s) - $1 ))" > "$WORK/last-origin"
}

# A held comeback's reason, exactly as wake_hold_for_heat books it.
HELD_PREFIX="You had this to say while he was mid-conversation and it was held:"
held_reason() {  # <note> <stamp>
    printf '%s %s — held at %s; the conversation has had a chance to cool since. Say it now if it still stands, and let it go if it does not.' \
        "$HELD_PREFIX" "$1" "$2"
}

# One day-journal fixture per case, so one case's own journal entries can
# never leak into the next case's evidence window.
journal_entry() {  # <dir> <epoch> <kind> <user> <reply> [outcome]
    mkdir -p "$1"
    python3 - "$@" <<'PYEOF'
import json, os, sys, time
d, epoch, kind, user, reply = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
obj = {"epoch": epoch,
       "time": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(epoch)),
       "kind": kind, "duration": 5, "user": user, "reply": reply, "pid": 1}
if len(sys.argv) > 6 and sys.argv[6]:
    obj["outcome"] = sys.argv[6]
path = os.path.join(d, time.strftime("%Y-%m-%d", time.localtime(epoch)) + ".jsonl")
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(obj, ensure_ascii=False) + "\n")
PYEOF
}

fire() {  # <journal dir> <reason>
    rm -f "$WORK/spoken.txt" "$WORK/displayed.txt" "$WORK/notified.txt" \
        "$WORK/judge-prompt.txt" "$CALLS" "$CONVO"
    DAY_JOURNAL_DIR="$1" WAKE_REASON="$2" \
        "$REPO/crab" wake event "$2" "" hot-hold >/dev/null 2>&1 || true
}

calls_of() { sandbox_count_in "^$1\$" "$CALLS"; }

NOW="$(date +%s)"
STAMP_PAST="$(date -d "@$(( NOW - 900 ))" '+%Y-%m-%d %H:%M')"

echo "the hold stamps the comeback's reason with the moment the note was written:"
# The producing side, run through the real hold: a quiet note into a hot
# conversation books its comeback, and the booked reason now carries the
# stamp the fire-time gate parses back out. This wake's own agenda has no
# stamp, so it also proves an unstamped reason falls straight through the
# gate — the judge count stays zero.
printf '%s' say > "$WORK/judge-mode"
printf '(quiet) Won browser-006 — the rook pair did it.' > /dev/null
cat > "$WORK/wake-reply.txt" <<'EOF'
(quiet) Won browser-006 — the rook pair did it.
EOF
he_spoke_at 4
rm -f "$WAKES_DIR"/*.wake 2>/dev/null
fire "$WORK/journal-stamp" "chessweb: game browser-006 ended"
HELD_RECORD="$(grep -lF "while he was mid-conversation" "$WAKES_DIR"/*.wake 2>/dev/null | head -n1)"
check "a comeback wake was booked at all" [ -n "$HELD_RECORD" ]
BOOKED="$(cut -f3 "$HELD_RECORD" 2>/dev/null)"
if printf '%s' "$BOOKED" | grep -qE 'held at [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}'; then
    ok "and its reason carries a parseable held-at stamp"
else
    fail "the booked reason has no parseable stamp" "[$BOOKED]"
fi
contains "$BOOKED" "rook pair" \
    && ok "with the held words still on it" \
    || fail "the held words were lost from the reason" "[$BOOKED]"
check_eq "and the unstamped wake that produced it was never judged" "$(calls_of judge)" "0"

echo
echo "a note the intervening exchange already covered is dropped, silently to him:"
printf '%s' drop > "$WORK/judge-mode"
J="$WORK/journal-drop"
journal_entry "$J" "$(( NOW - 600 ))" desktop \
    "did we actually win that chess game in the end?" \
    "We won browser-006 — the rook pair finished it a few minutes ago."
he_spoke_at 600
fire "$J" "$(held_reason 'Won browser-006 — the rook pair did it.' "$STAMP_PAST")"
check "nothing was synthesized" [ ! -f "$WORK/spoken.txt" ]
check "no window was opened" [ ! -f "$WORK/displayed.txt" ]
check "no notification was raised" [ ! -f "$WORK/notified.txt" ]
check "and nothing was appended to the conversation" \
    bash -c '[ ! -s "$1" ]' _ "$CONVO"
check_eq "the judge was called exactly once" "$(calls_of judge)" "1"
check_eq "and the wake session never ran — the drop spared the whole model run" \
    "$(calls_of wake)" "0"

echo
echo "...and the judge demonstrably received the note and the exchange:"
check "the note's own words reached the judge" \
    grep -qF "rook pair did it" "$WORK/judge-prompt.txt"
check "his side of the intervening exchange reached the judge" \
    grep -qF "did we actually win" "$WORK/judge-prompt.txt"
check "her delivered reply reached the judge" \
    grep -qF "finished it a few minutes ago" "$WORK/judge-prompt.txt"

echo
echo "...and the drop is loud to the record:"
check "the sessions log names the stale drop" \
    bash -c 'tail -n1 "$1" | grep -q "stale — held note dropped unspoken"' _ "$JOURNAL"
check "with the judge's reason on the line" \
    bash -c 'tail -n1 "$1" | grep -q "told about the win at 00:48"' _ "$JOURNAL"
check "and the note's words, so the record keeps what he never heard" \
    bash -c 'tail -n1 "$1" | grep -q "rook pair"' _ "$JOURNAL"
check "the day journal carries the drop" \
    bash -c 'grep -q "held note dropped unspoken" "$1"/*.jsonl' _ "$J"
check "the wake ledger carries it as its own action" \
    grep -q "dropped-stale" "$LEDGER"
check "under the gate's own actor name" \
    bash -c 'grep "dropped-stale" "$1" | grep -q "stale-judge"' _ "$LEDGER"
check "and the trace log records the DROP" \
    grep -q "DROP:" "$STALELOG"

echo
echo "a note about something never mentioned since is said, and delivered:"
printf '%s' say > "$WORK/judge-mode"
cat > "$WORK/wake-reply.txt" <<'EOF'
The backup drive has started smelling of hot dust — worth a look tomorrow.
EOF
J="$WORK/journal-say"
journal_entry "$J" "$(( NOW - 600 ))" desktop \
    "how did the chess game go?" \
    "We won browser-006 in the end."
he_spoke_at 600
fire "$J" "$(held_reason 'The backup drive has started smelling of hot dust — worth a look.' "$STAMP_PAST")"
check_eq "the judge was consulted" "$(calls_of judge)" "1"
check_eq "and the wake session ran" "$(calls_of wake)" "1"
check "the reply was synthesized" [ -f "$WORK/spoken.txt" ]
check "with the words it meant to say" \
    grep -qF "smelling of hot dust" "$WORK/spoken.txt"
check "and it is in the conversation" grep -qF "hot dust" "$CONVO"
check "and the trace records the SAY" grep -q "SAY" "$STALELOG"

echo
echo "no turns since the stamp: the judge is never invoked:"
printf '%s' drop > "$WORK/judge-mode"   # would drop, if it were ever asked
cat > "$WORK/wake-reply.txt" <<'EOF'
(quiet) Still turning the browser-006 endgame over.
EOF
J="$WORK/journal-quiet"
# Everything in this journal predates the stamp — said BEFORE the note.
journal_entry "$J" "$(( NOW - 3600 ))" desktop \
    "anything on the chess front?" "Not yet — mid-game."
he_spoke_at 600
fire "$J" "$(held_reason 'Won browser-006 — the rook pair did it.' "$(date -d "@$NOW" '+%Y-%m-%d %H:%M')")"
check_eq "the judge was never called" "$(calls_of judge)" "0"
check "and no prompt was ever built for it" [ ! -f "$WORK/judge-prompt.txt" ]
check_eq "the wake session ran as it always did" "$(calls_of wake)" "1"
check "and the trace says why the judge stayed cold" \
    grep -q "nothing said since" "$STALELOG"

echo
echo "a judge that fails delivers the note rather than losing it:"
printf '%s' fail > "$WORK/judge-mode"
cat > "$WORK/wake-reply.txt" <<'EOF'
The held thought, said in a quiet minute at last.
EOF
J="$WORK/journal-fail"
journal_entry "$J" "$(( NOW - 600 ))" desktop \
    "you were saying?" "Half a thought — go on."
he_spoke_at 600
fire "$J" "$(held_reason 'A real note the judge must not eat.' "$STAMP_PAST")"
check_eq "the judge was attempted" "$(calls_of judge)" "1"
check_eq "and the wake session still ran" "$(calls_of wake)" "1"
check "the reply reached the speakers" \
    grep -qF "quiet minute at last" "$WORK/spoken.txt"
check "and the failure is logged plainly" \
    grep -q "staleness judge failed" "$STALELOG"
check "while nothing was ledgered as dropped" \
    bash -c '[ "$(grep -c "dropped-stale" "$1")" = "1" ]' _ "$LEDGER"

PASSED=0; [ -f "$SANDBOX/witness/passes" ] && PASSED=$(wc -l < "$SANDBOX/witness/passes")
FAILED=0; [ -f "$SANDBOX/witness/failures" ] && FAILED=$(wc -l < "$SANDBOX/witness/failures")
echo "== $SANDBOX_NAME: $PASSED passed, $FAILED failed"
[ ! -s "$SANDBOX/witness/failures" ]
