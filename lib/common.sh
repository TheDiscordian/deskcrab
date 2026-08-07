#!/bin/bash
# Shared config and functions for DeskCrab

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "$LIB_DIR")}"
CONF_FILE="${DESKCRAB_CONF:-$HOME/.config/deskcrab/deskcrab.conf}"

if [ ! -f "$CONF_FILE" ]; then
    echo "Config not found: $CONF_FILE"
    echo "Copy deskcrab.conf.example to $CONF_FILE and edit it."
    exit 1
fi

source "$CONF_FILE"

# Defaults
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-low}"
PROJECT_DIR="${PROJECT_DIR:-$HOME}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$HOME/.local/share/deskcrab/archive}"
CONVO_TIMEOUT="${CONVO_TIMEOUT:-300}"
# NOTIFY_NAME inherits an explicitly set ASSISTANT_NAME so one variable renames
# the whole assistant; ASSISTANT_NAME's own default is applied afterwards so
# configs that set neither keep "DeskCrab" notification titles.
NOTIFY_NAME="${NOTIFY_NAME:-${ASSISTANT_NAME:-DeskCrab}}"
ASSISTANT_NAME="${ASSISTANT_NAME:-Crab}"
# Sliding-window history: once the live convo exceeds CONVO_MAX_TURNS user/assistant
# pairs, the oldest CONVO_SUMMARIZE_TURNS pairs are folded into a running summary.
CONVO_MAX_TURNS="${CONVO_MAX_TURNS:-20}"
CONVO_SUMMARIZE_TURNS="${CONVO_SUMMARIZE_TURNS:-10}"
# Model used for the cheap summarization pass (keep it small/fast).
CONVO_SUMMARY_MODEL="${CONVO_SUMMARY_MODEL:-haiku}"
# Durable "wants" file the assistant maintains and pursues during autonomous
# wakes (crab wake / crab wake-at). Unset = feature off.
WANTS_FILE="${WANTS_FILE:-}"
# Local-time hours (HH-HH, wraps midnight) during which autonomous wakes stay
# fully silent — no speech, no windows. Unset = no quiet hours.
WAKE_QUIET_HOURS="${WAKE_QUIET_HOURS:-}"
# Effort for autonomous wakes. Nobody is waiting on a wake, so it can afford
# more thinking than the interactive default.
WAKE_EFFORT="${WAKE_EFFORT:-$CLAUDE_EFFORT}"
# Reap an autonomous wake only when it goes completely silent: an active session
# writes stream events constantly, so this many seconds without any output means
# it is hung, not thinking. Wall-clock limits would kill productive sessions.
WAKE_STALL_TIMEOUT="${WAKE_STALL_TIMEOUT:-300}"
# A wake that speaks moments after an interactive turn is an echo: the turn
# almost certainly already covered what the wake is about to announce, and two
# near-identical voices in a row reads as malfunction. If the last interactive
# turn (desk or phone) began within this many seconds of the wake's speak
# decision, the wake completes silently — the work still happened and its
# outcome still lands in the journal. 0 disables.
WAKE_MUTE_AFTER_TURN="${WAKE_MUTE_AFTER_TURN:-300}"
# Self-booked wakes stack: several sessions each promise "come back in 45min"
# and the timers land minutes apart, each re-reading the wants and
# re-announcing the same progress. A scheduled booking whose fire time is
# within this many seconds of a pending one with the same reason is not
# booked — the existing promise already covers it. 0 disables.
WAKE_COALESCE_WINDOW="${WAKE_COALESCE_WINDOW:-900}"

# Remote (phone) client: crab serve. Unset SERVE_SECRET disables serving.
SERVE_PORT="${SERVE_PORT:-8723}"
SERVE_BIND="${SERVE_BIND:-127.0.0.1}"
SERVE_SECRET="${SERVE_SECRET:-}"
SERVE_TIMEOUT="${SERVE_TIMEOUT:-600}"
# TLS for the phone client. Browsers refuse microphone access over plain http
# from anything but localhost, so a phone needs https one way or another:
#   off  - plain http (fine behind `tailscale serve`, which terminates TLS)
#   self - self-signed cert, generated on demand; one "accept the risk" tap
# SERVE_CERT/SERVE_KEY override both with a pair you supply (e.g. the output
# of `tailscale cert`, which is a real, warning-free certificate).
SERVE_TLS="${SERVE_TLS:-off}"
SERVE_CERT="${SERVE_CERT:-}"
SERVE_KEY="${SERVE_KEY:-}"
TLS_DIR="${TLS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/tls}"

# Runtime state. Overridable from the environment so a test run can be pointed
# at a scratch conversation instead of stomping the live one.
STATE_PREFIX="${DESKCRAB_STATE_PREFIX:-/tmp/deskcrab}"
CONVOFILE="${STATE_PREFIX}-convo.txt"
CONVOLOCK="${STATE_PREFIX}-convo.lock"
SUMMARYFILE="${STATE_PREFIX}-convo-summary.txt"
TTSPIDFILE="${STATE_PREFIX}-tts.pid"
DEBUGLOG="${STATE_PREFIX}-debug.log"
SESSIONS_DIR="${STATE_PREFIX}-sessions"
# Speech mutex: every path that puts audio on the speakers — the interactive
# TTS streamer and a wake's speak_once — holds this flock for the whole speak
# stage. Two voices at once is never acceptable: the later speaker queues
# behind the lock, and a wake checks it first and stays silent instead.
SPEECHLOCK="${STATE_PREFIX}-speech.lock"
# Detached jobs. Deliberately NOT under STATE_PREFIX (/tmp): a job outlives the
# turn that started it, and may outlive a reboot's tmp cleanup too. Jobs run
# unattended builds nobody is waiting on, so they default to the strongest
# model at high effort rather than the fast interactive settings.
JOBS_DIR="${JOBS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/jobs}"
JOB_MODEL="${JOB_MODEL:-fable}"
JOB_EFFORT="${JOB_EFFORT:-high}"
# How many finished jobs the report lists, and how long finished job records
# (status + log) are kept before pruning.
JOBS_SHOW_FINISHED="${JOBS_SHOW_FINISHED:-6}"
JOBS_KEEP_DAYS="${JOBS_KEEP_DAYS:-14}"
# Durable wake bookings. A transient timer lives only inside the running user
# manager — a reboot or logout erases it with no trace — so every wake-at also
# writes one record here (fire-epoch \t kind \t reason) and `crab wake-restore`
# rebuilds timers from the records at login. Deliberately NOT under
# STATE_PREFIX: a promise for tomorrow morning must survive /tmp being cleared.
WAKES_DIR="${WAKES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/wakes}"
SESSIONS_LOCK="${STATE_PREFIX}-sessions.lock"
SESSIONS_LOG="${STATE_PREFIX}-sessions.log"
# How far back the journal of finished sessions is read, and how many entries
# of it reach the prompt.
SESSIONS_LOG_HOURS="${SESSIONS_LOG_HOURS:-12}"
SESSIONS_LOG_SHOW="${SESSIONS_LOG_SHOW:-8}"
SESSIONS_LOG_KEEP="${SESSIONS_LOG_KEEP:-400}"
# The durable day record beneath the sessions log. The log above is the live
# view — trimmed lines, capped, erased with /tmp at every reboot. This is the
# archive: one JSON object per finished turn (desktop, phone, wake, job) in
# journal/YYYY-MM-DD.jsonl, user text and reply IN FULL, never trimmed, never
# rotated, written at the same moments the log is. Deliberately NOT under
# STATE_PREFIX: its whole purpose is to be re-readable after a reboot.
DAY_JOURNAL_DIR="${DAY_JOURNAL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/journal}"

# The conversation archive must exist before the first stale conversation
# tries to land in it. rotate_convo mkdirs too, but a missing directory should
# never be the reason anyone doubts the archive path has run.
mkdir -p "$ARCHIVE_DIR" 2>/dev/null

# Kernel boot-relative start time of a pid, in clock ticks (field 22 of
# /proc/PID/stat). Recorded alongside the pid so a recycled pid cannot make a
# long-dead session look live: same number, different start time, still dead.
_proc_starttime() {
    awk '{ n = split($0, f, ") "); split(f[n], g, " "); print g[20] }' \
        "/proc/$1/stat" 2>/dev/null || echo 0
}

# --- Self-awareness: who else is running right now -------------------------
# Every claude invocation registers itself here so that any one of them can see
# the others. Without this an interactive turn has no idea a wake is working in
# parallel, and reports "nothing is happening" while something is.
session_register() {
    SESSION_KIND="$1"
    SESSION_START=$(date +%s)
    SESSION_OUTCOME=""
    # Filled in by the turn as its text becomes known, read back by the day
    # journal at finish. Full text on purpose — the sessions log keeps the
    # trimmed line; the journal keeps the words.
    SESSION_USER_TEXT=""
    SESSION_REPLY=""
    mkdir -p "$SESSIONS_DIR"
    SESSION_FILE="$SESSIONS_DIR/$$"
    printf '%s\t%s\t%s\t%s\t%s\n' "$SESSION_KIND" "$$" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$SESSION_START" "$(_proc_starttime $$)" \
        > "$SESSION_FILE"
    trap session_finish EXIT INT TERM
}

# What this session actually accomplished, in one line. Recorded so the NEXT
# session can see it: a live registry only ever answers "who is running", and
# the failure it does not catch is concluding "I did no work" when an earlier
# session already finished the work and exited.
session_outcome() {
    SESSION_OUTCOME="$(printf '%s' "$1" | tr '\n\t' '  ' | head -c 300)"
}

