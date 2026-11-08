#!/bin/bash
# A booked wake stays on its booked moment when the user manager reloads.
# Run: bash tests/test_wake_reload_drift.sh
#
# What happened: on 2026-10-02 every pending wake in the live queue stood armed
# for a later moment than its record named — seven sittings, five of them
# already past the time recorded, one booked for a Thursday at 14:00 and armed
# for the Friday of the week after. The timers had been armed as delays
# (`systemd-run --on-active`), a delay is counted from the timer's activation,
# and the user manager starts that count again on every `daemon-reload`. The
# record kept the civil time that was booked, `crab status` reads the records,
# and so everything she could see said the sittings were still coming when
# promised. Restore skipped any unit whose timer was merely active, so the one
# pass that could have healed them called the queue whole.
#
# This file asks a REAL user manager, because the defect lives in what systemd
# does and a stub can only repeat what its author believed. The manager is a
# private one: started here, under this test's own root, with its own runtime
# directory and a unit path holding nothing but its own transient units — it
# loads none of the machine's units and is never the live manager, which the
# sandbox keeps out of reach as it always has. Everything armed in it dies with
# it at exit, and what a unit would run is a stub that only writes down that it
# fired — which nothing here may do.
#
#   1. a wake booked through the one door is armed at its record's own epoch,
#      as one dated instant;
#   2. a daemon-reload of that manager moves neither the timer nor the record —
#      while a delay timer armed beside it as the control IS moved by the very
#      same reload, which is what makes the first claim mean something;
#   3. a delay timer left by the old arming is re-armed at its record's epoch
#      by restore, the record untouched;
#   4. a personal sitting whose moment passed under such a timer is re-seated
#      at its own clock time and never armed for the prompt overdue slot, while
#      a missed event wake still is.
#
# specs/wake-queue.md rules 8, 30a and 30b.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
W="$T/wakes"
M="$T/mgr"
mkdir -p "$W" "$M/run" "$M/home" "$M/units" "$T/realbin" "$T/fired"
chmod 700 "$M/run"
: > "$T/wants.md"

# --- the private manager ---------------------------------------------------
# The real tools, by absolute path: the sandbox's stubs are first on PATH, and
# they are the right answer for every other test.
REAL_RUN="$(PATH=/usr/bin:/bin command -v systemd-run 2>/dev/null)"
REAL_CTL="$(PATH=/usr/bin:/bin command -v systemctl 2>/dev/null)"
SYSTEMD_BIN=""
for _c in /usr/lib/systemd/systemd /lib/systemd/systemd; do
    [ -x "$_c" ] && { SYSTEMD_BIN="$_c"; break; }
done
[ -n "$REAL_RUN" ] && [ -n "$REAL_CTL" ] && [ -n "$SYSTEMD_BIN" ] ||
    sandbox_skip "no systemd on this box — the reload this test performs needs a real user manager"

# The targets a transient unit's default dependencies name, and nothing else.
for _t in default basic shutdown exit; do
    printf '[Unit]\nDescription=private test manager (%s)\n' "$_t" > "$M/units/$_t.target"
done
env -i PATH="$PATH" HOME="$M/home" XDG_RUNTIME_DIR="$M/run" \
    XDG_CONFIG_HOME="$M/home/.config" XDG_DATA_HOME="$M/home/.local/share" \
    SYSTEMD_UNIT_PATH="$M/run/systemd/transient:$M/units" \
    setsid "$SYSTEMD_BIN" --user --log-target=console > "$M/mgr.log" 2>&1 &
MGR_PID=$!
mgr_stop() {
    # SIGRTMIN+24 is a user manager's immediate exit; the unit path above has
    # no exit.target for a SIGTERM to walk through.
    kill -s RTMIN+24 "$MGR_PID" 2>/dev/null
    local n=0
    while kill -0 "$MGR_PID" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$(( n + 1 )); done
    kill -KILL "$MGR_PID" 2>/dev/null
    # The manager leaves read-only nodes in its runtime directory, and the
    # sandbox removes its root with a plain rm.
    chmod -R u+rwx "$M" 2>/dev/null
}
sandbox_at_exit mgr_stop
_n=0
until [ -S "$M/run/systemd/private" ] || ! kill -0 "$MGR_PID" 2>/dev/null || [ "$_n" -ge 100 ]; do
    sleep 0.1; _n=$(( _n + 1 ))
done
[ -S "$M/run/systemd/private" ] && kill -0 "$MGR_PID" 2>/dev/null ||
    sandbox_skip "a private user manager could not be started here ($(tail -1 "$M/mgr.log" 2>/dev/null))"

