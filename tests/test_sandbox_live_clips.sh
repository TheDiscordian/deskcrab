#!/bin/bash
# The touch gate reads live state and accuses; it must never DELETE live state
# (specs/test-harness.md rule 9). The sweep this pins against removed any
# /tmp/deskcrab-remote-*.opus a run had added, reasoning that shipping code
# hangs its reply audio off STATE_PREFIX now so a new clip could only be a
# leak — and on 2026-08-11 it deleted three clips the LIVE phone server had
# just synthesised and not yet served, cutting the spoken reply off
# mid-sentence. The live server and a hardcoded-path defect write the SAME
# path; the harness cannot tell the authors apart, so it may only accuse.
#
# This drives a child test through the real sandbox. The child writes a
# hardcoded live-prefix clip mid-run — the exact shape the sweep hunted, and
# equally the exact shape of a live clip landing during the run. The file
# must survive the child's exit, and the leak check must name it.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

MARK="/tmp/deskcrab-remote-crabtest$$.opus"
CHILD="$SANDBOX/tmp/child-live-clip.sh"
cat > "$CHILD" <<CHILD
#!/bin/bash
. "$SANDBOX_REPO/tests/lib/sandbox.sh"
printf 'not really opus' > "$MARK"
ok "wrote a live-prefix clip mid-run (the ambiguous shape)"
CHILD
chmod +x "$CHILD"

# A fresh phase-1 for the child: strip the outer sandbox's identity so the
# child builds its own root and takes its own photographs. Its hardcoded live
# prefix is the real /tmp, which is exactly the point.
OUT="$(env -u DESKCRAB_SANDBOX_ROOT -u DESKCRAB_SANDBOX_REPO \
        -u DESKCRAB_SANDBOX_LIB -u DESKCRAB_SANDBOX_NAME \
        bash "$CHILD" 2>&1)" || true

check "the live-prefix file survived the child's leak check" test -f "$MARK"
check "the leak check named the file it did not touch" contains "$OUT" "$MARK"
if contains "$OUT" "shipping code wrote a live path"; then
    fail "the harness still deletes live files (the removal note printed)"
else
    ok "no removal note — the harness's hand stayed off live state"
fi

# The planted file is this test's own live write; it is created and removed
# between the outer photographs, so the outer gate sees /tmp as it found it.
rm -f "$MARK"