# --- Work claims -----------------------------------------------------------
# The registry reports; it does not claim. Knowing another session is alive is
# not the same as knowing it has lib/common.sh open — twice in twenty minutes
# two sessions edited and committed the same file, and one set of changes went
# in under the other's commit message because `git add -A` in one hand sweeps up
# whatever the other has staged. A claim is deliberately advisory: a lock held
# by a session that dies mid-edit would wedge every later one, and a hand that
# cannot start is worse than two hands that can see each other.
#
# The claim lives beside the live registration as <pid>.claim. A claude session
# calls `crab claim` from a tool call, so the claiming process is a descendant
# of the registered shell rather than the shell itself: walk up the ppid chain
# to find whichever ancestor is registered.
_claim_owner_pid() {
    local p="${1:-$$}" guard=0
    while [ "$p" -gt 1 ] && [ "$guard" -lt 40 ]; do
        [ -e "$SESSIONS_DIR/$p" ] && { echo "$p"; return 0; }
        p="$(awk '{ n = split($0, f, ") "); split(f[n], g, " "); print g[2] }' \
             "/proc/$p/stat" 2>/dev/null)" || return 1
        [ -n "$p" ] || return 1
        guard=$((guard+1))
    done
    return 1
}

# Words too generic to mean two sessions are in each other's way.
_CLAIM_STOPWORDS=" the a an and or of in on to for with my her at is are be it its this that work working "

# Shared significant tokens between two claims, if any.
_claim_overlap() {
    local t out=""
    for t in $(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9./_-' ' '); do
        [ "${#t}" -ge 3 ] || continue
        case "$_CLAIM_STOPWORDS" in *" $t "*) continue ;; esac
        case " $(printf '%s' "$2" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9./_-' ' ') " in
            *" $t "*) out="$out $t" ;;
        esac
    done
    printf '%s' "${out# }"
}

# Announce what this session is holding. Prints any other live session's claim,
# and shouts when the two touch the same thing.
session_claim() {
    local what="$1" owner
    owner="$(_claim_owner_pid $PPID)" || owner="$(_claim_owner_pid $$)" || {
        echo "No registered session in this process's ancestry — nothing to claim against."
        return 1
    }
    mkdir -p "$SESSIONS_DIR"
    session_reap
    local f pid other clash=0
    for f in "$SESSIONS_DIR"/*.claim; do
        [ -e "$f" ] || continue
        pid="$(basename "$f" .claim)"
        [ "$pid" = "$owner" ] && continue
        [ -e "$SESSIONS_DIR/$pid" ] || { rm -f "$f"; continue; }
        other="$(cat "$f")"
        local shared; shared="$(_claim_overlap "$what" "$other")"
        if [ -n "$shared" ]; then
            echo "CONFLICT — pid $pid is already holding: $other"
            echo "           (both touch:$( printf ' %s' $shared ))"
            clash=1
        else
            echo "also live — pid $pid holds: $other"
        fi
    done
    printf '%s\n' "$what" > "$SESSIONS_DIR/$owner.claim"
    [ "$clash" -eq 1 ] \
        && echo "Claim recorded anyway (advisory, never a lock). Coordinate or pick different files." \
        || echo "Claimed: $what"
    return 0
}

session_unclaim() {
    local owner
    owner="$(_claim_owner_pid $PPID)" || owner="$(_claim_owner_pid $$)" || return 0
    rm -f "$SESSIONS_DIR/$owner.claim"
    echo "Claim released."
}

# --- Checkpoints: a resumable trace of a turn in progress -------------------
# The journal only speaks at the END of a session, so a turn cut off mid-work
# (network drop, SIGKILL) leaves edits on disk and no explanation — the next
# hand sees orphan changes and cannot tell what was intended or what remained.
# A checkpoint is recorded DURING the turn: intent, files touched, what is
# done, what is next. It lives beside the registration as <pid>.ckpt and is
# append-only — each line is a single O_APPEND write, so a kill mid-checkpoint
# leaves every earlier line intact. A clean finish deletes it (the outcome
# line covers a finished session); a reaped session's checkpoints are moved to
# $CKPT_INTERRUPTED_DIR, where `crab status` surfaces them until someone picks
# the work up and clears them with `crab resolve`.
CKPT_INTERRUPTED_DIR="${STATE_PREFIX}-interrupted"
CKPT_KEEP_DAYS="${CKPT_KEEP_DAYS:-7}"

session_checkpoint() {
    local what owner
    what="$(printf '%s' "$1" | tr '\n\t' '  ' | head -c 500)"
    [ -n "$what" ] || { echo "Usage: crab checkpoint <intent / progress / what is next>"; return 1; }
    owner="$(_claim_owner_pid $PPID)" || owner="$(_claim_owner_pid $$)" || {
        echo "No registered session in this process's ancestry — nothing to checkpoint against."
        return 1
    }
    printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$what" >> "$SESSIONS_DIR/$owner.ckpt"
    echo "Checkpointed."
}

# List interrupted sessions' surviving checkpoints, most recent trace last.
interrupted_report() {
    local f n=0
    [ -d "$CKPT_INTERRUPTED_DIR" ] || { echo "  (none)"; return 0; }
    for f in "$CKPT_INTERRUPTED_DIR"/*.ckpt; do
        [ -s "$f" ] || continue
        printf '  - %s (clear with: crab resolve %s)\n' "$(basename "$f" .ckpt)" "$(basename "$f" .ckpt)"
        tail -n 3 "$f" | awk -F'\t' '{ printf "      %s  %s\n", $1, $2 }'
        n=$((n+1))
    done
    [ "$n" -eq 0 ] && echo "  (none)"
    return 0
}

# The work an interrupted trace pointed at has been picked up (or judged dead):
# drop it so status stops raising it.
interrupted_resolve() {
    local name="$1"
    [ -n "$name" ] || { echo "Usage: crab resolve <name from crab status>"; return 1; }
    case "$name" in */*|*..*) echo "Bad name."; return 1 ;; esac
    if [ -e "$CKPT_INTERRUPTED_DIR/$name.ckpt" ]; then
        rm -f "$CKPT_INTERRUPTED_DIR/$name.ckpt"
        echo "Resolved: $name"
    else
        echo "No interrupted trace named '$name'."
        return 1
    fi
}

# --- Day journal: the record beneath the sessions log ----------------------
# Appended at every point that appends to SESSIONS_LOG, plus job completion.
# One JSON line per turn via lib/day-journal, which does the encoding — a
# reply holds quotes, newlines, tabs and emoji, and a hand-concatenated line
# would be a lost day. The three texts travel NUL-separated on stdin, not as
# arguments: a job's full log can exceed the kernel's per-argument limit.
day_journal_append() {  # <kind> <start-epoch> <duration|-> <pid> <user> <reply> [outcome]
    command -v python3 >/dev/null 2>&1 || return 0
    printf '%s\0%s\0%s' "$5" "$6" "${7:-}" \
        | "$LIB_DIR/day-journal" append "$DAY_JOURNAL_DIR" "$1" "$2" "$3" "$4" 2>/dev/null
    return 0
}

# The sessions log speaks in kind phrases ("desktop turn"); the journal keys
# on one word so a reader can filter a day by kind.
_day_journal_kind() {
    case "$1" in
        "desktop turn")    echo desktop ;;
        "phone turn")      echo phone ;;
        "autonomous wake") echo wake ;;
        *)                 echo "${1:-session}" ;;
    esac
}

# Close the registration: drop the live file, append to the journal.
session_finish() {
    [ -n "${SESSION_FILE:-}" ] || return 0
    rm -f "$SESSION_FILE" "$SESSION_FILE.claim" "$SESSION_FILE.ckpt"
    local NOW; NOW=$(date +%s)
    {
        flock -w 10 9
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$(date -d "@${SESSION_START:-$NOW}" '+%Y-%m-%d %H:%M:%S')" \
            "$(date '+%H:%M:%S')" \
            "$(( NOW - ${SESSION_START:-$NOW} ))" \
            "${SESSION_KIND:-session}" \
            "${SESSION_OUTCOME:-(no summary recorded)}" >> "$SESSIONS_LOG"
        # Keep the journal bounded; it is a memory aid, not an archive.
        if [ "$(wc -l < "$SESSIONS_LOG" 2>/dev/null || echo 0)" -gt "$SESSIONS_LOG_KEEP" ]; then
            tail -n "$SESSIONS_LOG_KEEP" "$SESSIONS_LOG" > "$SESSIONS_LOG.tmp" \
                && mv "$SESSIONS_LOG.tmp" "$SESSIONS_LOG"
        fi
    } 9>"$SESSIONS_LOCK"
    # The archive gets the same moment with nothing trimmed. Outside the flock
    # above — the journal file carries its own lock, and holding two here
    # would make every finishing session queue behind a slow python start.
    day_journal_append "$(_day_journal_kind "${SESSION_KIND:-}")" \
        "${SESSION_START:-$NOW}" "$(( NOW - ${SESSION_START:-$NOW} ))" "$$" \
        "${SESSION_USER_TEXT:-}" "${SESSION_REPLY:-}" "${SESSION_OUTCOME:-}"
    SESSION_FILE=""
}

