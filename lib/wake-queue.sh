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
# EVERY ONE OF THEM THAT WRITES TAKES THE BOOKING LOCK. Four of the five do,
# and for a while only two did: cancel and restore mutated records and systemd
# units with no lock at all, so `wake-cancel --all` running beside a finishing
# wake's restore could have the restore re-arm a unit the cancel was about to
# forget — an armed timer with no booking record, which nothing purges (it has
# never fired) and which fires a wake the user explicitly called off.
# specs/wake-queue.md rule 6.
#
# THE RECORD IS THE AUTHORITY. A timer is only ever the record's shadow: it
# lives inside one running user manager and dies with it, while the record is a
# file. Everything here reads records first and asks systemd second.
#
# Record format, tab separated, fixed order:
#     fire-epoch \t kind \t reason \t booked-at \t booked-by [\t effort [\t model]]
# Readers tolerate the older three-field shape — every record written before
# 2026-08-07 has it — and fill the missing fields with "unknown" rather than
# shifting the ones that are there. The sixth field is the per-wake effort
# override (specs/wake-queue.md rule 13a) and the seventh the per-wake model
# pin (rule 13b), each empty on every booking made without one; absent and
# empty read the same, and a model riding without an effort leaves the sixth
# field empty rather than sliding into it.

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
# The turn-cluster fold (specs/wake-queue.md rule 10b). Each folded item is cut
# through utf8_trim at this bound before it joins the reason's list, so every
# item's opening clause stays legible and the reason stays whole UTF-8 however
# many one cluster catches.
WAKE_CLUSTER_ITEM_MAX="${WAKE_CLUSTER_ITEM_MAX:-200}"
# The connective the fold writes once and then extends with '; "item"'. A
# plain constant, not a config knob: the fold recognises an already-folded
# reason by this exact text, and two instances disagreeing about it would
# each start a second list on the other's wake.
WAKE_CLUSTER_FOLD_MARK=" Also caught in this same cluster: "

# --- The ledger ------------------------------------------------------------
# Appended and trimmed through log_append_bounded (lib/common.sh): several
# unsynchronised hands write this file, and the old `tail > ledger.tmp && mv`
# lost every line appended between the read and the rename while two
# rotations raced each other through the one fixed temp name.
#
# The reason is bounded, and the bound must never split a character. A bare
# `head -c 200` cuts on bytes, and an em-dash straddling byte 200 left its
# lone leading 0xE2 in the live ledger — one byte that made grep classify the
# WHOLE file as binary and answer every query with nothing, exit 0
# (2026-08-11 02:22; specs/wake-queue.md, DATA). utf8_trim (lib/common.sh) is
# that incident's repair, hoisted to the one place every bounded field is cut:
# it drops whatever partial character the byte cut leaves, with the charset
# named explicitly so it holds even in a C-locale systemd unit, where GNU
# `cut -c` and bash's ${var:0:200} both still count bytes.
wake_ledger() {  # <action> <unit> <kind> <reason> <actor>
    mkdir -p "$WAKES_DIR" 2>/dev/null
    log_append_bounded "$WAKE_LEDGER" "$WAKE_LEDGER_KEEP" \
        "$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$(date +%s)" "$1" "${2:-}" "${3:-}" \
            "$(utf8_trim "${4:-}" 200)" "${5:-unknown}")"
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
# WK_BOOKED_BY / WK_EFFORT / WK_MODEL. Tolerant of the three-field shape: the
# missing fields become "unknown", never a shift of the fields that ARE there.
# The effort and model overrides have no "unknown" — a record without one IS a
# record without one, and the wake runs at the config default.
wake_record_read() {  # <record path>
    WK_FIRE=""; WK_KIND=""; WK_REASON=""; WK_BOOKED_AT=""; WK_BOOKED_BY=""
    WK_EFFORT=""; WK_MODEL=""
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
    WK_EFFORT="${_TF[5]:-}"
    WK_MODEL="${_TF[6]:-}"
    [ -n "$WK_BOOKED_AT" ] || WK_BOOKED_AT="unknown"
    [ -n "$WK_BOOKED_BY" ] || WK_BOOKED_BY="unknown"
    return 0
}

# The reason as the RECORD will hold it. Newlines and tabs are squashed on the
# way in, so any comparison against a stored reason has to squash its own side
# too — wake_pending_equivalent compared a caller's raw multi-line reason
# against the sanitised copy on disk, and a byte-identical event could
# therefore never coalesce with itself.
_wake_reason_norm() {  # <reason>
    printf '%s' "${1:-}" | tr '\n\t' '  '
}

