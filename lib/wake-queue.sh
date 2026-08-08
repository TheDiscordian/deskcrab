#!/bin/bash
# lib/wake-queue.sh — the wake queue, and the ONLY thing that touches it.
#
# Sourced by lib/common.sh. Nothing outside this file may read $WAKES_DIR, mint
# a unit name, call systemd-run for a wake, or stop a wake timer. Every booker
# — `crab wake-at`, the promise auditor, the job runner, the self-change
# watcher, its canary, the new-file watcher, the chain floor — comes through
# wake_book(). That single door is what makes the queue answerable: on
# 2026-08-07 twenty-five bookings sat on disk while every prompt and every
# `crab status` said "(none scheduled)", because the report enumerated systemd
# and nothing in the whole repo enumerated the records.
#
# The public operations are:
#   wake_list     enumerate the records, join the timers onto them
#   wake_book     book one, under the lock, spaced, coalesced, recorded first
#   wake_cancel   the only real cancellation — timer AND record
#   wake_restore  rebuild timers from records after a reboot or a cancellation
#   wake_tidy     purge the fired ghosts, collapse the repeats, spread the piles
#
# THE RECORD IS THE AUTHORITY. A timer is only ever the record's shadow: it
# lives inside one running user manager and dies with it, while the record is a
# file. Everything here reads records first and asks systemd second.
#
# Record format, tab separated, fixed order:
#     fire-epoch \t kind \t reason \t booked-at \t booked-by
# Readers tolerate the older three-field shape — every record written before
# 2026-08-07 has it — and fill the missing fields with "unknown" rather than
# shifting the ones that are there.

# The durable ledger. Every booking, cancellation, restoration, collapse and
# purge lands here, because a queue change is a fact she has to be able to
# read: `wake_restore` used to rebuild a whole cancelled backlog into
# /dev/null, so twenty-two calls-off were silently undone and nothing anywhere
# said so.
WAKE_LEDGER="${WAKE_LEDGER:-$WAKES_DIR/ledger.log}"
WAKE_LEDGER_KEEP="${WAKE_LEDGER_KEEP:-2000}"
# The unit-level ceiling on a wake session. The in-process stall watchdog
# cannot by construction reap a session that keeps emitting output, so this is
# the backstop — and it is TimeoutStartSec, not RuntimeMaxSec: a transient
# systemd-run service is Type=oneshot, and the journal has been saying
# "RuntimeMaxSec= has no effect in combination with Type=oneshot. Ignoring."
# for as long as the ceiling has existed. For a oneshot the whole run counts as
# its start, so the start timeout is the runtime bound that actually applies.
WAKE_RUNTIME_MAX="${WAKE_RUNTIME_MAX:-7200}"
# Where the LIVE queue lives, regardless of what this instance was pointed at.
# The fourth gate below compares against it.
WAKE_LIVE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/wakes"

# --- The ledger ------------------------------------------------------------
wake_ledger() {  # <action> <unit> <kind> <reason> <actor>
    mkdir -p "$WAKES_DIR" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "${2:-}" "${3:-}" \
        "$(printf '%s' "${4:-}" | tr '\n\t' '  ' | head -c 200)" "${5:-unknown}" \
        >> "$WAKE_LEDGER" 2>/dev/null
    # Bounded like the sessions log: it is a record she reads, not an archive.
    local n
    n="$(wc -l < "$WAKE_LEDGER" 2>/dev/null || echo 0)"
    if [ "$n" -gt $(( WAKE_LEDGER_KEEP * 2 )) ]; then
        tail -n "$WAKE_LEDGER_KEEP" "$WAKE_LEDGER" > "$WAKE_LEDGER.tmp" 2>/dev/null \
            && mv "$WAKE_LEDGER.tmp" "$WAKE_LEDGER" 2>/dev/null
    fi
    return 0
}

# Ledger lines since an epoch, as "<action>\t<count>" — what the state block
# reads to say "the queue changed while you were away".
wake_ledger_since() {  # <epoch>
    [ -s "$WAKE_LEDGER" ] || return 0
    awk -F'\t' -v cut="${1:-0}" '$1 + 0 >= cut { n[$2]++ }
        END { for (a in n) printf "%s\t%d\n", a, n[a] }' "$WAKE_LEDGER" 2>/dev/null | sort
}

# --- Records ---------------------------------------------------------------
# Arity normalisation, applied on write AND on read. `crab wake-at <when>
# [kind] [reason]` was positional with no validation, so a caller passing an
# agenda where the kind goes wrote the agenda into the kind field and left the
# reason empty — and `crab wake` then blanked any kind it did not recognise,
# destroying the agenda outright. One such record is on disk right now: a
# whole "re-dispatch the builder" brief sitting in the kind column. Normalising
# on read is what gets it back.
_wake_norm() {  # <kind> <reason>  -> WK_N_KIND, WK_N_REASON
    local k="${1:-}" r="${2:-}"
    case "$k" in
        scheduled|event|'') ;;
        *)  # Not a kind. It is the reason — keep it, and take the default kind.
            [ -n "$r" ] || r="$k"
            k="scheduled" ;;
    esac
    WK_N_KIND="$k"; WK_N_REASON="$r"
}

