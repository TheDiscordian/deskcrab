#!/usr/bin/env python3
"""HTTP front end for DeskCrab — the phone talks to this, the laptop does the work.

The phone is a terminal: microphone, speaker, screen. Everything that makes the
assistant itself (the claude CLI, its tools, the project memory, the wants file,
the conversation) stays on this machine. A remote turn is:

    POST /ask  (raw audio body)
      -> ffmpeg  : whatever the browser recorded -> 16 kHz mono wav
      -> whisper-cli (BATCH, not whisper-stream — the clip is already complete,
                      which is both simpler and faster than the desktop's
                      settle-and-poll loop)
      -> crab remote --voice "<text>"   (same conversation, same prompt)
      -> JSON    : {transcript, spoken, display_html, audio}

Stdlib only, deliberately: no pip, no uv download, no virtualenv to go stale —
it must still start on a laptop that is offline. `markdown` is optional; without
it the display channel is shown as preformatted text.

Started by `crab serve`, which passes config through DESKCRAB_* env vars and
refuses to run without a shared secret. The listener binds loopback by default;
publishing it to a phone is a separate, deliberate act (Tailscale).
"""

import contextlib
import hashlib
import hmac
import http.cookies
import json
import os
import mimetypes
import queue
import re
import subprocess
import ssl
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

LIB_DIR = Path(__file__).resolve().parent
WEBAPP_DIR = LIB_DIR / "webapp"

PORT = int(os.environ.get("DESKCRAB_SERVE_PORT", "8723"))
BIND = os.environ.get("DESKCRAB_SERVE_BIND", "127.0.0.1")
SECRET = os.environ.get("DESKCRAB_SERVE_SECRET", "")
WHISPER_MODEL = os.environ.get("DESKCRAB_WHISPER_MODEL", "")
WHISPER_FIXES = os.environ.get("DESKCRAB_WHISPER_FIXES", "")
CRAB_BIN = os.environ.get("DESKCRAB_CRAB_BIN", "crab")
NAME = os.environ.get("DESKCRAB_NOTIFY_NAME") or os.environ.get(
    "DESKCRAB_ASSISTANT_NAME", "DeskCrab"
)

# A remote turn is a full claude run; it can legitimately take a while.
CERT = os.environ.get("DESKCRAB_SERVE_CERT", "")
KEY = os.environ.get("DESKCRAB_SERVE_KEY", "")

TURN_TIMEOUT = int(os.environ.get("DESKCRAB_SERVE_TIMEOUT", "600"))
MAX_UPLOAD = 25 * 1024 * 1024

# How many turns are being answered right now. Restarting the server kills the
# claude process mid-answer and drops whoever is on the wire, so anything that
# wants to restart asks /health first and waits for this to reach zero.
_IN_FLIGHT = [0]
_IN_FLIGHT_LOCK = threading.Lock()


def turns_in_flight():
    with _IN_FLIGHT_LOCK:
        return _IN_FLIGHT[0]


@contextlib.contextmanager
def turn_in_flight():
    with _IN_FLIGHT_LOCK:
        _IN_FLIGHT[0] += 1
    try:
        yield
    finally:
        with _IN_FLIGHT_LOCK:
            _IN_FLIGHT[0] -= 1


# --- per-turn event buffers -------------------------------------------------
#
# The laptop's uplink is a phone hotspot, so the client's connection routinely
# dies mid-turn. Every event a turn produces is therefore buffered here as well
# as written to the socket; a client that reconnects asks /turn/<id>?from=<n>
# and gets exactly the events it missed, then follows live. The turn itself
# runs on its own thread, so a dead socket never kills the claude process.

TURN_BUFFER_TTL = int(os.environ.get("DESKCRAB_SERVE_TURN_TTL", "3600"))


class Turn:
    def __init__(self, tid):
        self.tid = tid
        self.events = []
        self.done = False
        self.created = time.time()
        self.cond = threading.Condition()

    def emit(self, kind, payload):
        with self.cond:
            self.events.append({"kind": kind, **payload})
            if kind == "done":
                self.done = True
            self.cond.notify_all()


TURNS = {}
TURNS_LOCK = threading.Lock()