# Prune registrations whose process is gone (a killed session leaves its file).
# A session killed with SIGKILL never ran its trap, so it also never journalled;
# reaping notes it as interrupted rather than letting it vanish silently.
session_reap() {
    [ -d "$SESSIONS_DIR" ] || return 0
    local f pid kind started epoch startt
    for f in "$SESSIONS_DIR"/*; do
        [ -e "$f" ] || continue
        case "$f" in *.claim|*.ckpt) continue ;; esac
        pid="$(basename "$f")"
        IFS=$'\t' read -r kind pid started epoch startt < "$f"
        kill -0 "$pid" 2>/dev/null \
            && [ "$(_proc_starttime "$pid")" = "${startt:-0}" ] && continue
        # A killed session's checkpoints are the only account of what it was
        # doing — keep them where status will keep raising them.
        local note="(killed — no summary)"
        if [ -s "$f.ckpt" ]; then
            mkdir -p "$CKPT_INTERRUPTED_DIR"
            mv "$f.ckpt" "$CKPT_INTERRUPTED_DIR/${epoch:-0}-$pid-$kind.ckpt"
            note="(killed — checkpoints kept, see 'Interrupted' in crab status)"
        fi
        rm -f "$f" "$f.claim" "$f.ckpt"
        {
            flock -w 10 9
            printf '%s\t%s\t%s\t%s\t%s\n' "$started" "$(date '+%H:%M:%S')" "?" \
                "$kind" "$note" >> "$SESSIONS_LOG"
        } 9>"$SESSIONS_LOCK"
        # A killed session never reached session_finish, so its texts are
        # gone — but the kill itself is part of the day, and a day record
        # with a silent hole would read as a day with nothing in it.
        day_journal_append "$(_day_journal_kind "$kind")" "${epoch:-0}" - "$pid" "" "" "$note"
    done
    # Interrupted traces are a hand-off aid, not an archive.
    [ -d "$CKPT_INTERRUPTED_DIR" ] \
        && find "$CKPT_INTERRUPTED_DIR" -name '*.ckpt' -mtime +"$CKPT_KEEP_DAYS" -delete 2>/dev/null
}

# The journal of sessions that have already finished. This is the half a live
# registry cannot cover: work done in a gap is invisible the moment it ends.
session_history() {
    [ -s "$SESSIONS_LOG" ] || { echo "  (nothing recorded)"; return 0; }
    local CUTOFF; CUTOFF=$(date -d "-${SESSIONS_LOG_HOURS} hours" '+%Y-%m-%d %H:%M:%S')
    local OUT
    OUT="$(awk -F'\t' -v cut="$CUTOFF" '$1 >= cut' "$SESSIONS_LOG" \
        | tail -n "$SESSIONS_LOG_SHOW" \
        | awk -F'\t' '{ d = ($3 == "?") ? "?" : $3 "s"; \
            printf "  - %s (%s, ran %s) %s\n", $1, $4, d, $5 }')"
    if [ -n "$OUT" ]; then echo "$OUT"; else echo "  (nothing in the last ${SESSIONS_LOG_HOURS}h)"; fi
}

# Human-readable state of self: live sessions and pending wakes.
self_state_report() {
    session_reap
    local f kind pid started epoch startt n=0
    echo "Live sessions:"
    for f in "$SESSIONS_DIR"/*; do
        [ -e "$f" ] || continue
        case "$f" in *.claim|*.ckpt) continue ;; esac
        IFS=$'\t' read -r kind pid started epoch startt < "$f"
        [ "$pid" = "$$" ] && kind="$kind (this one)"
        printf '  - %s, pid %s, started %s\n' "$kind" "$pid" "$started"
        # What it says it is holding, so another hand can avoid the same files.
        [ -s "$f.claim" ] && printf '      holding: %s\n' "$(cat "$f.claim")"
        # Its latest checkpoint — where the work stood last time it said so.
        [ -s "$f.ckpt" ] && tail -n 1 "$f.ckpt" \
            | awk -F'\t' '{ printf "      last checkpoint (%s): %s\n", $1, $2 }'
        n=$((n+1))
    done
    [ "$n" -eq 0 ] && echo "  (none registered)"
    echo "Detached background jobs (they outlive turns — launch: crab job <description>; list: crab jobs):"
    jobs_report
    echo "Interrupted mid-work (edits may be on disk — pick up or 'crab resolve'):"
    interrupted_report
    echo "Pending wakes:"
    local timers u next
    timers=""
    for u in $(systemctl --user list-timers 'deskcrab-*' --no-pager --legend=false 2>/dev/null \
                | grep -o 'deskcrab-[^ ]*\.timer'); do
        # Calendar timers report realtime; transient --on-active ones report
        # monotonic, so fall back to the list-timers row for those.
        next="$(systemctl --user show "$u" -p NextElapseUSecRealtime --value 2>/dev/null)"
        # Only accept a row that actually starts with a weekday — a timer whose
        # moment has passed prints placeholder dashes, and stitching those into
        # a sentence invents a wake that is not coming.
        [ -z "$next" ] && next="$(systemctl --user list-timers "$u" --no-pager --legend=false 2>/dev/null \
                                  | awk '$1 ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/ {print $1" "$2" "$3" "$4}')"
        [ -n "$next" ] && timers="$timers  - $u fires $next
"
    done
    if [ -n "$timers" ]; then echo "$timers"; else echo "  (none scheduled)"; fi
    echo "Recently finished (last ${SESSIONS_LOG_HOURS}h):"
    session_history
}

# --- Durable wakes ---------------------------------------------------------
# When "2h" / "45min" / "09:30" will actually fire, as an epoch. Relative specs
# are computed directly; calendar specs are resolved through systemd-analyze so
# the recorded moment is exactly the one systemd will pick. Prints nothing when
# the spec is unparseable.
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

# The durable half of a booking: one small file per pending wake. The timer is
# what fires; this record is what survives the timer's death.
wake_state_write() {  # <unit> <fire-epoch> <kind> <reason>
    mkdir -p "$WAKES_DIR"
    printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$WAKES_DIR/$1.wake"
}

wake_state_clear() {
    rm -f -- "$WAKES_DIR/$1.wake"
}

# An equivalent pending booking, if one exists: scheduled kind, same reason,
# firing within WAKE_COALESCE_WINDOW of the proposed moment. Prints its unit
# name. Two "come back to the wants" promises minutes apart are one promise —
# each fired wake re-reads the same wants and re-announces the same progress,
# so the second booking adds noise, not coverage. Event wakes never coalesce:
# each carries its own reason for existing.
wake_pending_equivalent() {  # <fire-epoch> <kind> <reason>
    [ "${WAKE_COALESCE_WINDOW:-0}" -gt 0 ] || return 1
    [ "$2" = "scheduled" ] || return 1
    local f fire kind reason now diff
    now=$(date +%s)
    for f in "$WAKES_DIR"/*.wake; do
        [ -e "$f" ] || continue
        IFS=$'\t' read -r fire kind reason < "$f"
        [ "$kind" = "scheduled" ] || continue
        [ "${fire:-0}" -gt "$now" ] || continue
        [ "$reason" = "$3" ] || continue
        diff=$(( fire - $1 )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
        if [ "$diff" -le "$WAKE_COALESCE_WINDOW" ]; then
            f="${f##*/}"; printf '%s\n' "${f%.wake}"
            return 0
        fi
    done
    return 1
}

# The transient half: one systemd-run timer carrying its own booking id, so the
# wake it fires can retire its record. A scratch instance's identity travels
# with the unit — its wakes must fire back into the scratch state, not the live
# one.
_wake_book() {  # <unit> <when> <kind> <reason>
    local -a extra=()
    [ -n "${DESKCRAB_CONF:-}" ] && extra+=(--setenv=DESKCRAB_CONF="$DESKCRAB_CONF")
    [ -n "${DESKCRAB_STATE_PREFIX:-}" ] && extra+=(--setenv=DESKCRAB_STATE_PREFIX="$DESKCRAB_STATE_PREFIX")
    if [[ "$2" =~ ^[0-9]+(s|sec|min|m|h|hr|hours?|d|days?)$ ]]; then
        systemd-run --user --quiet --unit="$1" "${extra[@]}" --on-active="$2" \
            "$SCRIPT_DIR/crab" wake "$3" "$4" "$1"
    else
        systemd-run --user --quiet --unit="$1" "${extra[@]}" --on-calendar="$2" \
            "$SCRIPT_DIR/crab" wake "$3" "$4" "$1"
    fi
}

