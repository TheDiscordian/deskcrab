#!/bin/bash
# The voice reading of a resay — specs/speech-output.md rule 58. Run:
# bash tests/test_claudism_voice.sh
#
# 2026-08-20 01:03: the flag log said two lines were caught at the gate and
# never spoken, and the user heard an assistant in both — the phrase was gone
# and the register had stayed, because the receipt was a detection stamp:
# whatever came back from the mirror call was spliced and logged `rewrite`.
# A phrase list cannot catch cadence; a SHAPE can be read. So the resay is
# read, deterministically, before it is spliced or logged: the slot refilled
# on a delete entry, a bare acknowledgement opener, report vocabulary the line
# did not carry, a sentence about its own wording — `flat`; a closing tag the
# line lacked and the draft already leans on — `costume`; everything else
# `kept`, a plain line as kept as any, because a jab is not voice.
#
# Then what the reading DOES, under the no-gate rule's three tests: on the
# whole-draft paths a flat resay buys exactly one more pass per turn and the
# second answer stands whatever it reads; at the desk the reading is recorded
# and nothing else happens; nothing is ever suppressed and no code writes a
# word. And rule 42a is held beside it: an error-only mirror stream still
# leaves the original standing, the row original-mirror-failed, no after.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
MIRROR="$REPO/lib/claudism-mirror"
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

reading() {  # <before> <after> <pattern> <fix> [draft] -> the voice word
    python3 -c 'import json,sys; print(json.dumps({"before": sys.argv[1], "after": sys.argv[2], "pattern": sys.argv[3], "fix": sys.argv[4], "draft": sys.argv[5]}))' \
        "$1" "$2" "$3" "$4" "${5:-}" \
        | "$MIRROR" voice | python3 -c 'import json,sys; print(json.load(sys.stdin).get("voice", ""))'
}
why() {  # the same, the why
    python3 -c 'import json,sys; print(json.dumps({"before": sys.argv[1], "after": sys.argv[2], "pattern": sys.argv[3], "fix": sys.argv[4], "draft": sys.argv[5]}))' \
        "$1" "$2" "$3" "$4" "${5:-}" \
        | "$MIRROR" voice | python3 -c 'import json,sys; print(json.load(sys.stdin).get("why", ""))'
}
HON='\bhonest(?:y|ly)?\b'

echo "the reading, on the recorded shapes (rule 58):"
check_eq "the slot refilled on a delete entry reads flat — her own 2026-08-09 verdict, the same coat with new buttons" \
    "$(reading 'the honest recovery, twenty minutes of my own reading.' 'the clean recovery, twenty minutes of my own reading.' "$HON" delete)" flat
check "and the why names the swap" \
    contains "$(why 'the honest recovery, twenty minutes.' 'the clean recovery, twenty minutes.' "$HON" delete)" "'honest' became 'clean'"
check_eq "the same swap on a resay entry is a plain-word repair and reads kept (jargon is cured by a plainer word)" \
    "$(reading 'So yes, the drain has been sending builders.' 'So yes, the overnight pass has been sending builders.' '\bthe drain\b' resay)" kept
check_eq "a deletion is the cure and reads kept" \
    "$(reading 'Wrote the honest version down for myself.' 'Wrote it down for myself.' "$HON" delete)" kept
check_eq "a resay that changed the sentence's subject reads kept (rule 56's repair)" \
    "$(reading 'Noted that in the moments file with the observation.' 'It went into the moments file with the observation.' '^\s*noted\b' resay)" kept
check_eq "a bare acknowledgement opener reads flat" \
    "$(reading "Noted, I won't give it another thought." 'Yes, I understand.' '^\s*noted\b' resay)" flat
check_eq "an acknowledgement the held line already opened on is not the resay's doing" \
    "$(reading 'Noted. The lamp is lit.' 'Noted. The lamp is lit, and the door is shut.' '\blamp\b' resay)" kept
check_eq "report vocabulary the line did not carry reads flat" \
    "$(reading 'To be honest the lamp is lit.' 'The lamp status is confirmed.' 'to be honest' delete)" flat
check_eq "report vocabulary the held line already carried is not introduced" \
    "$(reading 'To be honest the status is pending.' 'The status is pending.' 'to be honest' delete)" kept
check_eq "a sentence about her own wording reads flat (the 2026-10-20 19:46 defence)" \
    "$(reading 'Honestly, I am not building right now.' 'I am not building right now; my earlier wording made the work sound continuous.' "$HON" delete)" flat
check_eq "a closing tag the line lacked and the draft already leans on reads costume (rule 54's crutch, doubled)" \
    "$(reading 'To be honest, the beacon is green.' 'The beacon is green, I suppose.' 'to be honest' delete 'The lamp is lit, I suppose. To be honest, the beacon is green. The door is shut.')" costume