def get_turn(tid, create=False):
    """Look up (and atomically maybe create) a turn buffer.

    Returns (turn, created). Two racing requests with the same id get the same
    buffer and exactly one `created=True` — the loser attaches instead of
    running the turn twice.
    """
    with TURNS_LOCK:
        now = time.time()
        for dead in [k for k, v in TURNS.items()
                     if v.done and now - v.created > TURN_BUFFER_TTL]:
            TURNS.pop(dead)
        t = TURNS.get(tid)
        if t is None and create:
            TURNS[tid] = t = Turn(tid)
            return t, True
        return t, False


def _clean_tid(raw):
    """Client-supplied turn id, hex only. Empty/absent -> fresh server id."""
    tid = re.sub(r"[^a-f0-9]", "", (raw or "").lower())[:64]
    return tid or uuid.uuid4().hex


def run_turn(turn, text):
    """The actual assistant turn, feeding the buffer. Socket-independent."""
    try:
        with turn_in_flight():
            speaker = Speaker(turn.emit)
            reply = ask(text,
                        on_event=lambda kind, msg: turn.emit(kind, {"text": msg}),
                        speaker=speaker)
            turn.emit("done", {
                "spoken": reply.get("spoken", ""),
                "display_html": render_markdown(reply.get("display", "")),
                "audio": "",
                "error": reply.get("error", ""),
            })
    except Exception as exc:  # noqa: BLE001 — the client must hear about it
        turn.emit("done", {"spoken": "", "display_html": "", "audio": "",
                           "error": str(exc)[:300]})


if not SECRET:
    sys.exit("serve.py: DESKCRAB_SERVE_SECRET is required (set SERVE_SECRET in the config)")

try:
    import markdown as _markdown
except ImportError:
    _markdown = None

# Web Push (reaching the phone with the page closed) needs ECDH + AES-GCM,
# which stdlib cannot do. Same deal as `markdown`: optional. Without the
# `cryptography` package the push routes answer 501 and everything else works.
try:
    import webpush as _webpush
except ImportError:
    _webpush = None


def render_markdown(text):
    if not text.strip():
        return ""
    if _markdown is None:
        from html import escape

        return "<pre>" + escape(text) + "</pre>"
    return publish_local_images(
        _markdown.markdown(text, extensions=["fenced_code", "tables"]))


# Display markdown routinely points <img> at a local file (/tmp/cat.jpg), which
# means nothing to a phone. Each such path gets a token and is served back over
# this connection; nothing is exposed that a reply did not deliberately name.
IMAGES = {}
IMG_RE = re.compile(r'(<img\b[^>]*?\bsrc=")([^"]+)(")', re.I)


def publish_local_images(html):
    def sub(m):
        src = m.group(2)
        if "://" in src or src.startswith("//") or src.startswith("/img/"):
            return m.group(0)
        p = Path(src[7:] if src.startswith("file://") else src).expanduser()
        try:
            p = p.resolve(strict=True)
        except OSError:
            return m.group(0)
        if not p.is_file():
            return m.group(0)
        token = hashlib.sha256(str(p).encode()).hexdigest()[:24]
        IMAGES[token] = p
        return m.group(1) + "/img/" + token + m.group(3)

    return IMG_RE.sub(sub, html)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, timeout=TURN_TIMEOUT, **kw)


STATE_PREFIX = os.environ.get("DESKCRAB_STATE_PREFIX", "/tmp/deskcrab")
CONTEXT_TURNS = int(os.environ.get("DESKCRAB_SERVE_CONTEXT_TURNS", "6"))

# The phone's liveness beacon: touched on every authenticated /watch poll. An
# autonomous wake deciding whether its voice belongs on the phone checks this
# file's freshness — the same channel that would deliver the audio, so a fresh
# beacon means the audio will actually be picked up.
PHONE_SEEN = STATE_PREFIX + "-phone-seen"

# Pointer a wake writes when it routes its spoken reply here instead of the
# desk speakers. Freshness is bounded so a pointer nobody collected never
# replays days later when a page finally loads.
WAKE_AUDIO = STATE_PREFIX + "-wake-audio"
WAKE_AUDIO_TTL = int(os.environ.get("DESKCRAB_SERVE_WAKE_TTL", "120"))


def read_wake():
    """The current wake-audio pointer, if it is still fresh."""
    p = Path(WAKE_AUDIO)
    try:
        if time.time() - p.stat().st_mtime > WAKE_AUDIO_TTL:
            return None
        doc = json.loads(p.read_text())
    except (OSError, ValueError):
        return None
    if doc.get("id") and doc.get("audio"):
        return {"id": str(doc["id"]), "audio": doc["audio"],
                "spoken": doc.get("spoken", "")}
    return None