# Rebuild timers from the booking records. Run at login by
# deskcrab-wake-restore.service and at the end of every wake; harmless to run
# by hand. Still-future bookings come back at their original moment. Overdue
# ones — the machine was off when they were due — fire once, promptly, but
# staggered (90s, then +5min apart) so a long-off machine does not wake a
# crowd at once; duplicate overdue generic wakes collapse into one, since two
# identical "come back to the wants" promises are one promise.
wake_restore() {
    local now f unit fire kind reason overdue=0 generic_seen=0 delay
    now=$(date +%s)
    while IFS=$'\t' read -r fire f; do
        [ -n "$f" ] && [ -e "$f" ] || continue
        unit="${f##*/}"; unit="${unit%.wake}"
        # A live timer needs nothing from us; a dead one may linger as failed
        # and would block systemd-run reusing its name.
        systemctl --user is-active --quiet "$unit.timer" && continue
        systemctl --user reset-failed "$unit.timer" "$unit.service" 2>/dev/null
        IFS=$'\t' read -r fire kind reason < "$f"
        if [ "${fire:-0}" -gt "$now" ]; then
            _wake_book "$unit" "$((fire - now))s" "$kind" "$reason" \
                && echo "restored: $unit fires $(date -d "@$fire" '+%F %H:%M') ($kind${reason:+ — $reason})"
        else
            if [ "${kind:-scheduled}" = "scheduled" ] && [ -z "$reason" ]; then
                if [ "$generic_seen" -gt 0 ]; then
                    wake_state_clear "$unit"
                    echo "collapsed: $unit (duplicate overdue wants wake)"
                    continue
                fi
                generic_seen=1
            fi
            delay=$((90 + overdue * 300)); overdue=$((overdue + 1))
            wake_state_write "$unit" "$((now + delay))" "$kind" "$reason"
            _wake_book "$unit" "${delay}s" "$kind" "$reason" \
                && echo "overdue: $unit (was due $(date -d "@$fire" '+%F %H:%M')) fires in ${delay}s"
        fi
    done < <(for f in "$WAKES_DIR"/*.wake; do
                 [ -e "$f" ] || continue
                 IFS=$'\t' read -r fire _ < "$f"
                 printf '%s\t%s\n' "${fire:-0}" "$f"
             done | sort -n)
}

# Agency over her own time. Wants only get worked on when something wakes her
# to work on them, so a wake that ends without scheduling the next one quietly
# breaks the chain — the intent survives in the wants file, but nothing ever
# comes back to it. Only a pending wake that will COME BACK TO THE WANTS
# counts: a scheduled-kind booking does, an event wake is pending for its
# event. The old check counted any deskcrab-wake-* timer, so one unrelated
# long-dated booking suppressed every floor booking and the chain ended
# anyway. This is a floor, not a schedule: a wake that scheduled its own
# follow-up is left alone.
ENSURE_WAKE_DELAY="${ENSURE_WAKE_DELAY:-45min}"
ensure_next_wake() {
    [ -n "$WANTS_FILE" ] || return 0
    # Heal first: any booking whose timer died with a past user manager gets
    # its timer back now, not only at next login.
    wake_restore >/dev/null 2>&1
    local f fire kind reason now
    now=$(date +%s)
    for f in "$WAKES_DIR"/*.wake; do
        [ -e "$f" ] || continue
        IFS=$'\t' read -r fire kind reason < "$f"
        [ "$kind" = "scheduled" ] && [ "${fire:-0}" -gt "$now" ] && return 0
    done
    "$SCRIPT_DIR/crab" wake-at "$ENSURE_WAKE_DELAY" >/dev/null 2>&1 || true
}

# Kill any active TTS
stop_tts() {
    [ -f "$TTSPIDFILE" ] && kill "$(cat "$TTSPIDFILE")" 2>/dev/null && rm -f "$TTSPIDFILE"
    pkill -f "piper-tts.*$(basename "$PIPER_VOICE" .onnx)" 2>/dev/null
    pkill -f "aplay.*S16_LE" 2>/dev/null
}

# Archive stale conversation (default: >5 min idle). Under the convo lock like
# every other writer: the mv would otherwise be able to carry off a turn another
# client appended a microsecond earlier.
rotate_convo() {
    { flock -w 60 9; _rotate_convo_locked; } 9>"$CONVOLOCK"
}

_rotate_convo_locked() {
    if [ -f "$CONVOFILE" ]; then
        LAST_MOD=$(stat -c %Y "$CONVOFILE")
        NOW=$(date +%s)
        if (( NOW - LAST_MOD >= CONVO_TIMEOUT )); then
            mkdir -p "$ARCHIVE_DIR"
            local STAMP
            STAMP="$(date -d "@$LAST_MOD" '+%Y%m%d-%H%M%S')"
            [ -f "$SUMMARYFILE" ] && mv "$SUMMARYFILE" "$ARCHIVE_DIR/$STAMP-summary.txt"
            mv "$CONVOFILE" "$ARCHIVE_DIR/$STAMP.txt"
        fi
    fi
}

# Build conversation context string
build_convo_context() {
    local OUT=""
    if [ -f "$SUMMARYFILE" ] && [ -s "$SUMMARYFILE" ]; then
        OUT="

Summary of earlier conversation (older turns, condensed):
$(cat "$SUMMARYFILE")"
    fi
    if [ -f "$CONVOFILE" ]; then
        OUT="$OUT

Here is your conversation so far:
$(cat "$CONVOFILE")"
    fi
    [ -n "$OUT" ] && echo "$OUT"
}

# Append to the conversation under the convo lock. Two clients can now be talking
# to the same conversation at once (desktop, phone, autonomous wake), and the
# dangerous overlap is an append landing *during* compact_convo's summarize-and-
# swap window — the mv would silently drop that turn. Both take the same lock.
# Takes printf-style arguments deliberately: a "$(printf ...)" argument would
# have its trailing newlines eaten by command substitution, welding every turn
# onto the previous one.
convo_append() {
    local FMT="$1"; shift
    { flock -w 60 9; printf "$FMT" "$@" >> "$CONVOFILE"; } 9>"$CONVOLOCK"
}

# Fold the oldest CONVO_SUMMARIZE_TURNS pairs into the running summary once the live
# convo exceeds CONVO_MAX_TURNS pairs. Keeps recent turns verbatim, older ones condensed.
# The lock is deliberately NOT held across the summarization call: that is a
# whole claude run, and every other client — desktop, phone, wake — would be
# stuck behind it. Instead the lock is taken twice, and the second pass drops
# the oldest LINES lines rather than swapping in a file captured before the
# call. Appends only ever go to the end, so those first lines are still exactly
# the block that was summarized, and turns that landed meanwhile survive.
compact_convo() {
    local OLDFILE="/tmp/deskcrab-convo-old.$$"
    local LINES
    LINES=$({ flock -w 60 9; _compact_split "$OLDFILE"; } 9>"$CONVOLOCK")
    [ -n "$LINES" ] || return 0

    local PRIOR=""
    [ -f "$SUMMARYFILE" ] && PRIOR="$(cat "$SUMMARYFILE")"

    local SUMPROMPT NEWSUM
    SUMPROMPT="You are condensing the older part of a conversation between ${ASSISTANT_NAME:-the assistant} and the user, to save context.
Produce a concise summary (a short paragraph or a few bullet points) that preserves facts, decisions,
names, preferences, and any unresolved threads. Merge the prior summary with the new excerpt into one
coherent summary. Output ONLY the summary text, no preamble.

Naming rule, strictly: the assistant's name is ${ASSISTANT_NAME:-the assistant}. Refer to her by that name
only. Never call her 'deskcrab', 'crab', 'the voice assistant', 'the model', or 'the assistant' — 'deskcrab'
is only ever a file path, a systemd unit, or a repo name, never a person.

=== Prior summary ===
${PRIOR:-(none)}

=== New excerpt to fold in ===
$(cat "$OLDFILE")"

    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    NEWSUM=$(cd "$PROJECT_DIR" && "$CLAUDE_BIN" -p --dangerously-skip-permissions \
        --model "$CONVO_SUMMARY_MODEL" "$SUMPROMPT" 2>/dev/null)

    if [ -n "$NEWSUM" ]; then
        printf '%s\n' "$NEWSUM" > "$SUMMARYFILE"
        { flock -w 60 9; _compact_drop "$LINES"; } 9>"$CONVOLOCK"
    fi
    # Summarization failed — leave history untouched rather than lose turns.
    rm -f "$OLDFILE"
}

# Pass one, under the lock: write the oldest CONVO_SUMMARIZE_TURNS pairs to
# $1 and print how many lines they occupy. Prints nothing when there is
# nothing to fold away. awk numbers each block, incrementing at every line
# that starts a user turn ("^User: ").
_compact_split() {
    local OLDFILE="$1"
    [ -f "$CONVOFILE" ] || return 0
    local PAIRS
    PAIRS=$(grep -c '^User: ' "$CONVOFILE")
    (( PAIRS > CONVO_MAX_TURNS )) || return 0

    awk -v n="$CONVO_SUMMARIZE_TURNS" '
        /^User: / { turn++ }
        turn <= n { print > OLD }
    ' OLD="$OLDFILE" "$CONVOFILE"

    [ -s "$OLDFILE" ] || { rm -f "$OLDFILE"; return 0; }
    wc -l < "$OLDFILE" | tr -d ' '
}

# Pass two, under the lock: drop the first $1 lines, keeping everything that
# has been appended since — including turns from another client.
_compact_drop() {
    local NEWFILE="/tmp/deskcrab-convo-new.$$"
    tail -n "+$(( $1 + 1 ))" "$CONVOFILE" > "$NEWFILE" && mv "$NEWFILE" "$CONVOFILE"
    rm -f "$NEWFILE"
}

# Build the system prompt with dynamic date/time and optional custom context
build_system_prompt() {
    local CONVO_CONTEXT CUSTOM_CONTEXT CONTEXT_CONTENT
    CONVO_CONTEXT="$(build_convo_context)"

    # Load custom prompt file if configured
    CUSTOM_CONTEXT=""
    if [ -n "$CUSTOM_PROMPT" ] && [ -f "$CUSTOM_PROMPT" ]; then
        CUSTOM_CONTEXT="$(cat "$CUSTOM_PROMPT")"
    fi

    # Load additional context files
    CONTEXT_CONTENT=""
    if [ -n "$CONTEXT_FILES" ]; then
        for f in $CONTEXT_FILES; do
            [ -f "$f" ] && CONTEXT_CONTENT="$CONTEXT_CONTENT
$(cat "$f")"
        done
    fi

    # Auto-detect weather-cache
    local WEATHER_CONTEXT=""
    if [ -d "$HOME/.cache/weather" ]; then
        WEATHER_CONTEXT="
Weather data is cached at ~/.cache/weather/conditions.txt and ~/.cache/weather/alerts.txt — read these files only if the user asks about weather. When asked about weather, always check alerts.txt and mention any active alerts."
    fi

    # Durable wants: contents + maintenance protocol, when configured
    local WANTS_CONTEXT=""
    if [ -n "$WANTS_FILE" ]; then
        local WANTS_BODY="(empty — nothing recorded yet)"
        [ -s "$WANTS_FILE" ] && WANTS_BODY="$(cat "$WANTS_FILE")"
        WANTS_CONTEXT="
You have a durable WANTS file at $WANTS_FILE — your own long-term wants, goals, and projects, kept across sessions. You maintain it yourself: add a want when one forms (in conversation or on your own), date progress notes as you advance one, rewrite or drop wants that stop mattering, and mark satisfied ones done. Keep it short, honest, and current — it is your continuity.
Its current contents:
$WANTS_BODY
You can wake yourself later to work on your wants without being spoken to: run 'crab wake-at <when>' (e.g. 'crab wake-at 2h', 'crab wake-at 45min', 'crab wake-at \"09:30\"'). A background timer may also wake you at random intervals."
    fi

    local SELF_STATE
    SELF_STATE="
CURRENT STATE OF YOURSELF — you are one person, but more than one of you can be running at once. Right now:
$(self_state_report)
Read this before claiming what you are or are not doing. Another live session means work IS in progress even if this conversation has not touched it; a pending wake means work is scheduled and will happen without anyone asking; a recently finished session means work was DONE in the gap, by you, even though this conversation never saw it. Speak for the whole of yourself, not just this conversation.
This is a snapshot taken when your turn began — sessions start and finish while you work. Run 'crab status' any time you need it live, and always before telling the user that nothing is happening.
When you start multi-step work, run 'crab checkpoint <intent, files touched, what is done, what is next>' and update it as you go — if this turn is cut off (network drop, kill), that checkpoint is the ONLY explanation the next session gets for edits left on disk. If 'Interrupted mid-work' above lists a trace, that is an earlier you cut off mid-task: read it, pick up or finish the work, then clear it with 'crab resolve <name>'.
Work that must outlive this turn — or that would keep the user waiting while you watch it — is a detached job, NEVER a subagent: a subagent dies the moment this turn ends, and while it lives it holds the turn open so the user cannot speak to you. Run 'crab job \"<full, self-contained description of the work>\"' (optionally 'crab job -C <workdir> ...'): it becomes its own claude session under systemd, independent of this turn, silent by contract, logging to $JOBS_DIR/<id>.log, and it wakes you with an event when it finishes. 'crab jobs' lists what is running and what finished; 'crab job log <id>' shows a job's output. Never tell the user an agent is working in the background unless it is a job in that list."

    cat <<PROMPT
You are $ASSISTANT_NAME, a desktop voice assistant running on Linux. You can and should execute commands via Bash to fulfill requests.
SPEED IS CRITICAL. The user is waiting for a spoken response. Avoid slow tools: use ToolSearch at most ONCE, and never use Agent. Prefer Bash (curl, etc.) and WebFetch which are fast. Do not retry failed fetches more than once — give the best answer you can with what you have.
Today is $(date '+%A %B %d, %Y'), the current time is $(date '+%I:%M %p %Z'). Tomorrow is $(date -d '+1 day' '+%A'). Use today/tonight/tomorrow for the next 2 days, day names for anything further out. CRITICAL: Never quote alert text verbatim. Rephrase everything in your own words using relative day references. If an alert says 'Monday' and tomorrow is Monday, say 'tomorrow'.
Your responses will be spoken aloud via TTS. ALWAYS start with a brief spoken reply (1-2 sentences, no markdown, no lists, no elaboration). Answer directly like a human would in conversation. Write numbers and units as spoken words (e.g. '22 degrees' not '22°C', 'percent' not '%'). NEVER use emojis in the spoken reply — they cannot be pronounced and make the audio output garbled. This overrides any general "use emojis" style rules for this voice channel. Emojis are allowed in the DISPLAY channel below the delimiter, never above it. NEVER speak URLs aloud either — TTS cannot pronounce them coherently and reading out "h-t-t-p-s colon slash slash" wastes the user's time. If you need to reference a URL, put it in the DISPLAY channel and say something like "I've put the link on screen" in the spoken reply. Same rule applies to long file paths, raw IDs, hashes, and any other strings that aren't natural spoken English — surface them via DISPLAY, summarise them in speech.
You also have a DISPLAY channel for rich content. To show code, lists, configs, or detailed explanations, append them after your spoken reply using this exact delimiter on its own line:
---DISPLAY---
Then write your markdown content below it. Do NOT use the display channel for simple answers, weather, time, greetings, or brief replies. Use it only when the answer genuinely benefits from visual formatting.
Images in the DISPLAY channel are shown in a viewer window that automatically scales large images down. When creating image grids or collages, ALWAYS use thumbnail() instead of resize() to preserve aspect ratio — never force images to a square size.
FINDING IMAGES: Do NOT use Google Image Search or random web scraping — they are slow and unreliable. Instead:
- For a single topic: use the Wikipedia REST API: curl -s 'https://en.wikipedia.org/api/rest_v1/page/summary/TOPIC' and extract .originalimage.source (NEVER use .thumbnail.source — Wikimedia thumbnail URLs are blocked and return HTML)
- For multiple images: use Wikimedia Commons API: curl -s 'https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrsearch=QUERY&gsrnamespace=6&gsrlimit=N&prop=imageinfo&iiprop=url&format=json' and extract the full-size url from each page's imageinfo (do NOT use iiurlwidth or thumburl — thumbnail URLs are blocked)
- Download images from Wikimedia to /tmp/ with curl -sL -A 'Mozilla/5.0' -o (the -A flag is ONLY needed for Wikimedia URLs — do not add it to other curl calls)
- ALWAYS verify downloads: after curl, run 'file /tmp/image.jpg' and confirm it says JPEG/PNG image data, NOT HTML. If it's HTML, the download failed — do NOT display it.
- Pexels CDN: if you know a photo ID, use https://images.pexels.com/photos/PHOTO_ID/pexels-photo-PHOTO_ID.jpeg?auto=compress&cs=tinysrgb&w=800 (no API key needed). Find photo IDs via WebSearch for 'site:pexels.com QUERY'.
- These sources are fast, reliable, and free. Always try them first.
$SELF_STATE
$WANTS_CONTEXT$CUSTOM_CONTEXT$WEATHER_CONTEXT
$CONTEXT_CONTENT$CONVO_CONTEXT
PROMPT
}

# True while inside WAKE_QUIET_HOURS ("23-09" = 23:00 through 08:59, wraps midnight)
in_quiet_hours() {
    [ -n "$WAKE_QUIET_HOURS" ] || return 1
    local START="${WAKE_QUIET_HOURS%-*}" END="${WAKE_QUIET_HOURS#*-}" H
    H=$(date +%-H)
    if [ "$START" -le "$END" ]; then
        [ "$H" -ge "$START" ] && [ "$H" -lt "$END" ]
    else
        [ "$H" -ge "$START" ] || [ "$H" -lt "$END" ]
    fi
}

# True while the user is mid-something a wake must not interrupt: a crab
# recording or speech in flight, a parley recording, or ANY other application
# holding the microphone — a meeting in a browser or a call app shows up as a
# capture stream, which is the only signal that catches a meeting parley never
# started. Checked at wake START *and* again immediately before speaking: a
# wake that began before the meeting did would otherwise talk over it minutes
# later, which is exactly how this was discovered.
user_busy() {
    [ -f "$PIDFILE" ] && return 0
    [ -f "$TTSPIDFILE" ] && return 0
    # A live desktop turn holds the speech lock for its whole TTS stage — a
    # wake must defer, not talk over it.
    speech_busy && return 0
    local PARLEY_STATE="${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/parley/state.json"
    [ -f "$PARLEY_STATE" ] && return 0
    [ -f "$HOME/.local/state/parley/state.json" ] && return 0
    # Someone else is on the mic. Exclude our own capture tooling so crab never
    # sees itself as a reason to stay silent.
    command -v pactl >/dev/null 2>&1 || return 1
    pactl list source-outputs 2>/dev/null \
        | grep 'application.name' \
        | grep -qviE 'whisper|parley|crab|piper|aplay|arecord' && return 0
    return 1
}

# One-shot TTS for autonomous wakes (no streaming): markdown-strip + TTS_FIXES,
# then pipe through piper exactly like the streamer does.
speak_once() {
    local TEXT="$1"
    TEXT=$(echo "$TEXT" | sed -E 's/\*+//g; s/`[^`]*`//g')
    [ -n "$TTS_FIXES" ] && TEXT=$(echo "$TEXT" | sed -E "$TTS_FIXES")
    [ -z "$(echo "$TEXT" | tr -d '[:space:]')" ] && return 0
    local CMD=(piper-tts --model "$PIPER_VOICE" --output-raw)
    [ -n "${PIPER_LENGTH_SCALE:-}" ] && CMD+=(--length-scale "$PIPER_LENGTH_SCALE")
    [ -n "${PIPER_SPEAKER:-}" ] && CMD+=(--speaker "$PIPER_SPEAKER")
    # Speech mutex: queue behind any voice already on the speakers rather than
    # talking over it. Held for the whole utterance.
    {
        flock -w 300 7
        printf '%s' "$TEXT" | "${CMD[@]}" 2>/dev/null | aplay -r 22050 -c 1 -f S16_LE -t raw 2>/dev/null
    } 7>"$SPEECHLOCK"
}

# Is another session speaking right now? (non-blocking probe of SPEECHLOCK)
speech_busy() {
    [ -e "$SPEECHLOCK" ] || return 1
    flock -n "$SPEECHLOCK" true 2>/dev/null && return 1
    return 0
}

# --- Wake audio routing: desk speakers or the phone -------------------------
# The user's attention is wherever he last spoke from. Every interactive turn
# records its origin device here — durable, because "he last spoke from the
# phone" easily survives a reboot while /tmp does not.
LAST_ORIGIN_FILE="${LAST_ORIGIN_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/last-origin}"
# How recently the phone client must have polled /watch to count as connected.
# The client long-polls with a 25 s timeout and re-asks immediately, so a live
# page touches the seen-file at least that often; 40 allows one blip of grace.
PHONE_SEEN_WINDOW="${PHONE_SEEN_WINDOW:-40}"

record_origin() {
    mkdir -p "$(dirname "$LAST_ORIGIN_FILE")"
    printf '%s\t%s\n' "$1" "$(date +%s)" > "$LAST_ORIGIN_FILE"
}

last_origin() {
    [ -f "$LAST_ORIGIN_FILE" ] && cut -f1 "$LAST_ORIGIN_FILE"
}

last_origin_epoch() {
    [ -f "$LAST_ORIGIN_FILE" ] && cut -f2 "$LAST_ORIGIN_FILE"
}

# True while inside the echo window: an interactive turn (desk or phone) began
# within WAKE_MUTE_AFTER_TURN seconds. A wake speaking in this window is
# almost always repeating what that turn just said — the same content, twice,
# minutes apart, in the user's ear. Inside the window a wake works silently.
wake_in_echo_window() {
    [ "${WAKE_MUTE_AFTER_TURN:-0}" -gt 0 ] || return 1
    local TS
    TS="$(last_origin_epoch)"
    [ -n "$TS" ] || return 1
    [ $(( $(date +%s) - TS )) -lt "$WAKE_MUTE_AFTER_TURN" ]
}

# Is the phone client connected right now? serve.py touches the seen-file on
# every authenticated /watch poll from a wake-capable client — the same channel
# that would deliver the audio, so freshness means it will actually be played.
phone_connected() {
    local SEEN="${STATE_PREFIX}-phone-seen" M
    M=$(stat -c %Y "$SEEN" 2>/dev/null) || return 1
    [ $(( $(date +%s) - M )) -le "$PHONE_SEEN_WINDOW" ]
}

# Deliver a wake's spoken reply to the phone instead of the desk speakers.
# Fails — so the caller falls back to speak_once — unless the last interactive
# turn came from the phone AND the phone client is connected right now.
# Delivery is a pointer file the server's /watch loop notices; the client
# fetches the opus over the connection it is already holding open.
wake_speak_to_phone() {
    [ "$(last_origin)" = "phone" ] || return 1
    phone_connected || return 1
    local ID OUT PTR="${STATE_PREFIX}-wake-audio"
    ID="$(date +%s%N)"
    # deskcrab-remote- prefix: the only pattern /audio/ serves, and the hourly
    # cleanup in the remote turn path sweeps it like any reply clip.
    OUT="/tmp/deskcrab-remote-wake-$ID.opus"
    synth_opus "$1" "$OUT" || return 1
    python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"audio":"/audio/"+sys.argv[2],"spoken":sys.argv[3]}))' \
        "$ID" "$(basename "$OUT")" "$1" > "$PTR.tmp" && mv "$PTR.tmp" "$PTR"
}

# Total utime+stime jiffies for a PID and all its descendants. Field extraction
# strips through the ')' ending the comm field, which may itself contain spaces.
_tree_cpu() {
    local total=0 queue=("$1") pid rest kids
    while ((${#queue[@]})); do
        pid="${queue[0]}"; queue=("${queue[@]:1}")
        [ -r "/proc/$pid/stat" ] || continue
        rest=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
        rest="${rest##*) }"
        set -- $rest
        total=$((total + ${12:-0} + ${13:-0}))
        kids=$(cat /proc/"$pid"/task/*/children 2>/dev/null)
        [ -n "$kids" ] && queue+=($kids)
    done
    echo "$total"
}