# The durable half of a booking: one small file per pending wake. The timer is
# what fires; this record is what survives the timer's death. Always written in
# the five-field shape, always normalised, so a record read back is a record
# that still knows its own agenda.
#
# Written through a temp file and renamed, because a record is read by hands
# that hold no lock — the state block, the coalescing scan, the spacing scan,
# tidy's own enumeration. An in-place truncate makes the file zero-length for
# an instant, wake_record_read rejects a zero-length file, and the booking
# vanishes from the queue for exactly as long as the write takes: it is not in
# the block, not in the spacing search, and not in the coalescing test. A
# rename is atomic and has no such window. The temp name is dot-prefixed and
# carries this pid, so it matches no reader's `*.wake` glob and no two writers
# share it.
wake_state_write() {  # <unit> <fire-epoch> <kind> <reason> [booked-at] [booked-by] [effort] [model]
    mkdir -p "$WAKES_DIR"
    _wake_norm "${3:-}" "${4:-}"
    local tmp="$WAKES_DIR/.$1.$$.wtmp"
    # The override fields only exist on a record that has one — absent and
    # empty read the same (rules 13a, 13b), and a booking without an override
    # keeps the five-field shape every reader and test already knows. A model
    # riding without an effort writes the sixth field EMPTY rather than
    # shifting into it: position is meaning in this record.
    local overrides=""
    if [ -n "${8:-}" ]; then
        overrides="$(printf '\t%s\t%s' "${7:-}" "$8")"
    elif [ -n "${7:-}" ]; then
        overrides="$(printf '\t%s' "$7")"
    fi
    if printf '%s\t%s\t%s\t%s\t%s%s\n' "$2" "$WK_N_KIND" \
        "$(_wake_reason_norm "$WK_N_REASON")" \
        "${5:-$(date +%s)}" "${6:-${DESKCRAB_WAKE_ORIGIN:-herself}}" \
        "$overrides" > "$tmp"; then
        mv -f "$tmp" "$WAKES_DIR/$1.wake"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

wake_state_clear() {
    rm -f -- "$WAKES_DIR/$1.wake"
}

# --- Systemd, read once ----------------------------------------------------
# One call, not two per record. The state block is built on the hot path of
# every turn, and `systemctl is-active` twice over twenty-five records is fifty
# process spawns in front of a spoken reply.
# 'deskcrab-wake*', not 'deskcrab-wake-*': the standing background timer is
# named deskcrab-wake.timer with no suffix at all, so the narrower pattern
# never matched it and the "background" row this table exists to render could
# not be built. Widening it brings in the permanent units, which the fixture
# guard in wake_list keeps out of the orphan count.
declare -A _WAKE_UNIT_STATE
_wake_load_unit_states() {
    _WAKE_UNIT_STATE=()
    local u s
    while read -r u s; do
        [ -n "$u" ] || continue
        _WAKE_UNIT_STATE["$u"]="$s"
    done < <(systemctl --user list-units --all --no-pager --legend=false --plain \
                 'deskcrab-wake*' 2>/dev/null | awk 'NF >= 4 { print $1, $3 }')
    return 0
}

# The permanent wake units, which are FIXTURES of the installation and never
# bookings: the standing random-interval timer and the login reconciler. Each
# is installed by hand, has never had a booking record, and is not missing one
# — reporting either as "a timer with no booking record" is how a third timer
# nobody had booked appeared in the block beside two real wakes.
_wake_unit_is_fixture() {  # <unit base name>
    case "$1" in
        deskcrab-wake|deskcrab-wake-restore) return 0 ;;
    esac
    return 1
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

# --- The booking lock ------------------------------------------------------
# ONE door for every writer of the queue, and flock's own exit status is the
# answer. `{ flock -w 30 6; work; } 6>lock` discards that status, so a timeout
# ran the entire check-then-act with no lock at all — the single thing rule 6
# exists to forbid, and the failure mode it hides is silent: a booking made
# against a queue another hand is rewriting lands on a taken second, or counts
# a cap that is mid-drain. A lock that could not be taken is reported and the
# operation does NOT happen; a booking that did not happen says so to its
# caller, which is a fact, where a booking made unlocked is a lie the queue
# tells itself.
WAKE_BOOK_LOCK_WAIT="${WAKE_BOOK_LOCK_WAIT:-30}"
_wake_under_lock() {  # <name for the message> <function> [args…]
    local what="$1" rc=0
    shift
    {
        if flock -w "$WAKE_BOOK_LOCK_WAIT" 6; then
            "$@"
            rc=$?
        else
            echo "$what: the booking lock is still held after ${WAKE_BOOK_LOCK_WAIT}s — the queue was not touched." >&2
            rc=75
        fi
    } 6>"$WAKE_BOOK_LOCK"
    return "$rc"
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
    local f now diff want
    now=$(date +%s)
    # Compared as the record HOLDS it. The caller's reason is raw and a record's
    # is squashed, so a reason carrying a newline — every builder's task
    # description does — could never match itself and an event re-booked by its
    # own deferral stacked a fresh copy every time.
    want="$(_wake_reason_norm "$3")"
    for f in "$WAKES_DIR"/*.wake; do
        [ -e "$f" ] || continue
        wake_record_read "$f" || continue
        [ "$WK_KIND" = "$2" ] || continue
        [ "$WK_FIRE" -gt "$now" ] || continue
        [ "$WK_REASON" = "$want" ] || continue
        diff=$(( WK_FIRE - $1 )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
        if [ "$diff" -le "$WAKE_COALESCE_WINDOW" ]; then
            f="${f##*/}"; printf '%s\n' "${f%.wake}"
            return 0
        fi
    done
    return 1
}

