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
- **Remote client** — `crab serve` puts an installable web app in front of the same assistant, so a phone can talk to it while the CLI, tools, and conversation stay on the laptop
- **Debug viewer** for watching Crab's tool calls and reasoning in real-time

## Dependencies

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with `whisper-stream` and a model file
- [piper-tts](https://github.com/rhasspy/piper) with a voice model (`.onnx`)
- `aplay` (ALSA utils — for audio playback)
- `notify-send` (for desktop notifications)
- [render-md](https://github.com/TheDiscordian/render-md) (optional — for the display channel)
- `ffmpeg` and whisper.cpp's `whisper-cli` (optional — for the remote client)
- Python 3 (the `markdown` package is optional — it renders the remote client's display channel)

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
| Serve the phone client | `crab serve` |

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
| `TTS_FIXES` | No | `sed` expressions to fix TTS pronunciation (spoken text only) |
| `CONTEXT_FILES` | No | Space-separated list of files to include in the prompt |
| `ASSISTANT_NAME` | No | Persona name the assistant sees in its system prompt (default: `Crab`) |
| `NOTIFY_NAME` | No | Name shown in notifications (default: `ASSISTANT_NAME` if set, else `DeskCrab`) |
| `WANTS_FILE` | No | Durable goals file the assistant maintains and pursues during autonomous wakes |
| `WAKE_QUIET_HOURS` | No | Hours (`HH-HH`, wraps midnight) when wakes never speak or open windows |
| `WAKE_EFFORT` | No | Effort level for autonomous wakes (default: `CLAUDE_EFFORT`) |
| `WAKE_STALL_TIMEOUT` | No | Seconds without output or CPU activity before a wake is presumed hung (default: 300) |
| `SERVE_SECRET` | No | Shared secret for the remote client; unset disables `crab serve` entirely |
| `SERVE_PORT` | No | Port for `crab serve` (default: 8723) |
| `SERVE_BIND` | No | Address for `crab serve` (default: `127.0.0.1`) |
| `SERVE_TIMEOUT` | No | Seconds a single remote turn may take before it is abandoned (default: 600) |

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

### TTS fixes

Piper mispronounces some words — or spells them out letter-by-letter (e.g. "hmph"). Rewrite them with sed expressions before they're spoken. Fixes apply only to the spoken reply; display-channel content is untouched:

```bash
TTS_FIXES='s/\bhmph\b/humph/gi'
```

## Autonomous wants & wakes

Give the assistant its own durable goals and let it work on them unprompted. Set `WANTS_FILE` in your config and the assistant gains:

- **A wants file** it maintains itself — adding wants as they form in conversation, dating progress notes, and retiring satisfied ones. The file is injected into every prompt, so wants persist across sessions.
- **`crab wake`** — an autonomous session: the assistant reviews its wants, advances one, and updates the file. Nobody is waiting, so it only speaks (or opens a display window) when it judges something worth surfacing; otherwise it replies `(quiet)` and the wake is invisible. Wakes are skipped (or rescheduled) if a recording or speech is in progress, and unattended sessions are told to take no destructive or outward-facing actions. Sessions have **no wall-clock limit** — the assistant controls its own duration and can chain longer work across wakes; only a session showing no life signs (no output *and* no process-tree CPU activity, so long compiles count as alive) for `WAKE_STALL_TIMEOUT` seconds is presumed hung and reaped.
- **`crab wake-at <when>`** — the assistant (or you) can schedule a one-shot wake via a transient systemd timer: `crab wake-at 2h`, `crab wake-at 45min`, `crab wake-at "09:30"`.
- **Random background wakes** — install the provided timer for wakes every 3–6 hours:

```bash
cp systemd/deskcrab-wake.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now deskcrab-wake.timer
```

Set `WAKE_QUIET_HOURS="23-09"` to keep night wakes fully silent (they still run and can work — they just never speak or open windows).

## Remote client (phone)

`crab serve` puts a small web app in front of the assistant so a phone can talk to it. The assistant does not move: the phone is a microphone, a speaker, and a screen, while the `claude` CLI, the system prompt, the tools, the wants file, and the conversation all stay on this machine. A remote turn is the same conversation as the desktop one — ask something on the laptop, follow it up from the phone.

```bash
# in your config
SERVE_SECRET="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"

crab serve            # listens on 127.0.0.1:8723
```

Open `http://127.0.0.1:8723/?k=<secret>`. The key is stored in a cookie on first load, so the app can be installed to a home screen and opened with no querystring afterwards. Requests without the key get a flat `404` — an unauthenticated caller is told nothing about what is running here.

**Reaching it from a phone.** Browsers only grant microphone access in a secure context, so the server must be behind TLS. It binds loopback by default; publishing it is a separate, deliberate act:

```bash
tailscale serve --bg https / http://127.0.0.1:8723
```

Under the hood, `/ask` takes the browser's recording (Chrome sends WebM/Opus, iOS Safari sends MP4/AAC — ffmpeg decodes either), transcribes it with **batch** `whisper-cli` rather than `whisper-stream`, and hands the text to `crab remote`, which runs a normal turn and returns the spoken half as an Opus file plus the display half as HTML. Batch transcription of a finished clip is both simpler and faster than the desktop's settle-and-poll loop, so a remote turn costs only a couple of seconds more than a local one end to end. Remote turns are serialized — two overlapping requests queue rather than race.

`crab serve` needs `ffmpeg` and `whisper-cli`; the optional Python `markdown` package renders the display channel properly (without it, display content is shown as preformatted text).

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

## Integrations

### weather-cache

If [weather-cache](https://github.com/TheDiscordian/weather-cache) is installed and `~/.cache/weather/` exists, Crab automatically detects it and tells Claude how to read the cached weather data. No configuration needed — just install weather-cache and Crab picks it up.

## Conversation history

Crab maintains a running conversation at `/tmp/deskcrab-convo.txt`. After a period of inactivity (default: 5 minutes), the conversation is archived to `~/.local/share/deskcrab/archive/` with a timestamp filename. This lets Crab remember context within a session while keeping old conversations for reference.

The archive directory can be changed with `ARCHIVE_DIR` in your config, and the inactivity timeout with `CONVO_TIMEOUT`.

## Architecture

```
crab start   →  whisper-stream (recording)
crab stop    →  whisper transcription → claude CLI → TTS streaming
                                                  → display channel (optional)
crab <text>  →  claude CLI → TTS streaming → display channel (optional)
crab serve   →  HTTP  →  ffmpeg → whisper-cli (batch) → crab remote
                                               → opus reply + display HTML
```

- `crab` — main entry point (voice + text)
- `lib/common.sh` — shared functions (TTS, conversation, prompt building, Claude invocation)
- `lib/serve.py` — stdlib HTTP front end for the remote client
- `lib/webapp/` — the phone client (single page, installable)
- `crab-debug` — real-time debug viewer

## License

[MIT](LICENSE)