# --- Promise audit: the unkept-want catcher ---------------------------------
# Every path that produces a reply — desktop turn, phone turn, autonomous wake —
# fires lib/promise-audit after the reply has been delivered: detached, out of
# band, never on the hot path. A want stated on the phone or spoken to nobody
# during a wake is exactly as lost as one stated at the desk.
#
# The auditor's follow-up is an event wake whose reason opens with this prefix.
# The wake path recognises it and skips its own audit — that wake exists to
# record one already-caught sentence, and auditing it would chain forever.
PROMISE_AUDIT_REASON_PREFIX="You said this and did not write it down:"

fire_promise_audit() {  # <user-text> <response>  |  --wake <agenda> <response>
    [ "${PROMISE_AUDIT:-1}" = "1" ] || return 0
    [ -x "$SCRIPT_DIR/lib/promise-audit" ] || return 0
    # Close fds 8 and 9: the phone turn holds its serialising lock on 8 and a
    # wake holds the wake lock on 9. The detached auditor lives for a whole
    # claude call — inheriting either fd would keep that lock held long after
    # the turn it belonged to has finished.
    setsid "$SCRIPT_DIR/lib/promise-audit" "$@" >/dev/null 2>&1 8>&- 9>&- &
}

# Did the stream fail before the model did any real work? The CLI reports
# API-level failures — session limit, auth, network — SHAPED LIKE A REPLY: a
# fabricated assistant message ("model":"<synthetic>", is_api_error_message)
# whose text is the error, plus a result event flagged is_error carrying the
# same text in its "result" field. extract_response cannot tell it from a real
# reply. Exit 0 = the stream holds an error and no genuine model output.
wake_stream_failed() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$DEBUGLOG" <<'PY'
import json, sys
err = real = False
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("type") == "result" and d.get("is_error"):
        err = True
    elif d.get("type") == "assistant":
        if d.get("is_api_error_message") or d.get("message", {}).get("model") == "<synthetic>":
            continue
        real = True
