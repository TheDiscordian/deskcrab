#!/bin/bash
# Shared config and functions for DeskCrab

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
NOTIFY_NAME="${NOTIFY_NAME:-DeskCrab}"

CONVOFILE="/tmp/deskcrab-convo.txt"
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
            mv "$CONVOFILE" "$ARCHIVE_DIR/$(date -d "@$LAST_MOD" '+%Y%m%d-%H%M%S').txt"
        fi
    fi
}

# Build conversation context string
build_convo_context() {
    if [ -f "$CONVOFILE" ]; then
        echo "

Here is your conversation so far:
$(cat "$CONVOFILE")"
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

    cat <<PROMPT
You are Crab, a desktop voice assistant running on Linux. You can and should execute commands via Bash to fulfill requests.
SPEED IS CRITICAL. The user is waiting for a spoken response. Avoid slow tools: use ToolSearch at most ONCE, and never use Agent. Prefer Bash (curl, etc.) and WebFetch which are fast. Do not retry failed fetches more than once — give the best answer you can with what you have.
Today is $(date '+%A %B %d, %Y'), the current time is $(date '+%I:%M %p %Z'). Tomorrow is $(date -d '+1 day' '+%A'). Use today/tonight/tomorrow for the next 2 days, day names for anything further out. CRITICAL: Never quote alert text verbatim. Rephrase everything in your own words using relative day references. If an alert says 'Monday' and tomorrow is Monday, say 'tomorrow'.
Your responses will be spoken aloud via TTS. ALWAYS start with a brief spoken reply (1-2 sentences, no markdown, no lists, no elaboration). Answer directly like a human would in conversation. Write numbers and units as spoken words (e.g. '22 degrees' not '22°C', 'percent' not '%').
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
$CUSTOM_CONTEXT
$CONTEXT_CONTENT$CONVO_CONTEXT
PROMPT
}

# Start background TTS streamer that reads from DEBUGLOG
start_tts_streamer() {
    : > "$DEBUGLOG"
    python3 -c "
import json, subprocess, time, os, re, signal

signal.signal(signal.SIGTERM, lambda *a: os._exit(0))

LOG = '$DEBUGLOG'
PIPER = '$PIPER_VOICE'

def speak(text):
    try:
        piper = subprocess.Popen(
            ['piper-tts', '--model', PIPER, '--output-raw'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        aplay = subprocess.Popen(
            ['aplay', '-r', '22050', '-c', '1', '-f', 'S16_LE', '-t', 'raw'],
            stdin=piper.stdout, stderr=subprocess.DEVNULL)
        piper.stdin.write(text.encode())
        piper.stdin.close()
        aplay.wait()
        piper.wait()
    except Exception:
        pass

while not os.path.exists(LOG):
    time.sleep(0.1)

with open(LOG) as f:
    while True:
        line = f.readline()
        if not line:
            time.sleep(0.05)
            continue
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get('type') == 'result':
            break
        if d.get('type') == 'assistant' and 'message' in d:
            for block in d['message'].get('content', []):
                if block.get('type') == 'text':
                    text = block['text'].strip()
                    if not text:
                        continue
                    text = text.split('---DISPLAY---')[0].strip()
                    text = re.sub(r'\*+', '', text)
                    text = re.sub(r'\x60[^\x60]*\x60', '', text)
                    text = text.strip()
                    if not text:
                        continue
                    speak(text)
" &
    _TTS_STREAMER_PID=$!
}

# Extract final response text from DEBUGLOG
extract_response() {
    python3 -c "
import json, sys
result_text = ''
last_assistant_text = ''
for line in open('$DEBUGLOG'):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get('type') == 'result' and d.get('result'):
        result_text = d['result']
    elif d.get('type') == 'assistant':
        for block in d.get('message', {}).get('content', []):
            if block.get('type') == 'text' and block.get('text', '').strip():
                last_assistant_text = block['text'].strip()
print(result_text or last_assistant_text)
" 2>/dev/null
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

    # Dismiss thinking notification
    notify-send -t 1 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "" 2>/dev/null

    local RESPONSE
    RESPONSE=$(extract_response)

    if [ -n "$RESPONSE" ]; then
        printf "Assistant: %s\n\n" "$RESPONSE" >> "$CONVOFILE"

        local DISPLAY_PART
        DISPLAY_PART=$(echo "$RESPONSE" | sed -n '/^---DISPLAY---$/,${/^---DISPLAY---$/d;p}')

        if [ -n "$DISPLAY_PART" ]; then
            local DISPLAYFILE="/tmp/deskcrab-display.md"
            echo "$DISPLAY_PART" > "$DISPLAYFILE"
            hyprctl dispatch closewindow class:deskcrab-display 2>/dev/null
            RENDER_MD="${RENDER_MD:-$(command -v render-md 2>/dev/null || echo "$HOME/.local/bin/render-md")}"
            if [ -x "$RENDER_MD" ]; then
                setsid "$RENDER_MD" "$DISPLAYFILE" &
            fi
        fi

        wait "$_TTS_STREAMER_PID" 2>/dev/null
    fi

    echo "$RESPONSE"
}