ln -s "$REAL_RUN" "$T/realbin/systemd-run"
ln -s "$REAL_CTL" "$T/realbin/systemctl"
ctl() { XDG_RUNTIME_DIR="$M/run" "$REAL_CTL" --user "$@" 2>/dev/null; }
# Proof the manager answering is the private one and holds nothing of ours yet.
check_eq "the private manager is up and holds no wake unit" \
    "$(ctl list-units --all --no-legend 'deskcrab-*' | wc -l)" "0"

# What a fired unit would run: a stub that writes down that it fired. The lib
# beside it is the real one, so the module finds its own helpers.
ln -s "$SANDBOX_REPO/lib" "$T/fired/lib"
cat > "$T/fired/crab" <<FIRED
#!/bin/bash
printf '%s\n' "\$*" >> "$T/fired.log"
FIRED
chmod +x "$T/fired/crab"

# The queue module against the scratch queue AND the private manager.
run() { # <shell body>
    PATH="$T/realbin:$PATH" XDG_RUNTIME_DIR="$M/run" \
        WAKES_DIR="$W" WANTS_FILE="$T/wants.md" \
        sandbox_bash 'SCRIPT_DIR="'"$T/fired"'"; '"$*" 2>&1
}
# A timer the way the old arming made one: a delay, counted from activation.
legacy_timer() { # <unit> <delay seconds>
    XDG_RUNTIME_DIR="$M/run" "$REAL_RUN" --user --quiet --unit="$1" --collect \
        --on-active="${2}s" "$T/fired/crab" wake legacy "$1" 2>/dev/null
}
record() { # <unit> <fire-epoch> <kind> <reason> <booked-by>
    printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$(date +%s)" "$5" > "$W/$1.wake"
}
fire_of() { awk -F'\t' '{ print $1; exit }' "$W/$1.wake" 2>/dev/null; }
# Where a timer stands, as the manager tells it: "@<epoch>" for a dated timer,
# nothing for a delay timer — the manager cannot give a delay a wall-clock.
stands() { ctl show "$1.timer" -p NextElapseUSecRealtime --value --timestamp=unix; }
# The same for ANY timer, from the listing, which converts a delay to a clock
# reading. Zone pinned so the reading parses whatever the box's own zone is.
listed() { # <unit> -> epoch
    local when
    when="$(TZ=UTC ctl list-timers --all --no-legend "$1.timer" | awk '{ print $2, $3, $4; exit }')"
    date -d "$when" +%s 2>/dev/null
}
armed_as() { ctl cat "$1.timer" | grep -E '^On(Calendar|ActiveSec)=' | cut -d= -f1 | tr '\n' ' '; }
led_count() { awk -F'\t' -v a="$1" '$2 == a { n++ } END { print n + 0 }' "$W/ledger.log" 2>/dev/null || echo 0; }
clock() { date -d "@$1" '+%H:%M:%S'; }

echo
echo "a booked wake is armed at its record's own moment:"
out="$(run 'wake_book --by herself 2h scheduled "an evening with the book"')"
UNIT="$(ls "$W"/*.wake 2>/dev/null | head -1)"; UNIT="${UNIT##*/}"; UNIT="${UNIT%.wake}"
[ -n "$UNIT" ] || die "the booking wrote no record" "$out"
FIRE="$(fire_of "$UNIT")"
SUM="$(cksum < "$W/$UNIT.wake")"
check_eq "the manager holds its timer, waiting" \
    "$(ctl show "$UNIT.timer" -p ActiveState --value)" "active"
check_eq "and the timer stands on the record's epoch, to the second" "$(stands "$UNIT")" "@$FIRE"
check_eq "armed as one dated instant, with no delay beside it" "$(armed_as "$UNIT")" "OnCalendar "

# The control: the old arming, beside it, in the same manager.
legacy_timer deskcrab-wake-control 7200 || die "the control timer could not be armed"
CONTROL_BEFORE="$(listed deskcrab-wake-control)"
check "the control delay timer is armed and readable" [ -n "$CONTROL_BEFORE" ]

echo
echo "the user manager reloads, and the booked moment does not move:"
# Long enough that a restarted delay is measurably later — the drift a reload
# causes is exactly the time the timer had already waited.
_t0="$(date +%s)"
until [ "$(date +%s)" -ge "$(( _t0 + 4 ))" ]; do sleep 0.2; done
XDG_RUNTIME_DIR="$M/run" "$REAL_CTL" --user daemon-reload ||
    die "the private manager refused to reload"
check_eq "the wake's timer still stands on the record's epoch" "$(stands "$UNIT")" "@$FIRE"
check_eq "the record is byte for byte what it was" "$(cksum < "$W/$UNIT.wake")" "$SUM"
row="$(run 'wake_list' | awk -F'\t' -v u="$UNIT" '$2 == u')"
check_eq "the queue still reports that moment" "$(printf '%s' "$row" | cut -f1)" "$FIRE"
check_eq "and reports the booking armed" "$(printf '%s' "$row" | cut -f7)" "armed"
CONTROL_AFTER="$(listed deskcrab-wake-control)"
check "while the same reload DID move the delay timer armed beside it" \
    [ "$(( ${CONTROL_AFTER:-0} - ${CONTROL_BEFORE:-0} ))" -ge 3 ]
