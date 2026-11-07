#!/bin/bash
# Shared viewing on the real clock — specs/watchalong.md rules 24–26 and the whole path:
# a reader loop advances in the background through a multi-minute private synthetic source
# while real `crab` turns (desk and phone doors) run through the stub CLI, and each turn's
# assembled prompt is kept and read back for the receipts it carried.
# Run: bash tests/test_watchalong_live.sh [--export <dir>]        (about four minutes of real clock)
#     --export <dir>  copies the prompts, packets, receipts, logs and a lineage index there at
#                     the end. An argument, because the sandbox re-executes the test under a
#                     clean environment and a variable would not survive the crossing.
#
# Nothing is played and nothing is spoken: the synthesiser and the players are the sandbox's
# witnesses, and the spoken witness is read back to prove the reader's notes never went to a
# synthesiser — they are context, not speech. The source is painted here; its every frame carries
# a block code the decoder reads from the pixels, and known sentences were synthesised to a file.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
EXPORT=""
[ "${1:-}" = "--export" ] && EXPORT="${2:-}"
for tool in /usr/bin/ffmpeg /usr/bin/ffprobe /usr/bin/whisper-cli /usr/bin/montage; do
    [ -x "$tool" ] || sandbox_skip "$tool is not installed; the fixture cannot be decoded"
done
python3 -c 'import PIL, numpy' 2>/dev/null || sandbox_skip "python3 PIL/numpy are not installed"

export DESKCRAB_FFMPEG=/usr/bin/ffmpeg DESKCRAB_FFPROBE=/usr/bin/ffprobe \
    DESKCRAB_WHISPER_CLI=/usr/bin/whisper-cli DESKCRAB_MONTAGE=/usr/bin/montage