# Split a tab-separated line WITHOUT losing empty fields.
#
# `IFS=$'\t' read -r a b c d e` cannot do this: a tab is IFS *whitespace*, and
# bash collapses runs of IFS whitespace into one delimiter. A record with an
# empty reason — every "come back to the wants" booking has one — therefore
# read back with the booked-at in the reason column and the provenance in the
# booked-at column. It never showed before because the reason used to be the
# LAST field, where `read` hands over the remainder untouched.
_split_tabs() {  # <line>  -> _TF[]
    local line="$1"
    _TF=()
    while :; do
        case "$line" in
            *$'\t'*) _TF+=("${line%%$'\t'*}"); line="${line#*$'\t'}" ;;
            *) _TF+=("$line"); break ;;
        esac
    done
}

# Read one record into WK_FIRE / WK_KIND / WK_REASON / WK_BOOKED_AT /
# WK_BOOKED_BY. Tolerant of the three-field shape: the missing fields become
# "unknown", never a shift of the fields that ARE there.
wake_record_read() {  # <record path>
    WK_FIRE=""; WK_KIND=""; WK_REASON=""; WK_BOOKED_AT=""; WK_BOOKED_BY=""
    [ -s "$1" ] || return 1
    local line fire kind reason at by
    IFS= read -r line < "$1"
    _split_tabs "$line"
    fire="${_TF[0]:-}"; kind="${_TF[1]:-}"; reason="${_TF[2]:-}"
    at="${_TF[3]:-}"; by="${_TF[4]:-}"
    case "${fire:-}" in ''|*[!0-9]*) return 1 ;; esac
    _wake_norm "$kind" "$reason"
    WK_FIRE="$fire"; WK_KIND="$WK_N_KIND"; WK_REASON="$WK_N_REASON"
    WK_BOOKED_AT="${at:-unknown}"; WK_BOOKED_BY="${by:-unknown}"
    [ -n "$WK_BOOKED_AT" ] || WK_BOOKED_AT="unknown"
    [ -n "$WK_BOOKED_BY" ] || WK_BOOKED_BY="unknown"
    return 0
}

# The durable half of a booking: one small file per pending wake. The timer is
# what fires; this record is what survives the timer's death. Always written in
# the five-field shape, always normalised, so a record read back is a record
# that still knows its own agenda.
wake_state_write() {  # <unit> <fire-epoch> <kind> <reason> [booked-at] [booked-by]
    mkdir -p "$WAKES_DIR"
    _wake_norm "${3:-}" "${4:-}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$WK_N_KIND" \
        "$(printf '%s' "$WK_N_REASON" | tr '\n\t' '  ')" \
        "${5:-$(date +%s)}" "${6:-${DESKCRAB_WAKE_ORIGIN:-herself}}" \
        > "$WAKES_DIR/$1.wake"
}

wake_state_clear() {
    rm -f -- "$WAKES_DIR/$1.wake"
}

# --- Systemd, read once ----------------------------------------------------
# One call, not two per record. The state block is built on the hot path of
# every turn, and `systemctl is-active` twice over twenty-five records is fifty
# process spawns in front of a spoken reply.
declare -A _WAKE_UNIT_STATE
_wake_load_unit_states() {
    _WAKE_UNIT_STATE=()
    local u s
    while read -r u s; do
        [ -n "$u" ] || continue
        _WAKE_UNIT_STATE["$u"]="$s"
    done < <(systemctl --user list-units --all --no-pager --legend=false --plain \
                 'deskcrab-wake-*' 2>/dev/null | awk 'NF >= 4 { print $1, $3 }')
    return 0
}

# "<unit>\t<next-elapse string>" for every deskcrab timer systemd will admit to.
# Only consulted for rows that have no record — a record already knows its own
# moment, and a transient --on-active timer reports monotonic time that
# NextElapseUSecRealtime cannot answer.
_wake_timer_nexts() {
    systemctl --user list-timers --all --no-pager --legend=false 'deskcrab-*' 2>/dev/null \
        | awk '$1 ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/ {
                 u = ""
                 for (i = 1; i <= NF; i++) if ($i ~ /\.timer$/) u = $i
                 if (u != "") printf "%s\t%s %s %s %s\n", u, $1, $2, $3, $4
               }'
}

