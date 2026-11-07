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
if contains "$record" 'public text must not'; then fail "public content reached the wake agenda"; else ok "public content stays outside the wake agenda"; fi