export DESKCRAB_WATCHALONG_DIR="$T/data/deskcrab/watchalong"
unset WATCHALONG_CLOCK_FILE
WA() { python3 "$REPO/lib/watchalong" "$@"; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
status_json() { WA status --json > "$T/status.json"; }
sj() { jget "$T/status.json" "$1"; }
now() { date +%s; }
EV="$T/evidence"; mkdir -p "$EV/prompts"
PROMPTS="$EV/prompts"

VOICE="$(dirname "$SANDBOX_LIVE_DATA")/piper/en_US-lessac-medium.onnx"
[ -f "$VOICE" ] || VOICE=""
echo "painting the private fixture (300 s, 10 s scenes${VOICE:+, known speech to a file}):"
FX="$T/fixture"
python3 "$REPO/lib/watchalong_fixture.py" generate --out "$FX" --seconds 300 --scene-seconds 10 \
    --voice "$VOICE" --piper /usr/bin/piper-tts >/dev/null 2>&1
check "the fixture was written" test -s "$FX/fixture.mp4"
SPEECH="$(jget "$FX/fixture.json" "d['speech']")"
[ "$SPEECH" = True ] || echo "  note: no piper voice at $VOICE — tones only"

# The CLI stub: records argv, keeps the system prompt it was handed as this turn's artefact,
# answers with a fixed reply. The prompt file is the thing under test.
printf '%s' "Right, I'm here." > "$T/stub-reply.txt"
sandbox_stub claude <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX_CLAUDE_LOG"
n=\$(ls "$PROMPTS" | wc -l); n=\$((n+1))
prev=""
for a in "\$@"; do
    if [ "\$prev" = "--append-system-prompt" ]; then printf '%s' "\$a" > "$PROMPTS/turn-\$n.txt"; fi
    prev="\$a"
done
cat > /dev/null
python3 - <<'PYEOF'
import json
text = open("$T/stub-reply.txt", encoding="utf-8").read()
print(json.dumps({"type": "assistant", "message": {"model": "stub", "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result"}))
PYEOF
EOF

block_of() {  # <prompt file> — the viewing layer alone
    sed -n '/^SHARED VIEWING/,/asks for no narration/p' "$1"
}
turn() {  # <door> <message> -> prints the prompt file this turn produced
    local before after door="$1"; shift
    before="$(ls "$PROMPTS" | wc -l)"
    if [ "$door" = phone ]; then "$REPO/crab" remote "$*" </dev/null >/dev/null 2>&1 || true
    else "$REPO/crab" "$*" </dev/null >/dev/null 2>&1 || true; fi
    for _ in $(seq 1 80); do after="$(ls "$PROMPTS" | wc -l)"; [ "$after" -gt "$before" ] && break; sleep 0.25; done
    printf '%s' "$PROMPTS/turn-$after.txt"
}
wait_receipts() {  # <session> <epoch> <count> <seconds> — until that many receipts of that epoch exist
    local sid="$1" ep="$2" want="$3" limit="$4" i n
    for i in $(seq 1 $((limit * 2))); do
        n="$(ls "$DESKCRAB_WATCHALONG_DIR/sessions/$sid/receipts/" 2>/dev/null | grep -c "^e$(printf '%03d' "$ep")-")"
        [ "$n" -ge "$want" ] && return 0
        sleep 0.5
    done
    return 1
}

echo
echo "start, and the reader loop behind the conversation (rule 25):"
T0="$(now)"
WA start --source "$FX/fixture.mp4" --title "Fixture episode" \
    --authorized-by "the test harness at $(date +%H:%M:%S), synthetic source, nothing played" \
    --ttl 1200 --position 0 --quote "pressed play" >/dev/null
SID="$(cat "$DESKCRAB_WATCHALONG_DIR/current")"
check "a session is active" test -n "$SID"
WA reader --loop --reviewer fixture --interval 2 --min 12 --max 20 --log "$EV/reader.log" </dev/null >/dev/null 2>&1 &
RPID=$!
sandbox_at_exit "kill $RPID 2>/dev/null"
P1="$(turn desk "what's going on in this?")"
check "turn 1 ran through the real desk door and the CLI saw a prompt" test -s "$P1"
B1="$(block_of "$P1")"
check "its prompt carries the viewing layer" bash -c 'printf "%s" "$1" | grep -q "^SHARED VIEWING — you are watching Fixture episode with him"' _ "$B1"
check "which says NOTHING has been seen yet" bash -c 'printf "%s" "$1" | grep -q "What you have actually seen: NOTHING since his last anchor at 00:00.0"' _ "$B1"
check "and carries no reader notes" bash -c 'printf "%s" "$1" | grep -vq "READER NOTES"' _ "$B1"
check "and labels the position an estimate from his words" bash -c 'printf "%s" "$1" | grep -q "an ESTIMATE — his own anchor at .* (user-stated: pressed play)"' _ "$B1"

check "a first receipt arrives while the conversation goes on" wait_receipts "$SID" 1 1 60
R1="$(ls "$DESKCRAB_WATCHALONG_DIR/sessions/$SID/receipts/" | grep "^e001-" | head -1)"
R1J="$DESKCRAB_WATCHALONG_DIR/sessions/$SID/receipts/$R1"
P2="$(turn desk "and now?")"
B2="$(block_of "$P2")"
check "turn 2's prompt carries reader notes" bash -c 'printf "%s" "$1" | grep -q "READER NOTES BEGIN"' _ "$B2"
IV="$(printf '%s' "$B2" | grep -o "What you have actually seen since his last anchor ([A-Z]*, lag [0-9]* s behind the estimate): [0-9:.]*-[0-9:.]*" | sed 's/.*: //')"
check_eq "naming the reviewed interval from the anchor" "${IV%%-*}" "00:00.0"
OBS1="$(jget "$R1J" "d['observation']")"
check "the receipt's own words are in the prompt" bash -c 'printf "%s" "$1" | grep -qF "$2"' _ "$B2" "$(printf '%s' "$OBS1" | cut -c1-80)"
check "the decoder read scene zero's counters off the pixels" bash -c 'printf "%s" "$1" | grep -q "read scene counters 0, 4, 8"' _ "$OBS1"
check "and found them equal to the decoder timestamps" bash -c 'printf "%s" "$1" | grep -q "Every counter matches its decoder timestamp"' _ "$OBS1"
if [ "$SPEECH" = True ]; then
    check "the real transcript of scene zero reached the prompt, marked not heard" bash -c '
        printf "%s" "$1" | grep -qi "machine transcript (read, not heard): .*scene zero\|machine transcript (read, not heard): .*scene 0"' _ "$B2"
fi
check "the layer sits above the ranking rule" bash -c '
    V="$(grep -n "^SHARED VIEWING" "$1" | cut -d: -f1)"; R="$(grep -n "^HOW TO WEIGH WHAT IS ABOVE" "$1" | cut -d: -f1)"
    [ -n "$V" ] && [ -n "$R" ] && [ "$V" -lt "$R" ]' _ "$P2"
check "and below the conversation" bash -c '
    V="$(grep -n "^SHARED VIEWING" "$1" | cut -d: -f1)"; C="$(grep -n "^THE CONVERSATION SO FAR" "$1" | cut -d: -f1)"
    [ -n "$V" ] && [ -n "$C" ] && [ "$C" -lt "$V" ]' _ "$P2"

echo
echo "sustained: successive packets reach successive prompts while the reader runs on (rule 25):"
latest_interval() {  # the newest receipt of epoch 1, as MM:SS.s-MM:SS.s
    python3 - "$DESKCRAB_WATCHALONG_DIR/sessions/$SID" <<'EOF'
import json, glob, os, sys
def mmss(x):
    m = int(x // 60); return "%02d:%04.1f" % (m, x - 60 * m)
rs = [json.load(open(p)) for p in glob.glob(os.path.join(sys.argv[1], "receipts", "e001-*.json"))]
r = max(rs, key=lambda r: r["reviewed_mono"])
print("%s-%s" % (mmss(r["interval"]["start"]), mmss(r["interval"]["end"])))
EOF
}
for k in 2 3 4 5 6 7; do
    check "receipt $k of epoch 1 lands while the conversation goes on" wait_receipts "$SID" 1 "$k" 60
    LATEST="$(latest_interval)"
    PK="$(turn desk "keep going, what now, part $k?")"
    BK="$(block_of "$PK")"
    FIRST="$(printf '%s' "$BK" | grep -m1 -o '^\[[0-9:.]*-[0-9:.]*, reviewed' | sed 's/^\[//; s/, reviewed//')"
    check_eq "the turn after it quotes the newest look first ($LATEST)" "$FIRST" "$LATEST"
    status_json
    check_eq "coverage is unbroken from the anchor" "$(sj "d['gaps']")" "[]"
    check_eq "and the reader is keeping up (CURRENT)" "$(sj "d['word']")" "CURRENT"
done

echo
echo "pause: the estimate freezes, the reader cuts nothing, the look before it is history (rules 6-8):"
status_json
EST_BEFORE="$(sj "round(d['estimate'])")"
WA pause --quote "hang on, pausing" >/dev/null
NPK="$(ls "$DESKCRAB_WATCHALONG_DIR/sessions/$SID/packets/" | grep -c '\.json$')"
sleep 7
status_json
check_eq "the estimate did not move in seven seconds" "$(sj "round(d['estimate'])")" "$EST_BEFORE"
check_eq "and the reader cut nothing" "$(ls "$DESKCRAB_WATCHALONG_DIR/sessions/$SID/packets/" | grep -c '\.json$')" "$NPK"
P3="$(turn phone "still there?")"
B3="$(block_of "$P3")"
check "turn 3 ran through the phone door and carries the layer" bash -c 'printf "%s" "$1" | grep -q "^SHARED VIEWING"' _ "$B3"
check "which says PAUSED at his stated moment" bash -c 'printf "%s" "$1" | grep -q "Where he is: PAUSED at .* (user-stated: hang on, pausing)"' _ "$B3"
check "and that the earlier looks are history, not where he is" bash -c 'printf "%s" "$1" | grep -Eq "Before that anchor you had reviewed [0-9]+ intervals.*they are history now"' _ "$B3"

echo
echo "a backward seek: a new epoch, the reader follows from his stated position (rule 7):"
WA resume --position 20 --quote "go back to twenty seconds" >/dev/null
check "a receipt arrives in the new epoch" wait_receipts "$SID" 3 1 60
P4="$(turn desk "what do you see now?")"
B4="$(block_of "$P4")"
IV4="$(printf '%s' "$B4" | grep -o "What you have actually seen since his last anchor ([A-Z]*, lag [0-9]* s behind the estimate): [0-9:.]*-[0-9:.]*" | sed 's/.*: //')"
check_eq "turn 4's reviewed interval starts where he went back to" "${IV4%%-*}" "00:20.0"
check "the notes read scene two's counters, not scene zero's again" bash -c 'printf "%s" "$1" | grep -q "read scene counters 20, 24, 28"' _ "$B4"
check "the looks before the seek are history" bash -c 'printf "%s" "$1" | grep -Eq "[0-9]+ earlier intervals before that anchor are history"' _ "$B4"

echo
echo "a forward seek: the skipped seconds are nobody's, the reader follows (rule 17):"
WA anchor --position 200 --playing --quote "skip to three twenty" >/dev/null
check "a receipt arrives in epoch 4" wait_receipts "$SID" 4 1 60
P5="$(turn desk "and here?")"
B5="$(block_of "$P5")"
IV5="$(printf '%s' "$B5" | grep -o "What you have actually seen since his last anchor ([A-Z]*, lag [0-9]* s behind the estimate): [0-9:.]*-[0-9:.]*" | sed 's/.*: //')"
check_eq "turn 5's reviewed interval starts at his new position" "${IV5%%-*}" "03:20.0"
check "the notes read scene twenty's counters" bash -c 'printf "%s" "$1" | grep -q "read scene counters 200, 204, 208"' _ "$B5"
check "and no gap is named for the seconds he skipped" bash -c 'printf "%s" "$1" | grep -vq "UNREVIEWED gaps"' _ "$B5"
check "the estimate is labelled an estimate still" bash -c 'printf "%s" "$1" | grep -q "an ESTIMATE"' _ "$B5"

echo
echo "stop: the layer is gone from the next turn, the loop exits (rules 3, 25):"
WA stop --reason "end of the sitting" >/dev/null
P6="$(turn desk "that was fun")"
check "turn 6's prompt has no viewing layer" bash -c '! grep -q "^SHARED VIEWING" "$1"' _ "$P6"
check "and no reader notes" bash -c '! grep -q "READER NOTES" "$1"' _ "$P6"
for _ in $(seq 1 60); do kill -0 "$RPID" 2>/dev/null || break; sleep 0.25; done
check "the reader loop exited on its own" bash -c '! kill -0 "$1" 2>/dev/null' _ "$RPID"
check "saying the session was gone (stop clears the pointer, rule 3)" grep -Eq "session (STOPPED|INACTIVE): exiting" "$EV/reader.log"
T1="$(now)"
echo "  elapsed: $((T1 - T0)) s of real clock"

echo
echo "no speech carried the notes; nothing reached a device (rule 26):"
check "the desk and phone turns did go through the speech path (stub synthesiser fed)" test -s "$SANDBOX_SPOKEN_LOG"
check "but no viewing text ever reached the synthesiser" bash -c '! grep -q "SHARED VIEWING\|READER NOTES\|scene counters\|Deterministic decode" "$1"' _ "$SANDBOX_SPOKEN_LOG"
check "only the stub reply was ever handed to it" bash -c '! grep -v "Right, I.m here" "$1" | grep -q .' _ "$SANDBOX_SPOKEN_LOG"
check_eq "once per turn" "$(sandbox_count_in "Right, I.m here" "$SANDBOX_SPOKEN_LOG")" "12"
check "no notification" bash -c '! grep -q "SHARED VIEWING" "$1" 2>/dev/null' "$SANDBOX_NOTIFY_LOG"

echo
echo "lineage: every receipt quoted in a prompt is traceable to its packet, its frames and the source:"
python3 - "$DESKCRAB_WATCHALONG_DIR/sessions/$SID" "$PROMPTS" "$EV/lineage.json" "$FX/fixture.json" <<'EOF'
import json, os, sys, glob, hashlib
sdir, pdir, out, fxj = sys.argv[1:5]
session = json.load(open(os.path.join(sdir, "session.json")))
packets = {os.path.basename(p)[:-5]: json.load(open(p)) for p in glob.glob(os.path.join(sdir, "packets", "*.json"))}
receipts = {os.path.basename(p)[:-5]: json.load(open(p)) for p in glob.glob(os.path.join(sdir, "receipts", "*.json"))}
fx = json.load(open(fxj))
turns = []
for p in sorted(glob.glob(os.path.join(pdir, "turn-*.txt")), key=lambda x: int(x.split("-")[-1][:-4])):
    text = open(p, encoding="utf-8").read()
    carried = []
    for rid, r in receipts.items():
        key = " ".join(r["observation"].split())[:80]
        if key in " ".join(text.split()):
            pk = packets[r["packet_id"]]
            carried.append({"receipt": rid, "receipt_hash": r["hash"], "packet": r["packet_id"],
                            "packet_hash": pk["hash"], "epoch": r["epoch"], "interval": r["interval"],
                            "frame_pts": [f["pts"] for f in pk["frames"]],
                            "frame_sha256": [f["sha256"] for f in pk["frames"]],
                            "source_sha256": pk["source"]["sha256"], "reviewed_wall": r["reviewed_wall"],
                            "reviewer": r["reviewer"], "transcript_status": r["transcript_status"]})
    turns.append({"prompt": os.path.basename(p), "has_layer": "SHARED VIEWING" in text,
                  "carried": carried, "sha256": hashlib.sha256(text.encode()).hexdigest()})
lineage = {"session": session["id"], "source": session["source"], "fixture": {k: fx[k] for k in ("seconds", "scene_seconds", "speech", "spoken_scenes")},
           "turns": turns, "packets": len(packets), "receipts": len(receipts),
           "note": "prompts are the system prompts the stub CLI was handed by real crab turns; receipts quoted in them are listed with their packet, frame and source hashes"}
json.dump(lineage, open(out, "w"), indent=1)
ok = all(t["carried"] for t in turns if t["has_layer"] and "NOTHING since" not in open(os.path.join(pdir, t["prompt"])).read())
print("LINEAGE_OK" if ok else "LINEAGE_INCOMPLETE")
EOF
check "the lineage index resolves every quoted receipt" grep -q '"carried": \[$' "$EV/lineage.json"
check_eq "turn 2 carried at least one receipt" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["turns"][1]["carried"])>=1)' "$EV/lineage.json")" "True"
check_eq "the last turn carried none and had no layer" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); t=d["turns"][-1]; print((t["has_layer"], len(t["carried"])))' "$EV/lineage.json")" "(False, 0)"
check_eq "twelve turns ran, eleven with the layer" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((len(d["turns"]), sum(1 for t in d["turns"] if t["has_layer"])))' "$EV/lineage.json")" "(12, 11)"

