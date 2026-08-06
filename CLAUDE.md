# DeskCrab

A push-to-talk desktop assistant for Linux powered by Claude Code. The assistant is named "Crab" by default; `ASSISTANT_NAME` in the config renames it.

## Project structure

- `crab` — main entry point script (start/stop/shutup or any text as a query)
- `crab-debug` — Python real-time debug viewer for stream-json output
- `lib/common.sh` — shared functions: TTS, conversation management, prompt building, Claude invocation
- `lib/serve.py` — stdlib HTTP front end for the remote (phone) client, started by `crab serve`
- `lib/webapp/` — the phone client: one HTML page, a manifest, a network-only service worker
- `lib/notice-newfiles` — event emitter: turns files arriving in a watched directory into an event wake
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
- Autonomous mode: `WANTS_FILE` (durable goals injected into the prompt), `crab wake` (silent-capable unattended session via `run_claude_wake` — no TTS streamer, post-hoc speak/display decision, `(quiet)` reply = invisible wake), `crab wake-at <when> [kind] [reason]` (transient systemd timer), `systemd/deskcrab-wake.timer` (random 3–6 h background wakes), `WAKE_QUIET_HOURS` (never speak/show at night)
- Event wakes: `crab wake event "<reason>"` wakes the assistant *about something*, and the reason becomes that session's agenda instead of the wants file. Emitters live in `lib/` and are driven by systemd `.path` units, which watch with the kernel's own inotify — no polling daemon, no `inotify-tools`. `lib/notice-newfiles` is the first one (a transcript lands → wake about it); it seeds silently on first run so an existing backlog never fires, and defers while a Parley recording is still writing. Event units are shipped but **not** enabled by default — enabling one changes how the machine behaves towards its user, which is their call: `systemctl --user enable --now deskcrab-notice-transcriptions.path`
- Only one wake session runs at a time (`${STATE_PREFIX}-wake.lock`, held for the life of the process). A wake blocked by the lock — or by an active recording or speech — is re-armed 10–15 min later with its kind and reason intact, rather than dropped
- Remote client: `crab serve` (HTTP front end) + `crab remote <text>` (one turn in, JSON out). The phone is only a microphone/speaker/screen — the CLI, prompt, tools, and conversation never leave this machine. Uploaded clips go through **batch** `whisper-cli`, not `whisper-stream`: the clip is already complete, so batch is both simpler and faster. Serving requires `SERVE_SECRET` and binds loopback; exposing it (Tailscale, for the TLS a browser mic demands) is a separate, deliberate step
- `serve.py` is stdlib-only on purpose — no pip, no virtualenv to go stale, it must start on an offline laptop
- All temp files use `/tmp/deskcrab-*` prefix (override the whole prefix with `DESKCRAB_STATE_PREFIX` to run a scratch instance beside the live one)
- Every writer of the conversation file — desktop turn, remote turn, autonomous wake, compaction, rotation — goes through `convo_append` / the `$CONVOLOCK` flock. More than one client can now be mid-turn at once, and an append landing inside compaction's summarize-and-swap would otherwise vanish
- Any argument that isn't a subcommand (start/stop/shutup) is treated as a text query
- TTS streams in parallel with Claude's generation — speech starts before the full response is ready
- The display channel delimiter is `---DISPLAY---` on its own line
- `claude` must be on PATH or in `~/.local/bin/`

## Guidelines

- Keep the core system prompt generic — project-specific stuff goes in CUSTOM_PROMPT
- Never hardcode personal data (locations, usernames, server names) in the scripts
- The TTS streamer strips markdown (bold, code) before speaking
- Speed is the top priority — the user is waiting for a spoken response