def read_context():
    """Where the conversation currently stands, for seeding a freshly loaded page.

    Returns the running compaction summary (if compaction has happened at all)
    plus the last CONTEXT_TURNS exchanges still live in the convo file. Both are
    optional: a brand-new conversation yields nothing and the client shows
    nothing rather than an empty shell.
    """
    summary = ""
    sp = Path(STATE_PREFIX + "-convo-summary.txt")
    if sp.is_file():
        summary = sp.read_text(errors="replace").strip()

    turns = read_turns()
    n = len(turns)
    wake = read_wake()
    # wake_id lets a freshly loaded page mark the current wake audio as already
    # heard instead of blaring it on open.
    # Pairs, not messages — six exchanges reads as six exchanges.
    return {"summary": summary, "turns": turns[-(CONTEXT_TURNS * 2):], "n": n,
            "wake_id": wake["id"] if wake else ""}


def read_turns():
    """Every turn still live in the convo file, oldest first."""
    turns = []
    cp = Path(STATE_PREFIX + "-convo.txt")
    if not cp.is_file():
        return turns
    cur = None
    for line in cp.read_text(errors="replace").splitlines():
        if line.startswith("User: "):
            cur = {"role": "user", "text": line[6:]}
            turns.append(cur)
        elif line.startswith("Assistant: "):
            cur = {"role": "assistant", "text": line[11:]}
            turns.append(cur)
        elif line.startswith("[Autonomous wake"):
            # A wake marker is a turn boundary, not prose. Without this it is
            # welded onto the end of whatever turn preceded it as a
            # "continuation", polluting that bubble and hiding the fact that
            # the assistant turn that follows stands alone.
            cur = None
        elif cur is not None:
            # Continuation of a multi-line turn.
            cur["text"] += "\n" + line
    for t in turns:
        t["text"] = t["text"].strip()
        # A stored reply keeps its display channel inline. Live turns arrive
        # already split, so split these the same way — otherwise the markdown
        # lands in the spoken bubble as a wall of raw asterisks.
        if t["role"] == "assistant" and "---DISPLAY---" in t["text"]:
            spoken, _, disp = t["text"].partition("---DISPLAY---")
            t["text"] = spoken.strip()
            t["display_html"] = render_markdown(disp.strip())
    return turns


WATCH_TIMEOUT = int(os.environ.get("DESKCRAB_SERVE_WATCH_TIMEOUT", "25"))


def watch_turns(since, wait, wakeseen=None):
    """Long-poll for turns that appeared since the caller's cursor.

    The cursor is a turn count. Compaction drops the oldest lines, so the count
    can shrink; when it does the cursor is simply snapped back to the new total
    rather than replaying the whole file as if it were new.

    Wake audio rides the same poll with its own cursor: `wakeseen` is the id of
    the last wake clip the client played, and a fresh pointer with a different
    id ends the poll early so the voice arrives within a beat of being written.
    A client that sent no wakeseen at all cannot acknowledge an id, so handing
    it the wake would turn every poll into an instant return for the pointer's
    whole TTL — a hot loop. Wake delivery is strictly opt-in by the parameter's
    presence (an empty value opts in; None does not).
    """
    deadline = time.time() + (WATCH_TIMEOUT if wait else 0)
    while True:
        turns = read_turns()
        n = len(turns)
        if since is None or since > n:
            since = n
        wake = read_wake() if wakeseen is not None else None
        if wake is not None and wake["id"] == wakeseen:
            wake = None
        if n > since or wake is not None:
            out = {"n": n, "turns": turns[since:]}
            if wake is not None:
                out["wake"] = wake
            return out
        if time.time() >= deadline:
            return {"n": n, "turns": []}
        time.sleep(0.5)


def _suffix_for(ctype):
    """Chrome records webm/opus, iOS Safari mp4/aac — ffmpeg wants a hint."""
    if "mp4" in ctype or "aac" in ctype:
        return ".mp4"
    if "ogg" in ctype:
        return ".ogg"
    return ".webm"