# --- The fourth gate -------------------------------------------------------
# job-runner already refuses to reach the live me from a scratch jobs
# directory; the booking side had no equivalent, which is how a /tmp test
# checkout came to hold an armed timer in the live user manager. Isolating what
# a test may TOUCH says nothing about what it may ARM.
#
# A run whose WAKES_DIR is not the live one does not get to create a real unit.
# The record is still written — a scratch instance with records and no timers
# is exactly the "recorded, no live timer" state the queue is supposed to be
# able to describe — and a harness that has stubbed systemd-run says so with
# DESKCRAB_ALLOW_SCRATCH_BOOKING=1, which is how a test asserts on the argv.
_wake_manager_is_live() {
    [ -z "${DESKCRAB_NO_DISPATCH:-}" ] || return 1
    [ "$WAKES_DIR" = "$WAKE_LIVE_DIR" ] && return 0
    [ -n "${DESKCRAB_ALLOW_SCRATCH_BOOKING:-}" ] && return 0
    return 1
}

# --- Booking ---------------------------------------------------------------
# When "2h" / "45min" / "09:30" will actually fire, as an epoch. Relative specs
# are computed directly; calendar specs are resolved through systemd-analyze so
# the recorded moment is exactly the one systemd would pick. Prints nothing
# when the spec is unparseable.
wake_when_to_epoch() {
    local when="$1" n
    if [[ "$when" =~ ^([0-9]+)(s|sec|min|m|h|hr|hours?|d|days?)$ ]]; then
        n="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            s|sec) : ;;
            m|min) n=$((n * 60)) ;;
            h|hr|hour|hours) n=$((n * 3600)) ;;
            *) n=$((n * 86400)) ;;
        esac
        echo $(( $(date +%s) + n ))
    else
        local next
        next="$(systemd-analyze calendar "$when" 2>/dev/null \
                | awk -F': +' '/Next elapse/ { print $2; exit }')"
        [ -n "$next" ] && date -d "$next" +%s 2>/dev/null
    fi
}

# An equivalent pending booking, if one exists: same kind, same reason, firing
# within WAKE_COALESCE_WINDOW of the proposed moment. Prints its unit name. Two
# "come back to the wants" promises minutes apart are one promise — each fired
# wake re-reads the same wants and re-announces the same progress, so the
# second booking adds noise, not coverage.
#
# An event booking coalesces only against a BYTE-IDENTICAL reason. Two
# different events are two wakes and must both survive; but the same event
# booked twice is one event — and that is not hypothetical, it is how a wake
# blocked on the wake lock re-books itself, carrying the same kind and the same
# reason it arrived with. The old rule ("event wakes never coalesce") let a
# blocked event wake stack a fresh copy of itself on every retry.
wake_pending_equivalent() {  # <fire-epoch> <kind> <reason>
    [ "${WAKE_COALESCE_WINDOW:-0}" -gt 0 ] || return 1
    case "$2" in
        scheduled) : ;;
        event) [ -n "$3" ] || return 1 ;;
        *) return 1 ;;
    esac
    local f now diff
    now=$(date +%s)
    for f in "$WAKES_DIR"/*.wake; do
        [ -e "$f" ] || continue
        wake_record_read "$f" || continue
        [ "$WK_KIND" = "$2" ] || continue
        [ "$WK_FIRE" -gt "$now" ] || continue
        [ "$WK_REASON" = "$3" ] || continue
        diff=$(( WK_FIRE - $1 )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
        if [ "$diff" -le "$WAKE_COALESCE_WINDOW" ]; then
            f="${f##*/}"; printf '%s\n' "${f%.wake}"
            return 0
        fi
    done
    return 1
}

