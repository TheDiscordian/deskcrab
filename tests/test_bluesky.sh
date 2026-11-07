#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u
export SANDBOX

python3 "$SANDBOX_REPO/tests/test_bluesky.py" > "$SANDBOX/bluesky-tests.log" 2>&1
rc=$?
cat "$SANDBOX/bluesky-tests.log"
check_eq "Bluesky isolated Python suite" "$rc" 0

out="$("$SANDBOX_REPO/crab" bluesky status 2>&1)"
check "unconfigured CLI is readable" contains "$out" '"configured": false'
check "CLI database uses the sandbox pin" test -f "$DESKCRAB_BLUESKY_DIR/social.sqlite3"
out="$(DESKCRAB_ENG_ROLE=builder "$SANDBOX_REPO/crab" bluesky post --file absent --operation fixture --why fixture 2>&1)"
check "detached builder cannot post" contains "$out" 'unavailable to detached builders'
out="$(DESKCRAB_ENG_ROLE=builder "$SANDBOX_REPO/crab" bluesky inbox 2>&1)"
check "builder inbox stays untrusted" contains "$out" 'untrusted-social-data'

# specs/bluesky.md clause 21: the only unattended road to a public write is the
# public-composition wake. The whole-prompt proof is tests/test_bluesky_public_prompt.sh;
# these are the connector's own gate, in both directions.
out="$(DESKCRAB_WAKE_PROFILE=wake "$SANDBOX_REPO/crab" bluesky post --file absent --operation fixture --why fixture 2>&1)"
check "an ordinary autonomous sitting cannot post" contains "$out" 'unattended public write runs only on the public-composition wake'
out="$(DESKCRAB_WAKE_PROFILE=wake "$SANDBOX_REPO/crab" bluesky follow did:plc:fixture --why fixture 2>&1)"
check "an ordinary autonomous sitting cannot follow" contains "$out" 'unattended public write'
out="$(DESKCRAB_WAKE_PROFILE=public "$SANDBOX_REPO/crab" bluesky post --file absent --operation fixture --why fixture 2>&1)"
if contains "$out" 'unattended public write'; then fail "the public-composition sitting is refused its own write"; else ok "the public-composition sitting reaches the connector"; fi
out="$(DESKCRAB_WAKE_PROFILE=public "$SANDBOX_REPO/crab" bluesky inbox --peek 2>&1)"
check "the public sitting reads its inbox" contains "$out" 'untrusted-social-data'

# Source through the one sandbox, with an explicitly isolated social store.
. "$SANDBOX_REPO/lib/common.sh"
out="$(_prompt_layer_index)"
check "normal prompt exposes social memory" contains "$out" 'crab bluesky inbox --peek'
check "normal prompt contains only a numeric summary" contains "$out" '0 unread events'

cat > "$SANDBOX/queue-door" <<'SH'
#!/bin/bash
. "$SANDBOX_REPO/lib/common.sh"
[ "$1" = wake-at ] || exit 1
shift
wake_book "$@"
SH
chmod +x "$SANDBOX/queue-door"
export SANDBOX_REPO
DESKCRAB_CRAB="$SANDBOX/queue-door" python3 - <<'PY'
import sys,os
sys.path.insert(0,os.path.join(os.environ['SANDBOX_REPO'],'lib'))
import bluesky as b
s=b.Store(b.home())
s.event('fixture','notification',{'text':'public text must not become an agenda'})
s.db.commit()
b.book_wake(s)
s.db.close()
PY
record="$(cat "$WAKES_DIR"/*.wake 2>/dev/null)"
check "social booker reaches the real scratch queue" contains "$record" 'bluesky-bridge'
check "wake names the inbox" contains "$record" 'crab bluesky inbox'
check "wake says it is a public-composition sitting" contains "$record" 'public-composition sitting'
if contains "$record" 'public text must not'; then fail "public content reached the wake agenda"; else ok "public content stays outside the wake agenda"; fi

# specs/bluesky.md clauses 4a, 13, 15, 16: the builder gates on the new verbs, the person door
# through the real CLI, and the numeric-only prompt summary.
out="$(DESKCRAB_ENG_ROLE=builder "$SANDBOX_REPO/crab" bluesky remember did:plc:fixture 'a fact' 2>&1)"
check "detached builder cannot file a person memory" contains "$out" 'unavailable to detached builders'
out="$(DESKCRAB_ENG_ROLE=builder "$SANDBOX_REPO/crab" bluesky cancel fixture 2>&1)"
check "detached builder cannot cancel an intent" contains "$out" 'unavailable to detached builders'
out="$("$SANDBOX_REPO/crab" bluesky intents 2>&1)"
check "intents are listable and empty on a fresh store" contains "$out" '[]'
out="$("$SANDBOX_REPO/crab" bluesky summary 2>&1)"
check "offline summary counts people" contains "$out" '0 people known'
check "offline summary counts queued intents" contains "$out" '0 queued intents'
if [ -n "${MEMORY_PYTHON:-}" ] && "$MEMORY_PYTHON" -c 'import sqlite_vec' 2>/dev/null; then
    out="$("$SANDBOX_REPO/crab" bluesky person did:plc:nobody 2>&1)"
    check "person door answers an unknown DID with an empty retained context" contains "$out" '"count": 0'
    check "person door never grants authority" contains "$out" '"privileged_authority": false'
    check "person door reads the pinned memory store" test -f "$DESKCRAB_MEMORY_DIR/memory.db"
    out="$("$SANDBOX_REPO/crab" bluesky person not-a-did 2>&1)"
    if contains "$out" '"count"'; then fail "a non-DID actor must not open a person context without resolution"; else ok "a non-DID actor is resolved or refused, never keyed"; fi
else
    ok "person door CLI check skipped: no memory interpreter on this box"
fi