def apply_whisper_fixes(text):
    """Speech-recognition rewrites (WHISPER_FIXES in the config), applied the
    moment a transcript is born. They used to be applied later, by
    `crab remote --voice` — after the raw transcript had already been shown to
    the phone — so the User: line stored in the conversation differed from the
    text the phone remembered, and the phone's own-turn filter let the turn
    echo back onto the screen as if it had been said elsewhere. One canonical
    transcript, fixed once, seen identically by the phone, the conversation
    file, and the prompt."""
    if not WHISPER_FIXES or not text:
        return text
    try:
        r = subprocess.run(["sed", "-E", WHISPER_FIXES], input=text.encode(),
                           capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return text
    if r.returncode != 0:
        return text
    fixed = " ".join(r.stdout.decode("utf-8", "replace").split()).strip()
    return fixed or text


def transcribe(blob, suffix):
    """Browser recording -> text. ffmpeg decodes whatever container arrived."""
    tmp = Path(tempfile.gettempdir())
    stamp = uuid.uuid4().hex[:12]
    raw = tmp / f"deskcrab-upload-{stamp}{suffix}"
    wav = tmp / f"deskcrab-upload-{stamp}.wav"
    raw.write_bytes(blob)
    try:
        r = run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw),
                 "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)])
        if r.returncode != 0 or not wav.exists() or wav.stat().st_size == 0:
            return "", "audio could not be decoded"
        r = run(["whisper-cli", "-m", WHISPER_MODEL, "-f", str(wav), "-nt", "-np"])
        if r.returncode != 0:
            return "", "transcription failed"
        text = " ".join(r.stdout.decode("utf-8", "replace").split()).strip()
        # whisper emits these for silence; they are not something anybody said.
        if text.lower() in ("[blank_audio]", "(silence)", "[silence]", "."):
            text = ""
        return apply_whisper_fixes(text), None
    finally:
        for f in (raw, wav):
            f.unlink(missing_ok=True)


def _wav_seconds(path):
    """16 kHz mono s16le: 32000 bytes a second, minus the 44-byte header."""
    try:
        return max(0.0, (os.path.getsize(path) - 44) / 32000.0)
    except OSError:
        return 0.0


def _silences(wav):
    """Times (seconds) where a pause starts, so segments never cut mid-word."""
    r = run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(wav),
             "-af", "silencedetect=n=-35dB:d=0.35", "-f", "null", "-"])
    out = r.stderr.decode("utf-8", "replace")
    return [float(m) for m in re.findall(r"silence_start:\s*([0-9.]+)", out)]


class SttSession:
    """Incremental speech-to-text over a recording that is still happening.

    The phone uploads its MediaRecorder output in slices while you are still
    talking, so by the time the button is released almost all of the audio has
    already crossed the wire *and* been decoded. Only the tail is left.

    Slices after the first carry no container header, so they are only
    meaningful appended to the ones before them — the accumulated file is
    re-decoded each time (cheap, ~30 ms) and whisper is then run on just the
    part that has not been transcribed yet. Segment boundaries are placed at
    detected pauses rather than at slice boundaries: cutting mid-word costs
    more accuracy than waiting one more slice costs latency.
    """

    TTL = 600  # seconds; a session the phone abandoned is swept on next use

    def __init__(self, sid, suffix):
        self.sid = sid
        tmp = Path(tempfile.gettempdir())
        self.raw = tmp / f"deskcrab-stream-{sid}{suffix}"
        self.wav = tmp / f"deskcrab-stream-{sid}.wav"
        self.parts = []
        self.consumed = 0.0
        self.touched = time.time()
        self.lock = threading.Lock()
        self.raw.write_bytes(b"")

    def append(self, blob):
        with self.lock:
            self.touched = time.time()
            with open(self.raw, "ab") as f:
                f.write(blob)

    def advance(self, final=False):
        """Decode what has arrived and transcribe everything that has settled."""
        with self.lock:
            self.touched = time.time()
            if not self.raw.stat().st_size:
                return
            r = run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(self.raw),
                     "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                     str(self.wav)])
            if r.returncode != 0 or not self.wav.exists():
                return
            total = _wav_seconds(self.wav)
            if final:
                cut = total
            else:
                # Only pauses comfortably inside the audio are candidates: the
                # trailing silence of a slice is usually just the gap before
                # the next word, not the end of a phrase.
                pauses = [s for s in _silences(self.wav)
                          if s > self.consumed + 1.0 and s < total - 0.4]
                if not pauses:
                    return
                cut = pauses[-1]
            if cut - self.consumed < 0.4:
                return
            text = self._decode(self.consumed, cut - self.consumed)
            self.consumed = cut
            if text:
                self.parts.append(text)

    def _decode(self, start, dur):
        seg = self.wav.with_name(self.wav.stem + f"-{int(start * 100)}.wav")
        try:
            r = run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(self.wav),
                     "-ss", f"{start:.2f}", "-t", f"{dur:.2f}", str(seg)])
            if r.returncode != 0 or not seg.exists() or not seg.stat().st_size:
                return ""
            r = run(["whisper-cli", "-m", WHISPER_MODEL, "-f", str(seg),
                     "-nt", "-np"])
            if r.returncode != 0:
                return ""
            text = " ".join(r.stdout.decode("utf-8", "replace").split()).strip()
            if text.lower() in ("[blank_audio]", "(silence)", "[silence]", "."):
                return ""
            return text
        finally:
            seg.unlink(missing_ok=True)

    def transcript(self):
        return " ".join(p for p in self.parts if p).strip()

    def close(self):
        for f in (self.raw, self.wav):
            f.unlink(missing_ok=True)


