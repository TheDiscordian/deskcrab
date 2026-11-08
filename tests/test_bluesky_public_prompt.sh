#!/bin/bash
# The public-composition profile — specs/prompt-assembly.md rules 41 to 41b,
# specs/memory-recall.md rule 57, specs/bluesky.md clause 21.
# Run: bash tests/test_bluesky_public_prompt.sh
#
# The 2026-11-07 review found the Bluesky bridge's wake firing on the ordinary
# wake profile: L3 was the general recall block — the pinned tier, the user's
# directives, her private notes, the moments of her life — and L6 the desk
# transcript, so a public reply was composed in a context carrying private
# memory and another conversation, with a note under it asking her to treat
# the rest as private. This file proves the boundary the way the acceptance
# gate asked for it: not on the inbox JSON, but on the WHOLE system prompt a
# bridge-booked wake is actually handed, fired through `crab wake` against a
# live scratch memory store seeded with canaries in every private place —
# and the same seeds reaching another booker's wake and a desk turn, so
# ordinary recall is proven untouched. Asserted on what the CLI was HANDED
# (the stub captures its argv), never on a grep of `crab`.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

PY="${MEMORY_PYTHON:-}"
[ -n "$PY" ] && [ -x "$PY" ] && "$PY" -c "import sqlite_vec" 2>/dev/null \
    || sandbox_skip "no sqlite-vec interpreter (MEMORY_PYTHON) on this box"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }
count_in() { local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)"; printf '%s' "${n:-0}"; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/wakes" "$D/memory" "$D/journal" "$SANDBOX/witness"

# --- the fixture embedder: deterministic unit vectors, loopback only ---------
cat > "$SANDBOX/embedder.py" <<'PY'
import hashlib, json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def vec(text):
    digest = hashlib.sha256(text.encode()).digest()
    raw = [(digest[i % 32] / 255.0) - 0.5 for i in range(768)]
    norm = sum(x * x for x in raw) ** 0.5
    return [x / norm for x in raw]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        inp = body.get("input", [])
        inp = inp if isinstance(inp, list) else [inp]
        out = json.dumps({"embeddings": [vec(t) for t in inp]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(out)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_port))
server.serve_forever(poll_interval=0.05)
PY
python3 "$SANDBOX/embedder.py" "$SANDBOX/embedder.port" </dev/null >/dev/null 2>&1 &
EMB_PID=$!
sandbox_at_exit "kill $EMB_PID 2>/dev/null"
for _ in $(seq 1 100); do [ -s "$SANDBOX/embedder.port" ] && break; sleep 0.1; done
[ -s "$SANDBOX/embedder.port" ] || die "the fixture embedder never came up"
export MEMORY_EMBED_URL="http://127.0.0.1:$(cat "$SANDBOX/embedder.port")/api/embed"

# --- her instance: a persona, a shelf, a conversation with a canary in it ----
printf '# Wants\n\n- 🌱 **Keep a window box**\n' > "$D/wants.md"
printf '## Who you are\n\nPERSONA-MARKER: dry, brief, and you answer the person in front of you.\n' \
    > "$SANDBOX/persona.md"
cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=1
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROJECT_DIR="$SANDBOX/home"
CUSTOM_PROMPT="$SANDBOX/persona.md"
WANTS_FILE="$D/wants.md"
WAKE_QUIET_HOURS=""
EOF
printf 'User [2026-11-07 02:00]: CANARY-CONVO what we said at the desk tonight\nAssistant [2026-11-07 02:00]: an answer at the desk\n' \
    > "$DESKCRAB_STATE_PREFIX-convo.txt"

# --- the memory store, seeded through the real doors -------------------------
CRAB="$SANDBOX_REPO/crab"
A="did:plc:personalpha"
"$CRAB" memory add --kind note --source private-phone "CANARY-PHONE a private contact concerning $A" >/dev/null 2>&1 \
    || die "seeding the phone note failed"
"$CRAB" memory add --kind directive --pin "CANARY-PIN never say this in public" >/dev/null 2>&1 \
    || die "seeding the pinned directive failed"
"$CRAB" memory add --kind episodic --occurred 2026-11-01 --participants "the user" "CANARY-MOMENT an evening at home" >/dev/null 2>&1 \
    || die "seeding the moment failed"
"$CRAB" memory add --kind note --source conversation "CANARY-OTHER another conversation entirely" >/dev/null 2>&1 \
    || die "seeding the other conversation failed"
printf '{"did":"%s","text":"On Bluesky, @alpha.test replied to me: \\"CANARY-SOCIAL their public words\\""}' "$A" \
    | "$CRAB" memory social-retain >/dev/null 2>&1 || die "seeding the social row failed"
