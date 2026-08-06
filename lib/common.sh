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

CONVOFILE="/tmp/deskcrab-convo.txt"
SUMMARYFILE="/tmp/deskcrab-convo-summary.txt"
TTSPIDFILE="/tmp/deskcrab-tts.pid"
DEBUGLOG="/tmp/deskcrab-debug.log"

# Kill any active TTS
stop_tts() {
    [ -f "$TTSPIDFILE" ] && kill "$(cat "$TTSPIDFILE")" 2>/dev/null && rm -f "$TTSPIDFILE"
    pkill -f "piper-tts.*$(basename "$PIPER_VOICE" .onnx)" 2>/dev/null
    pkill -f "aplay.*S16_LE" 2>/dev/null
}

# Archive stale conversation (default: >5 min idle)
rotate_convo() {
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

# Fold the oldest CONVO_SUMMARIZE_TURNS pairs into the running summary once the live
# convo exceeds CONVO_MAX_TURNS pairs. Keeps recent turns verbatim, older ones condensed.
compact_convo() {
    [ -f "$CONVOFILE" ] || return 0
    local PAIRS
    PAIRS=$(grep -c '^User: ' "$CONVOFILE")
    (( PAIRS > CONVO_MAX_TURNS )) || return 0

    # Split: oldest N pairs -> /tmp old, the rest stays in CONVOFILE.
    # awk numbers each block, incrementing the counter at every line that starts a
    # user turn ("^User: "). Blocks 1..N are the oldest pairs to fold away.
    local OLDFILE="/tmp/deskcrab-convo-old.$$"
    local NEWFILE="/tmp/deskcrab-convo-new.$$"
    awk -v n="$CONVO_SUMMARIZE_TURNS" '
        /^User: / { turn++ }
        { if (turn <= n) print > OLD; else print > NEW }
    ' OLD="$OLDFILE" NEW="$NEWFILE" "$CONVOFILE"

    [ -s "$OLDFILE" ] || { rm -f "$OLDFILE" "$NEWFILE"; return 0; }

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
        mv "$NEWFILE" "$CONVOFILE"
        rm -f "$OLDFILE"
    else
        # Summarization failed — leave history untouched rather than lose turns.
        rm -f "$OLDFILE" "$NEWFILE"
    fi
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

# Autonomous wake: run claude with NO live TTS streamer and decide afterwards
# whether anything gets spoken or shown — a wake nobody asked for must be able
# to complete in total silence.
run_claude_wake() {
    local PROMPT_TEXT="$1"
    local SYSTEM_PROMPT
    SYSTEM_PROMPT="$(build_system_prompt)"

    printf "[Autonomous wake — %s]\n" "$(date '+%Y-%m-%d %H:%M')" >> "$CONVOFILE"

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
    # Stall watchdog: no wall-clock limit — an active session streams events
    # continuously, so reap only after WAKE_STALL_TIMEOUT seconds of total
    # silence (a hung network call, a tool waiting on stdin forever).
    while kill -0 "$CPID" 2>/dev/null; do
        sleep 10
        local LAST NOW
        LAST=$(stat -c %Y "$DEBUGLOG" 2>/dev/null || date +%s)
        NOW=$(date +%s)
        if [ $((NOW - LAST)) -ge "$WAKE_STALL_TIMEOUT" ]; then
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

    printf "Assistant: %s\n\n" "$RESPONSE" >> "$CONVOFILE"
    compact_convo

    # Silent completion: quiet hours, or the reply opens with "(quiet)".
    case "$RESPONSE" in "(quiet)"*) return 0 ;; esac
    in_quiet_hours && return 0

    local SPOKEN DISPLAY_PART
    SPOKEN=$(echo "$RESPONSE" | sed '/^---DISPLAY---$/,$d')
    DISPLAY_PART=$(echo "$RESPONSE" | sed -n '/^---DISPLAY---$/,${/^---DISPLAY---$/d;p}')

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

# Run claude, save response, handle display channel
run_claude_and_respond() {
    local TEXT="$1"
    local SYSTEM_PROMPT
    SYSTEM_PROMPT="$(build_system_prompt)"

    printf "User: %s\n" "$TEXT" >> "$CONVOFILE"

    start_tts_streamer

    notify-send -t 0 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "Thinking..."

    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    cd "$PROJECT_DIR" && "$CLAUDE_BIN" -p --dangerously-skip-permissions \
        --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" \
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

    # Dismiss thinking notification
    notify-send -t 1 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "" 2>/dev/null

    local RESPONSE
    RESPONSE=$(extract_response)

    if [ -n "$RESPONSE" ]; then
        printf "Assistant: %s\n\n" "$RESPONSE" >> "$CONVOFILE"
        compact_convo

        local DISPLAY_PART
        DISPLAY_PART=$(echo "$RESPONSE" | sed -n '/^---DISPLAY---$/,${/^---DISPLAY---$/d;p}')

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