# The turn-cluster fold (specs/wake-queue.md rule 10b). Three turns finishing
# inside one minute each fired a promise audit, each audit caught its own
# sentence, and each booked its own wake — three timers nagging her to check
# the same shelf (2026-08-07 12:12, defect b of that entry). A booker that
# declares a cluster window says: my bookings of one class this close together
# are one nag. When a pending booking of the same booker, kind and class
# (the --cap-prefix) was BOOKED within the window, the new booking is not made
# at all — its item joins the pending record's reason as a short list, and the
# pending wake's fire moment is never touched. This runs INSIDE the booking
# lock and ABOVE the cap, the identical-reason coalesce and the slot search:
# a folded booking never reaches any of them, which is the point — the slot
# allocator spreading three same-shelf nags onto three different seconds is
# still three nags.
#
# The candidate's own booked-at is the cluster's anchor and the rewrite keeps
# it, so the window cannot slide forward with every catch and chain a quiet
# afternoon into one ever-growing wake. And the merged reason is re-ARMED, not
# only re-recorded: the fired wake's agenda travels in the unit's argv, so a
# record-only rewrite would nag about the first item and silently drop the
# rest. Record first, rollback on a failed re-arm (rules 4 and 5); a fold that
# cannot re-arm puts the old booking back exactly as it stood and reports
# failure, so the caller books the item separately rather than losing it.
#
# When the class's fire moment is a PROMISE — the auditor's deferred wakes
# fire at the moment she named — the pin additionally requires the pending
# fire to fall within the window of the new booking's own, or there is no
# fold: a promised moment is never traded for tidiness.
_wake_cluster_fold() {  # <by> <kind> <class-prefix> <window> <item> <fire-epoch> <pin-fire>
    local by="$1" kind="$2" prefix="$3" window="$4" item="$5" fire="$6" pin="$7"
    local now f diff best="" bestat=""
    [ -n "$prefix" ] || return 1
    now=$(date +%s)
    for f in "$WAKES_DIR"/*.wake; do
        [ -e "$f" ] || continue
        wake_record_read "$f" || continue
        [ "$WK_BOOKED_BY" = "$by" ] || continue
        [ "$WK_KIND" = "$kind" ] || continue
        case "$WK_REASON" in "$prefix"*) ;; *) continue ;; esac
        [ "$WK_FIRE" -gt "$now" ] || continue
        case "$WK_BOOKED_AT" in ''|*[!0-9]*) continue ;; esac
        diff=$(( now - WK_BOOKED_AT ))
        [ "$diff" -ge 0 ] && [ "$diff" -le "$window" ] || continue
        if [ -n "$pin" ]; then
            diff=$(( WK_FIRE - fire )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
            [ "$diff" -le "$window" ] || continue
        fi
        # The cluster's first booking is its anchor; fold onto the earliest.
        if [ -z "$best" ] || [ "$WK_BOOKED_AT" -lt "$bestat" ]; then
            best="${f##*/}"; best="${best%.wake}"; bestat="$WK_BOOKED_AT"
        fi
    done
    [ -n "$best" ] || return 1
    wake_record_read "$WAKES_DIR/$best.wake" || return 1

    local merged
    item="$(utf8_trim "$item" "$WAKE_CLUSTER_ITEM_MAX")"
    case "$WK_REASON" in
        *"$WAKE_CLUSTER_FOLD_MARK"*) merged="$WK_REASON; \"$item\"" ;;
        *) merged="$WK_REASON$WAKE_CLUSTER_FOLD_MARK\"$item\"" ;;
    esac

    local oldfire="$WK_FIRE" oldkind="$WK_KIND" oldreason="$WK_REASON"
    local oldat="$WK_BOOKED_AT" oldby="$WK_BOOKED_BY" oldeffort="$WK_EFFORT"
    local oldmodel="$WK_MODEL"
    # Retire the old pair before re-booking — the tidy spread's own dance, at
    # the SAME fire moment rather than a new one.
    if _wake_manager_is_live; then
        systemctl --user stop "$best.timer" >/dev/null 2>&1
        systemctl --user reset-failed "$best.timer" "$best.service" >/dev/null 2>&1
    fi
    wake_state_clear "$best"
    local newunit
    newunit="$(_wake_new_unit)"
    wake_state_write "$newunit" "$oldfire" "$oldkind" "$merged" "$oldat" "$oldby" "$oldeffort" "$oldmodel"
    if _wake_book "$newunit" "$(( oldfire - now ))s" "$oldkind" "$merged" "$oldby" "$oldeffort" "$oldmodel"; then
        wake_ledger folded "$newunit" "$oldkind" "$merged" "$by (cluster fold, was $best)"
        echo "Folded into the cluster's pending wake: $newunit still fires $(date -d "@$oldfire" '+%H:%M:%S'), now carrying this item too."
        return 0
    fi
    wake_state_clear "$newunit"
    wake_state_write "$best" "$oldfire" "$oldkind" "$oldreason" "$oldat" "$oldby" "$oldeffort" "$oldmodel"
    wake_ledger fold-failed "$best" "$oldkind" "$oldreason" "$by"
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
    # An urgent booking is not part of the convoy. Spacing exists so wakes
    # that all want the same distant minute do not land on one second; a wake
    # that wants to fire NOW (a move waiting on a board, someone sitting
    # there) must not be shoved minutes into the future by a queue it was
    # never in. It takes the lock or waits for it — that is spacing enough.
    if [ "$base" -le "$WAKE_URGENT_DELAY" ]; then echo "$base"; return; fi
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

