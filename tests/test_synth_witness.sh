#!/bin/bash
# A lost voice names its killer.
# Run: bash tests/test_synth_witness.sh
#
# specs/speech-output.md rule 53: when synth_opus decides there is no audio,
# the speech-log line carries piper's status, ffmpeg's status, missing-versus-
# too-small (with the size), and the tail of what the two processes wrote to
# stderr. Their stderr is muzzled everywhere else, so that one line is the only
# witness a silent turn ever gets — on 2026-08-08 two phone turns died here
# with piper exiting 0 and the file never created, and nothing had recorded
# ffmpeg's side.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

LOG="$SANDBOX/state/deskcrab-speech.log"

# The synthesiser: a wall of samples, or a death with a reason on stderr.
sandbox_stub piper-tts <<'EOF'
#!/bin/sh
cat > /dev/null
[ -n "${STUB_PIPER_FAIL:-}" ] && { echo "piper: model load failed" >&2; exit 3; }
head -c 100000 /dev/zero
EOF

# The muxer: the real encoder for the good path — rule 53's read-back probe
# means a "good clip" must actually BE one now, and only the real ffmpeg can
# write bytes that probe as Ogg Opus — or the 137-byte header-only husk a
# dead synthesiser leaves, or no file at all, or a death mid-write: the
# shapes the live failures actually took.
# Looked up PAST the sandbox's stub directory: the default stub set carries
# an ffmpeg of its own, and a stub execing "the real one" found at the head
# of PATH would exec itself forever.
FFMPEG_REAL="$(PATH="${PATH#"$SANDBOX_BIN":}" command -v ffmpeg || true)"
FFPROBE_REAL="$(PATH="${PATH#"$SANDBOX_BIN":}" command -v ffprobe || true)"
[ -n "$FFMPEG_REAL" ] && [ -n "$FFPROBE_REAL" ] \
    || sandbox_skip "no real ffmpeg/ffprobe on this box"
export FFMPEG_REAL FFPROBE_REAL
# Rule 53's read-back probe needs the real prober too — the default ffprobe
# stub answers nothing, which would fail even an honest clip.
sandbox_stub ffprobe <<'EOF'
#!/bin/sh
exec "${FFPROBE_REAL:?}" "$@"
EOF
sandbox_stub ffmpeg <<'EOF'
#!/bin/sh
for a in "$@"; do out="$a"; done
[ -n "${STUB_FF_NOFILE:-}" ] && { cat > /dev/null; echo "ffmpeg: could not write output" >&2; exit 1; }
[ -n "${STUB_FF_HUSK:-}" ] && { cat > /dev/null; head -c 137 /dev/zero > "$out"; exit 0; }
[ -n "${STUB_FF_GRUMBLE:-}" ] && { cat > /dev/null; head -c 5000 /dev/zero > "$out"; exit 69; }
exec "${FFMPEG_REAL:?}" "$@"
EOF

# synth <name> — runs synth_opus in a scratch instance. RC is its status; the
# assertions read the speech log on disk, which is written outside the library
# call and outlives it.
RC=0
synth() {
    RC=0
    sandbox_bash "synth_opus 'a sentence worth hearing' '$SANDBOX/tmp/$1.opus'" \
        2>/dev/null || RC=$?
}
last() { tail -n 1 "$LOG" 2>/dev/null; }
logged() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }

echo "== a clip that plays is a success, and says nothing =="
BEFORE=$(logged)
synth good
check_eq "a real clip synthesises" "$RC" "0"
check "and the file is there" test -s "$SANDBOX/tmp/good.opus"
check_eq "and the speech log is not troubled" "$(logged)" "$BEFORE"

echo "== the header-only husk is not audio, and says its size =="
export STUB_FF_HUSK=1
synth husk
check "the husk fails" [ "$RC" != 0 ]
L="$(last)"
check "the line names piper's status" contains "$L" "piper rc=0"
check "and ffmpeg's status" contains "$L" "ffmpeg rc=0"
check "and the size that decided it" contains "$L" "output 137 bytes"
unset STUB_FF_HUSK

echo "== the live failure: no file at all, and ffmpeg's side recorded =="
export STUB_FF_NOFILE=1
synth gone
check "a missing output fails" [ "$RC" != 0 ]
L="$(last)"
check "the line says missing, not a size" contains "$L" "output missing"
check "and carries ffmpeg's non-zero status" contains "$L" "ffmpeg rc=1"
check "and quotes what ffmpeg said" contains "$L" "could not write output"

echo "== a dead synthesiser is quoted too, alongside the muxer =="
export STUB_PIPER_FAIL=1
synth dead
check "a dead piper fails" [ "$RC" != 0 ]
L="$(last)"
check "piper's own status is carried" contains "$L" "piper rc=3"
check "and its words are in the line" contains "$L" "model load failed"
unset STUB_PIPER_FAIL STUB_FF_NOFILE

echo "== a grumbling muxer left a husk, and the husk is withdrawn =="
# Rule 53's turn: a non-zero ffmpeg status used to stand on size alone, and
# what that served was the plausible-sized clip the phone answered with
# "audio could not be decoded" (2026-08-15).
export STUB_FF_GRUMBLE=1
synth grumble
check "the failed encode fails the clip" [ "$RC" != 0 ]
L="$(last)"
check "the failure carries ffmpeg's status" contains "$L" "ffmpeg rc=69"
check "and the line says it was withdrawn" contains "$L" "withdrawn"
check "and the husk is not left to be served" [ ! -e "$SANDBOX/tmp/grumble.opus" ]
unset STUB_FF_GRUMBLE
