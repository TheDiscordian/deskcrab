#!/bin/bash
# Tests for the handed-media path (specs/phone.md rules 34–38, and rule 18's
# ranges): a file handed with `crab play` reaches /watch as a play event and
# is served back — with a real content-type, with range support, behind the
# auth gate — while a path outside the home directory never leaves the box,
# from either side of the hand-off.
#
# Drives the REAL serve.py over a REAL socket, like test_phone_live.sh: the
# media route's whole point is what a browser's audio element sees on the
# wire, and headers cannot be asserted against a function call.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

SERVER_PID=""
# The exit trap belongs to the sandbox; the server is stopped through its hook.
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

SECRET="testsecret"
# A port nobody else is on; the live instance sits on 8723, the other phone
# tests on 18723–18727.
PORT=18728
BASE="http://127.0.0.1:$PORT"

# The piece: deterministic bytes (0..255 repeating), so a range's slice can be
# checked exactly rather than merely counted. The space in the name is on
# purpose — his files have them.
MUSIC_DIR="$HOME/Library/music"
mkdir -p "$MUSIC_DIR"
PIECE="$MUSIC_DIR/night piece.mp3"
python3 -c 'import sys; sys.stdout.buffer.write(bytes(range(256)) * 8)' > "$PIECE"

# A real file OUTSIDE the sandbox home — the boundary both hands must hold.
OUTSIDE="$T/outside.mp3"
printf 'not yours to serve' > "$OUTSIDE"

PTR="$DESKCRAB_STATE_PREFIX-play"

# --- the server ------------------------------------------------------------
# STATE_PREFIX, HOME and TMPDIR all ride in from the sandbox environment, so
# the server, `crab play`, and the assertions below agree on every path.
DESKCRAB_SERVE_SECRET="$SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 100); do
    curl -fsS -m 2 "$BASE/health?k=$SECRET" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -fsS -m 2 "$BASE/health?k=$SECRET" >/dev/null 2>&1; then
    die "the server never came up" "$(cat "$T/server.log")"
fi

# --- the hand: crab play ---------------------------------------------------

echo "== crab play hands a file, and only a file under home =="

if "$REPO_DIR/crab" play "$T/no-such-file.mp3" >/dev/null 2>&1; then
    fail "a missing file is refused" "crab play exited 0"
else
    ok "a missing file is refused"
fi

if "$REPO_DIR/crab" play "$OUTSIDE" > "$T/refuse.out" 2>&1; then
    fail "a file outside home is refused at the hand" "exit 0: $(cat "$T/refuse.out")"
else
    ok "a file outside home is refused at the hand"
fi
[ -f "$PTR" ] \
    && fail "a refused hand writes no pointer" "$(cat "$PTR")" \
    || ok "a refused hand writes no pointer"

if "$REPO_DIR/crab" play "$PIECE" > "$T/play.out" 2>&1; then
    ok "crab play accepts a file under home"
else
    fail "crab play accepts a file under home" "$(cat "$T/play.out")"
fi
[ -f "$PTR" ] \
    && ok "the pointer is written under the state prefix" \
    || fail "the pointer is written under the state prefix" "no $PTR"
grep -q '"title": "night piece"' "$PTR" \
    && ok "the piece's name rides along, extension shed" \
    || fail "the piece's name rides along, extension shed" "$(cat "$PTR" 2>/dev/null)"

# --- delivery: /watch and /context -----------------------------------------

echo "== the pointer reaches /watch, opt-in by playseen =="

W="$(curl -fsS -m 5 "$BASE/watch?wait=0&playseen=&k=$SECRET")"
PLAY_ID="$(printf '%s' "$W" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("play",{}).get("id",""))')"
PLAY_URL="$(printf '%s' "$W" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("play",{}).get("url",""))')"
PLAY_TITLE="$(printf '%s' "$W" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("play",{}).get("title",""))')"
[ -n "$PLAY_ID" ] \
    && ok "a poll that opts in gets the play event" \
    || fail "a poll that opts in gets the play event" "$W"