# How long to wait before a booking, in seconds, avoiding moments that are
# already taken. Prints a delay, not a moment.
#
# This is the fix for three timers at 12:09:15 with sequential ids. Only one
# wake session runs at a time (the wake lock); a wake that finds the lock held
# pushes itself back and tries again. That push-back was a FLAT 15 minutes, so
# three wakes blocked within the same minute all re-armed to the same second,
# one of them took the lock, and the other two were blocked again and marched
# on together — for as long as anything kept feeding the queue. It was never a
# loop and never a double booking: it was a convoy with no spacing.
#
# And it is asked by EVERY booking, not only by the retries: spacing the
# retries alone was measurably not enough — within a minute of that fix, two
# concurrent sessions booking different wakes had rebuilt the collision from
# the front. A nudge of a few minutes costs a promise to herself nothing;
# landing on another wake's second costs it a quarter of an hour.
wake_free_slot() {  # [base-delay-seconds] -> delay in seconds
    local base="${1:-$WAKE_DEFER_DELAY}" now cand f diff clash guard=0
    now=$(date +%s); cand=$(( now + base ))
    while [ "$guard" -lt 64 ]; do
        clash=0
        for f in "$WAKES_DIR"/*.wake; do
            [ -e "$f" ] || continue
            wake_record_read "$f" || continue
            [ "$WK_FIRE" -gt "$now" ] || continue
            diff=$(( WK_FIRE - cand )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
            if [ "$diff" -lt "$WAKE_SLOT_SPREAD" ]; then clash=1; break; fi
        done
        [ "$clash" = 0 ] && break
        cand=$(( cand + WAKE_SLOT_SPREAD )); guard=$(( guard + 1 ))
    done
    echo $(( cand - now ))
}

# A unit name nothing else is using. Timestamp + pid was not enough: a single
# process re-booking two wakes inside one second produced the same name twice,
# and the second systemd-run silently lost to the first. No caller builds a
# unit name inline — `crab wake-at` used to, and a collision there truncated
# the earlier booking with no word said.
_WAKE_UNIT_SEQ=0
_wake_new_unit() {
    _WAKE_UNIT_SEQ=$(( _WAKE_UNIT_SEQ + 1 ))
    local u="deskcrab-wake-$(date +%s)-$$"
    [ "$_WAKE_UNIT_SEQ" -gt 1 ] && u="$u-$_WAKE_UNIT_SEQ"
    while [ -e "$WAKES_DIR/$u.wake" ]; do
        _WAKE_UNIT_SEQ=$(( _WAKE_UNIT_SEQ + 1 ))
        u="deskcrab-wake-$(date +%s)-$$-$_WAKE_UNIT_SEQ"
    done
    printf '%s\n' "$u"
}

# The transient half: one systemd-run timer carrying its own booking id and its
# provenance, so the wake it fires can retire its record and a deferral can
# re-book in the same name. The ONLY caller of systemd-run in this project's
# wake path.
#
# Always a DELAY, never a calendar specification. A bare '09:45' handed to
# systemd makes a timer that comes back every morning while the record covers
# only the next firing — a wake-at is one-shot, and it is now one-shot in
# systemd too.
#
# --collect so a failed unit does not leak into the user manager (two were
# sitting failed when this was written, one of them pointing at a deleted /tmp
# checkout), and a start timeout so a runaway session has a ceiling the
# in-process watchdog cannot provide.
_wake_book() {  # <unit> <delay, e.g. 900s> <kind> <reason> [booked-by]
    local unit="$1" when="$2" kind="$3" reason="$4" by="${5:-unknown}"
    if ! _wake_manager_is_live; then
        echo "  (scratch instance — record kept for $unit, no timer armed)" >&2
        return 0
    fi
    case "$when" in
        *[!0-9]s) : ;;
        *) when="$(printf '%s' "$when" | tr -cd '0-9')s" ;;
    esac
    local -a extra=(--collect -p "TimeoutStartSec=$WAKE_RUNTIME_MAX")
    [ -n "${DESKCRAB_CONF:-}" ] && extra+=(--setenv=DESKCRAB_CONF="$DESKCRAB_CONF")
    [ -n "${DESKCRAB_STATE_PREFIX:-}" ] && extra+=(--setenv=DESKCRAB_STATE_PREFIX="$DESKCRAB_STATE_PREFIX")
    systemd-run --user --quiet --unit="$unit" "${extra[@]}" --on-active="$when" \
        "$SCRIPT_DIR/crab" wake "$kind" "$reason" "$unit" "$by"
}

# Book a wake. THE door: coalescing, spacing, the record, the timer, the
# rollback and the ledger line all live behind it.
#
#   wake_book [--by <origin>] [--cap <n>] <when> [kind] [reason]
#
# --by names the subsystem doing the booking, and it is not decoration: six
# non-conversational hands book wakes in her name — the promise auditor, the job
# runner, the two watchers, the canary and this module's own chain floor — and
# with no provenance on the record "nothing scheduled by me" was literally
# unanswerable. specs/wake-queue.md rule 41 holds the whole roster.
# --cap bounds how many pending wakes one booker may hold — counted from the
# RECORDS, under this lock, and it drains as well as gates. A cap that only
# refused new bookings let a queue five to six times its own size stand for
# hours while the auditor logged "capped" over and over.
wake_book() {
    local by="" cap=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --by)  by="${2:-}"; shift 2 || return 1 ;;
            --cap) cap="${2:-}"; shift 2 || return 1 ;;
            *) break ;;
        esac
    done
    [ -n "$by" ] || by="${DESKCRAB_WAKE_ORIGIN:-herself}"
    # One booker at a time, for the WHOLE check-then-act. Two wakes finishing
    # in the same second each found no pending floor and each booked one.
    { flock -w 30 6; _wake_book_locked "$by" "$cap" "$@"; } 6>"$WAKE_BOOK_LOCK"
}

_wake_book_locked() {  # <by> <cap> <when> [kind] [reason]
    local by="$1" cap="$2" when="${3:-}" kind="${4:-scheduled}" reason="${5:-}"
    [ -n "$when" ] || { echo "wake_book: no moment given."; return 1; }
    mkdir -p "$WAKES_DIR"
    _wake_norm "$kind" "$reason"; kind="$WK_N_KIND"; reason="$WK_N_REASON"

    local fire now
    fire="$(wake_when_to_epoch "$when")"
    if [ -z "$fire" ]; then
        echo "Cannot make sense of '$when' — nothing scheduled."
        return 1
    fi

    [ -n "$cap" ] && ! _wake_cap_admits "$by" "$cap" && return 0

    local existing
    if existing="$(wake_pending_equivalent "$fire" "$kind" "$reason")"; then
        echo "Wake already pending as $existing (fires within $((WAKE_COALESCE_WINDOW / 60))min of '$when') — not booking another."
        return 0
    fi

    now=$(date +%s)
    local delay slot newfire unit
    delay=$(( fire - now )); [ "$delay" -lt 1 ] && delay=1
    slot="$(wake_free_slot "$delay")"
    newfire=$(( now + slot ))
    if [ "$newfire" -ne "$fire" ]; then
        echo "Moved off a moment another wake already holds: $(date -d "@$fire" '+%H:%M:%S') -> $(date -d "@$newfire" '+%H:%M:%S')"
        fire="$newfire"
    fi
    unit="$(_wake_new_unit)"
    # Record first, timer second: a crash between the two leaves a record the
    # reconciler honours, where the other order leaves a timer nothing
    # remembers. And if the timer cannot be armed, the record goes back —
    # a failed booking must not become a phantom promise.
    wake_state_write "$unit" "$fire" "$kind" "$reason" "$now" "$by"
    if _wake_book "$unit" "${slot}s" "$kind" "$reason" "$by"; then
        wake_ledger booked "$unit" "$kind" "$reason" "$by"
        echo "Wake scheduled ($when — $(date -d "@$fire" '+%H:%M:%S')) as $unit, booked by $by"
        return 0
    fi
    wake_state_clear "$unit"
    wake_ledger book-failed "$unit" "$kind" "$reason" "$by"
    echo "Failed to schedule wake ($when)."
    return 1
}

# The cap, counted from the records under the booking lock, draining first.
# Returns 0 when there is room for one more.
_wake_cap_admits() {  # <booked-by> <cap>
    local by="$1" cap="$2" now f u n=0 _line
    case "$cap" in ''|*[!0-9]*) return 0 ;; esac
    now=$(date +%s)
    # SOONEST FIRST, so that the ones past the cap — the tail of this list —
    # are the ones that would have come back LAST. A queue over its cap loses
    # its far end and keeps the work about to happen. The verdict that booked
    # each of them is already in the auditor's own log, so a drained booking
    # loses the alarm clock and nothing else.
    #
    # The sort was descending here, which drained the queue from exactly the
    # wrong end: the wake five hours out survived and the one due in an hour
    # was cancelled, over and over, for as long as the auditor kept booking.
    local -a doomed=()
    while IFS= read -r _line; do
        _split_tabs "$_line"; unit="${_TF[1]:-}"
        [ -n "$unit" ] || continue
        n=$(( n + 1 ))
        [ "$n" -gt "$cap" ] && doomed+=("$unit")
    done < <(for f in "$WAKES_DIR"/*.wake; do
                 [ -e "$f" ] || continue
                 wake_record_read "$f" || continue
                 [ "$WK_BOOKED_BY" = "$by" ] || continue
                 [ "$WK_FIRE" -gt "$now" ] || continue
                 u="${f##*/}"
                 printf '%s\t%s\n' "$WK_FIRE" "${u%.wake}"
             done | sort -n)
    local u
    for u in ${doomed[@]+"${doomed[@]}"}; do
        _wake_cancel_one "$u" "$by cap drain"
        n=$(( n - 1 ))
    done
    if [ "$n" -ge "$cap" ]; then
        echo "Not booked — $by already holds $n pending wakes (cap $cap)."
        return 1
    fi
    return 0
}