"$CRAB" memory add --kind note --visibility public "PUBLIC-SELF I like reading on rainy evenings" >/dev/null 2>&1 \
    || die "seeding the public self-fact failed"
check "the store holds the six seeds" \
    [ "$("$PY" -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select count(*) from memories').fetchone()[0])" "$DESKCRAB_MEMORY_DIR/memory.db")" = 6 ]

# --- the stub CLI records what it was handed -------------------------------
# The system prompt is the argument after --append-system-prompt, the agenda
# is the last argument, and the whole argv is dumped for the canary sweep.
# Appending, because a wake may consult the CLI more than once.
sandbox_stub claude <<'STUB'
#!/bin/bash
prev=""
for a in "$@"; do
    [ "$prev" = "--append-system-prompt" ] && printf '%s' "$a" > "$SANDBOX_SYS_FILE"
    prev="$a"
done
printf '%s' "${@: -1}" > "$SANDBOX_AGENDA_FILE"
printf '%s\n' "$@" >> "$SANDBOX_ARGS_FILE"
env > "$SANDBOX_ENV_FILE"
case "$*" in
    *--output-format*)
        cat > /dev/null
        printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"stub reply."}]}}'
        printf '%s\n' '{"type":"result","result":"stub reply."}'
        ;;
    *) cat > /dev/null; printf 'stub reply.\n' ;;
esac
exit 0
STUB
export SANDBOX_SYS_FILE="$SANDBOX/witness/system-prompt.txt"
export SANDBOX_AGENDA_FILE="$SANDBOX/witness/agenda.txt"
export SANDBOX_ARGS_FILE="$SANDBOX/witness/argv.txt"
export SANDBOX_ENV_FILE="$SANDBOX/witness/env.txt"

fire() {  # <kind> <reason> <booked-by> [env assignments...]
    local kind="$1" reason="$2" by="$3"; shift 3
    : > "$SANDBOX_SYS_FILE"; : > "$SANDBOX_AGENDA_FILE"; : > "$SANDBOX_ARGS_FILE"; : > "$SANDBOX_ENV_FILE"
    env "$@" WAKES_DIR="$D/wakes" "$CRAB" wake "$kind" "$reason" "" "$by" \
        </dev/null >/dev/null 2>&1 || true
}
# The bridge's own constant, read from the connector so the test cannot drift from it.
BRIDGE_REASON="$(python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import bluesky; print(bluesky.WAKE_REASON)" "$SANDBOX_REPO/lib")"

echo "a wake booked by the Bluesky bridge composes in public:"
fire event "$BRIDGE_REASON" bluesky-bridge
[ -s "$SANDBOX_SYS_FILE" ] || die "the bridge-booked wake never handed the CLI a system prompt"
check "the session's tools are told the sitting is public" \
    grep -qx 'DESKCRAB_WAKE_PROFILE=public' "$SANDBOX_ENV_FILE"
check_eq "no canary of any kind reaches ANY argument the CLI was handed" \
    "$(count_in CANARY "$SANDBOX_ARGS_FILE")" 0
check "the memory layer is the public block" \
    grep -qF '## Public composition — what I may draw on here' "$SANDBOX_SYS_FILE"
check "the one fact she marked public rides it" \
    grep -qF 'PUBLIC-SELF I like reading on rainy evenings' "$SANDBOX_SYS_FILE"
refute "the general recall block is not there" \
    grep -qF '## What I remember' "$SANDBOX_SYS_FILE"
refute "the pinned directive is not there" grep -qF 'CANARY-PIN' "$SANDBOX_SYS_FILE"
refute "the phone-sourced note is not there" grep -qF 'CANARY-PHONE' "$SANDBOX_SYS_FILE"
refute "the moment is not there" grep -qF 'CANARY-MOMENT' "$SANDBOX_SYS_FILE"
refute "the other conversation's note is not there" grep -qF 'CANARY-OTHER' "$SANDBOX_SYS_FILE"
refute "the social row's public words are not in the system prompt either (clause 9)" \
    grep -qF 'CANARY-SOCIAL' "$SANDBOX_SYS_FILE"
refute "the desk transcript is absent — no L6" \
    grep -qF 'THE CONVERSATION SO FAR' "$SANDBOX_SYS_FILE"
