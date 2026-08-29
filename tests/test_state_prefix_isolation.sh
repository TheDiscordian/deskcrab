#!/usr/bin/env bash
# specs/test-harness.md rules 13a-13b: isolation is the DEFAULT, and the live
# state prefix is claimed by the canonical install, never inherited by a copy.
#
# The incident these rules answer: on 2026-08-07, test wakes running out of a
# /tmp copy of the repo spoke their turns into the REAL conversation, because
# STATE_PREFIX defaulted to the live prefix and isolation was opt-in through
# DESKCRAB_STATE_PREFIX. Every copy of the code was born holding the live
# instance's mouth unless it remembered to let go.
#
# What is proven here, against the SHIPPED resolution in lib/common.sh (the
# same file `crab` and every entry script source after their own readlink -f):
#   (a) a copy of the repo, run with no override, derives a stable prefix of
#       its own — never /tmp/deskcrab — under $TMPDIR, distinct per copy,
#       identical across runs of the same copy, and exported so children
#       inherit the answer rather than re-defaulting to the live prefix;
#   (b) those runs create and touch NOTHING under the live /tmp/deskcrab*
#       glob, photographed here exactly the way the harness photographs it;
#   (c) a canonical-install-shaped layout — ~/.local/lib/deskcrab a symlink to
#       the checkout's lib/, entered through that symlink the way the deploy
#       is — still resolves the live prefix;
#   (d) an explicit DESKCRAB_STATE_PREFIX beats both the canonical claim and
#       the derived isolation;
# and every choice above lands in the prefix-choice log with its reason
# (rule 13b), which the sandbox pins to a witness file so the canonical-shaped
# run in (c) records its choice without writing beside the live instance.
#
# Run: bash tests/test_state_prefix_isolation.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"

# Two independent copies of the repo tree, as a forgotten test harness or a
# scratch checkout would have them. lib/ is the whole library; crab rides
# along so the copy is repo-shaped, but the probe enters through lib/common.sh
# — the one resolution both `crab` and every entry script share — because
# `crab` with an unrecognised argument starts a turn, which is not a thing a
# test does even against a stub.
COPY_A="$T/copy-a"; COPY_B="$T/copy-b"
mkdir -p "$COPY_A" "$COPY_B"
cp -R "$REPO/lib" "$COPY_A/lib"; cp "$REPO/crab" "$COPY_A/crab"
cp -R "$REPO/lib" "$COPY_B/lib"; cp "$REPO/crab" "$COPY_B/crab"

# The live-prefix photograph, in exactly the harness's shape: the moment
# stamped first, then name, size, mtime, the external movers dropped, so what
# this test accuses is what the harness would accuse.
live_photo() { # <out>
    date +%s.%N > "$1.at"
    find "$(dirname "$SANDBOX_LIVE_PREFIX")" -maxdepth 1 \
        -name "$(basename "$SANDBOX_LIVE_PREFIX")*" \
        ! -path "$SANDBOX*" \
        -printf '%p\t%s\t%T@\n' 2>/dev/null \
        | _sandbox_drop_external "$SANDBOX_LIVE_PREFIX" "$SANDBOX_LIVE_DATA" \
        | LC_ALL=C sort > "$1"
}

# The probes run beside a live instance whose hands keep writing — the game
# harness alone rewrites its /tmp state every two seconds all night — so the
# pair is held to the harness's own standard (specs/test-harness.md rule 9's
# second look): a difference convicts only when the path had no foreign
# evidence by a third photograph. What the probes could have written settles
# and stays accused; the other hand's churn is excused by name.
settled() { # <before> <after> — 0 when nothing of this run's own moved
    diff -q "$1" "$2" >/dev/null 2>&1 && return 0
    local settle="${DESKCRAB_SANDBOX_SETTLE:-5}" rounds round
    rounds="$(awk -v v="${DESKCRAB_SANDBOX_VIGIL:-60}" -v s="$settle" \
        'BEGIN { r = (s + 0 > 0) ? int(v / s) : 1; print (r < 1) ? 1 : r }')"
    for (( round = 1; round <= rounds; round++ )); do
        sleep "$settle"
        live_photo "$2.settle"
        sandbox_second_look "$1" "$2" "$2.settle" "$2.look" && return 0
    done
    return 1
}

# probe <common.sh path> — source the real library with NO override in hand,
# and report three lines: the prefix it chose, the reason it recorded, and
# what a child process inherits as DESKCRAB_STATE_PREFIX.
probe() {
    env -u DESKCRAB_STATE_PREFIX bash -c '
        source "$1" >/dev/null 2>&1
        printf "%s\n%s\n" "${STATE_PREFIX:-}" "${STATE_PREFIX_WHY:-}"
        bash -c "printf \"%s\n\" \"\${DESKCRAB_STATE_PREFIX:-unset}\""
    ' _ "$1"
}