out="$(run 'wake_restore')"
case "$out" in
    *"needs no restoring"*) ok "and restore finds nothing to heal" ;;
    *) fail "an agreeing timer needs nothing from restore" "$out" ;;
esac
check_eq "the timer restore looked at is still on its epoch" "$(stands "$UNIT")" "@$FIRE"
ctl stop deskcrab-wake-control.timer

echo
echo "a delay timer left by the old arming is put back on its record:"
NOW="$(date +%s)"
record deskcrab-wake-legacy $(( NOW + 5400 )) scheduled "booked before the repair" herself
legacy_timer deskcrab-wake-legacy 9000 || die "the legacy timer could not be armed"
LSUM="$(cksum < "$W/deskcrab-wake-legacy.wake")"
check_eq "before: the manager cannot even give it a wall-clock moment" \
    "$(stands deskcrab-wake-legacy)" ""
check "before: it stands an hour off its record" \
    [ "$(( $(listed deskcrab-wake-legacy) - (NOW + 5400) ))" -ge 3000 ]
out="$(run 'wake_restore')"
check_eq "after restore the timer stands on the record's epoch" \
    "$(stands deskcrab-wake-legacy)" "@$(( NOW + 5400 ))"
check_eq "armed as a dated instant now" "$(armed_as deskcrab-wake-legacy)" "OnCalendar "
check_eq "the record was not rewritten to suit the timer" \
    "$(cksum < "$W/deskcrab-wake-legacy.wake")" "$LSUM"
check_eq "the ledger says reconciled" "$(led_count reconciled)" "1"
case "$out" in
    *"reconciled: deskcrab-wake-legacy"*) ok "and restore says so out loud" ;;
    *) fail "a reconciled timer must be reported" "$out" ;;
esac
check_eq "the wake booked at the start was left exactly where it stood" "$(stands "$UNIT")" "@$FIRE"
XDG_RUNTIME_DIR="$M/run" "$REAL_CTL" --user daemon-reload
check_eq "and a second reload moves the healed timer nowhere" \
    "$(stands deskcrab-wake-legacy)" "@$(( NOW + 5400 ))"

echo
echo "a sitting whose moment passed under a drifted timer is re-seated, not fired blind:"
NOW="$(date +%s)"
MISSED=$(( NOW - 3 * 86400 - 5 * 3600 ))
record deskcrab-wake-sitting "$MISSED" scheduled "the table, two more rows" herself
record deskcrab-wake-event $(( NOW - 7200 )) event "a job that finished" job-runner
legacy_timer deskcrab-wake-sitting 30000 || die "the sitting's stale timer could not be armed"
legacy_timer deskcrab-wake-event 30000 || die "the event's stale timer could not be armed"
out="$(run 'wake_restore')"
RESEAT="$(fire_of deskcrab-wake-sitting)"
check "the sitting's record names a moment still to come" [ "${RESEAT:-0}" -gt "$NOW" ]
check_eq "at the clock time it was booked for" "$(clock "${RESEAT:-0}")" "$(clock "$MISSED")"
check_eq "its timer stands on exactly that moment" "$(stands deskcrab-wake-sitting)" "@$RESEAT"
check_eq "armed as a dated instant — not the prompt overdue delay" \
    "$(armed_as deskcrab-wake-sitting)" "OnCalendar "
check_eq "the ledger says reseated" "$(led_count reseated)" "1"
case "$out" in
    *"reseated: deskcrab-wake-sitting"*) ok "and restore says so out loud" ;;
    *) fail "a re-seating must be reported" "$out" ;;
esac
# The event wake has something waiting on the other end of it: prompt, as ever.
EVFIRE="$(fire_of deskcrab-wake-event)"
check "the missed EVENT wake comes back within minutes, not tomorrow" \
    [ "$(( ${EVFIRE:-0} - NOW ))" -le 200 ]
check "and no sooner than the overdue stagger" [ "$(( ${EVFIRE:-0} - NOW ))" -ge 60 ]
check_eq "on the near lane's delay" "$(armed_as deskcrab-wake-event)" "OnActiveSec "
check_eq "ledgered as overdue" "$(led_count overdue)" "1"
# Called off before it can come due: this manager must fire nothing.
run 'wake_cancel deskcrab-wake-event' > /dev/null
check_eq "a cancellation takes the real timer with it" \
    "$(ctl show deskcrab-wake-event.timer -p ActiveState --value)" "inactive"

echo
echo "nothing armed here ever fired:"
check "no unit ran its command" [ ! -s "$T/fired.log" ]