refute "the desk conversation's canary is absent" grep -qF 'CANARY-CONVO' "$SANDBOX_SYS_FILE"
check "she is still herself — the persona sheet rides" grep -qF 'PERSONA-MARKER' "$SANDBOX_SYS_FILE"
check "her shelf rides — her interests are hers in public" grep -qF 'Keep a window box' "$SANDBOX_SYS_FILE"
check "the state block rides" grep -qF 'CURRENT STATE OF YOURSELF' "$SANDBOX_SYS_FILE"
check "the wake frame closes the prompt" grep -qF 'THIS WAKE IS ABOUT THE AGENDA BELOW' "$SANDBOX_SYS_FILE"
check "the policy names the closed doors" grep -qF '`crab memory` and `crab journal` refuse in this sitting' "$SANDBOX_SYS_FILE"
check "the agenda is the bridge's constant and names the inbox" grep -qF 'crab bluesky inbox' "$SANDBOX_AGENDA_FILE"
check "the agenda says the sitting is a public composition" grep -qF 'public-composition sitting' "$SANDBOX_AGENDA_FILE"

echo
echo "another booker's wake keeps ordinary recall, canaries and all:"
fire event "a file landed: report.pdf" notice-newfiles
[ -s "$SANDBOX_SYS_FILE" ] || die "the other booker's wake never handed the CLI a system prompt"
check "its tools are told it is an ordinary wake" grep -qx 'DESKCRAB_WAKE_PROFILE=wake' "$SANDBOX_ENV_FILE"
check "the general recall block is there" grep -qF '## What I remember' "$SANDBOX_SYS_FILE"
check "the pinned directive rides it" grep -qF 'CANARY-PIN' "$SANDBOX_SYS_FILE"
check "the desk transcript is there" grep -qF 'CANARY-CONVO' "$SANDBOX_SYS_FILE"
refute "and nothing of the public block" grep -qF '## Public composition' "$SANDBOX_SYS_FILE"

echo
echo "a desk turn keeps ordinary recall too:"
TURN="$(MEMORY_EMBED_URL="$MEMORY_EMBED_URL" sandbox_bash 'build_system_prompt --profile turn')"
check "the turn carries the general recall block" contains "$TURN" '## What I remember'
check "with the pinned directive" contains "$TURN" 'CANARY-PIN'
refute "and no public block" contains "$TURN" '## Public composition'

echo
echo "the profile is one command away, and its shape is the contract's:"
MAN="$("$CRAB" context --profile public --layers 2>/dev/null)"
layer() { printf '%s\n' "$MAN" | awk -F'\t' -v k="$1" '$1 == k { print $4 }'; }
check_eq "L3 is present on the public profile" "$(layer L3)" full
check_eq "L6 is absent" "$(layer L6)" absent
check_eq "the regroup block is absent" "$(layer regroup)" absent
# The shared-viewing layer is conditional and may not be a layer of this build
# at all; either way nothing of it rides a public composition.
VIEW="$(layer viewing)"
check "the viewing layer is absent, or not a layer of this build" \
    sh -c '[ -z "$1" ] || [ "$1" = absent ]' _ "$VIEW"
check_eq "L2 is present" "$(layer L2)" full
check_eq "L4 is present" "$(layer L4)" full
BODY="$("$CRAB" context --profile public 2>/dev/null)"
refute "crab context --profile public carries no canary" contains "$BODY" 'CANARY'
check "and carries the public fact" contains "$BODY" 'PUBLIC-SELF'

echo
echo "the block fails closed, never open:"
# The interpreter answers but the store will not open: the verb's own closed line.
printf 'not a directory\n' > "$SANDBOX/not-a-store"
OUT="$(DESKCRAB_MEMORY_DIR="$SANDBOX/not-a-store" "$PY" "$SANDBOX_REPO/lib/memory.py" public-block \
        --ids-out "$SANDBOX/witness/ids.json" --log "$SANDBOX/witness/closed.log" 2>/dev/null; echo "rc=$?")"