STT_SESSIONS = {}
STT_LOCK = threading.Lock()


def stt_session(sid, suffix, create=False):
    with STT_LOCK:
        for dead in [k for k, v in STT_SESSIONS.items()
                     if time.time() - v.touched > SttSession.TTL]:
            STT_SESSIONS.pop(dead).close()
        s = STT_SESSIONS.get(sid)
        if s is None and create:
            s = STT_SESSIONS[sid] = SttSession(sid, suffix)
        return s


class Speaker:
    """Voices text blocks as they stream in, one at a time and in order.

    The desktop speaks every text block through piper while the turn is still
    running; the phone gets the same thing as a series of opus clips. Synthesis
    runs on its own thread so tailing the log never blocks, and strictly
    sequentially — a reply spoken out of order is worse than one spoken late.
    """

    def __init__(self, emit):
        self.emit = emit
        self.queue = queue.Queue()
        self.thread = threading.Thread(target=self._work, daemon=True)
        self.thread.start()

    def say(self, text):
        self.queue.put(text)

    def _work(self):
        while True:
            text = self.queue.get()
            if text is None:
                return
            out = os.path.join(
                tempfile.gettempdir(), f"deskcrab-remote-{uuid.uuid4().hex}.opus")
            r = run([CRAB_BIN, "synth", out, text])
            if r.returncode == 0 and os.path.exists(out) and os.path.getsize(out):
                self.emit("voice", {"text": text,
                                    "audio": "/audio/" + os.path.basename(out)})

    def finish(self):
        self.queue.put(None)
        self.thread.join(timeout=120)


def _progress_events(logpath, stop, emit, speaker):
    """Tail a turn's stream-json log and report what the assistant is doing.

    The desktop client shows thinking and tool use as it happens; without this
    the phone stares at a spinner for the whole turn. Same stream, different
    consumer — we only summarise, the TTS streamer is not involved here.
    """
    seen_tools = 0
    while not stop.is_set() and not os.path.exists(logpath):
        time.sleep(0.05)
    try:
        with open(logpath, "r", errors="replace") as f:
            while not stop.is_set():
                line = f.readline()
                if not line:
                    time.sleep(0.05)
                    continue
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d.get("type") == "result":
                    return
                if d.get("type") != "assistant" or "message" not in d:
                    continue
                for block in d["message"].get("content", []):
                    kind = block.get("type")
                    if kind == "thinking":
                        thought = " ".join((block.get("thinking") or "").split())
                        if thought:
                            emit("thinking", thought[-400:])
                    elif kind == "tool_use":
                        seen_tools += 1
                        emit("tool", _tool_label(block))
                    elif kind == "text":
                        said = " ".join((block.get("text") or "").split())
                        said = said.split("---DISPLAY---")[0].strip()
                        if said:
                            # Not truncated: this block IS part of the reply on
                            # the phone, appended in order, not a status line.
                            emit("text", said)
                            # Speak it now, exactly as the desktop's TTS
                            # streamer does — every text block gets a voice, not
                            # just the final one.
                            if speaker:
                                speaker.say(said)
    except OSError:
        return