# probe_explicit <common.sh path> <prefix> — same, with the override set.
probe_explicit() {
    env DESKCRAB_STATE_PREFIX="$2" bash -c '
        source "$1" >/dev/null 2>&1
        printf "%s\n%s\n" "${STATE_PREFIX:-}" "${STATE_PREFIX_WHY:-}"
    ' _ "$1"
}

# --- (a) + (b): the isolated copies -----------------------------------------

live_photo "$T/live.before"

OUT_A="$(probe "$COPY_A/lib/common.sh")"
PFX_A="$(sed -n 1p <<<"$OUT_A")"
WHY_A="$(sed -n 2p <<<"$OUT_A")"
CHILD_A="$(sed -n 3p <<<"$OUT_A")"

OUT_A2="$(probe "$COPY_A/lib/common.sh")"
PFX_A2="$(sed -n 1p <<<"$OUT_A2")"

OUT_B="$(probe "$COPY_B/lib/common.sh")"
PFX_B="$(sed -n 1p <<<"$OUT_B")"

live_photo "$T/live.after"

check "a copy run with no override does not choose the live prefix" \
    [ "$PFX_A" != "/tmp/deskcrab" ]
check "the copy's prefix is non-empty" [ -n "$PFX_A" ]
case "$PFX_A" in
    "$TMPDIR"/deskcrab-????????) ok "the derived prefix lives under \$TMPDIR in the harness's shape: $PFX_A" ;;
    *) fail "the derived prefix lives under \$TMPDIR in the harness's shape" "$PFX_A" ;;
esac
check_eq "the copy records WHY as isolated" "$WHY_A" "isolated"
check_eq "the same copy derives the same prefix on a second run" "$PFX_A2" "$PFX_A"
check "a different copy derives a different prefix" [ "$PFX_B" != "$PFX_A" ]
check "the second copy does not choose the live prefix either" \
    [ "$PFX_B" != "/tmp/deskcrab" ]
check_eq "a child of the run inherits the resolved prefix, exported" \
    "$CHILD_A" "$PFX_A"
check "no live-prefix file was created or touched by the isolated runs" \
    settled "$T/live.before" "$T/live.after"

PREFIX_LOG="${DESKCRAB_PREFIX_LOG:-}"
check "the sandbox pins the prefix-choice log" [ -n "$PREFIX_LOG" ]
check "the isolated choice was recorded with its reason" \
    grep -q "	$PFX_A	isolated\$" "$PREFIX_LOG"

# --- (c): the canonical-install-shaped layout --------------------------------
# The real deploy topology (test-harness.md rule 15): ~/.local/lib/deskcrab is
# a symlink into the checkout's lib/, and the run enters THROUGH the symlink,
# which is what an installed unit or ~/.local/bin/crab does. $HOME here is the
# sandbox's own, so the layout is built without touching the real one.
CANON="$T/canon"
mkdir -p "$CANON" "$HOME/.local/lib"
cp -R "$REPO/lib" "$CANON/lib"
ln -s "$CANON/lib" "$HOME/.local/lib/deskcrab"

live_photo "$T/live.canon.before"
OUT_C="$(probe "$HOME/.local/lib/deskcrab/common.sh")"
PFX_C="$(sed -n 1p <<<"$OUT_C")"
WHY_C="$(sed -n 2p <<<"$OUT_C")"
# ...and entered directly, the way a hand in the checkout does. Both entries
# must agree: the claim is about the resolved directory, not the spelling.
OUT_C2="$(probe "$CANON/lib/common.sh")"
PFX_C2="$(sed -n 1p <<<"$OUT_C2")"
live_photo "$T/live.canon.after"

check_eq "a canonical-install-shaped run, through the symlink, claims the live prefix" \
    "$PFX_C" "/tmp/deskcrab"
check_eq "the canonical claim records WHY as canonical" "$WHY_C" "canonical"
check_eq "entering the same layout directly resolves the same claim" \
    "$PFX_C2" "/tmp/deskcrab"
check "the canonical-shaped run still wrote nothing under the live prefix" \
    settled "$T/live.canon.before" "$T/live.canon.after"
check "the canonical choice was recorded with its reason" \
    grep -q "	/tmp/deskcrab	canonical\$" "$PREFIX_LOG"

# --- (d): the explicit override beats both -----------------------------------
OWN="$T/own/prefix"
mkdir -p "$T/own"

OUT_D="$(probe_explicit "$HOME/.local/lib/deskcrab/common.sh" "$OWN")"
check_eq "an explicit DESKCRAB_STATE_PREFIX beats the canonical claim" \
    "$(sed -n 1p <<<"$OUT_D")" "$OWN"
check_eq "...and records WHY as explicit" "$(sed -n 2p <<<"$OUT_D")" "explicit"

OUT_E="$(probe_explicit "$COPY_A/lib/common.sh" "$OWN")"
check_eq "an explicit DESKCRAB_STATE_PREFIX beats the derived isolation" \
    "$(sed -n 1p <<<"$OUT_E")" "$OWN"
check_eq "...with the same recorded reason" "$(sed -n 2p <<<"$OUT_E")" "explicit"