check_eq "the same tag with no other sentence of the draft leaning on it reads kept — nothing here knows a tic by name" \
    "$(reading 'To be honest, the beacon is green.' 'The beacon is green, I suppose.' 'to be honest' delete 'The lamp is lit. To be honest, the beacon is green.')" kept
check_eq "a plain line reads kept — a flourish is not voice and its absence is not flatness" \
    "$(reading 'To be honest, the beacon is green.' 'The beacon is green.' 'to be honest' delete)" kept
check_eq "a jab the held line itself carried stays with it, kept" \
    "$(reading 'Honestly, you really are hopeless.' 'You really are hopeless.' "$HON" delete)" kept
check_eq "an empty resay has nothing to read" "$(reading 'Honestly, x.' '' "$HON" delete)" kept
check_eq "garbage on stdin prints nothing and exits 2 — the caller reads no reading" \
    "$(printf 'not json' | "$MIRROR" voice; echo "rc=$?")" "rc=2"

# --- the whole-draft path, through the real caller ----------------------------
echo
echo "the whole-draft path: a flat resay buys exactly one second pass (rules 44 and 58):"
LIST="$T/claudisms.md"
cat > "$LIST" <<'LIST'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed of her anyway.
- function: vouching
- fix: delete
LIST
MODE="$T/stub-mode"
cat > "$T/claude-stub" <<STUB
#!/bin/bash
# The mirror call, stubbed. The second pass is told apart by its own system
# prompt (the caller quotes the first resay under "Second pass"); the mode
# file says what kind of resay comes back.
cat > /dev/null
case "\$*" in *"Second pass"*) PASS=2 ;; *) PASS=1 ;; esac
printf 'CALL pass=%s\n' "\$PASS" >> "$T/calls"
printf '%s' "\$*" > "$T/argv-\$PASS"
case "\$(cat "$MODE" 2>/dev/null):\$PASS" in
    flat-then-good:1|flat-flat:*) REPLY='The clean recovery took twenty minutes.' ;;
    flat-then-good:2|good:*)      REPLY='Twenty minutes of my own reading got the piece back.' ;;
    error:*)
        printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","id":"msg_err","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]},"is_api_error_message":true}'
        printf '%s\n' '{"type":"result","result":"Failed to authenticate: OAuth session expired and could not be refreshed","is_error":true}'
        exit 0 ;;
    *) REPLY='stub reply.' ;;