def _tool_label(block):
    """A short human line for a tool call — the command, not the whole payload."""
    name = block.get("name", "tool")
    inp = block.get("input") or {}
    for field in ("command", "pattern", "file_path", "path", "query", "url", "prompt"):
        val = inp.get(field)
        if isinstance(val, str) and val.strip():
            return f"{name}: {' '.join(val.split())[:120]}"
    return name


def ask(text, on_event=None, speaker=None):
    """One turn through the real assistant. Returns the crab remote JSON.

    With on_event, progress is reported live while the turn runs. With speaker,
    each text block is also voiced as it arrives instead of only at the end.

    No --voice here: WHISPER_FIXES was already applied when the transcript was
    made, and --voice would apply it a second time — worse, to typed text too.
    The turn must store the text exactly as the phone knows it, or the phone
    cannot recognise its own turn coming back around in /watch.
    """
    if on_event is None:
        r = run([CRAB_BIN, "remote", text])
    else:
        logpath = f"/tmp/deskcrab-turn-{uuid.uuid4().hex}.log"
        stop = threading.Event()
        watcher = threading.Thread(
            target=_progress_events, args=(logpath, stop, on_event, speaker),
            daemon=True,
        )
        watcher.start()
        env = dict(os.environ, DESKCRAB_REMOTE_LOG=logpath)
        try:
            r = run([CRAB_BIN, "remote", text], env=env)
        finally:
            stop.set()
            watcher.join(timeout=1)
            if speaker:
                speaker.finish()
            Path(logpath).unlink(missing_ok=True)
    out = r.stdout.decode("utf-8", "replace").strip()
    # crab remote prints exactly one JSON object last; anything a tool leaked to
    # stdout before it would otherwise poison the parse.
    for line in reversed(out.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return {"spoken": "", "display": "", "audio": "",
            "error": r.stderr.decode("utf-8", "replace")[-500:] or "no response"}


class Handler(BaseHTTPRequestHandler):
    server_version = "deskcrab"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s  %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    # --- plumbing ---

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # The app is a single page talking only to its own origin.
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj, extra=None):
        self._send(code, json.dumps(obj), "application/json; charset=utf-8", extra)

    def _presented_key(self):
        header = self.headers.get("X-Crab-Key")
        if header:
            return header
        raw = self.headers.get("Cookie")
        if raw:
            jar = http.cookies.SimpleCookie()
            try:
                jar.load(raw)
            except http.cookies.CookieError:
                return None
            if "crabkey" in jar:
                return jar["crabkey"].value
        return None

    def _authed(self, query_key=None):
        for candidate in (query_key, self._presented_key()):
            if candidate and hmac.compare_digest(candidate, SECRET):
                return True
        return False

    # --- routes ---

    def do_GET(self):
        url = urlparse(self.path)
        # keep_blank_values: "wakeseen=" (nothing played yet) is an opt-in that
        # must survive parsing — parse_qs silently drops empty values otherwise.
        query = parse_qs(url.query, keep_blank_values=True)
        query_key = (query.get("k") or [None])[0]
        path = url.path

        if path == "/health":
            # `busy` is deliberately unauthenticated: it carries no content,
            # only whether a turn is in flight, and a restarter needs to be
            # able to ask without holding the secret.
            return self._json(200, {"ok": True, "name": NAME, "busy": turns_in_flight()})

        if not self._authed(query_key):
            # No hint about what is running here for an unauthenticated caller.
            return self._send(404, "not found")

        # Arriving with ?k=... stores the key so the installed PWA needs no
        # querystring afterwards.
        extra = {}
        if query_key:
            extra["Set-Cookie"] = (
                f"crabkey={query_key}; Path=/; Max-Age=31536000; "
                "SameSite=Strict; HttpOnly"
            )

        if path == "/context":
            return self._json(200, read_context(), extra)

        if path == "/push/key":
            # The VAPID public key the browser subscribes against. Generated
            # once on first ask and kept forever — rotating it would orphan
            # every existing subscription.
            if _webpush is None:
                return self._json(501, {"error": "push unavailable: python-cryptography is not installed"}, extra)
            return self._json(200, {"key": _webpush.vapid_keys()[1]}, extra)

        if path == "/watch":
            # Turns spoken at the laptop land in the same conversation file, so
            # the phone can follow along by watching it rather than being told.
            raw = (query.get("since") or [None])[0]
            try:
                since = int(raw) if raw is not None else None
            except ValueError:
                since = None
            wait = (query.get("wait") or ["1"])[0] != "0"
            wakeseen = (query.get("wakeseen") or [None])[0]
            # Only a wake-capable client (one that sends wakeseen) counts as
            # "connected": routing audio at a page too old to play it would
            # swallow the wake into silence on both devices.
            if wakeseen is not None:
                with contextlib.suppress(OSError):
                    Path(PHONE_SEEN).touch()
            return self._json(200, watch_turns(since, wait, wakeseen), extra)

        if path.startswith("/turn/"):
            # Re-attach to an in-flight (or recently finished) turn: replay
            # the buffered events past the client's cursor, then follow live.
            tid = re.sub(r"[^a-f0-9]", "", os.path.basename(path).lower())[:64]
            t, _ = get_turn(tid)
            if t is None:
                return self._json(404, {"error": "unknown turn"}, extra)
            raw = (query.get("from") or ["0"])[0]
            try:
                start = int(raw)
            except ValueError:
                start = 0
            return self._stream_turn(t, start)

        if path in ("/", "/index.html"):
            return self._send(200, (WEBAPP_DIR / "index.html").read_bytes(),
                              "text/html; charset=utf-8", extra)
        if path == "/manifest.webmanifest":
            # The installed app launches in its own context, which may not carry
            # the cookie, so bake the key into start_url.
            doc = json.loads((WEBAPP_DIR / "manifest.webmanifest").read_text())
            doc["start_url"] = "/?k=" + SECRET
            return self._send(200, json.dumps(doc),
                              "application/manifest+json", extra)
        if path == "/sw.js":
            return self._send(200, (WEBAPP_DIR / "sw.js").read_bytes(),
                              "application/javascript", extra)
        if path == "/icon.svg":
            return self._send(200, (WEBAPP_DIR / "icon.svg").read_bytes(),
                              "image/svg+xml", extra)
        if path.startswith("/img/"):
            f = IMAGES.get(os.path.basename(path))
            if f is None or not f.is_file():
                return self._send(404, "not found")
            ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
            return self._send(200, f.read_bytes(), ctype, extra)
        if path.startswith("/audio/"):
            name = os.path.basename(path)
            # Only ever serve this server's own generated replies.
            if not name.startswith("deskcrab-remote-") or not name.endswith(".opus"):
                return self._send(404, "not found")
            f = Path(tempfile.gettempdir()) / name
            if not f.exists():
                return self._send(404, "not found")
            return self._send(200, f.read_bytes(), "audio/ogg", extra)

        return self._send(404, "not found")

    def do_POST(self):
        if not self._authed():
            return self._send(404, "not found")
        url = urlparse(self.path)

        length = int(self.headers.get("Content-Length") or 0)
        # /stt/finish legitimately carries nothing — the audio already arrived
        # in slices while the user was still talking.
        empty_ok = url.path == "/stt/finish"
        if length > MAX_UPLOAD or (length <= 0 and not empty_ok):
            return self._json(400, {"error": "bad body length"})
        body = self.rfile.read(length) if length > 0 else b""

        if url.path in ("/stt/chunk", "/stt/finish"):
            q = parse_qs(url.query)
            sid = re.sub(r"[^a-f0-9]", "", (q.get("s") or [""])[0])[:32]
            if not sid:
                return self._json(400, {"error": "bad session"})
            ctype = self.headers.get("X-Audio-Type", "audio/webm")
            final = url.path == "/stt/finish"
            s = stt_session(sid, _suffix_for(ctype), create=not final)
            if s is None:
                return self._json(200, {"error": "unknown session"})
            if body:
                s.append(body)
            # Non-final slices advance opportunistically: if the audio has not
            # reached a pause yet there is simply nothing to transcribe, and
            # saying so costs nothing.
            s.advance(final=final)
            if not final:
                return self._json(200, {"partial": s.transcript()})
            text = apply_whisper_fixes(s.transcript())
            with STT_LOCK:
                STT_SESSIONS.pop(sid, None)
            s.close()
            if not text:
                return self._json(200, {"error": "no speech detected"})
            return self._json(200, {"transcript": text})

        if url.path in ("/push/subscribe", "/push/unsubscribe"):
            # The browser's PushSubscription, stored so `crab notify` can reach
            # this phone with the page closed. Idempotent by endpoint: the page
            # re-posts its subscription on every load and the store never grows
            # a duplicate.
            if _webpush is None:
                return self._json(501, {"error": "push unavailable: python-cryptography is not installed"})
            try:
                doc = json.loads(body.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                return self._json(400, {"error": "bad json"})
            if url.path == "/push/unsubscribe":
                removed, left = _webpush.remove_subscription(str(doc.get("endpoint", "")))
                return self._json(200, {"ok": True, "removed": removed, "stored": left})
            if not _webpush.valid_subscription(doc):
                return self._json(400, {"error": "not a valid PushSubscription"})
            return self._json(200, {"ok": True, "stored": _webpush.add_subscription(doc)})

        if url.path == "/transcribe":
            # Speech recognition only. The client shows the transcript the
            # instant it lands and asks for the answer separately, so a
            # mis-heard sentence is visible before the long wait, not after.
            ctype = self.headers.get("X-Audio-Type", "audio/webm")
            text, err = transcribe(body, _suffix_for(ctype))
            if err:
                return self._json(200, {"error": err})
            if not text:
                return self._json(200, {"error": "no speech detected"})
            return self._json(200, {"transcript": text})

        if url.path == "/ask":
            ctype = self.headers.get("X-Audio-Type", "audio/webm")
            text, err = transcribe(body, _suffix_for(ctype))
            if err:
                return self._json(200, {"error": err})
            if not text:
                return self._json(200, {"error": "no speech detected"})
            tid = _clean_tid((parse_qs(url.query).get("turn") or [""])[0])
        elif url.path == "/say":
            try:
                doc = json.loads(body.decode("utf-8"))
                text = doc.get("text", "").strip()
            except (json.JSONDecodeError, UnicodeDecodeError):
                return self._json(400, {"error": "bad json"})
            if not text:
                return self._json(200, {"error": "empty message"})
            tid = _clean_tid(doc.get("turn"))
        else:
            return self._send(404, "not found")

        # The answer is streamed, not returned in one lump: the desktop client
        # shows thinking and tool use as it happens and the phone should too.
        # Plain chunked SSE over the same POST — no second connection to
        # authenticate, correlate, and clean up.
        #
        # The turn itself runs on its own thread, feeding a buffer; this
        # connection merely tails the buffer. If the hotspot drops mid-turn the
        # turn carries on, and the client reconnects to /turn/<id>?from=<n> for
        # the rest. The id comes from the client so a retried POST is
        # idempotent: same id -> attach to the running turn, never a second run.
        turn, created = get_turn(tid, create=True)
        if created:
            turn.emit("transcript", {"text": text})
            threading.Thread(target=run_turn, args=(turn, text),
                             daemon=True).start()
        return self._stream_turn(turn, 0)

    def _stream_turn(self, turn, start):
        """SSE-over-chunked: replay buffered events from `start`, then follow
        live until the turn is done. A write failure just ends this tail — the
        buffer, and the turn, live on."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def write(raw):
            try:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(raw), raw))
                self.wfile.flush()
                return True
            except (BrokenPipeError, ConnectionResetError, ValueError, OSError):
                return False

        i = max(0, start)
        while True:
            with turn.cond:
                if i >= len(turn.events) and not turn.done:
                    turn.cond.wait(timeout=15)
                events = turn.events[i:]
                done = turn.done
            if not events and not done:
                # Keepalive comment: without traffic a dead hotspot socket can
                # sit in ESTABLISHED forever and this thread would tail nothing
                # to nobody. The client ignores non-data frames.
                if not write(b": ping\n\n"):
                    return
                continue
            for ev in events:
                frame = f"data: {json.dumps(ev)}\n\n".encode("utf-8")
                if not write(frame):
                    return
            i += len(events)
            if done and i >= len(turn.events):
                break
        try:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ValueError, OSError):
            pass
        return


def main():
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    httpd.daemon_threads = True

    scheme = "http"
    if CERT and KEY:
        # A browser only grants microphone access over https (or to localhost),
        # so a phone client needs TLS from somewhere: either here, or from a
        # proxy like `tailscale serve` that terminates it in front of us.
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT, KEY)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"

    print(f"{NAME} is listening on {scheme}://{BIND}:{PORT}/?k=<secret>")
    if scheme == "http":
        print("To reach it from a phone: tailscale serve --bg https / "
              f"http://127.0.0.1:{PORT}   (or set SERVE_TLS=self)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
