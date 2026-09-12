#!/bin/bash
# Phone photo attachments — specs/phone.md rule 3b.
# A real serve.py socket receives a JSON-carried image, stores only validated
# bytes privately for the model run, exposes its local path only in the phone
# turn frame, and removes it when the run ends. Text-only and auth behaviour
# stay unchanged.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"
SERVER_PID=""
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

SECRET=testsecret
PORT=18737
BASE="http://127.0.0.1:$PORT"

cat > "$T/crab" <<STUB
#!/bin/bash
case "\$1" in
  synth) : > "\$2"; exit 1 ;;
  remote) ;;
  *) exit 1 ;;
esac
N="\$(cat "$T/n" 2>/dev/null || echo 0)"; N=\$((N + 1)); echo "\$N" > "$T/n"
printenv DESKCRAB_TURN_ATTACHMENT > "$T/path.\$N" 2>/dev/null || : > "$T/path.\$N"
if [ -s "$T/path.\$N" ]; then cp "\$(cat "$T/path.\$N")" "$T/image.\$N"; fi
"$REPO_DIR/crab" context --profile turn > "$T/context.\$N" 2> "$T/context-err.\$N"
printf '{"spoken":"E2E-REPLY","display":"","audio":"","error":""}\n'
STUB
chmod +x "$T/crab"

mkdir -p "$T/data/deskcrab"
printf phone > "$T/data/deskcrab/last-origin"

DESKCRAB_SERVE_SECRET="$SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 \
DESKCRAB_CRAB_BIN="$T/crab" \
DESKCRAB_STATE_PREFIX="$T/deskcrab" \
DESKCRAB_GEOCODE_URL= \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 100); do
    curl -fsS -m 2 "$BASE/health?k=$SECRET" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS -m 2 "$BASE/health?k=$SECRET" >/dev/null 2>&1 \
    || die "the server never came up" "$(cat "$T/server.log")"

# A tiny signature-valid PNG-shaped payload. Byte identity is the transport
# claim here; image decoding belongs to the image tool itself.
printf '\211PNG\r\n\032\nPHOTO-CANARY' > "$T/photo.png"
B64="$(base64 -w0 "$T/photo.png")"

echo "== a photo reaches the same authenticated turn path =="
BODY="$(python3 - "$B64" <<'PY'
import json, sys
print(json.dumps({"text":"what is this?", "turn":"face01",
                  "attachment":{"name":"campfire.png", "type":"image/png",
                                "data":sys.argv[1]}}))
PY
)"
OUT="$(curl -sS -m 30 -H "X-Crab-Key: $SECRET" \
    -H 'Content-Type: application/json' --data "$BODY" "$BASE/say")"
check "the attached turn answered normally" contains "$OUT" 'E2E-REPLY'
check_eq "one assistant turn ran" "$(cat "$T/n")" "1"
check "the model received a private local path" [ -s "$T/path.1" ]
cmp -s "$T/photo.png" "$T/image.1" \
    && ok "the stored bytes reached the model byte-identical" \
    || fail "the stored bytes reached the model byte-identical" "bytes differ"
check_eq "the phone frame names exactly one attached photo" \
    "$(grep -c 'The user attached a photo at ' "$T/context.1")" "1"
check "the frame requires inspection with the image tool" \
    contains "$(grep 'The user attached a photo at ' "$T/context.1")" "Inspect it with view_image"
MODEL_PATH="$(cat "$T/path.1")"
[ ! -e "$MODEL_PATH" ] \
    && ok "the private upload is removed when the turn ends" \
    || fail "the private upload is removed when the turn ends" "$MODEL_PATH remains"

echo "== attachment-only, re-attach, validation, and auth boundaries =="
ONLY="$(python3 - "$B64" <<'PY'
import json, sys
print(json.dumps({"text":"", "turn":"face02",
                  "attachment":{"name":"photo.png", "type":"image/png",
                                "data":sys.argv[1]}}))
PY
)"
OUT2="$(curl -sS -m 30 -H "X-Crab-Key: $SECRET" \
    -H 'Content-Type: application/json' --data "$ONLY" "$BASE/say")"
check "a photo without a caption is a valid turn" contains "$OUT2" 'E2E-REPLY'
check "its conversation transcript has a visible placeholder" \
    contains "$OUT2" '[Photo attached]'

RUNS="$(cat "$T/n")"
OTHER="$(printf '\211PNG\r\n\032\nOTHER' | base64 -w0)"
REPOST="$(python3 - "$OTHER" <<'PY'
import json, sys
print(json.dumps({"text":"changed", "turn":"face01",
                  "attachment":{"type":"image/png", "data":sys.argv[1]}}))
PY
)"
curl -sS -m 10 -H "X-Crab-Key: $SECRET" -H 'Content-Type: application/json' \
    --data "$REPOST" "$BASE/say" >/dev/null
check_eq "re-posting a turn id attaches instead of running or replacing" \
    "$(cat "$T/n")" "$RUNS"

BAD="$(python3 - <<'PY'
import base64, json
print(json.dumps({"text":"bad", "turn":"face03",
                  "attachment":{"type":"image/png",
                                "data":base64.b64encode(b"not png").decode()}}))
PY
)"
CODE="$(curl -sS -m 10 -o "$T/bad.out" -w '%{http_code}' \
    -H "X-Crab-Key: $SECRET" -H 'Content-Type: application/json' \
    --data "$BAD" "$BASE/say")"
check_eq "claimed types whose bytes disagree are rejected before a turn" "$CODE" "400"
check_eq "a rejected photo ran no assistant turn" "$(cat "$T/n")" "$RUNS"

CODE="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' --data "$BODY" "$BASE/say")"
check_eq "the photo post uses the existing authorization gate" "$CODE" "404"

TEXT_OUT="$(curl -sS -m 30 -H "X-Crab-Key: $SECRET" \
    -H 'Content-Type: application/json' \
    --data '{"text":"plain text still works","turn":"face04"}' "$BASE/say")"
check "ordinary text messaging still answers" contains "$TEXT_OUT" 'E2E-REPLY'
check_eq "a text-only turn receives no attachment path" \
    "$(cat "$T/path.$(cat "$T/n")")" ""