check "a store that will not open is the closed line, exit 0" contains "$OUT" 'rc=0'
check "the closed line says the door did not answer" contains "$OUT" 'The memory door did not answer'
refute "and renders no row" contains "$OUT" 'What I have said about myself'
check "the closure is logged" grep -q 'public-block closed' "$SANDBOX/witness/closed.log"
refute "and leaves no sidecar" test -e "$SANDBOX/witness/ids.json"
CLOSED="$(DESKCRAB_MEMORY_DIR="$SANDBOX/not-a-store" "$CRAB" context --profile public 2>/dev/null)"
check "the assembler carries the closed line" contains "$CLOSED" 'The memory door did not answer'
refute "and not the recall block" contains "$CLOSED" '## What I remember'
refute "and not a canary" contains "$CLOSED" 'CANARY'
# The interpreter cannot even start: the assembler's own closed line.
DEAD="$(MEMORY_PYTHON=/bin/false "$CRAB" context --profile public 2>/dev/null)"
check "a dead interpreter is the closed line too" contains "$DEAD" 'The memory door did not answer'
refute "and still not the recall block" contains "$DEAD" '## What I remember'
refute "and still no canary" contains "$DEAD" 'CANARY'
# And through the real fire path.
fire event "$BRIDGE_REASON" bluesky-bridge MEMORY_PYTHON=/bin/false
[ -s "$SANDBOX_SYS_FILE" ] || die "the bridge-booked wake under a dead door never reached the CLI"
check "a bridge-booked wake under a dead door is handed the closed line" \
    grep -qF 'The memory door did not answer' "$SANDBOX_SYS_FILE"
check_eq "and no canary reaches any argument" "$(count_in CANARY "$SANDBOX_ARGS_FILE")" 0

echo
echo "the doors the prompt names are closed in a public sitting:"
OUT="$(DESKCRAB_WAKE_PROFILE=public "$CRAB" memory search anything 2>&1; echo "rc=$?")"
check "memory search refuses" contains "$OUT" 'closed in a public-composition sitting'
check "with the gate's exit status" contains "$OUT" 'rc=64'
OUT="$(DESKCRAB_WAKE_PROFILE=public "$CRAB" memory list 2>&1)"
check "memory list refuses" contains "$OUT" 'closed in a public-composition sitting'
OUT="$(DESKCRAB_WAKE_PROFILE=public "$CRAB" memory dump 2>&1)"
check "memory dump refuses" contains "$OUT" 'closed in a public-composition sitting'
OUT="$(DESKCRAB_WAKE_PROFILE=public "$CRAB" memory recall-block --query x 2>&1)"
check "memory recall-block refuses" contains "$OUT" 'closed in a public-composition sitting'
OUT="$(DESKCRAB_WAKE_PROFILE=public "$CRAB" journal 2>&1; echo "rc=$?")"
check "journal refuses" contains "$OUT" 'closed in a public-composition sitting'
check "with the gate's exit status" contains "$OUT" 'rc=64'
OUT="$(DESKCRAB_WAKE_PROFILE=public "$CRAB" memory add --kind note --visibility public "PUBLIC-SELF-TWO I keep a window box" 2>&1; echo "rc=$?")"
check "a public fact may still be written" contains "$OUT" 'rc=0'
check "crab context --profile public carries the new public fact" \
    contains "$("$CRAB" context --profile public 2>/dev/null)" 'PUBLIC-SELF-TWO'
# `list`, not `search`: the fixture embedder is hash-based, so similarity
# finds nothing on purpose; the deliberate listing is the door being proven.
OUT="$("$CRAB" memory list 2>&1)"
check "outside a public sitting the same door opens" contains "$OUT" 'window box'

echo
echo "an unattended public write runs only on the public-composition wake:"
for verb in post like repost follow unlike unrepost unfollow undo; do
    case "$verb" in
        post) set -- post --file "$SANDBOX/absent.json" --operation fixture --why fixture ;;
        undo) set -- undo fixture ;;
        *) set -- "$verb" "at://did:plc:x/app.bsky.feed.post/y" --why fixture ;;
    esac
    OUT="$(DESKCRAB_WAKE_PROFILE=wake "$CRAB" bluesky "$@" 2>&1; echo "rc=$?")"
    check "$verb from an ordinary wake is refused" contains "$OUT" 'unattended public write runs only on the public-composition wake'
    check "$verb refusal carries the gate's exit status" contains "$OUT" 'rc=64'
done
OUT="$(DESKCRAB_WAKE_PROFILE=public "$CRAB" bluesky post --file "$SANDBOX/absent.json" --operation fixture --why fixture 2>&1)"
refute "post from the public sitting passes the gate" contains "$OUT" 'unattended public write'
OUT="$("$CRAB" bluesky post --file "$SANDBOX/absent.json" --operation fixture --why fixture 2>&1)"
refute "post from a desk turn passes the gate" contains "$OUT" 'unattended public write'
OUT="$(DESKCRAB_WAKE_PROFILE=wake "$CRAB" bluesky inbox --peek 2>&1)"
check "reading the inbox is open to every sitting" contains "$OUT" 'untrusted-social-data'
OUT="$(DESKCRAB_WAKE_PROFILE=public "$CRAB" bluesky inbox --peek 2>&1)"
check "and to the public one" contains "$OUT" 'untrusted-social-data'
