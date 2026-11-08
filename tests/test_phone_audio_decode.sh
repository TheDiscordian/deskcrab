#!/bin/bash
# The phone is never handed a clip the browser will refuse to decode.
# Run: bash tests/test_phone_audio_decode.sh
#
# On 2026-08-15 the phone showed "audio could not be decoded" instead of a
# voice. A clip can arrive and still be unplayable: synth_opus used to judge
# its output by size alone, so an ffmpeg that died mid-write (non-zero
# status, plausible bytes on disk) or an output with no decodable stream in
# it was called a success and served — and the browser, quite rightly,
# refused it.
#
# specs/speech-output.md rule 53 (as amended) and specs/phone.md rule 18 are
# the contract this holds:
#
#   a successful synth    probes as exactly one opus audio stream in an Ogg
#                         container with a non-zero duration, and the /audio/
#                         route serves those bytes under a Content-Type that
#                         names them (audio/ogg).
#   a failed ffmpeg       fails the clip, whatever size it left on disk, with
#                         the exit status and stderr in the speech log, and
#                         leaves no file to be served.
#   husk or garbage       zero-length output and plausible-sized bytes with
#                         no decodable stream both fail the clip the same way.
#
# Both synth paths are driven for real: the primary path (`crab synth`, the
# exact argv serve.py's Speaker thread runs per sentence) and the fallback
# path (the whole-reply clip a real `crab remote` turn synthesises, phone.md
# rule 6), with claude stubbed and ffmpeg mode-switched between the real
# encoder and the failure shapes.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"
LOG="$SANDBOX/state/deskcrab-speech.log"

SERVER_PID=""
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

# The real encoder and prober. The sandbox's default stub directory sits at
# the head of PATH and carries an ffmpeg and an ffprobe of its own, so a bare
# `command -v` here answers with the stub — and a stub that execs "the real
# one" would exec itself forever. Looked up past the stub directory instead.
FFMPEG_REAL="$(PATH="${PATH#"$SANDBOX_BIN":}" command -v ffmpeg || true)"
FFPROBE_REAL="$(PATH="${PATH#"$SANDBOX_BIN":}" command -v ffprobe || true)"
[ -n "$FFMPEG_REAL" ] && [ -x "$FFMPEG_REAL" ] \
    && [ -n "$FFPROBE_REAL" ] && [ -x "$FFPROBE_REAL" ] \
    || sandbox_skip "no real ffmpeg/ffprobe on this box"
export FFMPEG_REAL FFPROBE_REAL

# synth_opus's read-back probe must see the real prober, not the default
# stub, in every mode: the bytes are real (or really broken) either way.
sandbox_stub ffprobe <<'EOF'
#!/bin/sh
exec "${FFPROBE_REAL:?}" "$@"
EOF

# The synthesiser: a second of s16le samples, always healthy — the failures
# under test are the encoder's, not piper's (test_synth_witness owns those).
sandbox_stub piper-tts <<'EOF'
#!/bin/sh
cat > /dev/null
head -c 44100 /dev/zero
EOF

# The encoder, mode-switched by a file so one stub serves every case:
#   real     hand the whole job to the real ffmpeg
#   fail     die mid-write: plausible bytes on disk, non-zero exit, a reason
#            on stderr — the shape that used to be served anyway
#   husk     zero-length output, exit 0
#   garbage  5000 bytes of not-audio, exit 0 — big enough to pass the old
#            size test, undecodable by anything
FFMODE_FILE="$T/ffmode"
echo real > "$FFMODE_FILE"
export FFMODE_FILE
sandbox_stub ffmpeg <<'EOF'
#!/bin/sh
for a in "$@"; do out="$a"; done
case "$(cat "$FFMODE_FILE")" in
  fail)
    cat > /dev/null
    yes NOTAUDIO 2>/dev/null | head -c 4096 > "$out"
    echo "ffmpeg: Error while writing output — device wedged" >&2
    exit 1 ;;
  husk)
    cat > /dev/null
    : > "$out"
    exit 0 ;;
  garbage)
    cat > /dev/null
    yes NOTAUDIO 2>/dev/null | head -c 5000 > "$out"
    exit 0 ;;
  *)
    exec "${FFMPEG_REAL:?}" "$@" ;;
