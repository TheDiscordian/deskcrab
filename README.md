# DeskCrab

A push-to-talk desktop assistant for Linux powered by [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Hold a key to talk, release to get a spoken response. Crab can execute commands, fetch information, display rich content, and maintain conversation context across interactions.

> **⚠️ Warning:** Crab runs Claude Code with `--dangerously-skip-permissions`, meaning it can execute any command on your system without asking for confirmation. This is necessary for a voice assistant (you can't approve each tool call mid-conversation), but it means Crab has full access to your shell, files, and network. Only run it on machines you trust, and review your custom prompt carefully — it shapes what Crab will do autonomously.

## Features

- **Push-to-talk voice input** via whisper.cpp (streaming STT)
- **Spoken responses** via piper-tts (streamed TTS — starts speaking before Claude finishes)
- **Display channel** for rich content (code, images, tables) via [render-md](https://github.com/TheDiscordian/render-md)
- **Conversation memory** with automatic archiving after inactivity
- **Text mode** — skip voice and type directly with `crab how's the weather?`
- **Fully configurable** — custom prompts, whisper fixes, context files, model selection
- **Debug viewer** for watching Crab's tool calls and reasoning in real-time

## Dependencies

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with `whisper-stream` and a model file
- [piper-tts](https://github.com/rhasspy/piper) with a voice model (`.onnx`)
- `aplay` (ALSA utils — for audio playback)
- `notify-send` (for desktop notifications)
- [render-md](https://github.com/TheDiscordian/render-md) (optional — for the display channel)
- Python 3

### Arch Linux / CachyOS

```bash
# whisper.cpp and piper from AUR
paru -S whisper.cpp-clblast piper-tts-bin

# Download a whisper model (small.en recommended)
# See: https://huggingface.co/ggerganov/whisper.cpp

# Download a piper voice
# See: https://github.com/rhasspy/piper/blob/master/VOICES.md
mkdir -p ~/.local/share/piper
# Example: en_US-lessac-medium
```

## Install

```bash
git clone https://github.com/TheDiscordian/deskcrab.git
cd deskcrab

# Copy scripts
cp crab crab-debug ~/.local/bin/
cp -r lib ~/.local/lib/deskcrab/
chmod +x ~/.local/bin/crab ~/.local/bin/crab-debug

# Create config
mkdir -p ~/.config/deskcrab
cp deskcrab.conf.example ~/.config/deskcrab/deskcrab.conf
$EDITOR ~/.config/deskcrab/deskcrab.conf
```

## Usage

### Voice mode (push-to-talk)

Bind these to a key in your compositor:

| Action | Command |
|--------|---------|
| Start recording (hold) | `crab start` |
| Stop and process (release) | `crab stop` |
| Stop TTS playback | `crab shutup` |
| Open debug viewer | `crab-debug` |

**Hyprland** example (SUPER+A as push-to-talk):

```ini
bind = $mainMod, A, exec, ~/.local/bin/crab start
bindr = $mainMod, A, exec, ~/.local/bin/crab stop
bind = $mainMod SHIFT, A, exec, ~/.local/bin/crab shutup
bind = $mainMod CTRL SHIFT, A, exec, kitty --class deskcrab-debug -T "Crab Debug" ~/.local/bin/crab-debug
```

**Sway** example:

```ini
bindsym --no-repeat $mod+a exec ~/.local/bin/crab start
bindsym --release $mod+a exec ~/.local/bin/crab stop
bindsym $mod+Shift+a exec ~/.local/bin/crab shutup
bindsym $mod+Ctrl+Shift+a exec kitty --class deskcrab-debug -T "Crab Debug" ~/.local/bin/crab-debug
```

### Text mode

```bash
crab "what time is it in Tokyo?"
crab "summarize this file: ~/notes.md"
```

Any argument that isn't a subcommand (`start`, `stop`, `shutup`) is treated as a text query.

### Debug viewer

Watch Crab's tool calls, reasoning, and responses in real-time:

```bash
crab-debug
```

Best opened in a terminal before triggering a voice command. Shows tool names, inputs, outputs, response text, duration, and cost.

## Configuration

Edit `~/.config/deskcrab/deskcrab.conf`. See `deskcrab.conf.example` for all options.

| Variable | Required | Description |
|----------|----------|-------------|
| `PIPER_VOICE` | Yes | Path to piper-tts voice model (`.onnx`) |
| `WHISPER_MODEL` | Yes | Path to whisper.cpp model |
| `CLAUDE_MODEL` | No | Claude model to use (default: `opus`) |
| `CLAUDE_EFFORT` | No | Claude effort level (default: `low`) |
| `PROJECT_DIR` | No | Working directory for Claude (default: `$HOME`) |
| `ARCHIVE_DIR` | No | Where to store conversation archives |
| `CONVO_TIMEOUT` | No | Seconds of inactivity before archiving conversation (default: 300) |
| `CUSTOM_PROMPT` | No | Path to a markdown file appended to Crab's core system prompt |
| `WHISPER_FIXES` | No | `sed` expressions to fix common whisper mistranscriptions |
| `CONTEXT_FILES` | No | Space-separated list of files to include in the prompt |
| `NOTIFY_NAME` | No | Name shown in notifications (default: `DeskCrab`) |

### Custom prompt

Crab has a built-in system prompt that handles core behavior (TTS formatting, display channel, speed optimization). Your custom prompt is **appended** to this, so use it for project-specific context or personal preferences — not for overriding Crab's core instructions.

```bash
cp custom-prompt.md.example ~/.config/deskcrab/custom-prompt.md
```

Then set `CUSTOM_PROMPT="$HOME/.config/deskcrab/custom-prompt.md"` in your config.

### Whisper fixes

Whisper often mistranscribes proper nouns. Fix them with sed expressions:

```bash
WHISPER_FIXES='s/mycool app/MyCoolApp/gi; s/\bhy plant\b/Hyprland/gi'
```

## Display channel

When Crab's response includes visual content (code, tables, images), it uses a display channel. The response includes a `---DISPLAY---` delimiter, and everything after it is rendered in a floating [render-md](https://github.com/TheDiscordian/render-md) window.

### Compositor window rules

**Hyprland**:

```ini
windowrule {
    match:class = ^(deskcrab-display|com\.github\.render-md)$
    float = on
    size = 80% 90%
    move = 10% 5%
    pin = on
}
```

## Conversation history

Crab maintains a running conversation at `/tmp/deskcrab-convo.txt`. After a period of inactivity (default: 5 minutes), the conversation is archived to `~/.local/share/deskcrab/archive/` with a timestamp filename. This lets Crab remember context within a session while keeping old conversations for reference.

The archive directory can be changed with `ARCHIVE_DIR` in your config, and the inactivity timeout with `CONVO_TIMEOUT`.

## Architecture

```
crab start   →  whisper-stream (recording)
crab stop    →  whisper transcription → claude CLI → TTS streaming
                                                  → display channel (optional)
crab <text>  →  claude CLI → TTS streaming → display channel (optional)
```

- `crab` — main entry point (voice + text)
- `lib/common.sh` — shared functions (TTS, conversation, prompt building, Claude invocation)
- `crab-debug` — real-time debug viewer

## License

[MIT](LICENSE)