# --- Enumeration -----------------------------------------------------------
# The records, with the timers joined ONTO them — never the reverse. Prints
# one row per pending wake, soonest first:
#
#   fire-epoch \t unit \t kind \t reason \t booked-at \t booked-by \t state
#
# state is one of:
#   armed       record and a live timer — the ordinary case
#   firing      its service is running right now (it cleared its record already)
#   unarmed     a record with NO live timer: the booking whose timer died with a
#               user manager, and exactly what `crab wake-restore` exists to heal
#   orphan      a transient timer with no record: either a booking whose record
#               was lost or a unit from another instance, and both are worth
#               seeing
#   background  the standing random-interval timer, which has no record by design
wake_list() {
    _wake_load_unit_states
    local f unit st u base nexts=""
    {
        # The records, soonest first.
        for f in "$WAKES_DIR"/*.wake; do
            [ -e "$f" ] || continue
            wake_record_read "$f" || continue
            unit="${f##*/}"; unit="${unit%.wake}"
            st=unarmed
            case "${_WAKE_UNIT_STATE[$unit.service]:-}" in
                active|activating) st=firing ;;
                *) case "${_WAKE_UNIT_STATE[$unit.timer]:-}" in
                       active|waiting) st=armed ;;
                   esac ;;
            esac
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$WK_FIRE" "$unit" "${WK_KIND:-scheduled}" "$WK_REASON" \
                "$WK_BOOKED_AT" "$WK_BOOKED_BY" "$st"
        done | sort -n
        # Timers nothing remembers, and the standing background timer. Both
        # only ever need the next-elapse table, so it is built at most once.
        for u in "${!_WAKE_UNIT_STATE[@]}"; do
            case "$u" in *.timer) ;; *) continue ;; esac
            base="${u%.timer}"
            case "$base" in deskcrab-wake-[0-9]*) ;; *) continue ;; esac
            [ -s "$WAKES_DIR/$base.wake" ] && continue
            [ -n "$nexts" ] || nexts="$(_wake_timer_nexts)"$'\n'
            printf '%s\t%s\t-\t%s\t-\t-\torphan\n' \
                "$(_wake_next_epoch "$u" "$nexts")" "$base" "(no booking record)"
        done
        case "${_WAKE_UNIT_STATE[deskcrab-wake.timer]:-}" in
            active|waiting)
                [ -n "$nexts" ] || nexts="$(_wake_timer_nexts)"$'\n'
                printf '%s\tdeskcrab-wake\tbackground\t%s\t-\tsystemd\tbackground\n' \
                    "$(_wake_next_epoch deskcrab-wake.timer "$nexts")" \
                    "the standing random-interval wake" ;;
        esac
    }
}

