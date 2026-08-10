#!/bin/bash
# Effort escalation on the chess move path — specs/chessweb.md rule 16b and
# the wake queue's effort override, specs/wake-queue.md rule 13a.
# Run: bash tests/test_chess_effort.sh
#
# Someone is waiting at the board, and before this existed every move wake
# thought at the same config-default effort: quiet manoeuvring cost a full
# deliberation, and the whole game's pace was set by its dullest move. Now a
# pure python-chess pre-check (NO engine, here as everywhere in her chess)
# books the wake at low unless a cheap alarm says the position deserves more —
# so what must hold is: the alarms fire on the positions they were built for
# and stay quiet on the quiet ones; the chosen level actually travels booking
# -> record -> fired unit -> the claude invocation's own --effort flag; and an
# exact reflex hit still plays before the classifier is ever consulted.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

REPO="$(dirname "$(dirname "$(readlink -f "$0")")")"
CHESS="$REPO/lib/betty-chess"
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
PY="$VENV/bin/python"

if [ ! -x "$PY" ]; then
  echo "SKIP: no chess venv at $VENV — run betty-chess once to bootstrap it"
  exit 0
fi
export PYTHONDONTWRITEBYTECODE=1

export DESKCRAB_CHESS_DIR="$SANDBOX/chess-games"
export DESKCRAB_CHESS_VENV="$VENV"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W"

chess() { "$CHESS" "$@" 2>&1; }

# --- the classifier -------------------------------------------------------
# One verdict per hand-built position: "<level> <reason,reason>" or
# "<level> -" when nothing fired.
verdict() { "$PY" -B - "$1" <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_effort
level, why = chess_effort.classify(chess.Board(sys.argv[1]))
print(level, ",".join(why) if why else "-")
EOF
}

echo "the alarms, on positions built for each of them:"
check_eq "the start position is quiet manoeuvring: low, no reasons" \
    "$(verdict 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1')" "low -"
check_eq "a closed queen's-pawn opening is quiet too" \
    "$(verdict 'rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 2')" "low -"

out="$(verdict 'rnb1kbnr/pppp1ppp/4p3/3Q4/8/8/PPPP1PPP/RNB1KBNR w KQkq - 0 1')"
case "$out" in
  high*en-prise:d5*) ok "a queen hanging to a pawn is en prise: high" ;;
  *) fail "hanging queen" "$out" ;;
esac
out="$(verdict 'rnb1kbnr/pppp1ppp/8/4p3/4PP1q/8/PPPP2PP/RNBQKBNR w KQkq - 1 3')"
case "$out" in
  high*in-check*) ok "the side to move in check: high" ;;
  *) fail "in check" "$out" ;;
esac
out="$(verdict '8/P7/8/8/8/4k3/8/4K3 w - - 0 1')"
case "$out" in
  high*pawn-on-7th*) ok "a pawn one square from queening: high" ;;
  *) fail "pawn on the 7th" "$out" ;;
esac
check_eq "two bare kings: high for the narrow tree ALONE — the king-danger \
alarms hold their tongue with no heavy piece left to exploit anything" \
    "$(verdict '7k/8/8/8/8/8/8/K7 w - - 0 1')" "high forced:3"
# A check merely EXISTING is not an alarm any more: in a middlegame some
# spite check is nearly always in the air, and firing on it made every move
# expensive (browser-003, 2026-08-10). Only a check that also wins material,
# or one in a tree narrow enough to be forcing, rings the bell.
check_eq "an Italian with a mere Bxf7+ spite check in the air stays low" \
    "$(verdict 'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4')" "low -"
out="$(verdict 'r1b1kbnr/pppp1qpp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 1')"
case "$out" in
  high*check-available*) ok "a check that also wins the queen: high" ;;
  *) fail "material-winning check" "$out" ;;
esac
out="$(verdict 'rnb1kbnr/pppppppp/8/8/6q1/5P2/PPPPP1PP/RNBQKBNR w KQkq - 0 1')"
case "$out" in
  high*capture-worth:9*) ok "a queen takeable by a pawn: a capture worth far more than a minor" ;;
  *) fail "capture worth a queen" "$out" ;;
esac

# The novelty verdict is an input, so classify stays pure; True is the only
# value that escalates.
out="$("$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_effort
print(*chess_effort.classify(chess.Board(), novel=True)[1])
print(chess_effort.classify(chess.Board(), novel=None)[0])
print(chess_effort.classify(chess.Board(), novel=False)[0])
EOF
)"
check_eq "a confident 'new ground' alone turns a quiet position high; \
an unsure or negative store verdict leaves it low" \
    "$out" "novel
low
low"