# --- The run lock's lanes ---------------------------------------------------
# Only one wake session runs at a time (the run lock, taken in `crab wake` and
# held for the life of the process), and the queue's fairness problem lives at
# that door: an event wake has something waiting on the other end of it — a
# move on a board, a file that landed — while a scheduled wake's hour is its
# own. specs/wake-queue.md rules 21a and 21b. Everything here is ephemeral
# state under $STATE_PREFIX, like the lock whose contention it measures: a
# reboot clears the lock and clears these with it.
#
# The urgent lane (rule 21b). While an event wake is waiting for the run lock,
# or has been deferred by it and is due straight back, this claim stands: one
# file holding the epoch until which it is spoken for. A non-event wake that
# finds an unexpired claim yields — defers itself without contending — so the
# event wake takes the lock the moment the holder lets go, instead of racing
# the whole queue for the next turn. The claim is advisory: it decides only
# who takes the lock NEXT, and nothing may pause or kill the wake holding it.
WAKE_URGENT_CLAIM="${STATE_PREFIX}-wake-urgent"

wake_urgent_mark() {  # <seconds the claim should stand>
    local till=$(( $(date +%s) + ${1:-$WAKE_EVENT_LOCK_WAIT} )) have
    # Keep the furthest expiry: two event waiters share the one claim, and the
    # lane stands until the LAST of them has had its chance at the lock.
    have="$(cat "$WAKE_URGENT_CLAIM" 2>/dev/null)"
    case "$have" in ''|*[!0-9]*) have=0 ;; esac
    [ "$have" -gt "$till" ] && till="$have"
    printf '%s\n' "$till" > "$WAKE_URGENT_CLAIM.tmp.$$" \
        && mv -f "$WAKE_URGENT_CLAIM.tmp.$$" "$WAKE_URGENT_CLAIM"
    return 0
}

wake_urgent_clear() { rm -f "$WAKE_URGENT_CLAIM"; }

wake_urgent_waiting() {  # 0 = an event wake holds an unexpired claim
    local till
    [ -f "$WAKE_URGENT_CLAIM" ] || return 1
    till="$(cat "$WAKE_URGENT_CLAIM" 2>/dev/null)"
    # An expired or unreadable claim is removed on sight, never obeyed — an
    # orphan (a waiter the unit ceiling reaped mid-wait) must not park the
    # scheduled queue behind a wake that is never coming back.
    case "$till" in ''|*[!0-9]*) rm -f "$WAKE_URGENT_CLAIM"; return 1 ;; esac
    [ "$till" -gt "$(date +%s)" ] && return 0
    rm -f "$WAKE_URGENT_CLAIM"
    return 1
}

# The escalating backoff (rule 21a): base, doubled per consecutive deferral of
# the same kind-and-reason, capped. Keyed by the reason as the record holds it
# — the one identity that survives the deferral round-trip. cksum rather than
# a stronger hash on purpose: a collision costs one wake a slightly longer
# backoff, and nothing here is input anybody hostile controls.
_wake_defer_count_file() {  # <kind> <reason>
    printf '%s-wake-defer-%s' "$STATE_PREFIX" \
        "$(printf '%s\n%s' "${1:-}" "$(_wake_reason_norm "${2:-}")" | cksum | tr ' \t' '--')"
}