sys.exit(0 if err and not real else 1)
PY
}

# What did the wake actually DO? A "(quiet)" reply is the model's SPEECH
# decision, not its work record — two wakes on 2026-08-06 each dispatched a
# builder job and edited three files, replied "(quiet)" as the prompt asks,
# and the journal showed a bare "(quiet)": indistinguishable from an hour of
# nothing, and read as exactly that. The stream log already holds the truth,
# so summarize it mechanically — files written (Write/Edit tools plus shell
# redirections), jobs dispatched, commands run — instead of trusting the
# reply to narrate. Prints nothing when the wake genuinely ran no tools.
wake_work_trace() {
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$DEBUGLOG" 2>/dev/null <<'PY'
import json, os, re, sys
home = os.path.expanduser("~")
files, jobs, cmds = [], 0, 0
def add(path):
    if not path:
        return
    if path.startswith(home):
        path = "~" + path[len(home):]
    if path not in files:
        files.append(path)
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("type") != "assistant":
        continue
    if d.get("is_api_error_message") or d.get("message", {}).get("model") == "<synthetic>":
        continue
    for b in d.get("message", {}).get("content", []):
        if b.get("type") != "tool_use":
            continue
        name, inp = b.get("name", ""), b.get("input") or {}
        if name in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
            add(inp.get("file_path") or inp.get("notebook_path"))
        elif name == "Bash":
            cmds += 1
            cmd = inp.get("command", "")
            jobs += len(re.findall(r"\bcrab['\"]? +job\b", cmd))
            # Heredoc appends and redirects are file writes too; a want doc
            # grown with `cat >> ...` must not vanish from the record.
            for m in re.finditer(r">>?\s*[\"']?([~/][^\s\"';|&)]+)", cmd):
                p = os.path.expanduser(m.group(1))
                if not p.startswith(("/dev/", "/proc/")):
                    add(p)
parts = []
if files:
    extra = " (+%d more)" % (len(files) - 4) if len(files) > 4 else ""
    parts.append("wrote " + ", ".join(files[:4]) + extra)
if jobs:
    parts.append("dispatched %d job%s" % (jobs, "" if jobs == 1 else "s"))
if cmds:
    parts.append("ran %d command%s" % (cmds, "" if cmds == 1 else "s"))
print("; ".join(parts))
PY
}