# The moment a record-less timer fires, from the next-elapse table. 0 when
# systemd will not say — a transient --on-active timer reports monotonic time,
# and inventing a clock reading for it would be worse than admitting the gap.
_wake_next_epoch() {  # <unit> <table>
    local line
    line="$(printf '%s' "$2" | awk -F'\t' -v u="$1" '$1 == u { print $2; exit }')"
    [ -n "$line" ] || { echo 0; return 0; }
    date -d "$line" +%s 2>/dev/null || echo 0
}

# --- Cancellation ----------------------------------------------------------
# The ONLY real cancellation. Stopping a timer is not one: the record survives
# and wake_restore brings it back — which is precisely what happened on
# 2026-08-07, when a backlog cancelled with `systemctl stop` came back in full
# an hour later, verbatim, and nothing anywhere said so.
_wake_cancel_one() {  # <unit> <actor>
    local unit="${1%.timer}"
    wake_record_read "$WAKES_DIR/$unit.wake" || { WK_KIND=""; WK_REASON=""; }
    if _wake_manager_is_live; then
        systemctl --user stop "$unit.timer" >/dev/null 2>&1
        systemctl --user reset-failed "$unit.timer" "$unit.service" >/dev/null 2>&1
    fi
    wake_state_clear "$unit"
    wake_ledger cancelled "$unit" "$WK_KIND" "$WK_REASON" "${2:-by hand}"
}

wake_cancel() {  # <unit> | --all
    if [ "${1:-}" = "--all" ]; then
        local f unit n=0
        for f in "$WAKES_DIR"/*.wake; do
            [ -e "$f" ] || continue
            unit="${f##*/}"; unit="${unit%.wake}"
            _wake_cancel_one "$unit" "${2:-by hand (--all)}"
            n=$(( n + 1 ))
        done
        echo "Cancelled $n pending wake$([ "$n" = 1 ] || echo s)."
        return 0
    fi
    [ -n "${1:-}" ] || { echo "Usage: crab wake-cancel <unit> | --all   (pending wakes: crab status)"; return 1; }
    _wake_cancel_one "$1" "${2:-by hand}"
    echo "Cancelled ${1%.timer}"
}