wake_event_defer_next() {  # <kind> <reason>  -> prints the delay, counts the miss
    local f n delay base="${WAKE_EVENT_DEFER_DELAY:-30}" max="${WAKE_EVENT_DEFER_MAX:-120}"
    f="$(_wake_defer_count_file "$1" "$2")"
    n="$(cat "$f" 2>/dev/null)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -gt 6 ] && n=6  # the shift below must not outrun bash arithmetic
    delay=$(( base << n ))
    [ "$delay" -gt "$max" ] && delay="$max"
    printf '%s\n' $(( n + 1 )) > "$f"
    # Counts whose wake never came back — a game that ended, a reason that
    # coalesced away — rot here otherwise. Only ever run on the contended path.
    find "$(dirname "$STATE_PREFIX")" -maxdepth 1 \
        -name "$(basename "$STATE_PREFIX")-wake-defer-*" -mmin +60 -delete 2>/dev/null
    printf '%s\n' "$delay"
}

wake_defer_clear() {  # <kind> <reason>
    rm -f "$(_wake_defer_count_file "$1" "$2")"
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
_wake_book() {  # <unit> <delay, e.g. 900s> <kind> <reason> [booked-by] [effort] [model]
    local unit="$1" when="$2" kind="$3" reason="$4" by="${5:-unknown}" effort="${6:-}" model="${7:-}"
    if ! _wake_manager_is_live; then
        echo "  (scratch instance — record kept for $unit, no timer armed)" >&2
        return 0
    fi
    case "$when" in
        *[!0-9]s) : ;;
        *) when="$(printf '%s' "$when" | tr -cd '0-9')s" ;;
    esac
    local -a extra=(--collect -p "TimeoutStartSec=$WAKE_RUNTIME_MAX")
    # Background CPU priority, wake-queue.md rule 12a: nobody is waiting on a
    # wake, so it yields the processor to a turn somebody IS waiting on.
    [ -n "${BACKGROUND_CPU_WEIGHT:-}" ] && extra+=(-p "CPUWeight=$BACKGROUND_CPU_WEIGHT")
    [ -n "${BACKGROUND_NICE:-}" ] && extra+=(-p "Nice=$BACKGROUND_NICE")
    [ -n "${DESKCRAB_CONF:-}" ] && extra+=(--setenv=DESKCRAB_CONF="$DESKCRAB_CONF")
    [ -n "${DESKCRAB_STATE_PREFIX:-}" ] && extra+=(--setenv=DESKCRAB_STATE_PREFIX="$DESKCRAB_STATE_PREFIX")
    # The overrides ride as the sixth and seventh arguments only when there is
    # one, so a wake booked without them fires with the argv it always had. A
    # model with no effort still fills the sixth slot — empty, which the fire
    # side ignores — because the seventh argument IS the model (rule 13b) and
    # position may not shift.
    local -a fired=("$SCRIPT_DIR/crab" wake "$kind" "$reason" "$unit" "$by")
    if [ -n "$model" ]; then
        fired+=("$effort" "$model")
    elif [ -n "$effort" ]; then
        fired+=("$effort")
    fi
    systemd-run --user --quiet --unit="$unit" "${extra[@]}" --on-active="$when" \
        "${fired[@]}"
}

# Book a wake. THE door: coalescing, spacing, the record, the timer, the
# rollback and the ledger line all live behind it.
#
#   wake_book [--by <origin>] [--cap <n>] [--cap-prefix <reason-prefix>]
#             [--effort <level>] <when> [kind] [reason]
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
# --cap-prefix scopes that cap to reasons opening with the prefix, so one
# booker can hold separately-capped classes of follow-up (rule 44): the
# auditor's want-flags must not count against — or drain — its caught
# promises, nor the reverse.
# --effort pins the fired session's reasoning effort (rule 13a). Refused here,
# at booking time, when it is not a level the CLI knows — a bad value carried
# to the claude invocation would fail hours later with nobody watching.
# --cluster declares the turn-cluster fold (rule 10b) with its window in
# seconds; --cluster-item names the one caught item this booking carries, and
# --cluster-pin-fire pins the fold to the fire moment for a class whose fire
# time is a promise. A cluster needs its class named with --cap-prefix — an
# unclassed fold would fold across every reason its booker ever wrote — and
# that is refused here, at booking time, like a bad effort level.
# Is this reason a workload rather than a moment — specs/wake-queue.md rule
# 10c's pattern classes, deterministic and NARROW on purpose: over-refusal
# seals her hands, so only the shapes with no benign timed reading match. A
# leading build verb (at the reason's start, or opening a clause after its
# intro), the record-sweep shapes, and the builder's-own-hands phrase. The
# named counter-shapes — a restart guarded by nothing-in-flight, a timer's
# first run to look in on, a sealed envelope to score, a thing to say at six —
# are held non-matching by tests/test_wake_work_gate.sh.
wake_work_shaped() {  # <reason> -> 0 when work-shaped
    printf '%s' "${1:-}" | grep -qiE \
        '(^|[-:—] )(build|implement|refactor|port|rewrite|fix|patch|write) |pull every|read every|scan every|run the [a-z ]{0,12}suite|run tests?\b|read its log|under my own hand'
}