# The forced threshold is an env knob, read where the spec says it is.
out="$(DESKCRAB_CHESS_EFFORT_FORCED=30 verdict 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1')"
check_eq "DESKCRAB_CHESS_EFFORT_FORCED is live: raised to 30, even the start \
position's twenty moves read as forced" "$out" "high forced:20"

echo
echo "novelty asks the similarity store, and refuses to guess from a thin one:"
chess new opponent >/dev/null
for m in f3 e5 g4 Qh4; do chess move "$m" >/dev/null; done   # 4 vector rows
out="$("$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_effort
START = chess.STARTING_FEN
FAR = "8/8/4k3/8/8/4K3/8/8 w - - 0 1"
print(chess_effort.novelty(FAR, min_rows=999))          # too thin to judge
print(chess_effort.novelty(FAR, min_rows=1, min_sim=0.999))   # nothing near
print(chess_effort.novelty(START, min_rows=1, min_sim=0.2))   # stored exactly
print(chess_effort.novelty(START, min_rows=1,
                           min_sim=0.2) is False)
EOF
)"
check_eq "thin store None, far position True, stored position False" \
    "$out" "None
True
False
True"
out="$(DESKCRAB_CHESS_DIR="$T/chess-none" "$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess_effort
print(chess_effort.novelty("8/8/4k3/8/8/4K3/8/8 w - - 0 1", min_rows=1))
EOF
)"
check_eq "no store at all is 'cannot say', never an alarm" "$out" "None"

# --- the override through the queue (wake-queue.md rule 13a) --------------
crab() { WAKES_DIR="$W" "$REPO/crab" "$@" 2>&1; }
run() { WAKES_DIR="$W" sandbox_bash "$*" 2>&1; }
records() { ls "$W"/*.wake 2>/dev/null | wc -l; }
field() { [ -s "$W/$1.wake" ] || return 0; awk -F'\t' -v n="$2" 'NR == 1 { print $n }' "$W/$1.wake"; }
nfields() { [ -s "$W/$1.wake" ] || return 0; awk -F'\t' 'NR == 1 { print NF }' "$W/$1.wake"; }
unit_of() { local f; f="$(ls -1 "$W"/*.wake 2>/dev/null | head -1)"; f="${f##*/}"; printf '%s' "${f%.wake}"; }

cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
WANTS_FILE="$T/wants.md"
WAKE_EFFORT="medium"
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CONF
printf '# Wants\n\n- one want, so the wake path is enabled at all\n' > "$T/wants.md"