esac
python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":sys.argv[1]}]}})); print(json.dumps({"type":"result","result":sys.argv[1]}))' "\$REPLY"
STUB
chmod +x "$T/claude-stub"
DRAFT='The honest recovery took twenty minutes. The rest is plain.'
direct() {  # <mode> <flags-dir> [draft]
    printf '%s' "$1" > "$MODE"; : > "$T/calls"; rm -f "$T"/argv-*
    CLAUDE_BIN="$T/claude-stub" CLAUDISMS_FILE="$LIST" CLAUDISM_FLAGS_DIR="$2" \
        SPEECH_LOG="$T/speech.log" \
        sandbox_bash 'claudism_mirror_direct phone "'"${3:-$DRAFT}"'"'
}
calls() { grep -c '^CALL' "$T/calls" 2>/dev/null || echo 0; }
second_passes() { grep -c '^CALL pass=2' "$T/calls" 2>/dev/null || echo 0; }
row() { cat "$1"/*.jsonl 2>/dev/null; }

OUT="$(direct flat-then-good "$T/flags-a")"
check_eq "two mirror calls: the resay, then the second pass" "$(calls)" 2
check_eq "and the second carries the first resay under its own banner" "$(second_passes)" 1
check "the second pass quotes the flat resay back to her" \
    contains "$(cat "$T/argv-2")" 'The clean recovery took twenty minutes.'
check "and names the reading" contains "$(cat "$T/argv-2")" 'the slot was refilled'
check "the second answer is what is delivered" contains "$OUT" 'Twenty minutes of my own reading got the piece back.'
refute "not the flat one" contains "$OUT" 'clean recovery'
refute "and not the original" contains "$OUT" 'honest recovery'
check "the rest of the draft is untouched" contains "$OUT" 'The rest is plain.'
R="$(row "$T/flags-a")"
check "one row, outcome rewrite" contains "$R" '"outcome": "rewrite"'
check "the row carries the final reading" contains "$R" '"voice": "kept"'
check "and that the line was resaid twice" contains "$R" '"resays": 2'
check "after is the second answer (rule 51)" contains "$R" '"after": "Twenty minutes of my own reading got the piece back."'
check "the speech log says the first resay read flat and bought one more pass" \
    contains "$(cat "$T/speech.log")" 'read flat'
check "and the final line says voice kept, resays 2" contains "$(cat "$T/speech.log")" 'voice kept, resays 2'

OUT="$(direct good "$T/flags-b")"
check_eq "a kept resay buys no second call" "$(calls)" 1
R="$(row "$T/flags-b")"
check "its row reads kept" contains "$R" '"voice": "kept"'
refute "and carries no resays count — once, as ever" contains "$R" '"resays"'

OUT="$(direct flat-flat "$T/flags-c")"
check_eq "two flat resays: two calls and no third" "$(calls)" 2
check "the second answer stands even flat — nothing is suppressed" contains "$OUT" 'The clean recovery took twenty minutes.'
refute "the original phrase is gone" contains "$OUT" 'honest recovery'
R="$(row "$T/flags-c")"
check "the row says so: voice flat" contains "$R" '"voice": "flat"'
check "with the why" contains "$R" 'the slot was refilled'
check "and resays 2" contains "$R" '"resays": 2'

printf '%s' flat-flat > "$MODE"; : > "$T/calls"
OUT="$(CLAUDE_BIN="$T/claude-stub" CLAUDISMS_FILE="$LIST" CLAUDISM_FLAGS_DIR="$T/flags-d" \
    CLAUDISM_VOICE_RESAY=0 SPEECH_LOG="$T/speech.log" \
    sandbox_bash 'claudism_mirror_direct phone "'"$DRAFT"'"')"
check_eq "CLAUDISM_VOICE_RESAY=0 keeps the reading and drops the second pass" "$(calls)" 1
R="$(row "$T/flags-d")"
check "the row still reads flat" contains "$R" '"voice": "flat"'
refute "with no resays count" contains "$R" '"resays"'

TWO='The honest recovery took twenty minutes. Honestly, the rest is plain.'
OUT="$(direct flat-flat "$T/flags-e" "$TWO")"
check_eq "two fires in one turn: the second pass is paid once — three calls, not four" "$(calls)" 3
check_eq "exactly one second pass" "$(second_passes)" 1
check_eq "two rows" "$(row "$T/flags-e" | grep -c '"outcome": "rewrite"')" 2
check_eq "one of them resaid twice" "$(row "$T/flags-e" | grep -c '"resays": 2')" 1

echo
echo "rule 42a beside it: an error-only mirror stream is still no rewrite:"
OUT="$(direct error "$T/flags-f")"
check_eq "the draft goes out exactly as written" "$OUT" "$DRAFT"
refute "the CLI's error text reaches the reply nowhere" contains "$OUT" 'Failed to authenticate'
check_eq "one call, no second pass on nothing" "$(calls)" 1
R="$(row "$T/flags-f")"
check "the row reads original-mirror-failed" contains "$R" '"outcome": "original-mirror-failed"'
refute "never rewrite" contains "$R" '"outcome": "rewrite"'
refute "no after" contains "$R" '"after"'
refute "and no voice — there was no resay to read" contains "$R" '"voice"'

# --- the desk: recorded, never acted on ----------------------------------------
echo
echo "the desk path: the reading is recorded and buys nothing (rules 46 and 58):"
FIRES="$T/desk-fires.jsonl"
printf '%s\n' '{"seq": 1, "sentence": "The honest recovery took twenty minutes.", "pattern": "\\bhonest(?:y|ly)?\\b", "note": "the honesty family", "function": "vouching", "fix": "delete", "use": "use"}' > "$FIRES"
# A stand-in for the streamer: the moment the verdict lands, it records the
# rewrite as spoken, exactly as the real one does.
( for _ in $(seq 150); do
      if [ -f "$FIRES.verdict-1" ]; then
          printf '{"seq": 1, "outcome": "rewrite-spoken"}\n' >> "$FIRES"; sleep 2; exit 0
      fi
      sleep 0.1
  done ) &
HELPER=$!
printf '%s' flat-flat > "$MODE"; : > "$T/calls"
OUT="$(CLAUDE_BIN="$T/claude-stub" CLAUDISMS_FILE="$LIST" CLAUDISM_FLAGS_DIR="$T/flags-desk" \
    SPEECH_LOG="$T/speech-desk.log" \
    sandbox_bash '_CLAUDISM_FIRES_FILE="'"$FIRES"'" _TTS_STREAMER_PID='"$HELPER"' CLAUDISM_DESK_WAIT=15 claudism_mirror_desk "'"$DRAFT"'"')"
wait "$HELPER" 2>/dev/null
check_eq "one mirror call — the hold's budget admits no second" "$(calls)" 1
check "the flat resay was spoken and committed as rule 41 says" contains "$OUT" 'The clean recovery took twenty minutes.'
check "the verdict handed to the streamer was the rewrite" contains "$(cat "$FIRES.verdict-1" 2>/dev/null)" '"action": "rewrite"'
R="$(row "$T/flags-desk")"
check "the row reads rewrite" contains "$R" '"outcome": "rewrite"'
check "and records the reading: flat" contains "$R" '"voice": "flat"'
refute "with no resays count" contains "$R" '"resays"'
check "the speech log carries the reading" contains "$(cat "$T/speech-desk.log")" 'voice flat'
