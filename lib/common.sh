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
    SUMPROMPT="You are condensing the older part of a voice-assistant conversation to save context.
Produce a concise summary (a short paragraph or a few bullet points) that preserves facts, decisions,
names, preferences, and any unresolved threads. Merge the prior summary with the new excerpt into one
coherent summary. Output ONLY the summary text, no preamble.

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
    printf '%s' "$TEXT" | "${CMD[@]}" 2>/dev/null | aplay -r 22050 -c 1 -f S16_LE -t raw 2>/dev/null
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

# Autonomous wake: run claude with NO live TTS streamer and decide afterwards
# whether anything gets spoken or shown — a wake nobody asked for must be able
# to complete in total silence.
run_claude_wake() {
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
    wait "$CPID" 2>/dev/null
    printf '{"type":"result"}\n' >> "$DEBUGLOG"

    local RESPONSE
    RESPONSE=$(extract_response)
    [ -z "$RESPONSE" ] && return 0

    convo_append 'Assistant: %s\n\n' "$RESPONSE"
    compact_convo

    # Silent completion: quiet hours, or the reply opens with "(quiet)".
    case "$RESPONSE" in "(quiet)"*) return 0 ;; esac
    in_quiet_hours && return 0

    local SPOKEN DISPLAY_PART
    SPOKEN=$(spoken_part "$RESPONSE")
    DISPLAY_PART=$(display_part "$RESPONSE")

    if [ -n "$(echo "$SPOKEN" | tr -d '[:space:]')" ]; then
        notify-send -t 8000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "$(echo "$SPOKEN" | head -c 140)" 2>/dev/null
        speak_once "$SPOKEN"
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
    local TEXT="$1"
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
        convo_append 'Assistant: %s\n\n' "$RESPONSE"
        compact_convo
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

    python3 -c 'import json,sys; print(json.dumps({"spoken":sys.argv[1],"display":sys.argv[2],"audio":sys.argv[3]}))' \
        "$SPOKEN" "$DISPLAY_MD" "$AUDIO"
}

# Run claude, save response, handle display channel
run_claude_and_respond() {
    local TEXT="$1"

    convo_append 'User: %s\n' "$TEXT"

    start_tts_streamer

    notify-send -t 0 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "Thinking..."

    local RESPONSE
    RESPONSE=$(claude_generate "$TEXT")

    # Dismiss thinking notification
    notify-send -t 1 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "" 2>/dev/null

    if [ -n "$RESPONSE" ]; then
        convo_append 'Assistant: %s\n\n' "$RESPONSE"
        compact_convo

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
    fi

    echo "$RESPONSE"
}