echo
echo "a booking carries its effort into the record and the unit:"
rm -f "$W"/*.wake
: > "$SANDBOX_SYSTEMD_LOG"
crab wake-at --by tester --effort low 3600s event "an effortful agenda" >/dev/null
check_eq "the booking is made" "$(records)" "1"
U="$(unit_of)"
check_eq "the record grew its sixth field" "$(nfields "$U")" "6"
check_eq "and that field is the level asked for" "$(field "$U" 6)" "low"
sandbox_systemd_calls | grep -q " wake event an effortful agenda $U tester low$" \
  && ok "the armed unit's argv ends with the provenance and the level" \
  || fail "unit argv" "$(sandbox_systemd_calls | tail -1)"

rm -f "$W"/*.wake
: > "$SANDBOX_SYSTEMD_LOG"
crab wake-at --by tester 3600s event "a plain agenda" >/dev/null
U="$(unit_of)"
check_eq "a booking WITHOUT an override keeps the five-field shape" \
    "$(nfields "$U")" "5"
sandbox_systemd_calls | grep -q " wake event a plain agenda $U tester$" \
  && ok "and its unit argv ends at the provenance, exactly as before" \
  || fail "plain unit argv" "$(sandbox_systemd_calls | tail -1)"

out="$(crab wake-at --by tester --effort xhigh 3600s event "never booked")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "not a level the CLI knows" \
  && ok "a level the CLI would refuse is refused at booking time instead" \
  || fail "bogus effort" "rc=$rc $out"
check_eq "and nothing was recorded for it" "$(records)" "1"

echo
echo "the record survives what records survive:"
FIRE=$(( $(date +%s) + 5400 ))
printf '%s\tevent\told agenda\t%s\ttester\n' "$FIRE" "$(date +%s)" > "$W/deskcrab-wake-legacy-5.wake"
out="$(run 'wake_record_read "$WAKES_DIR/deskcrab-wake-legacy-5.wake"; printf "[%s]" "$WK_EFFORT"')"
check_eq "a five-field record reads back with no override, no shift" "$out" "[]"
printf '%s\tevent\tnew agenda\t%s\ttester\tlow\n' "$FIRE" "$(date +%s)" > "$W/deskcrab-wake-six.wake"
out="$(run 'wake_record_read "$WAKES_DIR/deskcrab-wake-six.wake"; printf "[%s]" "$WK_EFFORT"')"
check_eq "a six-field record reads its override back" "$out" "[low]"

rm -f "$W"/*.wake
printf '%s\tevent\trestored agenda\t%s\ttester\tlow\n' "$FIRE" "$(date +%s)" \
    > "$W/deskcrab-wake-restoreme.wake"
: > "$SANDBOX_SYSTEMD_LOG"
run 'wake_restore' >/dev/null
sandbox_systemd_calls | grep -q " wake event restored agenda deskcrab-wake-restoreme tester low$" \
  && ok "restore re-arms the timer with the override intact" \
  || fail "restore argv" "$(sandbox_systemd_calls | tail -1)"
rm -f "$W"/*.wake

echo
echo "the fired wake thinks at the effort it was booked with:"
: > "$SANDBOX_CLAUDE_LOG"
crab wake event "an effortful agenda" "" tester low >/dev/null 2>&1
grep -q -- "--effort low" "$SANDBOX_CLAUDE_LOG" \
  && ok "the sixth argument reached the claude invocation as --effort low" \
  || fail "fired override" "$(cat "$SANDBOX_CLAUDE_LOG")"
rm -f "$W"/*.wake
: > "$SANDBOX_CLAUDE_LOG"
crab wake event "a plain agenda" "" tester >/dev/null 2>&1
grep -q -- "--effort medium" "$SANDBOX_CLAUDE_LOG" \
  && ok "no override, and the config's WAKE_EFFORT stands" \
  || fail "config default" "$(cat "$SANDBOX_CLAUDE_LOG")"
rm -f "$W"/*.wake
: > "$SANDBOX_CLAUDE_LOG"
crab wake event "a suspect agenda" "" tester xhigh >/dev/null 2>&1
grep -q -- "--effort medium" "$SANDBOX_CLAUDE_LOG" \
  && ok "an unrecognised level on the argv is ignored, not obeyed" \
  || fail "bogus fired level" "$(cat "$SANDBOX_CLAUDE_LOG")"
rm -f "$W"/*.wake

# --- the bridge: reflex first, then the classifier picks the level --------
# Hub.answer_position driven directly; the model call is a stub that logs its
# prompt and answers from a reply map. The effort metric stamp is the tuning
# record rule 17 owes; model-start names the effort the call actually went
# out at, which is how the level provably reaches the invocation.
HUBDIR="$T/chess-hub"
mkdir -p "$HUBDIR/games"
WAKE_LOG="$T/wake.log"
WAKE_STUB="$T/wake-stub"
cat > "$WAKE_STUB" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$WAKE_LOG"
SH
chmod +x "$WAKE_STUB"
MOVER_LOG="$T/mover.log"
MOVER_REPLIES="$T/mover-replies.tsv"
MOVER_STUB="$T/mover-stub"
cat > "$MOVER_STUB" <<SH
#!/bin/bash
prompt="\$(cat)"
printf '%s\n----\n' "\$prompt" >> "$MOVER_LOG"
while IFS=\$'\t' read -r pat reply; do
    [ -n "\$pat" ] || continue
    case "\$prompt" in *"\$pat"*) printf '%s\n' "\$reply"; exit 0 ;; esac
done < "$MOVER_REPLIES"
exit 0
SH
chmod +x "$MOVER_STUB"
printf 'game quiet-001\tc2c4\ngame quiet-002\tc2c4\ngame quiet-003\tc2c4\ngame danger-001\tb1c3\n' \
    > "$MOVER_REPLIES"
MET="$DESKCRAB_METRICS_DIR/$(date +%F).log"

seed_hub_game() { # <id> <moves json array>
  cat > "$HUBDIR/games/$1.json" <<JSON
{"id": "$1", "opponent": "hub", "my_side": "white", "moves": $2,
 "resigned_by": null, "draw_agreed": false, "engine_level": null,
 "created": "2026-01-01T00:00:00+00:00", "updated": "2026-01-01T00:00:00+00:00"}
JSON
}
# Two finished e4 wins open the reflex gate at the start position. The quiet
# and danger games stand on ground the store has never walked exactly; the
# quiet position is seeded once per drive because a drive now plays into it.
seed_hub_game won-001 '["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"]'
seed_hub_game won-002 '["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"]'
seed_hub_game quiet-001 '["d2d4", "d7d5"]'
seed_hub_game quiet-002 '["d2d4", "d7d5"]'
seed_hub_game quiet-003 '["d2d4", "d7d5"]'
seed_hub_game danger-001 '["e2e4", "e7e5", "d1h5", "g8f6"]'
seed_hub_game hit-001 '[]'
DESKCRAB_CHESS_DIR="$HUBDIR" chess reflex --backfill >/dev/null

drive() { # <game id> — answer_position for that game's live board. The
          # always-low pin is off here so the classifier itself is on trial;
          # the one check that wants the pin sets ALWAYS_LOW=1.
  DESKCRAB_CHESS_DIR="$HUBDIR" DESKCRAB_CHESS_MOVER_CMD="$MOVER_STUB" \
  DESKCRAB_CHESS_ALWAYS_LOW="${ALWAYS_LOW:-0}" \
      "$PY" -B - "$1" <<EOF
import sys
sys.path.insert(0, "$REPO/lib")
import chess_cli, chessweb
store = chessweb.Store("hub", "white", game_id=sys.argv[1])
hub = chessweb.Hub(store, ["$WAKE_STUB"])
g = store.load()
hub.answer_position(g, chess_cli.build_board(g))
hub.mover.wait_idle(60)
EOF
}

echo
echo "the bridge thinks about quiet positions cheap and alarmed ones dear:"
: > "$MOVER_LOG"
drive quiet-001 >/dev/null
awk -F'\t' '$3=="chess" && $4=="effort" && $5 == "quiet-001 ply 2 low quiet"' "$MET" \
    | grep -q . \
  && ok "a quiet middlegame classifies LOW, stamped with 'quiet'" \
  || fail "quiet effort stamp" "$(grep quiet-001 "$MET")"
awk -F'\t' '$3=="chess" && $4=="model-start" && $5 ~ /^quiet-001 ply 2 effort low /' "$MET" \
    | grep -q . \
  && ok "and the model call went out at low — the level reached the invocation" \
  || fail "quiet model-start" "$(grep model-start "$MET" | tail -3)"
awk -F'\t' '$3=="chess" && $4=="move-played" && $5 == "quiet-001 ply 2 c4 model"' "$MET" \
    | grep -q . \
  && ok "and the stub's answer was validated and played into the store" \
  || fail "quiet move-played" "$(grep quiet-001 "$MET")"

: > "$MOVER_LOG"
drive danger-001 >/dev/null
awk -F'\t' '$3=="chess" && $4=="effort" && $5 ~ /^danger-001 ply 4 high .*en-prise:h5/' "$MET" \
    | grep -q . \
  && ok "a hanging queen classifies HIGH, and the stamp names every alarm" \
  || fail "danger effort stamp" "$(grep danger-001 "$MET")"
awk -F'\t' '$3=="chess" && $4=="model-start" && $5 ~ /^danger-001 ply 4 effort high /' "$MET" \
    | grep -q . \
  && ok "and its model call went out at high" \
  || fail "danger model-start" "$(grep model-start "$MET" | tail -3)"

: > "$MOVER_LOG"
drive hit-001 >/dev/null
[ ! -s "$MOVER_LOG" ] \
  && ok "a position reflex knows makes no model call at all" \
  || fail "reflex hit reached the model" "$(cat "$MOVER_LOG")"
awk -F'\t' '$3=="chess" && $4=="effort" && $5 ~ /^hit-001 /' "$MET" | grep -q . \
  && fail "the classifier ran on the exact-hit path" "$(grep hit-001 "$MET")" \
  || ok "and left no effort stamp: the reflex hit bypassed the classifier entirely"

: > "$MOVER_LOG"
DESKCRAB_CHESS_EFFORT=0 drive quiet-002 >/dev/null
awk -F'\t' '$3=="chess" && $4=="effort" && $5 ~ /^quiet-002 /' "$MET" | grep -q . \
  && fail "DESKCRAB_CHESS_EFFORT=0 still classified" "$(grep quiet-002 "$MET")" \
  || true
awk -F'\t' '$3=="chess" && $4=="model-start" && $5 ~ /^quiet-002 ply 2 effort low /' "$MET" \
    | grep -q . \
  && ok "DESKCRAB_CHESS_EFFORT=0 skips the classifier; the call goes at the mover default (low)" \
  || fail "the off switch" "$(grep quiet-002 "$MET")"

: > "$MOVER_LOG"
ALWAYS_LOW=1 drive quiet-003 >/dev/null
awk -F'\t' '$3=="chess" && $4=="effort" && $5 == "quiet-003 ply 2 low always-low"' "$MET" \
    | grep -q . \
  && awk -F'\t' '$3=="chess" && $4=="model-start" && $5 ~ /^quiet-003 ply 2 effort low /' "$MET" \
    | grep -q . \
  && ok "the always-low pin (the live default) sends every call at low, stamped as the pin" \
  || fail "always-low" "$(grep quiet-003 "$MET")"

grep -q "you played" "$WAKE_LOG" && ! grep -q "your move" "$WAKE_LOG" \
  && ok "the only wakes are post-move consequences — the queue never gated a move" \
  || fail "wake log" "$(cat "$WAKE_LOG")"