esac
EOF

# The stub claude, for the fallback-path turns: one text block, one result.
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *--output-format*)
        cat > /dev/null
        printf '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"A short reply worth hearing."}]}}\n'
        printf '{"type":"result"}\n'
        ;;
    *)
        cat > /dev/null
        printf '\n'
        ;;
esac
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$T"
LAST_ORIGIN_FILE="$T/last-origin"
PIPER_VOICE="$T/voice.onnx"
EOF

# synth <name> — synth_opus in a scratch instance, the unit under everything.
RC=0
synth() {
    RC=0
    sandbox_bash "synth_opus 'a sentence worth hearing' '$T/$1.opus'" \
        2>/dev/null || RC=$?
}
last() { tail -n 1 "$LOG" 2>/dev/null; }

# probe <file> — the real ffprobe's reading, one key=value per line.
probe() {
    "$FFPROBE_REAL" -v error \
        -show_entries stream=codec_name,codec_type:format=format_name,duration \
        -of default=noprint_wrappers=1 "$1" 2>/dev/null
}
probe_field() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -n 1; }

# --- (a) the good path: what a successful synth actually is ----------------
echo "== a successful synth probes as one opus stream in an Ogg container =="
echo real > "$FFMODE_FILE"
synth good
check_eq "the synth succeeds" "$RC" "0"
check "and the clip is on disk" test -s "$T/good.opus"
P="$(probe "$T/good.opus")"
check_eq "exactly one stream" \
    "$(printf '%s\n' "$P" | grep -c '^codec_type=')" "1"
check_eq "and it is an audio stream" \
    "$(printf '%s\n' "$P" | grep -c '^codec_type=audio$')" "1"
check_eq "its codec is opus" "$(probe_field codec_name "$P")" "opus"
check_eq "its container is ogg" "$(probe_field format_name "$P")" "ogg"
DUR="$(probe_field duration "$P")"
check "and its duration is non-zero" \
    awk -v d="${DUR:-0}" 'BEGIN { exit !(d > 0) }'

# --- (b) an ffmpeg failure yields no served clip and a logged status -------
echo "== a failed encode is withdrawn, with status and stderr in the log =="
echo fail > "$FFMODE_FILE"
synth failed
check "the clip fails with ffmpeg" [ "$RC" != 0 ]
check "and no file is left to be served" [ ! -e "$T/failed.opus" ]
L="$(last)"
check "the log carries ffmpeg's exit status" contains "$L" "ffmpeg rc=1"
check "and says the clip was withdrawn" contains "$L" "withdrawn"
check "and quotes ffmpeg's stderr" contains "$L" "Error while writing output"

# --- (c) zero-length and truncated outputs yield no served clip ------------
echo "== a zero-length output is not audio =="
echo husk > "$FFMODE_FILE"
synth husk
check "the empty file fails" [ "$RC" != 0 ]
check "and is not left behind as playable" [ ! -s "$T/husk.opus" ]

echo "== plausible-sized bytes with no decodable stream are not audio =="
echo garbage > "$FFMODE_FILE"
synth garbage
check "the undecodable clip fails" [ "$RC" != 0 ]
check "and no file is left to be served" [ ! -e "$T/garbage.opus" ]
L="$(last)"
check "the log says it did not probe as playable" contains "$L" "does not probe as playable"

# --- the primary path: crab synth, the Speaker thread's exact call ---------
echo "== the primary path hands over a good clip and refuses a bad one =="
echo real > "$FFMODE_FILE"
PRC=0; POUT="$("$REPO_DIR/crab" synth "$T/primary.opus" "a sentence worth hearing" 2>/dev/null)" || PRC=$?
check_eq "a real synthesis succeeds" "$PRC" "0"
check "and prints the clip path" contains "$POUT" "primary.opus"
check "and the clip probes as opus" \
    [ "$(probe_field codec_name "$(probe "$T/primary.opus")")" = opus ]