# --- Restore ---------------------------------------------------------------
# Rebuild timers from the booking records. Run at login by
# deskcrab-wake-restore.service and at the end of every wake; harmless to run
# by hand. Still-future bookings come back at their original moment. Overdue
# ones — the machine was off when they were due — fire once, promptly, but
# staggered (90 s, then +5 min apart) so a long-off machine does not wake a
# crowd at once.
#
# Overdue duplicates collapse, and that now covers EVENT wakes too. It used to
# merge only kind=scheduled with an empty reason, so twenty-two identical-shaped
# promise wakes came back one for one.
#
# Every restoration is written to the ledger. This function's output used to go
# to /dev/null from ensure_next_wake, which is how a bulk resurrection became
# invisible; a bulk restore means a cancellation was undone or the machine
# rebooted, and that is a fact she has to be able to read.
wake_restore() {
    local now f unit overdue=0 delay key restored=0
    now=$(date +%s)
    local -a seen=()
    while IFS=$'\t' read -r _ f; do
        [ -n "$f" ] && [ -e "$f" ] || continue
        unit="${f##*/}"; unit="${unit%.wake}"
        # A live timer needs nothing from us; a dead one may linger as failed
        # and would block systemd-run reusing its name.
        if _wake_manager_is_live; then
            systemctl --user is-active --quiet "$unit.timer" && continue
            systemctl --user reset-failed "$unit.timer" "$unit.service" 2>/dev/null
        fi
        wake_record_read "$f" || continue
        if [ "$WK_FIRE" -gt "$now" ]; then
            if _wake_book "$unit" "$(( WK_FIRE - now ))s" "$WK_KIND" "$WK_REASON" "$WK_BOOKED_BY"; then
                wake_ledger restored "$unit" "$WK_KIND" "$WK_REASON" "$WK_BOOKED_BY"
                restored=$(( restored + 1 ))
                echo "restored: $unit fires $(date -d "@$WK_FIRE" '+%F %H:%M') (${WK_KIND:-scheduled}${WK_REASON:+ — $WK_REASON}, booked by $WK_BOOKED_BY)"
            fi
            continue
        fi
        # Overdue. Two identical promises are one promise however they were
        # kinded — a queue of them coming back in full is the resurrection
        # nobody could see.
        key="${WK_KIND:-scheduled}"$'\x1f'"$WK_REASON"
        local dup="" s
        for s in ${seen[@]+"${seen[@]}"}; do
            [ "$s" = "$key" ] && { dup=1; break; }
        done
        if [ -n "$dup" ]; then
            wake_state_clear "$unit"
            wake_ledger collapsed "$unit" "$WK_KIND" "$WK_REASON" "restore (duplicate overdue)"
            echo "collapsed: $unit (duplicate overdue promise — one of these is enough)"
            continue
        fi
        seen+=("$key")
        delay=$(( 90 + overdue * 300 )); overdue=$(( overdue + 1 ))
        wake_state_write "$unit" "$(( now + delay ))" "$WK_KIND" "$WK_REASON" \
            "$WK_BOOKED_AT" "$WK_BOOKED_BY"
        if _wake_book "$unit" "${delay}s" "$WK_KIND" "$WK_REASON" "$WK_BOOKED_BY"; then
            wake_ledger overdue "$unit" "$WK_KIND" "$WK_REASON" "$WK_BOOKED_BY"
            restored=$(( restored + 1 ))
            echo "overdue: $unit (was due $(date -d "@$WK_FIRE" '+%F %H:%M')) fires in ${delay}s"
        fi
    done < <(for f in "$WAKES_DIR"/*.wake; do
                 [ -e "$f" ] || continue
                 wake_record_read "$f" || continue
                 printf '%s\t%s\n' "$WK_FIRE" "$f"
             done | sort -n)
    [ "$restored" -eq 0 ] && echo "wake queue needs no restoring (every booking already has its timer)"
    return 0
}

# --- Tidy ------------------------------------------------------------------
# Housekeeping, safe to run at any time and run at the end of every wake. Three
# jobs, all of them things the queue cannot do for itself:
#
#  1. Purge transient timers that have ALREADY FIRED and have no booking
#     record. A one-shot wake unit stays loaded after it fires, but its record
#     was retired the moment it fired, so nothing remembers it and nothing
#     intends it. "Already fired" is the whole safety rule here, and it is
#     load-bearing: a timer that has NEVER fired and has no record is not a
#     ghost, it is a pending wake whose record some other hand removed, and
#     killing it would cancel a wake nobody asked to cancel. Left alone, it
#     fires and does its work.
#  2. Collapse bookings that are the same promise (same kind, same reason,
#     within WAKE_COALESCE_WINDOW). The earliest survives.
#  3. Spread bookings that landed on top of each other. Two wakes cannot run at
#     once, so two bookings in the same second are one wake and one deferral.
#
# A unit whose SERVICE is active is skipped everywhere — that is a wake firing
# right now, and it cleared its own record first thing. Under the booking lock,
# like every writer of the queue: two tidies running at once would each judge
# the other's fresh booking a duplicate.
wake_tidy() {
    { flock -w 30 6; _wake_tidy_locked; } 6>"$WAKE_BOOK_LOCK"
}

_wake_tidy_locked() {
    local u base purged=0 collapsed=0 spread=0
    mkdir -p "$WAKES_DIR"
    for u in $(systemctl --user list-units --all --no-pager --legend=false 'deskcrab-wake-*.timer' 2>/dev/null \
               | grep -o 'deskcrab-wake-[0-9][^ ]*\.timer'); do
        base="${u%.timer}"
        systemctl --user is-active --quiet "$base.service" && continue
        [ -s "$WAKES_DIR/$base.wake" ] && continue
        # Never fired = never a ghost. LastTriggerUSec is empty until the
        # timer has actually gone off at least once.
        [ -n "$(systemctl --user show "$u" -p LastTriggerUSec --value 2>/dev/null)" ] || continue
        systemctl --user stop "$u" >/dev/null 2>&1
        systemctl --user reset-failed "$u" "$base.service" >/dev/null 2>&1
        purged=$(( purged + 1 ))
        wake_ledger purged "$base" "" "" "tidy (already fired, no record)"
        echo "purged: $base (already fired — no booking record)"
    done

    local f unit fire kind reason now keptf keptk keptr newfire newunit at by
    local -a kf=() kk=() kr=()
    now=$(date +%s)
    while IFS=$'\t' read -r fire f; do
        [ -n "$f" ] && [ -e "$f" ] || continue
        unit="${f##*/}"; unit="${unit%.wake}"
        systemctl --user is-active --quiet "$unit.service" && continue
        wake_record_read "$f" || continue
        fire="$WK_FIRE"; kind="$WK_KIND"; reason="$WK_REASON"
        at="$WK_BOOKED_AT"; by="$WK_BOOKED_BY"
        [ "$fire" -gt "$now" ] || continue
        local i=0 dup="" near=0 diff
        while [ "$i" -lt "${#kf[@]}" ]; do
            keptf="${kf[$i]}"; keptk="${kk[$i]}"; keptr="${kr[$i]}"
            diff=$(( fire - keptf )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
            if [ "$keptk" = "$kind" ] && [ "$keptr" = "$reason" ] \
               && [ "$diff" -le "${WAKE_COALESCE_WINDOW:-900}" ]; then
                dup=1; break
            fi
            [ "$diff" -lt "$WAKE_SLOT_SPREAD" ] && near=1
            i=$(( i + 1 ))
        done
        if [ -n "$dup" ]; then
            _wake_cancel_one "$unit" "tidy (same promise as one already pending)"
            collapsed=$(( collapsed + 1 ))
            echo "collapsed: $unit (same promise as one already pending)"
            continue
        fi
        if [ "$near" = 1 ]; then
            # Retire this booking BEFORE asking for a free slot, or its own
            # record is the collision the search is trying to avoid.
            if _wake_manager_is_live; then
                systemctl --user stop "$unit.timer" >/dev/null 2>&1
                systemctl --user reset-failed "$unit.timer" "$unit.service" >/dev/null 2>&1
            fi
            wake_state_clear "$unit"
            newfire=$(( now + $(wake_free_slot $(( fire - now )) ) ))
            newunit="$(_wake_new_unit)"
            wake_state_write "$newunit" "$newfire" "$kind" "$reason" "$at" "$by"
            if _wake_book "$newunit" "$(( newfire - now ))s" "$kind" "$reason" "$by"; then
                spread=$(( spread + 1 ))
                wake_ledger spread "$newunit" "$kind" "$reason" "tidy (was $unit)"
                echo "spread: $unit -> $(date -d "@$newfire" '+%H:%M:%S') (was sharing a moment with another wake)"
                fire="$newfire"
            else
                wake_state_clear "$newunit"
                wake_state_write "$unit" "$fire" "$kind" "$reason" "$at" "$by"
            fi
        fi
        kf+=("$fire"); kk+=("$kind"); kr+=("$reason")
    done < <(for f in "$WAKES_DIR"/*.wake; do
                 [ -e "$f" ] || continue
                 wake_record_read "$f" || continue
                 printf '%s\t%s\n' "$WK_FIRE" "$f"
             done | sort -n)
    [ $(( purged + collapsed + spread )) -eq 0 ] && echo "wake queue is tidy (nothing purged, collapsed or spread)"
    return 0
}

# --- The floor -------------------------------------------------------------
# Agency over her own time. Wants only get worked on when something wakes her
# to work on them, so a wake that ends without scheduling the next one quietly
# breaks the chain — the intent survives in the wants file, but nothing ever
# comes back to it. Only a pending wake that will COME BACK TO THE WANTS
# counts: a scheduled-kind booking does, an event wake is pending for its
# event. The old check counted any deskcrab-wake-* timer, so one unrelated
# long-dated booking suppressed every floor booking and the chain ended anyway.
# This is a floor, not a schedule: a wake that scheduled its own follow-up is
# left alone. Judged from the RECORDS, never from systemd.
ENSURE_WAKE_DELAY="${ENSURE_WAKE_DELAY:-45min}"
ensure_next_wake() {
    [ -n "$WANTS_FILE" ] || return 0
    # Heal first: any booking whose timer died with a past user manager gets
    # its timer back now, not only at next login. Then tidy: drop the fired
    # timers nothing remembers, collapse repeated promises, and spread any that
    # landed on the same second.
    #
    # Neither output is discarded. It used to go to /dev/null, which is how a
    # cancelled backlog could be rebuilt in full with nobody the wiser; the
    # ledger keeps the durable copy and this stream reaches the journal.
    wake_restore
    wake_tidy
    local f now
    now=$(date +%s)
    for f in "$WAKES_DIR"/*.wake; do
        [ -e "$f" ] || continue
        wake_record_read "$f" || continue
        [ "$WK_KIND" = "scheduled" ] && [ "$WK_FIRE" -gt "$now" ] && return 0
    done
    wake_book --by wake-chain-floor "$ENSURE_WAKE_DELAY" scheduled "" >/dev/null 2>&1 || true
}