wake_book() {
    local by="" cap="" capprefix="" effort="" model="" cluster="" clusteritem="" clusterpin=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --by)  by="${2:-}"; shift 2 || return 1 ;;
            --cap) cap="${2:-}"; shift 2 || return 1 ;;
            --cap-prefix) capprefix="${2:-}"; shift 2 || return 1 ;;
            --effort) effort="${2:-}"; shift 2 || return 1 ;;
            --model) model="${2:-}"; shift 2 || return 1 ;;
            --cluster) cluster="${2:-}"; shift 2 || return 1 ;;
            --cluster-item) clusteritem="${2:-}"; shift 2 || return 1 ;;
            --cluster-pin-fire) clusterpin=1; shift ;;
            *) break ;;
        esac
    done
    case "$effort" in
        ''|low|medium|high) ;;
        *) echo "wake_book: '--effort $effort' is not a level the CLI knows (low, medium, high) — nothing scheduled." >&2
           return 1 ;;
    esac
    # The model pin (rule 13b) is an open vocabulary — the engine follows the
    # name — so the check is structural: one tab-free token, because a stray
    # byte here corrupts the tab-separated record and the fired argv, hours
    # later, with nobody watching.
    case "$model" in
        '') ;;
        *[!A-Za-z0-9._:-]*)
           echo "wake_book: '--model $model' is not a name the record can carry (one token of A-Za-z0-9._:-) — nothing scheduled." >&2
           return 1 ;;
    esac
    if [ -n "$cluster" ]; then
        case "$cluster" in
            *[!0-9]*) echo "wake_book: '--cluster $cluster' is not a window in seconds — nothing scheduled." >&2
                      return 1 ;;
        esac
        if [ -z "$capprefix" ]; then
            echo "wake_book: a --cluster fold needs its class named with --cap-prefix — nothing scheduled." >&2
            return 1
        fi
    fi
    [ -n "$by" ] || by="${DESKCRAB_WAKE_ORIGIN:-herself}"
    # One booker at a time, for the WHOLE check-then-act. Two wakes finishing
    # in the same second each found no pending floor and each booked one.
    _wake_under_lock "wake_book" _wake_book_locked "$by" "$cap" "$capprefix" "$effort" \
        "$model" "$cluster" "$clusteritem" "$clusterpin" "$@"
}

_wake_book_locked() {  # <by> <cap> <cap-prefix> <effort> <model> <cluster> <cluster-item> <cluster-pin> <when> [kind] [reason]
    local by="$1" cap="$2" capprefix="$3" effort="$4" model="$5"
    local cluster="$6" clusteritem="$7" clusterpin="$8"
    local when="${9:-}" kind="${10:-scheduled}" reason="${11:-}"
    [ -n "$when" ] || { echo "wake_book: no moment given."; return 1; }
    mkdir -p "$WAKES_DIR"
    _wake_norm "$kind" "$reason"; kind="$WK_N_KIND"; reason="$WK_N_REASON"

    # The work gate (specs/wake-queue.md rule 10c): the queue carries moments,
    # not workloads. A self-booked scheduled wake whose reason is work-shaped
    # is refused with both roads named — the record spine the night's builders
    # drain, and the builder that goes now — never silently converted. Only
    # her own hand is gated: every sanctioned identity of rule 41, every event
    # wake, and the held/outage/deferred-promise flows arrive under their own
    # identities and pass untouched.
    if [ "${WAKE_WORK_GATE:-1}" = "1" ] && [ "$by" = "herself" ] \
            && [ "$kind" = "scheduled" ] && wake_work_shaped "$reason"; then
        wake_ledger refused-work "" "$kind" "$reason" "$by"
        echo "Not booked — that reason is a workload, and the wake queue carries moments (specs/wake-queue.md rule 10c)."
        echo "Work has its own roads: open a record with  crab eng add '<title>'  and the night's builders will take it while you sleep, or send it now with  crab job '<self-contained brief>'."
        return 1
    fi

    local fire now
    fire="$(wake_when_to_epoch "$when")"
    if [ -z "$fire" ]; then
        echo "Cannot make sense of '$when' — nothing scheduled."
        return 1
    fi

    # The turn-cluster fold, ABOVE everything else that could make a second
    # wake out of the same cluster's nag: a folded booking never reaches the
    # cap, the identical-reason coalesce or the slot search.
    if [ -n "$cluster" ] && [ "$cluster" -gt 0 ] \
        && _wake_cluster_fold "$by" "$kind" "$capprefix" "$cluster" "$clusteritem" "$fire" "$clusterpin"; then
        return 0
    fi

    [ -n "$cap" ] && ! _wake_cap_admits "$by" "$cap" "$capprefix" && return 0

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
    wake_state_write "$unit" "$fire" "$kind" "$reason" "$now" "$by" "$effort" "$model"
    if _wake_book "$unit" "${slot}s" "$kind" "$reason" "$by" "$effort" "$model"; then
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
# Returns 0 when there is room for one more. A prefix, when given, scopes the
# whole count — and the drain — to reasons opening with it, so one booker's
# separately-capped classes of follow-up never count against each other.
_wake_cap_admits() {  # <booked-by> <cap> [reason-prefix]
    local by="$1" cap="$2" prefix="${3:-}" now f u n=0 _line
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
                 if [ -n "$prefix" ]; then
                     case "$WK_REASON" in "$prefix"*) ;; *) continue ;; esac
                 fi
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
            _wake_unit_is_fixture "$base" && continue
            case "$base" in deskcrab-wake-[0-9]*) ;; *) continue ;; esac
            [ -s "$WAKES_DIR/$base.wake" ] && continue
            # A unit whose SERVICE is active is a wake firing right now — it
            # retired its own record first thing (rule 19), and its timer husk
            # lingers only until --collect reaps the pair. Skipped here exactly
            # as tidy and restore skip it (rule 3a): reported as an orphan, an
            # evening of event wakes queueing at the run lock read as three to
            # six timers nobody had booked (2026-08-10). The running session is
            # the session registry's row, not this table's.
            case "${_WAKE_UNIT_STATE[$base.service]:-}" in
                active|activating) continue ;;
            esac
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