echo garbage > "$FFMODE_FILE"
PRC=0; POUT="$("$REPO_DIR/crab" synth "$T/primary-bad.opus" "a sentence worth hearing" 2>/dev/null)" || PRC=$?
check "an undecodable synthesis fails" [ "$PRC" != 0 ]
check_eq "and prints no path for the Speaker to emit" "$POUT" ""
check "and leaves no clip" [ ! -e "$T/primary-bad.opus" ]

# --- (d) the fallback path: the whole-reply clip of a real remote turn -----
# The reply clips of these turns land under the scratch instance's own
# REMOTE_AUDIO_PREFIX; the bad turns must leave nothing there at all.
clips() { ls "$SANDBOX/state/deskcrab-remote-"*.opus 2>/dev/null | wc -l; }
remote_audio() {
    printf '%s\n' "$1" | tail -n 1 | python3 -c \
        'import json,sys; print(json.loads(sys.stdin.read()).get("audio",""))'
}

echo "== the fallback path never offers a clip its own encoder failed =="
echo fail > "$FFMODE_FILE"
ROUT="$("$REPO_DIR/crab" remote "say something" 2>/dev/null)" || true
check_eq "the failed turn's completion carries no audio" \
    "$(remote_audio "$ROUT")" ""
check_eq "and no clip file was left to serve" "$(clips)" "0"
L="$(last)"
check "and the fallback failure logged ffmpeg's status" contains "$L" "ffmpeg rc=1"

echo "== nor a clip nothing can decode =="
echo garbage > "$FFMODE_FILE"
ROUT="$("$REPO_DIR/crab" remote "say something else" 2>/dev/null)" || true
check_eq "the undecodable turn's completion carries no audio" \
    "$(remote_audio "$ROUT")" ""
check_eq "and no clip file was left to serve" "$(clips)" "0"

echo "== and a good turn's fallback clip is real, playable audio =="
echo real > "$FFMODE_FILE"
ROUT="$("$REPO_DIR/crab" remote "say a third thing" 2>/dev/null)" || true
RAUDIO="$(remote_audio "$ROUT")"
check "the good turn's completion carries a clip" [ -n "$RAUDIO" ]
check "and the clip exists" test -s "$RAUDIO"
RP="$(probe "$RAUDIO")"
check_eq "and probes as one opus stream" \
    "$(probe_field codec_name "$RP")" "opus"
check_eq "in an ogg container" "$(probe_field format_name "$RP")" "ogg"

# --- what the phone is actually served: Content-Type versus the bytes ------
echo "== /audio/ names the bytes it serves: audio/ogg over an Ogg stream =="
SECRET="testsecret"
# A port nobody else is on; phone_live 18723 … voice_fallback 18727.
PORT=18728
DESKCRAB_SERVE_SECRET="$SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 \
DESKCRAB_CRAB_BIN="$T/no-crab-here" \
DESKCRAB_STATE_PREFIX="$T/deskcrab" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 100); do
    curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 \
    || die "the server never came up" "$(cat "$T/server.log")"

cp "$T/good.opus" "$TMPDIR/deskcrab-remote-decodeproof.opus"
CT_RC=0
curl -fsS -m 10 -H "X-Crab-Key: $SECRET" \
    -D "$T/hdrs" -o "$T/served.opus" \
    "http://127.0.0.1:$PORT/audio/deskcrab-remote-decodeproof.opus" || CT_RC=$?
check_eq "the clip is served" "$CT_RC" "0"
CTYPE="$(sed -n 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//p' "$T/hdrs" | tr -d '\r' | head -n 1)"
check_eq "under Content-Type audio/ogg" "$CTYPE" "audio/ogg"
check "the served bytes are the clip's bytes" cmp -s "$T/good.opus" "$T/served.opus"
SP="$(probe "$T/served.opus")"
check_eq "and they really are an Ogg container" \
    "$(probe_field format_name "$SP")" "ogg"
check_eq "holding an opus stream — the header matches the bytes" \
    "$(probe_field codec_name "$SP")" "opus"
