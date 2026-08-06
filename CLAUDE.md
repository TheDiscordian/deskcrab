# DeskCrab

A push-to-talk desktop assistant for Linux powered by Claude Code. The assistant is named "Crab" by default; `ASSISTANT_NAME` in the config renames it.

## Project structure

- `crab` — main entry point script (start/stop/shutup or any text as a query)
- `crab-debug` — Python real-time debug viewer for stream-json output
- `lib/common.sh` — shared functions: TTS, conversation management, prompt building, Claude invocation
- `deskcrab.conf.example` — example configuration
- `custom-prompt.md.example` — example custom prompt file

## How it works

1. `deskcrab start` launches whisper-stream for real-time STT
2. `deskcrab stop` kills whisper, reads the transcription through `lib/transcript-dedup` (collapses whisper-stream's overlapping-window repeats), applies whisper fixes
3. Builds system prompt from core instructions + custom prompt + context files + conversation history
4. Launches a background TTS streamer that reads Claude's stream-json output
5. Calls `claude` CLI with `--output-format stream-json` and pipes output to the TTS streamer
6. TTS streamer extracts text blocks and pipes them to piper-tts → aplay in real-time
7. After Claude finishes, extracts the display channel (if any) and opens render-md
8. Conversation is saved and archived after configurable inactivity timeout

## Key details

- Config loaded from `~/.config/deskcrab/deskcrab.conf` (override with `DESKCRAB_CONF` env var)
- Autonomous mode: `WANTS_FILE` (durable goals injected into the prompt), `crab wake` (silent-capable unattended session via `run_claude_wake` — no TTS streamer, post-hoc speak/display decision, `(quiet)` reply = invisible wake), `crab wake-at <when>` (transient systemd timer), `systemd/deskcrab-wake.timer` (random 3–6 h background wakes), `WAKE_QUIET_HOURS` (never speak/show at night)
- All temp files use `/tmp/deskcrab-*` prefix
- Any argument that isn't a subcommand (start/stop/shutup) is treated as a text query
- TTS streams in parallel with Claude's generation — speech starts before the full response is ready
- The display channel delimiter is `---DISPLAY---` on its own line
- `claude` must be on PATH or in `~/.local/bin/`

## Guidelines

- Keep the core system prompt generic — project-specific stuff goes in CUSTOM_PROMPT
- Never hardcode personal data (locations, usernames, server names) in the scripts
- The TTS streamer strips markdown (bold, code) before speaking
- Speed is the top priority — the user is waiting for a spoken response