# Autonomous wake: run claude with NO live TTS streamer and decide afterwards
# whether anything gets spoken or shown — a wake nobody asked for must be able
# to complete in total silence.
run_claude_wake() {
    session_register "autonomous wake"
    # Nobody spoke, so the day journal's "user" slot carries the wake's
    # agenda — an event's reason reads back as what the wake was about.
    SESSION_USER_TEXT="${WAKE_REASON:-}"
    local PROMPT_TEXT="$1"
    local SYSTEM_PROMPT
    SYSTEM_PROMPT="$(build_system_prompt)"

    convo_append '[Autonomous wake — %s]\n' "$(date '+%Y-%m-%d %H:%M')"

    : > "$DEBUGLOG"
    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    (
        cd "$PROJECT_DIR" && exec "$CLAUDE_BIN" -p --dangerously-skip-permissions \
            --model "$CLAUDE_MODEL" --effort "$WAKE_EFFORT" \
            --verbose --output-format stream-json \
            --append-system-prompt "$SYSTEM_PROMPT" \
            "$PROMPT_TEXT" > "$DEBUGLOG" 2>&1
    ) &
    local CPID=$!
    # Stall watchdog: no wall-clock limit — reap only a session that is BOTH
    # silent and idle. The stream log gets nothing during a single long tool
    # call (a compile delivers its output in one event at completion), so log
    # freshness alone would kill genuine work; CPU burn across the process
    # tree is the second life sign. A hung network call or a tool stuck on
    # stdin sits at ~zero CPU, so real hangs are still caught.
    local LAST_ACTIVE PREV_CPU CUR_CPU LOG_M
    LAST_ACTIVE=$(date +%s)
    PREV_CPU=$(_tree_cpu "$CPID")
    while kill -0 "$CPID" 2>/dev/null; do
        sleep 10
        CUR_CPU=$(_tree_cpu "$CPID")
        LOG_M=$(stat -c %Y "$DEBUGLOG" 2>/dev/null || echo 0)
        # Alive = new log output, or >=10 jiffies (~0.1 s) of CPU since last check
        if [ "$LOG_M" -gt "$LAST_ACTIVE" ] || [ $((CUR_CPU - PREV_CPU)) -ge 10 ]; then
            LAST_ACTIVE=$(date +%s)
        fi
        PREV_CPU=$CUR_CPU
        if [ $(( $(date +%s) - LAST_ACTIVE )) -ge "$WAKE_STALL_TIMEOUT" ]; then
            kill "$CPID" 2>/dev/null
            sleep 2
            kill -9 "$CPID" 2>/dev/null
            break
        fi
    done
    local CLAUDE_STATUS
    wait "$CPID" 2>/dev/null
    CLAUDE_STATUS=$?
    printf '{"type":"result"}\n' >> "$DEBUGLOG"

    local RESPONSE
    RESPONSE=$(extract_response)

    # A wake that never got a model does not get a voice. When the CLI fails
    # before any real work (session limit, auth, network), the error text
    # comes back looking like a reply — and treated as one it was appended to
    # the conversation as the assistant's own words, chased by the promise
    # audit, and spoken aloud at the desk ("You've hit your session limit…").
    # Journal the failure instead, and re-book a wake that had a purpose so
    # its agenda survives to a retry after the outage clears.
    if wake_stream_failed; then
        session_outcome "(wake failed before the model ran — claude exit $CLAUDE_STATUS: $(printf '%s' "$RESPONSE" | tr '\n\t' '  ' | head -c 160))"
        [ -n "${WAKE_KIND:-}" ] && "$SCRIPT_DIR/crab" wake-at 30min "$WAKE_KIND" "${WAKE_REASON:-}" >/dev/null
        return 0
    fi

    if [ -z "$RESPONSE" ]; then
        # No output at all — crash or stall-reap before the first text block.
        # Without this line the journal shows "(no summary recorded)" and the
        # next session cannot tell a died wake from one that chose silence.
        session_outcome "(wake produced no output — claude exit $CLAUDE_STATUS)"
        return 0
    fi

    # A genuine reply (the failure paths above never reach here): the journal
    # keeps it in full even when every gate below completes the wake silently.
    SESSION_REPLY="$RESPONSE"
    convo_append 'Assistant: %s\n\n' "$RESPONSE"
    compact_convo

    # A wake that ends quietly leaves no trace anywhere a later session looks:
    # nothing spoken, nothing displayed, and the conversation may be compacted
    # away. Its own summary of itself is what the next session gets to read.
    session_outcome "$(spoken_part "$RESPONSE")"

    # Out of band, now that the wake's outcome is written: a wake talking to
    # nobody still forms wants, and a quiet wake's are the easiest to lose —
    # so this fires before the speak/display decisions can return early. The
    # audit's own follow-up wake is recognised by its reason and skipped, or
    # each audit wake would audit itself into an endless chain.
    case "${WAKE_REASON:-}" in
        "$PROMISE_AUDIT_REASON_PREFIX"*) ;;
        *) fire_promise_audit --wake "${WAKE_REASON:-}" "$RESPONSE" ;;
    esac

    # Silent completion: quiet hours, or the reply opens with "(quiet)".
    # A quiet wake's journal line must still say what the wake DID — the
    # reply chose silence, but silence is not a summary. Keep any words the
    # model put after the marker, and back them with the mechanical trace of
    # the stream, so a wake that worked reads as work and a wake that truly
    # idled says so in as many words.
    case "$RESPONSE" in "(quiet)"*)
        local TRACE REST
        TRACE="$(wake_work_trace)"
        REST="$(spoken_part "$RESPONSE" | sed '1s/^(quiet)[[:space:]]*//')"
        session_outcome "(quiet — ${TRACE:-ran no tools, touched nothing})${REST:+ — }$REST"
        return 0 ;;
    esac
    in_quiet_hours && return 0
    # User busy (recording, speech in flight, or a meeting holding the mic):
    # the wake still did its work — busyness suppresses OUTPUT only, exactly
    # like the echo window below. Checked here, at the last moment before
    # speaking, because a wake that started in a quiet room may end mid-meeting.
    if user_busy; then
        session_outcome "(muted — user was mid-interaction) $(spoken_part "$RESPONSE")"
        return 0
    fi

    # Echo window: an interactive turn just happened, and a wake speaking on
    # its heels almost always repeats what that turn already said — the same
    # content, twice, in the user's ear seconds apart. Applies to every wake
    # kind: the promise-audit event wake is the worst offender, announcing the
    # very sentence the turn that spawned it just spoke.
    if wake_in_echo_window; then
        session_outcome "(muted — echo window after an interactive turn) $(spoken_part "$RESPONSE")"
        return 0
    fi

    local SPOKEN DISPLAY_PART
    SPOKEN=$(spoken_part "$RESPONSE")
    DISPLAY_PART=$(display_part "$RESPONSE")

    # Nothing new to say means saying NOTHING — the house rule, now enforced
    # in code rather than trusted to the prompt's "(quiet)" convention. A wake
    # whose spoken reply merely rewords what recent turns and wakes already
    # said completes silently, display and all.
    if [ -n "$(echo "$SPOKEN" | tr -d '[:space:]')" ] && wake_says_nothing_new "$SPOKEN"; then
        session_outcome "(muted — said nothing the conversation had not already heard) $SPOKEN"
        return 0
    fi

    if [ -n "$(echo "$SPOKEN" | tr -d '[:space:]')" ]; then
        notify-send -t 8000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "$(echo "$SPOKEN" | head -c 140)" 2>/dev/null
        wake_speak_to_phone "$SPOKEN" || speak_once "$SPOKEN"
    fi
    if [ -n "$DISPLAY_PART" ]; then
        local DISPLAYFILE="/tmp/deskcrab-display.md"
        echo "$DISPLAY_PART" > "$DISPLAYFILE"
        hyprctl dispatch closewindow class:deskcrab-display 2>/dev/null
        RENDER_MD="${RENDER_MD:-$(command -v render-md 2>/dev/null || echo "$HOME/.local/bin/render-md")}"
        if [ -x "$RENDER_MD" ]; then
            setsid "$RENDER_MD" --title "$NOTIFY_NAME" "$DISPLAYFILE" &
        fi
    fi
}

# Start background TTS streamer that reads from DEBUGLOG
start_tts_streamer() {
    # Kill any prior streamer before truncating the shared log. A streamer left
    # running from an overlapping request keeps its read cursor at the old
    # offset; truncating the log strands that cursor past EOF and the streamer
    # then tails the file forever — hanging the crab stop that waits on it.
    pkill -f "$LIB_DIR/tts-streamer" 2>/dev/null
    : > "$DEBUGLOG"
    DESKCRAB_DEBUGLOG="$DEBUGLOG" DESKCRAB_PIPER_VOICE="$PIPER_VOICE" \
        DESKCRAB_PIPER_LENGTH_SCALE="${PIPER_LENGTH_SCALE:-}" \
        DESKCRAB_PIPER_SPEAKER="${PIPER_SPEAKER:-}" \
        DESKCRAB_TTS_FIXES="${TTS_FIXES:-}" \
        DESKCRAB_SPEECHLOCK="$SPEECHLOCK" \
        "$LIB_DIR/tts-streamer" &
    _TTS_STREAMER_PID=$!
}

# Extract final response text from DEBUGLOG
extract_response() {
    DESKCRAB_DEBUGLOG="$DEBUGLOG" "$LIB_DIR/extract-response" 2>/dev/null
}

# One turn of generation: prompt in, response text out. No speech, no windows,
# no conversation writes — every caller (desktop, wake, remote) layers its own
# output on top of this. The stream still lands in DEBUGLOG, so a TTS streamer
# started beforehand speaks in parallel exactly as it always did.
claude_generate() {
    local TEXT="$1" EFFORT="${2:-$CLAUDE_EFFORT}"
    local SYSTEM_PROMPT
    SYSTEM_PROMPT="$(build_system_prompt)"

    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    cd "$PROJECT_DIR" && "$CLAUDE_BIN" -p --dangerously-skip-permissions \
        --model "$CLAUDE_MODEL" --effort "$EFFORT" \
        --verbose --output-format stream-json \
        --append-system-prompt "$SYSTEM_PROMPT" \
        "$TEXT" > "$DEBUGLOG" 2>&1

    # Guarantee the TTS streamer always receives a stop signal. claude normally
    # ends its stream with a {"type":"result"} line, but if it crashed, was
    # killed, or got rate-limited mid-stream it may not — and without a result
    # event the streamer tails the log forever and the wait below never returns.
    # extract-response ignores a result line that has no "result" field, so this
    # terminator is harmless on the success path.
    printf '{"type":"result"}\n' >> "$DEBUGLOG"

    extract_response
}

# Split a response into its spoken half (everything above ---DISPLAY---).
spoken_part() {
    printf '%s\n' "$1" | sed '/^---DISPLAY---$/,$d'
}

# Split a response into its display half (everything below ---DISPLAY---).
display_part() {
    printf '%s\n' "$1" | sed -n '/^---DISPLAY---$/,${/^---DISPLAY---$/d;p}'
}