check_eq "the play event carries the piece's name" "$PLAY_TITLE" "night piece"
case "$PLAY_URL" in
    /media/*) ok "the URL is a media token, not a path" ;;
    *) fail "the URL is a media token, not a path" "$PLAY_URL" ;;
esac

W2="$(curl -fsS -m 5 "$BASE/watch?wait=0&k=$SECRET")"
if printf '%s' "$W2" | grep -q '"play"'; then
    fail "delivery is opt-in by the parameter's presence" "$W2"
else
    ok "delivery is opt-in by the parameter's presence"
fi

W3="$(curl -fsS -m 5 "$BASE/watch?wait=0&playseen=$PLAY_ID&k=$SECRET")"
if printf '%s' "$W3" | grep -q '"play"'; then
    fail "an acknowledged id is not delivered again" "$W3"
else
    ok "an acknowledged id is not delivered again"
fi

CTX_ID="$(curl -fsS -m 5 "$BASE/context?k=$SECRET" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("play_id",""))')"
check_eq "/context seeds the media cursor (rule 37)" "$CTX_ID" "$PLAY_ID"

# --- serving: content-type, ranges, auth ------------------------------------

echo "== the media route serves it, with ranges =="

curl -fsS -m 5 -H "X-Crab-Key: $SECRET" -D "$T/full.hdr" -o "$T/full.bin" \
    "$BASE$PLAY_URL"
cmp -s "$T/full.bin" "$PIECE" \
    && ok "the whole file comes back byte-identical" \
    || fail "the whole file comes back byte-identical" "$(wc -c < "$T/full.bin") bytes"
grep -qi '^content-type: audio/mpeg' "$T/full.hdr" \
    && ok "with the file's own content-type" \
    || fail "with the file's own content-type" "$(grep -i '^content-type' "$T/full.hdr")"
grep -qi '^accept-ranges: bytes' "$T/full.hdr" \
    && ok "and ranges are advertised" \
    || fail "and ranges are advertised" "no Accept-Ranges header"

curl -sS -m 5 -H "X-Crab-Key: $SECRET" -H "Range: bytes=100-199" \
    -D "$T/rng.hdr" -o "$T/rng.bin" "$BASE$PLAY_URL"
head -1 "$T/rng.hdr" | grep -q ' 206 ' \
    && ok "a middle range answers 206" \
    || fail "a middle range answers 206" "$(head -1 "$T/rng.hdr")"
python3 - "$PIECE" "$T/rng.bin" <<'PY' \
    && ok "and carries exactly the requested bytes" \
    || fail "and carries exactly the requested bytes" "wrong slice"
import sys
whole = open(sys.argv[1], "rb").read()
part = open(sys.argv[2], "rb").read()
sys.exit(0 if part == whole[100:200] else 1)
PY
grep -qi '^content-range: bytes 100-199/2048' "$T/rng.hdr" \
    && ok "with the Content-Range that names the whole" \
    || fail "with the Content-Range that names the whole" "$(grep -i '^content-range' "$T/rng.hdr")"

curl -sS -m 5 -H "X-Crab-Key: $SECRET" -H "Range: bytes=-56" \
    -D "$T/sfx.hdr" -o "$T/sfx.bin" "$BASE$PLAY_URL"
python3 - "$PIECE" "$T/sfx.bin" <<'PY' \
    && ok "a suffix range hands back the tail" \
    || fail "a suffix range hands back the tail" "$(wc -c < "$T/sfx.bin") bytes"
import sys
whole = open(sys.argv[1], "rb").read()
part = open(sys.argv[2], "rb").read()
sys.exit(0 if part == whole[-56:] else 1)
PY

CODE="$(curl -sS -m 5 -H "X-Crab-Key: $SECRET" -H "Range: bytes=999999-" \
    -o /dev/null -w '%{http_code}' "$BASE$PLAY_URL")"
check_eq "a range past the end is 416" "$CODE" "416"

CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$BASE$PLAY_URL")"
check_eq "no secret, no bytes — the route sits behind the auth gate" "$CODE" "404"

CODE="$(curl -sS -m 5 -H "X-Crab-Key: $SECRET" -o /dev/null -w '%{http_code}' \
    "$BASE/media/deadbeefdeadbeefdeadbeef")"
check_eq "a token nobody handed over is 404" "$CODE" "404"

echo "== the audio route honours ranges too (MIN-25) =="

printf 'OPUSBYTES-0123456789' > "$TMPDIR/deskcrab-remote-media-test.opus"
curl -sS -m 5 -H "X-Crab-Key: $SECRET" -H "Range: bytes=10-13" \
    -D "$T/aud.hdr" -o "$T/aud.bin" "$BASE/audio/deskcrab-remote-media-test.opus"
head -1 "$T/aud.hdr" | grep -q ' 206 ' \
    && ok "a reply clip answers a range with 206" \
    || fail "a reply clip answers a range with 206" "$(head -1 "$T/aud.hdr")"
check_eq "and the right bytes" "$(cat "$T/aud.bin")" "0123"

# --- the boundary, held on the server's own side ----------------------------

echo "== the server holds the home boundary and the TTL itself =="

# A pointer written past crab play's check — another hand, a bug, whatever.
# The server must refuse it on its own.
python3 - "$PTR" "$OUTSIDE" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps(
    {"id": "evil1", "path": sys.argv[2], "title": "outside"}))
PY
W4="$(curl -fsS -m 5 "$BASE/watch?wait=0&playseen=&k=$SECRET")"
if printf '%s' "$W4" | grep -q '"play"'; then
    fail "a pointer outside home is never offered" "$W4"
else
    ok "a pointer outside home is never offered"
fi

"$REPO_DIR/crab" play "$PIECE" >/dev/null 2>&1
touch -d '10 minutes ago' "$PTR"
W5="$(curl -fsS -m 5 "$BASE/watch?wait=0&playseen=&k=$SECRET")"
if printf '%s' "$W5" | grep -q '"play"'; then
    fail "an expired pointer is not offered (rule 34)" "$W5"
else
    ok "an expired pointer is not offered (rule 34)"
fi
