#!/bin/bash
# Tests for the living portrait's moving parts (specs/face.md, including the
# 2026-08-30 automatic-tier amendment): the cue-track function, the broker's
# layered state and full precedence ladder, turn-token staleness, the
# streamer's cue scheduling and per-sentence acting against a stub
# synthesiser, and the detached mood updater against a stub classifier. The
# web routes ride in test_chessweb.sh and test_openrsc_web.sh beside their
# servers.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"
export DESKCRAB_FACE_SOCKET="$T/face.sock"
export DESKCRAB_FACE_STATE="$T/face-state.json"

FB() { python3 "$REPO_DIR/lib/face-broker" "$@"; }

echo "the cue track — a pure function of the synthesiser's own record (rule 20):"

OUT="$(python3 "$REPO_DIR/lib/viseme_cues.py" 'həlˈoʊ wˈɜːld' 1.4)"
check "a track begins at zero and ends at rest" \
    bash -c 'python3 -c "
import json,sys
c=json.loads(sys.argv[1])
assert c[0][0]==0.0, c
assert c[-1][1]==\"rest\", c
assert any(v==\"round\" for _,v in c), c   # the oʊ and the w
" "$1"' _ "$OUT"
check_eq "the same inputs give the same track" \
    "$OUT" "$(python3 "$REPO_DIR/lib/viseme_cues.py" 'həlˈoʊ wˈɜːld' 1.4)"
check_eq "no audio means no lip movement (rule 21)" \
    "$(python3 "$REPO_DIR/lib/viseme_cues.py" 'həlˈoʊ' 0)" '[[0.0, "rest"]]'

echo
echo "the sentence-cue table — fixed, public, and only over her own words (rule 40):"
check "surprise and irritation match; plain sentences never do" \
    python3 -c "
import sys
sys.path.insert(0, '$REPO_DIR/lib')
import face_state
assert face_state.sentence_cue('Wow, that actually worked!') == 'startled'
assert face_state.sentence_cue('You did what?!') == 'startled'
assert face_state.sentence_cue('Ugh, the cache again.') == 'annoyed'
assert face_state.sentence_cue('The tests are green now.') is None
assert face_state.sentence_cue('') is None
"
check "the table has an off switch (DESKCRAB_FACE_SENTENCE_CUES=0)" \
    bash -c 'DESKCRAB_FACE_SENTENCE_CUES=0 python3 -c "
import sys
sys.path.insert(0, \"$0/lib\")
import face_state
assert face_state.sentence_cue(\"Wow!\") is None
"' "$REPO_DIR"

echo
echo "the broker — the precedence ladder of rule 43, her hand on top:"

check "an explicit expression is accepted and reported" \
    bash -c 'python3 "$0/lib/face-broker" caught | grep -q "caught accepted"' "$REPO_DIR"
check "the state answers with the expression standing" \
    bash -c 'python3 "$0/lib/face-broker" | grep -q "expression=caught"' "$REPO_DIR"
check "activity never erases an authored expression (rule 18)" \
    bash -c 'python3 "$0/lib/face-broker" activity considering >/dev/null
        python3 "$0/lib/face-broker" | grep -q "expression=caught"' "$REPO_DIR"
check "an allowlisted event cannot displace her explicit choice (rule 16)" \
    bash -c 'python3 "$0/lib/face-broker" event failed-action >/dev/null
        python3 "$0/lib/face-broker" | grep -q "expression=caught"' "$REPO_DIR"
check "an automatic flourish cannot displace her explicit choice (rule 16)" \
    bash -c 'python3 "$0/lib/face-broker" auto startled | grep -q "stands"
        python3 "$0/lib/face-broker" | grep -q "expression=caught"' "$REPO_DIR"
check "a mood lands underneath without unseating her hand (rules 41, 43)" \
    bash -c 'python3 "$0/lib/face-broker" mood pleased >/dev/null
        python3 "$0/lib/face-broker" | grep -q "expression=caught" \
        && python3 "$0/lib/face-broker" | grep -q "mood=pleased"' "$REPO_DIR"
check "explicit rest clears the record AND the mood (rule 18)" \
    bash -c 'python3 "$0/lib/face-broker" rest >/dev/null
        ! python3 "$0/lib/face-broker" | grep -q "mood="' "$REPO_DIR"
check "with nothing above it, considering shows the activity default (rule 39)" \
    bash -c 'python3 "$0/lib/face-broker" \
        | grep -q "expression=focused \[activity\]"' "$REPO_DIR"
check "activity resting shows resting — never a guessed mood (rule 4)" \
    bash -c 'python3 "$0/lib/face-broker" activity resting >/dev/null
        python3 "$0/lib/face-broker" | grep -q "expression=resting"' "$REPO_DIR"
check "with composure at rest the event mapping stands (rule 17)" \
    bash -c 'python3 "$0/lib/face-broker" event failed-action >/dev/null
        python3 "$0/lib/face-broker" | grep -q "expression=annoyed \[event\]"' "$REPO_DIR"
check "a routine failed action recovers far sooner than a meaningful event (rule 17)" \
    bash -c 'python3 "$0/lib/face-broker" status | python3 -c "
import json,sys
s=json.load(sys.stdin)
assert s[\"event_lifetimes\"][\"failed-action\"] == 8.0, s
assert s[\"event_lifetimes\"][\"failed-action\"] < s[\"event_lifetimes\"][\"game-win\"], s
"' "$REPO_DIR"
check "an automatic flourish cannot displace an event (rule 16)" \
    bash -c 'python3 "$0/lib/face-broker" auto pleased | grep -q "stands"' "$REPO_DIR"
check "a newer explicit choice supersedes the event (rule 16)" \
    bash -c 'python3 "$0/lib/face-broker" focused >/dev/null
        python3 "$0/lib/face-broker" | grep -q "expression=focused \[explicit\]"' "$REPO_DIR"
check "an unknown expression is refused, not guessed at (rule 13)" \
    bash -c '! python3 "$0/lib/face-broker" cheerful >/dev/null 2>&1' "$REPO_DIR"
check "an unknown mood is refused too" \
    bash -c '! python3 "$0/lib/face-broker" mood gleeful >/dev/null 2>&1' "$REPO_DIR"
FB rest >/dev/null
check "a mood alone shows when nothing outranks it (rule 43)" \
    bash -c 'python3 "$0/lib/face-broker" mood tired >/dev/null
        python3 "$0/lib/face-broker" | grep -q "expression=tired \[mood\]"' "$REPO_DIR"
FB rest >/dev/null
check "a mood record keeps its reason, source, and originating turn (rules 41, 42a)" \
    bash -c 'DESKCRAB_FACE_TURN=turn-cause python3 "$0/lib/face-broker" \
        mood pleased --reason "finishing the repair cleanly felt satisfying" \
        --source "RuneScape" --origin "desktop exchange" \
        --source-ref turn-cause >/dev/null
        python3 "$0/lib/face-broker" status | python3 -c "
import json,sys
s=json.load(sys.stdin)
assert s[\"mood_reason\"] == \"finishing the repair cleanly felt satisfying\", s
assert s[\"mood_source\"] == \"RuneScape\", s
assert s[\"mood_origin\"] == \"desktop exchange\", s
assert s[\"mood_source_ref\"] == \"turn-cause\", s
assert s[\"mood_record\"][\"reason\"] == s[\"mood_reason\"], s
"' "$REPO_DIR"
FB rest >/dev/null
check "an automatic flourish recovers by its own lifetime (rules 18, 40)" \
    bash -c 'python3 "$0/lib/face-broker" auto startled --for 1 >/dev/null
        python3 "$0/lib/face-broker" | grep -q "expression=startled \[auto\]" || exit 1
        sleep 1.3
        python3 "$0/lib/face-broker" | grep -q "expression=resting"' "$REPO_DIR"
check "a lifetime chosen at set time recovers on its own (rule 18)" \
    bash -c 'python3 "$0/lib/face-broker" pleased --for 1 >/dev/null
        sleep 1.3
        python3 "$0/lib/face-broker" | grep -q "expression=resting"' "$REPO_DIR"
check "the diagnostics name the allowlist, the tier, and the surfaces (rule 19)" \
    bash -c 'python3 "$0/lib/face-broker" status | grep -q "event_map" \
        && python3 "$0/lib/face-broker" status | grep -q "watchers" \
        && python3 "$0/lib/face-broker" status | grep -q "sentence_cues" \
        && python3 "$0/lib/face-broker" status | grep -q "activity_expressions" \
        && python3 "$0/lib/face-broker" status | grep -q "mood_seconds"' "$REPO_DIR"

echo
echo "OpenRSC reactions — confirmed bridge changes, no history replay (rule 56):"
GAME_STATE="$T/openrsc-state.json"
GAME_CURSOR="$T/openrsc-cursor.json"
cat >"$GAME_STATE" <<'EOF'
{"logged_in":true,"in_combat":false,"messages":[{"id":10,"channel":"game","incoming":false,"text":"old"}],"skills":[{"id":0,"level":4}],"quests":[{"id":1,"status":"started"}]}
EOF
check_eq "the first observation only seeds its cursor" \
    "$(DESKCRAB_GAME_STATE="$GAME_STATE" DESKCRAB_FACE_OPENRSC_CURSOR="$GAME_CURSOR" \
        "$REPO_DIR/lib/face-openrsc" --once)" ""
cat >"$GAME_STATE" <<'EOF'
{"logged_in":true,"in_combat":false,"messages":[{"id":10,"channel":"game","incoming":false,"text":"old"},{"id":11,"channel":"private","incoming":true,"sender":"Ryan","text":"hello"}],"skills":[{"id":0,"level":4}],"quests":[{"id":1,"status":"started"}]}
EOF
check_eq "a new incoming player message reaches the broker" \
    "$(DESKCRAB_GAME_STATE="$GAME_STATE" DESKCRAB_FACE_OPENRSC_CURSOR="$GAME_CURSOR" \
        "$REPO_DIR/lib/face-openrsc" --once)" "player-message"
check "the message visibly resolves as attentive" \
    bash -c 'python3 "$0/lib/face-broker" | grep -q "expression=attentive \[event\]"' "$REPO_DIR"
cat >"$GAME_STATE" <<'EOF'
{"logged_in":true,"in_combat":false,"messages":[{"id":12,"channel":"game","incoming":false,"text":"You cannot reach that"}],"skills":[{"id":0,"level":5}],"quests":[{"id":1,"status":"completed"}]}
EOF
check_eq "a completion outranks simultaneous refusal noise" \
    "$(DESKCRAB_GAME_STATE="$GAME_STATE" DESKCRAB_FACE_OPENRSC_CURSOR="$GAME_CURSOR" \
        "$REPO_DIR/lib/face-openrsc" --once)" "game-win"
check "the completion visibly resolves as pleased" \
    bash -c 'python3 "$0/lib/face-broker" | grep -q "expression=pleased \[event\]"' "$REPO_DIR"
FB rest >/dev/null; FB activity resting >/dev/null

echo
echo "turn tokens — a result computed for a finished turn never lands (rule 38):"
check "the turn machinery registers its token through activity" \
    bash -c 'DESKCRAB_FACE_TURN=turn-live python3 "$0/lib/face-broker" \
        activity considering >/dev/null
        python3 "$0/lib/face-broker" status | grep -q "turn-live"' "$REPO_DIR"
check "a stale automatic flourish is turned away, state untouched" \
    bash -c 'DESKCRAB_FACE_TURN=turn-old python3 "$0/lib/face-broker" \
        auto pleased | grep -q "stale" \
        && python3 "$0/lib/face-broker" | grep -q "expression=focused \[activity\]"' "$REPO_DIR"
check "a stale mood is turned away the same" \
    bash -c 'DESKCRAB_FACE_TURN=turn-old python3 "$0/lib/face-broker" \
        mood annoyed | grep -q "stale" \
        && ! python3 "$0/lib/face-broker" | grep -q "mood="' "$REPO_DIR"
check "the current turn's own result lands" \
    bash -c 'DESKCRAB_FACE_TURN=turn-live python3 "$0/lib/face-broker" \
        mood pleased >/dev/null
        python3 "$0/lib/face-broker" | grep -q "mood=pleased"' "$REPO_DIR"
FB rest >/dev/null; FB activity resting >/dev/null

echo
echo "decay and disable switches — nothing automatic is permanent (rules 39, 41):"
DK_SOCK="$T/face-decay.sock"
check "an unrefreshed mood decays on the broker's own clock" \
    bash -c 'export DESKCRAB_FACE_SOCKET="$1" DESKCRAB_FACE_STATE="$2" \
        DESKCRAB_FACE_MOOD_SECONDS=1
        python3 "$0/lib/face-broker" mood annoyed >/dev/null
        sleep 1.3
        python3 "$0/lib/face-broker" | grep -q "expression=resting"' \
    "$REPO_DIR" "$DK_SOCK" "$T/face-decay-state.json"
AM_SOCK="$T/face-actmap.sock"
check "an emptied activity map moves nothing (rule 39)" \
    bash -c 'export DESKCRAB_FACE_SOCKET="$1" DESKCRAB_FACE_STATE="$2" \
        DESKCRAB_FACE_ACTIVITY_EXPRESSIONS=
        python3 "$0/lib/face-broker" activity considering >/dev/null
        python3 "$0/lib/face-broker" | grep -q "expression=resting"' \
    "$REPO_DIR" "$AM_SOCK" "$T/face-actmap-state.json"

echo
echo "the disabled allowlist — mappings are hers to turn off (rule 17):"
DIS_SOCK="$T/face-dis.sock"
check "a disabled event moves nothing" \
    bash -c 'export DESKCRAB_FACE_SOCKET="$1" DESKCRAB_FACE_STATE="$2" \
        DESKCRAB_FACE_EVENTS=""
        python3 "$0/lib/face-broker" event failed-action | grep -q "disabled" \
        && python3 "$0/lib/face-broker" | grep -q "expression=resting"' \
    "$REPO_DIR" "$DIS_SOCK" "$T/face-dis-state.json"

echo
echo "speech clips — scheduled with cues, cleared on stop (rules 21-23):"
python3 - "$REPO_DIR" <<'PY'
import json, subprocess, sys, time
sys.path.insert(0, sys.argv[1] + "/lib")
import face_state
r = face_state.send_cmd({"cmd": "speak", "clips": [
    {"id": "t1", "start": time.time(), "duration": 3.0,
     "cues": [[0, "slight"], [0.4, "open"], [2.8, "rest"]]}]})
assert r and r["ok"] and r["state"]["speaking"], r
assert r["state"]["clips"][0]["cues"][1] == [0.4, "open"], r
bad = face_state.send_cmd({"cmd": "speak", "clips": [
    {"id": "t2", "start": time.time(), "duration": 1.0,
     "cues": [[0, "grin"]]}]})
assert bad["ok"] and bad["state"]["clips"][-1]["cues"] == [], bad
r = face_state.send_cmd({"cmd": "speak-stop"})
assert r["ok"] and not r["state"]["speaking"] and r["state"]["clips"] == [], r
print("clip lifecycle holds")
PY
[ $? -eq 0 ] && ok "clips carry cues, unknown shapes are dropped, stop clears now" \
    || fail "clip lifecycle" "see above"

echo
echo "the streamer's cue plumbing — armed only by the socket (rules 29-30, 40):"

# A stub synthesiser that speaks the real one's debug dialect on stderr
# (verified 2026-08-30 against piper's actual --debug output).
sandbox_stub piper-tts <<'EOF'
#!/usr/bin/env bash
DEBUG=0
for a in "$@"; do [ "$a" = "--debug" ] && DEBUG=1; done
while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\tSAY\t%s\n' "$(date +%s.%N)" "$line" >> "$TRACE"
    if [ "$DEBUG" = 1 ]; then
        printf '[piper] [debug] Converting 5 phoneme(s) to ids: h@l"oU\n' >&2
        printf '[piper] [debug] Synthesized 1.500 second(s) of audio in 0.1 second(s)\n' >&2
    fi
    head -c 2048 /dev/zero
done
EOF

run_streamer() {  # <name> <spoken sentence> <extra-env...>
    LOG="$T/$1.log"; TRACE="$T/$1.trace"
    : > "$LOG"; : > "$TRACE"
    python3 - "$LOG" "$2" <<'PY'
import json, sys
lines = [
    {"type": "assistant", "message": {"model": "m", "content":
        [{"type": "text", "text": sys.argv[2]}]}},
    {"type": "result", "result": "x"},
]
with open(sys.argv[1], "w") as fh:
    for d in lines:
        fh.write(json.dumps(d) + "\n")
PY
    shift 2
    TRACE="$TRACE" DESKCRAB_DEBUGLOG="$LOG" DESKCRAB_PIPER_VOICE=/dev/null \
        DESKCRAB_SPEECHLOCK="$T/face-stream.speechlock" \
        DESKCRAB_SPEECH_LOG="$T/face-stream.speechlog" \
        DESKCRAB_SPEECH_RECEIPT="$T/face-stream.receipt" \
        DESKCRAB_VOICE_IDLE_CLOSE=2 \
        env "$@" bash -c '"$0/lib/tts-streamer" & wait' "$REPO_DIR" 2>/dev/null
}

run_streamer unarmed "Hello." DESKCRAB_FACE_SOCKET=
check "unarmed, the words still sound and no clips exist" \
    bash -c 'grep -q "SAY	Hello." "$1"' _ "$T/unarmed.trace"

run_streamer armed "Hello." DESKCRAB_FACE_SOCKET="$DESKCRAB_FACE_SOCKET"
check "armed, the words still sound identically (rule 30)" \
    bash -c 'grep -q "SAY	Hello." "$1"' _ "$T/armed.trace"
STATE_NOW="$(FB status)"
check "the drained burst closed the mouth (rule 23)" \
    bash -c 'printf %s "$1" | grep -q "\"speaking\": false"' _ "$STATE_NOW"
check "the broker heard the speaking presence (rule 15)" \
    bash -c 'printf %s "$1" | grep -q "\"activity\": \"speaking\""' _ "$STATE_NOW"
check "a plain sentence raised no flourish (rule 40)" \
    bash -c 'python3 "$0/lib/face-broker" | grep -q "expression=resting"' "$REPO_DIR"

# Per-sentence acting: the flourish rides the clip's own playback start
# (lead pinned to 0 so the stub's instant "audio" and the model agree), is
# sourced auto, and is bounded by clip length plus the linger.
run_streamer wow "Wow, that is a surprise!" \
    DESKCRAB_FACE_SOCKET="$DESKCRAB_FACE_SOCKET" \
    DESKCRAB_FACE_AUDIO_LEAD=0
check "her own exclamation acts on her face as the clip sounds (rule 40)" \
    bash -c 'python3 "$0/lib/face-broker" \
        | grep -q "expression=startled \[auto\]"' "$REPO_DIR"
check "…and the drain still closed the mouth underneath it (rule 23)" \
    bash -c 'python3 "$0/lib/face-broker" status \
        | grep -q "\"speaking\": false"' "$REPO_DIR"
FB rest >/dev/null

# A streamer that outlived its turn: its flourish carries the dead turn's
# token and must bounce off the broker (rule 38).
DESKCRAB_FACE_TURN=turn-current FB activity considering >/dev/null
run_streamer stale "Wow, that is a surprise!" \
    DESKCRAB_FACE_SOCKET="$DESKCRAB_FACE_SOCKET" \
    DESKCRAB_FACE_AUDIO_LEAD=0 \
    DESKCRAB_FACE_TURN=turn-finished
check "a stale streamer's flourish is turned away (rule 38)" \
    bash -c '! python3 "$0/lib/face-broker" | grep -q "startled" \
        && python3 "$0/lib/face-broker" | grep -q "expression=resting"' "$REPO_DIR"
FB rest >/dev/null; FB activity resting >/dev/null

echo
echo "the mood updater — detached, continuous, stale-proof, silent on failure (rule 42):"

# The classifier is the sandbox's own claude stub, taught to answer one word.
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep "${CLAUDE_STUB_SLEEP:-0}"
[ -n "${CLAUDE_STUB_RC:-}" ] && exit "$CLAUDE_STUB_RC"
echo "${CLAUDE_STUB_ANSWER:-neutral}"
EOF

FACE_AUTO_ENV=(FACE_ENABLED=1 FACE_AUTO_EXPRESSION=1
    DESKCRAB_FACE_SOCKET="$DESKCRAB_FACE_SOCKET")
check "a delivered exchange moves the standing mood" \
    bash -c 'env "$@" CLAUDE_STUB_ANSWER="$(printf "pleased\tfinishing the exchange well felt satisfying\tRuneScape rescue")" \
        "$0/lib/face-auto" --turn "" "hi" "That went beautifully." >/dev/null 2>&1
        python3 "$0/lib/face-broker" status | python3 -c "
import json,sys
s=json.load(sys.stdin)
assert s[\"mood\"] == \"pleased\", s
assert s[\"mood_reason\"] == \"finishing the exchange well felt satisfying\", s
assert s[\"mood_source\"] == \"RuneScape rescue\", s
assert s[\"mood_origin\"] == \"completed exchange\", s
"' \
    "$REPO_DIR" "${FACE_AUTO_ENV[@]}"
MOOD_SELF="$(sandbox_bash 'FACE_ENABLED=1; face_mood_report')"
contains "$MOOD_SELF" "How you feel: pleased" \
    && contains "$MOOD_SELF" "finishing the exchange well felt satisfying" \
    && contains "$MOOD_SELF" "source: RuneScape rescue" \
    && contains "$MOOD_SELF" "origin: completed exchange" \
    && ok "the self-state prompt carries the mood, why, and source (rule 42a)" \
    || fail "mood self-knowledge is missing from the state block" "$MOOD_SELF"
check "phone mood provenance names the phone origin, not the updater" \
    bash -c 'DESKCRAB_FACE_TURN=phone-cause python3 "$0/lib/face-broker" \
        activity considering >/dev/null
        env "$@" CLAUDE_STUB_ANSWER="focused<TAB>the call needed attention<TAB>phone conversation" \
        "$0/lib/face-auto" --turn phone-cause "hello" "I am listening." >/dev/null 2>&1
        python3 "$0/lib/face-broker" status | python3 -c "
import json,sys
s=json.load(sys.stdin)
assert s[\"mood_source\"] == \"phone conversation\", s
assert s[\"mood_origin\"] == \"phone exchange\", s
"' "$REPO_DIR" "${FACE_AUTO_ENV[@]}"
check "wake mood provenance names the wake origin, not the updater" \
    bash -c 'DESKCRAB_FACE_TURN=wake-cause python3 "$0/lib/face-broker" \
        activity considering >/dev/null
        env "$@" CLAUDE_STUB_ANSWER="attentive<TAB>the task needed care<TAB>scheduled work" \
        "$0/lib/face-auto" --turn wake-cause "check the task" "completed it" >/dev/null 2>&1
        python3 "$0/lib/face-broker" status | python3 -c "
import json,sys
s=json.load(sys.stdin)
assert s[\"mood_source\"] == \"scheduled work\", s
assert s[\"mood_origin\"] == \"autonomous wake\", s
"' "$REPO_DIR" "${FACE_AUTO_ENV[@]}"
check "neutral clears the mood rather than guessing one" \
    bash -c 'env "$@" CLAUDE_STUB_ANSWER=neutral \
        "$0/lib/face-auto" --turn "" "hi" "Noted." >/dev/null 2>&1
        ! python3 "$0/lib/face-broker" | grep -q "mood="' \
    "$REPO_DIR" "${FACE_AUTO_ENV[@]}"
check "an unparseable answer changes nothing (fail to resting, rule 42)" \
    bash -c 'env "$@" CLAUDE_STUB_ANSWER="pleased<TAB>the rescue succeeded<TAB>RuneScape" \
        "$0/lib/face-auto" --turn "" "hi" "Good." >/dev/null 2>&1
        env "$@" CLAUDE_STUB_ANSWER="who can say" \
        "$0/lib/face-auto" --turn "" "hi" "Hmm." >/dev/null 2>&1
        python3 "$0/lib/face-broker" | grep -q "mood=pleased"' \
    "$REPO_DIR" "${FACE_AUTO_ENV[@]}"
check "a failed classify changes nothing either" \
    bash -c 'env "$@" CLAUDE_STUB_RC=1 \
        "$0/lib/face-auto" --turn "" "hi" "Hmm." >/dev/null 2>&1
        python3 "$0/lib/face-broker" | grep -q "mood=pleased"' \
    "$REPO_DIR" "${FACE_AUTO_ENV[@]}"
check "a result for a finished turn is turned away (rule 38)" \
    bash -c 'DESKCRAB_FACE_TURN=turn-now python3 "$0/lib/face-broker" \
        activity considering >/dev/null
        env "$@" CLAUDE_STUB_ANSWER="$(printf "annoyed\tthe action failed\tcoding work")" \
        "$0/lib/face-auto" --turn turn-done "hi" "Ugh." >/dev/null 2>&1
        python3 "$0/lib/face-broker" | grep -q "mood=pleased"' \
    "$REPO_DIR" "${FACE_AUTO_ENV[@]}"

# The hook itself never waits: with the classifier held asleep, dispatch
# returns at once and the mood lands later, from the background (rule 37).
sandbox_systemd_rc 1   # force the setsid fallback so the child really runs
START_NS=$(date +%s%N)
sandbox_bash 'FACE_ENABLED=1 FACE_AUTO_EXPRESSION=1 \
    CLAUDE_STUB_SLEEP=3 CLAUDE_STUB_ANSWER="tired<TAB>the work was draining<TAB>coding work" \
    DESKCRAB_FACE_TURN= fire_face_mood "hi" "So tired tonight."' \
    >/dev/null 2>&1
ELAPSED_MS=$(( ($(date +%s%N) - START_NS) / 1000000 ))
[ "$ELAPSED_MS" -lt 2000 ] \
    && ok "fire_face_mood returns in ${ELAPSED_MS}ms while the classifier sleeps 3s (rule 37)" \
    || fail "fire_face_mood blocked" "${ELAPSED_MS}ms"
LANDED=0
for _ in $(seq 1 40); do
    FB 2>/dev/null | grep -q "mood=tired" && { LANDED=1; break; }
    sleep 0.3
done
[ "$LANDED" = 1 ] \
    && ok "…and the sleeping classifier's answer still lands afterwards" \
    || fail "background mood never landed" "$(FB status 2>/dev/null | head -40)"

for pidfile in "$DESKCRAB_FACE_SOCKET.pid" "$DIS_SOCK.pid" \
        "$DK_SOCK.pid" "$AM_SOCK.pid"; do
    [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null
done
true