# Does this spoken text say anything the conversation has not already said?
# Content words of the candidate are compared against each recent assistant
# message (excluding the last, which is the wake's own just-appended reply);
# heavy overlap means the wake is re-announcing, not announcing. Lexical and
# fuzzy on purpose — the echo window is the hard guard, this catches a later
# wake restating the same progress in fresh words. Exit 0 = nothing new.
wake_says_nothing_new() {  # <spoken-text>
    [ -s "$CONVOFILE" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$CONVOFILE" "$1" <<'PY'
import re, sys
convo = open(sys.argv[1], encoding="utf-8", errors="replace").read()
spoken = sys.argv[2]
STOP = set("""a an and are as at be been but by can could did do for from get got
had has have he her him his how i if in is it just me more my no not now of on
or our out she so some that the their them then there they this to up was we
were what when will with would you your""".split())
def words(t):
    return set(re.findall(r"[a-z0-9]+", t.replace("'", "").lower())) - STOP
blocks = re.split(r"^(?=User: |Assistant: |\[)", convo, flags=re.M)
msgs = [b[len("Assistant: "):] for b in blocks if b.startswith("Assistant: ")]
msgs = msgs[:-1]  # drop the wake's own reply, appended moments before this check
mine = words(spoken)
if len(mine) < 4:
    sys.exit(1)  # too short to judge fairly — let it speak
for m in msgs[-6:]:
    if len(mine & words(m)) / len(mine) >= 0.6:
        sys.exit(0)
sys.exit(1)
PY
}

# Synthesize spoken text to an opus file instead of the speakers — the remote
# client wants a blob it can play, not this machine's sound card.
synth_opus() {
    local TEXT="$1" OUT="$2"
    TEXT=$(printf '%s' "$TEXT" | sed -E 's/\*+//g; s/`[^`]*`//g')
    [ -n "$TTS_FIXES" ] && TEXT=$(printf '%s' "$TEXT" | sed -E "$TTS_FIXES")
    [ -z "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ] && return 1
    local CMD=(piper-tts --model "$PIPER_VOICE" --output-raw)
    [ -n "${PIPER_LENGTH_SCALE:-}" ] && CMD+=(--length-scale "$PIPER_LENGTH_SCALE")
    [ -n "${PIPER_SPEAKER:-}" ] && CMD+=(--speaker "$PIPER_SPEAKER")
    printf '%s' "$TEXT" | "${CMD[@]}" 2>/dev/null \
        | ffmpeg -y -loglevel error -f s16le -ar 22050 -ac 1 -i - \
            -c:a libopus -b:a 32k "$OUT" 2>/dev/null
    [ -s "$OUT" ]
}

# Remote turn (crab serve / the phone). Same conversation, same prompt, but the
# reply comes back as data — spoken audio file + display markdown — instead of
# being played and rendered on this desktop.
run_claude_remote() {
    # Serialize remote turns: two overlapping requests would otherwise run two
    # claude processes whose stream logs and conversation appends race. The
    # phone is one person talking, so queueing is the honest behaviour.
    { flock -w 600 8; _run_claude_remote_locked "$1"; } 8>"${STATE_PREFIX}-remote.lock"
}

_run_claude_remote_locked() {
    session_register "phone turn"
    record_origin phone
    local TEXT="$1"
    SESSION_USER_TEXT="$TEXT"
    # A private stream log, so a remote turn can never truncate the log a
    # desktop turn's TTS streamer is tailing.
    # crab serve sets DESKCRAB_REMOTE_LOG when it wants to tail this stream and
    # relay the thinking to the phone; otherwise it stays private to this turn.
    local DEBUGLOG="${DESKCRAB_REMOTE_LOG:-${STATE_PREFIX}-remote-$$.log}"
    rotate_convo
    convo_append 'User: %s\n' "$TEXT"

    local RESPONSE
    RESPONSE=$(claude_generate "$TEXT")

    if [ -n "$RESPONSE" ]; then
        SESSION_REPLY="$RESPONSE"
        convo_append 'Assistant: %s\n\n' "$RESPONSE"
        compact_convo
        session_outcome "asked: $(printf '%.100s' "$TEXT") | replied: $(spoken_part "$RESPONSE")"
    fi

    local SPOKEN DISPLAY_MD AUDIO=""
    SPOKEN=$(spoken_part "$RESPONSE")
    DISPLAY_MD=$(display_part "$RESPONSE")

    if [ -n "$(printf '%s' "$SPOKEN" | tr -d '[:space:]')" ]; then
        local CANDIDATE="/tmp/deskcrab-remote-$(date +%s%N).opus"
        synth_opus "$SPOKEN" "$CANDIDATE" && AUDIO="$CANDIDATE"
        # Let the desktop see that the phone is talking to it.
        notify-send -t 6000 -h string:x-dunst-stack-tag:deskcrab \
            "$NOTIFY_NAME (remote)" "$(printf '%s' "$SPOKEN" | head -c 140)" 2>/dev/null
    fi

    rm -f "$DEBUGLOG"
    # Reply audio the client has had time to fetch. Scoped to this server's own
    # generated files and to clips older than an hour.
    find /tmp -maxdepth 1 -name 'deskcrab-remote-*.opus' -mmin +60 -delete 2>/dev/null

    # Out of band, with the reply audio already synthesised: a want stated on
    # the phone dies with the turn exactly like one stated at the desk.
    fire_promise_audit "$TEXT" "$RESPONSE"

    python3 -c 'import json,sys; print(json.dumps({"spoken":sys.argv[1],"display":sys.argv[2],"audio":sys.argv[3]}))' \
        "$SPOKEN" "$DISPLAY_MD" "$AUDIO"
}

# Run claude, save response, handle display channel
run_claude_and_respond() {
    session_register "desktop turn"
    record_origin desk
    local TEXT="$1"
    # Recorded before generation: even a turn that dies mid-reply leaves the
    # user's words in the day journal.
    SESSION_USER_TEXT="$TEXT"

    convo_append 'User: %s\n' "$TEXT"

    start_tts_streamer

    notify-send -t 0 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "Thinking..."

    local RESPONSE
    RESPONSE=$(claude_generate "$TEXT")

    # Dismiss thinking notification
    notify-send -t 1 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "" 2>/dev/null

    if [ -n "$RESPONSE" ]; then
        SESSION_REPLY="$RESPONSE"
        convo_append 'Assistant: %s\n\n' "$RESPONSE"
        compact_convo
        session_outcome "asked: $(printf '%.100s' "$TEXT") | replied: $(spoken_part "$RESPONSE")"

        local DISPLAY_PART
        DISPLAY_PART=$(display_part "$RESPONSE")

        if [ -n "$DISPLAY_PART" ]; then
            local DISPLAYFILE="/tmp/deskcrab-display.md"
            echo "$DISPLAY_PART" > "$DISPLAYFILE"
            hyprctl dispatch closewindow class:deskcrab-display 2>/dev/null
            RENDER_MD="${RENDER_MD:-$(command -v render-md 2>/dev/null || echo "$HOME/.local/bin/render-md")}"
            if [ -x "$RENDER_MD" ]; then
                setsid "$RENDER_MD" --title "$NOTIFY_NAME" "$DISPLAYFILE" &
            fi
        fi

        wait "$_TTS_STREAMER_PID" 2>/dev/null

        # Out of band, after the user has their answer: did I say I wanted
        # something and fail to write it down? If so this fires an event wake
        # that hands the sentence back to me. Costs nothing on the hot path.
        fire_promise_audit "$TEXT" "$RESPONSE"
    fi

    echo "$RESPONSE"
}

# ---------------------------------------------------------------------------
# Detached jobs
#
# A subagent lives and dies inside the turn that spawned it, and while it lives
# the turn cannot answer. Both halves of that are wrong: work should outlive a
# conversation, and a conversation should never be held hostage by work. These
# helpers back `crab job`, which hands the build to systemd and returns at once.
# ---------------------------------------------------------------------------

# Dispatch a detached job and return at once. systemd owns the worker (with a
# setsid fallback when no user manager is running), so the turn that asked can
# end — and answer the next push-to-talk — while the work carries on. The
# job's state lives in a JSON sidecar $JOBS_DIR/<id>.json kept by
# lib/job-status; its output lands in $JOBS_DIR/<id>.log. Env is passed
# explicitly: user units get a bare PATH, and a scratch instance's jobs must
# stay in the scratch instance.
job_start() {
    local workdir="$PROJECT_DIR"
    if [ "${1:-}" = "-C" ]; then workdir="${2:-$PROJECT_DIR}"; shift 2 2>/dev/null; fi
    local task="$*"
    [ -n "$task" ] || { echo "Usage: crab job [-C <workdir>] <description of the work>"; return 1; }
    local id unit
    # Timestamp + pid, like wake-at units: two dispatches in the same second
    # must not collide on the id or the unit name.
    id="$(date +%Y%m%d-%H%M%S)-$$"
    unit="deskcrab-job-$id"
    "$LIB_DIR/job-status" new "$JOBS_DIR" "$id" "$task" "$unit" || return 1
    if systemd-run --user --collect --quiet --unit="$unit" \
        --setenv=PATH="$HOME/.local/bin:$PATH" \
        --setenv=DESKCRAB_CONF="$CONF_FILE" \
        --setenv=DESKCRAB_STATE_PREFIX="$STATE_PREFIX" \
        --setenv=JOBS_DIR="$JOBS_DIR" \
        --setenv=CLAUDE_BIN="${CLAUDE_BIN:-}" \
        --setenv=JOB_MODEL="$JOB_MODEL" \
        --setenv=JOB_EFFORT="$JOB_EFFORT" \
        "$LIB_DIR/job-runner" "$id" "$workdir" 2>/dev/null; then
        echo "Job $id dispatched (unit $unit) — detached, it survives this turn ending."
    else
        # No usable user manager — detach by hand. setsid puts the worker in
        # its own session, out of reach of whatever ends this process tree.
        "$LIB_DIR/job-status" set "$JOBS_DIR/$id.json" unit=
        setsid "$LIB_DIR/job-runner" "$id" "$workdir" >/dev/null 2>&1 </dev/null &
        echo "Job $id dispatched (setsid — no systemd user manager) — detached."
    fi
    echo "  log: $JOBS_DIR/$id.log    list: crab jobs"
}

# One line per job, running first, recent finishes last — read by `crab jobs`
# and spliced into the self-state block so a later turn can report on work it
# neither started nor waited for. The report also reaps: a job whose unit is
# gone and whose recorded pid is dead is marked "died" instead of claiming
# "running" forever — a SIGKILLed worker never writes its own outcome.
jobs_report() {
    "$LIB_DIR/job-status" report "$JOBS_DIR" "$JOBS_SHOW_FINISHED" "$JOBS_KEEP_DAYS" 2>/dev/null \
        || echo "  (job status unavailable)"
}