# Under the booking lock, like every writer of the queue. Without it a
# `wake-cancel --all` walking the records could be overtaken by a finishing
# wake's restore: the restore sees a record the cancel has not reached yet,
# finds no live timer, and arms a fresh one — and the cancel then deletes the
# record underneath it. What is left is an armed timer with no booking record,
# which tidy refuses to purge (it has never fired) and which goes off with the
# wake the user explicitly called off.
wake_cancel() {  # <unit> | --all
    _wake_under_lock "wake_cancel" _wake_cancel_locked "$@"
}

_wake_cancel_locked() {
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
#
# Under the booking lock, like every other writer. Two restores running at once
# each wrote a different fire time onto the same overdue record and then each
# called systemd-run for the same unit name; and a restore running beside a
# cancellation re-armed the record the cancellation was about to delete. The
# lock is taken by the public name; _wake_restore_locked is what runs inside
# it, and the internal name is what the cap drain and tidy already use for the
# same reason.
wake_restore() {
    _wake_under_lock "wake_restore" _wake_restore_locked
}

_wake_restore_locked() {
    local now f unit overdue=0 delay key restored=0 failed=0
    now=$(date +%s)
    local -a seen=()
    while IFS=$'\t' read -r _ f; do
        [ -n "$f" ] && [ -e "$f" ] || continue
        unit="${f##*/}"; unit="${unit%.wake}"
        # A live timer needs nothing from us; a dead one may linger as failed
        # and would block systemd-run reusing its name.
        if _wake_manager_is_live; then
            # A wake FIRING RIGHT NOW is not an unarmed booking, and its timer
            # is the wrong thing to ask: a one-shot timer goes inactive the
            # instant it fires, so between the timer going quiet and the wake
            # reaching its own record-retiring line, this loop would see an
            # overdue record with no timer and re-arm the wake underneath
            # itself. tidy has skipped an active service since it was written
            # (rule 36); restore skipped only the timer.
            systemctl --user is-active --quiet "$unit.service" && continue
            systemctl --user is-active --quiet "$unit.timer" && continue
            systemctl --user reset-failed "$unit.timer" "$unit.service" 2>/dev/null
        fi
        wake_record_read "$f" || continue
        if [ "$WK_FIRE" -gt "$now" ]; then
            if _wake_book "$unit" "$(( WK_FIRE - now ))s" "$WK_KIND" "$WK_REASON" "$WK_BOOKED_BY" "$WK_EFFORT" "$WK_MODEL"; then
                wake_ledger restored "$unit" "$WK_KIND" "$WK_REASON" "$WK_BOOKED_BY"
                restored=$(( restored + 1 ))
                echo "restored: $unit fires $(date -d "@$WK_FIRE" '+%F %H:%M') (${WK_KIND:-scheduled}${WK_REASON:+ — $WK_REASON}, booked by $WK_BOOKED_BY)"
            else
                failed=$(( failed + 1 ))
                wake_ledger restore-failed "$unit" "$WK_KIND" "$WK_REASON" "$WK_BOOKED_BY"
                echo "could not re-arm: $unit (still recorded, still without a timer)"
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
        # Record first, timer second — rule 4 — and the record goes BACK if the
        # timer will not arm. Without the rollback a failed re-arm left the
        # booking claiming a moment that will never come: still overdue, but now
        # dated ninety seconds from a restore that did not happen, so the next
        # pass computes its stagger from a fiction.
        local WAS_FIRE="$WK_FIRE" WAS_KIND="$WK_KIND" WAS_REASON="$WK_REASON"
        local WAS_AT="$WK_BOOKED_AT" WAS_BY="$WK_BOOKED_BY" WAS_EFFORT="$WK_EFFORT"
        local WAS_MODEL="$WK_MODEL"
        wake_state_write "$unit" "$(( now + delay ))" "$WAS_KIND" "$WAS_REASON" \
            "$WAS_AT" "$WAS_BY" "$WAS_EFFORT" "$WAS_MODEL"
        if _wake_book "$unit" "${delay}s" "$WAS_KIND" "$WAS_REASON" "$WAS_BY" "$WAS_EFFORT" "$WAS_MODEL"; then
            wake_ledger overdue "$unit" "$WAS_KIND" "$WAS_REASON" "$WAS_BY"
            restored=$(( restored + 1 ))
            echo "overdue: $unit (was due $(date -d "@$WAS_FIRE" '+%F %H:%M')) fires in ${delay}s"
        else
            wake_state_write "$unit" "$WAS_FIRE" "$WAS_KIND" "$WAS_REASON" "$WAS_AT" "$WAS_BY" "$WAS_EFFORT" "$WAS_MODEL"
            wake_ledger restore-failed "$unit" "$WAS_KIND" "$WAS_REASON" "$WAS_BY"
            failed=$(( failed + 1 ))
            echo "could not re-arm: $unit (still recorded, still overdue)"
        fi
    done < <(for f in "$WAKES_DIR"/*.wake; do
                 [ -e "$f" ] || continue
                 wake_record_read "$f" || continue
                 printf '%s\t%s\n' "$WK_FIRE" "$f"
             done | sort -n)
    # "Nothing needed restoring" is a claim about the queue, and it may only be
    # made when nothing FAILED to restore. A pass that could not arm a single
    # timer used to end on the sentence that says every booking has one.
    if [ "$failed" -gt 0 ]; then
        echo "wake queue: $failed booking$([ "$failed" = 1 ] || echo s) could not be re-armed — still recorded, still without a timer"
    elif [ "$restored" -eq 0 ]; then
        echo "wake queue needs no restoring (every booking already has its timer)"
    fi
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
    _wake_under_lock "wake_tidy" _wake_tidy_locked
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

    local f unit fire kind reason now keptf keptk keptr newfire newunit at by effort model
    local -a kf=() kk=() kr=()
    now=$(date +%s)
    while IFS=$'\t' read -r fire f; do
        [ -n "$f" ] && [ -e "$f" ] || continue
        unit="${f##*/}"; unit="${unit%.wake}"
        systemctl --user is-active --quiet "$unit.service" && continue
        wake_record_read "$f" || continue
        fire="$WK_FIRE"; kind="$WK_KIND"; reason="$WK_REASON"
        at="$WK_BOOKED_AT"; by="$WK_BOOKED_BY"; effort="$WK_EFFORT"
        model="$WK_MODEL"
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
            wake_state_write "$newunit" "$newfire" "$kind" "$reason" "$at" "$by" "$effort" "$model"
            if _wake_book "$newunit" "$(( newfire - now ))s" "$kind" "$reason" "$by" "$effort" "$model"; then
                spread=$(( spread + 1 ))
                wake_ledger spread "$newunit" "$kind" "$reason" "tidy (was $unit)"
                echo "spread: $unit -> $(date -d "@$newfire" '+%H:%M:%S') (was sharing a moment with another wake)"
                fire="$newfire"
            else
                wake_state_clear "$newunit"
                wake_state_write "$unit" "$fire" "$kind" "$reason" "$at" "$by" "$effort" "$model"
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
    # The floor's delay carries a fresh jitter while the own-time discipline
    # stands (specs/wake-queue.md rule 40e), so recurring opportunities land
    # irregularly instead of hardening into a clock ritual. Stood down, the
    # flat historic delay comes back exactly.
    local delay="$ENSURE_WAKE_DELAY"
    if [ "${IDLE_RETURN:-1}" = "1" ]; then
        delay="$(( ${IDLE_RETURN_BASE:-2700} + $(idle_return_jitter) ))s"
    fi
    wake_book --by wake-chain-floor "$delay" scheduled "" >/dev/null 2>&1 || true
}
