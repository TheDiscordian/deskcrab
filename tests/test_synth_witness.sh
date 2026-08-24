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

# The muxer: a real clip, the 137-byte header-only husk a dead synthesiser
# leaves, or no file at all — the shape the live failure actually took.
sandbox_stub ffmpeg <<'EOF'
#!/bin/sh
cat > /dev/null
for a in "$@"; do out="$a"; done
[ -n "${STUB_FF_NOFILE:-}" ] && { echo "ffmpeg: could not write output" >&2; exit 1; }
[ -n "${STUB_FF_HUSK:-}" ] && { head -c 137 /dev/zero > "$out"; exit 0; }
head -c 5000 /dev/zero > "$out"
[ -n "${STUB_FF_GRUMBLE:-}" ] && exit 69
exit 0
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

echo "== a grumbling muxer with a good clip stands, but is written down =="
export STUB_FF_GRUMBLE=1
synth grumble
check_eq "the clip is accepted" "$RC" "0"
L="$(last)"
check "the near-miss is logged" contains "$L" "ffmpeg rc=69"
check "and the line says the clip stands" contains "$L" "so it stands"
unset STUB_FF_GRUMBLE