# Evidence export, only when asked: outside the sandbox's own root, named by the caller.
if [ -n "$EXPORT" ]; then
    WATCHALONG_EVIDENCE_EXPORT="$EXPORT"
    mkdir -p "$WATCHALONG_EVIDENCE_EXPORT"
    cp -r "$DESKCRAB_WATCHALONG_DIR/sessions/$SID" "$WATCHALONG_EVIDENCE_EXPORT/session"
    cp -r "$PROMPTS" "$WATCHALONG_EVIDENCE_EXPORT/prompts"
    cp "$EV/reader.log" "$EV/lineage.json" "$FX/fixture.json" "$FX/fixture.mp4" "$WATCHALONG_EVIDENCE_EXPORT/"
    cp "$SANDBOX_CLAUDE_LOG" "$WATCHALONG_EVIDENCE_EXPORT/claude-argv.log"
    cp "$SANDBOX_SPOKEN_LOG" "$WATCHALONG_EVIDENCE_EXPORT/spoken-witness.log" 2>/dev/null || true
    cp "$SANDBOX_PLAYED_LOG" "$WATCHALONG_EVIDENCE_EXPORT/played-witness.log" 2>/dev/null || true
    printf 'test=%s\nrun=%s\nelapsed_s=%s\nsession=%s\nnote=%s\n' "$SANDBOX_NAME" "$(date -Is)" "$((T1 - T0))" "$SID" \
        "sandboxed run; stub CLI and stub synthesiser; nothing played or spoken; fixture painted here" \
        > "$WATCHALONG_EVIDENCE_EXPORT/RUN.txt"
    echo "  evidence exported to $WATCHALONG_EVIDENCE_EXPORT"
fi
